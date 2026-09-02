#!/usr/bin/env python3
"""
The bare-metal display path, exercised rather than parsed.

On the target machine no virtual display device exists. A loader - m1n1,
U-Boot, EFI, iBoot before any of them - brings the panel up itself and hands
over an address, a size and a stride in the device tree it passes. The kernel's
job is to believe that description and draw into it. Everything about that path
is different from the ramfb one the other end-to-end test uses: ramfb is a
device the guest configures, and this is a buffer the guest is simply given.

QEMU does not hand over such a buffer, which is why this path had until now
been tested only as a parser: dtb.S and screen.S could read a node, and nothing
had ever drawn through what they read. tools/loadertree.py closes that by putting
the node into QEMU's own tree, so the kernel takes the route it will take on
hardware and the pixels can be read back out of guest memory afterwards.

What is asserted, and why each one can fail:

  - The kernel says the display is up without a ramfb in the machine. Before
    this path was wired into platform_init it said the opposite while standing
    in front of a working framebuffer.
  - The chrome is at the address the tree named. Two different addresses are
    tried in turn, so agreeing with the tree cannot be a constant that happens
    to match.
  - Memory below the buffer stays clean, so "found the picture" is not "wrote
    over everything".
  - The padding beyond a deliberately wide stride is never touched. A kernel
    that multiplies the width instead of reading the stride fills it, and its
    picture shears one row at a time - which looks like a font bug and is not.
  - The geometry comes from the tree too: a second run at another size puts the
    last drawn row where that size says it is and not where the first one did.
  - Typing changes the picture, so this is a live editor and not one frame
    painted at boot.
  - The device tree is still intact at the end, because on a real machine the
    loader reserves the framebuffer and here nobody does. Drawing over the tree
    the kernel is still holding produces a fault in the parser minutes later,
    which reads as a kernel bug and is a harness one - so the collision is
    checked for directly rather than left to be rediscovered.
  - Nothing faulted through any of it.
"""

import os
import re
import socket
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.path.join(ROOT, "build")
SCRATCH = os.environ.get("E2E_DIR", "/tmp/armedit-treefb")

# Out of include/editor.inc. The bar is the top strip and the dim is the gutter
# beside the text, and between them they are most of what is on screen before
# anybody types - which makes them what a framebuffer read can be sure of.
COL_BAR = 0xFF1D2228
COL_DIM = 0xFF3A4048
COL_BG = 0xFF141618

failures = []


def ok(passed, what, detail=""):
    print("  %-58s %s%s" % (what, "ok" if passed else "FAIL",
                            "" if not detail else "   " + detail))
    if not passed:
        failures.append(what)


def stub_dtb_address(machine):
    """
    Where QEMU put the tree, asked rather than assumed.

    With -kernel, QEMU writes a short stub at the base of RAM that loads the
    tree's address into x0 and jumps. The address is a literal in that stub, so
    reading it back is exact - and it moves with the QEMU version and the
    amount of memory, which is why it is not written down here as a number.
    """
    b = machine.memory(0x40000000, 0x40)
    return struct.unpack_from("<Q", b, 0x18)[0]


def dumpdtb(path):
    """QEMU's own tree for the machine this test builds, straight from QEMU."""
    subprocess.run(["qemu-system-aarch64", "-M", "virt,dumpdtb=" + path,
                    "-cpu", "cortex-a72", "-m", "256",
                    "-global", "virtio-mmio.force-legacy=false",
                    "-device", "virtio-keyboard-device", "-display", "none"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   timeout=60)
    return os.path.exists(path)


class Machine:
    """One armedit booted with a loader-shaped framebuffer and no ramfb."""

    def __init__(self, name, dtb, port):
        self.name = name
        self.serial = os.path.join(SCRATCH, name + ".log")
        self.port = port
        self.argv = [
            "qemu-system-aarch64", "-M", "virt", "-cpu", "cortex-a72",
            "-m", "512", "-kernel", os.path.join(BUILD, "kernel.img"),
            "-dtb", dtb,
            "-global", "virtio-mmio.force-legacy=false",
            "-device", "virtio-keyboard-device",
            "-monitor", "tcp:127.0.0.1:%d,server,nowait" % port,
            "-serial", "file:" + self.serial,
            "-display", "none",
        ]

    def __enter__(self):
        if os.path.exists(self.serial):
            os.remove(self.serial)
        self.proc = subprocess.Popen(self.argv, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        for _ in range(200):
            if os.path.exists(self.serial):
                with open(self.serial, "rb") as f:
                    if b"armedit:" in f.read():
                        break
            time.sleep(0.1)
        time.sleep(1.5)
        self.mon = socket.create_connection(("127.0.0.1", self.port), timeout=10)
        time.sleep(0.3)
        self.mon.recv(65536)
        return self

    def __exit__(self, *rest):
        try:
            self.mon.close()
        except Exception:
            pass
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()

    def cmd(self, text, wait=0.2):
        self.mon.sendall((text + "\n").encode())
        time.sleep(wait)
        try:
            return self.mon.recv(200000).decode(errors="replace")
        except Exception:
            return ""

    def type(self, text, rate=0.14):
        names = {" ": "spc", ".": "dot", ",": "comma", "-": "minus"}
        for ch in text:
            self.cmd("sendkey " + names.get(ch, ch), rate)

    def memory(self, addr, length):
        """
        Guest memory as pixels. pmemsave rather than the monitor's xp, because
        this reads megabytes and xp renders them as text one word at a time.
        """
        path = os.path.join(SCRATCH, "%s-%x.bin" % (self.name, addr))
        if os.path.exists(path):
            os.remove(path)
        # The path is quoted because the monitor parses an unquoted argument as
        # an expression, and a leading slash there is a division sign.
        self.cmd('pmemsave %#x %#x "%s"' % (addr, length, path), 2.5)
        for _ in range(40):
            if os.path.exists(path) and os.path.getsize(path) >= length:
                break
            time.sleep(0.25)
        with open(path, "rb") as f:
            return f.read()

    def log(self):
        try:
            with open(self.serial, "rb") as f:
                return f.read().decode(errors="replace")
        except OSError:
            return ""


def pixels(buf):
    return struct.unpack("<%dI" % (len(buf) // 4), buf[:len(buf) // 4 * 4])


def run(name, addr, width, height, stride, port, dtb_in):
    """Boot at one geometry and report what came back, for the caller to judge."""
    dtb = os.path.join(SCRATCH, name + ".dtb")
    subprocess.run([sys.executable, os.path.join(ROOT, "tools", "loadertree.py"),
                    dtb_in, dtb, "--fb", hex(addr), str(width), str(height),
                    "--stride", str(stride)],
                   stderr=subprocess.DEVNULL, check=True)
    with Machine(name, dtb, port) as m:
        tree = stub_dtb_address(m)
        rows = m.memory(addr, stride * height)
        below = m.memory(addr - 0x10000, 0x10000)
        m.type("hello")
        time.sleep(1.0)
        after = m.memory(addr, stride * min(height, 64))
        magic = m.memory(tree, 4)
        return {
            "log": m.log(), "rows": rows, "below": below, "tree": tree,
            "intact": magic == b"\xd0\x0d\xfe\xed",
            "before": rows[:stride * min(height, 64)], "after": after,
        }


def row(buf, stride, y, width):
    """One row of visible pixels, without the padding that follows it."""
    return pixels(buf[y * stride:y * stride + width * 4])


def padding(buf, stride, y, width):
    """The bytes past the visible width, which nothing should ever write."""
    return pixels(buf[y * stride + width * 4:(y + 1) * stride])


def main():
    os.makedirs(SCRATCH, exist_ok=True)
    if not os.path.exists(os.path.join(BUILD, "kernel.img")):
        print("treefb: build the kernel first (make kernel-img)")
        return 1

    base = os.path.join(SCRATCH, "virt.dtb")
    if not dumpdtb(base):
        print("treefb: QEMU would not dump its device tree")
        return 1
    print("the display a loader hands over:")

    # Two geometries at two addresses. Neither is the other's default, so
    # nothing here can pass by agreeing with a constant compiled into the
    # kernel - it has to have read the tree both times.
    #
    # Both are high in the 512MB this machine has, above the kernel image and
    # above where QEMU keeps the tree - which on this build is 0x48000000, and
    # putting a framebuffer there paints over the tree and faults the parser
    # much later. The addresses avoid it and the run checks that they did.
    A = (0x50000000, 1280, 800, 1280 * 4 + 256)
    B = (0x58000000, 1024, 600, 1024 * 4)
    a = run("fb-a", A[0], A[1], A[2], A[3], 4610, base)
    b = run("fb-b", B[0], B[1], B[2], B[3], 4611, base)

    for name, r, (addr, w, h, stride) in (("first", a, A), ("second", b, B)):
        ok("display up" in r["log"] and "no framebuffer" not in r["log"],
           "%s: the kernel took the tree's framebuffer" % name)
        ok("KERNEL FAULT" not in r["log"], "%s: nothing faulted" % name)

        top = row(r["rows"], stride, 0, w)
        ok(top.count(COL_BAR) > w * 0.9,
           "%s: the bar is at %#x, where the tree said" % (name, addr),
           "%d of %d pixels" % (top.count(COL_BAR), w))

        seen = set()
        for y in range(0, h, 7):
            seen.update(row(r["rows"], stride, y, w))
        ok(COL_BG in seen and COL_DIM in seen,
           "%s: the editor's own background and gutter are there" % name)

        ok(set(r["below"]) == {0},
           "%s: memory below the buffer is untouched" % name,
           "%d non-zero" % sum(1 for p in pixels(r["below"]) if p))

        if stride > w * 4:
            dirty = sum(1 for y in range(h) if any(padding(r["rows"], stride, y, w)))
            ok(dirty == 0,
               "%s: the padding past the stride is never written" % name,
               "%d rows of %d" % (dirty, h))

        ok(r["before"] != r["after"],
           "%s: typing changes the picture" % name)

        ok(r["intact"], "%s: the device tree survived the drawing" % name,
           "tree at %#x, buffer %#x..%#x" % (r["tree"], addr, addr + stride * h))

    # The geometry is the tree's, not a guess: the last row the first machine
    # drew is past the bottom of the second machine's screen, so a kernel using
    # a compiled-in height would have run off the end of the smaller one.
    last_a = row(a["rows"], A[3], A[2] - 1, A[1])
    last_b = row(b["rows"], B[3], B[2] - 1, B[1])
    ok(any(last_a) and any(last_b),
       "both screens are drawn to their own last row",
       "%d and %d" % (A[2], B[2]))

    print()
    if failures:
        print("treefb: %d of these did not hold" % len(failures))
        for f in failures:
            print("  - " + f)
        return 1
    print("treefb: the bare-metal display path draws what the tree describes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
