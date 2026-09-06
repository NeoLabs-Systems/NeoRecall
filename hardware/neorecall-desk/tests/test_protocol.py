"""The contract between the appliance and the app."""

from dataclasses import replace

import cbor2
import pytest

from neorecall_desk.control import protocol as P
from neorecall_desk.state import MicSource, OutputTarget, Snapshot, State


def test_a_status_notification_survives_a_round_trip():
    snapshot = Snapshot(
        state=State.RECORDING,
        recording_elapsed_ms=843000,
        pending_chunks=12,
        output_target=OutputTarget.HEADPHONES,
        output_name="Sony WH-1000XM5",
        mic_source=MicSource.HEADSET,
        headset_connected=True,
        headset_name="Sony WH-1000XM5",
        headset_battery=72,
        network_online=False,
        firmware="0.1.0",
    )

    decoded, result = P.decode_status(P.encode_status(snapshot))

    # The output's name is not on the wire: when the output is headphones it is
    # the headset name, and when it is the speaker the app writes the word
    # itself. Everything else survives unchanged.
    assert decoded == replace(snapshot, output_name="")
    assert result is None


def test_a_status_notification_fits_in_one_bluetooth_packet():
    # A status update that fragments is a status update that arrives late, and
    # this one is sent on every state change.
    snapshot = Snapshot(
        state=State.RECORDING,
        output_name="A Really Quite Long Headphone Name Edition",
        headset_name="A Really Quite Long Headphone Name Edition",
        error="No network yet — 12 recordings are waiting to be sent",
        firmware="0.1.0",
    )

    assert len(P.encode_status(snapshot)) <= P.STATUS_NOTIFICATION_LIMIT


def test_the_last_command_outcome_rides_along_with_the_status():
    result = P.CommandResult(
        command=P.CMD_WIFI_SCAN, ok=False, message="That password was not accepted."
    )

    _, decoded = P.decode_status(P.encode_status(Snapshot(), result))

    assert decoded == result


def test_the_app_can_name_the_output_without_being_told():
    # Headphones: the name is the headset's. Speaker: the app supplies the word.
    snapshot = Snapshot(
        output_target=OutputTarget.HEADPHONES,
        headset_name="Sony WH-1000XM5",
        headset_connected=True,
    )
    decoded, _ = P.decode_status(P.encode_status(snapshot))

    assert decoded.output_target is OutputTarget.HEADPHONES
    assert decoded.headset_name == "Sony WH-1000XM5"


def test_an_over_long_name_is_clipped_rather_than_allowed_to_fragment():
    long_name = "A Really Quite Long Headphone Name Special Edition Mark Two"
    decoded, _ = P.decode_status(P.encode_status(Snapshot(headset_name=long_name)))

    assert decoded.headset_name != long_name
    assert decoded.headset_name.startswith("A Really Quite Long Headphone Name")
    assert decoded.headset_name.endswith("\u2026")


def test_the_status_stays_inside_one_packet_even_with_absurd_input():
    snapshot = Snapshot(
        output_name="x" * 500,
        headset_name="y" * 500,
        error="z" * 500,
        firmware="0.1.0-beta.41+build.12345",
    )

    assert len(P.encode_status(snapshot)) <= P.STATUS_NOTIFICATION_LIMIT


def test_scan_results_round_trip():
    entries = [{"ssid": "Kitchen", "signal": 71, "secured": True}]
    kind, decoded = P.decode_discovery(P.encode_discovery("wifi", entries))

    assert kind == "wifi"
    assert decoded == entries


# ------------------------------------------------------------------- commands


def test_start_and_stop_decode():
    assert P.decode_command(cbor2.dumps({"c": "start"})).name == P.CMD_START
    assert P.decode_command(cbor2.dumps({"c": "stop"})).name == P.CMD_STOP


def test_choosing_an_output_decodes_to_a_real_target():
    command = P.decode_command(cbor2.dumps({"c": "set_output", "t": "headphones"}))
    assert command.target is OutputTarget.HEADPHONES


def test_an_output_this_device_does_not_have_is_refused():
    with pytest.raises(P.ProtocolError, match="audio output"):
        P.decode_command(cbor2.dumps({"c": "set_output", "t": "hdmi"}))


def test_the_headset_microphone_switch_must_be_on_or_off():
    assert P.decode_command(cbor2.dumps({"c": "set_headset_mic", "on": True})).enabled is True
    with pytest.raises(P.ProtocolError):
        P.decode_command(cbor2.dumps({"c": "set_headset_mic", "on": "yes"}))


def test_connecting_headphones_needs_an_address():
    assert P.decode_command(cbor2.dumps({"c": "bt_connect", "a": "AA:BB:CC:DD:EE:FF"})).address
    with pytest.raises(P.ProtocolError):
        P.decode_command(cbor2.dumps({"c": "bt_connect"}))


def test_an_unknown_command_is_refused_rather_than_ignored():
    # A newer app talking to an older appliance deserves a real answer instead of
    # silence it has to time out on.
    with pytest.raises(P.ProtocolError, match="does not understand"):
        P.decode_command(cbor2.dumps({"c": "self_destruct"}))


def test_a_malformed_frame_is_refused_without_raising_something_unreadable():
    with pytest.raises(P.ProtocolError, match="could not be read"):
        P.decode_command(b"\xff\xff not cbor")
    with pytest.raises(P.ProtocolError, match="could not be read"):
        P.decode_command(cbor2.dumps(["start"]))


def test_an_over_long_name_is_refused():
    with pytest.raises(P.ProtocolError, match="too long"):
        P.decode_command(cbor2.dumps({"c": "rename", "n": "x" * (P.MAX_NAME_LENGTH + 1)}))


# ---------------------------------------------------------------- provisioning


def test_setup_carries_everything_needed_to_join_and_upload():
    payload = cbor2.dumps(
        {
            "url": "https://recall.example.com/",
            "key": "nrk_ab12cd_secret",
            "ssid": "Kitchen",
            "psk": "hunter2hunter2",
            "tz": "Europe/Berlin",
            "n": "Desk in the study",
        }
    )

    provisioning = P.decode_provisioning(payload)

    assert provisioning.backend_url == "https://recall.example.com"
    assert provisioning.api_key == "nrk_ab12cd_secret"
    assert provisioning.wifi_ssid == "Kitchen"
    assert provisioning.timezone == "Europe/Berlin"
    assert provisioning.tls_verify


def test_setup_without_a_server_address_is_refused():
    with pytest.raises(P.ProtocolError, match="address is missing"):
        P.decode_provisioning(cbor2.dumps({"key": "nrk_x"}))


def test_a_server_address_that_is_not_a_url_is_refused():
    with pytest.raises(P.ProtocolError, match="http"):
        P.decode_provisioning(cbor2.dumps({"url": "recall.example.com", "key": "nrk_x"}))


def test_setup_without_an_access_key_is_refused():
    with pytest.raises(P.ProtocolError, match="access key is missing"):
        P.decode_provisioning(cbor2.dumps({"url": "https://recall.example.com"}))


def test_setup_may_omit_wifi_for_a_device_that_already_has_a_network():
    provisioning = P.decode_provisioning(
        cbor2.dumps({"url": "https://recall.example.com", "key": "nrk_x"})
    )
    assert provisioning.wifi_ssid == ""


def test_the_status_carries_the_id_the_server_gave_the_appliance():
    # Without this the app cannot tell which row in the account's device list it
    # is looking at, and two appliances on one account become indistinguishable.
    snapshot = Snapshot(state=State.IDLE, device_id="44444444-4444-4444-8444-444444444444")

    decoded, _ = P.decode_status(P.encode_status(snapshot))

    assert decoded.device_id == "44444444-4444-4444-8444-444444444444"


def test_the_device_id_survives_when_everything_else_has_to_be_trimmed():
    # Identity outranks the tail of an error message: the shrinker may cut text,
    # never the field that says which device this is.
    snapshot = Snapshot(
        state=State.RECORDING,
        device_id="44444444-4444-4444-8444-444444444444",
        output_name="x" * 400,
        headset_name="y" * 400,
        error="z" * 400,
        firmware="0.1.0-beta.41+build.12345",
    )
    result = P.CommandResult(command=P.CMD_SET_HEADSET_MIC, ok=True, message="m" * 400)

    payload = P.encode_status(snapshot, result)

    assert len(payload) <= P.STATUS_NOTIFICATION_LIMIT
    decoded, _ = P.decode_status(payload)
    assert decoded.device_id == "44444444-4444-4444-8444-444444444444"
