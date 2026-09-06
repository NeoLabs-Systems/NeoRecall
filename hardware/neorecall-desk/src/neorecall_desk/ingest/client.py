"""HTTP client for the NeoRecall ingest protocol.

Every endpoint, header and field name here is the one the Flutter client and the
ESP32 panel already use. Nothing about this appliance is special to the server —
it is one more registered device uploading chunks, which is exactly why it needs
no backend feature of its own.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any

import requests

from .. import __version__
from ..config import CHANNELS, SAMPLE_RATE, Config, ServerLimits

LOG = logging.getLogger(__name__)

# Chosen so a slow uplink is not mistaken for a dead server. Uploads scale their
# read timeout with the payload; everything else is a small JSON round trip.
CONNECT_TIMEOUT_S = 10.0
JSON_READ_TIMEOUT_S = 30.0
UPLOAD_BASE_READ_TIMEOUT_S = 45.0
UPLOAD_TIMEOUT_S_PER_MIB = 20.0

SOURCE_KIND = "combined"
CHANNEL_LAYOUT = "mono"


def iana_timezone(name: str) -> str:
    """The name if a real IANA zone, otherwise UTC.

    The server takes IANA names only. An abbreviation like "CEST" is rejected
    with "Invalid IANA timezone", and because that rejection happens when the
    session is declared, *every* recording the device made stayed on it. A
    timezone is not worth losing recordings over: fall back and keep going.
    """
    if not name:
        return "UTC"
    try:
        from zoneinfo import ZoneInfo

        ZoneInfo(name)
    except Exception:  # noqa: BLE001 - any failure to resolve means "not usable"
        LOG.warning("ignoring the unusable timezone %r; recording as UTC", name)
        return "UTC"
    return name


#: How the appliance identifies itself to the server. Not decoration: a bot
#: filter in front of the API rejects clients that do not name themselves.
USER_AGENT = f"NeoRecallDesk/{__version__}"
SAMPLE_FORMAT = "pcm_s16le"
AUDIO_CONTAINER = "wav"
AUDIO_CODEC = "pcm_s16le"


class IngestError(RuntimeError):
    """A request the server refused, carrying enough to decide what to do next."""

    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(f"{status} {code}: {message}")
        self.status = status
        self.code = code
        self.message = message

    @property
    def unauthorized(self) -> bool:
        return self.status == 401

    @property
    def retryable(self) -> bool:
        """Whether trying the identical request again could plausibly work.

        A 5xx or a rate limit is the server having a bad moment. A 4xx other than
        429 means the request itself is wrong, and repeating it only burns power.
        """
        return self.status >= 500 or self.status == 429


class TransportError(RuntimeError):
    """The request never reached a server: no route, DNS, TLS, or a timeout."""


@dataclass(frozen=True)
class DeclaredSession:
    session_id: str
    source_id: str


class IngestClient:
    def __init__(self, config: Config, session: requests.Session | None = None) -> None:
        self._config = config
        self._http = session or requests.Session()

    @property
    def config(self) -> Config:
        return self._config

    # ------------------------------------------------------------------ plumbing

    def _headers(self, extra: dict[str, str] | None = None) -> dict[str, str]:
        headers = {
            "Authorization": f"Bearer {self._config.api_key}",
            "Accept": "application/json",
            # Say who is calling. A server behind a bot filter judges an
            # unidentified client on its signature alone: the appliance's
            # requests came back as Cloudflare 1010 ("banned by signature")
            # while the same host answered curl, so recordings piled up on the
            # device with nothing in the log to explain it.
            "User-Agent": USER_AGENT,
        }
        if extra:
            headers.update(extra)
        return headers

    def _request(
        self,
        method: str,
        path: str,
        *,
        json_body: Any = None,
        files: Any = None,
        headers: dict[str, str] | None = None,
        read_timeout: float = JSON_READ_TIMEOUT_S,
    ) -> Any:
        url = f"{self._config.api_base}{path}"
        try:
            response = self._http.request(
                method,
                url,
                json=json_body,
                files=files,
                headers=self._headers(headers),
                timeout=(CONNECT_TIMEOUT_S, read_timeout),
                verify=self._config.tls_verify,
            )
        except requests.RequestException as error:
            raise TransportError(str(error)) from error

        if response.status_code >= 400:
            code, message = "HTTP_ERROR", response.reason or "Request failed."
            try:
                payload = response.json()
                error = payload.get("error") if isinstance(payload, dict) else None
                if isinstance(error, dict):
                    code = str(error.get("code") or code)
                    message = str(error.get("message") or message)
            except ValueError:
                pass
            raise IngestError(response.status_code, code, message)

        if response.status_code == 204 or not response.content:
            return None
        try:
            return response.json()
        except ValueError as error:
            raise TransportError(f"malformed JSON from {path}") from error

    # ---------------------------------------------------------------- discovery

    def meta(self) -> ServerLimits:
        payload = self._request("GET", "/meta") or {}
        limits = payload.get("limits") or {}
        defaults = ServerLimits()

        def pick(key: str, fallback: int) -> int:
            value = limits.get(key)
            return int(value) if isinstance(value, (int, float)) and value > 0 else fallback

        return ServerLimits(
            chunk_target_ms=pick("chunkTargetMs", defaults.chunk_target_ms),
            chunk_overlap_ms=pick("chunkOverlapMs", defaults.chunk_overlap_ms),
            chunk_min_ms=pick("chunkMinMs", defaults.chunk_min_ms),
            chunk_max_ms=pick("chunkMaxMs", defaults.chunk_max_ms),
            max_upload_bytes=pick("maxUploadBytes", defaults.max_upload_bytes),
        )

    # ------------------------------------------------------------------ devices

    def register_device(self, *, firmware: str) -> str:
        """Register or refresh this appliance, returning the id the server owns.

        The server is authoritative: if it already knows this ``clientUuid`` it
        answers with the existing id, and the caller must adopt it. Keeping a
        locally invented id after that would make every later upload a 404.
        """
        payload = self._request(
            "POST",
            "/devices",
            json_body={
                "clientUuid": self._config.client_uuid,
                "name": self._config.device_name,
                "platform": "raspberrypi",
                "kind": "appliance",
                "capabilities": {
                    "microphone": True,
                    "systemAudio": True,
                    "hardwareButtons": True,
                    "firmware": firmware,
                },
            },
        )
        device_id = (payload or {}).get("id")
        if not isinstance(device_id, str) or not device_id:
            raise TransportError("device registration returned no id")
        return device_id

    def heartbeat(self, device_id: str, *, client_sent_at: str) -> dict:
        return (
            self._request(
                "POST",
                f"/devices/{device_id}/heartbeat",
                json_body={"clientSentAt": client_sent_at},
            )
            or {}
        )

    # ----------------------------------------------------------------- sessions

    def create_session(
        self,
        *,
        device_id: str,
        client_uuid: str,
        source_client_uuid: str,
        started_at: str,
        timezone: str,
        consent_attested_at: str,
    ) -> DeclaredSession:
        payload = (
            self._request(
                "POST",
                "/ingest/sessions",
                json_body={
                    "deviceId": device_id,
                    "clientUuid": client_uuid,
                    "startedAt": started_at,
                    "timezone": iana_timezone(timezone),
                    "consentAttestedAt": consent_attested_at,
                    "sources": [
                        {
                            "clientUuid": source_client_uuid,
                            "kind": SOURCE_KIND,
                            "channelLayout": CHANNEL_LAYOUT,
                            "sampleRate": SAMPLE_RATE,
                            "sampleFormat": SAMPLE_FORMAT,
                            "metadata": {"mix": "near_and_far", "channels": CHANNELS},
                        }
                    ],
                },
            )
            or {}
        )
        session = payload.get("session") or {}
        sources = payload.get("sources") or []
        session_id = session.get("id")
        source_id = None
        for source in sources:
            if (
                source.get("client_uuid") == source_client_uuid
                or source.get("clientUuid") == source_client_uuid
            ):
                source_id = source.get("id")
                break
        if source_id is None and sources:
            source_id = sources[0].get("id")
        if not isinstance(session_id, str) or not isinstance(source_id, str):
            raise TransportError("session declaration returned no usable identifiers")
        return DeclaredSession(session_id=session_id, source_id=source_id)

    def close_session(
        self, session_id: str, *, ended_at: str, status: str, source_id: str, final_sequence: int
    ) -> None:
        self._request(
            "PATCH",
            f"/ingest/sessions/{session_id}",
            json_body={
                "endedAt": ended_at,
                "status": status,
                "sources": [{"id": source_id, "finalSequence": final_sequence}],
            },
        )

    def declare_gaps(self, session_id: str, gaps: list[dict]) -> None:
        if not gaps:
            return
        self._request("POST", f"/ingest/sessions/{session_id}/gaps", json_body={"gaps": gaps})

    # ------------------------------------------------------------------- chunks

    def upload_chunk(
        self,
        *,
        session_id: str,
        source_id: str,
        sequence: int,
        payload: bytes,
        idempotency_key: str,
        sha256: str,
        duration_ms: int,
        overlap_ms: int,
        monotonic_offset_ms: int,
        device_started_at: str,
        is_final: bool,
    ) -> dict:
        headers = {
            "Idempotency-Key": idempotency_key,
            "X-Chunk-Sha256": sha256,
            "X-Chunk-Duration-Ms": str(duration_ms),
            "X-Chunk-Overlap-Ms": str(overlap_ms),
            "X-Channel-Layout": CHANNEL_LAYOUT,
            "X-Monotonic-Offset-Ms": str(monotonic_offset_ms),
            "X-Device-Started-At": device_started_at,
            "X-Audio-Container": AUDIO_CONTAINER,
            "X-Audio-Codec": AUDIO_CODEC,
            "X-Audio-Content-Encoding": "identity",
            "X-Final-Chunk": "true" if is_final else "false",
        }
        timeout = UPLOAD_BASE_READ_TIMEOUT_S + UPLOAD_TIMEOUT_S_PER_MIB * (
            len(payload) / (1024 * 1024)
        )
        response = self._request(
            "PUT",
            f"/ingest/sessions/{session_id}/sources/{source_id}/chunks/{sequence}",
            files={"audio": (f"{idempotency_key}.wav", payload, "audio/wav")},
            headers=headers,
            read_timeout=timeout,
        )
        receipt = (response or {}).get("receipt")
        if not isinstance(receipt, dict):
            raise TransportError("chunk upload returned no receipt")
        return receipt

    def chunk_statuses(self, chunk_ids: list[str]) -> list[dict]:
        if not chunk_ids:
            return []
        payload = (
            self._request("POST", "/ingest/chunks/status", json_body={"chunkIds": chunk_ids}) or {}
        )
        receipts = payload.get("receipts")
        return [r for r in receipts if isinstance(r, dict)] if isinstance(receipts, list) else []

    def release_chunks(self, chunk_ids: list[str]) -> int:
        if not chunk_ids:
            return 0
        payload = (
            self._request("POST", "/ingest/chunks/released", json_body={"chunkIds": chunk_ids})
            or {}
        )
        released = payload.get("released")
        return int(released) if isinstance(released, (int, float)) else 0
