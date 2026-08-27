"""Well-known filesystem locations for the appliance.

Every path is overridable through an environment variable so unit tests and a
developer workstation never touch real appliance state.
"""

from __future__ import annotations

import os
from pathlib import Path

_STATE_ENV = "NEORECALL_DESK_STATE_DIR"
_DEFAULT_STATE_DIR = "/var/lib/neorecall-desk"


def state_dir() -> Path:
    return Path(os.environ.get(_STATE_ENV, _DEFAULT_STATE_DIR))


def config_file() -> Path:
    return state_dir() / "config.json"


def ledger_file() -> Path:
    return state_dir() / "ledger.sqlite3"


def audio_dir() -> Path:
    return state_dir() / "pending_audio"


def ensure_layout() -> None:
    """Create the state layout with owner-only permissions."""
    root = state_dir()
    root.mkdir(parents=True, exist_ok=True)
    os.chmod(root, 0o700)
    audio = audio_dir()
    audio.mkdir(parents=True, exist_ok=True)
    os.chmod(audio, 0o700)
