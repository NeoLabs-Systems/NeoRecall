"""One button, two meanings, and the timing edges between them."""

from neorecall_desk.control.button import DEBOUNCE_MS, LONG_PRESS_MS, ButtonEvent, ButtonReader


def press_and_release(reader, *, hold_ms, start_ms=0, step_ms=10):
    """Drive a clean press of a given length, returning every event it produced."""
    events = []
    at = start_ms
    while at <= start_ms + hold_ms:
        event = reader.update(True, at)
        if event:
            events.append(event)
        at += step_ms
    at = start_ms + hold_ms
    end = at + DEBOUNCE_MS + step_ms
    while at <= end:
        event = reader.update(False, at)
        if event:
            events.append(event)
        at += step_ms
    return events


def test_a_quick_press_toggles_recording():
    assert press_and_release(ButtonReader(), hold_ms=200) == [ButtonEvent.SHORT_PRESS]


def test_a_long_hold_opens_setup_and_does_not_also_toggle():
    events = press_and_release(ButtonReader(), hold_ms=LONG_PRESS_MS + 500)

    # Exactly one meaning per press: the user already heard the setup tone while
    # still holding, so releasing must not then start a recording.
    assert events == [ButtonEvent.LONG_PRESS]


def test_the_setup_tone_arrives_while_the_button_is_still_held():
    # The hold is measured from the moment the contact became stable, not from
    # the first noisy edge, so the threshold sits one debounce window later.
    reader = ButtonReader()
    at = 0
    while at <= LONG_PRESS_MS:
        assert reader.update(True, at) is None, f"fired too early at {at} ms"
        at += 10

    fired_at = None
    while at <= LONG_PRESS_MS + DEBOUNCE_MS + 40 and fired_at is None:
        if reader.update(True, at) is ButtonEvent.LONG_PRESS:
            fired_at = at
        at += 10

    assert fired_at is not None


def test_contact_bounce_does_not_produce_a_press():
    reader = ButtonReader()
    events = []
    # A noisy contact flapping faster than the debounce window.
    for at in range(0, 200, 5):
        event = reader.update(at % 10 == 0, at)
        if event:
            events.append(event)

    assert events == []


def test_two_separate_presses_produce_two_events():
    reader = ButtonReader()

    first = press_and_release(reader, hold_ms=200, start_ms=0)
    second = press_and_release(reader, hold_ms=200, start_ms=1000)

    assert first == [ButtonEvent.SHORT_PRESS]
    assert second == [ButtonEvent.SHORT_PRESS]


def test_a_hold_just_under_the_threshold_is_still_a_short_press():
    events = press_and_release(ButtonReader(), hold_ms=LONG_PRESS_MS - 200)
    assert events == [ButtonEvent.SHORT_PRESS]


def test_holding_far_past_the_threshold_still_opens_setup_only_once():
    events = press_and_release(ButtonReader(), hold_ms=LONG_PRESS_MS * 3)
    assert events == [ButtonEvent.LONG_PRESS]


class FakeV2Request:
    """libgpiod 2.x: a request object with per-offset values."""

    def __init__(self, values):
        self.values = values
        self.released = False

    def get_value(self, offset):
        class _Value:
            def __init__(self, v):
                self.value = v

        return _Value(self.values[offset])

    def release(self):
        self.released = True


class FakeV2Module:
    LINE_REQ_DIR_IN = 1

    def __init__(self, values):
        self._values = values
        self.request = None
        self.line = _fake_line_module()

    def LineSettings(self, **kwargs):  # noqa: N802 - mirrors the real API
        return kwargs

    def request_lines(self, chip, consumer, config):
        self.request = FakeV2Request(self._values)
        return self.request


class FakeV1Line:
    def __init__(self, value):
        self.value = value
        self.released = False
        self.requested = None

    def request(self, **kwargs):
        self.requested = kwargs

    def get_value(self):
        return self.value

    def release(self):
        self.released = True


class FakeV1Chip:
    def __init__(self, line):
        self._line = line
        self.closed = False

    def get_line(self, offset):
        return self._line

    def close(self):
        self.closed = True


class FakeV1Module:
    """libgpiod 1.6, which is what Raspberry Pi OS Bookworm ships."""

    LINE_REQ_DIR_IN = 1
    LINE_REQ_FLAG_BIAS_PULL_UP = 8

    def __init__(self, value):
        self.line = FakeV1Line(value)
        self.chip = None

    def Chip(self, path):  # noqa: N802 - mirrors the real API
        self.chip = FakeV1Chip(self.line)
        return self.chip


def _fake_line_module():
    import types

    module = types.SimpleNamespace()
    module.Bias = types.SimpleNamespace(PULL_UP="pull-up", PULL_DOWN="pull-down")
    module.Direction = types.SimpleNamespace(INPUT="input")
    return module


def install(monkeypatch, module):
    import sys
    import types

    monkeypatch.setitem(sys.modules, "gpiod", module)
    if hasattr(module, "line"):
        monkeypatch.setitem(sys.modules, "gpiod.line", module.line)
    else:
        monkeypatch.setitem(sys.modules, "gpiod.line", types.SimpleNamespace())


def test_the_button_works_with_the_libgpiod_the_pi_actually_ships(monkeypatch):
    # Bookworm has libgpiod 1.6 and its original API. A button that only speaks
    # 2.x is a button that does nothing on the hardware in front of us.
    module = FakeV1Module(value=0)  # active-low: 0 means pressed
    install(monkeypatch, module)

    from neorecall_desk.control.button import GpioButton

    line = GpioButton(lambda event: None)._claim()

    assert line is not None
    assert line.pressed() is True
    assert module.line.requested["type"] == FakeV1Module.LINE_REQ_DIR_IN
    assert module.line.requested["flags"] == FakeV1Module.LINE_REQ_FLAG_BIAS_PULL_UP


def test_the_button_also_works_with_the_newer_api(monkeypatch):
    module = FakeV2Module({17: 1})  # active-low: 1 means released
    install(monkeypatch, module)

    from neorecall_desk.control.button import GpioButton

    line = GpioButton(lambda event: None, line=17)._claim()

    assert line is not None
    assert line.pressed() is False


def test_releasing_a_line_closes_the_chip_too(monkeypatch):
    module = FakeV1Module(value=1)
    install(monkeypatch, module)

    from neorecall_desk.control.button import GpioButton

    line = GpioButton(lambda event: None)._claim()
    line.release()

    assert module.line.released
    assert module.chip.closed


def test_no_gpio_at_all_disables_the_button_instead_of_the_appliance(monkeypatch):
    import sys

    monkeypatch.setitem(sys.modules, "gpiod", None)

    from neorecall_desk.control.button import GpioButton

    # Importing a None module raises ImportError, which is the "not installed"
    # path. The appliance is still a perfectly good recorder without a button.
    assert GpioButton(lambda event: None)._claim() is None


def test_a_line_another_process_already_owns_disables_the_button(monkeypatch):
    class Busy(FakeV1Module):
        def Chip(self, path):  # noqa: N802
            raise OSError(16, "Device or resource busy")

    install(monkeypatch, Busy(value=1))

    from neorecall_desk.control.button import GpioButton

    assert GpioButton(lambda event: None)._claim() is None
