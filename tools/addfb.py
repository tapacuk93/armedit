#!/usr/bin/env python3
"""
Add a simple-framebuffer node to a device tree that has not got one.

A real loader on a real machine - m1n1, U-Boot, almost anything - brings the
display up itself and describes it in the tree it hands over. QEMU does not: it
offers ramfb, which the guest configures through fw_cfg, and that is a
different path with different code behind it.

So the bare-metal display path has been tested only as a parser. This closes
that gap without needing the machine: take QEMU's own tree, add the node a real
loader would have added, hand it back with -dtb, and the kernel takes the
route it will take on hardware. Then read the memory afterwards and see whether
the picture is there.

    addfb.py <in.dtb> <out.dtb> <address> <width> <height> [format] [stride]

The address must be RAM the kernel is not otherwise using, because nothing here
reserves it - on a real machine the loader owns that allocation, and pretending
otherwise would test something the guest does not do.

The stride is separate from the width on purpose. Real panels pad their rows -
a 1280-pixel line in a 2048-byte-aligned buffer - and a kernel that multiplies
the width instead of reading the stride draws a picture that shears a little
further left on every row. Passing a stride wider than the width is how that
mistake is made to show.
"""

import struct
import sys

FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_NOP = 4
FDT_END = 9


def read(path):
    d = open(path, "rb").read()
    magic, total, off_st, off_str, off_rsv, ver, last, cpu, size_str, size_st = \
        struct.unpack_from(">10I", d, 0)
    if magic != 0xD00DFEED:
        raise SystemExit("%s is not a device tree" % path)
    return d, off_st, off_str, size_st, size_str, off_rsv, ver, last, cpu


def main(src, dst, addr, width, height, fmt, stride):
    d, off_st, off_str, size_st, size_str, off_rsv, ver, last, cpu = read(src)
    st = bytearray(d[off_st:off_st + size_st])
    strs = bytearray(d[off_str:off_str + size_str])

    def soff(name):
        # A property name already in the block is reused, because two entries
        # for one name is legal and wasteful and makes diffs unreadable.
        want = name.encode() + b"\0"
        at = bytes(strs).find(want)
        if at >= 0 and (at == 0 or strs[at - 1] == 0):
            return at
        at = len(strs)
        strs.extend(want)
        return at

    def prop(name, data):
        out = bytearray()
        out.extend(struct.pack(">III", FDT_PROP, len(data), soff(name)))
        out.extend(data)
        while len(out) % 4:
            out.append(0)
        return out

    node = bytearray()
    node.extend(struct.pack(">I", FDT_BEGIN_NODE))
    name = ("framebuffer@%x" % addr).encode() + b"\0"
    while len(name) % 4:
        name += b"\0"
    node.extend(name)
    node.extend(prop("compatible", b"simple-framebuffer\0"))
    node.extend(prop("reg", struct.pack(">QQ", addr, stride * height)))
    node.extend(prop("width", struct.pack(">I", width)))
    node.extend(prop("height", struct.pack(">I", height)))
    node.extend(prop("stride", struct.pack(">I", stride)))
    node.extend(prop("format", fmt.encode() + b"\0"))
    node.extend(struct.pack(">I", FDT_END_NODE))

    # Just before the root node closes, which is where a child belongs. The
    # last END_NODE in the block is the root's; everything before it is nested.
    at, depth, close = 0, 0, None
    while at < len(st):
        tok, = struct.unpack_from(">I", st, at)
        if tok == FDT_BEGIN_NODE:
            depth += 1
            at += 4
            end = st.index(b"\0", at)
            at = (end + 4) & ~3
        elif tok == FDT_END_NODE:
            depth -= 1
            if depth == 0:
                close = at
                break
            at += 4
        elif tok == FDT_PROP:
            ln, _ = struct.unpack_from(">II", st, at + 4)
            at += 12 + ((ln + 3) & ~3)
        elif tok == FDT_NOP:
            at += 4
        else:
            break
    if close is None:
        raise SystemExit("could not find where the root node ends")

    st[close:close] = node

    hdr_size = 40
    new_off_st = hdr_size
    new_off_str = new_off_st + len(st)
    total = new_off_str + len(strs)
    hdr = struct.pack(">10I", 0xD00DFEED, total, new_off_st, new_off_str,
                      hdr_size, ver, last, cpu, len(strs), len(st))
    open(dst, "wb").write(hdr + bytes(st) + bytes(strs))
    print("addfb: %s has a %dx%d %s framebuffer at %#x, stride %d"
          % (dst, width, height, fmt, addr, stride), file=sys.stderr)


if __name__ == "__main__":
    a = sys.argv
    width = int(a[4])
    main(a[1], a[2], int(a[3], 0), width, int(a[5]),
         a[6] if len(a) > 6 else "x8r8g8b8",
         int(a[7], 0) if len(a) > 7 else width * 4)
