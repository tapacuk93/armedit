# asmedit

A text editor written in aarch64 assembly, that runs two ways:

- **hosted** — as a macOS window (or in a terminal), on top of a normal OS
- **bare metal** — as its own kernel, with no operating system underneath it

Both modes share one source tree and one font. Every glyph on screen was
rasterized by `font/render.S` from a bitmap font whose scanlines were written
out by hand — no text API, no UI toolkit, no font library anywhere in the
pipeline. The kernel has no firmware under it either: `kernel/boot.S` holds the
first instructions the machine executes.

The editor talks to one server — its own backend — and carries one credential.
The backend reaches models through [aicoin](https://aicoin.oeaio.com), which
fronts Claude and the other providers, and it is the only thing that ever holds
an AWS credential.

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
                   │ asmeditd (Java 25)   │  the only holder of secrets
                   │ asmedit.oeaio.com    │
                   └───────┬──────────┬───┘
                           ▼          ▼
                 aicoin proxy       EC2
                 (Claude and the    (one minimal Linux
                  other providers,   instance, Docker up)
                  billed to your
                  wallet)
```

## One property

A device is configured with exactly one value: **`ASMEDIT_KEY`**.

The key issued at registration carries the address to reach the backend at —
`<secret>@<host:port>` — so there is no second setting to get wrong and no
endpoint compiled into the binary. Without that one value, `Cmd`+`Enter` and
`Cmd`+`P` do nothing at all: the editor still opens, still edits, still saves,
it simply has nowhere to ask.

The editor never holds an aicoin wallet token and never holds AWS credentials.
Registration binds **both** accesses — without a wallet token an account cannot
pay for a call, and without AWS credentials it cannot be given an instance —
plus a password, which seeds that account's pad windows.

Consequently there are **no tokens in this repository**. Credentials live in
the backend's environment and nowhere else; `.gitignore` refuses the usual
suspects as a second line of defence, not a first one.

## Using it

Requires `qemu-system-aarch64` and `lld` (`brew install qemu lld`) for the
assembly targets, and a JDK 25 for the backend. The assembler and the Mach-O
linker ship with Xcode.

```
make                             # both hosted modes and the kernel
java backend-java/src/Asmeditd.java   # the backend, straight from source
ASMEDIT_KEY=<key> make win       # the editor, bound to that account
make run                         # terminal mode: make run TEXT="HELLO WORLD"
make boot                        # boot the kernel in QEMU, with a framebuffer
make boot-tty                    # boot it headless, serial on your terminal
```

Open `http://localhost:8080/` to register and receive a key. The editor opens
with its instance already attached: on start it asks the backend for this
account's instance, and the backend either reuses the one it has or brings one
up.

### Keys

| | |
|---|---|
| `Cmd`+`T` | new screen |
| `Cmd`+`←` / `Cmd`+`→` | previous / next screen |
| `Cmd`+`Delete` | close this screen |
| `Cmd`+`↑` / `Cmd`+`↓` | page up / page down |
| `Cmd`+`Shift`+`↑` / `↓` | start / end of this screen |
| `Cmd`+`Enter` | ask about this screen; the answer is appended |
| `Cmd`+`P` | act on this screen: rewrite at the caret, or go and do the thing |
| `Cmd`+`+` / `Cmd`+`-` | font size |
| `Cmd`+`0`…`9` | ink colour |
| click | place the caret; click the bar to switch screens |

`Cmd`+`P` sends both the current text and the text as of the last exchange,
along with the caret offset, so the far side sees *the edit* and knows where
its reply will land.

## What `Cmd`+`P` is for

Booted as an OS, this is a notepad. You write a list, an idea, a bug. You press
`Cmd`+`P` and something happens to it — the list gets updated, a suggestion
appears at the caret, nothing at all happens because nothing needed to, or a
machine somewhere checks out a repository, fixes the bug and publishes a build.

Which of those it is depends on what you wrote, and that is the whole design:
one key, one meaning — *act on this* — and the backend decides how much acting
is warranted.

Reaching real infrastructure is the part that has to be got right. The model
never receives an AWS credential: it writes an action line, the backend judges
it, signs it with the account's own keys, runs it, and hands back a redacted
result. Reads run unattended; anything that changes infrastructure comes back
to you for confirmation; identity APIs are refused outright.
See [docs/aws-and-the-model.md](docs/aws-and-the-model.md) — it matters most
because aicoin shares one provider key across users, so anything in a prompt
should be considered disclosed.

### Backend configuration

Server-side settings, all environment, none committed.

| variable | meaning |
|---|---|
| `ASMEDIT_PORT` | listen port (default 8080) |
| `ASMEDIT_PUBLIC_ADDR` | the address to bake into issued keys |
| `ASMEDIT_AICOIN` | aicoin proxy base URL |
| `ASMEDIT_PROVIDER` | which provider aicoin should route to (default `anthropic`) |
| `ASMEDIT_MODEL` | model override (default `claude-opus-5`) |
| `ASMEDIT_AWS_ADDR` | EC2 endpoint override, for a local or proxied endpoint |
| `ASMEDIT_AMI` | image the account's instance runs |
| `ASMEDIT_INSTANCE_TYPE` | default `t4g.small` |
| `ASMEDIT_WORKSPACE` | where accounts' folders live (default `workspaces`) |
| `ASMEDIT_S3_BUCKET` | third tier of persistence; unset means disk only |
| `ASMEDIT_IDLE_MINUTES` | terminate an idle account's instance (default 30, 0 disables) |
| `ASMEDIT_REAP_SECONDS` | how often to sweep for idle accounts (default 60) |

### Protocol

What a device may say, and all it may say:

```
POST /api/agent      X-Asmedit-Key
     {mode:"agent"|"aify", screen, scroll, rows, cursor, baseline, context} -> {text}
POST /api/session    X-Asmedit-Key -> {instance}
POST /api/teardown   X-Asmedit-Key -> {instance:""}
POST /api/journal    X-Asmedit-Key; {screen, op|kind, at, text|word, dx, dy} -> {ok}
GET  /api/clouds     X-Asmedit-Key -> {bound}
POST /api/clouds     X-Asmedit-Key; {provider, ...fields} -> {provider, complete}
GET  /api/otp        X-Asmedit-Key -> the pad ledger for this account
POST /api/otp/reserve X-Asmedit-Key -> {pad, bits, window}
```

and, from a browser rather than a device:

```
GET  /                registration page
POST /api/register    {wallet, aws_key, aws_secret, region, password} -> {key}
```

## Which model, and which cloud

**The server picks the model.** Most presses of `Cmd`+`P` are small — a list to
tidy, a line to finish — and sending those to the largest model available is
just slow and expensive. The router reads the state of the screen (length, how
code-shaped it is, whether it mentions infrastructure, how big the edit was)
and starts on the cheapest tier that fits.

**A model can hand over.** One that finds itself in the wrong seat writes a
line and stops:

```
#HANDOFF opus  this needs to reason about the whole repository
```

The backend re-asks the named model, carrying the transcript and the reason. A
handoff is a routing decision made with more information than the router had —
which is why it is allowed, and why it is capped at two per exchange, because
it costs another call.

**The account picks the cloud, or the model does.** The homepage takes
credentials for AWS, Hetzner, DigitalOcean, GCP and Azure. With more than one
bound, work goes to whichever can run it most cheaply — unless it names
resources that only live somewhere specific, in which case it goes there. The
model chooses a provider *by name*; it never sees a credential for any of them.

## What the user did, not just what is there

A screen's text says where you ended up. The journal says how: every insertion,
every **deletion**, every tap on a word, every swipe.

Both halves matter. A screen that no longer mentions something was changed by
someone deciding it should not be mentioned, and that decision is invisible in
the final text — so removals are recorded, not just the result. And the model
is shown the recent history, because "the user just deleted the retry block and
tapped on `timeout`" is a different question from the same screen with no
history.

```
<workspace>/<account-id>/screen-3/edits.jsonl      every edit, removals included
<workspace>/<account-id>/screen-3/gestures.jsonl   taps, swipes, scrolls
```

## Where the text lives

Memory, then disk, then cloud.

Each account gets a folder, and each screen gets a folder inside it — the same
shape the provisioned machine sees in its home directory, so "screen 3" means
one thing whether you are typing into it or running something against it:

```
<workspace>/<account-id>/screen-3/text.md      the current text
<workspace>/<account-id>/screen-3/text.1.md    the previous megabyte
<workspace>/<account-id>/aws-audit.log         what the agent asked AWS for
```

Files rotate at 1 MB, before the write that would cross the line rather than
after. Nothing is written on a request thread: a screen is handed to a writer
thread and the caller returns. Losing the last few seconds of typing to a crash
is acceptable; making a keystroke wait on a disk — let alone on S3 — is not.

## The pad, and the bit ledger

Both ends count the exact number of bits that have crossed the link, and that
count is the only framing there is. Reservation windows sit at offsets derived
from the account's own seed, so at any bit position both ends already agree on
whether what follows is data or a pad reservation. Nothing on the wire says
which, and an observer without the seed cannot tell where one ends and the
other begins.

The seed is `SHA-256(server private random ‖ creation nanosecond ‖ account id ‖
password)`. Two accounts registered in the same nanosecond with the same
password still diverge, because the server's random value is in the hash and
never leaves the process.

Pad bytes are real `SecureRandom`, handed over once, and zeroed as they are
spent — that is what makes this a pad rather than a stream cipher. The seed
decides only *where* the windows fall, never what the pad contains.

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
| `crypto/` | SHA-256, HMAC, ChaCha20, Poly1305, AEAD, HKDF, X25519 |
| `backend-java/src/` | the backend: routing, accounts, aicoin, EC2, the pad |
| `backend/` | the earlier assembly backend, kept until the Java one is proven |

## Status

Verified by running it, against published test vectors where they exist:

- [x] hand-built 5×7 font, 69 glyphs, one shared rasterizer
- [x] hosted terminal mode and hosted window mode
- [x] bare-metal kernel: boots, brings up a framebuffer, scrolling console
- [x] editor: screens, caret, mouse, paging, edit-aware rewrite
- [x] SHA-256 (FIPS), HMAC (RFC 4231), AWS SigV4 (byte-identical to an
      independent reference)
- [x] ChaCha20, Poly1305 and the AEAD (RFC 8439), HKDF (RFC 5869),
      X25519 (RFC 7748) — the whole symmetric and key-agreement half of TLS 1.3
- [x] backend round trip: registration, key issue, aicoin call, signed EC2
      run/terminate — proven against the assembly implementation

Written but not yet compiled or run:

- [ ] the Java 25 backend in `backend-java/` — a like-for-like replacement for
      the assembly one, plus the pad ledger, the workspace tiers, the idle
      reaper, the AWS agent with its policy gates, the model router and
      handoff, multi-cloud credentials, and the edit/gesture journals
- [ ] `Cmd`+`Shift`+arrows, `Cmd`+`+`/`-`, `Cmd`+`0`…`9`, the one-property key,
      and the no-key no-op

Next, in rough order:

- [ ] **TLS 1.3 client in assembly** — the primitives are done and verified; the
      handshake, record layer and certificate pinning are not. Until then the
      backend reaches AWS and aicoin over TLS from Java, and the editor talks
      to its backend in the clear
- [ ] local persistence on the device itself: everything typed written to disk
      asynchronously, rotating at 1 MB, so a screen survives losing the backend
- [ ] mounting the account's folders into the provisioned machine's home
      directory, so the agent works on the same files you are typing into
- [ ] the editor emitting edits and gestures: the journal endpoint and storage
      exist, nothing sends to them yet
- [ ] provisioning on anything but AWS — the other clouds take credentials and
      are compared on price, but only EC2 is actually brought up
- [ ] iOS: the same editor core behind a UIKit front end — paste,
      tap-as-cursor, and landscape
- [ ] keyboard and networking in the bare-metal kernel (it renders; it does not
      yet type or talk)
- [ ] accounts survive only as long as the daemon does

## Ground rules

1. **The client is assembly.** The font, the rasterizer, the editor, the
   kernel, the crypto and the HTTP stack are `.S` files. The backend is Java,
   because that is where TLS, an HTTP server and the AWS wire format are worth
   having for free.
2. **No frameworks doing our work on the client.** System libraries appear only
   where the platform gives no alternative — AppKit to obtain a window on
   macOS, nothing at all on bare metal — never to draw a glyph, sign a request
   or parse a reply.
3. **No credentials in the tree.** See above.
