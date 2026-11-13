#!/usr/bin/env python3
"""Builds the boundary files for voice-attachments-e2e.sh next to the real recordings in DIR.

The 120 s / 121 s and 5 MiB files are real containers (ftyp/moov/mvhd/mdat, RIFF/fmt/data) built by hand, because a
real 120.000 s AAC encode cannot be made to hit the limit exactly. Usage: voice-fixtures.py DIR
"""
import struct, sys, os

d = sys.argv[1]
MIB5 = 5 * 1024 * 1024

def box(t, payload): return struct.pack(">I", 8 + len(payload)) + t + payload

def m4a(duration_ms, total=None):
    ftyp = box(b"ftyp", b"M4A " + struct.pack(">I", 0) + b"M4A ")
    mvhd = struct.pack(">B3xIIII", 0, 0, 0, 1000, duration_ms).ljust(100, b"\0")
    head = ftyp + box(b"moov", box(b"mvhd", mvhd))
    pad = max(8, (total or len(head) + 8 + 64) - len(head))
    return head + box(b"mdat", b"\x07" * (pad - 8))

def wav(data_bytes, byte_rate=16000):
    fmt = struct.pack("<HHIIHH", 1, 1, byte_rate // 2, byte_rate, 2, 16)
    body = b"WAVE" + b"fmt " + struct.pack("<I", 16) + fmt + b"data" + struct.pack("<I", data_bytes) + b"\x03" * data_bytes
    return b"RIFF" + struct.pack("<I", len(body)) + body

def put(name, data):
    open(os.path.join(d, name), "wb").write(data)

put("m4a_120s.m4a", m4a(120_000))
put("m4a_121s.m4a", m4a(121_000))
put("wav_120s.wav", wav(120 * 16000))
put("wav_121s.wav", wav(121 * 16000))
put("m4a_5mib.m4a", m4a(1000, MIB5))
put("m4a_5mib_plus1.m4a", m4a(1000, MIB5 + 1))
put("fake.m4a", bytes.fromhex("89504e470d0a1a0a") + b"\0" * 64)
