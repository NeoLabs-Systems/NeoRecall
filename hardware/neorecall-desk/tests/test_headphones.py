"""Headphone routing: what the user is told, and what is kept out of the list."""

import pytest

from neorecall_desk.control import headphones as H

CARD_LISTING = """Card #12
\tName: bluez_card.AA_BB_CC_DD_EE_FF
\tDriver: module-bluez5-device.c
\tProfiles:
\t\toff: Off (sinks: 0, sources: 0, priority: 0, available: yes)
\t\ta2dp-sink: High Fidelity Playback (sinks: 1, sources: 0, priority: 40, available: yes)
\t\theadset-head-unit-msbc: Handsfree (sinks: 1, sources: 1, priority: 30, available: yes)
\tActive Profile: a2dp-sink
\tPorts:
\t\theadphone-output: Headphone
"""

PLAYBACK_ONLY_LISTING = """Card #12
\tName: bluez_card.AA_BB_CC_DD_EE_FF
\tProfiles:
\t\toff: Off (sinks: 0, sources: 0, priority: 0, available: yes)
\t\ta2dp-sink: High Fidelity Playback (sinks: 1, sources: 0, priority: 40, available: yes)
\tActive Profile: a2dp-sink
"""


@pytest.fixture()
def manager():
    return H.HeadphoneManager(runtime=None)


def test_a_card_name_is_derived_from_the_address():
    assert H._card_name("aa:bb:cc:dd:ee:ff") == "bluez_card.AA_BB_CC_DD_EE_FF"


def test_offered_profiles_are_read_from_the_card(monkeypatch):
    monkeypatch.setattr(H, "_run", lambda argv: (0, CARD_LISTING))

    assert H.available_profiles("AA:BB:CC:DD:EE:FF") == {
        "off": True,
        "a2dp-sink": True,
        "headset-head-unit-msbc": True,
    }


def test_the_wideband_headset_profile_is_preferred(monkeypatch):
    monkeypatch.setattr(H, "_run", lambda argv: (0, CARD_LISTING))
    assert H.preferred_headset_profile("AA:BB:CC:DD:EE:FF") == "headset-head-unit-msbc"


def test_a_playback_only_headphone_offers_no_microphone(monkeypatch):
    monkeypatch.setattr(H, "_run", lambda argv: (0, PLAYBACK_ONLY_LISTING))
    assert H.preferred_headset_profile("AA:BB:CC:DD:EE:FF") is None


def test_a_card_that_is_not_there_offers_nothing(monkeypatch):
    monkeypatch.setattr(H, "_run", lambda argv: (0, "Card #1\n\tName: alsa_card.0\n"))
    assert H.available_profiles("AA:BB:CC:DD:EE:FF") == {}


def test_turning_on_the_headset_microphone_warns_about_the_quality_drop(monkeypatch, manager):
    monkeypatch.setattr(H, "available_profiles", lambda address: {"headset-head-unit-msbc": True})
    monkeypatch.setattr(H, "set_profile", lambda address, profile: True)

    ok, message = manager.use_headset_microphone("AA:BB:CC:DD:EE:FF", True)

    assert ok
    assert "quality drops" in message


def test_the_narrowband_fallback_warns_more_firmly(monkeypatch, manager):
    monkeypatch.setattr(H, "available_profiles", lambda address: {"headset-head-unit": True})
    monkeypatch.setattr(H, "set_profile", lambda address, profile: True)

    ok, message = manager.use_headset_microphone("AA:BB:CC:DD:EE:FF", True)

    assert ok
    assert message == "Using the headset microphone. Sound quality drops while recording."


def test_headphones_without_a_usable_microphone_say_so_plainly(monkeypatch, manager):
    monkeypatch.setattr(H, "available_profiles", lambda address: {"a2dp-sink": True})

    ok, message = manager.use_headset_microphone("AA:BB:CC:DD:EE:FF", True)

    assert not ok
    assert "do not offer a microphone" in message


def test_a_headset_the_card_cannot_be_read_for_is_not_blamed(monkeypatch, manager):
    """An empty card listing means "not connected yet", not "no microphone".

    Telling somebody their working headset has no microphone sends them to buy
    another one. Saying the appliance has not finished connecting sends them to
    wait a second, which is the actual remedy.
    """
    monkeypatch.setattr(H, "available_profiles", lambda address: {})

    ok, message = manager.use_headset_microphone("AA:BB:CC:DD:EE:FF", True)

    assert not ok
    assert "not connected yet" in message


def test_turning_the_headset_microphone_off_restores_playback_quality(monkeypatch, manager):
    chosen = {}
    monkeypatch.setattr(
        H, "set_profile", lambda address, profile: chosen.setdefault("p", profile) or True
    )

    ok, message = manager.use_headset_microphone("AA:BB:CC:DD:EE:FF", False)

    assert ok and message == ""
    assert chosen["p"] == H.PROFILE_PLAYBACK


def test_only_audio_devices_are_offered_as_headphones():
    assert H._looks_like_audio({"Class": 0x240404})
    assert H._looks_like_audio({"Icon": "audio-headset"})
    # A phone or a keyboard in range must not show up in a headphone picker.
    assert not H._looks_like_audio({"Class": 0x5A020C, "Icon": "phone"})
    assert not H._looks_like_audio({})


def test_a_headphone_entry_omits_values_it_does_not_have():
    entry = H.Headphone(address="AA:BB:CC:DD:EE:FF", name="Sony WH-1000XM5", paired=True).as_entry()

    assert entry == {
        "address": "AA:BB:CC:DD:EE:FF",
        "name": "Sony WH-1000XM5",
        "paired": True,
        "connected": False,
    }


def test_a_headphone_entry_carries_battery_when_it_is_known():
    entry = H.Headphone(address="A", name="B", battery=72, signal=-54).as_entry()

    assert entry["battery"] == 72
    assert entry["signal"] == -54


def test_a_paired_phone_is_not_a_pair_of_headphones(monkeypatch):
    """Reported from the living room: "it shows the connected phone as a headphone".

    The phone used to set the appliance up is paired by definition, and the
    check for "is this actually an audio device" was skipped for anything
    paired. So the phone appeared in the headphone list, and the status told
    the app a headset was connected when none was.
    """
    objects = {
        "/org/bluez/hci0/dev_64_9D_38_E4_56_1D": {
            H.bluez.DEVICE_IFACE: {
                "Address": "64:9D:38:E4:56:1D",
                "Alias": "Pixel 10 Pro",
                "Paired": True,
                "Connected": True,
                "Class": 0x5A020C,  # phone
                "Icon": "phone",
            }
        },
        "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF": {
            H.bluez.DEVICE_IFACE: {
                "Address": "AA:BB:CC:DD:EE:FF",
                "Alias": "WH-1000XM5",
                "Paired": True,
                "Connected": True,
                "Class": 0x240404,  # audio
            }
        },
    }

    async def _objects(_bus):
        return objects

    monkeypatch.setattr(H.bluez, "managed_objects", _objects)
    manager = H.HeadphoneManager(runtime=None)

    import asyncio

    found = asyncio.run(manager._known(None, include_unpaired=False))

    assert [item.name for item in found] == ["WH-1000XM5"]


CVSD_ONLY_LISTING = """Card #12
\tName: bluez_card.AA_BB_CC_DD_EE_FF
\tProfiles:
\t\toff: Off (sinks: 0, sources: 0, priority: 0, available: yes)
\t\ta2dp-sink: High Fidelity Playback (sinks: 1, sources: 0, priority: 40, available: yes)
\t\theadset-head-unit-cvsd: Handsfree (sinks: 1, sources: 1, priority: 30, available: yes)
\tActive Profile: a2dp-sink
"""

MIXED_AVAILABILITY_LISTING = """Card #12
\tName: bluez_card.AA_BB_CC_DD_EE_FF
\tProfiles:
\t\ta2dp-sink: High Fidelity Playback (sinks: 1, sources: 0, priority: 40, available: yes)
\t\theadset-head-unit-msbc: Handsfree (sinks: 1, sources: 1, priority: 30, available: no)
\t\theadset-head-unit-cvsd: Handsfree (sinks: 1, sources: 1, priority: 20, available: yes)
\tActive Profile: a2dp-sink
"""


def test_a_headset_offering_only_cvsd_still_has_a_microphone(monkeypatch):
    """The exact headset that was told it had no microphone.

    PipeWire names its hands-free profiles after the codec it negotiated, and
    the set of names depends on the build. Matching a fixed pair of them meant a
    headset offering `headset-head-unit-cvsd` — an ordinary, working headset —
    was refused outright.
    """
    monkeypatch.setattr(H, "_run", lambda argv: (0, CVSD_ONLY_LISTING))

    assert H.preferred_headset_profile("AA:BB:CC:DD:EE:FF") == "headset-head-unit-cvsd"


def test_an_unavailable_profile_is_not_offered_ahead_of_a_usable_one(monkeypatch):
    """`available: no` means selecting it fails, so it cannot be the first choice."""
    monkeypatch.setattr(H, "_run", lambda argv: (0, MIXED_AVAILABILITY_LISTING))

    assert H.preferred_headset_profile("AA:BB:CC:DD:EE:FF") == "headset-head-unit-cvsd"


def test_better_codecs_are_preferred_when_both_are_usable():
    offered = {
        "a2dp-sink": True,
        "headset-head-unit": True,
        "headset-head-unit-cvsd": True,
        "headset-head-unit-msbc": True,
    }
    assert H.headset_profiles(offered) == [
        "headset-head-unit-msbc",
        "headset-head-unit-cvsd",
        "headset-head-unit",
    ]


def test_an_unknown_future_codec_is_usable_without_editing_the_list():
    offered = {"headset-head-unit-aptx-hf": True}
    assert H.headset_profiles(offered) == ["headset-head-unit-aptx-hf"]


def test_an_unavailable_profile_is_tried_rather_than_refused(monkeypatch, manager):
    """Some headsets only publish hands-free as available once asked.

    Trying it and letting the switch fail is a better answer than refusing on
    the strength of a flag that is only advisory.
    """
    monkeypatch.setattr(H, "available_profiles", lambda address: {"headset-head-unit-msbc": False})
    attempted: list[str] = []
    monkeypatch.setattr(
        H, "set_profile", lambda address, profile: attempted.append(profile) or True
    )

    ok, _ = manager.use_headset_microphone("AA:BB:CC:DD:EE:FF", True)

    assert ok
    assert attempted == ["headset-head-unit-msbc"]


def test_the_next_profile_is_tried_when_the_best_one_will_not_switch(monkeypatch, manager):
    monkeypatch.setattr(
        H,
        "available_profiles",
        lambda address: {"headset-head-unit-msbc": True, "headset-head-unit-cvsd": True},
    )
    attempted: list[str] = []

    def switch(address, profile):
        attempted.append(profile)
        return profile == "headset-head-unit-cvsd"

    monkeypatch.setattr(H, "set_profile", switch)

    ok, message = manager.use_headset_microphone("AA:BB:CC:DD:EE:FF", True)

    assert ok
    assert attempted == ["headset-head-unit-msbc", "headset-head-unit-cvsd"]
    assert "quality drops while recording" in message
