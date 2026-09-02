# armedit

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
   │ armedit (hosted)     │        │ armedit (bare metal) │
   │  macOS window / tty  │        │  own kernel, ramfb   │
   └──────────┬───────────┘        └──────────┬───────────┘
              │      one armedit key,         │
              │      one protocol             │
              └───────────────┬───────────────┘
                              ▼
                   ┌──────────────────────┐
                   │ armeditd (Java 25)   │  the only holder of secrets
                   │ armedit.oeaio.com    │
                   └───────┬──────────┬───┘
                           ▼          ▼
                 aicoin proxy       EC2
                 (Claude and the    (one minimal Linux
                  other providers,   instance, Docker up)
                  billed to your
                  wallet)
```

## One property

A device is configured with exactly one value: **`ARMEDIT_KEY`**.

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
java backend-java/src/Armeditd.java   # the backend, straight from source
ARMEDIT_KEY=<key> make win       # the editor, bound to that account
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

## Opening a site

Write `open example.com`, press `Cmd`+`Enter`, and the page is on the screen.
There is no browser mode — it is the same key that hands a screen to a model,
because from the editor's side those are one request with two sources.

It goes two ways, and the choice between them is the point:

A page arrives with its links numbered at the bottom, whichever route it came
by, so `open 3` opens the third one. The screen is the link table — which also
means you can see what you are about to open, and edit the line if you want
somewhere else.

**Directly.** Resolve the name, open a socket, send a `GET`, and `net/html.S`
turns the reply into text. Nothing in the middle, nobody else's logs, no
backend needed. This is better whenever it works.

**Through the backend.** It fetches and hands back text. This is the only route
that works for `https` — the editor has no TLS yet — and the only one that
works on a bare-metal machine, which has no resolver at all.

Direct first, backend when direct cannot, and the working route is remembered
per host so the second visit skips the discovery. Deliberately not a race: a
race fetches every page twice, and the loser's request still arrived at
somebody's server.

A route that *cannot* work is not attempted, and that turned out to matter more
than it sounds. Sending a plain `GET` to port 443 does not fail — a TLS server
answers `400 The plain HTTP request was sent to HTTPS port`, which is a page. It
parses, it renders, and it lands on the screen looking like the site said it,
while the fallback never runs because nothing failed.

`/api/fetch` is not an open proxy. `http` and `https` only, every redirect hop
re-checked, and anything resolving to loopback, link-local or a private range
refused — `http://localhost:8090/api/stats` is a URL, and `169.254.169.254` is
where every cloud keeps its credentials.

## Operations the editor learns

The same request, asked by enough different people, stops being a question and
becomes a feature.

`Cmd`+`P` starts by asking a model. That is slow and it costs money, so the
answer is cached — but a cache only helps the person who asks the identical
thing. What helps everyone is the model noticing, mid-answer, that what it just
wrote was not about this person at all, and teaching the server to answer the
next one itself:

```
#SCRIPT set-colour :: colours {name:colour}
#JS
if (name == "blue") { return "#COLOUR 3"; }
return "";
#END
```

That is an *operation*. Its pattern has typed holes, so it understands rather
than merely matches — `{name:colour}` accepts a colour the editor has and
nothing else, and returning empty means "not me", which sends the request back
to a model as though the operation had never matched. Declining is half of what
these are for; an operation that guesses is worse than none, because a wrong
fast answer looks exactly like a right one.

Operations are compiled ahead of time to aarch64. The device can then run one
without a network at all, which is the point: `colours blue` works on a laptop
with the wifi off, and on bare metal where there is no operating system to fall
back to.

Every operation is handed the whole screen, after its own variables. An
operation that matched two words can rewrite the entire document — the
difference between answering a sentence and answering a request.

### The consortium

Machine code that ships to everybody is not the kind of decision one model
should make alone.

An answer on your screen is yours: you can see it, and if it is wrong you
retype the line. A compiled operation committed to this repository is none of
those things — it runs on machines whose owners never asked for it, and by the
time it is wrong it is wrong everywhere. So the last gate before the repository
is not the model that wrote the operation. It is every model the wallet can
reach, asked separately:

```
armedit: consortium seats 6 of 40 eligible models, across 2 provider(s)
bench: [openai:o4-mini, anthropic:claude-sonnet-5, openai:o3-mini,
        anthropic:claude-opus-5, openai:o3, anthropic:claude-haiku-4-5]
VERDICT COMMIT - 4 of 6 members, unanimous
```

Seats go round the providers rather than down the list. Sorted by name, one
vendor's models occupy the whole front of the queue — the first sitting this
ran filled all six seats with one vendor, which is a single opinion with five
corroborations, and worse than one opinion because it looks like agreement.

Members do not see each other's votes. A consortium that passes opinions along
manufactures agreement without producing evidence, and agreement is the thing
being measured.

A commit needs everyone who answered to agree, above a quorum of three — one
credible objection is enough, because holding costs a release and committing
costs everybody. But unanimity has a failure mode, and it appeared immediately:
the cheapest model on the bench answered "this should be verified and audited",
which is true of all code, names nothing, and blocks everything forever. So an
objection is put back to the members who did not raise it, and stands unless
most of them say it is wrong or says nothing.

What gets written, on approval, is three files under `ops/`: the machine code,
its source and pattern, and every member's reasoning. The reasoning is
committed because a decision without it is not reviewable later — "the
consortium approved it" is otherwise a claim about a conversation nobody kept.

Nothing here runs `git`. A daemon that commits on its own is one that can
rewrite history while nobody is looking; the value is in the files being
reviewable, not in them appearing unattended.

**What this is not.** It is not a fact-checker. On its first sitting over its
own source, a member held the change because an API parameter "does not exist"
— specific, confident, and false: both spellings had been put to the proxy
before the code was written, and the newer one is the one that works. A
consortium is good at vagueness and at real defects in code in front of it, and
bad at the world having moved since it was trained. That is why the appeal asks
whether an objection is *correct* rather than merely specific, and why claims
about the world get checked by making the call.

### Backend configuration

Server-side settings, all environment, none committed.

| variable | meaning |
|---|---|
| `ARMEDIT_PORT` | listen port (default 8080) |
| `ARMEDIT_PUBLIC_ADDR` | the address to bake into issued keys |
| `ARMEDIT_AICOIN` | aicoin proxy base URL |
| `ARMEDIT_PROVIDER` | which provider aicoin should route to (default `anthropic`) |
| `ARMEDIT_MODEL` | model override (default `claude-opus-5`) |
| `ARMEDIT_AWS_ADDR` | EC2 endpoint override, for a local or proxied endpoint |
| `ARMEDIT_AMI` | image the account's instance runs |
| `ARMEDIT_INSTANCE_TYPE` | default `t4g.small` |
| `ARMEDIT_WORKSPACE` | where accounts' folders live (default `workspaces`) |
| `ARMEDIT_S3_BUCKET` | third tier of persistence; unset means disk only |
| `ARMEDIT_IDLE_MINUTES` | terminate an idle account's instance (default 30, 0 disables) |
| `ARMEDIT_REAP_SECONDS` | how often to sweep for idle accounts (default 60) |

### Protocol

What a device may say, and all it may say:

```
POST /api/agent      X-Armedit-Key
     {mode:"agent"|"aify", screen, scroll, rows, cursor, baseline, context} -> {text}
POST /api/session    X-Armedit-Key -> {instance}
POST /api/teardown   X-Armedit-Key -> {instance:""}
POST /api/journal    X-Armedit-Key; {screen, op|kind, at, text|word, dx, dy} -> {ok}
GET  /api/clouds     X-Armedit-Key -> {bound}
POST /api/clouds     X-Armedit-Key; {provider, ...fields} -> {provider, complete}
GET  /api/otp        X-Armedit-Key -> the pad ledger for this account
POST /api/otp/reserve X-Armedit-Key -> {pad, bits, window}
```

and, from a browser rather than a device:

```
GET  /                registration page
POST /api/register    {wallet, aws_key, aws_secret, region, password} -> {key}
```

## Touch

A phone has one input and five meanings, so nothing acts on touch-down: what a
touch was is decided when the finger lifts, from how long it stayed and how far
it went.

| | |
|---|---|
| tap a key | type it |
| tap text | place the caret |
| **swipe over words** | hand them to the model — "do something with this" |
| **swipe left / right** | the previous or next screen |
| **long press a word** | open a screen *about that word* |
| long press a key | open a screen about the keyboard |
| long press empty space | ASK and REWRITE, under the finger |
| two fingers | paste |

Selections snap outwards to whole words, because a swipe is a gesture and
gestures are not precise: the user meant the words they dragged across, not the
two characters their finger started and stopped on.

Screens have a **subject**. Long-pressing `build` opens a screen bound to that
word, and the subject travels with every request from it — so "make it faster"
typed there is understood to be about the build, without restating it. The
swipe and what the model did with it both go into the file history: a screen
that changed says what it says *now*, but only the journal says the user swiped
these words and asked.

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

**The list of models is asked for, not assumed.** aicoin forwards
`GET /v1/models` to each provider, and that path is free, so the backend
refreshes its catalogue on a timer without spending coins on bookkeeping. A
hardcoded list is wrong the day a provider ships something — and wrong
silently, with the router still choosing between three names while a fourth
sits unused.

**Each model is told what the others are for, and what the record says.**
The record is behaviour, not grades: nobody scores the answers, so what gets
counted is how often a model hands this kind of work to someone else, how often
the user comes straight back and asks again, how long it took, and how often it
failed. A handoff is the strongest signal there, because it is the model's own
judgement that it was the wrong choice. `GET /api/stats` shows the table.

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
| `net/` | sockets, HTTP client and server, JSON and string primitives |
| `net/browse.S` | opening a site: direct, or through the backend, and remembering which |
| `net/html.S` | HTML to text, for the direct route |
| `app/localops.S` | the built-in operations, matched and run without a network |
| `kernel/arch/aarch64/trap.S` | what happens when something goes wrong |
| `crypto/` | SHA-256, HMAC, ChaCha20, Poly1305, AEAD, HKDF, X25519 |
| `backend-java/src/` | the backend: routing, accounts, aicoin, EC2, the pad |
| `backend-java/src/Scripts.java` | operations: patterns with typed holes, and what they may know |
| `backend-java/src/Js.java` | the JavaScript subset, compiled ahead of time to aarch64 |
| `backend-java/src/Consortium.java` | several models, asked separately, before anything ships |
| `ops/` | approved operations: the machine code, its source, and the votes |
| `tests/` | `make test` — the backend's judgement, and the aarch64 it emits, run |
| `backend/` | the earlier assembly backend, kept until the Java one is proven |

## Getting to bare metal

Apple Silicon is the target and the route in is m1n1, Asahi's bootloader: iBoot
starts it, it starts something else. It does not hand over a device tree the
way QEMU and the Virtualization framework do — it passes a structure of its
own, and the most important thing in it is **a framebuffer that is already
running**. m1n1 has talked to the display controller so its payload does not
have to, and that is the whole of first light on that machine.

There are two ways that arrives. m1n1 passes its own `boot_args` to a raw
payload, and `kernel/arch/aarch64/bootargs.S` reads those. But m1n1 also boots
**Linux-style images**, and armedit is one now — it has the arm64 image header
— so the loader hands it a device tree with a `simple-framebuffer` node
instead. `kernel/screen.S` reads either, and the second is both the more likely
path on a real Mac and the one that works on every other arm64 board whose
loader produces the same node.

`platform_present` draws into whichever it found, row by row with the real
stride, converting to thirty-bit pixels when that is what the panel is —
`x2r10g10b10` is what an Apple display usually reports, and writing eight-bit
channels into it gives a picture that is dim and wrong rather than absent,
which is the kind of wrong that gets shipped.

Fifteen assertions cover both handovers, the device-tree one against a real
generated blob rather than a mocked parser: the flattened device tree is a wire
format, and a reader tested only against what its author imagined is a
description of the author's imagination. All of it checks out without owning
the machine, which matters, since the alternative is repartitioning one to find
out whether an offset was right.

What is *not* done is everything after first light: the interrupt controller,
the timers, the Apple serial port, and input. Input is the hard one — an Apple
keyboard is USB or SPI behind an IOMMU, which is a great deal more than
virtio-input. Expect display and serial before anything types.

EFI does not help here. Apple's iBoot is not EFI firmware, so the EFI path is
for the Virtualization framework and for other arm64 boards, not for this Mac.

## Status

Verified by running it, against published test vectors where they exist:

- [x] hand-built 5x7 font, 95 glyphs, one shared rasterizer
- [x] hosted terminal mode and hosted window mode
- [x] bare-metal kernel: boots, framebuffer, scrolling console, back buffer
- [x] editor: screens, caret, mouse, paging, edit-aware rewrite, colours
- [x] SHA-256 (FIPS), HMAC (RFC 4231), AWS SigV4 (byte-identical to an
      independent reference)
- [x] ChaCha20, Poly1305 and the AEAD (RFC 8439), HKDF (RFC 5869),
      X25519 (RFC 7748) - the whole symmetric and key-agreement half of TLS 1.3
- [x] **keyboard and networking on bare metal**: virtio-input and virtio-net
      drivers, then ARP, IPv4 and TCP written from scratch. `Cmd`+`P` in the
      kernel reaches the backend over our own stack. Found by packet capture
      rather than by reading: a SYN that did not consume a sequence number, an
      address byte order that disagreed with itself, and an unaligned 32-bit
      load that hangs silently because the MMU is off and every page is Device
      memory
- [x] the Java backend, running: routing, accounts that survive a restart,
      aicoin, the pad ledger, the workspace tiers, the model router
- [x] real EC2 provisioning: an instance is brought up, runs the command,
      reports, and is terminated as soon as its output has been read
- [x] operations: cached, scripted, compiled to aarch64, and run on the device
      without a network. `make test` proves the answer survives every stage and
      then executes the machine code the compiler emitted
- [x] the consortium: several models, two vendors, asked separately before
      anything is committed to `ops/`
- [x] **offline**: `ops/` is baked into the image and tried before the network,
      so `colours blue` works on a machine with no netdev, no backend and no key
- [x] **exception vectors**: a fault reports its class, ESR, ELR, faulting
      address and every register, over serial and framebuffer alike, instead of
      stopping silently. `make boot-fault` proves it. It found three bugs in the
      week it was written
- [x] **opening a site**: `open example.com` and `Cmd`+`Enter`, rendered on the
      bare-metal framebuffer over our own TCP stack
- [x] typing during a request is no longer typing that is lost

Next, in rough order:

- [ ] **TLS 1.3 client in assembly** - the primitives are done and verified; the
      handshake, record layer and certificate pinning are not. Until then the
      backend reaches AWS and aicoin over TLS from Java, and the editor talks
      to its backend in the clear
- [ ] local persistence on the device itself, so a screen survives losing the
      backend
- [ ] mounting the account's folders into the provisioned machine's home
      directory, so the agent works on the same files you are typing into
- [ ] the editor emitting edits and gestures: the journal endpoint and storage
      exist, nothing sends to them yet
- [ ] provisioning on anything but AWS - the other clouds take credentials and
      are compared on price, but only EC2 is actually brought up
- [ ] iOS gestures the macOS front end does not have yet
- [ ] baking proven operations into the shipped image, so a release carries
      what the previous one learned

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
4. **Nothing ships on one opinion.** Machine code reaches `ops/` only after
   enough distinct people were independently given the same answer, only after
   it compiled, and only after several models — across vendors, asked
   separately — agreed it should exist. Their reasoning is committed with it.
