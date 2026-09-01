#include "asm.inc"
#include "editor.inc"
/*
 * backend_client.S - the editor's entire view of the outside world.
 *
 * The editor knows one server and one credential: its own backend, and the
 * armedit key issued by armedit.oeaio.com.  It does not know that Claude
 * exists, does not know what an aicoin wallet is, and holds no AWS
 * credentials - the backend owns all of that.  What travels on this wire is
 * the screen's text out, and text back.
 *
 *   POST /api/agent
 *   X-Armedit-Key: <the one key>
 *   {"mode":"agent"|"aify","screen":<n>,"scroll":<r>,"rows":<n>,"cursor":<i>,
 *    "baseline":"<the text at the last sync>",
 *    "context":"<the whole current screen>"}
 * ->
 *   {"text":"<what came back>"}
 *
 * Cmd+Enter appends: the answer goes on the end and everything stays.
 * Cmd+P replaces: the instruction is consumed by its own answer, so writing
 * "c hello world" and pressing it leaves the program where the words were,
 * not the words followed by the program.  What gets replaced is the selection
 * if there is one, otherwise the line the caret is on - never the screen.
 *
 * An empty or missing reply changes nothing either way.
 *
 * scroll/rows tell the backend which part of the text the user is actually
 * looking at, and baseline is what the text was the last time the backend saw
 * it - so the far side can reason about the edit, not just the file.
 *
 * Configuration comes from the environment: ARMEDIT_BACKEND (address:port,
 * default 127.0.0.1:8080) and ARMEDIT_KEY.  Neither is ever written to disk
 * by us, and neither appears anywhere in this repository.
 */
#define REQ_IP          0
#define REQ_PORT        4
#define REQ_METHOD      8
#define REQ_PATH        16
#define REQ_HOST        24
#define REQ_HDRS        32
#define REQ_BODY        40
#define REQ_BODYLEN     48
#define REQ_OUT         56
#define REQ_OUTCAP      64

#define CTX_SZ          8192
#define BODY_SZ         16384
#define RESP_SZ         32768
#define HDRS_SZ         512
#define REPLY_SZ        8192
#define KEY_SZ          128

/* What the fetch half leaves behind for the apply half. */
#define ST_OK           0
#define ST_NOKEY        1
#define ST_BADADDR      2
#define ST_UNREACHABLE  3
#define ST_BADREPLY     4
#define ST_EMPTY        5

        CODE
        .p2align 2

/*
 * resolve_backend - work out where to send things, and with what.
 *   out x0 = address string ("a.b.c.d:port"), x1 = key, or x1 = 0 if unset
 *
 * A device is configured with exactly one value: ARMEDIT_KEY.  The key the
 * backend issues carries the address to reach it at, as "<secret>@<addr>", so
 * there is no second setting to get wrong and no endpoint baked into the
 * binary.  A bare key falls back to the local default, and ARMEDIT_BACKEND
 * overrides everything - both of those are for development, not for users.
 */
resolve_backend:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]

        LEA     x0, s_env_key
        bl      SYM(env_get)
        mov     x19, x0
        cbz     x19, .Lrb_nokey

        LEA     x20, keybuf             /* copy the key, stopping at '@' */
        mov     w9, #0
1:      ldrb    w10, [x19, w9, uxtw]
        cbz     w10, 2f
        cmp     w10, #'@'
        b.eq    2f
        strb    w10, [x20, w9, uxtw]
        add     w9, w9, #1
        cmp     w9, #(KEY_SZ - 1)
        b.lo    1b
2:      strb    wzr, [x20, w9, uxtw]

        ldrb    w10, [x19, w9, uxtw]    /* was there an address after it? */
        cmp     w10, #'@'
        b.ne    3f
        add     w9, w9, #1
        add     x21, x19, w9, uxtw
        b       .Lrb_out
3:      LEA     x0, s_env_backend       /* no: the override, then the default */
        bl      SYM(env_get)
        mov     x21, x0
        cbnz    x21, .Lrb_out
        LEA     x21, s_default_backend

.Lrb_out:
        mov     x0, x21
        LEA     x1, keybuf
        b       .Lrb_ret
.Lrb_nokey:
        LEA     x0, s_default_backend
        mov     x1, #0
.Lrb_ret:
        ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * backend_submit - hand the current screen to the backend, paste the answer.
 * Called when the editor reports Cmd+Enter.  Any failure is reported into the
 * buffer itself rather than silently swallowed.
 */
/*
 * The request and its result are two jobs, and they belong on different
 * threads.  backend_fetch talks to the network and writes only into its own
 * buffers; backend_apply is the half that touches the screen's text, and it
 * must run where the drawing runs.  Doing both on a background thread would
 * mean rewriting the buffer underneath a redraw that is reading it.
 */
        .globl  SYM(backend_submit)
SYM(backend_submit):
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     w19, w0
        bl      SYM(backend_fetch)
        mov     w0, w19
        bl      SYM(backend_apply)
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/*
 * browse_via_backend - x0 = what they wrote, x1 = out, w2 = capacity.
 *   out w0 = bytes of text, or -1.
 *
 * The other half of net/browse.S. It lives here because reaching the backend
 * means the key, the address and the request machinery, all of which are this
 * file's business and none of which a page fetcher should have to know about.
 *
 * The backend gets the page as text, having already run whatever the page
 * needed run. That is the trade for the round trip: it is the only route that
 * works for https, and for a machine that cannot resolve a name at all.
 */
        .globl  SYM(browse_via_backend)
SYM(browse_via_backend):
        stp     x29, x30, [sp, #-80]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        mov     x23, x0                 /* what they wrote */
        mov     x24, x1                 /* out             */
        mov     w22, w2                 /* capacity        */

        bl      resolve_backend
        mov     x19, x0
        mov     x20, x1
        cbz     x20, .Lbv_fail

        LEA     x0, hdrbuf
        LEA     x1, s_hdr_key
        bl      SYM(str_copy)
        mov     x1, x20
        bl      SYM(str_copy)
        LEA     x1, s_hdr_tail
        bl      SYM(str_copy)

        LEA     x0, bodybuf             /* {"url":"..."} */
        LEA     x1, s_json_url
        bl      SYM(str_copy)
        mov     x1, x23
        mov     w2, #1024
        bl      SYM(json_escape)
        LEA     x1, s_json_tail
        bl      SYM(str_copy)

        LEA     x21, req
        mov     x0, x19
        add     x1, x21, #REQ_IP
        add     x2, x21, #REQ_PORT
        bl      SYM(net_parse_addr)
        tbnz    w0, #31, .Lbv_fail

        LEA     x0, s_post
        str     x0, [x21, #REQ_METHOD]
        LEA     x0, s_path_fetch
        str     x0, [x21, #REQ_PATH]
        str     x19, [x21, #REQ_HOST]
        LEA     x0, hdrbuf
        str     x0, [x21, #REQ_HDRS]
        LEA     x0, bodybuf
        str     x0, [x21, #REQ_BODY]
        LEA     x0, bodybuf
        bl      SYM(str_len)
        str     w0, [x21, #REQ_BODYLEN]
        LEA     x0, respbuf
        str     x0, [x21, #REQ_OUT]
        mov     w0, #RESP_SZ
        str     w0, [x21, #REQ_OUTCAP]

        mov     x0, x21
        bl      SYM(http_request)
        cmp     w0, #0
        b.le    .Lbv_fail

        LEA     x0, respbuf
        bl      SYM(http_body)
        LEA     x1, s_key_text
        bl      SYM(json_find)
        cbz     x0, .Lbv_fail
        mov     x1, x0
        mov     x0, x24
        mov     w2, w22
        bl      SYM(json_unescape)
        b       .Lbv_out

.Lbv_fail:
        mov     w0, #-1
.Lbv_out:
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #80
        ret

/*
 * backend_reboot_wanted - out w0 = 1 once, if a restart was asked for.
 *
 * Asked by the main loop rather than acted on here, and the ordering is the
 * point: a machine that restarts inside the request has eaten its own reply,
 * and the person is left looking at a fresh boot with no idea whether anything
 * happened. The loop draws first and asks afterwards.
 *
 * It answers once. A flag that stayed set would restart the machine again on
 * the next pass, forever, which is a reboot loop caused by remembering.
 */
        .globl  SYM(backend_reboot_wanted)
SYM(backend_reboot_wanted):
        LEA     x9, pending_reboot
        ldr     w0, [x9]
        str     wzr, [x9]
        ret

        .globl  SYM(backend_fetch)
SYM(backend_fetch):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        str     x23, [sp, #48]
        mov     w23, w0                 /* ED_SUBMIT, ED_AIFY or ED_SWIPE */
        LEA     x9, fetch_status        /* what apply will have to say */
        mov     w10, #ST_NOKEY
        str     w10, [x9]
        bl      SYM(editor_cursor_get)  /* where the user was when they asked */
        LEA     x9, saved_cursor
        str     w0, [x9]

        cmp     w23, #ED_AIFY           /* what will the answer replace? */
        b.ne    20f
        bl      SYM(editor_selection)
        cmp     w0, w1
        b.lo    19f                     /* a selection, if they made one */
        LEA     x0, region_a            /* otherwise the line they are on */
        LEA     x1, region_b
        bl      SYM(editor_line_bounds)
        b       20f
19:     LEA     x9, region_a
        str     w0, [x9]
        LEA     x9, region_b
        str     w1, [x9]
20:

/* ---- a site is a thing the editor opens ---------------------------------
 *
 * "open google", then Cmd+Enter. The same key that hands a screen to a model
 * hands it to a website, because from here they are the same request with
 * different sources: something is asked for, and text comes back.
 *
 * Which route the page arrives by is not this file's decision - net/browse.S
 * tries directly, falls back to the backend, and remembers which worked. What
 * matters here is that neither of those is a different feature. There is no
 * "browser mode": there is a line that happens to name a site.
 */
        cmp     w23, #ED_SUBMIT
        b.ne    .Lno_browse
        LEA     x0, region_a
        LEA     x1, region_b
        bl      SYM(editor_line_bounds)
        LEA     x9, region_a
        ldr     w0, [x9]
        LEA     x9, region_b
        ldr     w1, [x9]
        LEA     x2, instrbuf
        mov     w3, #CTX_SZ
        bl      SYM(editor_range_text)

        LEA     x0, instrbuf
        LEA     x1, s_open
        bl      SYM(str_starts)
        cbz     w0, .Lno_browse

        LEA     x0, instrbuf
        add     x0, x0, #5              /* past "open " */
        LEA     x1, replybuf
        mov     w2, #REPLY_SZ
        bl      SYM(browse_open)
        cmn     w0, #1
        b.eq    .Lno_browse             /* neither route worked: let the normal
                                           path have it, since "open the door"
                                           is a sentence too */
        LEA     x9, replybuf
        strb    wzr, [x9, w0, uxtw]
        LEA     x9, reply_colour
        mov     w10, #-1
        str     w10, [x9]
        LEA     x9, reply_whole
        str     wzr, [x9]
        LEA     x9, fetch_status
        str     wzr, [x9]               /* ST_OK */
        b       .Lsub_out
.Lno_browse:

/* ---- what this build already knows, before anything is asked -------------
 *
 * The operations baked into this binary get the request first. They were put
 * there because enough people asked for them, they compiled, and several
 * models agreed they should exist - so consulting a server about them would be
 * asking permission to know something already known.
 *
 * This runs before the key is even looked at, which is the whole point: an
 * editor with no key, no link and no backend still answers everything it has
 * been taught. Most requests are not in the table and fall straight through,
 * costing one pass over a handful of patterns.
 */
        cmp     w23, #ED_AIFY
        b.ne    .Lno_local
        LEA     x9, region_a
        ldr     w0, [x9]
        LEA     x9, region_b
        ldr     w1, [x9]
        LEA     x2, instrbuf
        mov     w3, #CTX_SZ
        bl      SYM(editor_range_text)
        LEA     x0, ctxbuf
        mov     w1, #CTX_SZ
        bl      SYM(editor_context)
        LEA     x0, subjtext
        mov     w1, #64                 /* what subjtext actually holds */
        bl      SYM(editor_subject)

        LEA     x0, instrbuf
        LEA     x1, ctxbuf
        LEA     x2, subjtext
        LEA     x3, s_nothing
        LEA     x4, replybuf
        mov     w5, #REPLY_SZ
        bl      SYM(localop_run)
        cmn     w0, #1
        b.eq    .Lno_local

        LEA     x9, replybuf            /* recomputed: the call ate x9-x15 */
        strb    wzr, [x9, w0, uxtw]

        LEA     x0, replybuf            /* the same directives, read here */
        bl      SYM(localop_colour)
        LEA     x9, reply_colour
        str     w0, [x9]
        LEA     x0, replybuf
        bl      SYM(localop_reboot)
        LEA     x9, reply_reboot
        str     w0, [x9]
        LEA     x0, replybuf
        bl      SYM(localop_strip)

        LEA     x9, reply_whole         /* a local answer replaces what it was
                                           asked about, never the whole screen:
                                           nothing offline can have been told
                                           that the screen was the subject */
        str     wzr, [x9]
        LEA     x9, fetch_status
        str     wzr, [x9]               /* ST_OK */
        b       .Lsub_out
.Lno_local:

/* ---- one property: the key, which carries where to reach the backend ---- */
        bl      resolve_backend         /* x0 = address, x1 = key, or x1 = 0 */
        mov     x19, x0
        mov     x20, x1
        cbnz    x20, 2f
        b       .Lsub_out               /* no key: these keys do nothing at all,
                                           rather than writing into the buffer */
2:
        LEA     x21, req
        mov     x0, x19
        add     x1, x21, #REQ_IP
        add     x2, x21, #REQ_PORT
        bl      SYM(net_parse_addr)
        tbz     w0, #31, 3f
        LEA     x9, fetch_status
        mov     w10, #ST_BADADDR
        str     w10, [x9]
        b       .Lsub_out
3:

/* ---- {"screen":N,"context":"..."} --------------------------------------- */
        LEA     x0, rawbuf
        mov     w1, #CTX_SZ
        bl      SYM(editor_context)
        LEA     x0, ctxbuf              /* private lines lose their content
                                           here, on the device, before any of
                                           this is a request */
        LEA     x1, rawbuf
        mov     w2, #CTX_SZ
        bl      SYM(str_redact)

        LEA     x22, bodybuf
        mov     x0, x22
        LEA     x1, s_json_mode
        bl      SYM(str_copy)
        mov     x22, x0
        cmp     w23, #ED_AIFY
        b.ne    10f
        LEA     x1, s_mode_aify
        b       11f
10:     cmp     w23, #ED_SWIPE
        b.ne    12f
        LEA     x1, s_mode_swipe
        b       11f
12:     LEA     x1, s_mode_agent
11:     mov     x0, x22
        bl      SYM(str_copy)
        mov     x22, x0
        mov     x0, x22
        LEA     x1, s_json_head
        bl      SYM(str_copy)
        mov     x22, x0
        bl      SYM(editor_screen_info) /* w0 = current screen */
        mov     w1, w0
        add     w1, w1, #1              /* 1-based, as shown in the bar */
        mov     x0, x22
        bl      SYM(u32_dec)
        mov     x22, x0
        mov     x0, x22                 /* which rows the user can see */
        LEA     x1, s_json_scroll
        bl      SYM(str_copy)
        mov     x22, x0
        bl      SYM(editor_view)        /* w0 = scroll, w1 = rows */
        mov     w9, w1
        mov     w1, w0
        mov     x0, x22
        bl      SYM(u32_dec)
        mov     x22, x0
        mov     x0, x22
        LEA     x1, s_json_rows
        bl      SYM(str_copy)
        mov     x22, x0
        bl      SYM(editor_view)
        mov     x0, x22
        bl      SYM(u32_dec)
        mov     x22, x0
        mov     x0, x22                 /* where the caret is, in bytes */
        LEA     x1, s_json_cursor
        bl      SYM(str_copy)
        mov     x22, x0
        LEA     x9, saved_cursor
        ldr     w1, [x9]
        mov     x0, x22
        bl      SYM(u32_dec)
        mov     x22, x0
        mov     x0, x22                 /* what this screen is bound to, if
                                           anything: a widget's screen takes
                                           behaviour, a word's takes work */
        LEA     x1, s_json_subj
        bl      SYM(str_copy)
        mov     x22, x0
        LEA     x0, subjtext
        mov     w1, #64
        bl      SYM(editor_subject)
        mov     x0, x22
        LEA     x1, subjtext
        mov     w2, #128
        bl      SYM(json_escape)
        mov     x22, x0
        mov     x0, x22
        LEA     x1, s_json_quote
        bl      SYM(str_copy)
        mov     x22, x0

        cmp     w23, #ED_AIFY           /* Cmd+P carries what it will replace */
        b.ne    14f
        mov     x0, x22
        LEA     x1, s_json_instr
        bl      SYM(str_copy)
        mov     x22, x0
        LEA     x9, region_a
        ldr     w0, [x9]
        LEA     x9, region_b
        ldr     w1, [x9]
        LEA     x2, selbuf
        mov     w3, #CTX_SZ
        bl      SYM(editor_range_text)
        mov     x0, x22
        LEA     x1, selbuf
        mov     w2, #(BODY_SZ / 4)
        bl      SYM(json_escape)
        mov     x22, x0
        mov     x0, x22
        LEA     x1, s_json_quote
        bl      SYM(str_copy)
        mov     x22, x0
14:
        cmp     w23, #ED_SWIPE          /* a swipe carries what it covered */
        b.ne    13f
        mov     x0, x22
        LEA     x1, s_json_sel
        bl      SYM(str_copy)
        mov     x22, x0
        LEA     x0, selbuf
        mov     w1, #CTX_SZ
        bl      SYM(editor_selection_text)
        mov     x0, x22
        LEA     x1, selbuf
        mov     w2, #(BODY_SZ / 4)
        bl      SYM(json_escape)
        mov     x22, x0
        mov     x0, x22
        LEA     x1, s_json_quote
        bl      SYM(str_copy)
        mov     x22, x0
13:
        mov     x0, x22                 /* what it looked like at last sync */
        LEA     x1, s_json_base
        bl      SYM(str_copy)
        mov     x22, x0
        LEA     x0, basebuf
        mov     w1, #CTX_SZ
        bl      SYM(editor_baseline)
        mov     x0, x22
        LEA     x1, basebuf
        mov     w2, #(BODY_SZ / 2 - 256)
        bl      SYM(json_escape)
        mov     x22, x0
        mov     x0, x22
        LEA     x1, s_json_ctx
        bl      SYM(str_copy)
        mov     x22, x0
        mov     x0, x22
        LEA     x1, ctxbuf
        mov     w2, #(BODY_SZ / 2 - 256)
        bl      SYM(json_escape)
        mov     x22, x0
        mov     x0, x22
        LEA     x1, s_json_tail
        bl      SYM(str_copy)
        mov     x22, x0

/* ---- X-Armedit-Key: <key> ---------------------------------------------- */
        LEA     x0, hdrbuf
        LEA     x1, s_hdr_key
        bl      SYM(str_copy)
        mov     x1, x20
        bl      SYM(str_copy)
        LEA     x1, s_hdr_tail
        bl      SYM(str_copy)

/* ---- send ---------------------------------------------------------------- */
        LEA     x0, s_post
        str     x0, [x21, #REQ_METHOD]
        LEA     x0, s_path_agent
        str     x0, [x21, #REQ_PATH]
        str     x19, [x21, #REQ_HOST]
        LEA     x0, hdrbuf
        str     x0, [x21, #REQ_HDRS]
        LEA     x0, bodybuf
        str     x0, [x21, #REQ_BODY]
        LEA     x0, bodybuf
        bl      SYM(str_len)
        str     w0, [x21, #REQ_BODYLEN]
        LEA     x0, respbuf
        str     x0, [x21, #REQ_OUT]
        mov     w0, #RESP_SZ
        str     w0, [x21, #REQ_OUTCAP]

        mov     x0, x21
        bl      SYM(http_request)
        cmp     w0, #0
        b.gt    4f
        LEA     x9, fetch_status
        mov     w10, #ST_UNREACHABLE
        str     w10, [x9]
        b       .Lsub_out
4:

/* ---- {"text":"..."} into a buffer of our own, and no further ------------ */
        LEA     x0, respbuf
        bl      SYM(http_body)
        LEA     x1, s_key_text
        bl      SYM(json_find)
        cbnz    x0, 4f
        LEA     x9, fetch_status
        mov     w10, #ST_BADREPLY
        str     w10, [x9]
        b       .Lsub_out
4:      mov     x1, x0
        LEA     x0, replybuf
        mov     w2, #REPLY_SZ
        bl      SYM(json_unescape)

/*
 * A colour, if it named one. The palette is the client's, so what crosses the
 * wire is a slot in it rather than a pixel value - the far side does not get to
 * pick colours this editor never agreed to.
 */
        LEA     x9, reply_colour
        mov     w10, #-1
        str     w10, [x9]
        LEA     x0, respbuf
        LEA     x1, s_key_colour
        bl      SYM(str_find)
        cbz     x0, 7f                  /* str_find lands past the match, so
                                           this is already the digit */
        ldrb    w10, [x0]
        sub     w10, w10, #'0'
        cmp     w10, #9
        b.hi    7f
        LEA     x9, reply_colour
        str     w10, [x9]
7:
/*
 * And whether it asked the machine to restart.
 *
 * A field, not the text. Every directive is stripped before the server hands
 * the text over - which is right, and means a client reading the text for one
 * finds nothing. The offline path reads the text instead, because there the
 * operation's output has not been through a server; both end up setting the
 * same flag, which is the only thing that matters downstream.
 */
        LEA     x9, reply_reboot
        str     wzr, [x9]
        LEA     x0, respbuf
        LEA     x1, s_key_restart
        bl      SYM(str_find)
        cbz     x0, 6f
        LEA     x9, reply_reboot        /* recomputed: str_find ate x9-x15 */
        mov     w10, #1
        str     w10, [x9]
6:

/*
 * Did the far side say its answer supersedes the whole screen rather than the
 * line that asked for it?  "add a loop" is about the program above, not a
 * request for a new one, and only the model can tell those apart - so it says,
 * and this looks for the saying.
 */
        LEA     x0, respbuf
        LEA     x1, s_whole_true
        bl      SYM(str_find)
        LEA     x9, reply_whole
        cmp     x0, #0
        cset    w10, ne
        str     w10, [x9]
/*
 * Empty means nothing came back at all - not "no text came back". A reply that
 * changes the colour, or restarts the machine, and nothing else has no text by
 * design: the line the
 * person typed is meant to vanish and be replaced by the editor looking
 * different. Treating that as an empty reply printed "NOTHING CHANGED" over a
 * request that had, in fact, been understood and answered.
 */
        LEA     x9, replybuf
        ldrb    w10, [x9]
        cbnz    w10, 5f
        LEA     x9, reply_colour        /* a colour on its own is an answer */
        ldr     w10, [x9]
        cmn     w10, #1
        b.ne    5f
        LEA     x9, reply_reboot        /* and so is "restart", which has even
                                           less to say for itself - the machine
                                           is about to be gone */
        ldr     w10, [x9]
        cbnz    w10, 5f
        LEA     x9, fetch_status
        mov     w11, #ST_EMPTY
        str     w11, [x9]
        b       .Lsub_out
5:      LEA     x9, fetch_status        /* recomputed: str_find ate x9-x15 */
        str     wzr, [x9]               /* ST_OK */

.Lsub_out:
        ldr     x23, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * backend_apply - w0 = the mode that was asked.
 *
 * The half that touches the text, and the only half that may: it runs where
 * the drawing runs.  Cmd+P replaces what asked for it, Cmd+Enter and a swipe
 * append.  Every failure says what happened in the buffer rather than
 * vanishing, except a missing key - that one is meant to do nothing at all.
 */
        .globl  SYM(backend_apply)
SYM(backend_apply):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     w19, w0
        LEA     x9, fetch_status
        ldr     w20, [x9]

        cmp     w20, #ST_OK
        b.eq    .Lap_ok
        cmp     w20, #ST_NOKEY
        b.eq    .Lap_out                /* no key: these keys do nothing */
        cmp     w20, #ST_BADADDR
        b.ne    1f
        LEA     x0, m_badaddr
        b       .Lap_say
1:      cmp     w20, #ST_UNREACHABLE
        b.ne    2f
        LEA     x0, m_unreachable
        b       .Lap_say
2:      cmp     w20, #ST_BADREPLY
        b.ne    3f
        LEA     x0, m_badreply
        b       .Lap_say
3:      LEA     x0, m_empty
.Lap_say:
        bl      SYM(editor_insert_str)
        b       .Lap_reboot

.Lap_ok:
        LEA     x9, reply_reboot        /* asked for last, so whatever else the
                                           answer did is on screen first - a
                                           machine that restarts before showing
                                           its reply has eaten it */
        ldr     w0, [x9]
        cbz     w0, 6f
        LEA     x9, pending_reboot
        mov     w10, #1
        str     w10, [x9]
6:
        LEA     x9, reply_colour        /* a named colour is a real answer, */
        ldr     w0, [x9]                /* even when no text came with it */
        cmn     w0, #1
        b.eq    8f
        bl      SYM(editor_colour)
8:
        cmp     w19, #ED_AIFY
        b.ne    4f
        LEA     x9, reply_whole         /* the whole screen, when the answer is
                                           a rewrite of what was already there */
        ldr     w9, [x9]
        cbz     w9, 5f
        mov     w0, #0
        bl      SYM(editor_length)
        mov     w1, w0
        mov     w0, #0
        b       6f
5:      LEA     x9, region_a            /* otherwise the instruction that asked */
        ldr     w0, [x9]
        LEA     x9, region_b
        ldr     w1, [x9]
6:
        LEA     x2, replybuf
        bl      SYM(editor_replace)
        bl      SYM(editor_selection_clear)
        bl      SYM(editor_mark_synced)
        b       .Lap_reboot
4:      bl      SYM(editor_length)      /* Cmd+Enter: on the end, keeping all
                                           of what is already there */
        bl      SYM(editor_cursor_set)
        LEA     x0, m_reply_open
        bl      SYM(editor_insert_str)
        LEA     x0, replybuf
        bl      SYM(editor_insert_str)
        LEA     x0, s_nl
        bl      SYM(editor_insert_str)
        bl      SYM(editor_mark_synced)

.Lap_reboot:
.Lap_out:
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * backend_session - ask the backend for this account's instance at startup.
 * The editor is meant to open with somewhere to run things already attached;
 * the backend decides whether that means starting one or reusing the one this
 * account already has.
 */

/*
 * behaviour_sync - fetch what everyone decided, and apply it here.
 *
 * The server keeps one table of rules of the form "target trigger verb weight"
 * - "video drag move 3" means three people, between them, have said a video
 * should follow the pointer. The weight is why this is a table rather than a
 * setting: one person writing "draggable" on a video screen is a suggestion,
 * and the same sentence from enough people is how video widgets work.
 *
 * The client's half is deliberately dumb. It cannot interpret a rule, only
 * recognise one: the verbs are a closed set, and a line it does not know the
 * shape of is skipped rather than guessed at. That is what stops a server -
 * or a model talking through one - from describing behaviour this program has
 * no way to perform.
 *
 * Failing is silent and total: no key, no server, no answer, and the editor
 * carries on with whatever it already knew. A device that cannot reach the
 * server is not a device that should forget how its widgets work.
 */
        .globl  SYM(behaviour_sync)
SYM(behaviour_sync):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]

        bl      resolve_backend
        mov     x19, x0
        mov     x20, x1
        cbz     x20, .Lbs_out

        LEA     x0, hdrbuf
        LEA     x1, s_hdr_key
        bl      SYM(str_copy)
        mov     x1, x20
        bl      SYM(str_copy)
        LEA     x1, s_hdr_tail
        bl      SYM(str_copy)

        LEA     x21, req
        mov     x0, x19
        add     x1, x21, #REQ_IP
        add     x2, x21, #REQ_PORT
        bl      SYM(net_parse_addr)
        tbnz    w0, #31, .Lbs_out

        LEA     x0, s_get
        str     x0, [x21, #REQ_METHOD]
        LEA     x0, s_path_behav
        str     x0, [x21, #REQ_PATH]
        str     x19, [x21, #REQ_HOST]
        LEA     x0, hdrbuf
        str     x0, [x21, #REQ_HDRS]
        str     xzr, [x21, #REQ_BODY]
        str     wzr, [x21, #REQ_BODYLEN]
        LEA     x0, respbuf
        str     x0, [x21, #REQ_OUT]
        mov     w0, #RESP_SZ
        str     w0, [x21, #REQ_OUTCAP]

        mov     x0, x21
        bl      SYM(http_request)
        cmp     w0, #0
        b.le    .Lbs_out

        LEA     x0, respbuf
        bl      SYM(http_body)
        mov     x19, x0

/* Each line is "<target> <trigger> <verb> <weight>". */
.Lbs_line:
        ldrb    w9, [x19]
        cbz     w9, .Lbs_out

        LEA     x22, targetbuf          /* the target word */
        mov     w9, #0
1:      cmp     w9, #31
        b.hs    2f
        ldrb    w10, [x19, w9, uxtw]
        cbz     w10, 2f
        cmp     w10, #' '
        b.ls    2f
        strb    w10, [x22, w9, uxtw]
        add     w9, w9, #1
        b       1b
2:      strb    wzr, [x22, w9, uxtw]
        add     x21, x19, w9, uxtw      /* what follows it on the line */

        mov     x0, x21                 /* the one rule shape we know */
        LEA     x1, s_rule_dragmove
        bl      SYM(str_starts)
        cbz     w0, .Lbs_next
        LEA     x0, targetbuf
        bl      SYM(applet_mark_draggable)

.Lbs_next:
        ldrb    w9, [x19]
        cbz     w9, .Lbs_out
        add     x19, x19, #1
        cmp     w9, #'\n'
        b.ne    .Lbs_next
        b       .Lbs_line

.Lbs_out:
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

        .globl  SYM(backend_session)
SYM(backend_session):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]

        bl      resolve_backend         /* the key says where to go */
        mov     x19, x0
        mov     x20, x1
        cbz     x20, .Lses_out          /* no key: the editor still opens */

        LEA     x21, req
        mov     x0, x19
        add     x1, x21, #REQ_IP
        add     x2, x21, #REQ_PORT
        bl      SYM(net_parse_addr)
        tbnz    w0, #31, .Lses_out

        LEA     x0, hdrbuf
        LEA     x1, s_hdr_key
        bl      SYM(str_copy)
        mov     x1, x20
        bl      SYM(str_copy)
        LEA     x1, s_hdr_tail
        bl      SYM(str_copy)

        LEA     x0, s_post
        str     x0, [x21, #REQ_METHOD]
        LEA     x0, s_path_session
        str     x0, [x21, #REQ_PATH]
        str     x19, [x21, #REQ_HOST]
        LEA     x0, hdrbuf
        str     x0, [x21, #REQ_HDRS]
        LEA     x0, s_empty_body
        str     x0, [x21, #REQ_BODY]
        mov     w0, #0
        str     w0, [x21, #REQ_BODYLEN]
        LEA     x0, respbuf
        str     x0, [x21, #REQ_OUT]
        mov     w0, #RESP_SZ
        str     w0, [x21, #REQ_OUTCAP]
        mov     x0, x21
        bl      SYM(http_request)
        cmp     w0, #0
        b.le    .Lses_none

        LEA     x0, respbuf
        bl      SYM(http_body)
        LEA     x1, s_key_instance
        bl      SYM(json_find)
        cbz     x0, .Lses_none
        mov     x1, x0
        LEA     x0, replybuf
        mov     w2, #REPLY_SZ
        bl      SYM(json_unescape)
        LEA     x9, replybuf
        ldrb    w10, [x9]
        cbz     w10, .Lses_none
        LEA     x0, m_instance
        bl      SYM(editor_insert_str)
        LEA     x0, replybuf
        bl      SYM(editor_insert_str)
        LEA     x0, s_nl
        bl      SYM(editor_insert_str)
        b       .Lses_out
.Lses_none:
        LEA     x0, m_noinstance
        bl      SYM(editor_insert_str)
.Lses_out:
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

        CSTR
s_path_session:     .asciz "/api/session"
s_key_instance:     .asciz "\"instance\""
s_empty_body:       .asciz ""
m_instance:         .asciz "INSTANCE: "
m_noinstance:       .asciz "NO INSTANCE. THE EDITOR WORKS; CMD+ENTER NEEDS THE BACKEND.\n"
s_env_backend:      .asciz "ARMEDIT_BACKEND"
s_env_key:          .asciz "ARMEDIT_KEY"
s_default_backend:  .asciz "127.0.0.1:8080"
s_post:             .asciz "POST"
s_path_agent:       .asciz "/api/agent"
s_get:              .asciz "GET"
s_path_behav:       .asciz "/api/behaviours"
s_rule_dragmove:    .asciz " drag move"
s_whole_true:       .asciz "\"whole\":true"
s_key_colour:       .asciz "\"colour\":"
s_key_restart:      .asciz "\"restart\":true"
s_nothing:          .asciz ""
s_json_url:         .asciz "{\"url\":\""
s_path_fetch:       .asciz "/api/fetch"
s_open:             .asciz "open "
s_hdr_key:          .asciz "Content-Type: application/json\r\nX-Armedit-Key: "
s_hdr_tail:         .asciz "\r\n"
s_json_mode:        .asciz "{\"mode\":\""
s_mode_agent:       .asciz "agent"
s_mode_aify:        .asciz "aify"
s_mode_swipe:       .asciz "swipe"
s_json_sel:         .asciz ",\"selection\":\""
s_json_instr:       .asciz ",\"instruction\":\""
s_json_subj:        .asciz ",\"subject\":\""
s_json_quote:       .asciz "\""
s_json_head:        .asciz "\",\"screen\":"
s_json_scroll:      .asciz ",\"scroll\":"
s_json_rows:        .asciz ",\"rows\":"
s_json_cursor:      .asciz ",\"cursor\":"
s_json_base:        .asciz ",\"baseline\":\""
s_json_ctx:         .asciz "\",\"context\":\""
s_json_tail:        .asciz "\"}"
s_key_text:         .asciz "\"text\""
s_nl:               .asciz "\n"
m_reply_open:       .asciz "\n--- REPLY ---\n"
m_nokey:            .asciz "\nNO ARMEDIT KEY. REGISTER AT ARMEDIT.OEAIO.COM AND SET ARMEDIT_KEY.\n"
m_badaddr:          .asciz "\nARMEDIT_BACKEND MUST LOOK LIKE 127.0.0.1:8080\n"
m_unreachable:      .asciz "\nBACKEND UNREACHABLE.\n"
m_badreply:         .asciz "\nBACKEND REPLY HAD NO TEXT FIELD.\n"
m_empty:            .asciz "\nEMPTY REPLY. NOTHING CHANGED.\n"

        BSS
        .p2align 4
req:        .space 80
saved_cursor: .space 8
keybuf:     .space KEY_SZ           /* the key with any @address stripped off */
rawbuf:     .space CTX_SZ           /* the screen as it is, before redaction */
ctxbuf:     .space CTX_SZ
instrbuf:   .space CTX_SZ
basebuf:    .space CTX_SZ
selbuf:     .space CTX_SZ
region_a:   .space 8
region_b:   .space 8
fetch_status: .space 8
subjtext:   .space 64
targetbuf:  .space 32
reply_whole: .space 8
reply_colour: .space 8
reply_reboot: .space 8
pending_reboot: .space 8
bodybuf:    .space BODY_SZ
hdrbuf:     .space HDRS_SZ
respbuf:    .space RESP_SZ
replybuf:   .space REPLY_SZ
