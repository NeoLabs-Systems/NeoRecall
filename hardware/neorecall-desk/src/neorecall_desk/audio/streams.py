"""Audio input as restartable subprocesses.

Capture runs through ``pw-record`` rather than a Python audio binding. That is a
deliberate trade: PipeWire already owns resampling, device selection and format
conversion, and a subprocess that dies is trivially observable and trivially
restarted. A crashed binding inside our own process would take the recorder with
it.

Two streams matter:

* the **near** side — the microphone, after echo cancellation, which also acts as
  the clock for the whole recording;
* the **far** side — whatever the laptop is sending over USB, which is present
  only while the laptop is actually playing something.
"""

from __future__ import annotations

import fcntl
import logging
import os
import subprocess
import threading
from typing import Protocol

from ..config import CHANNELS, SAMPLE_RATE

LOG = logging.getLogger(__name__)

PW_RECORD = "pw-record"

# PipeWire node names created by the configuration in ``pipewire/``. They are
# stable because we name them ourselves; nothing here depends on ALSA card
# ordering, which is exactly the kind of detail a user must never have to know
# about.
#
# Each is overridable through the environment so hardware bring-up can correct a
# name without rebuilding an image — the one place where a wrong guess is both
# likely and cheap to fix.
NODE_NEAR = os.environ.get("NEORECALL_NODE_NEAR", "neorecall.capture.near")

#: The far side is read from the USB gadget's own capture node rather than from
#: a virtual source built on top of it.
#:
#: There used to be a ``neorecall.capture.far`` virtual source, and on real
#: hardware it sat permanently suspended: every ``pw-record`` against it failed
#: with "no more input formats", at any rate and any format. Because the capture
#: process discarded its stderr, nothing said so — recordings simply arrived at
#: the server with the microphone on them and the computer's side missing.
#: Resolved at runtime because the gadget's node name contains the SoC's USB
#: address, which differs between Pi models.
NODE_FAR = os.environ.get("NEORECALL_NODE_FAR", "")
NODE_RELAY_OUT = os.environ.get("NEORECALL_NODE_RELAY_OUT", "neorecall.relay.out")


class AudioStream(Protocol):
    def start(self) -> None: ...
    def stop(self) -> None: ...
    def read(self, size: int) -> bytes | None: ...
    def read_available(self, limit: int) -> bytes: ...
    @property
    def alive(self) -> bool: ...


def far_side_target() -> str:
    """Which node carries the computer's side of the conversation.

    Reuses the relay's endpoint discovery rather than repeating the matching
    rules: there is one definition of "which node is the USB gadget", and both
    the relay and the recorder read it.
    """
    if NODE_FAR:
        return NODE_FAR
    from .relay import _nodes, find_endpoints

    return find_endpoints(_nodes())["from_computer"]


class PwRecordStream:
    """One ``pw-record`` process reading raw signed 16-bit PCM from a node."""

    def __init__(
        self,
        target: str,
        *,
        sample_rate: int = SAMPLE_RATE,
        channels: int = CHANNELS,
        blocking: bool = True,
        launcher=subprocess.Popen,
    ) -> None:
        self._target = target
        self._sample_rate = sample_rate
        self._channels = channels
        self._blocking = blocking
        self._launcher = launcher
        self._process: subprocess.Popen | None = None
        self._lock = threading.Lock()

    @property
    def target(self) -> str:
        return self._target

    def _argv(self) -> list[str]:
        return [
            PW_RECORD,
            "--target",
            self._target,
            "--rate",
            str(self._sample_rate),
            "--channels",
            str(self._channels),
            "--format",
            "s16",
            "--latency",
            "20ms",
            "-",
        ]

    def start(self) -> None:
        with self._lock:
            if self._process is not None and self._process.poll() is None:
                return
            # stderr is kept, not discarded. A capture stream that cannot open
            # says exactly why — "no more input formats" was printed on every
            # attempt for weeks, straight into /dev/null, while recordings went
            # to the server missing half the conversation.
            self._process = self._launcher(
                self._argv(), stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )
            if not self._blocking and self._process.stdout is not None:
                handle = self._process.stdout.fileno()
                flags = fcntl.fcntl(handle, fcntl.F_GETFL)
                fcntl.fcntl(handle, fcntl.F_SETFL, flags | os.O_NONBLOCK)
            self._watch_errors(self._process)

    def _watch_errors(self, process) -> None:
        """Drain the capture process's complaints into the log.

        Kept on its own thread because an unread pipe fills up and stalls the
        writer — the reason it was easier to discard it in the first place.
        """
        stream = getattr(process, "stderr", None)
        if stream is None:
            return

        def pump() -> None:
            try:
                for line in stream:
                    text = line.decode("utf-8", "replace").strip()
                    if text:
                        LOG.warning("%s: %s", self._target, text)
            except Exception:  # noqa: BLE001 - logging must not kill capture
                LOG.debug("could not read capture errors", exc_info=True)

        threading.Thread(target=pump, name="capture-errors", daemon=True).start()

    def stop(self) -> None:
        with self._lock:
            process, self._process = self._process, None
        if process is None:
            return
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)

    @property
    def alive(self) -> bool:
        process = self._process
        return process is not None and process.poll() is None

    def read(self, size: int) -> bytes | None:
        """Read exactly ``size`` bytes, or ``None`` if the stream ended."""
        process = self._process
        if process is None or process.stdout is None:
            return None
        buffer = bytearray()
        while len(buffer) < size:
            piece = process.stdout.read(size - len(buffer))
            if not piece:
                return None
            buffer.extend(piece)
        return bytes(buffer)

    def read_available(self, limit: int) -> bytes:
        """Read whatever is waiting, up to ``limit``, without blocking."""
        process = self._process
        if process is None or process.stdout is None:
            return b""
        try:
            piece = process.stdout.read(limit)
        except (BlockingIOError, InterruptedError):
            return b""
        return piece or b""
