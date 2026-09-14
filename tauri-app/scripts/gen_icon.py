#!/usr/bin/env python3
"""Generate a simple VoiceFlow tray icon (cyan ring on dark) as a PNG.

Writes:
  icons/tray.png        (32x32, embedded in the binary via include_bytes!)
  icons/icon-source.png (512x512, used by `npx tauri icon` to build the set)
"""
import struct
import zlib

SIG = b"\x89PNG\r\n\x1a\n"


def chunk(typ, data):
    body = typ + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def encode_png(size, rgba):
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    raw = bytearray()
    for y in range(size):
        raw.append(0)  # filter type 0 (none) per scanline
        raw.extend(rgba[y * size * 4 : (y + 1) * size * 4])
    idat = zlib.compress(bytes(raw), 9)
    return SIG + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


def make(size):
    buf = bytearray(size * size * 4)
    cx = cy = size / 2.0
    R = size * 0.42
    for y in range(size):
        for x in range(size):
            d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
            i = (y * size + x) * 4
            if d <= R:
                t = d / R
                buf[i] = int(34 + (120 - 34) * t)
                buf[i + 1] = int(211 + (140 - 211) * t)
                buf[i + 2] = int(238 + (160 - 238) * t)
                buf[i + 3] = 255
            else:
                buf[i] = 11
                buf[i + 1] = 16
                buf[i + 2] = 32
                buf[i + 3] = 255
    return encode_png(size, bytes(buf))


if __name__ == "__main__":
    with open("icons/tray.png", "wb") as f:
        f.write(make(32))
    with open("icons/icon-source.png", "wb") as f:
        f.write(make(512))
    print("wrote icons/tray.png and icons/icon-source.png")
