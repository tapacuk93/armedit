#!/usr/bin/env python3
"""
ELF to a flat arm64 image.

A loader that boots "an arm64 kernel" wants the bytes, laid out the way they
will sit in memory, starting at the image header. It does not want an ELF: an
ELF is a description of how to lay bytes out, and a loader that understood one
would be a loader that could disagree with the linker about where things go.

There is no objcopy in this toolchain, and there does not need to be. The
kernel links to a single loadable segment by construction - see
kernel/arch/aarch64/link.ld - so this is the segment's bytes and nothing else.
If that ever stops being true, this says so rather than quietly writing the
first segment and losing the rest.

.bss is deliberately absent from the file and present in the size the header
declares. The kernel zeroes it on the way up, and writing 300KB of zeroes into
an image only to have them zeroed again is a slower boot and a bigger file for
no difference at all.
"""

import struct
import sys


def segments(data):
    """The PT_LOAD segments of a little-endian aarch64 ELF64."""
    if data[:4] != b"\x7fELF":
        raise SystemExit("not an ELF")
    if data[4] != 2 or data[5] != 1:
        raise SystemExit("expected a little-endian 64-bit ELF")
    e_phoff, = struct.unpack_from("<Q", data, 0x20)
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 0x36)
    out = []
    for i in range(e_phnum):
        at = e_phoff + i * e_phentsize
        p_type, = struct.unpack_from("<I", data, at)
        if p_type != 1:                      # PT_LOAD
            continue
        p_offset, p_vaddr = struct.unpack_from("<QQ", data, at + 0x08)
        p_filesz, p_memsz = struct.unpack_from("<QQ", data, at + 0x20)
        out.append((p_vaddr, p_offset, p_filesz, p_memsz))
    return sorted(out)


def main(elf_path, img_path):
    data = open(elf_path, "rb").read()
    loads = segments(data)
    if not loads:
        raise SystemExit("no loadable segments")

    base = loads[0][0]
    end = max(v + f for v, o, f, m in loads)
    image = bytearray(end - base)
    for vaddr, offset, filesz, memsz in loads:
        at = vaddr - base
        image[at:at + filesz] = data[offset:offset + filesz]

    # The header's own claim about itself, checked rather than trusted: a
    # missing magic means the header did not end up first, and a loader would
    # reject the image with no explanation of why.
    if bytes(image[0x38:0x3C]) != b"ARM\x64":
        raise SystemExit("no arm64 image magic at offset 0x38 - is boot.S first?")

    declared, = struct.unpack_from("<Q", image, 0x10)
    if declared < len(image):
        raise SystemExit("the header says %d bytes but the image is %d"
                         % (declared, len(image)))

    open(img_path, "wb").write(image)
    print("mkimg: %d bytes on disk, %d declared in memory" % (len(image), declared),
          file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
