# ARMV1 — the video format armedit can decode by itself

armedit has no libraries. Everything it draws, it draws from bytes it
understands, and that has to stay true for video or the bootable mode stops
being the same program as the window mode. So there is a format here, and it
is small enough to decode in assembly without apology.

The design follows from one constraint: **the decoder must be a few hundred
instructions and hold no state beyond one previous frame.** That rules out
transforms, motion vectors and entropy coders, and it leaves the oldest
combination that still works — a palette, run-length coding, and inter-frame
differences. It is roughly what Autodesk FLIC did in 1990, which is the right
company to keep: it compresses screen content, drawings and animation very
well, ordinary camera footage poorly, and it never needs a multiply to
reconstruct a pixel.

## Layout

All integers little-endian, which is what the machine already is.

```
offset  size    field
0       4       "ARMV"
4       1       version, currently 1
5       1       reserved, 0
6       2       width in pixels
8       2       height in pixels
10      2       frame count
12      2       frames per second
14      2       palette entry count, 1..256
16      3*N     palette: R, G, B per entry
```

Then one record per frame, back to back to the end of the file:

```
4       payload length, in bytes, not counting these 4 or the type byte
1       type: 0 = key, 1 = delta
L       payload
```

Frame 0 is always a key frame. So is every frame that follows a scene change,
which is what makes seeking and looping possible: rewinding to the start never
needs a frame that was thrown away.

## Key frames

A run-length stream over palette indices:

```
1       count, 1..255
1       palette index
```

Repeated until `width * height` pixels have been produced. A key frame is
self-contained — nothing before it is consulted.

## Delta frames

A stream of ops over the *previous* frame's pixels, in raster order:

```
op & 0x80 == 0   skip (op & 0x7F) + 1 pixels — they keep the colour they had
op & 0x80 != 0   copy (op & 0x7F) + 1 pixels — that many index bytes follow
```

So a run is 1..128 pixels either way, and a frame where nothing moved is a
handful of skip bytes. The stream ends when `width * height` pixels have been
accounted for; a decoder that reaches the payload end early stops there and
leaves the rest of the frame as it was, which is what a truncated download
should look like rather than a crash.

## What this costs

For the synthetic content armedit actually shows — a bouncing square, a plot,
a terminal recording, an animation somebody generated — a delta frame is
typically under 2% of a raw frame, because most of the screen did not change
and a skip run covers it in one byte. For camera footage it is bad, sometimes
worse than raw, and it should be: dithering a photograph to 256 colours
destroys exactly the smooth gradients that RLE needs to find runs in.

The honest boundary is this: **ARMV1 is for pictures a computer drew.** Video
from a camera needs a transform codec, and a transform codec needs a decoder
an order of magnitude larger than this one. That is a later milestone, not a
hidden limitation of this one.

## Getting internet video into it

The client only ever sees ARMV1. Anything else is converted before it arrives,
by the backend, and the conversion is written from scratch for the same reason
the decoder is:

- **Animated GIF** — a complete from-scratch path (LZW, frame disposal,
  transparency composition). GIF is already palette-and-delta, so the
  conversion is nearly a transliteration and loses nothing.
- **MJPEG** — baseline JPEG per frame, then quantise to a palette. Written,
  lossy at the quantise step, honest about it.
- **H.264 / VP9 / AV1** — not implemented, and not planned as from-scratch
  work. A URL pointing at one of these returns a clear error rather than a
  silent still frame.

The size limits the client enforces are 320x240 and 4096 frames. Anything
larger is scaled and decimated during conversion, on the backend, where there
is room to do it.
