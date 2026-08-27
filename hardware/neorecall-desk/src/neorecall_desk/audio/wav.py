"""Minimal RIFF/WAVE writer for 16-bit PCM.

The appliance uploads ``pcm_s16le`` inside a WAV container because that is what
the ingest route already accepts from every other client. Writing the 44-byte
header by hand keeps the chunk bytes byte-for-byte predictable, which is what
makes the SHA-256 in the upload header meaningful.
"""

from __future__ import annotations

import struct

HEADER_BYTES = 44


def wav_header(
    *, data_bytes: int, sample_rate: int, channels: int, bits_per_sample: int = 16
) -> bytes:
    byte_rate = sample_rate * channels * bits_per_sample // 8
    block_align = channels * bits_per_sample // 8
    return b"".join(
        (
            b"RIFF",
            struct.pack("<I", 36 + data_bytes),
            b"WAVEfmt ",
            struct.pack(
                "<IHHIIHH", 16, 1, channels, sample_rate, byte_rate, block_align, bits_per_sample
            ),
            b"data",
            struct.pack("<I", data_bytes),
        )
    )


def wrap(pcm: bytes, *, sample_rate: int, channels: int) -> bytes:
    return wav_header(data_bytes=len(pcm), sample_rate=sample_rate, channels=channels) + pcm


def payload_of(wav: bytes) -> bytes:
    """Return the PCM payload of a WAV this module produced."""
    if len(wav) < HEADER_BYTES or wav[:4] != b"RIFF" or wav[8:12] != b"WAVE":
        raise ValueError("not a RIFF/WAVE buffer")
    return wav[HEADER_BYTES:]
