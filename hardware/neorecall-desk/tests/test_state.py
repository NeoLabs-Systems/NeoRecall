"""The three transitions, and the one refusal that matters."""

import pytest

from neorecall_desk.state import (
    MicSource,
    OutputTarget,
    Snapshot,
    State,
    StateMachine,
    TransitionRefused,
)


def test_a_fresh_appliance_starts_unconfigured():
    assert StateMachine().state is State.UNCONFIGURED


def test_setting_up_makes_it_ready():
    machine = StateMachine()
    assert machine.configured() is State.IDLE


def test_recording_is_refused_until_the_device_has_an_account():
    # Recording with nowhere to send it would silently fill the card with audio
    # nobody can collect, and the device has no screen to say so.
    with pytest.raises(TransitionRefused):
        StateMachine().start()


def test_the_button_toggles_between_ready_and_recording():
    machine = StateMachine(configured=True)

    assert machine.toggle() is State.RECORDING
    assert machine.toggle() is State.IDLE


def test_starting_twice_is_not_an_error():
    machine = StateMachine(configured=True)
    machine.start()
    assert machine.start() is State.RECORDING


def test_stopping_when_idle_is_not_an_error():
    machine = StateMachine(configured=True)
    assert machine.stop() is State.IDLE


def test_removing_the_account_stops_a_running_recording():
    machine = StateMachine(configured=True)
    machine.start()

    assert machine.unconfigured() is State.UNCONFIGURED


def test_listeners_see_every_real_transition_and_no_others():
    machine = StateMachine(configured=True)
    seen = []
    machine.on_change(lambda before, after: seen.append((before, after)))

    machine.start()
    machine.start()  # already recording: not a transition
    machine.stop()

    assert seen == [(State.IDLE, State.RECORDING), (State.RECORDING, State.IDLE)]


def test_a_snapshot_reports_syncing_only_when_it_can_actually_sync():
    queued = Snapshot(state=State.IDLE, pending_chunks=4, network_online=False)
    assert not queued.syncing

    draining = Snapshot(state=State.IDLE, pending_chunks=4, network_online=True)
    assert draining.syncing

    recording = Snapshot(state=State.RECORDING, pending_chunks=4, network_online=True)
    assert not recording.syncing
    assert recording.recording


def test_snapshot_defaults_describe_a_box_nobody_has_touched():
    snapshot = Snapshot()
    assert snapshot.state is State.UNCONFIGURED
    assert snapshot.output_target is OutputTarget.SPEAKER
    assert snapshot.mic_source is MicSource.BUILT_IN
    assert not snapshot.recording
