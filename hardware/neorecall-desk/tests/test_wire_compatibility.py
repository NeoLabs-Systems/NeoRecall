"""The exact bytes the app is compiled to expect.

`flutter_app/test/appliance_wire_compatibility_test.dart` holds this same array
and decodes it with the app's own CBOR reader. Pinning it on both sides is what
makes a change to either encoder a loud failure rather than a device that pairs
and then shows nothing.

If this test fails because the payload legitimately changed, regenerate the array
and update the Dart fixture in the same commit. Never update only one.
"""

from neorecall_desk.control import protocol as P
from neorecall_desk.state import MicSource, OutputTarget, Snapshot, State

# fmt: off
EXPECTED_STATUS = bytes([
    177, 97, 118, 1, 98, 115, 116, 105, 114, 101, 99, 111, 114, 100, 105, 110,
    103, 98, 101, 108, 26, 0, 12, 220, 248, 98, 112, 99, 12, 98, 110, 97,
    1, 99, 111, 117, 116, 106, 104, 101, 97, 100, 112, 104, 111, 110, 101, 115,
    99, 109, 105, 99, 103, 104, 101, 97, 100, 115, 101, 116, 98, 104, 99, 245,
    98, 104, 110, 111, 83, 111, 110, 121, 32, 87, 72, 45, 49, 48, 48, 48,
    88, 77, 53, 98, 104, 98, 24, 72, 99, 110, 101, 116, 244, 100, 97, 117,
    116, 104, 244, 99, 114, 101, 118, 244, 99, 101, 114, 114, 96, 98, 102, 119,
    101, 48, 46, 49, 46, 48, 99, 100, 105, 100, 120, 36, 52, 52, 52, 52,
    52, 52, 52, 52, 45, 52, 52, 52, 52, 45, 52, 52, 52, 52, 45, 56,
    52, 52, 52, 45, 52, 52, 52, 52, 52, 52, 52, 52, 52, 52, 52, 52,
    99, 114, 101, 115, 163, 97, 99, 111, 115, 101, 116, 95, 104, 101, 97, 100,
    115, 101, 116, 95, 109, 105, 99, 98, 111, 107, 245, 97, 109, 120, 45, 83,
    111, 117, 110, 100, 32, 113, 117, 97, 108, 105, 116, 121, 32, 100, 114, 111,
    112, 115, 32, 97, 32, 108, 105, 116, 116, 108, 101, 32, 119, 104, 105, 108,
    101, 32, 114, 101, 99, 111, 114, 100, 105, 110, 103, 46,
])

EXPECTED_DISCOVERY = bytes([
    165, 97, 118, 1, 97, 107, 105, 98, 108, 117, 101, 116, 111, 111, 116, 104, 97, 101,
    129, 165, 103, 97, 100, 100, 114, 101, 115, 115, 113, 65, 65, 58, 66, 66, 58, 67,
    67, 58, 68, 68, 58, 69, 69, 58, 70, 70, 100, 110, 97, 109, 101, 111, 83, 111, 110,
    121, 32, 87, 72, 45, 49, 48, 48, 48, 88, 77, 53, 102, 112, 97, 105, 114, 101, 100,
    245, 105, 99, 111, 110, 110, 101, 99, 116, 101, 100, 245, 103, 98, 97, 116, 116,
    101, 114, 121, 24, 72, 97, 112, 0, 97, 110, 1,
])
# fmt: on

SNAPSHOT = Snapshot(
    state=State.RECORDING,
    recording_elapsed_ms=843000,
    pending_chunks=12,
    needs_attention=1,
    output_target=OutputTarget.HEADPHONES,
    mic_source=MicSource.HEADSET,
    headset_connected=True,
    headset_name="Sony WH-1000XM5",
    headset_battery=72,
    network_online=False,
    error="No network yet — 12 recordings are waiting.",
    firmware="0.1.0",
    device_id="44444444-4444-4444-8444-444444444444",
)

RESULT = P.CommandResult(
    command=P.CMD_SET_HEADSET_MIC,
    ok=True,
    message="Sound quality drops a little while recording.",
)


def test_a_status_update_is_byte_for_byte_what_the_app_expects():
    assert P.encode_status(SNAPSHOT, RESULT) == EXPECTED_STATUS


def test_a_scan_result_is_byte_for_byte_what_the_app_expects():
    entries = [
        {
            "address": "AA:BB:CC:DD:EE:FF",
            "name": "Sony WH-1000XM5",
            "paired": True,
            "connected": True,
            "battery": 72,
        }
    ]
    assert P.encode_discovery("bluetooth", entries) == EXPECTED_DISCOVERY


def test_every_page_of_a_discovery_result_fits_one_notification():
    """The invariant the pinned bytes above are only one example of.

    A result list used to be sent as a single notification whatever its size.
    Seven self-test verdicts encode to about 650 bytes against a 244-byte
    packet, so BlueZ delivered a fragment the app could not decode and the check
    appeared to do nothing at all.
    """
    verdicts = [
        {
            "name": f"check {index}",
            "ok": False,
            "detail": "a sentence about what went wrong that is as long as these get, "
            "because the appliance explains itself in words rather than codes",
        }
        for index in range(7)
    ]
    pages = P.discovery_pages("selftest", verdicts)

    assert len(pages) > 1
    assert all(len(page) <= P.STATUS_NOTIFICATION_LIMIT for page in pages)


def test_no_verdict_is_lost_to_paging():
    entries = [{"name": f"check {index}", "ok": True, "detail": "x" * 120} for index in range(9)]

    recovered: list[dict] = []
    for page in P.discovery_pages("selftest", entries):
        kind, part = P.decode_discovery(page)
        assert kind == "selftest"
        recovered.extend(part)

    assert [entry["name"] for entry in recovered] == [entry["name"] for entry in entries]


def test_a_single_oversized_detail_is_clipped_rather_than_dropped():
    pages = P.discovery_pages("selftest", [{"name": "check", "ok": False, "detail": "y" * 900}])

    assert len(pages) == 1
    _, entries = P.decode_discovery(pages[0])
    assert entries[0]["name"] == "check"
    assert entries[0]["detail"].endswith("\u2026")


def test_the_pinned_payload_is_the_worst_case_and_still_fits_one_packet():
    assert len(EXPECTED_STATUS) <= P.STATUS_NOTIFICATION_LIMIT


def test_the_pinned_payload_kept_identity_and_the_direct_answer():
    # The two fields that must survive the shrinker: which device this is, and
    # the answer to what the user just did.
    decoded, result = P.decode_status(EXPECTED_STATUS)

    assert decoded.device_id == "44444444-4444-4444-8444-444444444444"
    assert result.message == "Sound quality drops a little while recording."
    # The ambient error is what was traded away for them.
    assert decoded.error == ""


def test_an_unusable_timezone_does_not_cost_recordings():
    """Found against the real server, on the first appliance recording ever made.

    The app sent ``DateTime.timeZoneName`` — "CEST" — and the session endpoint
    answered "Invalid IANA timezone". Session declaration is the first step of
    every upload, so the rejection held back the whole queue.
    """
    from neorecall_desk.ingest.client import iana_timezone

    assert iana_timezone("CEST") == "UTC"
    assert iana_timezone("") == "UTC"
    assert iana_timezone("Europe/Berlin") == "Europe/Berlin"
