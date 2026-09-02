# The console that receives and will not transmit

armedit boots under macOS's Virtualization framework, discovers its hardware,
brings up the virtio console, and prints nothing. This is everything known
about why, written down because the investigation is longer than anyone will
want to repeat and most of its value is in what has been ruled out.

The framework is a test bed, not the target. Bare metal on Apple Silicon is the
target; this is the closest machine to it that does not involve repartitioning
anything.

## The one fact that matters

**The device works.** A stock Alpine arm64 kernel booted under the same host
program prints its entire boot log to this console, then panics for want of a
root filesystem. `make vz-reference VMLINUZ=<vmlinuz>` reproduces that, and
`tools/refkernel.py` extracts the raw `Image` a distribution vmlinuz hides
inside its EFI stub.

So the bug is in `kernel/arch/aarch64/virtio_console.S`, not in the framework.

## What the machine is

Found by asking, one bit at a time, through a probe that powers the machine off
to mean "yes" — the framework offers no console until this driver works, so
that was the only channel available. See `ARMEDIT_PROBE_CONSOLE` in
`kernel/main.S`.

| | |
|---|---|
| device tree in `x0` | yes |
| `pci-host-ecam-generic` | present |
| `arm,gic-v3` | present |
| `virtio,mmio`, `arm,pl011`, `simple-framebuffer` | absent |
| BARs | **unassigned**; the guest must do it |
| bridge memory window | 64-bit only |
| virtio consoles on the bus | **two** |
| console features offered | **none** — not MULTIPORT, SIZE or EMERG_WRITE |
| transport features offered | `VERSION_1`, `RING_PACKED`, and nothing else |
| `num_queues` | 4 |

## What works

Queue 0, packed ring, one descriptor with flags `0x0082` — AVAIL set, USED
clear, WRITE set. The device completes it **and** the host's input bytes appear
in the buffer. Ring, DMA and data transfer all demonstrably work.

The entropy device on the same bus completes a split-ring descriptor and writes
real random bytes, so the transport is sound independently of the console.

## What does not

Queue 1, packed, flags `0x0080` — never completes, nothing ever reaches the
host. Queue 2 never completes. Queue 3 completes device-readable descriptors
and emits nothing, which is how a control queue behaves.

## Ruled out

Each of these was tested on the machine, not reasoned about:

- **The wrap counter.** Initialised to 1, so available is AVAIL=1 USED=0 —
  the same encoding queue 0 uses successfully.
- **The doorbell.** Notification offsets 0,1,2,3 with multiplier 4, read from
  the notify capability. Ringing every doorbell with every value after posting
  on queue 1 changes nothing.
- **Addresses.** The device reads back the descriptor address written to it.
  The MMU is off, so virtual equals physical.
- **`queue_enable`**, which reads back 1 for every queue.
- **MSI-X**, set to `0xFFFF` for the config and every queue.
- **Queue size**, both shrunk to 8 and left at the device's own.
- **`DRIVER_OK` ordering**, set after every queue is configured and after the
  receive buffer is posted, as Linux does.
- **Split rings**, which this device does not service at all.
- **Both console instances.**
- **The emergency-write config register**, which emits nothing.
- **The multiport control handshake** — `DEVICE_READY`, `PORT_READY`,
  `PORT_OPEN` — sent on queue 3 and on queue 2. The device consumes them from
  queue 3 and nothing changes. A buffer posted on the control receive queue
  comes back **unwritten**, so the device announces no ports.
- **The shape of the host's end**: a pipe, and a real file.

## Where a consortium landed

Six models across two vendors were asked, twice, with the ruled-out list in
front of them. Three converged on the wrap counter, which is already correct.
One proposed an eight-byte per-buffer header, which virtio-console does not
have. One proposed split-ring event indices, which are not negotiated. The
sharpest answer was the multiport handshake, which had already been tried and
was tried again on their advice; it does not work.

Worth recording: the bench agreed on something wrong more readily than it found
something right. That is the failure mode the consortium's appeal round exists
for, and it applies to debugging advice as much as to code review.

## The one asymmetry nobody has explained

A receive completes because the **host** delivers data: the device reads the
ring when input arrives, whether or not it ever saw a notification. A transmit
completes only if the device notices a notification, because nothing else
prompts it.

So "receive works" is not evidence that notifications work. Queue 3 consuming
control messages is the only evidence for that, and it is weak — a device may
poll its control queue.

If notifications are in fact never seen, everything observed follows. What has
not been found is a mechanism by which they would be lost, given that the
offsets and multiplier read correctly and every doorbell has been rung.

## What to try next

Read Linux's `virtio_ring.c` packed path and `virtio_console.c` initialisation
against this driver line by line. There is now a working reference on the same
machine, which makes that a reading exercise rather than a guess. Start with
what the reference does between `find_vqs` and the first transmit, and with
whether it ever writes the driver event suppression structure.
