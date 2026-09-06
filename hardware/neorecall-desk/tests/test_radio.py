"""Joining a network, and the two ways it lied to the owner.

Both were found while setting up a real device against a real router. The
appliance had been on that network before — as every shipped device will have
been, and as every device set up a second time is — so NetworkManager already
had a profile for it. ``nmcli device wifi connect`` then reused that profile,
ignored the password it had just been handed, and failed on the profile's own
missing settings. The app told the owner their correct password was wrong.
"""

from neorecall_desk.control import radio

SSID = "Frank-Router-2,4"


class FakeNmcli:
    """Records what was run and answers the way nmcli actually answers."""

    def __init__(self, *, profiles: dict[str, str] | None = None, fail: str = ""):
        self.profiles = profiles or {}
        self.fail = fail
        self.calls: list[list[str]] = []

    def __call__(self, argv: list[str]) -> tuple[int, str]:
        self.calls.append(argv)
        if argv[1:4] == ["-t", "-f", "NAME"]:
            return 0, "\n".join(self.profiles) + "\n"
        if argv[1:3] == ["-g", "802-11-wireless.ssid"]:
            return 0, self.profiles.get(argv[-1], "") + "\n"
        if self.fail:
            return 4, self.fail
        return 0, ""

    def ran(self, *fragment: str) -> bool:
        return any(list(fragment) == call[1 : 1 + len(fragment)] for call in self.calls)


def test_a_saved_profile_is_updated_rather_than_worked_around(monkeypatch):
    nmcli = FakeNmcli(profiles={"neorecall": SSID, "lo": ""})
    monkeypatch.setattr(radio, "_run", nmcli)

    ok, message = radio.join(SSID, "correct horse")

    assert ok and message == ""
    # The password goes into the profile that already exists, and that profile
    # is the one brought up. Handing it to `device wifi connect` would have
    # left the saved settings — and the failure — exactly as they were.
    assert nmcli.ran("connection", "modify", "neorecall")
    assert nmcli.ran("connection", "up", "neorecall")
    assert not nmcli.ran("device", "wifi", "connect")
    assert any("correct horse" in call for call in nmcli.calls)


def test_a_network_never_seen_before_is_joined_directly(monkeypatch):
    nmcli = FakeNmcli(profiles={"lo": ""})
    monkeypatch.setattr(radio, "_run", nmcli)

    ok, _ = radio.join("Somewhere Else", "hunter2")

    assert ok
    assert nmcli.ran("device", "wifi", "connect")


def test_a_fault_on_the_device_is_not_blamed_on_the_password(monkeypatch):
    # The exact text nmcli produced on the appliance. It mentions the security
    # setting, which an over-eager match read as "wrong password".
    nmcli = FakeNmcli(
        profiles={"neorecall": SSID},
        fail="Error: 802-11-wireless-security.key-mgmt: property is missing.",
    )
    monkeypatch.setattr(radio, "_run", nmcli)

    ok, message = radio.join(SSID, "the right password")

    assert not ok
    assert message == "Could not join that network."


def test_a_refused_password_still_says_so(monkeypatch):
    nmcli = FakeNmcli(profiles={}, fail="Error: Secrets were required, but not provided.")
    monkeypatch.setattr(radio, "_run", nmcli)

    ok, message = radio.join(SSID, "wrong")

    assert not ok
    assert message == "That password was not accepted."


def test_an_open_network_is_configured_without_a_key(monkeypatch):
    nmcli = FakeNmcli(profiles={"cafe": "Cafe Wifi"})
    monkeypatch.setattr(radio, "_run", nmcli)

    ok, _ = radio.join("Cafe Wifi", None)

    assert ok
    modify = next(call for call in nmcli.calls if call[1:3] == ["connection", "modify"])
    assert "none" in modify
    assert "802-11-wireless-security.psk" not in modify
