#include "asm.inc"
/* nettest.S - drive net/http.S against a local server and dump the reply. */
#define SYS_EXIT   1
#define SYS_WRITE  4
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

        CODE
        .p2align 2
        .globl  _main
_main:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]

        mov     w0, #127
        mov     w1, #0
        mov     w2, #0
        mov     w3, #1
        bl      SYM(net_ip4)
        LEA     x19, req
        str     w0, [x19, #REQ_IP]
        mov     w0, #8099
        strh    w0, [x19, #REQ_PORT]
        LEA     x0, s_post
        str     x0, [x19, #REQ_METHOD]
        LEA     x0, s_path
        str     x0, [x19, #REQ_PATH]
        LEA     x0, s_host
        str     x0, [x19, #REQ_HOST]
        LEA     x0, s_hdrs
        str     x0, [x19, #REQ_HDRS]
        LEA     x0, s_body
        str     x0, [x19, #REQ_BODY]
        bl      SYM(str_len)            /* clobbers nothing we need */
        LEA     x0, s_body
        bl      SYM(str_len)
        str     w0, [x19, #REQ_BODYLEN]
        LEA     x0, respbuf
        str     x0, [x19, #REQ_OUT]
        mov     w0, #8192
        str     w0, [x19, #REQ_OUTCAP]

        mov     x0, x19
        bl      SYM(http_request)
        cmp     w0, #0
        b.gt    1f
        LEA     x1, s_failed
        mov     x2, #16
        b       2f
1:      mov     w2, w0
        LEA     x1, respbuf
2:      mov     x0, #1
        mov     x16, #SYS_WRITE
        svc     #0x80
        mov     w0, #0
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

        CSTR
s_post:   .asciz "POST"
s_path:   .asciz "/echo"
s_host:   .asciz "127.0.0.1:8099"
s_hdrs:   .asciz "X-Armedit-Test: 1\r\nContent-Type: application/json\r\n"
s_body:   .asciz "{\"hello\":\"from assembly\"}"
s_failed: .asciz "http_request failed\n"

        BSS
        .p2align 4
req:      .space 80
respbuf:  .space 8192
