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
    def __init__(self, name, port, dtb=None, keyboard=True, ramfb=False,
                 usb=None, extra=None):
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
        # None means no controller at all; an empty tuple means a controller
        # with nothing plugged into it, which is a different machine.
        if usb is not None:
            argv += ["-device", "qemu-xhci"]
            for d in usb:
                argv += ["-device", d]
        if extra:
            argv += extra
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
        # The number that says whether the kernel is inside the machine's own
        # memory. QEMU was started with 512MB at 0x40000000 and the tree says
        # so; on the target this line is the first thing worth reading.
        ok(field(log, "memory") == "0000000040000000 + 512MB",
           "...where memory begins and how much there is", field(log, "memory"))

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

    # --- the USB controller, which is the road to both of the things this
    # machine has not got: something to type on, and a network.
    #
    # The count of occupied ports is the assertion that matters. A base address
    # and a version can both be right by accident - the same numbers come back
    # from a controller nobody is really talking to. A count that goes 0, 1, 2
    # as devices are plugged in is a driver reading the port registers the
    # controller actually keeps, at the address its capability length actually
    # gave. It was 1 and 0 in the right places while that address was wrong,
    # which is why the progression is checked and not one reading.
    cases = [("no controller", None, 4632),
             ("nothing plugged in", (), 4633),
             ("a keyboard", ("usb-kbd",), 4634),
             ("a keyboard and a mouse", ("usb-kbd", "usb-mouse"), 4635)]
    said = {}
    device = {}
    for label, devices, port in cases:
        with Machine("usb%d" % port, port, ramfb=True,
                     usb=devices if devices is not None else None) as m:
            log = m.log()
            said[label] = field(log, "usb") or ""
            device[label] = field(log, "usb device") or ""
            ok("KERNEL FAULT" not in log, "nothing faults with %s" % label)

    ok(said["no controller"] == "absent",
       "a machine with no controller says absent", said["no controller"])
    for label in ("nothing plugged in", "a keyboard", "a keyboard and a mouse"):
        ok("xhci 1.0" in said[label],
           "the controller is found, and says which xHCI it is (%s)" % label,
           said[label])
        ok("would not reset" not in said[label], "...and it resets (%s)" % label)
        # The one that proves a ring rather than a register read: a No-Op
        # command placed in memory by this kernel, executed, and reported back
        # on the event ring it was handed. Every way a ring implementation goes
        # wrong - a physical address the controller cannot reach, a cycle bit
        # the wrong way round, a doorbell at the wrong offset, an event ring
        # pointer never given - produces the same silence, and none of them is
        # about USB.
        ok("answers commands" in said[label],
           "...and executes a command from a ring we built (%s)" % label)
    ok("8 ports" in said["a keyboard"],
       "its own shape is read rather than assumed", said["a keyboard"])

    def attached(label):
        m = re.search(r"(\d+) attached", said[label])
        return int(m.group(1)) if m else -1

    ok(attached("nothing plugged in") == 0,
       "an empty controller reports nothing attached")
    ok(attached("a keyboard") == 1, "...one device, one port occupied")
    ok(attached("a keyboard and a mouse") == 2,
       "...and two, so these are the real port registers")

    # --- and what is on the other end of the wire
    #
    # Everything above is this machine talking to its own controller. Reading a
    # vendor and a product means the controller talked to something somebody
    # else made: a port was reset, a slot allocated, a device addressed, and a
    # control transfer came back with what the device says it is. Any one of
    # those failing gives no ids at all, which is why the ids are the assertion.
    ok(device["a keyboard"].startswith("0627:0001"),
       "a keyboard says who made it and what it is",
       device["a keyboard"])
    ok("stopped at step" in device["nothing plugged in"],
       "an empty controller says which step it got to, not merely that it failed",
       device["nothing plugged in"])

    # The ids have to come from the device rather than from this kernel. A
    # network adapter is a different maker, a different product and a different
    # class - and class 2 is CDC, which is the road to a network on bare metal.
    with Machine("usbnet", 4636, ramfb=True, usb=(),
                 extra=["-netdev", "user,id=u0", "-device", "usb-net,netdev=u0"]) as m:
        net = field(m.log(), "usb device") or ""
    ok(net.startswith("0525:a4a2"),
       "an Ethernet adapter says something else entirely", net)
    ok(net.endswith("class 2"),
       "...and calls itself a communications device, which is what it is", net)

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
