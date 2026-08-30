"""The Bluetooth Low Energy control channel.

This is how the NeoRecall app sees the appliance: one service with four
characteristics — a status the app subscribes to, a command it writes, a setup
message it writes once, and a list of things the appliance found while scanning.

Two properties matter more than the wire details:

* **A recording never depends on this.** Everything here is a view onto state the
  appliance owns anyway. If the phone walks out of range mid-meeting, capture,
  buffering and upload carry on, and the next connection simply reads the truth.
* **Pairing needs a hand on the device.** With no screen there is no number to
  compare, so the appliance is only pairable while it is in setup mode, and the
  only way into setup mode is the physical button. Somebody has to be standing
  at it.


Note the absence of ``from __future__ import annotations`` in this module: the
D-Bus type signatures below are ordinary string annotations that dbus-fast reads
at run time, and deferred evaluation would hand it the quoted source text instead
of the signature.
"""

import logging
import queue
import threading
import time
from collections.abc import Callable

from dbus_fast import PropertyAccess, Variant
from dbus_fast.service import ServiceInterface, dbus_property, method

from ..state import Snapshot
from . import bluez, protocol

LOG = logging.getLogger(__name__)

APP_ROOT = "/de/neorecall/desk"
ADVERTISEMENT_PATH = f"{APP_ROOT}/advertisement0"
SERVICE_PATH = f"{APP_ROOT}/service0"
AGENT_PATH = f"{APP_ROOT}/agent0"

GATT_SERVICE_IFACE = "org.bluez.GattService1"
GATT_CHARACTERISTIC_IFACE = "org.bluez.GattCharacteristic1"
LE_ADVERTISEMENT_IFACE = "org.bluez.LEAdvertisement1"
AGENT_IFACE = "org.bluez.Agent1"

#: "No input, no output": the appliance cannot show or read a pairing code. That
#: makes the physical button the only thing standing between a stranger and a
#: pairing, which is why setup mode is button-gated and time-limited.
AGENT_CAPABILITY = "NoInputNoOutput"

SETUP_MODE_TIMEOUT_S = 300

#: Time between pages of a discovery result. One characteristic carries them all,
#: so each page has to be read out before the next replaces it.
DISCOVERY_PAGE_GAP_S = 0.12

#: Time between audio pages during a Bluetooth drain. Far tighter than the
#: discovery gap: audio pages are numbered, so a lost one is detected by the
#: phone and re-requested with a resume — a luxury scan results do not have.
#: At 192 bytes a page this paces the transfer near 12 KB/s.
AUDIO_PAGE_GAP_S = 0.015


class _Characteristic(ServiceInterface):
    def __init__(
        self,
        path: str,
        uuid: str,
        flags: list[str],
        *,
        on_read: Callable[[], bytes] | None = None,
        on_write: Callable[[bytes], None] | None = None,
    ) -> None:
        super().__init__(GATT_CHARACTERISTIC_IFACE)
        self.path = path
        self._uuid = uuid
        self._flags = flags
        self._on_read = on_read
        self._on_write = on_write
        self._value = b""
        self._notifying = False

    @dbus_property(access=PropertyAccess.READ)
    def UUID(self) -> "s":  # noqa: N802,F821 - the name is BlueZ's
        return self._uuid

    @dbus_property(access=PropertyAccess.READ)
    def Service(self) -> "o":  # noqa: N802,F821
        return SERVICE_PATH

    @dbus_property(access=PropertyAccess.READ)
    def Flags(self) -> "as":  # noqa: N802,F821
        return self._flags

    @dbus_property(access=PropertyAccess.READ)
    def Value(self) -> "ay":  # noqa: N802,F821
        return self._value

    @method()
    def ReadValue(self, options: "a{sv}") -> "ay":  # noqa: N802,F821,ARG002
        if self._on_read is not None:
            self._value = self._on_read()
        return self._value

    @method()
    def WriteValue(self, value: "ay", options: "a{sv}"):  # noqa: N802,F821,ARG002
        if self._on_write is not None:
            self._on_write(bytes(value))

    @method()
    def StartNotify(self):  # noqa: N802
        self._notifying = True

    @method()
    def StopNotify(self):  # noqa: N802
        self._notifying = False

    def publish(self, payload: bytes) -> None:
        """Push a new value to whoever is subscribed."""
        self._value = payload
        if self._notifying:
            self.emit_properties_changed({"Value": payload})

    def properties(self) -> dict[str, Variant]:
        return {
            "UUID": Variant("s", self._uuid),
            "Service": Variant("o", SERVICE_PATH),
            "Flags": Variant("as", self._flags),
        }


class _Service(ServiceInterface):
    def __init__(self, uuid: str) -> None:
        super().__init__(GATT_SERVICE_IFACE)
        self._uuid = uuid

    @dbus_property(access=PropertyAccess.READ)
    def UUID(self) -> "s":  # noqa: N802,F821
        return self._uuid

    @dbus_property(access=PropertyAccess.READ)
    def Primary(self) -> "b":  # noqa: N802,F821
        return True

    def properties(self) -> dict[str, Variant]:
        return {"UUID": Variant("s", self._uuid), "Primary": Variant("b", True)}


class _Application(ServiceInterface):
    """The object manager BlueZ reads to learn our service tree."""

    def __init__(self, service: _Service, characteristics: list[_Characteristic]) -> None:
        super().__init__(bluez.OBJECT_MANAGER_IFACE)
        self._service = service
        self._characteristics = characteristics

    @method()
    def GetManagedObjects(self) -> "a{oa{sa{sv}}}":  # noqa: N802,F821
        objects: dict[str, dict[str, dict[str, Variant]]] = {
            SERVICE_PATH: {GATT_SERVICE_IFACE: self._service.properties()}
        }
        for characteristic in self._characteristics:
            objects[characteristic.path] = {GATT_CHARACTERISTIC_IFACE: characteristic.properties()}
        return objects


class _Advertisement(ServiceInterface):
    def __init__(self, name: str) -> None:
        super().__init__(LE_ADVERTISEMENT_IFACE)
        self._name = name

    @dbus_property(access=PropertyAccess.READ)
    def Type(self) -> "s":  # noqa: N802,F821
        return "peripheral"

    @dbus_property(access=PropertyAccess.READ)
    def ServiceUUIDs(self) -> "as":  # noqa: N802,F821
        return [protocol.SERVICE_UUID]

    @dbus_property(access=PropertyAccess.READ)
    def LocalName(self) -> "s":  # noqa: N802,F821
        return self._name

    @dbus_property(access=PropertyAccess.READ)
    def Includes(self) -> "as":  # noqa: N802,F821
        return ["tx-power"]

    @method()
    def Release(self):  # noqa: N802
        LOG.debug("advertisement released by BlueZ")


class _PairingAgent(ServiceInterface):
    """Accepts pairing only while the appliance is in setup mode."""

    def __init__(self, is_pairable: Callable[[], bool]) -> None:
        super().__init__(AGENT_IFACE)
        self._is_pairable = is_pairable

    def _guard(self) -> None:
        if not self._is_pairable():
            from dbus_fast import DBusError

            raise DBusError("org.bluez.Error.Rejected", "This device is not in setup mode.")

    @method()
    def Release(self):  # noqa: N802
        return

    @method()
    def RequestAuthorization(self, device: "o"):  # noqa: N802,F821,ARG002
        self._guard()

    @method()
    def AuthorizeService(self, device: "o", uuid: "s"):  # noqa: N802,F821,ARG002
        self._guard()

    @method()
    def RequestConfirmation(self, device: "o", passkey: "u"):  # noqa: N802,F821,ARG002
        self._guard()

    @method()
    def Cancel(self):  # noqa: N802
        return


class GattServer:
    """Publishes the control service and keeps the app's view of it current."""

    def __init__(
        self,
        runtime: bluez.BluezRuntime,
        *,
        snapshot_provider: Callable[[], Snapshot],
        on_command: Callable[[protocol.Command], protocol.CommandResult],
        on_provision: Callable[[protocol.Provisioning], protocol.CommandResult],
        adapter_path: str = bluez.DEFAULT_ADAPTER_PATH,
        advertised_name: str = protocol.ADVERTISED_NAME,
    ) -> None:
        self._runtime = runtime
        self._snapshot = snapshot_provider
        self._on_command = on_command
        self._on_provision = on_provision
        self._adapter_path = adapter_path
        self._name = advertised_name
        self._pairable = False
        self._last_result: protocol.CommandResult | None = None
        self._registered = False

        # Commands run on their own thread, never on the D-Bus thread that
        # delivered them. A handler is allowed to talk to BlueZ — switching the
        # output to headphones does exactly that — and a BlueZ call made from
        # the D-Bus thread waits for the loop it is itself blocking. One worker,
        # so commands still execute in the order the app sent them.
        self._work: queue.Queue = queue.Queue()
        self._idle = threading.Condition()
        self._pending = 0
        self._worker = threading.Thread(target=self._work_loop, name="gatt-commands", daemon=True)
        self._worker.start()

        self._service = _Service(protocol.SERVICE_UUID)
        self._status = _Characteristic(
            f"{SERVICE_PATH}/char0",
            protocol.STATUS_UUID,
            ["read", "notify"],
            on_read=self._read_status,
        )
        self._command = _Characteristic(
            f"{SERVICE_PATH}/char1",
            protocol.COMMAND_UUID,
            ["encrypt-write"],
            on_write=self._write_command,
        )
        self._provision = _Characteristic(
            f"{SERVICE_PATH}/char2",
            protocol.PROVISION_UUID,
            ["encrypt-write"],
            on_write=self._write_provision,
        )
        self._discovery = _Characteristic(
            f"{SERVICE_PATH}/char3",
            protocol.DISCOVERY_UUID,
            ["read", "notify"],
        )
        self._characteristics = [self._status, self._command, self._provision, self._discovery]
        self._application = _Application(self._service, self._characteristics)
        self._advertisement = _Advertisement(self._name)
        self._agent = _PairingAgent(lambda: self._pairable)

    # ------------------------------------------------------------------ payloads

    def _read_status(self) -> bytes:
        return protocol.encode_status(self._snapshot(), self._last_result)

    def _write_command(self, payload: bytes) -> None:
        try:
            command = protocol.decode_command(payload)
        except protocol.ProtocolError as error:
            self._last_result = protocol.CommandResult(
                command=protocol.CMD_UNREADABLE, ok=False, message=str(error)
            )
            self.publish_status()
            return
        self._submit(lambda: self._run_command(command))

    def _submit(self, job) -> None:
        with self._idle:
            self._pending += 1
        self._work.put(job)

    def _work_loop(self) -> None:
        while True:
            job = self._work.get()
            if job is None:
                return
            try:
                job()
            except Exception:  # noqa: BLE001 - the worker outlives any one command
                LOG.exception("a queued command failed")
            finally:
                with self._idle:
                    self._pending -= 1
                    self._idle.notify_all()

    def wait_until_idle(self, timeout: float = 5.0) -> bool:
        """Block until queued commands have finished. Used on shutdown, and by tests."""
        with self._idle:
            return self._idle.wait_for(lambda: self._pending == 0, timeout=timeout)

    def _run_command(self, command: protocol.Command) -> None:
        try:
            self._last_result = self._on_command(command)
        except Exception:  # noqa: BLE001 - a bad command must not take the link down
            LOG.exception("command handler failed")
            self._last_result = protocol.CommandResult(
                command=command.name, ok=False, message="Something went wrong on the device."
            )
        self.publish_status()

    def _write_provision(self, payload: bytes) -> None:
        try:
            provisioning = protocol.decode_provisioning(payload)
        except protocol.ProtocolError as error:
            self._last_result = protocol.CommandResult(
                command="setup", ok=False, message=str(error)
            )
            self.publish_status()
            return
        # Also queued: provisioning joins a network and registers with the
        # server, which is seconds of work. Doing it here would hold the D-Bus
        # thread the whole time, and the app's own reads would stall behind it.
        self._submit(lambda: self._run_provision(provisioning))

    def _run_provision(self, provisioning: protocol.Provisioning) -> None:
        try:
            self._last_result = self._on_provision(provisioning)
        except Exception:  # noqa: BLE001
            LOG.exception("provisioning handler failed")
            self._last_result = protocol.CommandResult(
                command=protocol.CMD_SETUP, ok=False, message="Setup could not be completed."
            )
        self.publish_status()

    # ------------------------------------------------------------------ publish

    def publish_status(self) -> None:
        payload = protocol.encode_status(self._snapshot(), self._last_result)
        self._status.publish(payload)

    def publish_audio(self, pages: list[bytes], *, abort=None) -> int:
        """Stream a chunk's pages over the discovery characteristic.

        Returns how many pages went out. ``abort`` is polled between pages so a
        recording that starts mid-transfer can stop the drain immediately — the
        recording always wins the radio.
        """
        sent = 0
        for index, page in enumerate(pages):
            if abort is not None and abort():
                break
            if index:
                time.sleep(AUDIO_PAGE_GAP_S)
            self._discovery.publish(page)
            sent += 1
        return sent

    def publish_discovery(self, kind: str, entries: list[dict]) -> None:
        """Send a result list, in as many notifications as it takes.

        A realistic list does not fit in one: seven self-test verdicts encode to
        about 650 bytes against a 244-byte packet. BlueZ delivered the first
        packet's worth and the app could not decode the fragment, so a scan or a
        sound check produced a spinner that never stopped.

        The pause between pages is not decoration. Notifications are
        PropertiesChanged signals on one characteristic, and pushing the next
        value before BlueZ has read the last one out replaces it — the app then
        waits for a page that was overwritten before it was ever sent.
        """
        pages = protocol.discovery_pages(kind, entries)
        for index, page in enumerate(pages):
            if index:
                time.sleep(DISCOVERY_PAGE_GAP_S)
            self._discovery.publish(page)

    # ---------------------------------------------------------------- lifecycle

    @property
    def pairable(self) -> bool:
        return self._pairable

    def set_setup_mode(self, enabled: bool) -> None:
        """Open or close the window in which a phone may pair."""
        self._pairable = enabled
        try:
            self._runtime.run(self._apply_setup_mode(enabled))
        except bluez.BluetoothUnavailable:
            LOG.warning("could not change pairing state: Bluetooth is unavailable")

    async def _apply_setup_mode(self, enabled: bool) -> None:
        adapter = await bluez.introspected(
            self._runtime.bus, self._adapter_path, bluez.ADAPTER_IFACE
        )
        if adapter is None:
            return
        await adapter.set_powered(True)
        await adapter.set_pairable(enabled)
        await adapter.set_pairable_timeout(SETUP_MODE_TIMEOUT_S if enabled else 0)
        await adapter.set_discoverable(enabled)
        await adapter.set_discoverable_timeout(SETUP_MODE_TIMEOUT_S if enabled else 0)

    def start(self) -> None:
        self._runtime.run(self._register(), timeout=45)
        self._registered = True
        self.publish_status()

    async def _register(self) -> None:
        bus = self._runtime.bus
        bus.export(SERVICE_PATH, self._service)
        for characteristic in self._characteristics:
            bus.export(characteristic.path, characteristic)
        bus.export(APP_ROOT, self._application)
        bus.export(ADVERTISEMENT_PATH, self._advertisement)
        bus.export(AGENT_PATH, self._agent)

        adapter = await bluez.introspected(bus, self._adapter_path, bluez.ADAPTER_IFACE)
        if adapter is None:
            raise bluez.BluetoothUnavailable("no Bluetooth adapter")
        await adapter.set_powered(True)
        await adapter.set_alias(self._name)

        gatt = await bluez.introspected(bus, self._adapter_path, bluez.GATT_MANAGER_IFACE)
        if gatt is None:
            raise bluez.BluetoothUnavailable("this adapter cannot host a GATT service")
        await gatt.call_register_application(APP_ROOT, {})

        advertising = await bluez.introspected(
            bus, self._adapter_path, bluez.LE_ADVERTISING_MANAGER_IFACE
        )
        if advertising is not None:
            try:
                await advertising.call_register_advertisement(ADVERTISEMENT_PATH, {})
            except Exception:  # noqa: BLE001 - a stale registration is recoverable
                LOG.warning("could not start advertising", exc_info=True)

        agents = await bluez.introspected(bus, "/org/bluez", bluez.AGENT_MANAGER_IFACE)
        if agents is not None:
            try:
                await agents.call_register_agent(AGENT_PATH, AGENT_CAPABILITY)
                await agents.call_request_default_agent(AGENT_PATH)
            except Exception:  # noqa: BLE001 - another agent already owns pairing
                LOG.warning("could not become the pairing agent", exc_info=True)

    def stop(self) -> None:
        if not self._registered:
            return
        try:
            self._runtime.run(self._unregister(), timeout=20)
        except bluez.BluetoothUnavailable:
            LOG.debug("Bluetooth already gone during shutdown")
        self._registered = False

    async def _unregister(self) -> None:
        bus = self._runtime.bus
        advertising = await bluez.introspected(
            bus, self._adapter_path, bluez.LE_ADVERTISING_MANAGER_IFACE
        )
        if advertising is not None:
            try:
                await advertising.call_unregister_advertisement(ADVERTISEMENT_PATH)
            except Exception:  # noqa: BLE001
                LOG.debug("advertisement was already gone", exc_info=True)
        gatt = await bluez.introspected(bus, self._adapter_path, bluez.GATT_MANAGER_IFACE)
        if gatt is not None:
            try:
                await gatt.call_unregister_application(APP_ROOT)
            except Exception:  # noqa: BLE001
                LOG.debug("application was already gone", exc_info=True)
        for path in (
            AGENT_PATH,
            ADVERTISEMENT_PATH,
            APP_ROOT,
            *[c.path for c in self._characteristics],
            SERVICE_PATH,
        ):
            try:
                bus.unexport(path)
            except Exception:  # noqa: BLE001
                LOG.debug("could not unexport %s", path, exc_info=True)
