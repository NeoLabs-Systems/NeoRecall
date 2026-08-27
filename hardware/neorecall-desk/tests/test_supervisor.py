"""What the appliance decides, with the hardware replaced by stand-ins."""

import pytest

from neorecall_desk.config import ConfigStore
from neorecall_desk.control import protocol
from neorecall_desk.control import tones as T
from neorecall_desk.control.button import ButtonEvent
from neorecall_desk.control.supervisor import RELAY_UNIT, UPDATE_UNIT, Supervisor
from neorecall_desk.ingest.pump import PumpStatus
from neorecall_desk.state import MicSource, OutputTarget, State


class FakeRadio:
    def __init__(self, online=True):
        self.enabled = True
        self._online = online
        self.joined = None
        self.join_result = (True, "")
        self.networks = [{"ssid": "Kitchen", "signal": 71, "secured": True}]

    def available(self):
        return True

    def enable(self):
        self.enabled = True
        return True

    def disable(self):
        self.enabled = False
        return True

    def online(self):
        return self._online and self.enabled

    def scan(self):
        return self.networks

    def join(self, ssid, password):
        self.joined = (ssid, password)
        return self.join_result


class FakePump:
    def __init__(self):
        self.status = PumpStatus()
        self.paused = False
        self.wakes = 0

    def set_paused(self, paused):
        self.paused = paused

    def wake(self):
        self.wakes += 1


class FakeTones:
    def __init__(self):
        self.played = []

    def play(self, steps):
        name = {
            id(T.RECORDING_STARTED): "started",
            id(T.RECORDING_STOPPED): "stopped",
            id(T.SETUP_MODE): "setup",
            id(T.REFUSED): "refused",
            id(T.READY): "ready",
            id(T.ATTENTION): "attention",
        }.get(id(steps), "other")
        self.played.append(name)


def _ticking_clock(step: float = 3600.0):
    """A monotonic clock that jumps a long way every time it is read."""
    reading = [0.0]

    def now() -> float:
        reading[0] += step
        return reading[0]

    return now


class FakeGraph:
    def __init__(self, speaker=True, bluetooth=True):
        self.speaker = speaker
        self.bluetooth = bluetooth
        self.routed = []

    def use_speaker(self):
        self.routed.append("speaker")
        return self.speaker

    def use_bluetooth(self):
        self.routed.append("bluetooth")
        return self.bluetooth

    def bluetooth_available(self):
        # The sink exists exactly when routing to it would succeed. A test that
        # wants the "connected but not published yet" gap sets this to False.
        return self.bluetooth


class FakeGatt:
    def __init__(self):
        self.published = 0
        self.setup_mode = False
        self.discoveries = []

    def publish_status(self):
        self.published += 1

    def publish_discovery(self, kind, entries):
        self.discoveries.append((kind, entries))

    def set_setup_mode(self, enabled):
        self.setup_mode = enabled


class FakeHeadphone:
    def __init__(
        self, address="AA:BB:CC:DD:EE:FF", name="Sony WH-1000XM5", connected=True, battery=72
    ):
        self.address = address
        self.name = name
        self.connected = connected
        self.battery = battery
        self.paired = True

    def as_entry(self):
        return {"address": self.address, "name": self.name, "connected": self.connected}


class FakeHeadphones:
    def __init__(self, devices=None):
        self._devices = devices if devices is not None else []
        self.mic_result = (
            True,
            "Using the headset microphone. Sound quality drops a little while recording.",
        )
        self.actions = []

    def known(self):
        return self._devices

    def scan(self):
        return self._devices

    def connect(self, address):
        self.actions.append(("connect", address))
        for device in self._devices:
            device.connected = device.address == address
        return True, ""

    def disconnect(self, address):
        self.actions.append(("disconnect", address))
        for device in self._devices:
            if device.address == address:
                device.connected = False
        return True, ""

    def forget(self, address):
        self.actions.append(("forget", address))
        self._devices = [d for d in self._devices if d.address != address]
        return True, ""

    def use_headset_microphone(self, address, enabled):
        self.actions.append(("mic", address, enabled))
        return self.mic_result


class FakeRecorder:
    def __init__(self):
        self.elapsed_ms = 0
        self.fault = None
        self.ran = False
        self.stopped = False
        self._release = None

    def run(self):
        import threading

        self.ran = True
        self._release = threading.Event()
        self._release.wait(5)

    def request_stop(self):
        self.stopped = True
        if self._release is not None:
            self._release.set()


@pytest.fixture()
def rig(ledger, state_dir):
    config = ConfigStore()
    config.update(backend_url="https://recall.example.com", api_key="nrk_test")
    radio = FakeRadio()
    pump = FakePump()
    gatt = FakeGatt()
    toneplayer = FakeTones()
    headphones = FakeHeadphones()
    audio_graph = FakeGraph()
    recorders = []

    def factory():
        recorder = FakeRecorder()
        recorders.append(recorder)
        return recorder

    supervisor = Supervisor(
        ledger=ledger,
        config_store=config,
        pump=pump,
        firmware="0.1.0",
        recorder_factory=factory,
        gatt=gatt,
        headphones=headphones,
        toneplayer=toneplayer,
        radio_module=radio,
        audio_graph=audio_graph,
        # A clock that always reads "later". Waiting for a Bluetooth sink is
        # real behaviour on the device and dead time in a test, so the timeout
        # expires on its first look rather than six seconds in.
        monotonic=_ticking_clock(),
    )
    # No test should reach the real systemctl: switching the output restarts the
    # relay unit, and on a developer machine that call can only fail.
    units = FakeUnits()
    supervisor._units = units
    return {
        "supervisor": supervisor,
        "units": units,
        "graph": audio_graph,
        "config": config,
        "radio": radio,
        "pump": pump,
        "gatt": gatt,
        "tones": toneplayer,
        "headphones": headphones,
        "recorders": recorders,
    }


# ----------------------------------------------------------------- radio policy


def test_recording_silences_the_wifi_radio_and_pauses_uploading(rig):
    supervisor, radio, pump = rig["supervisor"], rig["radio"], rig["pump"]

    supervisor.start_recording()

    assert supervisor.state is State.RECORDING
    assert not radio.enabled, "Bluetooth audio needs the antenna to itself while recording"
    assert pump.paused, "retrying against a radio we switched off would only build backoff"


def test_stopping_brings_the_radio_back_and_drains_the_queue(rig):
    supervisor, radio, pump = rig["supervisor"], rig["radio"], rig["pump"]
    supervisor.start_recording()

    supervisor.stop_recording()

    assert supervisor.state is State.IDLE
    assert radio.enabled
    assert not pump.paused
    assert pump.wakes >= 1


# --------------------------------------------------------------------- button


def test_the_button_starts_and_stops_a_recording(rig):
    supervisor = rig["supervisor"]

    supervisor.on_button(ButtonEvent.SHORT_PRESS)
    assert supervisor.state is State.RECORDING

    supervisor.on_button(ButtonEvent.SHORT_PRESS)
    assert supervisor.state is State.IDLE


def test_holding_the_button_opens_setup_without_touching_the_recording(rig):
    supervisor, gatt = rig["supervisor"], rig["gatt"]
    supervisor.start_recording()

    supervisor.on_button(ButtonEvent.LONG_PRESS)

    assert gatt.setup_mode
    assert supervisor.state is State.RECORDING, "opening setup must not drop a recording"


def test_each_transition_is_confirmed_by_a_sound(rig):
    supervisor, toneplayer = rig["supervisor"], rig["tones"]

    supervisor.start_recording()
    supervisor.stop_recording()

    assert toneplayer.played == ["started", "stopped"]


def test_an_unconfigured_device_refuses_to_record_and_says_so(ledger, state_dir):
    config = ConfigStore()
    toneplayer = FakeTones()
    supervisor = Supervisor(
        ledger=ledger,
        config_store=config,
        pump=FakePump(),
        firmware="0.1.0",
        recorder_factory=FakeRecorder,
        toneplayer=toneplayer,
        radio_module=FakeRadio(),
        audio_graph=FakeGraph(),
    )

    result = supervisor.on_button(ButtonEvent.SHORT_PRESS)

    assert supervisor.state is State.UNCONFIGURED
    assert toneplayer.played == ["refused"]
    assert result is None


# ------------------------------------------------------------------- snapshot


def test_the_snapshot_describes_the_device_in_plain_language(rig):
    supervisor, headphones = rig["supervisor"], rig["headphones"]
    headphones._devices = [FakeHeadphone()]
    supervisor.handle_command(
        protocol.Command(name=protocol.CMD_SET_OUTPUT, target=OutputTarget.HEADPHONES)
    )

    snapshot = supervisor.snapshot()

    assert snapshot.output_target is OutputTarget.HEADPHONES
    assert snapshot.output_name == "Sony WH-1000XM5"
    assert snapshot.headset_connected
    assert snapshot.headset_battery == 72
    assert snapshot.mic_source is MicSource.BUILT_IN, "the headset microphone is opt-in"


def test_a_queue_with_no_network_reads_as_a_sentence_not_a_code(rig):
    supervisor, pump, radio = rig["supervisor"], rig["pump"], rig["radio"]
    pump.status = PumpStatus(pending_chunks=12)
    radio._online = False

    assert supervisor.snapshot().error == "No network yet — 12 recordings are waiting."


def test_a_lost_account_tells_the_user_what_to_do(rig):
    supervisor, pump = rig["supervisor"], rig["pump"]
    pump.status = PumpStatus(authentication_failed=True)

    assert "Set it up again" in supervisor.snapshot().error


# ------------------------------------------------------------------- commands


def test_an_unknown_command_is_answered_rather_than_dropped(rig):
    result = rig["supervisor"].handle_command(protocol.Command(name="fly"))

    assert not result.ok
    assert "does not understand" in result.message


def test_choosing_headphones_that_are_not_there_is_refused_clearly(rig):
    result = rig["supervisor"].handle_command(
        protocol.Command(name=protocol.CMD_SET_OUTPUT, target=OutputTarget.HEADPHONES)
    )

    assert not result.ok
    assert result.message == "No headphones are connected."


def test_turning_on_the_headset_microphone_passes_the_warning_through(rig):
    supervisor, headphones = rig["supervisor"], rig["headphones"]
    headphones._devices = [FakeHeadphone()]

    result = supervisor.handle_command(
        protocol.Command(name=protocol.CMD_SET_HEADSET_MIC, enabled=True)
    )

    assert result.ok
    assert "quality drops" in result.message
    assert rig["config"].get().use_hfp_mic
    assert supervisor.snapshot().mic_source is MicSource.HEADSET


def test_a_headset_without_a_microphone_leaves_the_setting_alone(rig):
    supervisor, headphones = rig["supervisor"], rig["headphones"]
    headphones._devices = [FakeHeadphone()]
    headphones.mic_result = (
        False,
        "These headphones do not offer a microphone the appliance can use.",
    )

    result = supervisor.handle_command(
        protocol.Command(name=protocol.CMD_SET_HEADSET_MIC, enabled=True)
    )

    assert not result.ok
    assert not rig["config"].get().use_hfp_mic


def test_scanning_publishes_what_it_found_to_the_app(rig):
    supervisor, gatt = rig["supervisor"], rig["gatt"]
    rig["headphones"]._devices = [FakeHeadphone()]

    supervisor.handle_command(protocol.Command(name=protocol.CMD_WIFI_SCAN))
    supervisor.handle_command(protocol.Command(name=protocol.CMD_BT_SCAN))

    kinds = [kind for kind, _ in gatt.discoveries]
    assert kinds == ["wifi", "bluetooth"]
    assert gatt.discoveries[0][1][0]["ssid"] == "Kitchen"


def test_an_output_the_graph_cannot_reach_is_refused_rather_than_faked(rig):
    supervisor, headphones = rig["supervisor"], rig["headphones"]
    headphones._devices = [FakeHeadphone()]
    rig["graph"].bluetooth = False

    result = supervisor.handle_command(
        protocol.Command(name=protocol.CMD_SET_OUTPUT, target=OutputTarget.HEADPHONES)
    )

    assert not result.ok
    assert supervisor.snapshot().output_target is OutputTarget.SPEAKER


def test_connecting_headphones_makes_them_the_output(rig):
    supervisor, headphones = rig["supervisor"], rig["headphones"]
    headphones._devices = [FakeHeadphone(connected=False)]

    result = supervisor.handle_command(
        protocol.Command(name=protocol.CMD_BT_CONNECT, address="AA:BB:CC:DD:EE:FF")
    )

    assert result.ok
    assert supervisor.snapshot().output_target is OutputTarget.HEADPHONES


def test_forgetting_headphones_falls_back_to_the_speaker(rig):
    supervisor, headphones = rig["supervisor"], rig["headphones"]
    headphones._devices = [FakeHeadphone()]
    supervisor.handle_command(
        protocol.Command(name=protocol.CMD_BT_CONNECT, address="AA:BB:CC:DD:EE:FF")
    )

    supervisor.handle_command(
        protocol.Command(name=protocol.CMD_BT_FORGET, address="AA:BB:CC:DD:EE:FF")
    )

    assert supervisor.snapshot().output_target is OutputTarget.SPEAKER


def test_removing_the_account_stops_recording_and_reopens_setup(rig):
    supervisor, gatt, config = rig["supervisor"], rig["gatt"], rig["config"]
    supervisor.start_recording()

    supervisor.handle_command(protocol.Command(name=protocol.CMD_FORGET_ACCOUNT))

    assert supervisor.state is State.UNCONFIGURED
    assert gatt.setup_mode
    assert not config.get().configured
    # The hardware keeps its identity, so setting it up again updates the same
    # device on the server instead of creating a second one.
    assert config.get().client_uuid


# --------------------------------------------------------------- provisioning


def test_setup_joins_the_network_then_stores_the_account(rig):
    supervisor, radio, config = rig["supervisor"], rig["radio"], rig["config"]
    config.clear_account_binding()

    result = supervisor.handle_provisioning(
        protocol.Provisioning(
            backend_url="https://recall.example.com",
            api_key="nrk_new_key",
            wifi_ssid="Kitchen",
            wifi_password="hunter2hunter2",
            timezone="Europe/Berlin",
            device_name="Desk in the study",
        )
    )

    assert result.ok
    assert radio.joined == ("Kitchen", "hunter2hunter2")
    stored = config.get()
    assert stored.backend_url == "https://recall.example.com"
    assert stored.api_key == "nrk_new_key"
    assert stored.device_name == "Desk in the study"
    assert supervisor.state is State.IDLE


def test_a_wrong_wifi_password_stops_setup_before_anything_is_stored(rig):
    supervisor, radio, config = rig["supervisor"], rig["radio"], rig["config"]
    config.clear_account_binding()
    radio.join_result = (False, "That password was not accepted.")

    result = supervisor.handle_provisioning(
        protocol.Provisioning(
            backend_url="https://recall.example.com",
            api_key="nrk_new_key",
            wifi_ssid="Kitchen",
            wifi_password="wrong",
        )
    )

    assert not result.ok
    assert result.message == "That password was not accepted."
    assert not config.get().configured, "a half-finished setup must not look finished"
    assert supervisor.state is State.UNCONFIGURED


def test_the_wifi_password_is_never_written_into_our_own_configuration(rig):
    import json

    from neorecall_desk import paths

    supervisor, config = rig["supervisor"], rig["config"]
    config.clear_account_binding()
    supervisor.handle_provisioning(
        protocol.Provisioning(
            backend_url="https://recall.example.com",
            api_key="nrk_new_key",
            wifi_ssid="Kitchen",
            wifi_password="hunter2hunter2",
        )
    )

    stored = json.loads(paths.config_file().read_text())
    assert "hunter2hunter2" not in json.dumps(stored)


def test_setup_leaves_pairing_mode_so_a_stranger_cannot_walk_in(rig):
    supervisor, gatt, config = rig["supervisor"], rig["gatt"], rig["config"]
    config.clear_account_binding()
    supervisor.enter_setup_mode()
    assert gatt.setup_mode

    supervisor.handle_provisioning(
        protocol.Provisioning(backend_url="https://recall.example.com", api_key="nrk_new_key")
    )

    assert not gatt.setup_mode


class FakeUnits:
    def __init__(self, ok=True):
        self.ok = ok
        self.started = []
        self.restarted = []
        self.timers = []
        self.auto_update_enabled = True
        # What `systemctl is-active` / `is-failed` would say about the updater.
        self.update_running = False
        self.update_failed = False

    def start(self, unit):
        self.started.append(unit)
        return self.ok

    def restart_user_unit(self, unit):
        self.restarted.append(unit)
        return self.ok

    def enable_timer(self, unit, enabled):
        self.timers.append((unit, enabled))
        return self.ok

    def is_enabled(self, unit):
        return self.auto_update_enabled

    def is_active(self, unit):
        return self.update_running

    def failed(self, unit):
        return self.update_failed


def with_units(rig, units):
    rig["supervisor"]._units = units
    return rig["supervisor"]


def test_an_update_can_be_asked_for_from_the_app(rig):
    units = FakeUnits()
    supervisor = with_units(rig, units)

    result = supervisor.handle_command(protocol.Command(name=protocol.CMD_UPDATE_NOW))

    assert result.ok
    assert units.started == ["neorecall-desk-update.service"]
    assert supervisor.snapshot().update_state == "checking"


def test_an_update_is_refused_while_recording_rather_than_queued_silently(rig):
    units = FakeUnits()
    supervisor = with_units(rig, units)
    supervisor.start_recording()

    result = supervisor.handle_command(protocol.Command(name=protocol.CMD_UPDATE_NOW))

    # Cutting a conversation in half for a version bump is never the right
    # trade, and the app should say so rather than appear to do nothing.
    assert not result.ok
    assert "Not while a recording" in result.message
    assert units.started == []


def test_a_failed_start_is_reported_rather_than_claimed(rig):
    supervisor = with_units(rig, FakeUnits(ok=False))

    result = supervisor.handle_command(protocol.Command(name=protocol.CMD_UPDATE_NOW))

    assert not result.ok
    assert supervisor.snapshot().update_state == "idle"


def test_automatic_updates_can_be_turned_off_and_on(rig):
    units = FakeUnits()
    supervisor = with_units(rig, units)

    supervisor.handle_command(protocol.Command(name=protocol.CMD_SET_AUTO_UPDATE, enabled=False))
    assert units.timers[-1] == ("neorecall-desk-update.timer", False)
    assert supervisor.snapshot().auto_update is False

    supervisor.handle_command(protocol.Command(name=protocol.CMD_SET_AUTO_UPDATE, enabled=True))
    assert units.timers[-1] == ("neorecall-desk-update.timer", True)
    assert supervisor.snapshot().auto_update is True


def test_a_timer_that_refuses_to_change_leaves_the_setting_alone(rig):
    supervisor = with_units(rig, FakeUnits(ok=False))

    result = supervisor.handle_command(
        protocol.Command(name=protocol.CMD_SET_AUTO_UPDATE, enabled=False)
    )

    assert not result.ok
    assert supervisor.snapshot().auto_update is True


def test_choosing_headphones_actually_moves_the_sound(rig):
    """Reported from the sofa: "when i select headphones it still plays via speaker".

    Setting the default sink is not enough. The relay plays into a *named*
    target, so it keeps using the speakers no matter what the default says —
    the choice was recorded, the app showed headphones, and the box carried on
    playing out loud. The relay has to be restarted so it picks the new target.
    """
    supervisor, headphones = rig["supervisor"], rig["headphones"]
    headphones._devices = [FakeHeadphone()]

    result = supervisor.handle_command(
        protocol.Command(name=protocol.CMD_SET_OUTPUT, target=OutputTarget.HEADPHONES)
    )

    assert result.ok
    assert rig["config"].get().output_target == "headphones"
    assert "neorecall-desk-relay.service" in rig["units"].restarted


def test_the_sound_stays_put_when_the_relay_will_not_move(rig):
    supervisor, headphones = rig["supervisor"], rig["headphones"]
    headphones._devices = [FakeHeadphone()]
    rig["units"].ok = False

    result = supervisor.handle_command(
        protocol.Command(name=protocol.CMD_SET_OUTPUT, target=OutputTarget.HEADPHONES)
    )

    # Saying "done" while the sound is still coming out of the box is worse than
    # saying it did not work.
    assert not result.ok
    assert supervisor.snapshot().output_target is OutputTarget.SPEAKER


def test_a_timezone_the_server_cannot_use_is_fixed_on_the_way_in(rig):
    """Otherwise every upload logs the same complaint for the life of the device.

    The app once sent "CEST"; the fallback kept recordings flowing, but the
    unusable value stayed in the config and was re-read on every chunk.
    """
    supervisor = rig["supervisor"]

    supervisor.handle_provisioning(
        protocol.Provisioning(
            backend_url="https://recall.example.com",
            api_key="nrk_test",
            timezone="CEST",
        )
    )

    assert rig["config"].get().timezone == "UTC"


def test_a_device_already_carrying_a_bad_timezone_repairs_itself(rig):
    """The fix at setup time does nothing for devices already in the field."""
    supervisor, config = rig["supervisor"], rig["config"]
    config.update(timezone="CEST")

    supervisor._reconcile_configuration()

    assert config.get().timezone == "UTC"


# --------------------------------------------------------------- output routing


def test_connecting_headphones_actually_moves_the_sound(rig):
    """The bug behind "I heard sound for a moment and then nothing".

    Connecting a headset used to set the status to Headphones and move the
    default sink, but never restart the relay — and the relay plays at a node
    name it resolved when it started, so the audio kept going to the speaker.
    Worse, the app then showed headphones as already selected, so the one
    control that would have fixed it could no longer be triggered.
    """
    supervisor = rig["supervisor"]
    units = rig["units"]
    rig["headphones"]._devices = [FakeHeadphone(name="Sony WH-1000XM5")]

    result = supervisor.handle_command(
        protocol.Command(name=protocol.CMD_BT_CONNECT, address="AA:BB:CC:DD:EE:FF")
    )

    assert result.ok
    assert units.restarted == [RELAY_UNIT]
    snapshot = supervisor.snapshot()
    assert snapshot.output_target is OutputTarget.HEADPHONES
    # The headset's real name, which means the cache was refreshed after the
    # connect rather than read from before it.
    assert snapshot.output_name == "Sony WH-1000XM5"
    assert rig["config"].get().output_target == "headphones"


def test_a_connect_that_cannot_be_routed_does_not_claim_to_have_worked(rig):
    supervisor = rig["supervisor"]
    rig["headphones"]._devices = [FakeHeadphone(name="Buds")]
    supervisor._units = FakeUnits(ok=False)

    result = supervisor.handle_command(
        protocol.Command(name=protocol.CMD_BT_CONNECT, address="AA:BB:CC:DD:EE:FF")
    )

    assert not result.ok
    assert result.message


def test_disconnecting_headphones_puts_the_sound_back_on_the_speaker(rig):
    supervisor = rig["supervisor"]
    units = rig["units"]

    supervisor.handle_command(
        protocol.Command(name=protocol.CMD_BT_DISCONNECT, address="AA:BB:CC:DD:EE:FF")
    )

    assert units.restarted == [RELAY_UNIT]
    assert supervisor.snapshot().output_target is OutputTarget.SPEAKER
    assert rig["config"].get().output_target == "speaker"


def test_switching_to_the_headset_microphone_rebuilds_the_relay(rig):
    """Hands-free mode replaces the headset's sink, so the relay has to re-look.

    Without this the relay went on playing at the A2DP node that the profile
    switch had just removed — the headphones fell silent a second after the
    microphone was turned on.
    """
    supervisor = rig["supervisor"]
    rig["headphones"]._devices = [FakeHeadphone(name="Buds")]
    supervisor.handle_command(
        protocol.Command(name=protocol.CMD_BT_CONNECT, address="AA:BB:CC:DD:EE:FF")
    )
    rig["units"].restarted.clear()

    supervisor.handle_command(protocol.Command(name=protocol.CMD_SET_HEADSET_MIC, enabled=True))

    assert rig["units"].restarted == [RELAY_UNIT]


def test_the_headset_microphone_does_not_rebuild_the_relay_on_the_speaker(rig):
    """Nothing about the output changed, so nothing about it should be restarted."""
    supervisor = rig["supervisor"]
    rig["headphones"]._devices = [FakeHeadphone(name="Buds")]
    supervisor._refresh_headset()

    supervisor.handle_command(protocol.Command(name=protocol.CMD_SET_HEADSET_MIC, enabled=True))

    assert rig["units"].restarted == []


# ---------------------------------------------------------------------- updates


def test_the_update_state_returns_to_idle_when_the_updater_finishes(rig):
    """Otherwise the app shows a spinner where the button was, for good.

    Nothing ever cleared "checking", so one press of Check now disabled the
    control for the life of the process.
    """
    supervisor = rig["supervisor"]
    units = rig["units"]
    units.update_running = False

    supervisor.handle_command(protocol.Command(name=protocol.CMD_UPDATE_NOW))
    assert supervisor.snapshot().update_state == "checking"

    supervisor._watch_update()

    assert supervisor.snapshot().update_state == "idle"


def test_an_update_that_fails_says_so_rather_than_going_quiet(rig):
    supervisor = rig["supervisor"]
    units = rig["units"]
    units.update_failed = True

    supervisor.handle_command(protocol.Command(name=protocol.CMD_UPDATE_NOW))
    supervisor._watch_update()

    snapshot = supervisor.snapshot()
    assert snapshot.update_state == "failed"
    assert "did not finish" in snapshot.error


def test_a_second_check_while_one_is_running_is_not_started_twice(rig):
    supervisor = rig["supervisor"]
    units = rig["units"]

    supervisor.handle_command(protocol.Command(name=protocol.CMD_UPDATE_NOW))
    result = supervisor.handle_command(protocol.Command(name=protocol.CMD_UPDATE_NOW))

    assert result.ok
    assert units.started == [UPDATE_UNIT]


def test_the_auto_update_switch_reports_what_systemd_actually_says(rig):
    """It defaulted to on and was only ever changed by the app.

    An appliance whose timer was disabled showed the switch as on until somebody
    toggled it twice.
    """
    supervisor = rig["supervisor"]
    rig["units"].auto_update_enabled = False

    supervisor.start()
    try:
        assert supervisor.snapshot().auto_update is False
    finally:
        supervisor.stop()


def test_headphones_are_waited_for_rather_than_refused_the_instant_they_connect(rig):
    """BlueZ says "connected" before PipeWire has a sink for it.

    Routing in that gap found no Bluetooth sink and failed, so connecting a
    headset reported an error about a headset that was connected and a moment
    away from working.
    """
    supervisor = rig["supervisor"]
    graph = rig["graph"]
    rig["headphones"]._devices = [FakeHeadphone(name="Buds")]

    # Absent on the first look, published on the second.
    looks = {"count": 0}

    def appears_shortly():
        looks["count"] += 1
        return looks["count"] > 1

    graph.bluetooth_available = appears_shortly
    supervisor._monotonic = _ticking_clock(step=1.0)

    result = supervisor.handle_command(
        protocol.Command(name=protocol.CMD_BT_CONNECT, address="AA:BB:CC:DD:EE:FF")
    )

    assert result.ok
    assert looks["count"] == 2
    assert supervisor.snapshot().output_target is OutputTarget.HEADPHONES


def test_a_headset_whose_sink_never_appears_is_reported_not_hidden(rig):
    supervisor = rig["supervisor"]
    rig["headphones"]._devices = [FakeHeadphone(name="Buds")]
    rig["graph"].bluetooth_available = lambda: False

    result = supervisor.handle_command(
        protocol.Command(name=protocol.CMD_BT_CONNECT, address="AA:BB:CC:DD:EE:FF")
    )

    assert not result.ok
    assert result.message
