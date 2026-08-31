#include "asm.inc"
/*
 * http.S - an HTTP/1.1 client over BSD sockets, hosted target.
 *
 * Sockets are reached through raw syscalls (socket/connect/read/write/close),
 * so there is no libc and no HTTP library in the path - the request bytes are
 * assembled here, character by character, and the response is read back into a
 * caller-supplied buffer.
 *
 * Darwin reports syscall failure by setting the carry flag and returning errno
 * in x0, which is what every b.cs below is testing.
 */
#define SYS_READ        3
#define SYS_WRITE       4
#define SYS_CLOSE       6
#define SYS_SOCKET      97
#define SYS_CONNECT     98
#define AF_INET         2
#define SOCK_STREAM     1

/* struct http_req */
#define REQ_IP          0       /* u32, network byte order */
#define REQ_PORT        4       /* u16, host byte order    */
#define REQ_METHOD      8
#define REQ_PATH        16
#define REQ_HOST        24
#define REQ_HDRS        32      /* extra headers, each CRLF-terminated, or 0 */
#define REQ_BODY        40
#define REQ_BODYLEN     48
#define REQ_OUT         56
#define REQ_OUTCAP      64

#define REQBUF_SZ       32768

        CODE
        .p2align 2

/* net_ip4 - w0.w1.w2.w3 -> a packed address in network byte order */
        .globl  SYM(net_ip4)
SYM(net_ip4):
        and     w0, w0, #0xFF
        and     w1, w1, #0xFF
        and     w2, w2, #0xFF
        and     w3, w3, #0xFF
        orr     w0, w0, w1, lsl #8
        orr     w0, w0, w2, lsl #16
        orr     w0, w0, w3, lsl #24
        ret

/*
 * http_request - one request/response exchange on a fresh connection.
 *   x0 = struct http_req *
 *   out w0 = bytes of response (headers included), or -1
 */
        .globl  SYM(http_request)
SYM(http_request):
        stp     x29, x30, [sp, #-112]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        stp     x27, x28, [sp, #80]
        mov     x19, x0

/* ---- build the request ------------------------------------------------- */
        LEA     x20, http_reqbuf
        mov     x28, x20                /* remember the start */
        mov     x0, x20
        ldr     x1, [x19, #REQ_METHOD]
        bl      SYM(str_copy)
        mov     x20, x0
        mov     w9, #' '
        strb    w9, [x20], #1
        mov     x0, x20
        ldr     x1, [x19, #REQ_PATH]
        bl      SYM(str_copy)
        mov     x20, x0
        mov     x0, x20
        LEA     x1, s_proto
        bl      SYM(str_copy)
        mov     x20, x0
        mov     x0, x20
        ldr     x1, [x19, #REQ_HOST]
        bl      SYM(str_copy)
        mov     x20, x0
        mov     x0, x20
        LEA     x1, s_fixed_hdrs
        bl      SYM(str_copy)
        mov     x20, x0

        ldr     x1, [x19, #REQ_HDRS]
        cbz     x1, 1f
        mov     x0, x20
        bl      SYM(str_copy)
        mov     x20, x0
1:      ldr     x1, [x19, #REQ_BODY]
        cbz     x1, 2f
        mov     x0, x20
        LEA     x1, s_clen
        bl      SYM(str_copy)
        mov     x20, x0
        mov     x0, x20
        ldr     w1, [x19, #REQ_BODYLEN]
        bl      SYM(u32_dec)
        mov     x20, x0
        mov     x0, x20
        LEA     x1, s_crlf
        bl      SYM(str_copy)
        mov     x20, x0
2:      mov     x0, x20                 /* blank line ends the headers */
        LEA     x1, s_crlf
        bl      SYM(str_copy)
        mov     x20, x0

        ldr     x1, [x19, #REQ_BODY]
        cbz     x1, 3f
        ldr     w2, [x19, #REQ_BODYLEN]
        mov     w9, #0
4:      cmp     w9, w2
        b.hs    3f
        ldrb    w10, [x1, w9, uxtw]
        strb    w10, [x20], #1
        add     w9, w9, #1
        b       4b
3:      sub     x24, x20, x28           /* total request length */

/*
 * ---- the exchange --------------------------------------------------------
 *
 * Four calls, and each target supplies them: sockets under an operating
 * system, and the kernel's own TCP on bare metal. What is above this line -
 * building a request, finding the body - is identical either way, which is
 * the point of putting the seam here rather than writing the whole client
 * twice.
 */
        ldr     w0, [x19, #REQ_IP]
        ldrh    w1, [x19, #REQ_PORT]
        bl      SYM(sock_open)
        cmn     w0, #1
        b.eq    .Lfail
        mov     w21, w0

        mov     x23, x28                /* everything we built, out */
5:      cbz     w24, 6f
        mov     w0, w21
        mov     x1, x23
        mov     w2, w24
        bl      SYM(sock_write)
        cmp     w0, #0
        b.le    .Lfail_close
        add     x23, x23, w0, uxtw
        sub     w24, w24, w0
        b       5b
6:
        ldr     x25, [x19, #REQ_OUT]    /* and the answer back */
        ldr     w26, [x19, #REQ_OUTCAP]
        sub     w26, w26, #1            /* leave room for a NUL */
        mov     w27, #0
7:      cmp     w27, w26
        b.hs    8f
        mov     w0, w21
        add     x1, x25, w27, uxtw
        sub     w2, w26, w27
        bl      SYM(sock_read)
        cmp     w0, #0
        b.le    8f
        add     w27, w27, w0
        b       7b
8:      add     x9, x25, w27, uxtw
        strb    wzr, [x9]
        mov     w0, w21
        bl      SYM(sock_close)
        mov     w0, w27
        b       .Lout

.Lfail_close:
        mov     w0, w21
        bl      SYM(sock_close)
.Lfail:
        mov     w0, #-1
.Lout:
        ldp     x27, x28, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #112
        ret

/*
 * net_parse_addr - "a.b.c.d:port" -> packed address and port.
 *   x0 = string, x1 = u32* for the address, x2 = u16* for the port
 *   out w0 = 0 on success, -1 if it is not a dotted quad with a port
 * Names are not resolved: the client is configured with an address, and DNS
 * is a later milestone rather than a hidden dependency.
 */
        .globl  SYM(net_parse_addr)
SYM(net_parse_addr):
        mov     x9, x0
        mov     w10, #0                 /* packed address, built byte by byte */
        mov     w11, #0                 /* octets seen */
.Loctet:
        mov     w12, #0                 /* value */
        mov     w13, #0                 /* digits */
1:      ldrb    w14, [x9]
        sub     w15, w14, #'0'
        cmp     w15, #9
        b.hi    2f
        mov     w16, #10
        mul     w12, w12, w16
        add     w12, w12, w15
        add     w13, w13, #1
        add     x9, x9, #1
        b       1b
2:      cbz     w13, .Lbad
        cmp     w12, #255
        b.hi    .Lbad
        lsl     w16, w11, #3
        lsl     w17, w12, w16           /* octet n goes in byte n */
        orr     w10, w10, w17
        add     w11, w11, #1
        cmp     w11, #4
        b.hs    3f
        ldrb    w14, [x9]
        cmp     w14, #'.'
        b.ne    .Lbad
        add     x9, x9, #1
        b       .Loctet
3:      ldrb    w14, [x9]
        cmp     w14, #':'
        b.ne    .Lbad
        add     x9, x9, #1
        mov     w12, #0
        mov     w13, #0
4:      ldrb    w14, [x9]
        sub     w15, w14, #'0'
        cmp     w15, #9
        b.hi    5f
        mov     w16, #10
        mul     w12, w12, w16
        add     w12, w12, w15
        add     w13, w13, #1
        add     x9, x9, #1
        b       4b
5:      cbz     w13, .Lbad
        str     w10, [x1]
        strh    w12, [x2]
        mov     w0, #0
        ret
.Lbad:  mov     w0, #-1
        ret

/*
 * http_body - x0 = raw response, out x0 = first byte after the blank line,
 * or the response itself if no header terminator is present.
 */
        .globl  SYM(http_body)
SYM(http_body):
        mov     x1, x0
1:      ldrb    w2, [x1]
        cbz     w2, 9f
        cmp     w2, #'\r'
        b.ne    2f
        ldrb    w3, [x1, #1]
        cmp     w3, #'\n'
        b.ne    2f
        ldrb    w3, [x1, #2]
        cmp     w3, #'\r'
        b.ne    2f
        ldrb    w3, [x1, #3]
        cmp     w3, #'\n'
        b.ne    2f
        add     x0, x1, #4
        ret
2:      add     x1, x1, #1
        b       1b
9:      ret

        CSTR
s_proto:        .asciz " HTTP/1.1\r\nHost: "
s_fixed_hdrs:   .asciz "\r\nConnection: close\r\nUser-Agent: armedit/0.1\r\n"
s_clen:         .asciz "Content-Length: "
s_crlf:         .asciz "\r\n"

        BSS
        .p2align 4
http_reqbuf:    .space REQBUF_SZ
http_sockaddr:  .space 16
