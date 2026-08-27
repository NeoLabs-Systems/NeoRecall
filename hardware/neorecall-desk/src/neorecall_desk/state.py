"""The appliance state machine.

The device has no display, so its state has to be unambiguous to three different
audiences at once: the app over Bluetooth, the person pressing the button, and
the next boot after a power cut. Keeping the whole thing in one small, pure
machine is what makes those three agree.

Transitions are deliberately few. Everything else the appliance does — relaying
audio, holding a Bluetooth headset, draining the upload queue — happens
regardless of which state it is in, and therefore is not modelled as one.
"""

from __future__ import annotations

import threading
from collections.abc import Callable
from dataclasses import dataclass, field
from enum import StrEnum


class State(StrEnum):
    #: Flashed but never set up: no account, no server, nothing to upload to.
    UNCONFIGURED = "unconfigured"
    #: Ready. Audio relay runs, the upload queue drains, nothing is being recorded.
    IDLE = "idle"
    #: Capturing. The Wi-Fi radio is down so Bluetooth audio has the air to itself.
    RECORDING = "recording"


class MicSource(StrEnum):
    BUILT_IN = "built_in"
    HEADSET = "headset"


class OutputTarget(StrEnum):
    SPEAKER = "speaker"
    HEADPHONES = "headphones"


class TransitionRefused(RuntimeError):
    """A transition that would have been a lie about what the hardware is doing."""


@dataclass(frozen=True)
class Snapshot:
    """Everything the app needs to render the device, and nothing it does not.

    No device node names, no IP addresses, no log lines: whatever ends up here
    has to survive being shown to somebody who has never opened a terminal.
    """

    state: State = State.UNCONFIGURED
    recording_elapsed_ms: int = 0
    pending_chunks: int = 0
    needs_attention: int = 0
    output_target: OutputTarget = OutputTarget.SPEAKER
    output_name: str = ""
    mic_source: MicSource = MicSource.BUILT_IN
    headset_connected: bool = False
    headset_name: str = ""
    headset_battery: int | None = None
    network_online: bool = False
    authentication_failed: bool = False
    device_revoked: bool = False
    error: str = ""
    firmware: str = ""
    #: The id the server gave this appliance. It is what lets the app match the
    #: device it is talking to over Bluetooth against the row in the account's
    #: device list — without it, two appliances on one account are
    #: indistinguishable. Empty until the appliance has registered.
    device_id: str = ""

    #: What the software is doing about itself. Kept as a short word rather than
    #: a set of flags so the app can show it without translating anything.
    update_state: str = "idle"
    auto_update: bool = True

    @property
    def recording(self) -> bool:
        return self.state is State.RECORDING

    @property
    def syncing(self) -> bool:
        return self.state is State.IDLE and self.pending_chunks > 0 and self.network_online


@dataclass
class _Machine:
    state: State = State.UNCONFIGURED
    listeners: list[Callable[[State, State], None]] = field(default_factory=list)


class StateMachine:
    """Guards the three transitions that actually change what the hardware does."""

    def __init__(self, *, configured: bool = False) -> None:
        self._lock = threading.RLock()
        self._m = _Machine(state=State.IDLE if configured else State.UNCONFIGURED)

    @property
    def state(self) -> State:
        with self._lock:
            return self._m.state

    def on_change(self, listener: Callable[[State, State], None]) -> None:
        with self._lock:
            self._m.listeners.append(listener)

    def _move(self, target: State) -> State:
        previous = self._m.state
        if previous is target:
            return target
        self._m.state = target
        for listener in list(self._m.listeners):
            listener(previous, target)
        return target

    def configured(self) -> State:
        """The app finished provisioning."""
        with self._lock:
            if self._m.state is State.UNCONFIGURED:
                return self._move(State.IDLE)
            return self._m.state

    def unconfigured(self) -> State:
        """The account link was removed, or the server rejected our credentials.

        A recording in flight is stopped first: continuing to capture for an
        account the appliance can no longer reach would fill the card with audio
        nobody can collect.
        """
        with self._lock:
            return self._move(State.UNCONFIGURED)

    def start(self) -> State:
        with self._lock:
            if self._m.state is State.UNCONFIGURED:
                # Refusing is the honest answer. Recording into a device that has
                # no account has no destination and no way to tell anyone, and it
                # would leave audio sitting on an SD card indefinitely.
                raise TransitionRefused("This device has not been set up yet.")
            if self._m.state is State.RECORDING:
                return self._m.state
            return self._move(State.RECORDING)

    def stop(self) -> State:
        with self._lock:
            if self._m.state is not State.RECORDING:
                return self._m.state
            return self._move(State.IDLE)

    def toggle(self) -> State:
        """What the hardware button does. One press, one meaning."""
        with self._lock:
            return self.stop() if self._m.state is State.RECORDING else self.start()
