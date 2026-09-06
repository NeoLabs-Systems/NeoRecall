"""The acoustic loopback: does the box hear its own tone?

The analysis is what these tests cover. Playing and recording need hardware, but
"is the tone in this recording" is arithmetic — and it is the part that decides
whether a device passes, so it is the part worth being sure about.
"""

import pathlib

import numpy as np
import pytest

from neorecall_desk.audio import selftest

#: Kept before any test replaces `selftest.pathlib.Path`, so the fakes can still
#: reach the real one for paths they do not care about.
pathlib_real = pathlib.Path

RATE = selftest.SAMPLE_RATE


def tone(hz, seconds=1.0, amplitude=0.4, noise=0.0):
    t = np.arange(int(RATE * seconds)) / RATE
    signal = amplitude * np.sin(2 * np.pi * hz * t)
    if noise:
        rng = np.random.default_rng(7)
        signal = signal + rng.normal(0, noise, t.size)
    return np.clip(signal * 32767, -32768, 32767).astype(np.int16)


def test_a_clean_tone_is_detected():
    assert selftest.tone_strength_db(tone(selftest.TONE_HZ)) > selftest.DETECTION_MARGIN_DB


def test_a_tone_buried_in_room_noise_is_still_detected():
    # A real recording is never clean: the microphones sit centimetres from the
    # speaker but also hear the room.
    heard = tone(selftest.TONE_HZ, amplitude=0.08, noise=0.02)

    assert selftest.tone_strength_db(heard) > selftest.DETECTION_MARGIN_DB


def test_noise_without_the_tone_is_not_mistaken_for_success():
    rng = np.random.default_rng(3)
    only_noise = (rng.normal(0, 0.05, RATE) * 32767).astype(np.int16)

    assert selftest.tone_strength_db(only_noise) < selftest.DETECTION_MARGIN_DB


def test_a_different_tone_does_not_count():
    # Something else in the room humming at 400 Hz must not pass as our 1 kHz.
    assert selftest.tone_strength_db(tone(400.0)) < selftest.DETECTION_MARGIN_DB


def test_silence_is_reported_as_silence():
    assert selftest.is_silent(np.zeros(RATE, dtype=np.int16))
    assert selftest.is_silent(np.full(RATE, 3, dtype=np.int16))
    assert not selftest.is_silent(tone(selftest.TONE_HZ))


def test_an_empty_recording_is_silent_not_a_crash():
    empty = np.zeros(0, dtype=np.int16)

    assert selftest.is_silent(empty)
    assert selftest.tone_strength_db(empty) == float("-inf")


def test_a_recording_too_short_to_judge_is_refused():
    assert selftest.tone_strength_db(tone(selftest.TONE_HZ, seconds=0.05)) == float("-inf")


def test_a_dead_microphone_blames_the_microphone_not_the_speakers(monkeypatch):
    monkeypatch.setattr(selftest.shutil, "which", lambda tool: "/usr/bin/" + tool)
    monkeypatch.setattr(selftest.relay, "_nodes", lambda: [])
    monkeypatch.setattr(
        selftest.relay,
        "find_endpoints",
        lambda nodes: {
            "speaker": "spk",
            "microphone": "mic",
            "from_computer": "usb-in",
            "to_computer": "usb-out",
        },
    )
    monkeypatch.setattr(
        selftest, "_play_and_record", lambda *a, **k: np.zeros(RATE, dtype=np.int16)
    )

    checks = {check.name: check for check in selftest.run()}

    assert not checks["microphones"].ok
    # And it must not claim the speakers are broken on evidence it does not have.
    assert not checks["speakers"].ok
    assert "cannot tell" in checks["speakers"].detail


def test_working_hardware_passes_every_check(monkeypatch):
    monkeypatch.setattr(selftest.shutil, "which", lambda tool: "/usr/bin/" + tool)
    monkeypatch.setattr(selftest.relay, "_nodes", lambda: [])
    monkeypatch.setattr(
        selftest.relay,
        "find_endpoints",
        lambda nodes: {
            "speaker": "spk",
            "microphone": "mic",
            "from_computer": "usb-in",
            "to_computer": "usb-out",
        },
    )
    monkeypatch.setattr(
        selftest,
        "_play_and_record",
        lambda *a, **k: tone(selftest.TONE_HZ, amplitude=0.2, noise=0.01),
    )
    healthy_system(monkeypatch)

    checks = selftest.run()

    assert all(check.ok for check in checks), [c.detail for c in checks if not c.ok]


def healthy_system(monkeypatch):
    """Stand in for the checks that read the running system."""
    monkeypatch.setattr(
        selftest,
        "codec_driver",
        lambda: selftest.Check("codec driver", True, "loaded"),
    )
    monkeypatch.setattr(
        selftest,
        "usb_gadget",
        lambda: selftest.Check("usb gadget", True, "bound"),
    )
    monkeypatch.setattr(
        selftest,
        "usb_audio_name_driver",
        lambda: selftest.Check("usb audio name", True, "DKMS override selected"),
    )
    monkeypatch.setattr(
        selftest,
        "audio_relay",
        lambda: selftest.Check("audio relay", True, "wired"),
    )


def test_a_missing_codec_driver_is_reported_as_the_silent_failure_it_is(monkeypatch):
    # The one check that would have saved the longest evening of bring-up: the
    # card enumerates, plays, reports success, and converts nothing.
    monkeypatch.setattr(
        selftest.pathlib.Path, "read_text", lambda self, *a, **k: "snd_soc_wm8960 45056 1\n"
    )

    check = selftest.codec_driver()

    assert not check.ok
    assert "no clock" in check.detail


def test_a_loaded_machine_driver_passes(monkeypatch):
    monkeypatch.setattr(
        selftest.pathlib.Path,
        "read_text",
        lambda self, *a, **k: "snd_soc_wm8960_soundcard 16384 1\n",
    )

    assert selftest.codec_driver().ok


def test_a_gadget_with_the_wrong_function_name_is_a_failure(monkeypatch, tmp_path):
    root = tmp_path / "neorecall"
    (root / "functions/uac2.usb0").mkdir(parents=True)
    (root / "UDC").write_text("3f980000.usb\n")
    (root / "functions/uac2.usb0/function_name").write_text("USB Audio\n")
    monkeypatch.setattr(
        selftest.pathlib,
        "Path",
        lambda p="": root if str(p).endswith("usb_gadget/neorecall") else pathlib_real(p),
    )

    check = selftest.usb_gadget()

    assert not check.ok
    assert "USB Audio" in check.detail


def test_a_named_gadget_passes(monkeypatch, tmp_path):
    root = tmp_path / "neorecall"
    (root / "functions/uac2.usb0").mkdir(parents=True)
    (root / "UDC").write_text("3f980000.usb\n")
    (root / "functions/uac2.usb0/function_name").write_text("NeoRecall Desk\n")
    monkeypatch.setattr(
        selftest.pathlib,
        "Path",
        lambda p="": root if str(p).endswith("usb_gadget/neorecall") else pathlib_real(p),
    )

    assert selftest.usb_gadget().ok


def test_the_dkms_usb_audio_module_passes(monkeypatch):
    completed = selftest.subprocess.CompletedProcess(
        args=[], returncode=0, stdout="/lib/modules/6.18/updates/dkms/usb_f_uac2.ko.xz\n"
    )
    monkeypatch.setattr(selftest.subprocess, "run", lambda *args, **kwargs: completed)

    assert selftest.usb_audio_name_driver().ok


def test_the_stock_usb_audio_module_reports_the_old_names(monkeypatch):
    completed = selftest.subprocess.CompletedProcess(
        args=[],
        returncode=0,
        stdout="/lib/modules/6.18/kernel/drivers/usb/gadget/function/usb_f_uac2.ko.xz\n",
    )
    monkeypatch.setattr(selftest.subprocess, "run", lambda *args, **kwargs: completed)

    check = selftest.usb_audio_name_driver()

    assert not check.ok
    assert "stock module" in check.detail


def test_an_unbound_gadget_is_a_failure(monkeypatch, tmp_path):
    root = tmp_path / "neorecall"
    (root / "functions/uac2.usb0").mkdir(parents=True)
    (root / "UDC").write_text("\n")
    monkeypatch.setattr(
        selftest.pathlib,
        "Path",
        lambda p="": root if str(p).endswith("usb_gadget/neorecall") else pathlib_real(p),
    )

    check = selftest.usb_gadget()
    assert not check.ok
    assert "no controller" in check.detail


#: The cards themselves, as ``pw-dump`` reports them. The recorder reads the
#: computer's side straight from the USB gadget, so the check has to see it.
_HARDWARE_NODES = [
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


def test_a_missing_relay_names_the_nodes_that_are_not_there(monkeypatch):
    monkeypatch.setattr(
        selftest.relay,
        "_nodes",
        lambda: [
            {
                "name": "neorecall.speakers.in",
                "media_class": "Stream/Input/Audio",
                "description": "neorecall.speakers.in",
                "card": "",
            },
            *_HARDWARE_NODES,
        ],
    )

    check = selftest.audio_relay()

    assert not check.ok
    assert "neorecall.mic.in" in check.detail


def test_a_complete_relay_passes(monkeypatch):
    monkeypatch.setattr(
        selftest.relay,
        "_nodes",
        lambda: [
            {
                "name": "neorecall.speakers.in",
                "media_class": "Stream/Input/Audio",
                "description": "neorecall.speakers.in",
                "card": "",
            },
            {
                "name": "neorecall.speakers.out",
                "media_class": "Stream/Output/Audio",
                "description": "neorecall.speakers.out",
                "card": "",
            },
            {
                "name": "neorecall.mic.in",
                "media_class": "Stream/Input/Audio",
                "description": "neorecall.mic.in",
                "card": "",
            },
            {
                "name": "neorecall.mic.out",
                "media_class": "Stream/Output/Audio",
                "description": "neorecall.mic.out",
                "card": "",
            },
            # The relay being up is not the same thing as the appliance being
            # able to record, which is the distinction this check now makes.
            {
                "name": "neorecall.relay.out",
                "media_class": "Audio/Sink",
                "description": "neorecall.relay.out",
                "card": "",
            },
            {
                "name": "neorecall.capture.near",
                "media_class": "Audio/Source",
                "description": "neorecall.capture.near",
                "card": "",
            },
            *_HARDWARE_NODES,
        ],
    )

    assert selftest.audio_relay().ok


def test_the_wrong_account_is_refused_with_an_instruction():
    # PipeWire lives in the appliance account's session. Asked from anywhere else
    # it answers with an empty graph — which looks exactly like broken hardware,
    # and did: this test once reported four confident failures while the speakers
    # were audibly working.
    problem = selftest.session_problem(euid=1000, appliance_uid=102)

    assert problem
    assert "sudo" in problem


def test_root_is_told_to_switch_rather_than_to_stop():
    # An empty string means "re-exec as the appliance account", not "fail".
    assert selftest.session_problem(euid=0, appliance_uid=102) == ""


def test_the_appliance_account_itself_proceeds():
    assert selftest.session_problem(euid=102, appliance_uid=102) is None


def test_a_machine_without_the_account_is_left_alone():
    # A developer workstation has no neorecall account and should still be able
    # to run the analysis parts.
    assert selftest.session_problem(euid=501, appliance_uid=None) is None


def test_a_check_that_throws_reports_a_failure_rather_than_aborting(monkeypatch):
    # A diagnostic that raises is worse than no diagnostic: it takes the other
    # checks with it, and the crash tells you nothing about the hardware. This
    # happened for real — pw-play blocked, and the timeout killed the run.
    def explode():
        raise RuntimeError("something in the audio stack")

    check = selftest._safely("usb gadget", explode)

    assert not check.ok
    assert "the check itself failed" in check.detail
    assert "something in the audio stack" in check.detail


def test_a_check_that_works_is_passed_through_untouched():
    original = selftest.Check("codec driver", True, "loaded")

    assert selftest._safely("codec driver", lambda: original) is original


def test_a_loopback_that_cannot_run_is_reported_not_raised(monkeypatch):
    healthy_system(monkeypatch)
    monkeypatch.setattr(selftest.shutil, "which", lambda tool: "/usr/bin/" + tool)
    monkeypatch.setattr(
        selftest.relay,
        "find_endpoints",
        lambda nodes: {
            "speaker": "spk",
            "microphone": "mic",
            "from_computer": "u-in",
            "to_computer": "u-out",
        },
    )
    monkeypatch.setattr(selftest.relay, "_nodes", lambda: [])
    monkeypatch.setattr(
        selftest,
        "_play_and_record",
        lambda *a, **k: (_ for _ in ()).throw(OSError("pw-play went away")),
    )

    checks = selftest.run()

    assert not checks[-1].ok
    assert "could not run" in checks[-1].detail
    # The system checks before it still reported.
    assert [c.ok for c in checks[:3]] == [True, True, True]


def test_the_relay_is_restarted_even_when_the_check_blows_up(monkeypatch, tmp_path):
    """A diagnostic must not be able to break the thing it diagnoses.

    The check stops the audio relay so it can have the speakers to itself. It
    used to start it again on the happy path only, so anything that raised in
    between left the appliance silent until somebody restarted the unit by hand.
    """
    actions: list[str] = []
    monkeypatch.setattr(selftest, "_relay", lambda action: actions.append(action))
    monkeypatch.setattr(selftest, "_tone", lambda path: None)
    monkeypatch.setattr(selftest.time, "sleep", lambda seconds: None)

    def explode(*args, **kwargs):
        raise OSError("pw-record is not installed")

    monkeypatch.setattr(selftest, "_tone_round_trip", explode)

    with pytest.raises(OSError):
        selftest._play_and_record("speaker", "microphone", tmp_path)

    assert actions == ["stop", "start"]


def test_the_relay_is_restarted_after_an_ordinary_run(monkeypatch, tmp_path):
    actions: list[str] = []
    monkeypatch.setattr(selftest, "_relay", lambda action: actions.append(action))
    monkeypatch.setattr(selftest, "_tone", lambda path: None)
    monkeypatch.setattr(selftest.time, "sleep", lambda seconds: None)
    monkeypatch.setattr(selftest, "_tone_round_trip", lambda *a, **k: np.zeros(0, dtype=np.int16))

    selftest._play_and_record("speaker", "microphone", tmp_path)

    assert actions == ["stop", "start"]
