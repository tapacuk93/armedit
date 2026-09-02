#!/usr/bin/env python3
"""
Joining a network, which is the half of "wifi" that is not the radio.

The kernel used to know its own address by having been told it at compile
time: 10.0.2.15, with 10.0.2.2 for the gateway. Those are QEMU's user-mode
network's fixed, documented addresses. They are correct on exactly one machine
and wrong everywhere else - a USB Ethernet adapter on bare metal, or a radio
when there is one, hands out nothing until it is asked.

Associating with a wireless network is silicon-specific, undocumented on the
target, and cannot be emulated. Everything after the link comes up can be: it
is DHCP, it is identical on wired and wireless, and QEMU runs a DHCP server. So
this is written and proved here rather than discovered on hardware.

The serial log says whether a lease arrived. That is not enough on its own - a
kernel that skipped the exchange and printed the address it always used would
say exactly the same thing. So the traffic is captured and read: there must be
a DISCOVER from 0.0.0.0 to the broadcast address, an OFFER, a REQUEST and an
ACK, in that order, carrying this machine's own hardware address, and the
REQUEST must be broadcast rather than sent to the server that offered.
"""

import os
import re
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.path.join(ROOT, "build")
SCRATCH = os.environ.get("E2E_DIR", "/tmp/armedit-network")

DISCOVER, OFFER, REQUEST, ACK = 1, 2, 3, 5
NAMES = {DISCOVER: "DISCOVER", OFFER: "OFFER", REQUEST: "REQUEST", ACK: "ACK"}

failures = []


def ok(passed, what, detail=""):
    print("  %-58s %s%s" % (what, "ok" if passed else "FAIL",
                            "" if not detail else "   " + detail))
    if not passed:
        failures.append(what)


def boot(name, netdev, seconds, pcap=None):
    serial = os.path.join(SCRATCH, name + ".log")
    for p in (serial, pcap):
        if p and os.path.exists(p):
            os.remove(p)
    argv = ["qemu-system-aarch64", "-M", "virt", "-cpu", "cortex-a72", "-m", "512",
            "-kernel", os.path.join(BUILD, "kernel.img"), "-device", "ramfb",
            "-device", "virtio-keyboard-device",
            "-global", "virtio-mmio.force-legacy=false",
            "-netdev", netdev, "-device", "virtio-net-device,netdev=n0",
            "-display", "none", "-serial", "file:" + serial]
    if pcap:
        argv += ["-object", "filter-dump,id=f0,netdev=n0,file=" + pcap]
    p = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(seconds)
    p.terminate()
    try:
        p.wait(timeout=5)
    except Exception:
        p.kill()
    time.sleep(0.5)
    try:
        return open(serial, "rb").read().decode(errors="replace")
    except OSError:
        return ""


def dhcp_packets(path):
    """
    Every DHCP message in the capture, as (type, source, destination, chaddr).

    Read out of the frames rather than trusted: a capture is the only place
    this test can see what the kernel actually put on the wire, as opposed to
    what it says it did.
    """
    out = []
    if not os.path.exists(path):
        return out
    d = open(path, "rb").read()
    off = 24                            # past the pcap file header
    while off + 16 <= len(d):
        _, _, incl, _ = struct.unpack_from("<IIII", d, off)
        off += 16
        pkt, off = d[off:off + incl], off + incl
        if len(pkt) < 42 or struct.unpack_from(">H", pkt, 12)[0] != 0x0800:
            continue
        if pkt[14 + 9] != 17:           # not UDP
            continue
        sport, dport = struct.unpack_from(">HH", pkt, 34)
        if {sport, dport} != {67, 68}:
            continue
        body = pkt[42:]
        if len(body) < 240 or body[236:240] != b"\x63\x82\x53\x63":
            continue
        kind, at = None, 240
        while at + 1 < len(body):
            code = body[at]
            if code == 255:
                break
            if code == 0:
                at += 1
                continue
            length = body[at + 1]
            if code == 53 and length == 1:
                kind = body[at + 2]
            at += 2 + length
        out.append((kind,
                    ".".join(str(b) for b in pkt[26:30]),
                    ".".join(str(b) for b in pkt[30:34]),
                    body[28:34]))
    return out


def main():
    os.makedirs(SCRATCH, exist_ok=True)
    if not os.path.exists(os.path.join(BUILD, "kernel.img")):
        print("network: build the kernel first (make kernel-img)")
        return 1
    print("joining a network:")

    pcap = os.path.join(SCRATCH, "lease.pcap")
    log = boot("lease", "user,id=n0", 8, pcap)

    ok("the network gave us 10.0.2.15" in log,
       "the kernel is given an address rather than assuming one",
       (re.search(r"gave us [\d.]+", log) or [""])[0] if "gave us" in log else log[-60:])
    ok("nobody answered DHCP" not in log, "...without falling back to the old constants")
    ok("KERNEL FAULT" not in log, "...and nothing faulted asking")

    seen = dhcp_packets(pcap)
    kinds = [k for k, _, _, _ in seen]
    ok(kinds[:4] == [DISCOVER, OFFER, REQUEST, ACK],
       "the whole four-packet exchange is really on the wire",
       " ".join(NAMES.get(k, str(k)) for k in kinds[:6]))

    first = next((p for p in seen if p[0] == DISCOVER), None)
    ok(first is not None and first[1] == "0.0.0.0",
       "the discover comes from no address, because we have none")
    ok(first is not None and first[2] == "255.255.255.255",
       "...and goes to everybody, because we do not know who to ask")

    # The second broadcast is the one that is easy to get wrong and costs
    # nothing on a network with one server: sending the request only to the
    # server that offered leaves every other server holding an address it
    # reserved for a machine that took somebody else's.
    req = next((p for p in seen if p[0] == REQUEST), None)
    ok(req is not None and req[2] == "255.255.255.255",
       "the request is broadcast too, so unchosen servers hear it")
    ok(req is not None and req[1] == "0.0.0.0",
       "...and still from no address, the offer not being ours yet")

    ok(first is not None and req is not None and first[3] == req[3] and any(first[3]),
       "both carry this machine's own hardware address",
       ":".join("%02x" % b for b in first[3]) if first else "")

    # And a network device with nothing behind it. The interesting part is that
    # it neither hangs nor pretends: this editor already works with no network,
    # and saying so is a better outcome than a machine that stops booting.
    log2 = boot("silent", "socket,id=n0,listen=127.0.0.1:9913", 14)
    ok("nobody answered DHCP" in log2,
       "a network with no server is reported, not waited on forever")
    ok("KERNEL FAULT" not in log2, "...without faulting either")
    ok("armedit: network device found" in log2, "...and the boot carries on")

    print()
    if failures:
        print("network: %d of these did not hold" % len(failures))
        for f in failures:
            print("  - " + f)
        return 1
    print("network: it asks for an address, the way a real network requires")
    return 0


if __name__ == "__main__":
    sys.exit(main())
