# asmedit

A text editor written entirely in aarch64 assembly, that runs two ways:

- **hosted** — as a macOS window (or in a terminal), on top of a normal OS
- **bare metal** — as its own kernel, with no operating system underneath it

Both modes share one source tree and one font. Every glyph on screen was
rasterized by `font/render.S` from a bitmap font whose scanlines were written
out by hand — no text API, no UI toolkit, no font library anywhere in the
pipeline. The kernel has no firmware under it either: `kernel/boot.S` holds the
first instructions the machine executes.

The editor talks to one server — its own backend — using one credential. The
backend is where Claude, [aicoin](https://aicoin.oeaio.com) and AWS live.

```
   ┌──────────────────────┐        ┌──────────────────────┐
   │ asmedit (hosted)     │        │ asmedit (bare metal) │
   │  macOS window / tty  │        │  own kernel, ramfb   │
   └──────────┬───────────┘        └──────────┬───────────┘
              │      one asmedit key,         │
              │      one protocol             │
              └───────────────┬───────────────┘
                              ▼
                   ┌──────────────────────┐
                   │ asmeditd             │  assembly, no libraries
                   │ asmedit.oeaio.com    │  the only holder of secrets
                   └───────┬──────────┬───┘
                           ▼          ▼
                 aicoin proxy       EC2
                 (Claude, billed    (one minimal Linux
                  to your wallet)    instance, Docker up)
```

## The single key

The editor never holds an aicoin wallet token and never holds AWS credentials.
You register once at `asmedit.oeaio.com`, bind **both** accesses, and receive
**one opaque asmedit key**. That key is all a device needs, and the only
credential that ever reaches one.

Registration refuses half an account. Without a wallet token the account cannot
pay for a model call; without AWS credentials it cannot be given an instance.
Issuing a key for either half alone would only fail later, further from the
cause.

Consequently there are **no tokens in this repository** — credentials live in
the backend's environment and nowhere else. `.gitignore` refuses the usual
suspects as a second line of defence, not a first one.

## Using it

Requires `qemu-system-aarch64` and `lld` (`brew install qemu lld`); the
assembler and the Mach-O linker ship with Xcode.

```
make                    # everything: both hosted modes, the kernel, the backend
make serve              # run the backend, then open http://localhost:8080 to register
ASMEDIT_KEY=<key> make win     # the editor, bound to that account
make run                # terminal mode:  make run TEXT="HELLO WORLD"
make boot               # boot the kernel in QEMU, with a framebuffer
make boot-tty           # boot it headless, serial on your terminal
```

The editor opens with its instance already attached: on start it asks the
backend for this account's instance, and the backend either reuses the one it
has or brings one up.

### Keys

| | |
|---|---|
| `Cmd`+`T` | new screen |
| `Cmd`+`←` / `Cmd`+`→` | previous / next screen |
| `Cmd`+`Delete` | close this screen |
| `Cmd`+`↑` / `Cmd`+`↓` | page up / page down |
| `Cmd`+`Enter` | ask about this screen; the answer is appended |
| `Cmd`+`P` | rewrite this screen in place, keeping the caret where it was |
| click | place the caret; click the bar to switch screens |

`Cmd`+`P` sends both the current text and the text as of the last exchange, so
the far side sees *the edit*, not just the file.

### Backend configuration

Everything is environment, nothing is committed.

| variable | meaning |
|---|---|
| `ASMEDIT_PORT` | backend listen port (default 8080) |
| `ASMEDIT_AICOIN` | aicoin proxy address, `ip:port` |
| `ASMEDIT_AWS_ADDR` | EC2 endpoint address, `ip:port` |
| `ASMEDIT_AMI` | image the account's instance runs |
| `ASMEDIT_INSTANCE_TYPE` | default `t4g.small` |
| `ASMEDIT_BACKEND` | *(editor)* backend address, default `127.0.0.1:8080` |
| `ASMEDIT_KEY` | *(editor)* the key from registration |

### Protocol

What a device may say, and all it may say:

```
POST /api/agent      X-Asmedit-Key
     {mode:"agent"|"aify", screen, scroll, rows, baseline, context} -> {text}
POST /api/session    X-Asmedit-Key -> {instance}
POST /api/teardown   X-Asmedit-Key -> {instance:""}
```

and, from a browser rather than a device:

```
GET  /                registration page
POST /api/register    {wallet, aws_key, aws_secret, region} -> {key}
```

## Layout

| path | what lives there |
|---|---|
| `include/asm.inc` | the only place the Mach-O and bare-ELF targets differ |
| `font/font.S` | the 5×7 bitmap font: 69 hand-drawn glyphs, and the lookup |
| `font/render.S` | glyph → pixels, into any 32-bit buffer (shared by all modes) |
| `editor/editor.S` | screens, cursor, scrolling, drawing — and no I/O at all |
| `app/window.S` | macOS window; `NSView` subclassed at runtime, in assembly |
| `app/tty.S` | terminal mode — one `write` syscall, no libc |
| `app/backend_client.S` | the editor's entire view of the world |
| `kernel/` | boot, PL011 serial, fw_cfg DMA, ramfb, scrolling console |
| `net/` | sockets, HTTP/1.1 client and server, JSON and string primitives |
| `crypto/` | SHA-256 and HMAC-SHA256 |
| `backend/` | the daemon, registration page, SigV4, aicoin, EC2 |

## Status

What runs today, verified by running it:

- [x] hand-built 5×7 font, 69 glyphs, one shared rasterizer
- [x] hosted terminal mode and hosted window mode
- [x] bare-metal kernel: boots, brings up a framebuffer, scrolling console
- [x] editor: screens, caret, mouse, paging, edit-aware rewrite
- [x] SHA-256 (FIPS vectors), HMAC-SHA256 (RFC 4231), SigV4 (matches an
      independent reference byte for byte)
- [x] backend: registration, key issue, the agent round trip through aicoin,
      EC2 run/terminate signed by our own SigV4
- [ ] **TLS** — the backend speaks plain HTTP, so today it reaches AWS and
      aicoin through an endpoint that terminates TLS for it. A TLS 1.3 client
      in assembly is the next milestone and the last thing between this and
      `ec2.amazonaws.com` directly
- [ ] keyboard and networking in the bare-metal kernel (it renders; it does not
      yet type or talk)
- [ ] accounts survive only as long as the daemon does
- [ ] one connection at a time, by design for now

## Ground rules

1. **All code is assembly.** Not "mostly": the font, the rasterizer, the
   editor, the kernel, the crypto, the HTTP stack and the backend are `.S`
   files. The only non-assembly artifacts are a linker script and a Makefile.
2. **No frameworks doing our work.** System libraries appear only where the
   platform gives no alternative — AppKit to obtain a window on macOS, nothing
   at all on bare metal — never to draw a glyph, sign a request or parse a
   reply.
3. **No credentials in the tree.** See above.
