"""The only component that owns appliance state.

Everything else in this package does one thing and does it without opinions: the
ledger stores, the pump uploads, the recorder captures, the GATT server relays.
The supervisor is where those meet, and it is deliberately the only place that
decides anything.

Its most important job is the radio policy. Entering a recording takes the Wi-Fi
interface down so Bluetooth audio has the antenna to itself and pauses the upload
pump, because there is no point retrying against a radio we switched off on
purpose. Leaving a recording puts both back. That single rule is what makes
Bluetooth headphones and reliable uploads coexist on one small chip.
"""

from __future__ import annotations

import logging
import subprocess
import threading
import time
from collections.abc import Callable
from datetime import UTC, datetime

from ..audio import graph
from ..config import ConfigStore
from ..ingest.client import iana_timezone
from ..ingest.pump import UploadPump
from ..ledger import SESSION_ENDED, Ledger
from ..recorder import Recorder
from ..state import MicSource, OutputTarget, Snapshot, State, StateMachine, TransitionRefused
from . import protocol, radio, tones
from .button import ButtonEvent
from .protocol import Command, CommandResult, Provisioning

LOG = logging.getLogger(__name__)

#: The user unit that owns the audio graph. Restarted when the output changes.
RELAY_UNIT = "neorecall-desk-relay.service"

#: The updater and its daily timer. System units, which is why the appliance
#: account needs the polkit grant in `systemd/10-neorecall.rules` to touch them.
UPDATE_UNIT = "neorecall-desk-update.service"
UPDATE_TIMER = "neorecall-desk-update.timer"

#: How often the update watcher asks whether the updater has finished, and how
#: long it keeps asking. An update that outlives the ceiling has not failed —
#: the appliance simply stops claiming to know, rather than showing a spinner
#: with no end.
UPDATE_POLL_S = 3.0
UPDATE_WATCH_CEILING_S = 900.0


class SystemdUnits:
    """The few systemd operations the appliance performs on itself.

    Behind a seam so the supervisor's decisions can be tested without a service
    manager, and so every place that touches systemd is visible in one class
    rather than scattered through the command handlers.
    """

    def start(self, unit: str) -> bool:
        return self._run(["systemctl", "start", unit])

    def restart_user_unit(self, unit: str) -> bool:
        """Restart a unit in this account's own user manager."""
        return self._run(["systemctl", "--user", "restart", unit])

    def enable_timer(self, unit: str, enabled: bool) -> bool:
        action = ["enable", "--now"] if enabled else ["disable", "--now"]
        return self._run(["systemctl", *action, unit])

    def is_enabled(self, unit: str) -> bool:
        return self._run(["systemctl", "is-enabled", "--quiet", unit])

    def is_active(self, unit: str) -> bool:
        """Whether a unit is still running. A finished oneshot is not active."""
        return self._run(["systemctl", "is-active", "--quiet", unit])

    def failed(self, unit: str) -> bool:
        return self._run(["systemctl", "is-failed", "--quiet", unit])

    @staticmethod
    def _run(argv: list[str]) -> bool:
        try:
            return (
                subprocess.run(argv, capture_output=True, timeout=30, check=False).returncode == 0
            )
        except (OSError, subprocess.SubprocessError):
            LOG.debug("%s failed", " ".join(argv), exc_info=True)
            return False


STATUS_TICK_S = 1.0

#: How often the connected headset is re-read from BlueZ. Slower than the status
#: tick on purpose — see `_status_loop`. A command handler refreshes it directly,
#: so anything the user just did is reflected without waiting for this.
HEADSET_POLL_S = 5.0

WIFI_JOIN_TIMEOUT_S = 45

#: How long to wait for PipeWire to publish a headset's sink after BlueZ says it
#: is connected. The two are not simultaneous, and routing into the gap fails.
BLUETOOTH_SINK_TIMEOUT_S = 6.0
BLUETOOTH_SINK_POLL_S = 0.25


class Supervisor:
    def __init__(
        self,
        *,
        ledger: Ledger,
        config_store: ConfigStore,
        pump: UploadPump,
        firmware: str,
        recorder_factory: Callable[[], Recorder],
        gatt=None,
        headphones=None,
        toneplayer: tones.Toneplayer | None = None,
        radio_module=radio,
        audio_graph=graph,
        units=None,
        now: Callable[[], datetime] = lambda: datetime.now(UTC),
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self._ledger = ledger
        self._config = config_store
        self._pump = pump
        self._firmware = firmware
        self._recorder_factory = recorder_factory
        self._gatt = gatt
        self._headphones = headphones
        self._tones = toneplayer or tones.Toneplayer()
        self._radio = radio_module
        self._graph = audio_graph
        self._units = units or SystemdUnits()
        self._now = now
        self._monotonic = monotonic

        self._machine = StateMachine(configured=config_store.get().configured)
        self._machine.on_change(self._on_state_change)
        self._lock = threading.RLock()
        self._recorder: Recorder | None = None
        self._recorder_thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._status_thread: threading.Thread | None = None
        self._output_target = OutputTarget.SPEAKER
        self._output_name = "Speaker"
        self._error = ""
        self._setup_mode = False
        self._update_state = "idle"
        self._auto_update = True
        self._selftest_running = False
        # The headset is *cached*, not queried on demand. Reading the status
        # characteristic happens on the D-Bus thread, and asking BlueZ from
        # there deadlocks against the very loop that has to deliver the answer:
        # setup timed out after ten seconds and pairing could never finish.
        self._headset = None

    # ---------------------------------------------------------------- lifecycle

    def start(self) -> None:
        report = self._ledger.recover()
        if any(report.values()):
            LOG.info("recovered from an unclean shutdown: %s", report)
        self._reconcile_configuration()
        # Ask systemd rather than assume. The switch defaulted to "on" and was
        # only ever changed by the app, so an appliance whose timer was off
        # showed it as on until somebody toggled it twice.
        self._auto_update = self._units.is_enabled(UPDATE_TIMER)
        if not self._config.get().configured:
            self.enter_setup_mode()
        self._status_thread = threading.Thread(target=self._status_loop, name="status", daemon=True)
        self._status_thread.start()
        # The radio comes up on its own thread. `nmcli radio wifi on` blocks for
        # as long as NetworkManager takes to answer — measured in seconds on a
        # cold boot — and it used to run before the status thread started, so
        # the appliance was unreachable over Bluetooth for the whole of it while
        # having nothing to say that depended on the answer.
        if self._config.get().configured:
            threading.Thread(target=self._radio.enable, name="radio-up", daemon=True).start()
        self._tones.play(tones.READY)

    def stop(self) -> None:
        self._stop.set()
        self.stop_recording()
        if self._status_thread is not None:
            self._status_thread.join(timeout=3)
            self._status_thread = None

    def attach_gatt(self, gatt) -> None:
        """Hand the supervisor its control channel once it is published.

        The two are built as a pair — the server needs the supervisor's snapshot
        and command handlers, the supervisor needs somewhere to publish — so one
        of them has to be wired in afterwards.
        """
        self._gatt = gatt
        if self._setup_mode:
            gatt.set_setup_mode(True)
        self._publish()

    @property
    def state(self) -> State:
        return self._machine.state

    # ------------------------------------------------------------------ status

    def snapshot(self) -> Snapshot:
        pump = self._pump.status
        config = self._config.get()
        headset = self._connected_headset()
        return Snapshot(
            state=self._machine.state,
            recording_elapsed_ms=self._recorder.elapsed_ms if self._recorder else 0,
            pending_chunks=pump.pending_chunks,
            needs_attention=pump.needs_attention,
            output_target=self._output_target,
            output_name=self._output_name,
            mic_source=MicSource.HEADSET
            if (config.use_hfp_mic and headset is not None)
            else MicSource.BUILT_IN,
            headset_connected=headset is not None,
            headset_name=headset.name if headset else "",
            headset_battery=headset.battery if headset else None,
            network_online=self._radio.online() if self._radio.available() else False,
            authentication_failed=pump.authentication_failed,
            device_revoked=pump.device_revoked,
            error=self._error or self._user_facing_error(pump),
            firmware=self._firmware,
            device_id=config.device_id,
            update_state=self._update_state,
            auto_update=self._auto_update,
        )

    def _user_facing_error(self, pump) -> str:
        """Turn machine trouble into a sentence somebody can act on."""
        if pump.device_revoked:
            return "This device was removed from your account. Set it up again."
        if pump.authentication_failed:
            return "This device lost access to your account. Set it up again."
        if pump.needs_attention:
            return f"{pump.needs_attention} recordings could not be sent."
        if pump.pending_chunks and not self._radio.online():
            return f"No network yet — {pump.pending_chunks} recordings are waiting."
        return ""

    def _connected_headset(self):
        """The connected headset as last seen. Never talks to BlueZ."""
        return self._headset

    def _refresh_headset(self) -> None:
        """Ask BlueZ which headset is connected. Callers must not be the bus thread."""
        if self._headphones is None:
            self._headset = None
            return
        try:
            self._headset = next(
                (device for device in self._headphones.known() if device.connected), None
            )
        except Exception:  # noqa: BLE001 - a missing headset must not stop the appliance
            LOG.debug("could not read the headset list", exc_info=True)
            self._headset = None

    def _publish(self) -> None:
        if self._gatt is not None:
            try:
                self._gatt.publish_status()
            except Exception:  # noqa: BLE001 - a status update must not break anything
                LOG.debug("could not publish status", exc_info=True)

    def _status_loop(self) -> None:
        """Keep the app's picture current, at two different rates.

        The elapsed recording clock has to move every second. The headset does
        not: asking BlueZ for every managed object on the bus is the most
        expensive thing this loop can do, and doing it once a second kept a core
        of a Pi Zero 2 W busy for a question whose answer changes when somebody
        picks up a pair of headphones.
        """
        since_headset = HEADSET_POLL_S
        while not self._stop.wait(STATUS_TICK_S):
            since_headset += STATUS_TICK_S
            if since_headset >= HEADSET_POLL_S:
                since_headset = 0.0
                # This thread is the one place allowed to block on BlueZ.
                self._refresh_headset()
            if self._machine.state is State.RECORDING or self._pump.status.pending_chunks:
                self._publish()

    # -------------------------------------------------------------- transitions

    def _on_state_change(self, previous: State, current: State) -> None:
        LOG.info("state %s -> %s", previous, current)
        if current is State.RECORDING:
            self._radio.disable()
            self._pump.set_paused(True)
        elif previous is State.RECORDING:
            self._pump.set_paused(False)
            self._radio.enable()
            self._pump.wake()
        self._publish()

    def start_recording(self) -> CommandResult:
        with self._lock:
            try:
                self._machine.start()
            except TransitionRefused as error:
                self._tones.play(tones.REFUSED)
                return CommandResult(command=protocol.CMD_START, ok=False, message=str(error))
            if self._recorder is not None:
                return CommandResult(command=protocol.CMD_START, ok=True)

            self._error = ""
            recorder = self._recorder_factory()
            self._recorder = recorder
            self._recorder_thread = threading.Thread(
                target=self._run_recorder, args=(recorder,), name="recorder", daemon=True
            )
            self._recorder_thread.start()
            self._tones.play(tones.RECORDING_STARTED)
            return CommandResult(command=protocol.CMD_START, ok=True)

    def _run_recorder(self, recorder: Recorder) -> None:
        try:
            recorder.run()
        except Exception:  # noqa: BLE001 - a failed recording still has to close cleanly
            LOG.exception("the recording ended unexpectedly")
            self._error = "The recording stopped unexpectedly."
        finally:
            if recorder.fault:
                self._error = recorder.fault
            with self._lock:
                if self._recorder is recorder:
                    self._recorder = None
            self._machine.stop()
            self._pump.wake()
            self._publish()

    def stop_recording(self) -> CommandResult:
        with self._lock:
            recorder, self._recorder = self._recorder, None
            thread, self._recorder_thread = self._recorder_thread, None
        if recorder is not None:
            recorder.request_stop()
        if thread is not None:
            thread.join(timeout=30)
        self._machine.stop()
        if recorder is not None:
            self._tones.play(tones.RECORDING_STOPPED)
        return CommandResult(command=protocol.CMD_STOP, ok=True)

    # -------------------------------------------------------------------- setup

    def enter_setup_mode(self) -> None:
        self._setup_mode = True
        if self._gatt is not None:
            self._gatt.set_setup_mode(True)
        self._tones.play(tones.SETUP_MODE)
        self._publish()

    def leave_setup_mode(self) -> None:
        self._setup_mode = False
        if self._gatt is not None:
            self._gatt.set_setup_mode(False)

    def _reconcile_configuration(self) -> None:
        """Keep the state machine honest about whether there is an account.

        The two can drift — an account removed from the app, a stored
        configuration cleared — and a machine that still believes it is set up
        would happily start a recording with nowhere to send it.

        A running recording is never touched. A credential problem discovered
        mid-meeting is a reason to show an error, never a reason to stop
        capturing audio that is already durable on the card.
        """
        if self._machine.state is State.RECORDING:
            return
        # Devices set up before the app sent a usable timezone still carry the
        # abbreviation, and would log the same complaint on every upload for
        # the rest of their lives. Fix it once, here.
        stored = self._config.get().timezone
        usable = iana_timezone(stored)
        if stored and stored != usable:
            LOG.info("replacing the unusable timezone %r with %r", stored, usable)
            self._config.update(timezone=usable)
        configured = self._config.get().configured
        if configured and self._machine.state is State.UNCONFIGURED:
            self._machine.configured()
        elif not configured and self._machine.state is not State.UNCONFIGURED:
            self._machine.unconfigured()

    def on_button(self, event: ButtonEvent) -> None:
        if event is ButtonEvent.LONG_PRESS:
            self.enter_setup_mode()
            return
        self._reconcile_configuration()
        if self._machine.state is State.RECORDING:
            self.stop_recording()
        else:
            self.start_recording()

    # ----------------------------------------------------------------- commands

    def handle_command(self, command: Command) -> CommandResult:
        # Commands arrive on the GATT worker thread, so this is a safe place to
        # ask BlueZ what is actually connected rather than trust the cache the
        # status path has to make do with.
        self._refresh_headset()
        handler = {
            protocol.CMD_START: lambda: self.start_recording(),
            protocol.CMD_STOP: lambda: self.stop_recording(),
            protocol.CMD_SET_OUTPUT: lambda: self._set_output(command),
            protocol.CMD_SET_HEADSET_MIC: lambda: self._set_headset_mic(command),
            protocol.CMD_WIFI_SCAN: lambda: self._wifi_scan(),
            protocol.CMD_BT_SCAN: lambda: self._bt_scan(),
            protocol.CMD_BT_CONNECT: lambda: self._bt_action(command, "connect"),
            protocol.CMD_BT_DISCONNECT: lambda: self._bt_action(command, "disconnect"),
            protocol.CMD_BT_FORGET: lambda: self._bt_action(command, "forget"),
            protocol.CMD_RENAME: lambda: self._rename(command),
            protocol.CMD_FORGET_ACCOUNT: lambda: self._forget_account(),
            protocol.CMD_UPDATE_NOW: lambda: self._update_now(),
            protocol.CMD_SET_AUTO_UPDATE: lambda: self._set_auto_update(command),
            protocol.CMD_SELFTEST: lambda: self._selftest(),
        }.get(command.name)
        if handler is None:
            return CommandResult(
                command=command.name,
                ok=False,
                message="This device does not understand that request.",
            )
        return handler()

    def _route_output(self, target: OutputTarget) -> tuple[bool, str]:
        """Actually move the sound, and remember where it went.

        The single place that changes the output. Three things have to happen
        together and used to happen in two different methods that each did a
        subset: the default sink moves, the choice is persisted, and the relay is
        restarted so it re-resolves its playback target.

        That last step is the one connecting a pair of headphones used to skip.
        It set the status to "Headphones" without restarting the relay, so the
        relay kept playing at the speaker it had resolved at start-up — and
        because the app then showed headphones as already selected, the one
        control that would have fixed it could no longer be triggered. The sound
        was audible for as long as the sink took to move and silent afterwards.
        """
        if target is OutputTarget.HEADPHONES:
            routed = self._wait_for_bluetooth_sink() and self._graph.use_bluetooth()
        else:
            routed = self._graph.use_speaker()
        if not routed:
            return False, "Could not switch to that output."
        self._config.update(
            output_target="headphones" if target is OutputTarget.HEADPHONES else "speaker"
        )
        # The default sink is only half of it. The relay plays at a *named*
        # target resolved when it started, so a running relay keeps using
        # whatever it found then however the default is set.
        if not self._units.restart_user_unit(RELAY_UNIT):
            return False, "Could not move the sound to that output."
        self._output_target = target
        headset = self._connected_headset()
        self._output_name = (
            (headset.name if headset else "Headphones")
            if target is OutputTarget.HEADPHONES
            else "Speaker"
        )
        return True, ""

    def _wait_for_bluetooth_sink(self) -> bool:
        """Give PipeWire a moment to publish the headset's sink.

        BlueZ reports a headset connected before WirePlumber has built a node
        for it. Routing in that gap finds no Bluetooth sink and fails, so
        connecting a pair of headphones reported an error — or fell back to the
        speaker — for a headset that was connected and about to work.
        """
        deadline = self._monotonic() + BLUETOOTH_SINK_TIMEOUT_S
        while True:
            if self._graph.bluetooth_available():
                return True
            if self._monotonic() >= deadline:
                LOG.warning(
                    "no Bluetooth sink appeared within %.0fs of connecting",
                    BLUETOOTH_SINK_TIMEOUT_S,
                )
                return False
            self._stop.wait(BLUETOOTH_SINK_POLL_S)

    def _set_output(self, command: Command) -> CommandResult:
        target = command.target or OutputTarget.SPEAKER
        if target is OutputTarget.HEADPHONES and self._connected_headset() is None:
            return CommandResult(
                command=command.name, ok=False, message="No headphones are connected."
            )
        ok, message = self._route_output(target)
        self._publish()
        return CommandResult(command=command.name, ok=ok, message=message)

    def _set_headset_mic(self, command: Command) -> CommandResult:
        enabled = bool(command.enabled)
        headset = self._connected_headset()
        if enabled and headset is None:
            return CommandResult(
                command=command.name, ok=False, message="No headphones are connected."
            )
        message = ""
        if headset is not None and self._headphones is not None:
            ok, message = self._headphones.use_headset_microphone(headset.address, enabled)
            if not ok:
                return CommandResult(command=command.name, ok=False, message=message)
        self._config.update(use_hfp_mic=enabled)
        # Switching a headset in or out of hands-free mode replaces its sink:
        # the A2DP node goes away and a hands-free one takes its place under a
        # different name. The relay resolved the old name when it started, so
        # unless it is restarted it goes on playing at a node that no longer
        # exists — which sounds exactly like the headphones falling silent a
        # second after the microphone was switched on.
        if self._output_target is OutputTarget.HEADPHONES:
            self._units.restart_user_unit(RELAY_UNIT)
        self._publish()
        return CommandResult(command=command.name, ok=True, message=message)

    def _wifi_scan(self) -> CommandResult:
        networks = self._radio.scan()
        if self._gatt is not None:
            self._gatt.publish_discovery("wifi", networks)
        return CommandResult(command=protocol.CMD_WIFI_SCAN, ok=True)

    def _bt_scan(self) -> CommandResult:
        if self._headphones is None:
            return CommandResult(
                command=protocol.CMD_BT_SCAN, ok=False, message="Bluetooth is not available."
            )
        found = [device.as_entry() for device in self._headphones.scan()]
        if self._gatt is not None:
            self._gatt.publish_discovery("bluetooth", found)
        return CommandResult(command=protocol.CMD_BT_SCAN, ok=True)

    def _bt_action(self, command: Command, action: str) -> CommandResult:
        if self._headphones is None:
            return CommandResult(
                command=command.name, ok=False, message="Bluetooth is not available."
            )
        ok, message = getattr(self._headphones, action)(command.address)
        if ok and action == "connect":
            # BlueZ has only just reported the connection, so the cache the
            # status path reads is still one step behind. Refreshing here is
            # what makes the headset's real name reach the app instead of the
            # word "Headphones".
            self._refresh_headset()
            routed, problem = self._route_output(OutputTarget.HEADPHONES)
            if not routed:
                ok, message = False, problem
        elif action in ("disconnect", "forget"):
            # Falling back to the speaker keeps the appliance audible instead of
            # silently routing laptop audio into a device that just left.
            self._refresh_headset()
            self._route_output(OutputTarget.SPEAKER)
        self._publish()
        return CommandResult(command=command.name, ok=ok, message=message)

    def _rename(self, command: Command) -> CommandResult:
        self._config.update(device_name=command.text)
        self._publish()
        return CommandResult(command=command.name, ok=True)

    def _update_now(self) -> CommandResult:
        """Ask the appliance to look for a new version right now.

        The same unit the daily timer runs, so there is one update path rather
        than two. It postpones itself while a recording is in progress, which is
        why this reports "started" rather than "done": the answer arrives through
        the status the app is already watching.
        """
        if self._machine.state is State.RECORDING:
            return CommandResult(
                command=protocol.CMD_UPDATE_NOW,
                ok=False,
                message="Not while a recording is running. It will update afterwards.",
            )
        if self._update_state != "idle":
            return CommandResult(
                command=protocol.CMD_UPDATE_NOW, ok=True, message="Already looking."
            )
        if not self._units.start(UPDATE_UNIT):
            return CommandResult(
                command=protocol.CMD_UPDATE_NOW,
                ok=False,
                message="Could not start the update.",
            )
        self._set_update_state("checking")
        # Without a watcher the state stayed at "checking" for the life of the
        # process: nothing ever set it back, so the app showed a spinner where
        # the button had been and "Check now" could never be pressed again.
        threading.Thread(target=self._watch_update, name="update-watch", daemon=True).start()
        return CommandResult(
            command=protocol.CMD_UPDATE_NOW, ok=True, message="Looking for a new version."
        )

    def _set_update_state(self, state: str) -> None:
        if self._update_state != state:
            self._update_state = state
            self._publish()

    def _watch_update(self) -> None:
        """Follow the updater to its end and report what happened.

        A successful update restarts this very service, so the common ending is
        that this thread is killed mid-wait — which is fine, because the process
        that comes back reports "idle" from a fresh start.
        """
        waited = 0.0
        while waited < UPDATE_WATCH_CEILING_S:
            if self._stop.wait(UPDATE_POLL_S):
                return
            waited += UPDATE_POLL_S
            if self._units.is_active(UPDATE_UNIT):
                self._set_update_state("installing")
                continue
            if self._units.failed(UPDATE_UNIT):
                self._error = "The update did not finish. It will try again tomorrow."
                self._set_update_state("failed")
            else:
                self._set_update_state("idle")
            return
        LOG.warning("the updater is still running after %.0fs", UPDATE_WATCH_CEILING_S)
        self._set_update_state("idle")

    def _set_auto_update(self, command: Command) -> CommandResult:
        enabled = bool(command.enabled)
        if not self._units.enable_timer(UPDATE_TIMER, enabled):
            return CommandResult(
                command=command.name, ok=False, message="Could not change automatic updates."
            )
        self._auto_update = enabled
        self._publish()
        return CommandResult(command=command.name, ok=True)

    def _selftest(self) -> CommandResult:
        """Run the acoustic self-test and publish its verdicts to the app.

        On a thread, because it plays a tone and listens for it — several seconds
        during which the control link must stay answerable. The results go out on
        the same channel as scan results rather than a characteristic of their
        own: one list mechanism, not two.
        """
        if self._machine.state is State.RECORDING:
            return CommandResult(
                command=protocol.CMD_SELFTEST,
                ok=False,
                message="Not while a recording is running.",
            )
        if self._selftest_running:
            return CommandResult(
                command=protocol.CMD_SELFTEST, ok=True, message="Already checking."
            )
        self._selftest_running = True
        threading.Thread(target=self._run_selftest, name="selftest", daemon=True).start()
        return CommandResult(command=protocol.CMD_SELFTEST, ok=True, message="Checking the sound…")

    def _run_selftest(self) -> None:
        entries: list[dict] = []
        try:
            from ..audio import selftest

            entries = [
                {"name": check.name, "ok": check.ok, "detail": check.detail}
                for check in selftest.run()
            ]
        except Exception as error:  # noqa: BLE001 - a check must always answer
            LOG.exception("the self-test failed to run")
            entries = [{"name": "self-test", "ok": False, "detail": str(error)[:120]}]
        finally:
            self._selftest_running = False
        if self._gatt is not None:
            try:
                self._gatt.publish_discovery("selftest", entries)
            except Exception:  # noqa: BLE001
                LOG.debug("could not publish the self-test result", exc_info=True)
        self._publish()

    def _forget_account(self) -> CommandResult:
        self.stop_recording()
        self._config.clear_account_binding()
        self._machine.unconfigured()
        self.enter_setup_mode()
        return CommandResult(command=protocol.CMD_FORGET_ACCOUNT, ok=True)

    # ------------------------------------------------------------ provisioning

    def handle_provisioning(self, provisioning: Provisioning) -> CommandResult:
        """Apply what the app sent over the encrypted link.

        Wi-Fi first, because everything after it needs a network. The password
        goes to NetworkManager and is never written into our own configuration —
        one copy of a secret is enough.
        """
        self._reconcile_configuration()
        if provisioning.wifi_ssid:
            self._radio.enable()
            joined, message = self._radio.join(provisioning.wifi_ssid, provisioning.wifi_password)
            if not joined:
                return CommandResult(command=protocol.CMD_SETUP, ok=False, message=message)

        changes = {
            "backend_url": provisioning.backend_url,
            "api_key": provisioning.api_key,
            "tls_verify": provisioning.tls_verify,
        }
        if provisioning.timezone:
            # Normalised on the way in, not on every upload. An abbreviation the
            # server cannot use is worth one line in the log, not one per chunk
            # for the life of the device.
            changes["timezone"] = iana_timezone(provisioning.timezone)
        if provisioning.device_name:
            changes["device_name"] = provisioning.device_name
        self._config.update(**changes)

        self._machine.configured()
        self.leave_setup_mode()
        self._error = ""
        self._pump.set_paused(False)
        self._pump.wake()
        self._tones.play(tones.READY)
        self._publish()
        return CommandResult(command=protocol.CMD_SETUP, ok=True)

    # -------------------------------------------------------- recorder factory

    def build_recorder(self, near, far) -> Recorder:
        """Construct a recorder bound to this appliance's ledger and settings."""
        return Recorder(
            ledger=self._ledger,
            config_store=self._config,
            near=near,
            far=far,
            timezone=self._config.get().timezone or "UTC",
            on_fault=self._note_fault,
            now=self._now,
        )

    def _note_fault(self, message: str) -> None:
        self._error = message
        self._tones.play(tones.ATTENTION)
        self._publish()

    def close_orphan_session(self) -> None:
        session = self._ledger.active_session()
        if session is not None:
            self._ledger.close_session(
                session.id,
                ended_at=self._now().isoformat(),
                status=SESSION_ENDED,
                final_sequence=self._ledger.next_sequence(session.id) - 1,
            )
