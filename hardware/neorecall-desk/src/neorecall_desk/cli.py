"""The appliance service entry point.

One process owns capture, control and upload. That is deliberate: the pump has to
be paused at the exact moment a recording starts, and the app has to be told how
many recordings are still waiting — splitting those across processes would buy
nothing and cost an IPC channel to get wrong.

The audio *relay* is not in here. It runs as two ``pw-loopback`` units that know
nothing about NeoRecall, so a laptop keeps hearing its own audio through the
appliance even while this service is restarting, and even if it was never set up.
"""

from __future__ import annotations

import logging
import os
import signal
import sys
import threading

from . import __version__, paths
from .audio.streams import NODE_NEAR, NODE_RELAY_OUT, PwRecordStream, far_side_target
from .config import ConfigStore
from .control import bluez, tones
from .control.button import GpioButton
from .control.gatt import GattServer
from .control.headphones import HeadphoneManager
from .control.supervisor import Supervisor
from .ingest.pump import UploadPump
from .ledger import Ledger

LOG = logging.getLogger("neorecall_desk")


def _configure_logging() -> None:
    """Log to the journal, at a level the field can turn up without a rebuild.

    Bring-up wants everything; a device that has been running for months wants
    the summary. ``NEORECALL_LOG_LEVEL=debug`` is the difference, and it is a
    drop-in file rather than a new image.
    """
    requested = os.environ.get("NEORECALL_LOG_LEVEL", "info").upper()
    level = getattr(logging, requested, None)
    logging.basicConfig(
        level=level if isinstance(level, int) else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        stream=sys.stderr,
    )
    if not isinstance(level, int):
        logging.getLogger(__name__).warning("unknown log level %r; using info", requested)


def main() -> int:
    _configure_logging()
    paths.ensure_layout()

    config = ConfigStore()
    ledger = Ledger()
    pump = UploadPump(ledger=ledger, config_store=config, firmware=__version__)

    runtime = bluez.BluezRuntime()
    headphones = None
    try:
        runtime.start()
        headphones = HeadphoneManager(runtime)
    except bluez.BluetoothUnavailable as error:
        # A Pi without a working Bluetooth stack is still a perfectly good USB
        # audio interface and recorder. Refusing to start would turn a missing
        # convenience into a dead appliance.
        LOG.warning("Bluetooth is unavailable: %s", error)

    toneplayer = tones.Toneplayer(target=NODE_RELAY_OUT)

    def build_recorder():
        return supervisor.build_recorder(
            near=PwRecordStream(NODE_NEAR),
            far=PwRecordStream(far_side_target(), blocking=False),
        )

    supervisor = Supervisor(
        ledger=ledger,
        config_store=config,
        pump=pump,
        firmware=__version__,
        recorder_factory=build_recorder,
        headphones=headphones,
        toneplayer=toneplayer,
    )

    gatt = None
    if runtime.running:
        gatt = GattServer(
            runtime,
            snapshot_provider=supervisor.snapshot,
            on_command=supervisor.handle_command,
            on_provision=supervisor.handle_provisioning,
            advertised_name=config.get().device_name,
        )
        try:
            gatt.start()
            supervisor.attach_gatt(gatt)
        except Exception:  # noqa: BLE001
            LOG.exception("could not publish the Bluetooth control service")
            gatt = None

    button = GpioButton(supervisor.on_button)
    button.start()

    pump_thread = threading.Thread(target=pump.run_forever, name="upload-pump", daemon=True)
    pump_thread.start()

    supervisor.start()
    LOG.info("NeoRecall Desk %s is running", __version__)

    stopping = threading.Event()

    def _shutdown(signum, _frame) -> None:
        LOG.info("shutting down on signal %s", signum)
        stopping.set()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    try:
        stopping.wait()
    finally:
        # Order matters: stop capturing before anything that could be uploading,
        # so the final chunk and the session close land before the pump looks.
        supervisor.stop()
        button.stop()
        pump.stop()
        pump_thread.join(timeout=10)
        if gatt is not None:
            gatt.stop()
        runtime.stop()
        ledger.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
