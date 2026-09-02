#!/usr/bin/env python3
"""
Make QEMU's device tree describe the machine this kernel is actually aimed at.

QEMU's virt board is a generous host and that is the problem: it offers ramfb,
which a guest configures for itself, and it advertises PSCI, which answers a
single instruction with a reboot. The target does neither. A real loader on a
real machine - m1n1, U-Boot, almost anything - brings the display up itself and
hands over an address in the tree; and Apple Silicon has no secure monitor
offering PSCI to anything m1n1 booted, so a restart there means finding a
watchdog and arming it.

Both of those paths could therefore only be tested as parsers. The code could
read a node; nothing had ever acted on what it read. This closes that without
needing the machine: take QEMU's own tree, make it say what the target's tree
says, hand it back with -dtb, and the kernel takes the route it will take on
hardware. Then read the memory afterwards and see what it did.

    loadertree.py <in.dtb> <out.dtb> [options]

      --fb ADDR WIDTH HEIGHT   a simple-framebuffer, as a loader would leave it
      --format NAME            its pixel format (default x8r8g8b8)
      --stride BYTES           bytes per row (default width * 4)
      --wdt ADDR               an apple,wdt watchdog
      --drop PREFIX            remove a node whose name starts with this

Dropping is less powerful than it looks. QEMU patches the tree it is handed
before the guest sees it, and for the virt board that includes putting its own
psci node back - so removing that one from the file changes the file and not
the machine. Removing nodes QEMU does not care about works. Where the point is
to reach code that runs when something is absent, forcing the condition in the
guest is honest and describing it in the tree may quietly not be.

Any address given must be RAM the kernel is not otherwise using, because
nothing here reserves it - on a real machine the loader owns that allocation,
and pretending otherwise would test something the guest does not do. QEMU keeps
its own tree in RAM too, and painting over it produces a fault in the parser
long afterwards that reads as a kernel bug and is not.

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


def walk(st):
    """Every token in the structure block, as (offset, token, end) triples."""
    at = 0
    while at < len(st):
        tok, = struct.unpack_from(">I", st, at)
        if tok == FDT_BEGIN_NODE:
            end = st.index(b"\0", at + 4)
            nxt = (end + 4) & ~3
            yield at, tok, nxt
            at = nxt
        elif tok == FDT_PROP:
            ln, _ = struct.unpack_from(">II", st, at + 4)
            nxt = at + 12 + ((ln + 3) & ~3)
            yield at, tok, nxt
            at = nxt
        elif tok in (FDT_END_NODE, FDT_NOP):
            yield at, tok, at + 4
            at += 4
        else:
            yield at, tok, at + 4
            return


def root_close(st):
    """Where the root node ends, which is where a new child belongs."""
    depth = 0
    for at, tok, _ in walk(st):
        if tok == FDT_BEGIN_NODE:
            depth += 1
        elif tok == FDT_END_NODE:
            depth -= 1
            if depth == 0:
                return at
    raise SystemExit("could not find where the root node ends")


def drop(st, prefix):
    """
    Remove a whole node, children and all.

    Removing is how a test asks for a machine that lacks something, and lacking
    is the interesting case: a kernel is easy to write so that it works when
    every node it hopes for is present. QEMU always advertises PSCI, so without
    this there is no way to reach the code that runs when nobody does.
    """
    want = prefix.encode()
    for at, tok, after in walk(st):
        if tok != FDT_BEGIN_NODE:
            continue
        name = st[at + 4:st.index(b"\0", at + 4)]
        if not name.startswith(want):
            continue
        depth, cur = 0, at
        for a2, t2, n2 in walk(st[at:]):
            if t2 == FDT_BEGIN_NODE:
                depth += 1
            elif t2 == FDT_END_NODE:
                depth -= 1
                if depth == 0:
                    del st[at:at + n2]
                    return name.decode()
        break
    return None


def main(argv):
    src, dst = argv[0], argv[1]
    fb = wdt = None
    fmt, stride = "x8r8g8b8", None
    drops = []
    i = 2
    while i < len(argv):
        a = argv[i]
        if a == "--fb":
            fb = (int(argv[i + 1], 0), int(argv[i + 2]), int(argv[i + 3]))
            i += 4
        elif a == "--format":
            fmt = argv[i + 1]; i += 2
        elif a == "--stride":
            stride = int(argv[i + 1], 0); i += 2
        elif a == "--wdt":
            wdt = int(argv[i + 1], 0); i += 2
        elif a == "--drop":
            drops.append(argv[i + 1]); i += 2
        else:
            raise SystemExit("loadertree: no such option: " + a)

    d, off_st, off_str, size_st, size_str, off_rsv, ver, last, cpu = read(src)
    st = bytearray(d[off_st:off_st + size_st])
    strs = bytearray(d[off_str:off_str + size_str])
    said = []

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

    def node(name, props):
        out = bytearray()
        out.extend(struct.pack(">I", FDT_BEGIN_NODE))
        raw = name.encode() + b"\0"
        while len(raw) % 4:
            raw += b"\0"
        out.extend(raw)
        for n, v in props:
            out.extend(prop(n, v))
        out.extend(struct.pack(">I", FDT_END_NODE))
        return out

    for prefix in drops:
        gone = drop(st, prefix)
        said.append("dropped " + gone if gone else "no %s node to drop" % prefix)

    if fb:
        addr, width, height = fb
        step = stride if stride is not None else width * 4
        st[root_close(st):root_close(st)] = node("framebuffer@%x" % addr, [
            ("compatible", b"simple-framebuffer\0"),
            ("reg", struct.pack(">QQ", addr, step * height)),
            ("width", struct.pack(">I", width)),
            ("height", struct.pack(">I", height)),
            ("stride", struct.pack(">I", step)),
            ("format", fmt.encode() + b"\0"),
        ])
        said.append("a %dx%d %s screen at %#x, stride %d"
                    % (width, height, fmt, addr, step))

    if wdt is not None:
        # The compatible is a list, specific half first, exactly as a real
        # Apple tree writes it - so the reader has to find the general half
        # inside the list rather than matching the whole property.
        st[root_close(st):root_close(st)] = node("watchdog@%x" % wdt, [
            ("compatible", b"apple,t8103-wdt\0apple,wdt\0"),
            ("reg", struct.pack(">QQ", wdt, 0x4000)),
        ])
        said.append("a watchdog at %#x" % wdt)

    #
    # The memory reservation block gets its own space, which it did not have
    # before: the header pointed both it and the structure block at the same
    # offset, so anything that read reservations read node tokens instead and
    # kept reading, there being no terminator to find. Nothing here noticed,
    # because this kernel does not read reservations - but QEMU parses the tree
    # it is handed and writes out its own, and what came back was damaged in a
    # way that only showed up several device-tree lookups later, as a machine
    # that reset in the middle of a search.
    #
    # It is empty. An empty list is two zero 64-bit words, and it still has to
    # be somewhere.
    #
    hdr_size = 40
    new_off_rsv = hdr_size
    rsv = struct.pack(">QQ", 0, 0)
    new_off_st = new_off_rsv + len(rsv)
    new_off_str = new_off_st + len(st)
    total = new_off_str + len(strs)
    hdr = struct.pack(">10I", 0xD00DFEED, total, new_off_st, new_off_str,
                      new_off_rsv, ver, last, cpu, len(strs), len(st))
    open(dst, "wb").write(hdr + rsv + bytes(st) + bytes(strs))
    print("loadertree: %s has %s" % (dst, "; ".join(said) or "no changes"),
          file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1:])
