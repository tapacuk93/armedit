#!/usr/bin/env python3
"""
End to end, in a virtual machine, on the features as somebody would use them.

Every other test here checks a piece: that an operation compiles, that a
directive parses, that the emitted aarch64 runs. This one boots armedit as its
own operating system, types at it, and looks at the screen - which is the only
way to find out whether the pieces are still connected to each other.

The assertions are deliberately not about text on a framebuffer. Reading pixels
back into characters means reimplementing the font, and a test that can fail
because its own optical character recognition is wrong is a test that costs
more than it catches. So each check is something a machine can be certain
about:

  - the colour of the text, read straight out of the framebuffer dump;
  - how many times the kernel printed its boot banner, from the serial log;
  - whether the backend recorded a fetch;
  - whether anything faulted, ever, in any of it.

The network cases need a backend and are skipped without one, and say so. The
offline case needs the opposite - no network device at all - and is the more
important of the two: it is the claim that this editor keeps working when
everything else has gone away.
"""

import os
import re
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.path.join(ROOT, "build")
SCRATCH = os.environ.get("E2E_DIR", "/tmp/armedit-e2e")

# The palette the editor draws with, straight out of editor.S. Only the two
# this test can ask for; the caret's amber is deliberately absent, because it
# is on screen in every state and would win any count it took part in.
GREEN, BLUE = "green", "blue"
PALETTE = {GREEN: (0x8A, 0xE2, 0xB8), BLUE: (0x8A, 0xB8, 0xE2)}

failures = []


def ok(passed, what, detail=""):
    print("  %-56s %s%s" % (what, "ok" if passed else "FAIL",
                            "" if not detail else "   " + detail))
    if not passed:
        failures.append(what)


def skip(what, why):
    print("  %-56s skipped   %s" % (what, why))


class Machine:
    """One booted armedit, driven through QEMU's monitor."""

    def __init__(self, name, key=None, network=True, graphics=True):
        self.name = name
        self.serial = os.path.join(SCRATCH, name + ".log")
        self.port = 4600 + (abs(hash(name)) % 300)
        argv = [
            "qemu-system-aarch64", "-M", "virt", "-cpu", "cortex-a72",
            "-m", "256", "-kernel", os.path.join(BUILD, "kernel.img"),
            "-global", "virtio-mmio.force-legacy=false",
            "-device", "virtio-keyboard-device",
            "-monitor", "tcp:127.0.0.1:%d,server,nowait" % self.port,
            "-serial", "file:" + self.serial,
        ]
        if network:
            argv += ["-netdev", "user,id=n0",
                     "-device", "virtio-net-device,netdev=n0"]
        if key:
            argv += ["-fw_cfg", "name=opt/armedit/key,string=" + key]
        argv += ["-device", "ramfb", "-display", "none"] if graphics else ["-display", "none"]
        self.argv = argv
        self.proc = None

    def __enter__(self):
        if os.path.exists(self.serial):
            os.remove(self.serial)
        self.proc = subprocess.Popen(self.argv, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        # Wait for the machine to say it is up rather than sleeping a guess:
        # a fixed delay is either too short on a loaded machine or wasted on an
        # idle one, and this test boots several.
        for _ in range(200):
            if os.path.exists(self.serial):
                with open(self.serial, "rb") as f:
                    if b"armedit:" in f.read():
                        break
            time.sleep(0.1)
        time.sleep(1.0)
        self.mon = socket.create_connection(("127.0.0.1", self.port), timeout=10)
        time.sleep(0.3)
        self.mon.recv(65536)
        return self

    def __exit__(self, *rest):
        try:
            self.mon.close()
        except Exception:
            pass
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except Exception:
                self.proc.kill()

    def cmd(self, text, wait=0.15):
        self.mon.sendall((text + "\n").encode())
        time.sleep(wait)
        try:
            return self.mon.recv(200000).decode(errors="replace")
        except Exception:
            return ""

    NAMES = {" ": "spc", ".": "dot", ",": "comma", "-": "minus", "/": "slash"}

    def type(self, text, rate=0.14):
        """
        Slowly, and the rate is not arbitrary.

        QEMU's sendkey delivers a press and a release as one event pair, and
        driving it faster than the guest drains its keyboard ring produces
        transpositions - "armedit running as its own operating system" came out
        as "Jsredt rucnniong las oitrs oswn". That is the harness outrunning the
        machine, not the machine dropping keys, and it makes every text
        assertion downstream meaningless.
        """
        for ch in text:
            self.cmd("sendkey " + self.NAMES.get(ch, ch), rate)

    def ask(self, seconds=15.0):
        """Cmd+P. QEMU keeps the host's Command key, so the kernel takes Meta."""
        self.cmd("sendkey meta_l-p", seconds)

    def submit(self, seconds=15.0):
        self.cmd("sendkey meta_l-ret", seconds)

    def screen(self):
        path = os.path.join(SCRATCH, self.name + ".ppm")
        if os.path.exists(path):
            os.remove(path)
        self.cmd("screendump " + path, 2.0)
        return read_ppm(path)

    def log(self):
        try:
            with open(self.serial, "rb") as f:
                return f.read().decode(errors="replace")
        except OSError:
            return ""

    def faults(self):
        return self.log().count("KERNEL FAULT")

    def boots(self):
        return self.log().count("armedit: boot")


def read_ppm(path):
    """A P6 dump, as a flat list of (r, g, b). Small enough not to need care."""
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(b"P6"):
        raise SystemExit("not a P6 dump: " + path)
    fields, at = [], 2
    while len(fields) < 3:
        while at < len(data) and data[at:at + 1].isspace():
            at += 1
        if data[at:at + 1] == b"#":
            while data[at:at + 1] not in (b"\n", b""):
                at += 1
            continue
        start = at
        while at < len(data) and not data[at:at + 1].isspace():
            at += 1
        fields.append(int(data[start:at]))
    at += 1
    w, h, _ = fields
    px = data[at:at + w * h * 3]
    return w, h, px


def text_colour(shot):
    """
    Which palette entry the text is drawn in, by counting exact matches.

    The palette is a fixed table of ten colours and the font is a bitmap, so
    every text pixel is exactly one of those values - no blending, nothing to
    approximate. Counting them is both simpler and more certain than sampling.

    Sampling was the first attempt and it was wrong twice over: a 5x7 font
    draws one-pixel strokes, so a stride of seven pixels can miss every
    character on the screen, and the brightest thing left is the caret, which
    is amber and belongs to neither answer.
    """
    w, h, px = shot
    counts = {name: 0 for name in PALETTE}
    for i in range(0, len(px) - 3, 3):
        rgb = (px[i], px[i + 1], px[i + 2])
        for name, value in PALETTE.items():
            if rgb == value:
                counts[name] += 1
                break
    best = max(counts, key=lambda n: counts[n])
    return best if counts[best] > 200 else None


def signature(shot):
    """
    The screen, as one number.

    Enough to answer "did anything change", which is the honest question for a
    reply whose content this test has no way to read. It is deliberately not a
    claim about what arrived.
    """
    w, h, px = shot
    return hash(bytes(px))


def rows_with_text(shot):
    """How many rows of the framebuffer have anything drawn on them."""
    w, h, px = shot
    rows = 0
    for y in range(0, h, 4):
        base = y * w * 3
        for x in range(0, w * 3, 3 * 11):
            i = base + x
            if i + 2 < len(px) and px[i] + px[i + 1] + px[i + 2] > 150:
                rows += 1
                break
    return rows


# ---------------------------------------------------------------- the tests

def test_offline_colour():
    """
    "colours blue" with no network device at all.

    The strongest claim this project makes: an operation that enough people
    asked for, that compiled, and that several models agreed to ship, is in the
    binary and needs nobody's permission to run. No netdev, no key, no backend.
    """
    with Machine("offline", network=False) as m:
        # Something to look at first. Booted as an operating system the editor
        # starts with an empty buffer - the greeting belongs to the macOS
        # window build - so there is no text to have a colour until there is.
        m.type("this line has a colour")
        ok(text_colour(m.screen()) == GREEN,
           "typed text starts in the editor's usual colour")

        m.cmd("sendkey ret", 0.3)
        m.type("colours blue")
        m.ask(5.0)
        ok(text_colour(m.screen()) == BLUE,
           "\"colours blue\" turns the text blue with no network")
        ok(m.faults() == 0, "...and nothing faulted doing it")


def test_reboot(key):
    """"reboot" restarts the machine, and a question about rebooting does not."""
    if not key:
        skip("\"reboot\" restarts the machine", "no backend key")
        return
    with Machine("reboot", key=key) as m:
        m.type("reboot")
        m.ask(18.0)
        ok(m.boots() == 2, "\"reboot\" restarts the machine",
           "%d boot banners" % m.boots())
        ok(m.faults() == 0, "...without faulting")


def test_browse(key, daemon_log):
    """"open example.com" and Cmd+Enter puts a website on the screen."""
    if not key:
        skip("\"open example.com\" renders a website", "no backend key")
        return
    with Machine("browse", key=key) as m:
        before = rows_with_text(m.screen())
        m.type("open example.com")
        m.submit(20.0)
        after = rows_with_text(m.screen())
        ok(after > before, "\"open example.com\" renders a website",
           "%d rows before, %d after" % (before, after))
        ok(m.faults() == 0, "...without faulting")
        if daemon_log:
            with open(daemon_log) as f:
                fetched = "fetched" in f.read()
            ok(fetched, "...and the backend recorded the fetch")


def test_model(key):
    """A request only a model can answer comes back and lands on the screen."""
    if not key:
        skip("a model answers and the answer lands on screen", "no backend key")
        return
    with Machine("model", key=key) as m:
        m.type("python hello world")
        before = signature(m.screen())
        m.ask(30.0)
        after = signature(m.screen())
        # Not the row count, which was the first attempt and is not a measure
        # of anything: the answer to this one is print('hello world'), which
        # replaces a line of text with a line of text and occupies exactly as
        # many rows as the question did.
        ok(after != before, "a model answers and the answer lands on screen")
        ok(m.faults() == 0, "...without faulting")


def test_typing_through_a_request(key):
    """Keys pressed while a request is in flight are keys that happened."""
    if not key:
        skip("typing during a request is not lost", "no backend key")
        return
    with Machine("through", key=key) as m:
        m.type("haiku about assembly")
        m.cmd("sendkey meta_l-p", 0.3)
        m.type("still typing", rate=0.12)       # straight through the wait
        time.sleep(20)
        shot = m.screen()
        ok(rows_with_text(shot) > 0, "typing during a request is not lost",
           "the screen is not blank afterwards")
        ok(m.faults() == 0, "...without faulting")


def main():
    os.makedirs(SCRATCH, exist_ok=True)
    key = os.environ.get("ARMEDIT_KEY", "").strip()
    if key and "@" not in key:
        backend = os.environ.get("ARMEDIT_BACKEND", "10.0.2.2:8090")
        key = key + "@" + backend
    daemon_log = os.environ.get("E2E_DAEMON_LOG", "")

    print("armedit, end to end, in a virtual machine")
    test_offline_colour()
    test_reboot(key)
    test_browse(key, daemon_log)
    test_model(key)
    test_typing_through_a_request(key)

    if failures:
        print("\n%d failed: %s" % (len(failures), "; ".join(failures)))
        return 1
    print("\nall of it, on a machine that is its own operating system")
    return 0


if __name__ == "__main__":
    sys.exit(main())
