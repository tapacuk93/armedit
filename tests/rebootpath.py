#!/usr/bin/env python3
"""
Restarting a machine that has no PSCI, all the way down.

Everywhere this kernel currently runs, a reboot is one instruction: PSCI's
SYSTEM_RESET, made with hvc or smc as the device tree says. Apple Silicon has
no secure monitor offering PSCI to anything m1n1 booted, so the instruction
that works everywhere else goes nowhere there - or somewhere unintended, which
is worse. The kernel has to find a watchdog in the tree and arm it instead.

That path cannot be reached under QEMU by describing a machine without PSCI.
Removing the psci node from the tree does not work: QEMU's virt board patches
whatever tree it is handed and puts its own psci node back, so the guest
receives one regardless. That cost an afternoon; it is written here so it is
not paid twice.

So ARMEDIT_REBOOT_TEST forces the condition rather than describing it - the
kernel behaves as though nothing offered PSCI - and everything past that point
is the real path: QEMU's own tree, a real search through it for a watchdog,
real stores to the address it gives back. tools/loadertree.py adds the watchdog
node, pointing at ordinary memory so the three words can be read afterwards and
the machine is still running to be asked.

That build also calls the bottom of the path directly at boot. Reaching it from
the editor means typing a word and having an operation answer #REBOOT, which
needs a network and a backend and an agreed operation - none of which exist on
the machine at first boot, and none of which is what is in question here.

And in that build the PSCI call is replaced by a line saying it was reached,
because QEMU answers the call whatever its tree says: a fall-through and a
clean restart look identical from outside, and the whole point is telling them
apart.

What is in question:

  - a kernel with no psci node finds the watchdog rather than firing an hvc
    into the dark;
  - it writes reset-enable, then a bite time of zero, then a current time of
    zero, at the second watchdog's offsets;
  - it leaves the first watchdog - the one the system holds - alone;
  - having armed one, it stops, rather than going on to the PSCI call;
  - and with no watchdog it does go on to it, because then there is genuinely
    nothing else left to try.
"""

import os
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.path.join(ROOT, "build")
SCRATCH = os.environ.get("E2E_DIR", "/tmp/armedit-reboot")

WDT_AT = 0x50000000             # RAM, well clear of the kernel and of the tree
POISON = 0xAAAAAAAA

failures = []


def ok(passed, what, detail=""):
    print("  %-58s %s%s" % (what, "ok" if passed else "FAIL",
                            "" if not detail else "   " + detail))
    if not passed:
        failures.append(what)


def sh(argv, **kw):
    return subprocess.run(argv, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, **kw)


def tree(name, wdt):
    """QEMU's own tree with the PSCI taken out, and a watchdog put in."""
    base = os.path.join(SCRATCH, "virt.dtb")
    if not os.path.exists(base):
        sh(["qemu-system-aarch64", "-M", "virt,dumpdtb=" + base,
            "-cpu", "cortex-a72", "-m", "512", "-display", "none"], timeout=60)
    out = os.path.join(SCRATCH, name + ".dtb")
    argv = [sys.executable, os.path.join(ROOT, "tools", "loadertree.py"),
            base, out]
    if wdt is not None:
        argv += ["--wdt", hex(wdt)]
    subprocess.run(argv, stderr=subprocess.DEVNULL, check=True)
    return out


def run(name, dtb, wdt):
    """
    Boot the reboot-on-purpose kernel, then read the watchdog back.

    The region is poisoned first, through QEMU itself before the guest starts,
    so that a zero read afterwards means "the kernel wrote zero" rather than
    "nobody has ever written here" - which are the same bytes and different
    facts, and the bite time and current time are both expected to be zero.
    """
    serial = os.path.join(SCRATCH, name + ".log")
    if os.path.exists(serial):
        os.remove(serial)

    poison = os.path.join(SCRATCH, name + ".poison")
    with open(poison, "wb") as f:
        f.write(struct.pack("<16I", *([POISON] * 16)))

    argv = ["qemu-system-aarch64", "-M", "virt", "-cpu", "cortex-a72",
            "-m", "512", "-kernel", os.path.join(BUILD, "kernel.img"),
            "-dtb", dtb, "-display", "none",
            "-serial", "file:" + serial]
    if wdt is not None:
        argv += ["-device", "loader,file=%s,addr=%#x,force-raw=on" % (poison, wdt)]
    argv += ["-monitor", "tcp:127.0.0.1:4620,server,nowait"]

    proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    words = None
    try:
        import socket
        for _ in range(200):
            if os.path.exists(serial) and b"armedit:" in open(serial, "rb").read():
                break
            time.sleep(0.1)
        time.sleep(1.5)
        mon = socket.create_connection(("127.0.0.1", 4620), timeout=10)
        time.sleep(0.3)
        mon.recv(65536)
        if wdt is not None:
            path = os.path.join(SCRATCH, name + ".bin")
            if os.path.exists(path):
                os.remove(path)
            mon.sendall(('pmemsave %#x 0x40 "%s"\n' % (wdt, path)).encode())
            time.sleep(2.0)
            for _ in range(40):
                if os.path.exists(path) and os.path.getsize(path) >= 0x40:
                    break
                time.sleep(0.25)
            with open(path, "rb") as f:
                words = struct.unpack("<16I", f.read(0x40))
        mon.close()
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()

    log = open(serial, "rb").read().decode(errors="replace") if os.path.exists(serial) else ""
    return words, log


def main():
    os.makedirs(SCRATCH, exist_ok=True)
    print("restarting a machine with no PSCI:")

    sh(["make", "-C", ROOT, "clean-kernel"])
    built = subprocess.run(["make", "-C", ROOT, "kernel-img",
                            "KERNEL_DEFS=-DARMEDIT_REBOOT_TEST"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if built.returncode:
        print(built.stderr.decode()[-2000:])
        return 1

    try:
        words, log = run("wdt", tree("wdt", WDT_AT), WDT_AT)
        ok("KERNEL FAULT" not in log, "nothing faulted with no PSCI to call")

        if words is None:
            ok(False, "the watchdog could be read back")
        else:
            ok(words[0x1c // 4] == 4,
               "reset enable is set on the second watchdog",
               "0x1c = %#x" % words[0x1c // 4])
            ok(words[0x14 // 4] == 0, "the bite time is zeroed",
               "0x14 = %#x" % words[0x14 // 4])
            ok(words[0x10 // 4] == 0, "so is the current time",
               "0x10 = %#x" % words[0x10 // 4])
            ok(words[0] == POISON,
               "the system's own watchdog is left as it was",
               "0x00 = %#x" % words[0])

        ok("reached the PSCI call" not in log,
           "having armed a watchdog, it stops rather than calling PSCI")
        ok("reboot returned" in log,
           "...and says it came back, which on real hardware it would not")
        ok(log.count("armedit: boot") == 1,
           "...and the machine is still the one that booted",
           "%d boots" % log.count("armedit: boot"))

        # And a machine with no watchdog. Here falling through is right: there
        # is genuinely nothing else left to try, and a kernel that gave up
        # instead would refuse to restart machines that can.
        _, log2 = run("bare", tree("bare", None), None)
        ok("reached the PSCI call" in log2,
           "with no watchdog it does go on to PSCI, having nothing else")
        ok("KERNEL FAULT" not in log2, "...without faulting on the way")
    finally:
        sh(["make", "-C", ROOT, "clean-kernel"])
        sh(["make", "-C", ROOT, "kernel-img"])

    print()
    if failures:
        print("rebootpath: %d of these did not hold" % len(failures))
        for f in failures:
            print("  - " + f)
        return 1
    print("rebootpath: a machine with no PSCI restarts through its watchdog")
    return 0


if __name__ == "__main__":
    sys.exit(main())
