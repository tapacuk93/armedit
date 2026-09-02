#!/usr/bin/env python3
"""
What the machine says about itself, on the machine's own screen.

Every other diagnostic in this kernel goes to the serial port, and on every
machine it has run on so far that was the same thing as going somewhere. The
target is not such a machine: a MacBook booted from its own disk has no serial
port reachable without a special cable and a second computer. A kernel that
explains itself only there has, on that machine, not explained itself - and
"printed something nobody can read" looks exactly like "died before printing",
which is the worst pair of outcomes to be unable to tell apart on a first boot.

So the report goes to both, and this checks both. The serial copy is checked
for content, field by field, because text is what serial is good for. The
screen is checked for the thing serial cannot show: that the page was drawn in
the pixels, at the address the tree named, and that on a machine nobody can
type at it is still there afterwards instead of having been replaced by an
empty document.

The two machines here are the two first boots that matter. One has a keyboard
and a screen it asked for, which is this QEMU. One has a screen handed to it by
a loader and no keyboard at all, which is the Mac.
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
SCRATCH = os.environ.get("E2E_DIR", "/tmp/armedit-machine")

FB_AT = 0x50000000
FG = 0xFF8AE2B8         # console.S draws text in this; nothing else does
BG = 0xFF141618

failures = []


def ok(passed, what, detail=""):
    print("  %-58s %s%s" % (what, "ok" if passed else "FAIL",
                            "" if not detail else "   " + detail))
    if not passed:
        failures.append(what)


def sh(argv, **kw):
    return subprocess.run(argv, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, **kw)


def base_tree():
    p = os.path.join(SCRATCH, "virt.dtb")
    if not os.path.exists(p):
        sh(["qemu-system-aarch64", "-M", "virt,dumpdtb=" + p, "-cpu", "cortex-a72",
            "-m", "512", "-display", "none"], timeout=60)
    return p


class Machine:
    def __init__(self, name, port, dtb=None, keyboard=True, ramfb=False):
        self.name = name
        self.port = port
        self.serial = os.path.join(SCRATCH, name + ".log")
        argv = ["qemu-system-aarch64", "-M", "virt", "-cpu", "cortex-a72",
                "-m", "512", "-kernel", os.path.join(BUILD, "kernel.img"),
                "-global", "virtio-mmio.force-legacy=false",
                "-display", "none", "-serial", "file:" + self.serial,
                "-monitor", "tcp:127.0.0.1:%d,server,nowait" % port]
        if dtb:
            argv += ["-dtb", dtb]
        if keyboard:
            argv += ["-device", "virtio-keyboard-device"]
        if ramfb:
            argv += ["-device", "ramfb"]
        self.argv = argv

    def __enter__(self):
        if os.path.exists(self.serial):
            os.remove(self.serial)
        self.proc = subprocess.Popen(self.argv, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        for _ in range(200):
            if os.path.exists(self.serial) and b"armedit:" in open(self.serial, "rb").read():
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

    def pixels(self, addr, length):
        path = os.path.join(SCRATCH, "%s-%x.bin" % (self.name, addr))
        if os.path.exists(path):
            os.remove(path)
        self.mon.sendall(('pmemsave %#x %#x "%s"\n' % (addr, length, path)).encode())
        time.sleep(2.0)
        for _ in range(40):
            if os.path.exists(path) and os.path.getsize(path) >= length:
                break
            time.sleep(0.25)
        with open(path, "rb") as f:
            b = f.read()
        return struct.unpack("<%dI" % (len(b) // 4), b[:len(b) // 4 * 4])

    def log(self):
        try:
            return open(self.serial, "rb").read().decode(errors="replace")
        except OSError:
            return ""


def field(log, name):
    """One line of the report, as the value after its label."""
    m = re.search(r"^  %s\s+(.*)$" % re.escape(name), log, re.M)
    return m.group(1).strip() if m else None


def main():
    os.makedirs(SCRATCH, exist_ok=True)
    if not os.path.exists(os.path.join(BUILD, "kernel.img")):
        print("machine: build the kernel first (make kernel-img)")
        return 1
    print("what the machine says about itself:")

    # --- the machine with a keyboard and a screen it asked for
    with Machine("asked", 4630, ramfb=True) as m:
        log = m.log()
        ok("this machine" in log, "it reports at all")
        ok(field(log, "running at EL") is None and "running at EL1" in log,
           "it says which exception level the loader left it at")
        ok((field(log, "cpu") or "").startswith("00000000410f"),
           "...and which CPU this is", field(log, "cpu"))
        ok((field(log, "handover") or "").endswith("device tree"),
           "...which of the two handovers arrived", field(log, "handover"))
        ok("ramfb, asked for by this kernel" in (field(log, "screen") or ""),
           "...that this screen was asked for rather than handed over",
           field(log, "screen"))
        ok((field(log, "serial") or "").endswith("pl011"),
           "...which serial port, and of which kind", field(log, "serial"))
        ok(field(log, "restart") == "psci, hvc",
           "...how it would restart", field(log, "restart"))
        ok(field(log, "keyboard") == "yes", "...and whether anybody can type at it")
        ok("KERNEL FAULT" not in log, "and nothing faulted saying it")

        # Before the network, because the network is a likelier thing to hang on
        # than anything above it, and a report that waits for it is a report
        # about the boot that did not need one.
        ok(log.index("this machine") < log.index("armedit: no network device"),
           "the report comes before the network is tried")

        # A keyboard means the editor: the page is not the end of the machine.
        ok("nothing to type at" not in log,
           "a machine that can be typed at does not stop at the report")

    # --- the machine a loader handed a screen to, with nothing to type at
    dtb = os.path.join(SCRATCH, "handed.dtb")
    subprocess.run([sys.executable, os.path.join(ROOT, "tools", "loadertree.py"),
                    base_tree(), dtb, "--fb", hex(FB_AT), "1280", "800"],
                   stderr=subprocess.DEVNULL, check=True)
    with Machine("handed", 4631, dtb=dtb, keyboard=False) as m:
        log = m.log()
        ok(("handed over at %016x" % FB_AT) in (field(log, "screen") or ""),
           "a handed-over screen is reported as one, at its address",
           field(log, "screen"))
        ok("stride" in (field(log, "screen") or "") and "depth" in (field(log, "screen") or ""),
           "...with the stride and depth it was given")
        ok(field(log, "keyboard") == "no", "...and no keyboard, said plainly")

        # The part serial cannot show: that it is on the glass.
        rows = m.pixels(FB_AT, 1280 * 4 * 400)
        ok(rows.count(FG) > 500,
           "the report is drawn in the pixels, not only sent down the wire",
           "%d lit" % rows.count(FG))
        ok(rows.count(BG) > 100000, "...on the console's own background")

        # And that it stays. A machine nobody can type at has nothing to offer
        # past this page, and replacing it with an empty document would be
        # replacing the only useful thing on the screen with nothing.
        ok("nothing to type at" in log, "it says it is stopping, rather than stopping")
        before = m.pixels(FB_AT, 1280 * 4 * 64)
        time.sleep(4.0)
        after = m.pixels(FB_AT, 1280 * 4 * 64)
        ok(before == after, "the page is still there four seconds later")
        ok("armedit: type in the display window" not in log,
           "...and the editor never started over it")
        ok("KERNEL FAULT" not in log, "and nothing faulted doing that either")

    print()
    if failures:
        print("machine: %d of these did not hold" % len(failures))
        for f in failures:
            print("  - " + f)
        return 1
    print("machine: it says what it found, on the screen it found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
