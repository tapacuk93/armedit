#!/usr/bin/env python3
"""
mkvideo.py - the reference encoder for ARMV1 (see docs/armv1.md).

This exists to make the assembly decoder testable. It produces clips whose
every byte is known here, so gfx/video.S can be checked against a second
implementation rather than against itself. It is also the specification in
executable form: where this file and the document disagree, one of them is a
bug.

    ./tools/mkvideo.py bounce out.armv        # synthetic clip
    ./tools/mkvideo.py dump out.armv          # what the bytes say
    ./tools/mkvideo.py rgba out.armv frames/  # decode to raw RGBA, per frame
"""

import struct
import sys


MAGIC = b"ARMV"


# ---------------------------------------------------------------- encoding

def rle_key(indices):
    """A key frame: (count, index) pairs, runs up to 255."""
    out = bytearray()
    i, n = 0, len(indices)
    while i < n:
        v = indices[i]
        run = 1
        while i + run < n and indices[i + run] == v and run < 255:
            run += 1
        out.append(run)
        out.append(v)
        i += run
    return bytes(out)


def rle_delta(prev, cur):
    """
    A delta frame: skip runs over pixels that did not change, literal runs
    over pixels that did. Runs are 1..128 either way.

    A single changed pixel between two long identical stretches costs 2 bytes
    to encode as a literal and 2 bytes of skip to step over, so there is no
    point coalescing across it - the naive split is already the small one.
    """
    out = bytearray()
    i, n = 0, len(cur)
    while i < n:
        if cur[i] == prev[i]:
            run = 1
            while i + run < n and cur[i + run] == prev[i + run] and run < 128:
                run += 1
            out.append(run - 1)                 # high bit clear: skip
            i += run
        else:
            run = 1
            while i + run < n and cur[i + run] != prev[i + run] and run < 128:
                run += 1
            out.append(0x80 | (run - 1))        # high bit set: literal
            out.extend(cur[i:i + run])
            i += run
    return bytes(out)


def encode(width, height, fps, palette, frames):
    """
    frames is a list of index planes, each width*height bytes.

    Frame 0 is a key frame by definition. Later frames go out as deltas
    unless the delta is bigger than the key would have been, which happens
    on a scene change - and a key frame there is what makes looping work.
    """
    assert 1 <= len(palette) <= 256
    out = bytearray()
    out += MAGIC
    out += bytes([1, 0])
    out += struct.pack("<HHHHH", width, height, len(frames), fps, len(palette))
    for (r, g, b) in palette:
        out += bytes([r, g, b])

    prev = None
    for plane in frames:
        assert len(plane) == width * height
        key = rle_key(plane)
        if prev is None:
            payload, kind = key, 0
        else:
            delta = rle_delta(prev, plane)
            payload, kind = (delta, 1) if len(delta) <= len(key) else (key, 0)
        out += struct.pack("<I", len(payload))
        out += bytes([kind])
        out += payload
        prev = plane
    return bytes(out)


# ---------------------------------------------------------------- decoding

def decode(data):
    """The reference decoder. Returns (width, height, fps, palette, planes)."""
    if data[:4] != MAGIC or data[4] != 1:
        raise ValueError("not an ARMV1 file")
    width, height, count, fps, ncol = struct.unpack("<HHHHH", data[6:16])
    pos = 16
    palette = []
    for _ in range(ncol):
        palette.append(tuple(data[pos:pos + 3]))
        pos += 3

    npx = width * height
    planes = []
    plane = bytearray(npx)
    for _ in range(count):
        (length,) = struct.unpack("<I", data[pos:pos + 4])
        kind = data[pos + 4]
        p = data[pos + 5:pos + 5 + length]
        pos += 5 + length
        if kind == 0:
            plane = bytearray(npx)
            i, at = 0, 0
            while i + 1 < len(p) and at < npx:
                run, idx = p[i], p[i + 1]
                i += 2
                run = min(run, npx - at)
                plane[at:at + run] = bytes([idx]) * run
                at += run
        else:
            plane = bytearray(plane)
            i, at = 0, 0
            while i < len(p) and at < npx:
                op = p[i]
                i += 1
                run = (op & 0x7F) + 1
                run = min(run, npx - at)
                if op & 0x80:
                    plane[at:at + run] = p[i:i + run]
                    i += run
                at += run
        planes.append(bytes(plane))
    return width, height, fps, palette, planes


def to_rgba(width, height, palette, plane):
    """0xAARRGGBB little-endian - the one pixel format this project has."""
    out = bytearray(width * height * 4)
    for i, idx in enumerate(plane):
        r, g, b = palette[idx]
        out[i * 4 + 0] = b
        out[i * 4 + 1] = g
        out[i * 4 + 2] = r
        out[i * 4 + 3] = 0xFF
    return bytes(out)


# ---------------------------------------------------------------- clips

def bounce(width=64, height=48, frames=24):
    """
    A square that moves, on a background that does not. Exactly the content
    the format is good at, and exactly the content that proves delta coding
    works: every frame but the first should be a few dozen bytes.
    """
    palette = [(0x10, 0x14, 0x1A), (0xF2, 0xA0, 0x30), (0x30, 0xC0, 0x90)]
    planes = []
    size = 12
    for f in range(frames):
        plane = bytearray(width * height)
        # a fixed stripe, so there is something a delta must never touch
        for x in range(width):
            plane[(height - 3) * width + x] = 2
        t = f / max(1, frames - 1)
        x0 = int((width - size) * abs(1 - 2 * t))
        y0 = int((height - size - 6) * (0.5 - 0.5 * (1 - 2 * t) ** 2) * 2)
        for y in range(y0, y0 + size):
            for x in range(x0, x0 + size):
                plane[y * width + x] = 1
        planes.append(bytes(plane))
    return width, height, 12, palette, planes


def scope(width=64, height=48, frames=24):
    """
    A textured background with a line sweeping across it.

    The texture is the point. It breaks every horizontal run, so a key frame
    can barely compress at all, and only a delta - which spends nothing on the
    unchanged texture - is small. This is the clip that proves the delta path
    is real rather than an unused branch.
    """
    palette = [(0x0E, 0x12, 0x18), (0x1A, 0x22, 0x2C), (0x3A, 0xD0, 0xA0),
               (0xF0, 0x60, 0x50)]
    planes = []
    base = bytearray(width * height)
    for y in range(height):
        for x in range(width):
            base[y * width + x] = (x * 7 + y * 13) % 2      # dithered ground
    for f in range(frames):
        plane = bytearray(base)
        col = int((width - 1) * f / max(1, frames - 1))
        for y in range(height):
            plane[y * width + col] = 2                      # the sweep
        cy = height // 2 + int(8 * ((f % 8) - 4) / 4)
        for x in range(max(0, col - 6), col):
            plane[cy * width + x] = 3                       # a short trail
        planes.append(bytes(plane))
    return width, height, 12, palette, planes


CLIPS = {"bounce": bounce, "scope": scope}


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip())
        return 2
    cmd = argv[1]

    if cmd in CLIPS:
        width, height, fps, palette, planes = CLIPS[cmd]()
        blob = encode(width, height, fps, palette, planes)
        with open(argv[2], "wb") as fh:
            fh.write(blob)
        raw = width * height * len(planes)
        print(f"{argv[2]}: {width}x{height} {len(planes)} frames @{fps}fps, "
              f"{len(blob)} bytes ({100 * len(blob) / raw:.1f}% of raw indices)")
        return 0

    if cmd == "dump":
        data = open(argv[2], "rb").read()
        width, height, fps, palette, planes = decode(data)
        print(f"{width}x{height} {len(planes)} frames @{fps}fps, "
              f"{len(palette)} colours")
        pos = 16 + 3 * len(palette)
        for i in range(len(planes)):
            (length,) = struct.unpack("<I", data[pos:pos + 4])
            kind = "key  " if data[pos + 4] == 0 else "delta"
            print(f"  frame {i:3d}  {kind}  {length:6d} bytes")
            pos += 5 + length
        return 0

    if cmd == "rgba":
        import os
        data = open(argv[2], "rb").read()
        width, height, fps, palette, planes = decode(data)
        os.makedirs(argv[3], exist_ok=True)
        for i, plane in enumerate(planes):
            with open(os.path.join(argv[3], f"{i:04d}.rgba"), "wb") as fh:
                fh.write(to_rgba(width, height, palette, plane))
        print(f"wrote {len(planes)} frames of {width}x{height} RGBA")
        return 0

    print(f"unknown command {cmd!r}")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))


def emit_asm(path, name, blob):
    """
    A clip as an assembler source file.

    The demo clip has to be inside the binary: OS mode has no filesystem to
    load one from, and a video widget that only works on the hosted build would
    not be testing the thing that matters.
    """
    with open(path, "w") as fh:
        fh.write('#include "asm.inc"\n')
        fh.write("/*\n * %s.S - generated by tools/mkvideo.py; do not hand-edit.\n"
                 " *\n * %d bytes of ARMV1 (see docs/armv1.md), built into the binary because\n"
                 " * OS mode has no filesystem to read a clip from.\n */\n"
                 % (name, len(blob)))
        fh.write("        RODATA\n        .p2align 3\n")
        fh.write("        .globl  SYM(%s)\nSYM(%s):\n" % (name, name))
        for i in range(0, len(blob), 16):
            fh.write("        .byte " + ",".join("0x%02X" % b for b in blob[i:i + 16]) + "\n")
        fh.write("        .globl  SYM(%s_end)\nSYM(%s_end):\n" % (name, name))
