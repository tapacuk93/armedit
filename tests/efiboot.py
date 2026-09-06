#!/usr/bin/env python3
"""
The handover, which is the one thing about bare metal that had never happened.

Every other bare-metal test starts the kernel with QEMU's -kernel, which puts
the image in memory and jumps to it. That is not how the target starts. There,
a loader owns the machine first, brings the display up, describes it in a
device tree, gives the machine back and jumps - and until now nothing had done
that to this kernel, so the handover was tested only as a parser.

boot/efi.S is that loader. It carries the kernel inside itself, asks the
firmware for the display, makes somewhere two-megabyte aligned for the kernel
to live, copies it there and zeroes the bss it did not carry, writes the
screen and the memory map into a device tree, exits boot services, and jumps
with x0 pointing at the tree. That is m1n1's shape from a different direction,
and an EFI machine is where it can be run.

What is checked is both halves, on two machines, because a machine proves one
thing or the other and not both. The loader says what the firmware gave it on
the serial line, which is the last thing it can say before the firmware is
gone. The kernel says the rest in pixels, because after the handover the screen
is all it has.

The first machine has nothing to type on, so the kernel stops on its report and
the report can be read off the screen. The second has a keyboard and a network,
both on the USB controller and neither of them virtio - which is the shape the
target has - so the editor starts, and what is checked there is that it can be
used. Nothing in the firmware draws in the editor's colours, so finding them on
either machine means the kernel took the machine.
"""

import collections
import os
import re
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.path.join(ROOT, "build")
SCRATCH = os.environ.get("E2E_DIR", "/tmp/armedit-efi")

FIRMWARE = "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
BG = (0x14, 0x16, 0x18)         # what the kernel clears its screen to
FG = (0x8A, 0xE2, 0xB8)         # and draws its text in

failures = []


def ok(passed, what, detail=""):
    print("  %-58s %s%s" % (what, "ok" if passed else "FAIL",
                            "" if not detail else "   " + detail))
    if not passed:
        failures.append(what)


def screen(port, path):
    """What is on the display, as a count of each colour."""
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    time.sleep(0.4)
    s.recv(65536)
    if os.path.exists(path):
        os.remove(path)
    s.sendall(("screendump " + path + "\n").encode())
    time.sleep(3.0)
    s.close()
    if not os.path.exists(path):
        return collections.Counter()
    d = open(path, "rb").read()
    at = 0
    for _ in range(4):                          # P6, width, height, maxval
        while d[at:at + 1].isspace():
            at += 1
        while not d[at:at + 1].isspace():
            at += 1
    at += 1
    px = d[at:]
    c = collections.Counter()
    for i in range(0, len(px) - 2, 3):
        c[(px[i], px[i + 1], px[i + 2])] += 1
    return c


def type_at(port, text):
    """Type at the machine and count what it drew, in the editor's own green."""
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    time.sleep(0.4)
    s.recv(65536)
    for ch in text:
        s.sendall(("sendkey " + ("spc" if ch == " " else ch) + "\n").encode())
        time.sleep(0.16)
        try:
            s.recv(65536)
        except Exception:
            pass
    time.sleep(1.5)
    path = os.path.join(SCRATCH, "typed.ppm")
    if os.path.exists(path):
        os.remove(path)
    s.sendall(("screendump " + path + "\n").encode())
    time.sleep(3.0)
    s.close()
    if not os.path.exists(path):
        return 0
    d = open(path, "rb").read()
    at = 0
    for _ in range(4):
        while d[at:at + 1].isspace():
            at += 1
        while not d[at:at + 1].isspace():
            at += 1
    at += 1
    px = d[at:]
    return sum(1 for i in range(0, len(px) - 2, 3)
               if (px[i], px[i + 1], px[i + 2]) == FG)


def main():
    os.makedirs(SCRATCH, exist_ok=True)
    if not os.path.exists(FIRMWARE):
        print("efiboot: no EFI firmware for QEMU at " + FIRMWARE)
        print("efiboot: skipped - this needs edk2-aarch64-code.fd")
        return 0
    esp = os.path.join(BUILD, "esp.img")
    if not os.path.exists(esp):
        print("efiboot: build the loader first (make efi)")
        return 1

    print("a loader hands the kernel a machine:")

    # Firmware variables have to be writable and the same size as the code.
    code = os.path.join(SCRATCH, "code.fd")
    varsf = os.path.join(SCRATCH, "vars.fd")
    subprocess.run(["cp", FIRMWARE, code], check=True)
    with open(varsf, "wb") as f:
        f.truncate(os.path.getsize(FIRMWARE))

    def run(name, port, usb):
        serial = os.path.join(SCRATCH, name + ".log")
        if os.path.exists(serial):
            os.remove(serial)
        argv = [
            "qemu-system-aarch64", "-M", "virt", "-cpu", "cortex-a72", "-m", "512",
            "-drive", "if=pflash,format=raw,readonly=on,file=" + code,
            "-drive", "if=pflash,format=raw,file=" + varsf,
            "-drive", "format=raw,file=" + esp + ",if=virtio",
            "-device", "ramfb",
        ]
        if usb:
            argv += ["-device", "qemu-xhci", "-device", "usb-kbd",
                     "-netdev", "user,id=u0", "-device", "usb-net,netdev=u0"]
        argv += ["-display", "none", "-serial", "file:" + serial,
                 "-monitor", "tcp:127.0.0.1:%d,server,nowait" % port]
        # Fresh firmware variables per boot: they are stored, and an entry
        # recorded against an older image sends the firmware looking for
        # something that is not there.
        with open(varsf, "wb") as f:
            f.truncate(os.path.getsize(FIRMWARE))
        p = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            time.sleep(30)
            colours = screen(port, os.path.join(SCRATCH, name + ".ppm"))
            typed = type_at(port, "hello from bare metal") if usb else 0
        finally:
            p.terminate()
            try:
                p.wait(timeout=5)
            except Exception:
                p.kill()
        time.sleep(0.5)
        log = (open(serial, "rb").read().decode(errors="replace")
               if os.path.exists(serial) else "")
        return log, colours, typed

    # --- a machine with nothing to type on, which stops on its report
    log, colours, _ = run("alone", 4683, usb=False)

    ok("EFI console is alive" in log, "the firmware starts the loader")
    m = re.search(r"screen at ([0-9a-f]+) (\d+)x(\d+), stride (\d+), format (\d+)", log)
    ok(m is not None, "...which is given a display it can address",
       (re.search(r"armedit: screen.*", log) or [""])[0] if "screen at" in log else "nothing")
    ok("blt only" not in log, "...a real one, not a draw-for-me one")
    ok("drawn" in log, "...and can write to it")

    # The kernel's own colours. The firmware draws its console in grey on
    # black and nothing in it uses these, so finding them means the kernel
    # cleared the screen and drew - which it can only do having been given the
    # framebuffer, at the address the tree said, after the handover.
    ok(colours.get(BG, 0) > 100000,
       "the kernel has the screen, and cleared it to its own background",
       "%d pixels" % colours.get(BG, 0))
    ok(colours.get(FG, 0) > 5000,
       "...and drew what it found on the machine, in its own foreground",
       "%d pixels" % colours.get(FG, 0))
    ok(colours.get(BG, 0) + colours.get(FG, 0) > sum(colours.values()) * 0.9,
       "...over the whole display, so the firmware's console is gone")

    # --- and one with a keyboard and a network, which is the target's shape
    log2, colours2, typed = run("used", 4684, usb=True)

    m = re.search(r"bus at ([0-9a-f]+)", log2)
    ok(m is not None and int(m.group(1), 16) != 0,
       "the loader finds configuration space in ACPI and passes it on",
       m.group(1) if m else "nothing")
    ok(colours2.get(BG, 0) > 100000, "the editor starts, having found a keyboard")
    ok(typed > 300,
       "...and can be typed at, over USB, on a bus that came from ACPI",
       "%d pixels of text" % typed)

    print()
    if failures:
        print("efiboot: %d of these did not hold" % len(failures))
        for f in failures:
            print("  - " + f)
        return 1
    print("efiboot: a loader gave it a machine and it took it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
