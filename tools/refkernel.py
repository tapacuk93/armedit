#!/usr/bin/env python3
"""
Pull a raw arm64 kernel Image out of a distribution's vmlinuz.

Why this exists: the framework's virtio console never carried a byte for this
kernel, through many rounds of narrowing, and the one question none of that
could answer was whether the console works at all. A stock kernel answers it -
if Linux prints, the device is fine and the fault is here; if Linux is silent
too, the search was in the wrong process.

It printed. That is what this script is for: making that reference repeatable,
because "I once booted something else and it worked" is not a fact anybody can
check later.

The extraction is needed because a distribution vmlinuz is not an Image. It is
a PE executable - the EFI stub - with the real kernel compressed inside it, and
VZLinuxBootLoader declines to boot that. The arm64 Image has a sixty-four byte
header with "ARM\\x64" at offset 0x38, so the way to find it is to decompress
every compressed member in the file and look for that magic.

    tools/refkernel.py <vmlinuz> <Image out>

A kernel this finds boots far enough to print, panics for want of a root
filesystem, and that is entirely sufficient - the output is the whole point.
"""

import bz2
import io
import lzma
import struct
import sys
import zlib


def members(data):
    """Every compressed stream in the file, with a decompressor for each."""
    def gunzip(b):
        # A kernel's payload is followed by whatever the EFI stub keeps after
        # it, so the stream ends before the file does. An incremental
        # decompressor stops cleanly at that boundary; gzip.GzipFile does not.
        return zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(b)

    def unxz(b):
        return lzma.LZMADecompressor().decompress(b)

    def unlzma(b):
        return lzma.LZMADecompressor(format=lzma.FORMAT_ALONE).decompress(b)

    def unbz2(b):
        return bz2.BZ2Decompressor().decompress(b)

    def unzstd(b):
        from compression import zstd
        return zstd.ZstdDecompressor().decompress(b)

    kinds = [
        (b"\x1f\x8b\x08", gunzip, "gzip"),
        (b"\xfd7zXZ", unxz, "xz"),
        (b"\x5d\x00\x00\x00", unlzma, "lzma"),
        (b"BZh9", unbz2, "bzip2"),
        (b"\x28\xb5\x2f\xfd", unzstd, "zstd"),
    ]
    for magic, fn, name in kinds:
        at = 0
        while True:
            i = data.find(magic, at)
            if i < 0:
                break
            yield i, fn, name
            at = i + 1


def main(vmlinuz, out):
    data = open(vmlinuz, "rb").read()
    if data[0x38:0x3C] == b"ARM\x64":
        open(out, "wb").write(data)
        print("refkernel: already a raw Image, copied", file=sys.stderr)
        return 0

    for at, fn, name in members(data):
        try:
            body = fn(data[at:])
        except Exception:
            continue
        if len(body) > 1_000_000 and body[0x38:0x3C] == b"ARM\x64":
            size, = struct.unpack_from("<Q", body, 0x10)
            open(out, "wb").write(body)
            print("refkernel: %s at %#x -> %d bytes, image_size %#x"
                  % (name, at, len(body), size), file=sys.stderr)
            return 0

    print("refkernel: no arm64 Image inside %s" % vmlinuz, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
