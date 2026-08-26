#include "asm.inc"
#include "account.inc"
/*
 * daemon.S - the asmedit backend.
 *
 * This is the only process in the system that holds credentials.  It serves
 * the registration page, issues asmedit keys, spends aicoin on the account's
 * behalf, and provisions the account's instance.  Devices hold one key and
 * know none of the rest.
 *
 * Endpoints:
 *   GET  /                registration page
 *   GET  /api/health
 *   POST /api/register    {wallet, aws_key, aws_secret, region} -> {key}
 *   POST /api/agent       X-Asmedit-Key; {mode, context, baseline} -> {text}
 *   POST /api/session     X-Asmedit-Key -> {instance}
 *   POST /api/teardown    X-Asmedit-Key -> {instance:""}
 */
#define SYS_EXIT        1
#define SYS_WRITE       4
#define REQ_SZ          65536
#define OUT_SZ          65536
#define FIELD_SZ        16384

        CODE
        .p2align 2
        .globl  _main
_main:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]

        mov     x0, x2                  /* envp: where all configuration lives */
        bl      SYM(env_init)

        LEA     x0, s_env_port
        bl      SYM(env_get)
        cbz     x0, 1f
        bl      SYM(str_to_u32)
        mov     w19, w0
        cbnz    w19, 2f
1:      mov     w19, #8080
2:      mov     w0, w19
        bl      SYM(server_listen)
        cmp     w0, #0
        b.ge    3f
        LEA     x1, m_listen_failed
        mov     x2, #34
        mov     x0, #2
        mov     x16, #SYS_WRITE
        svc     #0x80
        mov     x0, #1
        mov     x16, #SYS_EXIT
        svc     #0x80
3:      mov     w20, w0                 /* listening socket */

        LEA     x0, banner              /* say where we are */
        bl      SYM(str_len)
        mov     w2, w0
        LEA     x1, banner
        mov     x0, #1
        mov     x16, #SYS_WRITE
        svc     #0x80

.Laccept:
        mov     w0, w20
        bl      SYM(server_accept)
        tbnz    w0, #31, .Laccept
        mov     w21, w0
        mov     w0, w21
        LEA     x1, reqbuf
        mov     w2, #REQ_SZ
        bl      SYM(server_read_request)
        cmp     w0, #0
        b.le    4f
        mov     w0, w21
        LEA     x1, reqbuf
        bl      handle
4:      mov     w0, w21
        bl      SYM(server_close)
        b       .Laccept

/* ------------------------------------------------------------------ routing */
/* handle - w0 = fd, x1 = request */
handle:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     w19, w0
        mov     x20, x1

        mov     x0, x20
        LEA     x1, r_get_root
        bl      SYM(str_starts)
        cbnz    w0, .Lpage
        mov     x0, x20
        LEA     x1, r_get_index
        bl      SYM(str_starts)
        cbnz    w0, .Lpage
        mov     x0, x20
        LEA     x1, r_health
        bl      SYM(str_starts)
        cbnz    w0, .Lhealth
        mov     x0, x20
        LEA     x1, r_register
        bl      SYM(str_starts)
        cbnz    w0, .Lregister
        mov     x0, x20
        LEA     x1, r_agent
        bl      SYM(str_starts)
        cbnz    w0, .Lagent
        mov     x0, x20
        LEA     x1, r_session
        bl      SYM(str_starts)
        cbnz    w0, .Lsession
        mov     x0, x20
        LEA     x1, r_teardown
        bl      SYM(str_starts)
        cbnz    w0, .Lteardown

        mov     w0, w19                 /* nothing matched */
        LEA     x1, st_404
        LEA     x2, ct_json
        LEA     x3, j_notfound
        bl      send_str
        b       .Lhandled

.Lpage: mov     w0, w19
        LEA     x1, st_200
        LEA     x2, ct_html
        LEA     x3, SYM(page)
        bl      send_str
        b       .Lhandled

.Lhealth:
        mov     w0, w19
        LEA     x1, st_200
        LEA     x2, ct_json
        LEA     x3, j_ok
        bl      send_str
        b       .Lhandled

.Lregister:
        mov     w0, w19
        mov     x1, x20
        bl      h_register
        b       .Lhandled
.Lagent:
        mov     w0, w19
        mov     x1, x20
        bl      h_agent
        b       .Lhandled
.Lsession:
        mov     w0, w19
        mov     x1, x20
        mov     w2, #1
        bl      h_session
        b       .Lhandled
.Lteardown:
        mov     w0, w19
        mov     x1, x20
        mov     w2, #0
        bl      h_session

.Lhandled:
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* ---------------------------------------------------------------- responses */
/*
 * send_str - w0 = fd, x1 = status line, x2 = content type, x3 = body
 */
send_str:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     w19, w0
        mov     x20, x1
        mov     x21, x2
        mov     x22, x3

        LEA     x0, outbuf
        LEA     x1, s_http
        bl      SYM(str_copy)
        mov     x1, x20
        bl      SYM(str_copy)
        LEA     x1, s_ct
        bl      SYM(str_copy)
        mov     x1, x21
        bl      SYM(str_copy)
        LEA     x1, s_cl
        bl      SYM(str_copy)
        mov     x23, x0
        mov     x0, x22
        bl      SYM(str_len)
        mov     w1, w0
        mov     x0, x23
        bl      SYM(u32_dec)
        LEA     x1, s_hdr_end
        bl      SYM(str_copy)
        mov     x1, x22
        bl      SYM(str_copy)

        LEA     x0, outbuf
        bl      SYM(str_len)
        mov     w2, w0
        mov     w0, w19
        LEA     x1, outbuf
        bl      SYM(server_write)

        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/* ------------------------------------------------------------- registration */
/*
 * h_register - both accesses or nothing.  An account without an aicoin wallet
 * cannot pay for a call, and one without AWS credentials cannot be given an
 * instance; issuing a key for half an account would only fail later, further
 * from the cause.
 */
h_register:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     w19, w0
        mov     x0, x1
        bl      SYM(http_body)
        mov     x20, x0

        mov     x0, x20
        LEA     x1, k_wallet
        LEA     x2, f_wallet
        mov     w3, #256
        bl      SYM(json_get_str)
        mov     x0, x20
        LEA     x1, k_aws_key
        LEA     x2, f_akid
        mov     w3, #128
        bl      SYM(json_get_str)
        mov     x0, x20
        LEA     x1, k_aws_secret
        LEA     x2, f_secret
        mov     w3, #128
        bl      SYM(json_get_str)
        mov     x0, x20
        LEA     x1, k_region
        LEA     x2, f_region
        mov     w3, #32
        bl      SYM(json_get_str)

        LEA     x9, f_wallet            /* all three, or none */
        ldrb    w10, [x9]
        cbz     w10, .Lreg_missing
        LEA     x9, f_akid
        ldrb    w10, [x9]
        cbz     w10, .Lreg_missing
        LEA     x9, f_secret
        ldrb    w10, [x9]
        cbz     w10, .Lreg_missing
        LEA     x9, f_region
        ldrb    w10, [x9]
        cbnz    w10, 1f
        LEA     x0, f_region
        LEA     x1, s_region_default
        bl      SYM(str_copy)
1:
        bl      acct_new
        cbz     x0, .Lreg_full
        mov     x21, x0
        add     x0, x21, #ACCT_KEY      /* 24 bytes of entropy, hex */
        mov     w1, #24
        bl      SYM(rand_hex)
        tbnz    w0, #31, .Lreg_full

        add     x0, x21, #ACCT_WALLET
        LEA     x1, f_wallet
        bl      SYM(str_copy)
        add     x0, x21, #ACCT_AKID
        LEA     x1, f_akid
        bl      SYM(str_copy)
        add     x0, x21, #ACCT_SECRET
        LEA     x1, f_secret
        bl      SYM(str_copy)
        add     x0, x21, #ACCT_REGION
        LEA     x1, f_region
        bl      SYM(str_copy)
        add     x0, x21, #ACCT_INSTANCE
        strb    wzr, [x0]

        LEA     x0, jbuf                /* {"key":"..."} */
        LEA     x1, j_key_head
        bl      SYM(str_copy)
        add     x1, x21, #ACCT_KEY
        bl      SYM(str_copy)
        LEA     x1, j_tail
        bl      SYM(str_copy)
        mov     w0, w19
        LEA     x1, st_200
        LEA     x2, ct_json
        LEA     x3, jbuf
        bl      send_str
        b       .Lreg_out

.Lreg_missing:
        mov     w0, w19
        LEA     x1, st_400
        LEA     x2, ct_json
        LEA     x3, j_need_both
        bl      send_str
        b       .Lreg_out
.Lreg_full:
        mov     w0, w19
        LEA     x1, st_503
        LEA     x2, ct_json
        LEA     x3, j_full
        bl      send_str
.Lreg_out:
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/* ------------------------------------------------------------------- agent */
h_agent:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     w19, w0
        mov     x20, x1

        mov     x0, x20
        bl      req_account
        cbz     x0, .Lag_unauth
        mov     x21, x0

        mov     x0, x20
        bl      SYM(http_body)
        mov     x22, x0
        mov     x0, x22
        LEA     x1, k_mode
        LEA     x2, f_mode
        mov     w3, #32
        bl      SYM(json_get_str)
        mov     x0, x22
        LEA     x1, k_context
        LEA     x2, f_context
        mov     w3, #FIELD_SZ
        bl      SYM(json_get_str)
        mov     x0, x22
        LEA     x1, k_baseline
        LEA     x2, f_baseline
        mov     w3, #FIELD_SZ
        bl      SYM(json_get_str)

        mov     x0, x21
        LEA     x1, f_mode
        LEA     x2, f_context
        LEA     x3, f_baseline
        LEA     x4, f_reply
        mov     w5, #FIELD_SZ
        bl      SYM(aicoin_ask)
        tbnz    w0, #31, .Lag_upstream

        LEA     x0, jbuf                /* {"text":"..."} */
        LEA     x1, j_text_head
        bl      SYM(str_copy)
        LEA     x1, f_reply
        mov     w2, #(OUT_SZ / 2)
        bl      SYM(json_escape)
        LEA     x1, j_tail
        bl      SYM(str_copy)
        mov     w0, w19
        LEA     x1, st_200
        LEA     x2, ct_json
        LEA     x3, jbuf
        bl      send_str
        b       .Lag_out

.Lag_unauth:
        mov     w0, w19
        LEA     x1, st_401
        LEA     x2, ct_json
        LEA     x3, j_unauth
        bl      send_str
        b       .Lag_out
.Lag_upstream:
        mov     w0, w19
        LEA     x1, st_502
        LEA     x2, ct_json
        LEA     x3, j_upstream
        bl      send_str
.Lag_out:
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/* ----------------------------------------------------------------- session */
/* h_session - w0 = fd, x1 = request, w2 = 1 to provision, 0 to tear down */
h_session:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     w19, w0
        mov     x20, x1
        mov     w22, w2

        mov     x0, x20
        bl      req_account
        cbz     x0, .Lse_unauth
        mov     x21, x0

        mov     x0, x21
        cbz     w22, 1f
        bl      SYM(aws_provision)
        b       2f
1:      bl      SYM(aws_deprovision)
2:      cmp     w0, #-2
        b.eq    .Lse_noami
        tbnz    w0, #31, .Lse_fail

        LEA     x0, jbuf                /* {"instance":"..."} */
        LEA     x1, j_inst_head
        bl      SYM(str_copy)
        add     x1, x21, #ACCT_INSTANCE
        bl      SYM(str_copy)
        LEA     x1, j_tail
        bl      SYM(str_copy)
        mov     w0, w19
        LEA     x1, st_200
        LEA     x2, ct_json
        LEA     x3, jbuf
        bl      send_str
        b       .Lse_out

.Lse_unauth:
        mov     w0, w19
        LEA     x1, st_401
        LEA     x2, ct_json
        LEA     x3, j_unauth
        bl      send_str
        b       .Lse_out
.Lse_noami:
        mov     w0, w19
        LEA     x1, st_400
        LEA     x2, ct_json
        LEA     x3, j_noami
        bl      send_str
        b       .Lse_out
.Lse_fail:
        mov     w0, w19
        LEA     x1, st_502
        LEA     x2, ct_json
        LEA     x3, j_awsfail
        bl      send_str
.Lse_out:
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/* --------------------------------------------------------------- accounts */
/* req_account - x0 = request; out x0 = the account its key names, or 0 */
req_account:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        LEA     x1, h_key
        bl      SYM(str_find_ci)
        cbz     x0, 9f
        mov     x19, x0
1:      ldrb    w9, [x19]               /* skip the space after the colon */
        cmp     w9, #' '
        b.ne    2f
        add     x19, x19, #1
        b       1b
2:      LEA     x1, f_key
        mov     w2, #0
3:      ldrb    w9, [x19], #1
        cmp     w9, #'\r'
        b.eq    4f
        cmp     w9, #'\n'
        b.eq    4f
        cbz     w9, 4f
        strb    w9, [x1, w2, uxtw]
        add     w2, w2, #1
        cmp     w2, #64
        b.lo    3b
4:      strb    wzr, [x1, w2, uxtw]
        LEA     x0, f_key
        bl      acct_find
        b       8f
9:      mov     x0, #0
8:      ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/* acct_find - x0 = key; out x0 = account or 0 */
acct_find:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]
        mov     x19, x0
        LEA     x20, accounts
        mov     w21, #0
1:      cmp     w21, #ACCT_MAX
        b.hs    9f
        mov     w9, #ACCT_SZ
        mul     w9, w21, w9
        add     x0, x20, w9, uxtw
        ldr     w10, [x0, #ACCT_USED]
        cbz     w10, 2f
        mov     x1, x19
        bl      SYM(str_eq)
        cbz     w0, 2f
        mov     w9, #ACCT_SZ
        mul     w9, w21, w9
        add     x0, x20, w9, uxtw
        b       8f
2:      add     w21, w21, #1
        b       1b
9:      mov     x0, #0
8:      ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* acct_new - out x0 = a free account slot, or 0 */
acct_new:
        LEA     x1, accounts
        mov     w2, #0
1:      cmp     w2, #ACCT_MAX
        b.hs    9f
        mov     w3, #ACCT_SZ
        mul     w3, w2, w3
        add     x0, x1, w3, uxtw
        ldr     w4, [x0, #ACCT_USED]
        cbnz    w4, 2f
        mov     w4, #1
        str     w4, [x0, #ACCT_USED]
        ret
2:      add     w2, w2, #1
        b       1b
9:      mov     x0, #0
        ret

        CSTR
s_env_port:     .asciz "ASMEDIT_PORT"
banner:         .asciz "asmedit backend listening. register at / to bind a wallet and AWS access.\n"
m_listen_failed:.asciz "asmedit: cannot listen\n"
s_http:         .asciz "HTTP/1.1 "
s_ct:           .asciz "\r\nContent-Type: "
s_cl:           .asciz "\r\nConnection: close\r\nContent-Length: "
s_hdr_end:      .asciz "\r\n\r\n"
st_200:         .asciz "200 OK"
st_400:         .asciz "400 Bad Request"
st_401:         .asciz "401 Unauthorized"
st_404:         .asciz "404 Not Found"
st_502:         .asciz "502 Bad Gateway"
st_503:         .asciz "503 Service Unavailable"
ct_json:        .asciz "application/json"
ct_html:        .asciz "text/html; charset=utf-8"
r_get_root:     .asciz "GET / "
r_get_index:    .asciz "GET /index.html"
r_health:       .asciz "GET /api/health"
r_register:     .asciz "POST /api/register"
r_agent:        .asciz "POST /api/agent"
r_session:      .asciz "POST /api/session"
r_teardown:     .asciz "POST /api/teardown"
h_key:          .asciz "x-asmedit-key:"
k_wallet:       .asciz "\"wallet\""
k_aws_key:      .asciz "\"aws_key\""
k_aws_secret:   .asciz "\"aws_secret\""
k_region:       .asciz "\"region\""
k_mode:         .asciz "\"mode\""
k_context:      .asciz "\"context\""
k_baseline:     .asciz "\"baseline\""
s_region_default: .asciz "us-east-1"
j_ok:           .asciz "{\"ok\":true}"
j_notfound:     .asciz "{\"error\":\"no such endpoint\"}"
j_unauth:       .asciz "{\"error\":\"unknown or missing asmedit key\"}"
j_need_both:    .asciz "{\"error\":\"an account needs both an aicoin wallet token and AWS access\"}"
j_full:         .asciz "{\"error\":\"no free account slots\"}"
j_upstream:     .asciz "{\"error\":\"aicoin proxy unreachable\"}"
j_awsfail:      .asciz "{\"error\":\"ec2 call failed\"}"
j_noami:        .asciz "{\"error\":\"set ASMEDIT_AMI to the image the instance should run\"}"
j_key_head:     .asciz "{\"key\":\""
j_text_head:    .asciz "{\"text\":\""
j_inst_head:    .asciz "{\"instance\":\""
j_tail:         .asciz "\"}"

        BSS
        .p2align 4
reqbuf:         .space REQ_SZ
outbuf:         .space OUT_SZ
jbuf:           .space OUT_SZ
accounts:       .space (ACCT_MAX * ACCT_SZ)
f_wallet:       .space 256
f_akid:         .space 128
f_secret:       .space 128
f_region:       .space 32
f_key:          .space 72
f_mode:         .space 32
f_context:      .space FIELD_SZ
f_baseline:     .space FIELD_SZ
f_reply:        .space FIELD_SZ
