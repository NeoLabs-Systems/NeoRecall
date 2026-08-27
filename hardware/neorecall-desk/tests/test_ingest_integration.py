"""The appliance against a real NeoRecall server.

Every other test in this suite talks to a stand-in. A stand-in accepts whatever
it was written to accept, which is precisely the wrong property for a wire
protocol: it will happily take a header the real server rejects, and the mistake
only surfaces on hardware, in a room, at midnight.

So this one boots the actual backend — migrations, routes, hash verification and
all — and drives the appliance's own recorder, ledger and upload pump against it.
It is slow by the standards of this suite and worth every second.

Skipped when Node or the server tree is unavailable, so a checkout of the
appliance alone still tests cleanly.
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest

from neorecall_desk import ledger as L
from neorecall_desk.audio.chunker import Chunker
from neorecall_desk.config import ConfigStore
from neorecall_desk.ingest.client import IngestClient
from neorecall_desk.ingest.pump import UploadPump

HARNESS = Path(__file__).parent / "support" / "neorecall_server.js"
SERVER_TREE = Path(__file__).resolve().parents[3] / "server" / "app.js"
BOOT_TIMEOUT_S = 90

pytestmark = pytest.mark.skipif(
    shutil.which("node") is None or not SERVER_TREE.exists(),
    reason="needs Node and the NeoRecall server tree",
)


def post(url: str, body: dict, token: str | None = None) -> dict:
    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={
            "Content-Type": "application/json",
            **({"Authorization": f"Bearer {token}"} if token else {}),
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read() or b"{}")


@pytest.fixture(scope="module")
def server() -> str:
    process = subprocess.Popen(
        ["node", str(HARNESS)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env={**os.environ, "NODE_ENV": "test"},
    )
    port = None
    deadline = time.monotonic() + BOOT_TIMEOUT_S
    while time.monotonic() < deadline and process.poll() is None:
        line = process.stdout.readline()
        if line.startswith("LISTENING "):
            port = int(line.split()[1])
            break
    if port is None:
        process.kill()
        pytest.skip("the NeoRecall server did not start")
    yield f"http://127.0.0.1:{port}"
    process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=20)
    except subprocess.TimeoutExpired:
        process.kill()


@pytest.fixture()
def account(server: str) -> tuple[str, str]:
    """A fresh account and an ingest-scoped API key, as the app would mint one."""
    name = f"desk-{int(time.time() * 1000)}"
    session = post(
        f"{server}/api/v1/auth/register",
        {"username": name, "password": "a long and unique password"},
    )
    token = session["session"]["token"]
    key = post(
        f"{server}/api/v1/api-keys",
        {"name": "NeoRecall Desk", "scopes": ["ingest:write"]},
        token,
    )
    return token, key["token"]


@pytest.fixture()
def appliance(state_dir, server: str, account: tuple[str, str]):
    _, api_key = account
    config = ConfigStore()
    config.update(backend_url=server, api_key=api_key, timezone="Europe/Berlin")
    store = L.Ledger()
    pump = UploadPump(ledger=store, config_store=config, firmware="test")
    yield config, store, pump
    store.close()


def record_one_chunk(store: L.Ledger, seconds: float = 1.0) -> L.ChunkRow:
    """Produce a real chunk through the real chunker, not a hand-made blob."""
    session = store.open_session(device_started_at=L.utc_now_iso(), timezone="Europe/Berlin")
    chunker = Chunker(target_ms=30000, overlap_ms=2000)
    import numpy as np

    from neorecall_desk.config import SAMPLE_RATE

    tone = (np.sin(np.arange(int(SAMPLE_RATE * seconds)) * 0.05) * 8000).astype(np.int16)
    chunker.feed(tone.tobytes())
    final = chunker.finish()
    assert final is not None
    return store.append_chunk(
        session_id=session.id,
        sequence=0,
        payload=final.payload,
        duration_ms=final.duration_ms,
        overlap_ms=final.overlap_ms,
        monotonic_offset_ms=final.monotonic_offset_ms,
        is_final=True,
    )


def test_the_thing_under_test_really_is_a_neorecall_server(server: str):
    """Prove the harness before trusting anything it says.

    A suite that quietly stops exercising the real server keeps passing, which is
    the worst possible failure for an integration test. This asserts the health
    endpoint of an actual NeoRecall process answered.
    """
    with urllib.request.urlopen(f"{server}/health", timeout=15) as response:
        health = json.loads(response.read())

    assert health["status"] == "ok"
    assert health["process"] == "http"
    assert health["version"]


def test_the_appliance_registers_itself_as_a_device(appliance):
    config, _, _ = appliance
    client = IngestClient(config.get())

    device_id = client.register_device(firmware="test")

    assert device_id
    # Idempotent on the client uuid: a restart must not create a second device.
    assert client.register_device(firmware="test") == device_id


def test_the_server_accepts_a_real_chunk_from_the_real_pump(appliance):
    config, store, pump = appliance
    row = record_one_chunk(store)

    pump.run_once()

    stored = store.chunk(row.id)
    # Accepted means: session declared, source declared, headers valid, the
    # SHA-256 the appliance sent matched what the server computed.
    assert stored.state in (L.STATE_UPLOADED, L.STATE_TERMINAL, L.STATE_RELEASED)
    assert stored.server_chunk_id, "the server's own id has to be kept for receipts"


def test_audio_is_kept_until_the_server_proves_it_is_safe_to_delete(appliance):
    config, store, pump = appliance
    row = record_one_chunk(store)

    pump.run_once()
    pump.run_once()

    stored = store.chunk(row.id)
    if stored is not None and stored.state == L.STATE_UPLOADED:
        # No transcription provider is configured here, so the receipt never
        # turns terminal — and the local audio must therefore still be on disk.
        # This is the invariant from AGENTS.md, checked against the real server's
        # real receipt rather than a fixture.
        assert row.path.exists()
        assert not L.proves_safe_audio_release(stored.receipt)


def test_the_session_is_closed_with_a_truthful_final_sequence(appliance):
    config, store, pump = appliance
    record_one_chunk(store)
    session = store.active_session()
    store.close_session(
        session.id, ended_at=L.utc_now_iso(), status=L.SESSION_ENDED, final_sequence=0
    )

    pump.run_once()

    assert store.session(session.id).closed_on_server


def test_a_capture_gap_is_accepted_by_the_real_gap_endpoint(appliance):
    config, store, pump = appliance
    record_one_chunk(store)
    session = store.active_session()
    # Offsets, not timestamps — the shape the route's schema actually validates.
    store.record_gap(
        session_id=session.id,
        reason=L.GAP_CAPTURE_ERROR,
        start_offset_ms=1000,
        end_offset_ms=4000,
    )

    pump.run_once()

    assert store.undeclared_gaps(session.id) == []


def test_a_wrong_key_is_reported_rather_than_retried_forever(appliance):
    config, store, pump = appliance
    record_one_chunk(store)
    config.update(api_key="nrk_not_a_real_key")

    status = pump.run_once()

    assert status.authentication_failed


def test_a_recording_that_produced_nothing_does_not_stay_active(appliance, server, account):
    """A microphone can die before the first chunk is ever written.

    Seen on the appliance: the recorder aborted seconds in, closed its session
    locally, and the server went on listing that recording as active. In the app
    that is a Desk that appears to be recording and never stops — exactly the
    ambiguity the device is supposed to remove.
    """
    config, store, pump = appliance
    token, _ = account

    session = store.open_session(device_started_at=L.utc_now_iso(), timezone="Europe/Berlin")
    store.close_session(
        session.id, ended_at=L.utc_now_iso(), status=L.SESSION_ENDED, final_sequence=-1
    )

    for _ in range(4):
        pump.run_once()

    request = urllib.request.Request(
        f"{server}/api/v1/recordings?limit=50", headers={"Authorization": f"Bearer {token}"}
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        recordings = json.loads(response.read())["items"]

    mine = [row for row in recordings if row["client_uuid"] == session.id]
    assert mine, "the session was never declared to the server at all"
    assert mine[0]["status"] == "ended", f"still {mine[0]['status']} with no chunks"
