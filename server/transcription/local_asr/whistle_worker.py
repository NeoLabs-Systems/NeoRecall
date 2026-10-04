"""NeoRecall's host for the Whistle speech-recognition engine.

Whistle ships as a plain C library (`needle_load`, `needle_transcribe`). This
file is the whole of the Python NeoRecall depends on: it uses only the standard
library, so no package is installed and nothing here phones home.

Protocol: one JSON object per line on stdin, one per line on stdout.

    -> {"id": 1, "op": "transcribe", "samples": "<base64 float32le>",
        "language": null, "keywords": [], "wordTimestamps": true}
    <- {"id": 1, "ok": true, "result": {...}}
    <- {"id": 1, "ok": false, "error": "..."}

The first line on stdout is {"event": "ready"} once the model is loaded, or
{"event": "fatal", "error": "..."} before the process exits. End of input on
stdin ends the process, so a worker cannot outlive its parent.

The engine is not thread-safe and one model is loaded per process; requests are
therefore handled strictly one at a time.
"""

import base64
import ctypes
import json
import os
import sys
import time

RESULT_BUFFER_BYTES = 1 << 20


def open_protocol_channel():
    """Returns a stream on the real stdout and points fd 1 at stderr.

    The native library may write to stdout. Anything it prints must never be
    mistaken for a protocol line, so the original descriptor is kept private.
    """
    channel = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    return channel


def load_engine(library_path, weights_path):
    library = ctypes.CDLL(library_path)
    samples = ctypes.POINTER(ctypes.c_float)
    library.needle_load.argtypes = [ctypes.c_char_p, ctypes.c_uint64]
    library.needle_load.restype = ctypes.c_int
    library.needle_transcribe.argtypes = [
        samples, ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int,
        ctypes.c_char_p, ctypes.c_int,
    ]
    library.needle_transcribe.restype = ctypes.c_int
    library.needle_last_error.argtypes = []
    library.needle_last_error.restype = ctypes.c_char_p
    with open(weights_path, "rb") as handle:
        weights = handle.read()
    if library.needle_load(weights, len(weights)) < 0:
        raise RuntimeError(library.needle_last_error().decode("utf-8", "replace"))
    return library


class Engine:
    def __init__(self, library_path, weights_path):
        self.library = load_engine(library_path, weights_path)
        self.buffer = ctypes.create_string_buffer(RESULT_BUFFER_BYTES)

    def transcribe(self, request):
        raw = base64.b64decode(request["samples"])
        if len(raw) % 4:
            raise ValueError("samples must be a whole number of float32 values")
        count = len(raw) // 4
        if count == 0:
            return {"text": "", "language": None, "words": []}
        samples = (ctypes.c_float * count).from_buffer_copy(raw)
        keywords = "\n".join(request.get("keywords") or [])
        language = request.get("language")
        started = time.perf_counter()
        code = self.library.needle_transcribe(
            samples, count,
            language.encode("utf-8") if language else None,
            keywords.encode("utf-8") if keywords else None,
            int(bool(request.get("wordTimestamps"))),
            self.buffer, len(self.buffer),
        )
        if code < 0:
            raise RuntimeError(self.library.needle_last_error().decode("utf-8", "replace"))
        result = json.loads(self.buffer.value.decode("utf-8", "replace"))
        result["elapsed_ms"] = round((time.perf_counter() - started) * 1000, 1)
        return result


def serve(channel, engine):
    def reply(payload):
        channel.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")

    for line in sys.stdin.buffer:
        line = line.strip()
        if not line:
            continue
        request_id = None
        try:
            request = json.loads(line.decode("utf-8"))
            request_id = request.get("id")
            operation = request.get("op")
            if operation == "ping":
                reply({"id": request_id, "ok": True, "result": {"pong": True}})
            elif operation == "transcribe":
                reply({"id": request_id, "ok": True, "result": engine.transcribe(request)})
            elif operation == "shutdown":
                reply({"id": request_id, "ok": True, "result": {}})
                return
            else:
                reply({"id": request_id, "ok": False, "error": "unknown operation: %s" % operation})
        except Exception as error:  # one bad request must not take the worker down
            reply({"id": request_id, "ok": False, "error": "%s: %s" % (type(error).__name__, error)})


def main():
    channel = open_protocol_channel()
    try:
        engine = Engine(sys.argv[1], sys.argv[2])
    except Exception as error:
        channel.write(json.dumps({"event": "fatal", "error": "%s: %s" % (type(error).__name__, error)}) + "\n")
        return 1
    channel.write(json.dumps({"event": "ready"}) + "\n")
    serve(channel, engine)
    return 0


if __name__ == "__main__":
    sys.exit(main())
