"""Finding the four audio endpoints among everything else PipeWire publishes.

The relay used to be a PipeWire configuration file. On hardware it silently did
nothing — right place, right modules, no error, no nodes — so it became a process
that discovers the endpoints itself. These tests cover the discovery, because
"which node is the microphone" is the part that a kernel rename or a new HAT
revision will break, and it is the part that can be checked without a Pi.
"""

import time

import pytest

from neorecall_desk.audio import relay


def node(name, media_class, description="", card=""):
    return {
        "id": abs(hash(name)) % 1000,
        "name": name,
        "description": description,
        "media_class": media_class,
        "card": card,
    }


REAL_GRAPH = [
    node(
        "alsa_output.platform-soc_sound.stereo-fallback",
        "Audio/Sink",
        "Built-in Audio Stereo",
        "wm8960-soundcard",
    ),
    node(
        "alsa_input.platform-soc_sound.stereo-fallback",
        "Audio/Source",
        "Built-in Audio Stereo",
        "wm8960-soundcard",
    ),
    node(
        "alsa_output.platform-fe980000_usb.stereo-fallback",
        "Audio/Sink",
        "Built-in Audio Stereo",
        "UAC2_Gadget",
    ),
    node(
        "alsa_input.platform-fe980000_usb.stereo-fallback",
        "Audio/Source",
        "Built-in Audio Stereo",
        "UAC2_Gadget",
    ),
    node(
        "alsa_output.platform-107c701400_hdmi.hdmi-stereo",
        "Audio/Sink",
        "Built-in Audio Digital Stereo (HDMI)",
        "vc4-hdmi",
    ),
]


def test_the_four_endpoints_are_found_in_a_real_looking_graph():
    # The names PipeWire actually generates carry no hint of their role, which is
    # exactly why the card name is part of the match.
    found = relay.find_endpoints(REAL_GRAPH)

    assert "soc_sound" in found["speaker"]
    assert found["speaker"].startswith("alsa_output")
    assert found["microphone"].startswith("alsa_input")
    assert "usb" in found["from_computer"]
    assert found["from_computer"].startswith("alsa_input")
    assert found["to_computer"].startswith("alsa_output")


def test_the_gadget_roles_are_the_way_round_they_look_wrong():
    found = relay.find_endpoints(REAL_GRAPH)

    # What the laptop plays arrives here as a *capture* device, and what we play
    # to the gadget is what the laptop records. Getting this backwards produces a
    # box that echoes the room to itself.
    assert found["from_computer"].startswith("alsa_input")
    assert found["to_computer"].startswith("alsa_output")


def test_hdmi_is_never_mistaken_for_the_speakers():
    found = relay.find_endpoints(REAL_GRAPH)
    assert "hdmi" not in found["speaker"]


def test_a_missing_hat_is_named_rather_than_guessed_around():
    without_hat = [n for n in REAL_GRAPH if "wm8960" not in n["card"]]

    with pytest.raises(relay.RelayError) as error:
        relay.find_endpoints(without_hat)

    assert "speaker" in str(error.value)
    assert "microphone" in str(error.value)
    # Name the side that is actually absent: the HAT and the gadget fail for
    # completely different reasons, and blaming both sends the reader looking in
    # the wrong place half the time.
    assert "WM8960 HAT is not in the audio graph" in str(error.value)
    assert "USB" not in str(error.value)


def test_a_missing_usb_gadget_is_named_too():
    without_gadget = [n for n in REAL_GRAPH if "UAC2" not in n["card"]]

    with pytest.raises(relay.RelayError) as error:
        relay.find_endpoints(without_gadget)

    assert "from_computer" in str(error.value)
    assert "to_computer" in str(error.value)
    assert "USB sound card" in str(error.value)
    assert "WM8960" not in str(error.value)


def test_an_empty_graph_fails_loudly_instead_of_starting_a_useless_relay():
    with pytest.raises(relay.RelayError):
        relay.find_endpoints([])


def test_matching_uses_the_card_name_when_the_node_name_says_nothing():
    # This is the case on a real Pi: every node is called "Built-in Audio
    # Stereo" and only the ALSA card name distinguishes them.
    anonymous = [
        node("alsa_output.a", "Audio/Sink", "Built-in Audio Stereo", "wm8960-soundcard"),
        node("alsa_input.b", "Audio/Source", "Built-in Audio Stereo", "wm8960-soundcard"),
        node("alsa_output.c", "Audio/Sink", "Built-in Audio Stereo", "UAC2_Gadget"),
        node("alsa_input.d", "Audio/Source", "Built-in Audio Stereo", "UAC2_Gadget"),
    ]

    found = relay.find_endpoints(anonymous)

    assert found["speaker"] == "alsa_output.a"
    assert found["microphone"] == "alsa_input.b"
    assert found["to_computer"] == "alsa_output.c"
    assert found["from_computer"] == "alsa_input.d"


def test_the_loopback_command_names_its_nodes():
    command = relay.loopback_command(capture="in", playback="out", name="neorecall.speakers")

    assert command[0] == "pw-loopback"
    assert "--capture" in command and "in" in command
    assert "--playback" in command and "out" in command
    # Named nodes are what make the graph readable in a diagnostic report.
    assert any("neorecall.speakers.in" in part for part in command)
    assert any("neorecall.speakers.out" in part for part in command)


def write_cards(tmp_path, text):
    path = tmp_path / "cards"
    path.write_text(text)
    return str(path)


BOTH_CARDS = """ 0 [wm8960soundcard]: simple-card - wm8960-soundcard
 2 [UAC2Gadget     ]: UAC2_Gadget - UAC2_Gadget
"""


def test_a_gadget_alsa_has_but_the_graph_lacks_is_worth_a_restart(monkeypatch, tmp_path):
    # The boot-order race: the USB gadget is built by a system service while
    # PipeWire runs in a user session, and WirePlumber only enumerates cards that
    # existed when it started. Restarting it is a fix, not a workaround.
    monkeypatch.setattr(relay, "ALSA_CARDS", write_cards(tmp_path, BOTH_CARDS))

    assert relay._card_exists_but_is_not_in_the_graph(
        "missing: from_computer, to_computer. The USB sound card ..."
    )


def test_a_missing_hat_that_alsa_also_lacks_is_not_worth_a_restart(monkeypatch, tmp_path):
    # No card in ALSA means the driver is the problem. Restarting WirePlumber
    # would only hide that behind a loop.
    monkeypatch.setattr(relay, "ALSA_CARDS", write_cards(tmp_path, " 1 [vc4hdmi]: vc4-hdmi\n"))

    assert not relay._card_exists_but_is_not_in_the_graph("missing: speaker, microphone. ...")


def test_a_hat_alsa_has_but_the_graph_lacks_is_also_worth_a_restart(monkeypatch, tmp_path):
    monkeypatch.setattr(relay, "ALSA_CARDS", write_cards(tmp_path, BOTH_CARDS))

    assert relay._card_exists_but_is_not_in_the_graph("missing: microphone, speaker. ...")


def test_no_cards_file_means_no_restart(monkeypatch):
    monkeypatch.setattr(relay, "ALSA_CARDS", "/definitely/not/here")

    assert not relay._card_exists_but_is_not_in_the_graph("missing: to_computer. ...")


VOLUME_25 = """numid=7,iface=MIXER,name='PCM Capture Volume'
  ; type=INTEGER,access=rw---R--,values=1,min=0,max=100,step=1
  : values=25
  | dBminmax-min=-100.00dB,max=0.00dB
"""
SWITCH_ON = """numid=6,iface=MIXER,name='PCM Capture Switch'
  ; type=BOOLEAN,access=rw------,values=1
  : values=on
"""
SWITCH_OFF = SWITCH_ON.replace("values=on", "values=off")


def test_host_volume_is_normalized_for_pipewire():
    level, muted = relay.host_playback_level(VOLUME_25, SWITCH_ON)

    assert level == pytest.approx(0.25)
    assert not muted


def test_host_mute_is_kept_separate_from_volume():
    level, muted = relay.host_playback_level(VOLUME_25, SWITCH_OFF)

    assert level == pytest.approx(0.25)
    assert muted


def test_an_invalid_host_volume_control_fails_loudly():
    with pytest.raises(relay.RelayError, match="unreadable"):
        relay.host_playback_level("not an ALSA control", SWITCH_ON)


def test_the_gadget_control_card_is_found_by_id_not_card_number(monkeypatch, tmp_path):
    (tmp_path / "card0").mkdir()
    (tmp_path / "card0/id").write_text("wm8960soundcard\n")
    (tmp_path / "card7").mkdir()
    (tmp_path / "card7/id").write_text("UAC2Gadget\n")
    monkeypatch.setattr(relay, "ALSA_CARD_ROOT", str(tmp_path))

    assert relay._gadget_alsa_card() == "UAC2Gadget"


def test_host_volume_is_applied_only_to_the_speaker_relay(monkeypatch):
    controls = {
        relay.HOST_PLAYBACK_VOLUME: VOLUME_25,
        relay.HOST_PLAYBACK_SWITCH: SWITCH_OFF,
    }
    commands = []
    monkeypatch.setattr(relay, "_read_mixer_control", lambda card, name: controls[name])

    def run(command, **kwargs):
        commands.append(command)
        return relay.subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(relay.subprocess, "run", run)

    relay._apply_host_playback_level("UAC2Gadget", 114)

    assert commands == [
        ["wpctl", "set-volume", "114", "0.250000"],
        ["wpctl", "set-mute", "114", "1"],
    ]


def test_the_computers_side_is_read_from_the_gadget_itself(monkeypatch):
    """The virtual source it used to read from never worked on real hardware.

    ``neorecall.capture.far`` sat permanently suspended: every ``pw-record``
    against it failed with "no more input formats", at any rate and any format.
    The capture process discarded its stderr, so nothing said so, and recordings
    reached the server carrying the microphone and nothing else — half of every
    conversation missing, with a green self-test.
    """
    from neorecall_desk.audio import streams

    nodes = [
        {
            "name": "alsa_input.platform-3f980000.usb.stereo-fallback",
            "media_class": "Audio/Source",
            "description": "USB gadget",
            "card": "UAC2Gadget",
        },
        {
            "name": "alsa_output.platform-3f980000.usb.stereo-fallback",
            "media_class": "Audio/Sink",
            "description": "USB gadget",
            "card": "UAC2Gadget",
        },
        {
            "name": "alsa_input.platform-soc_sound.stereo-fallback",
            "media_class": "Audio/Source",
            "description": "Built-in Audio",
            "card": "wm8960-soundcard",
        },
        {
            "name": "alsa_output.platform-soc_sound.stereo-fallback",
            "media_class": "Audio/Sink",
            "description": "Built-in Audio",
            "card": "wm8960-soundcard",
        },
    ]
    monkeypatch.setattr(relay, "_nodes", lambda: nodes)
    monkeypatch.setattr(streams, "NODE_FAR", "")

    assert streams.far_side_target() == "alsa_input.platform-3f980000.usb.stereo-fallback"


def test_a_capture_that_cannot_open_says_why(caplog):
    """Silence here cost a fortnight. The error goes to the log, not to nowhere."""
    import logging
    import subprocess

    from neorecall_desk.audio import streams

    class Refuses:
        returncode = 1
        stdout = None
        stderr = [b"stream node 147 error: no more input formats\n"]

        def poll(self):
            return 1

    def launcher(argv, **kwargs):
        assert kwargs["stderr"] is subprocess.PIPE, "the error has to be readable"
        return Refuses()

    stream = streams.PwRecordStream("neorecall.capture.far", launcher=launcher)
    with caplog.at_level(logging.WARNING):
        stream.start()
        for _ in range(200):
            if any("no more input formats" in record.message for record in caplog.records):
                break
            time.sleep(0.01)

    assert any("no more input formats" in record.message for record in caplog.records)


def test_no_loopback_is_ever_built_without_a_name():
    """A nameless loopback is not a warning, it is a crash loop.

    Emptying the far-side constant left the relay still building a loopback
    from it: pw-loopback got ``node.name=`` with nothing after it, refused to
    parse, exited 255, and took the whole audio graph down with it on every
    restart — speakers, microphones and all.
    """
    with pytest.raises(ValueError, match="name"):
        relay.loopback_command(capture="alsa_input.x", playback=None, name="")


def test_a_replug_is_recognised_only_on_the_edge_into_configured():
    """The moment the stale-handle cure has to fire, and only that moment.

    Measured, not reasoned: after a cable replug the relay's long-open ALSA
    handle to the gadget delivers silence for ever — 117 000 captured frames,
    RMS 0, while the computer audibly played. Rebuilding the graph fixed it on
    the spot, so the graph is rebuilt exactly when the host (re)attaches.
    """
    # The cure moment: back to configured from unplugged or suspended.
    assert relay.replug_happened("not attached", "configured")
    assert relay.replug_happened("suspended", "configured")
    assert relay.replug_happened("default", "configured")

    # Steady states and mid-enumeration flapping must not restart anything.
    assert not relay.replug_happened("configured", "configured")
    assert not relay.replug_happened("configured", "not attached")
    assert not relay.replug_happened("not attached", "default")
    assert not relay.replug_happened("", "configured"), "first reading is not a replug"


def test_a_stale_volume_target_is_re_resolved_not_fatal(monkeypatch, caplog):
    """One stale node id took the whole relay down for ten silent seconds.

    Node ids churn with the graph; names do not. The volume follower now
    re-resolves by name and retries, and a still-failing event is skipped —
    volume is a convenience, audio is the product.
    """
    import logging

    calls = []

    def apply(card, target_id):
        calls.append(target_id)
        if target_id == 127:  # the id that vanished on hardware
            raise relay.RelayError("wpctl set-volume 127 failed")

    class EndedMonitor:
        stdout = iter(())

        def terminate(self):  # pragma: no cover - must not be reached
            raise AssertionError("the monitor must not be killed over one event")

    monkeypatch.setattr(relay, "_apply_host_playback_level", apply)
    monkeypatch.setattr(relay, "_resolve_node_id", lambda name: 201)

    with caplog.at_level(logging.INFO):
        relay._follow_host_playback_level("UAC2Gadget", 127, EndedMonitor())

    assert calls == [127, 201], "retried once with the freshly resolved id"
