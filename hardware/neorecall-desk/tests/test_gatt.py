"""The shape of the Bluetooth service, pinned.

These signatures are string annotations that dbus-fast reads at run time. A
formatter that "helpfully" unquotes them, or a stray
``from __future__ import annotations``, turns every one of them into something
BlueZ rejects — and the failure is silent until a phone tries to connect. That is
what this file exists to catch.
"""

import pytest

pytest.importorskip("dbus_fast")

from dbus_fast.service import ServiceInterface  # noqa: E402

from neorecall_desk.control import gatt, protocol  # noqa: E402
from neorecall_desk.state import Snapshot, State  # noqa: E402


def signatures(interface):
    methods = ServiceInterface._get_methods(interface)
    return {m.name: (m.in_signature, m.out_signature) for m in methods}


def properties(interface):
    return {p.name: p.signature for p in ServiceInterface._get_properties(interface)}


@pytest.fixture()
def characteristic():
    return gatt._Characteristic(
        "/x", protocol.STATUS_UUID, ["read", "notify"], on_read=lambda: b"hello"
    )


def test_a_characteristic_exposes_the_methods_bluez_calls(characteristic):
    assert signatures(characteristic) == {
        "ReadValue": ("a{sv}", "ay"),
        "WriteValue": ("aya{sv}", ""),
        "StartNotify": ("", ""),
        "StopNotify": ("", ""),
    }


def test_a_characteristic_exposes_the_properties_bluez_reads(characteristic):
    assert properties(characteristic) == {
        "UUID": "s",
        "Service": "o",
        "Flags": "as",
        "Value": "ay",
    }


def test_the_service_and_advertisement_signatures_are_intact():
    assert properties(gatt._Service(protocol.SERVICE_UUID)) == {"UUID": "s", "Primary": "b"}
    assert properties(gatt._Advertisement("NeoRecall Desk")) == {
        "Type": "s",
        "ServiceUUIDs": "as",
        "LocalName": "s",
        "Includes": "as",
    }


def test_the_object_manager_returns_the_whole_tree():
    characteristic = gatt._Characteristic("/x", protocol.STATUS_UUID, ["read"])
    service = gatt._Service(protocol.SERVICE_UUID)
    application = gatt._Application(service, [characteristic])

    assert signatures(application) == {"GetManagedObjects": ("", "a{oa{sa{sv}}}")}

    tree = application.GetManagedObjects.__wrapped__(application)
    assert set(tree) == {gatt.SERVICE_PATH, "/x"}
    assert tree[gatt.SERVICE_PATH][gatt.GATT_SERVICE_IFACE]["UUID"].value == protocol.SERVICE_UUID


def test_writing_is_encrypted_and_reading_is_not_a_command_channel():
    server = gatt.GattServer(
        runtime=None,
        snapshot_provider=Snapshot,
        on_command=lambda command: protocol.CommandResult(command=command.name),
        on_provision=lambda provisioning: protocol.CommandResult(command="setup"),
    )

    flags = {c._uuid: c._flags for c in server._characteristics}
    assert flags[protocol.COMMAND_UUID] == ["encrypt-write"]
    assert flags[protocol.PROVISION_UUID] == ["encrypt-write"]
    assert flags[protocol.STATUS_UUID] == ["read", "notify"]
    assert flags[protocol.DISCOVERY_UUID] == ["read", "notify"]


def test_a_command_the_appliance_cannot_read_answers_instead_of_crashing():
    server = gatt.GattServer(
        runtime=None,
        snapshot_provider=lambda: Snapshot(state=State.IDLE),
        on_command=lambda command: protocol.CommandResult(command=command.name),
        on_provision=lambda provisioning: protocol.CommandResult(command="setup"),
    )

    server._write_command(b"\xff not cbor at all")

    _, result = protocol.decode_status(server._read_status())
    assert result is not None and not result.ok


def test_a_handler_that_throws_does_not_take_the_link_down():
    def explode(command):
        raise RuntimeError("something in the hardware")

    server = gatt.GattServer(
        runtime=None,
        snapshot_provider=lambda: Snapshot(state=State.IDLE),
        on_command=explode,
        on_provision=lambda provisioning: protocol.CommandResult(command="setup"),
    )

    import cbor2

    server._write_command(cbor2.dumps({"c": "start"}))
    # Commands are handled off the D-Bus thread now, so the write returns before
    # the handler has run.
    assert server.wait_until_idle()

    _, result = protocol.decode_status(server._read_status())
    assert result is not None and not result.ok
    assert result.message == "Something went wrong on the device."


def test_pairing_is_refused_unless_the_appliance_is_in_setup_mode():
    from dbus_fast import DBusError

    pairable = {"value": False}
    agent = gatt._PairingAgent(lambda: pairable["value"])

    with pytest.raises(DBusError):
        agent.RequestConfirmation.__wrapped__(agent, "/org/bluez/hci0/dev_X", 123456)

    pairable["value"] = True
    agent.RequestConfirmation.__wrapped__(agent, "/org/bluez/hci0/dev_X", 123456)


def test_a_command_never_runs_on_the_thread_that_delivered_it():
    """The bug this guards against cost a whole evening of bring-up.

    ``WriteValue`` runs on the D-Bus thread. Handlers legitimately talk to
    BlueZ — switching the output to headphones is exactly that — and a BlueZ
    call made from the D-Bus thread waits on the loop it is itself blocking.
    On hardware that surfaced as a ten-second silence, a ``TimeoutError`` in
    the journal, and setup that never completed.
    """
    import threading

    import cbor2

    ran_on: list[int] = []

    def record(command):
        ran_on.append(threading.get_ident())
        return protocol.CommandResult(command=command.name)

    server = gatt.GattServer(
        runtime=None,
        snapshot_provider=lambda: Snapshot(state=State.IDLE),
        on_command=record,
        on_provision=lambda provisioning: protocol.CommandResult(command="setup"),
    )

    server._write_command(cbor2.dumps({"c": "start"}))
    assert server.wait_until_idle()

    assert ran_on and ran_on[0] != threading.get_ident()
