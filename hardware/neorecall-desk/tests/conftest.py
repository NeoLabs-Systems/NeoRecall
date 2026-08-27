import sys
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parents[1] / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))


@pytest.fixture()
def state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("NEORECALL_DESK_STATE_DIR", str(tmp_path / "state"))
    from neorecall_desk import paths

    paths.ensure_layout()
    return paths.state_dir()


@pytest.fixture()
def ledger(state_dir):
    from neorecall_desk.ledger import Ledger

    store = Ledger()
    yield store
    store.close()
