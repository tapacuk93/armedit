# asmedit

A text editor written entirely in aarch64 assembly, that runs two ways:

- **hosted** — as a macOS window (or in a terminal), on top of a normal OS
- **bare metal** — as its own kernel, with no operating system underneath it

Both modes share one source tree and one font. Every glyph you see on screen was
rasterized by `font/render.S` from a bitmap font whose scanlines were written out
by hand — there is no text API, no UI toolkit, and no font library anywhere in
the pipeline. The kernel has no firmware under it either: `kernel/boot.S` is the
first instruction the machine executes.

The editor talks to Claude through an [aicoin](https://aicoin.oeaio.com) wallet,
and to an assembly backend that provisions and tears down AWS resources on
demand. The device itself holds exactly one secret: a key issued by
`asmedit.oeaio.com`.

```
   ┌──────────────────────┐        ┌──────────────────────┐
   │ asmedit (hosted)     │        │ asmedit (bare metal) │
   │  macOS window / tty  │        │  own kernel, ramfb   │
   └──────────┬───────────┘        └──────────┬───────────┘
              │        one asmedit key        │
              └───────────────┬───────────────┘
                              ▼
                   ┌──────────────────────┐
                   │ asmedit backend      │   asm, no libraries
                   │ asmedit.oeaio.com    │
                   └───────┬──────────┬───┘
                           ▼          ▼
                 aicoin proxy      AWS API
                 (Claude, billed   (provision /
                  per call)         deprovision)
```

## Why the single key matters

The client never holds an aicoin wallet token and never holds AWS credentials.
It registers once at `asmedit.oeaio.com`, binds its wallet and its AWS access
there, and receives **one opaque asmedit key**. That key is all the editor needs
to start, and it is the only credential that ever reaches a device.

Consequently there are **no tokens in this repository**, and there is nothing to
leak in a screenshot of a booting kernel. Credentials live in the environment of
the machine running the backend, and nowhere else. `.gitignore` refuses the
usual suspects (`.env`, `*.pem`, `*.key`, `*.token`) as a second line of
defence, not a first one.

## Build and run

Requires `qemu-system-aarch64` and `lld` (`brew install qemu lld`); the
assembler and the Mach-O linker ship with Xcode.

```
make            # everything
make run        # terminal mode:  make run TEXT="HELLO WORLD"
make win        # macOS window
make boot       # boot the kernel in QEMU, with a framebuffer
make boot-tty   # boot it headless, serial on your terminal
```

`make boot` opens a QEMU window showing text the kernel drew itself, pixel by
pixel, into a `ramfb` framebuffer it configured over fw_cfg DMA.

## Layout

| path | what lives there |
|---|---|
| `include/asm.inc` | the only place the Mach-O and bare-ELF targets differ |
| `font/font.S` | the 5×7 bitmap font: 69 hand-drawn glyphs, and the lookup |
| `font/render.S` | glyph → pixels, into any 32-bit buffer (shared by all modes) |
| `app/tty.S` | hosted mode, terminal — one `write` syscall, no libc |
| `app/window.S` | hosted mode, window — AppKit driven through the bare ObjC runtime |
| `kernel/boot.S` | power-on: stack, `.bss`, and into `kmain` |
| `kernel/fwcfg.S` | fw_cfg DMA, and handing our framebuffer to the host scanout |
| `kernel/console.S` | scrolling text console over raw pixels |
| `backend/` | the asm backend: aicoin, AWS, and the asmedit key |

## Status

This is an early, working foundation, not a finished product. What runs today:

- [x] hand-built 5×7 font, 69 glyphs, one shared rasterizer
- [x] hosted terminal mode
- [x] hosted window mode (real macOS window, our pixels)
- [x] bare-metal kernel: boots, brings up a framebuffer, scrolling console
- [ ] keyboard input, editable buffer — the *edit* half of asmedit
- [ ] network stack in the kernel
- [ ] backend: HTTP, SHA-256/HMAC, AWS SigV4, EC2 provision/deprovision
- [ ] `asmedit.oeaio.com`: registration, wallet binding, key issue
- [ ] Claude in the editor, billed through aicoin

Everything above the line is verified by running it, not by reading it.

## Ground rules

1. **All code is assembly.** Not "mostly": the font, the rasterizer, the kernel,
   the network path and the backend are `.S` files. The build is `make`, the
   only non-asm artifact is a linker script.
2. **No frameworks doing our work.** System libraries appear only where the
   platform gives no alternative — AppKit to obtain a window on macOS, and
   nothing at all on bare metal — never to draw a glyph or shape text.
3. **No credentials in the tree.** See above.
