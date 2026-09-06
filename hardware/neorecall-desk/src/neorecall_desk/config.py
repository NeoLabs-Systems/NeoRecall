"""Persistent appliance configuration.

The whole file is rewritten atomically on every change, so a power loss during a
write leaves either the previous configuration or the new one — never a half
one. Readers take an immutable snapshot, so a provisioning write cannot tear a
value out from under the recorder or the upload pump.

Wi-Fi credentials are deliberately *not* stored here. They are handed to
NetworkManager, which owns them; keeping a second copy would only create a
second thing to leak.
"""

from __future__ import annotations

import json
import os
import threading
import uuid
from dataclasses import asdict, dataclass, field, replace
from pathlib import Path

from . import paths

# Fallbacks used until GET /api/v1/meta has been read once. They mirror the
# server defaults in server/config.js so a first recording made before the
# network is up still produces chunks the server will accept.
DEFAULT_CHUNK_TARGET_MS = 30000
DEFAULT_CHUNK_OVERLAP_MS = 2000
DEFAULT_CHUNK_MIN_MS = 15000
DEFAULT_CHUNK_MAX_MS = 120000
DEFAULT_MAX_UPLOAD_BYTES = 32 * 1024 * 1024

SAMPLE_RATE = 16000
SAMPLE_WIDTH_BYTES = 2
CHANNELS = 1


@dataclass(frozen=True)
class ServerLimits:
    chunk_target_ms: int = DEFAULT_CHUNK_TARGET_MS
    chunk_overlap_ms: int = DEFAULT_CHUNK_OVERLAP_MS
    chunk_min_ms: int = DEFAULT_CHUNK_MIN_MS
    chunk_max_ms: int = DEFAULT_CHUNK_MAX_MS
    max_upload_bytes: int = DEFAULT_MAX_UPLOAD_BYTES


@dataclass(frozen=True)
class Config:
    """One immutable snapshot of everything the appliance was told."""

    client_uuid: str = ""
    device_id: str = ""
    device_name: str = "NeoRecall Desk"
    backend_url: str = ""
    api_key: str = ""
    tls_verify: bool = True
    timezone: str = ""

    # Audio behaviour the user can change from the app.
    use_hfp_mic: bool = False
    preferred_headphone: str = ""
    volume: float = 0.7

    #: "speaker" or "headphones". Read by the relay, which plays at a named
    #: target and so cannot be redirected by changing the default sink alone.
    output_target: str = "speaker"

    limits: ServerLimits = field(default_factory=ServerLimits)

    @property
    def configured(self) -> bool:
        return bool(self.backend_url) and bool(self.api_key)

    @property
    def api_base(self) -> str:
        return self.backend_url.rstrip("/") + "/api/v1"


def _decode(raw: dict) -> Config:
    limits_raw = raw.get("limits") or {}
    known = {f for f in ServerLimits.__dataclass_fields__}
    limits = ServerLimits(**{k: int(v) for k, v in limits_raw.items() if k in known})
    fields = {f for f in Config.__dataclass_fields__ if f != "limits"}
    return Config(limits=limits, **{k: v for k, v in raw.items() if k in fields})


class ConfigStore:
    """Thread-safe owner of the on-disk configuration."""

    def __init__(self, path: Path | None = None) -> None:
        self._path = path or paths.config_file()
        self._lock = threading.Lock()
        self._config = self._load()

    def _load(self) -> Config:
        try:
            raw = json.loads(self._path.read_text("utf-8"))
        except FileNotFoundError:
            raw = {}
        except (OSError, ValueError):
            # A corrupt configuration must not brick the appliance: it falls back
            # to unconfigured, which puts it back into the setup flow rather than
            # into a crash loop.
            raw = {}
        config = _decode(raw) if isinstance(raw, dict) else Config()
        if not config.client_uuid:
            config = replace(config, client_uuid=str(uuid.uuid4()))
            self._write(config)
        return config

    def _write(self, config: Config) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self._path.with_suffix(".json.partial")
        payload = json.dumps(asdict(config), indent=2, sort_keys=True)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
        except BaseException:
            tmp.unlink(missing_ok=True)
            raise
        os.replace(tmp, self._path)
        os.chmod(self._path, 0o600)

    def get(self) -> Config:
        with self._lock:
            return self._config

    def update(self, **changes: object) -> Config:
        """Apply changes and persist them. Returns the new snapshot."""
        with self._lock:
            updated = replace(self._config, **changes)  # type: ignore[arg-type]
            if updated == self._config:
                return self._config
            self._write(updated)
            self._config = updated
            return updated

    def set_limits(self, limits: ServerLimits) -> Config:
        return self.update(limits=limits)

    def clear_account_binding(self) -> Config:
        """Forget the account without forgetting the identity of the hardware.

        Used by "remove device" in the app. The client uuid survives so that
        re-provisioning the same appliance updates its existing server-side
        device row instead of creating a duplicate.
        """
        return self.update(backend_url="", api_key="", device_id="")
