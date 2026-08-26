#include "asm.inc"
#include "editor.inc"
/*
 * backend_client.S - the editor's entire view of the outside world.
 *
 * The editor knows one server and one credential: its own backend, and the
 * asmedit key issued by asmedit.oeaio.com.  It does not know that Claude
 * exists, does not know what an aicoin wallet is, and holds no AWS
 * credentials - the backend owns all of that.  What travels on this wire is
 * the screen's text out, and text back.
 *
 *   POST /api/agent
 *   X-Asmedit-Key: <the one key>
 *   {"mode":"agent"|"aify","screen":<n>,"scroll":<r>,"rows":<n>,"cursor":<i>,
 *    "baseline":"<the text at the last sync>",
 *    "context":"<the whole current screen>"}
 * ->
 *   {"text":"<what came back>"}
 *
 * "agent" appends the answer under a marker; "aify" drops it straight in at
 * the caret, where the user pressed the key.  Neither one removes text: an
 * empty or missing reply leaves the screen exactly as it was.
 *
 * scroll/rows tell the backend which part of the text the user is actually
 * looking at, and baseline is what the text was the last time the backend saw
 * it - so the far side can reason about the edit, not just the file.
 *
 * Configuration comes from the environment: ASMEDIT_BACKEND (address:port,
 * default 127.0.0.1:8080) and ASMEDIT_KEY.  Neither is ever written to disk
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

        CODE
        .p2align 2

/*
 * resolve_backend - work out where to send things, and with what.
 *   out x0 = address string ("a.b.c.d:port"), x1 = key, or x1 = 0 if unset
 *
 * A device is configured with exactly one value: ASMEDIT_KEY.  The key the
 * backend issues carries the address to reach it at, as "<secret>@<addr>", so
 * there is no second setting to get wrong and no endpoint baked into the
 * binary.  A bare key falls back to the local default, and ASMEDIT_BACKEND
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
        .globl  SYM(backend_submit)
SYM(backend_submit):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        str     x23, [sp, #48]
        mov     w23, w0                 /* ED_SUBMIT or ED_AIFY */
        bl      SYM(editor_cursor_get)  /* where the user was when they asked */
        LEA     x9, saved_cursor
        str     w0, [x9]

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
        LEA     x0, m_badaddr
        bl      SYM(editor_insert_str)
        b       .Lsub_out
3:

/* ---- {"screen":N,"context":"..."} --------------------------------------- */
        LEA     x0, ctxbuf
        mov     w1, #CTX_SZ
        bl      SYM(editor_context)

        LEA     x22, bodybuf
        mov     x0, x22
        LEA     x1, s_json_mode
        bl      SYM(str_copy)
        mov     x22, x0
        cmp     w23, #ED_AIFY
        b.ne    10f
        LEA     x1, s_mode_aify
        b       11f
10:     LEA     x1, s_mode_agent
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

/* ---- X-Asmedit-Key: <key> ---------------------------------------------- */
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
        LEA     x0, m_unreachable
        bl      SYM(editor_insert_str)
        b       .Lsub_out
4:

/* ---- {"text":"..."} back into the buffer -------------------------------- */
        LEA     x0, respbuf
        bl      SYM(http_body)
        LEA     x1, s_key_text
        bl      SYM(json_find)
        cbnz    x0, 4f
        LEA     x0, m_badreply
        bl      SYM(editor_insert_str)
        b       .Lsub_out
4:      mov     x1, x0
        LEA     x0, replybuf
        mov     w2, #REPLY_SZ
        bl      SYM(json_unescape)
        LEA     x9, replybuf            /* nothing came back: change nothing */
        ldrb    w10, [x9]
        cbnz    w10, 5f
        LEA     x0, m_empty
        bl      SYM(editor_insert_str)
        b       .Lsub_out
5:      cmp     w23, #ED_AIFY
        b.ne    6f
        LEA     x0, saved_cursor        /* aify: land it exactly where the key
                                           was pressed, leaving the rest of the
                                           screen alone */
        ldr     w0, [x0]
        bl      SYM(editor_cursor_set)
        LEA     x0, replybuf
        bl      SYM(editor_insert_str)
        bl      SYM(editor_mark_synced)
        b       .Lsub_out
6:      LEA     x0, m_reply_open        /* agent: append it below */
        bl      SYM(editor_insert_str)
        LEA     x0, replybuf
        bl      SYM(editor_insert_str)
        LEA     x0, s_nl
        bl      SYM(editor_insert_str)
        bl      SYM(editor_mark_synced)

.Lsub_out:
        ldr     x23, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * backend_session - ask the backend for this account's instance at startup.
 * The editor is meant to open with somewhere to run things already attached;
 * the backend decides whether that means starting one or reusing the one this
 * account already has.
 */
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
s_env_backend:      .asciz "ASMEDIT_BACKEND"
s_env_key:          .asciz "ASMEDIT_KEY"
s_default_backend:  .asciz "127.0.0.1:8080"
s_post:             .asciz "POST"
s_path_agent:       .asciz "/api/agent"
s_hdr_key:          .asciz "Content-Type: application/json\r\nX-Asmedit-Key: "
s_hdr_tail:         .asciz "\r\n"
s_json_mode:        .asciz "{\"mode\":\""
s_mode_agent:       .asciz "agent"
s_mode_aify:        .asciz "aify"
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
m_nokey:            .asciz "\nNO ASMEDIT KEY. REGISTER AT ASMEDIT.OEAIO.COM AND SET ASMEDIT_KEY.\n"
m_badaddr:          .asciz "\nASMEDIT_BACKEND MUST LOOK LIKE 127.0.0.1:8080\n"
m_unreachable:      .asciz "\nBACKEND UNREACHABLE.\n"
m_badreply:         .asciz "\nBACKEND REPLY HAD NO TEXT FIELD.\n"
m_empty:            .asciz "\nEMPTY REPLY. NOTHING CHANGED.\n"

        BSS
        .p2align 4
req:        .space 80
saved_cursor: .space 8
keybuf:     .space KEY_SZ           /* the key with any @address stripped off */
ctxbuf:     .space CTX_SZ
basebuf:    .space CTX_SZ
bodybuf:    .space BODY_SZ
hdrbuf:     .space HDRS_SZ
respbuf:    .space RESP_SZ
replybuf:   .space REPLY_SZ
