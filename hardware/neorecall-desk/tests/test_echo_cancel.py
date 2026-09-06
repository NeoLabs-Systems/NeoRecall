"""Tests for echo cancellation and the nodes the recorder opens by name.

The bug these are written against is not a crash. The drop-in configuration that
used to create ``neorecall.capture.near`` was removed after PipeWire turned out
to be ignoring it, and nothing replaced it — so the recorder was aiming
``pw-record`` at a node that did not exist, and every one of these tests would
have passed anyway if they only checked that the relay started *something*. They
check the node names instead.
"""

from __future__ import annotations

import pathlib

import pytest

from neorecall_desk.audio import echo_cancel, relay


def test_the_config_names_the_two_nodes_the_rest_of_the_appliance_expects():
    text = echo_cancel.config(microphone="alsa_input.wm8960", speaker="alsa_output.wm8960")

    # streams.py opens these by name. If either drifts, recording stops working
    # on hardware while every unit test still passes.
    assert f'node.name        = "{echo_cancel.NODE_NEAR}"' in text
    assert f'node.name        = "{echo_cancel.NODE_RELAY_OUT}"' in text


def test_the_node_names_match_the_ones_the_recorder_reads_from():
    from neorecall_desk.audio import streams

    assert echo_cancel.NODE_NEAR == streams.NODE_NEAR
    assert echo_cancel.NODE_RELAY_OUT == streams.NODE_RELAY_OUT

    # The far side has no published name to drift: the recorder resolves the
    # gadget's own capture node through the relay's endpoint discovery, so
    # there is one definition of "which node is the computer" and both sides
    # read it. The relay publishes nothing for it at all.
    assert not hasattr(relay, "NODE_FAR")
    assert streams.NODE_FAR == ""


def test_the_real_devices_are_the_canceller_ends_not_the_virtual_ones():
    text = echo_cancel.config(microphone="the-microphone", speaker="the-speaker")

    # The canceller captures from the real microphone and plays to the real
    # speaker; the virtual pair is what everything else talks to. Swapping these
    # produces a graph that runs and cancels nothing.
    assert 'target.object    = "the-microphone"' in text
    assert 'target.object    = "the-speaker"' in text


def test_automatic_gain_is_off_in_every_form():
    text = echo_cancel.config(microphone="m", speaker="s")

    for setting in (
        "webrtc.gain_control        = false",
        "webrtc.analog_gain_control = false",
        "webrtc.digital_gain_control = false",
    ):
        assert setting in text, setting


def test_the_webrtc_backend_is_requested_by_name():
    assert "aec/libspa-aec-webrtc" in echo_cancel.config(microphone="m", speaker="s")


def test_the_config_is_written_where_the_canceller_can_read_it(tmp_path):
    path = echo_cancel.write_config("hello", directory=str(tmp_path))

    assert path.read_text(encoding="utf-8") == "hello"
    assert echo_cancel.command(path) == ["pipewire", "-c", str(path)]


def _plugin_tree(root: pathlib.Path) -> pathlib.Path:
    """The layout Debian actually ships, reproduced exactly.

    The path has an ``aec/`` directory in it. A pattern that omits that level
    matches nothing on a machine that has the canceller, and the appliance then
    relays without cancellation while reporting only a log line.
    """
    directory = root / "aarch64-linux-gnu" / "spa-0.2" / "aec"
    directory.mkdir(parents=True)
    (directory / "libspa-aec-webrtc.so").write_bytes(b"")
    return root


def test_a_backend_that_is_there_is_found(tmp_path, monkeypatch):
    monkeypatch.setattr(echo_cancel.shutil, "which", lambda name: "/usr/bin/pipewire")

    assert echo_cancel.is_available(search_roots=(str(_plugin_tree(tmp_path)),)) is True


def test_a_missing_backend_is_detected_rather_than_assumed(tmp_path, monkeypatch):
    monkeypatch.setattr(echo_cancel.shutil, "which", lambda name: "/usr/bin/pipewire")

    # A module that loads without a backend cancels nothing while looking
    # perfectly healthy, so absence has to be noticed before the graph is built.
    assert echo_cancel.is_available(search_roots=(str(tmp_path),)) is False


def test_pipewire_itself_missing_means_no_canceller(tmp_path, monkeypatch):
    monkeypatch.setattr(echo_cancel.shutil, "which", lambda name: None)

    assert echo_cancel.is_available(search_roots=(str(_plugin_tree(tmp_path)),)) is False


@pytest.fixture()
def endpoints() -> dict[str, str]:
    return {
        "speaker": "alsa_output.wm8960",
        "microphone": "alsa_input.wm8960",
        "from_computer": "alsa_input.usb_gadget",
        "to_computer": "alsa_output.usb_gadget",
    }


class _Recorder:
    """Collects the commands the relay would run instead of running them."""

    def __init__(self) -> None:
        self.commands: list[list[str]] = []

    def __call__(self, command, *args, **kwargs):
        self.commands.append(list(command))

        class _Process:
            returncode = None

            def poll(self):
                return None

            def terminate(self):
                return None

        return _Process()


def test_the_far_side_is_published_as_something_recordable(endpoints, monkeypatch):
    started = _Recorder()
    monkeypatch.setattr(relay.subprocess, "Popen", started)
    monkeypatch.setattr(relay.echo_cancel, "is_available", lambda: True)
    monkeypatch.setattr(relay, "_wait_for_nodes", lambda names, timeout: True)
    monkeypatch.setattr(
        relay.echo_cancel, "write_config", lambda text, directory=None: pathlib.Path("/tmp/x.conf")
    )

    processes: list = []
    near, speakers = relay._start_echo_canceller(endpoints, processes, endpoints["speaker"])
    assert (near, speakers) == (echo_cancel.NODE_NEAR, echo_cancel.NODE_RELAY_OUT)

    far = relay.loopback_command(
        capture=endpoints["from_computer"], name="neorecall.capture.far", publish_as_source=True
    )
    # A sink would let us play the laptop's audio. The recorder needs to listen
    # to it, which is what makes the virtual media class load-bearing.
    assert "media.class=Audio/Source/Virtual" in " ".join(far)
    assert "--playback" not in far


def test_the_laptop_is_played_into_the_canceller_so_it_has_a_reference(endpoints, monkeypatch):
    started = _Recorder()
    monkeypatch.setattr(relay.subprocess, "Popen", started)
    monkeypatch.setattr(relay.echo_cancel, "is_available", lambda: True)
    monkeypatch.setattr(relay, "_wait_for_nodes", lambda names, timeout: True)
    monkeypatch.setattr(
        relay.echo_cancel, "write_config", lambda text, directory=None: pathlib.Path("/tmp/x.conf")
    )

    _, speakers = relay._start_echo_canceller(endpoints, [], endpoints["speaker"])

    # Playing straight at the card would work acoustically and leave the
    # canceller with nothing to subtract.
    assert speakers == echo_cancel.NODE_RELAY_OUT
    assert speakers != endpoints["speaker"]


def test_without_a_backend_the_near_node_still_exists(endpoints, monkeypatch):
    started = _Recorder()
    monkeypatch.setattr(relay.subprocess, "Popen", started)
    monkeypatch.setattr(relay.echo_cancel, "is_available", lambda: False)

    processes: list = []
    near, speakers = relay._start_echo_canceller(endpoints, processes, endpoints["speaker"])

    # Degrade, do not refuse: the appliance records the echo too, but it records.
    assert near == echo_cancel.NODE_NEAR
    assert speakers == endpoints["speaker"]
    published = " ".join(started.commands[0])
    assert f"node.name={echo_cancel.NODE_NEAR}" in published
    assert "media.class=Audio/Source/Virtual" in published


def test_a_canceller_that_never_publishes_is_not_waited_on_forever(endpoints, monkeypatch):
    monkeypatch.setattr(relay.subprocess, "Popen", _Recorder())
    monkeypatch.setattr(relay.echo_cancel, "is_available", lambda: True)
    monkeypatch.setattr(relay, "_wait_for_nodes", lambda names, timeout: False)
    monkeypatch.setattr(
        relay.echo_cancel, "write_config", lambda text, directory=None: pathlib.Path("/tmp/x.conf")
    )

    near, speakers = relay._start_echo_canceller(endpoints, [], endpoints["speaker"])

    assert near == echo_cancel.NODE_NEAR
    assert speakers == endpoints["speaker"]
