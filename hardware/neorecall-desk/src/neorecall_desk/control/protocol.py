"""The wire format between the appliance and the NeoRecall app.

CBOR with short keys, because a BLE notification has to fit in one MTU and a
status update that fragments is a status update that arrives late. The encoding
is pure and lives here rather than inside the GATT server so the whole contract
can be tested — and evolved — without a radio.

Two rules shape everything below:

* the appliance never sends anything the app would have to translate for a human
  (no device nodes, no error codes, no log lines);
* the app never sends anything the appliance would have to trust blindly — every
  field is validated here before it reaches the hardware.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import cbor2

from ..state import MicSource, OutputTarget, Snapshot, State

PROTOCOL_VERSION = 1

#: 128-bit service and characteristic UUIDs. Fixed for the life of the product;
#: the app filters its scan on the service UUID.
SERVICE_UUID = "6e4d0001-9b3f-4f2a-8d21-1c7a5f0b9e11"
STATUS_UUID = "6e4d0002-9b3f-4f2a-8d21-1c7a5f0b9e11"
COMMAND_UUID = "6e4d0003-9b3f-4f2a-8d21-1c7a5f0b9e11"
PROVISION_UUID = "6e4d0004-9b3f-4f2a-8d21-1c7a5f0b9e11"
DISCOVERY_UUID = "6e4d0005-9b3f-4f2a-8d21-1c7a5f0b9e11"

ADVERTISED_NAME = "NeoRecall Desk"

#: Commands the appliance accepts. Anything else is refused rather than ignored,
#: so a newer app talking to an older appliance gets a real answer.
CMD_START = "start"
CMD_STOP = "stop"
CMD_SET_OUTPUT = "set_output"
CMD_SET_HEADSET_MIC = "set_headset_mic"
CMD_WIFI_SCAN = "wifi_scan"
CMD_BT_SCAN = "bt_scan"
CMD_BT_CONNECT = "bt_connect"
CMD_BT_DISCONNECT = "bt_disconnect"
CMD_BT_FORGET = "bt_forget"
CMD_RENAME = "rename"
CMD_FORGET_ACCOUNT = "forget_account"
CMD_UPDATE_NOW = "update_now"
CMD_SET_AUTO_UPDATE = "set_auto_update"
CMD_SELFTEST = "selftest"

#: Placeholder name used when a write could not even be parsed into a command.
#: A refusal still has to reach the app: silence would leave it waiting on a
#: notification that is never coming.
CMD_UNREADABLE = "unreadable"
CMD_SETUP = "setup"

KNOWN_COMMANDS = frozenset(
    {
        CMD_START,
        CMD_STOP,
        CMD_SET_OUTPUT,
        CMD_SET_HEADSET_MIC,
        CMD_WIFI_SCAN,
        CMD_BT_SCAN,
        CMD_BT_CONNECT,
        CMD_BT_DISCONNECT,
        CMD_BT_FORGET,
        CMD_RENAME,
        CMD_FORGET_ACCOUNT,
        CMD_UPDATE_NOW,
        CMD_SET_AUTO_UPDATE,
        CMD_SELFTEST,
    }
)

MAX_NAME_LENGTH = 100

#: A status notification has to fit in one ATT packet at the 247-byte MTU the app
#: negotiates, because a status update that fragments is a status update that
#: arrives late — and this one is sent on every state change. Everything else in
#: the payload is fixed-size, so the three free-text fields are what has to be
#: bounded. These caps are generous for real headphone names and for the short
#: sentences the appliance actually produces.
MAX_STATUS_NAME = 40
MAX_STATUS_ERROR = 96
STATUS_NOTIFICATION_LIMIT = 244
#: The one free-text field a discovery entry carries. Long enough for the
#: sentences the self-test writes, short enough that a single verdict always
#: fits in a packet of its own.
MAX_DISCOVERY_DETAIL = 160
MAX_SSID_LENGTH = 64
MAX_SECRET_LENGTH = 256
MAX_URL_LENGTH = 512


class ProtocolError(ValueError):
    """A message the appliance refuses to act on, with a reason worth showing."""


@dataclass(frozen=True)
class CommandResult:
    """The outcome of the last command, echoed back in the status notification."""

    command: str = ""
    ok: bool = True
    message: str = ""


@dataclass(frozen=True)
class Command:
    name: str
    address: str = ""
    target: OutputTarget | None = None
    enabled: bool | None = None
    text: str = ""


@dataclass(frozen=True)
class Provisioning:
    backend_url: str
    api_key: str
    wifi_ssid: str = ""
    wifi_password: str = ""
    timezone: str = ""
    device_name: str = ""
    tls_verify: bool = True


# ------------------------------------------------------------------- outbound


def _clip(value: str, limit: int) -> str:
    if limit <= 0:
        return ""
    if len(value) <= limit:
        return value
    return value[: max(1, limit - 1)].rstrip() + "\u2026"


def encode_status(snapshot: Snapshot, result: CommandResult | None = None) -> bytes:
    payload: dict[str, Any] = {
        "v": PROTOCOL_VERSION,
        "st": snapshot.state.value,
        "el": int(snapshot.recording_elapsed_ms),
        "pc": int(snapshot.pending_chunks),
        "na": int(snapshot.needs_attention),
        "out": snapshot.output_target.value,
        # The output's *name* is deliberately not sent. When the output is
        # headphones it is the headset name, which is already here; when it is
        # the speaker it is the word "Speaker", which the app can write itself.
        # Sending it twice cost about twenty bytes of a packet that has none to
        # spare, and it was the field the shrinker sacrificed first.
        "mic": snapshot.mic_source.value,
        "hc": bool(snapshot.headset_connected),
        "hn": _clip(snapshot.headset_name, MAX_STATUS_NAME),
        "hb": snapshot.headset_battery,
        "net": bool(snapshot.network_online),
        "auth": bool(snapshot.authentication_failed),
        "rev": bool(snapshot.device_revoked),
        "err": _clip(snapshot.error, MAX_STATUS_ERROR),
        "fw": snapshot.firmware,
        "did": snapshot.device_id,
    }
    # Software state, sent only when it differs from the quiet case. Carrying
    # "idle" and "on" in every notification cost eighteen bytes that the packet
    # does not have — and the shrinker paid for them by cutting the headset name,
    # which a user reads far more often than an update state.
    if snapshot.update_state != "idle":
        payload["upd"] = snapshot.update_state
    if not snapshot.auto_update:
        payload["auto"] = False
    if result is not None and result.command:
        payload["res"] = {
            "c": result.command,
            "ok": result.ok,
            "m": _clip(result.message, MAX_STATUS_ERROR),
        }
    return _fit(payload)


def _fit(payload: dict[str, Any]) -> bytes:
    """Shrink the free-text fields until the notification fits one packet.

    Clipping each field to a fixed cap is not enough on its own — three long
    fields together still overflow, and a future field would break the
    arithmetic silently. Measuring and shrinking is the version that stays true
    as the payload grows.
    """
    encoded = cbor2.dumps(payload)
    if len(encoded) <= STATUS_NOTIFICATION_LIMIT:
        return encoded

    # Least to most important. The ambient error goes first: its substance is
    # already carried by the counters and the two account flags, so trimming its
    # wording loses the least. The outcome message goes last, because it is the
    # direct answer to something the user just did and there is nothing else in
    # the payload that says it.
    for key in ("err", "hn", "res"):
        while len(encoded) > STATUS_NOTIFICATION_LIMIT:
            if key == "res":
                message = payload.get("res", {}).get("m", "")
                if not message:
                    break
                payload["res"]["m"] = _clip(message, max(0, len(message) - 16))
            else:
                value = payload.get(key, "")
                if not value:
                    break
                payload[key] = _clip(value, max(0, len(value) - 16))
            encoded = cbor2.dumps(payload)
        if len(encoded) <= STATUS_NOTIFICATION_LIMIT:
            return encoded
    return encoded


def decode_status(payload: bytes) -> tuple[Snapshot, CommandResult | None]:
    """Decode a status notification. Used by the tests and by protocol tooling."""
    raw = cbor2.loads(payload)
    if not isinstance(raw, dict):
        raise ProtocolError("status payload is not a map")
    snapshot = Snapshot(
        state=State(raw.get("st", State.UNCONFIGURED.value)),
        recording_elapsed_ms=int(raw.get("el", 0)),
        pending_chunks=int(raw.get("pc", 0)),
        needs_attention=int(raw.get("na", 0)),
        output_target=OutputTarget(raw.get("out", OutputTarget.SPEAKER.value)),
        mic_source=MicSource(raw.get("mic", MicSource.BUILT_IN.value)),
        headset_connected=bool(raw.get("hc", False)),
        headset_name=str(raw.get("hn", "")),
        headset_battery=raw.get("hb"),
        network_online=bool(raw.get("net", False)),
        authentication_failed=bool(raw.get("auth", False)),
        device_revoked=bool(raw.get("rev", False)),
        error=str(raw.get("err", "")),
        firmware=str(raw.get("fw", "")),
        device_id=str(raw.get("did", "")),
        update_state=str(raw.get("upd", "idle")),
        auto_update=raw.get("auto", True) is not False,
    )
    result_raw = raw.get("res")
    result = None
    if isinstance(result_raw, dict):
        result = CommandResult(
            command=str(result_raw.get("c", "")),
            ok=bool(result_raw.get("ok", True)),
            message=str(result_raw.get("m", "")),
        )
    return snapshot, result


def encode_discovery(kind: str, entries: list[dict], *, page: int = 0, pages: int = 1) -> bytes:
    """One page of scan results or check verdicts, already ordered for display."""
    return cbor2.dumps(
        {"v": PROTOCOL_VERSION, "k": kind, "e": entries, "p": int(page), "n": int(pages)}
    )


def _shrink_entry(entry: dict) -> dict:
    """Bound the one free-text field a discovery entry carries.

    Everything else in an entry is a name, an address or a number. Only the
    self-test's `detail` is a sentence, and it is the field that turns a page
    into two.
    """
    detail = entry.get("detail")
    if isinstance(detail, str) and len(detail) > MAX_DISCOVERY_DETAIL:
        entry = dict(entry)
        entry["detail"] = _clip(detail, MAX_DISCOVERY_DETAIL)
    return entry


def discovery_pages(kind: str, entries: list[dict]) -> list[bytes]:
    """Split a result list into notifications that each fit one BLE packet.

    This channel used to send the whole list in a single notification. A
    realistic list does not fit: seven self-test verdicts encode to about 650
    bytes against a 244-byte packet, so BlueZ delivered the first 244 and the
    app could not decode them. Nothing reported an error — the app simply never
    received a result, which is what "the sound check does nothing" was.

    Paging rather than truncating, because the verdicts are the whole point of
    the check: an answer that silently drops four of seven checks is worse than
    a slower one that carries all of them.
    """
    bounded = [_shrink_entry(entry) for entry in entries]
    if not bounded:
        return [encode_discovery(kind, [], page=0, pages=1)]

    # Group first with a placeholder page count, then re-encode once the real
    # count is known. The count changes the header by at most a byte or two, so
    # a page built against the placeholder is re-checked below.
    groups: list[list[dict]] = []
    current: list[dict] = []
    for entry in bounded:
        candidate = [*current, entry]
        if current and len(encode_discovery(kind, candidate, page=0, pages=99)) > (
            STATUS_NOTIFICATION_LIMIT
        ):
            groups.append(current)
            current = [entry]
        else:
            current = candidate
    groups.append(current)

    return [
        encode_discovery(kind, group, page=index, pages=len(groups))
        for index, group in enumerate(groups)
    ]


def decode_discovery(payload: bytes) -> tuple[str, list[dict]]:
    raw = cbor2.loads(payload)
    if not isinstance(raw, dict):
        raise ProtocolError("discovery payload is not a map")
    entries = raw.get("e")
    return str(raw.get("k", "")), entries if isinstance(entries, list) else []


# -------------------------------------------------------------------- inbound


def _text(raw: dict, key: str, *, limit: int, label: str, required: bool = False) -> str:
    value = raw.get(key)
    if value is None or value == "":
        if required:
            raise ProtocolError(f"{label} is missing")
        return ""
    if not isinstance(value, str):
        raise ProtocolError(f"{label} must be text")
    if len(value) > limit:
        raise ProtocolError(f"{label} is too long")
    return value


def decode_command(payload: bytes) -> Command:
    try:
        raw = cbor2.loads(payload)
    except Exception as error:  # noqa: BLE001 - any malformed frame is one refusal
        raise ProtocolError("That command could not be read.") from error
    if not isinstance(raw, dict):
        raise ProtocolError("That command could not be read.")

    name = raw.get("c")
    if not isinstance(name, str) or name not in KNOWN_COMMANDS:
        raise ProtocolError("This device does not understand that request.")

    target = None
    if name == CMD_SET_OUTPUT:
        try:
            target = OutputTarget(raw.get("t"))
        except ValueError as error:
            raise ProtocolError("That is not an audio output this device has.") from error

    enabled = None
    if name in (CMD_SET_HEADSET_MIC, CMD_SET_AUTO_UPDATE):
        value = raw.get("on")
        if not isinstance(value, bool):
            raise ProtocolError("That setting must be on or off.")
        enabled = value

    address = ""
    if name in (CMD_BT_CONNECT, CMD_BT_DISCONNECT, CMD_BT_FORGET):
        address = _text(raw, "a", limit=64, label="The headphone address", required=True)

    text = ""
    if name == CMD_RENAME:
        text = _text(raw, "n", limit=MAX_NAME_LENGTH, label="The device name", required=True)

    return Command(name=name, address=address, target=target, enabled=enabled, text=text)


def decode_provisioning(payload: bytes) -> Provisioning:
    try:
        raw = cbor2.loads(payload)
    except Exception as error:  # noqa: BLE001
        raise ProtocolError("That setup message could not be read.") from error
    if not isinstance(raw, dict):
        raise ProtocolError("That setup message could not be read.")

    url = _text(raw, "url", limit=MAX_URL_LENGTH, label="The NeoRecall address", required=True)
    if not url.startswith(("http://", "https://")):
        raise ProtocolError("The NeoRecall address must start with http:// or https://.")

    return Provisioning(
        backend_url=url.rstrip("/"),
        api_key=_text(raw, "key", limit=MAX_SECRET_LENGTH, label="The access key", required=True),
        wifi_ssid=_text(raw, "ssid", limit=MAX_SSID_LENGTH, label="The network name"),
        wifi_password=_text(raw, "psk", limit=MAX_SECRET_LENGTH, label="The network password"),
        timezone=_text(raw, "tz", limit=100, label="The time zone"),
        device_name=_text(raw, "n", limit=MAX_NAME_LENGTH, label="The device name"),
        tls_verify=bool(raw.get("tls", True)),
    )
