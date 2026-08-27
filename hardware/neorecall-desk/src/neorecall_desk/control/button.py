"""The one physical control.

Two meanings, both chosen to be hard to get wrong without a screen:

* a **short press** starts or stops recording;
* a **long press** puts the appliance back into setup mode.

The long press fires the moment the threshold is crossed, while the button is
still held, so the confirming tone tells the user they can let go. Firing on
release instead would leave them holding a button and guessing.

The classifier is pure — it is handed "pressed or not, at this millisecond" —
so every timing edge is testable without a GPIO line.
"""

from __future__ import annotations

import logging
import os
import threading
import time
from collections.abc import Callable
from enum import StrEnum

LOG = logging.getLogger(__name__)

DEFAULT_GPIO_CHIP = os.environ.get("NEORECALL_BUTTON_CHIP", "/dev/gpiochip0")
#: The user button on the Waveshare WM8960 Audio HAT. Verified during hardware
#: bring-up; overridable so a different HAT revision costs a setting rather than
#: a new image.
DEFAULT_GPIO_LINE = int(os.environ.get("NEORECALL_BUTTON_LINE", "17"))

DEBOUNCE_MS = 40
LONG_PRESS_MS = 5000
POLL_INTERVAL_S = 0.02
CONSUMER = "neorecall-desk"


class ButtonEvent(StrEnum):
    SHORT_PRESS = "short_press"
    LONG_PRESS = "long_press"


class ButtonReader:
    """Debounces a raw contact and classifies presses."""

    def __init__(
        self, *, debounce_ms: int = DEBOUNCE_MS, long_press_ms: int = LONG_PRESS_MS
    ) -> None:
        self._debounce_ms = debounce_ms
        self._long_press_ms = long_press_ms
        self._stable = False
        self._candidate = False
        self._candidate_since: int | None = None
        self._pressed_at: int | None = None
        self._long_fired = False

    def update(self, pressed: bool, at_ms: int) -> ButtonEvent | None:
        if pressed != self._candidate:
            self._candidate = pressed
            self._candidate_since = at_ms
        elif (
            self._candidate_since is not None and at_ms - self._candidate_since >= self._debounce_ms
        ):
            if self._candidate != self._stable:
                self._stable = self._candidate
                self._candidate_since = None
                return self._on_edge(at_ms)
            self._candidate_since = None

        if self._stable and not self._long_fired and self._pressed_at is not None:
            if at_ms - self._pressed_at >= self._long_press_ms:
                self._long_fired = True
                return ButtonEvent.LONG_PRESS
        return None

    def _on_edge(self, at_ms: int) -> ButtonEvent | None:
        if self._stable:
            self._pressed_at = at_ms
            self._long_fired = False
            return None
        was_long = self._long_fired
        self._pressed_at = None
        self._long_fired = False
        # A release that already produced a long press must not also produce a
        # short one; the user got their answer while still holding the button.
        return None if was_long else ButtonEvent.SHORT_PRESS


class GpioButton:
    """Polls a GPIO line and turns it into button events."""

    def __init__(
        self,
        on_event: Callable[[ButtonEvent], None],
        *,
        chip: str = DEFAULT_GPIO_CHIP,
        line: int = DEFAULT_GPIO_LINE,
        active_low: bool = True,
        poll_interval_s: float = POLL_INTERVAL_S,
    ) -> None:
        self._on_event = on_event
        self._chip = chip
        self._line = line
        self._active_low = active_low
        self._poll = poll_interval_s
        self._reader = ButtonReader()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._run, name="button", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2)
            self._thread = None

    def _run(self) -> None:
        line = self._claim()
        if line is None:
            return
        try:
            while not self._stop.is_set():
                event = self._reader.update(line.pressed(), int(time.monotonic() * 1000))
                if event is not None:
                    # Logged because the button is the only input this device
                    # has, and "I pressed it and nothing happened" is otherwise
                    # impossible to tell apart from a press that never reached
                    # the line. One line per press makes that answerable from
                    # the journal, long after the fact.
                    LOG.info("button %s", event.value if hasattr(event, "value") else event)
                    try:
                        self._on_event(event)
                    except Exception:  # noqa: BLE001 - a handler must not kill the button
                        LOG.exception("button handler failed")
                self._stop.wait(self._poll)
        finally:
            line.release()

    def _claim(self) -> _Line | None:
        """Open the button line through whichever libgpiod is installed.

        Debian Bookworm — what a Raspberry Pi OS image of this vintage ships —
        has libgpiod 1.6 and its original Python API. Newer systems have 2.x,
        which is a different API entirely. Supporting both is the difference
        between a button that works on the hardware in front of us and one that
        works on a machine we do not have.
        """
        try:
            import gpiod
        except ImportError:
            LOG.warning("GPIO support is unavailable; the hardware button is disabled")
            return None

        try:
            if hasattr(gpiod, "request_lines"):
                return _LibgpiodV2(gpiod, self._chip, self._line, self._active_low)
            return _LibgpiodV1(gpiod, self._chip, self._line, self._active_low)
        except OSError:
            LOG.exception("could not claim the button line; the hardware button is disabled")
            return None
        except Exception:  # noqa: BLE001 - an unfamiliar binding must not stop the appliance
            LOG.exception("this libgpiod build is not one the button understands")
            return None


class _Line:
    """One claimed input line, normalised to "is the button down?"."""

    def __init__(self, active_low: bool) -> None:
        self._active_low = active_low

    def _normalise(self, raw: int) -> bool:
        return (not raw) if self._active_low else bool(raw)

    def pressed(self) -> bool:  # pragma: no cover - overridden
        raise NotImplementedError

    def release(self) -> None:  # pragma: no cover - overridden
        raise NotImplementedError


class _LibgpiodV2(_Line):
    def __init__(self, gpiod, chip: str, offset: int, active_low: bool) -> None:
        super().__init__(active_low)
        from gpiod.line import Bias, Direction

        self._offset = offset
        settings = gpiod.LineSettings(
            direction=Direction.INPUT,
            bias=Bias.PULL_UP if active_low else Bias.PULL_DOWN,
        )
        self._request = gpiod.request_lines(chip, consumer=CONSUMER, config={offset: settings})

    def pressed(self) -> bool:
        return self._normalise(int(self._request.get_value(self._offset).value))

    def release(self) -> None:
        self._request.release()


class _LibgpiodV1(_Line):
    def __init__(self, gpiod, chip: str, offset: int, active_low: bool) -> None:
        super().__init__(active_low)
        self._chip = gpiod.Chip(chip)
        self._line = self._chip.get_line(offset)
        flag = getattr(
            gpiod,
            "LINE_REQ_FLAG_BIAS_PULL_UP" if active_low else "LINE_REQ_FLAG_BIAS_PULL_DOWN",
            0,
        )
        self._line.request(consumer=CONSUMER, type=gpiod.LINE_REQ_DIR_IN, flags=flag)

    def pressed(self) -> bool:
        return self._normalise(int(self._line.get_value()))

    def release(self) -> None:
        try:
            self._line.release()
        finally:
            self._chip.close()
