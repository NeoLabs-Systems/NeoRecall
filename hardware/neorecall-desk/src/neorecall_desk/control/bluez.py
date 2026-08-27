"""One thread, one event loop, one system bus.

BlueZ is only reachable over D-Bus, and D-Bus in Python is asynchronous, while
the rest of this appliance is deliberately synchronous — a recorder that blocks
on a block of audio is far easier to reason about than one built out of tasks.

Rather than colour the whole codebase async, every D-Bus interaction is funnelled
through this runtime: one dedicated thread owning one event loop and one system
bus connection. Callers hand it a coroutine and get a result or an exception,
exactly as if it were an ordinary function call.

That also means the GATT server and the headphone manager share a single bus
connection instead of racing each other for two.
"""

from __future__ import annotations

import asyncio
import logging
import threading
from collections.abc import Coroutine
from typing import Any, TypeVar

LOG = logging.getLogger(__name__)

BLUEZ_SERVICE = "org.bluez"
ADAPTER_IFACE = "org.bluez.Adapter1"
DEVICE_IFACE = "org.bluez.Device1"
BATTERY_IFACE = "org.bluez.Battery1"
GATT_MANAGER_IFACE = "org.bluez.GattManager1"
LE_ADVERTISING_MANAGER_IFACE = "org.bluez.LEAdvertisingManager1"
AGENT_MANAGER_IFACE = "org.bluez.AgentManager1"
OBJECT_MANAGER_IFACE = "org.freedesktop.DBus.ObjectManager"
PROPERTIES_IFACE = "org.freedesktop.DBus.Properties"

DEFAULT_ADAPTER_PATH = "/org/bluez/hci0"
DEFAULT_TIMEOUT_S = 30.0

T = TypeVar("T")


class BluetoothUnavailable(RuntimeError):
    """No usable Bluetooth stack. The appliance still records; it just cannot pair."""


class BluezRuntime:
    """A private asyncio loop with a connected system bus."""

    def __init__(self) -> None:
        self._loop: asyncio.AbstractEventLoop | None = None
        self._thread: threading.Thread | None = None
        self._bus: Any = None
        self._ready = threading.Event()
        self._error: BaseException | None = None

    @property
    def bus(self) -> Any:
        if self._bus is None:
            raise BluetoothUnavailable("the system bus is not connected")
        return self._bus

    @property
    def running(self) -> bool:
        return self._bus is not None and self._loop is not None and not self._loop.is_closed()

    def start(self, *, timeout: float = DEFAULT_TIMEOUT_S) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._run, name="dbus", daemon=True)
        self._thread.start()
        if not self._ready.wait(timeout):
            raise BluetoothUnavailable("timed out connecting to the system bus")
        if self._error is not None:
            raise BluetoothUnavailable(str(self._error))

    def _run(self) -> None:
        loop = asyncio.new_event_loop()
        self._loop = loop
        asyncio.set_event_loop(loop)

        async def connect() -> Any:
            # The bus must be *constructed* inside the running loop, not merely
            # awaited there: dbus-fast calls asyncio.get_running_loop() in its
            # constructor. Building it outside and awaiting the result fails with
            # "no running event loop", which on real hardware cost the entire
            # control channel while everything else looked healthy.
            from dbus_fast import BusType
            from dbus_fast.aio import MessageBus

            return await MessageBus(bus_type=BusType.SYSTEM).connect()

        try:
            self._bus = loop.run_until_complete(connect())
        except BaseException as error:  # noqa: BLE001 - reported through start()
            self._error = error
            self._ready.set()
            loop.close()
            return
        self._ready.set()
        try:
            loop.run_forever()
        finally:
            loop.close()

    def run(self, coro: Coroutine[Any, Any, T], *, timeout: float = DEFAULT_TIMEOUT_S) -> T:
        """Run a coroutine on the bus thread and wait for its result."""
        if self._loop is None or self._loop.is_closed():
            coro.close()
            raise BluetoothUnavailable("the Bluetooth runtime is not running")
        if threading.current_thread() is self._thread:
            # Waiting here would wait on the thread that has to do the work, so
            # the call could only ever time out. It did: reading the GATT status
            # characteristic asked BlueZ for the headset list from inside the
            # D-Bus handler, and setup failed ten seconds later with no
            # explanation. Refuse immediately and say why, rather than hang.
            coro.close()
            raise BluetoothUnavailable(
                "a Bluetooth call was made from the Bluetooth thread itself; "
                "the caller has to use cached state instead"
            )
        future = asyncio.run_coroutine_threadsafe(coro, self._loop)
        return future.result(timeout)

    def stop(self) -> None:
        loop, self._loop = self._loop, None
        thread, self._thread = self._thread, None
        self._bus = None
        if loop is not None and not loop.is_closed():
            loop.call_soon_threadsafe(loop.stop)
        if thread is not None:
            thread.join(timeout=5)
        self._ready.clear()


async def introspected(bus: Any, path: str, interface: str) -> Any:
    """Return a proxy interface, or None when the object does not expose it."""
    try:
        introspection = await bus.introspect(BLUEZ_SERVICE, path)
    except Exception:  # noqa: BLE001 - a missing object is a normal answer here
        return None
    proxy = bus.get_proxy_object(BLUEZ_SERVICE, path, introspection)
    try:
        return proxy.get_interface(interface)
    except Exception:  # noqa: BLE001
        return None


async def managed_objects(bus: Any) -> dict[str, dict[str, dict[str, Any]]]:
    manager = await introspected(bus, "/", OBJECT_MANAGER_IFACE)
    if manager is None:
        return {}
    raw = await manager.call_get_managed_objects()
    return {
        path: {
            iface: {key: value.value for key, value in props.items()}
            for iface, props in ifaces.items()
        }
        for path, ifaces in raw.items()
    }
