"""The D-Bus runtime, and the mistake that cost a whole bring-up round.

dbus-fast calls ``asyncio.get_running_loop()`` inside ``MessageBus.__init__``.
Constructing the bus outside the loop and merely awaiting the result there fails
with "no running event loop" — and it fails *quietly*: the appliance starts, the
audio graph comes up, the service reports healthy, and the app simply never finds
the device. These tests pin the construction site.
"""

import asyncio
import sys
import types

import pytest

from neorecall_desk.control import bluez


class FakeBus:
    def __init__(self):
        self.connected = False

    async def connect(self):
        self.connected = True
        return self


def install_fake_dbus(monkeypatch, record):
    """A dbus-fast that behaves like the real one: needs a running loop."""

    class MessageBus:
        def __init__(self, bus_type=None):
            # Exactly what the real library does, and the whole point of the test.
            record["loop_at_construction"] = asyncio.get_running_loop()
            self._bus = FakeBus()

        async def connect(self):
            return await self._bus.connect()

    aio = types.SimpleNamespace(MessageBus=MessageBus)
    root = types.ModuleType("dbus_fast")
    root.BusType = types.SimpleNamespace(SYSTEM="system", SESSION="session")
    root.aio = aio
    monkeypatch.setitem(sys.modules, "dbus_fast", root)
    monkeypatch.setitem(sys.modules, "dbus_fast.aio", aio)


def test_the_bus_is_built_inside_the_running_loop(monkeypatch):
    record = {}
    install_fake_dbus(monkeypatch, record)

    runtime = bluez.BluezRuntime()
    try:
        runtime.start()
        assert runtime.running
        # If the bus were constructed before the loop started, this would never
        # have been reached: the constructor would have raised.
        assert record["loop_at_construction"] is not None
    finally:
        runtime.stop()


def test_a_missing_dbus_library_is_reported_not_raised(monkeypatch):
    # A Pi with no Bluetooth stack is still a recorder. The runtime has to say so
    # in a way the service can catch, rather than dying on an import.
    monkeypatch.setitem(sys.modules, "dbus_fast", None)

    runtime = bluez.BluezRuntime()
    with pytest.raises(bluez.BluetoothUnavailable):
        runtime.start()
    runtime.stop()


def test_running_a_coroutine_before_start_is_refused_cleanly(monkeypatch):
    record = {}
    install_fake_dbus(monkeypatch, record)
    runtime = bluez.BluezRuntime()

    async def nothing():
        return 1

    with pytest.raises(bluez.BluetoothUnavailable):
        runtime.run(nothing())


def test_the_bus_is_unreachable_before_start():
    with pytest.raises(bluez.BluetoothUnavailable):
        _ = bluez.BluezRuntime().bus


def test_stopping_a_runtime_that_never_started_is_harmless():
    bluez.BluezRuntime().stop()


def test_a_coroutine_runs_on_the_bus_thread(monkeypatch):
    record = {}
    install_fake_dbus(monkeypatch, record)
    runtime = bluez.BluezRuntime()
    runtime.start()
    try:

        async def where():
            return asyncio.get_running_loop()

        # Same loop the bus was built on: one thread, one loop, one connection.
        assert runtime.run(where()) is record["loop_at_construction"]
    finally:
        runtime.stop()


def test_a_call_from_the_bus_thread_is_refused_rather_than_deadlocked():
    """Found on hardware: setup timed out with no explanation.

    Reading the GATT status characteristic runs on the D-Bus thread, and that
    status included "which headset is connected", which asked BlueZ. The answer
    had to come back through the very loop that was blocked waiting for it, so
    the call could only ever reach its timeout — ten silent seconds, a
    TimeoutError in the journal, and a pairing that never completed.
    """
    import threading

    runtime = bluez.BluezRuntime()

    async def _probe():  # pragma: no cover - reached only if the guard fails
        return "never produced"

    runtime._thread = threading.current_thread()
    runtime._loop = asyncio.new_event_loop()
    try:
        with pytest.raises(bluez.BluetoothUnavailable, match="Bluetooth thread itself"):
            runtime.run(_probe())
    finally:
        runtime._loop.close()
