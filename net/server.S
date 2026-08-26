#include "asm.inc"
/*
 * server.S - the listening half of the socket layer.
 *
 * One process, one connection at a time, no threads: the backend's work is
 * dominated by waiting on an upstream API, and a serial accept loop is honest
 * about what it is.  Concurrency is a later milestone, not a hidden claim.
 */
#define SYS_READ        3
#define SYS_WRITE       4
#define SYS_CLOSE       6
#define SYS_ACCEPT      30
#define SYS_SOCKET      97
#define SYS_BIND        104
#define SYS_SETSOCKOPT  105
#define SYS_LISTEN      106
#define AF_INET         2
#define SOCK_STREAM     1
#define SOL_SOCKET      0xFFFF
#define SO_REUSEADDR    0x0004

        CODE
        .p2align 2

/* server_listen - w0 = port; out w0 = listening fd, or -1 */
        .globl  SYM(server_listen)
SYM(server_listen):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     w19, w0

        mov     x0, #AF_INET
        mov     x1, #SOCK_STREAM
        mov     x2, #0
        mov     x16, #SYS_SOCKET
        svc     #0x80
        b.cs    .Lsrv_fail
        mov     w20, w0

        LEA     x9, one                 /* SO_REUSEADDR, so restarts are quick */
        mov     w10, #1
        str     w10, [x9]
        mov     w0, w20
        mov     x1, #SOL_SOCKET
        mov     x2, #SO_REUSEADDR
        LEA     x3, one
        mov     x4, #4
        mov     x16, #SYS_SETSOCKOPT
        svc     #0x80

        LEA     x9, srv_addr
        mov     w10, #16
        strb    w10, [x9, #0]
        mov     w10, #AF_INET
        strb    w10, [x9, #1]
        rev16   w10, w19
        strh    w10, [x9, #2]
        str     wzr, [x9, #4]           /* INADDR_ANY */
        str     xzr, [x9, #8]
        mov     w0, w20
        LEA     x1, srv_addr
        mov     x2, #16
        mov     x16, #SYS_BIND
        svc     #0x80
        b.cs    .Lsrv_close

        mov     w0, w20
        mov     x1, #16                 /* backlog */
        mov     x16, #SYS_LISTEN
        svc     #0x80
        b.cs    .Lsrv_close
        mov     w0, w20
        b       .Lsrv_out
.Lsrv_close:
        mov     w0, w20
        mov     x16, #SYS_CLOSE
        svc     #0x80
.Lsrv_fail:
        mov     w0, #-1
.Lsrv_out:
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* server_accept - w0 = listening fd; out w0 = connection fd, or -1 */
        .globl  SYM(server_accept)
SYM(server_accept):
        mov     x1, #0
        mov     x2, #0
        mov     x16, #SYS_ACCEPT
        svc     #0x80
        b.cs    1f
        ret
1:      mov     w0, #-1
        ret

/*
 * server_read_request - read one HTTP request: headers, then exactly as many
 * body bytes as Content-Length promises.
 *   w0 = fd, x1 = buffer, w2 = capacity; out w0 = total bytes, or -1
 */
        .globl  SYM(server_read_request)
SYM(server_read_request):
        stp     x29, x30, [sp, #-80]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        str     x25, [sp, #64]
        mov     w19, w0
        mov     x20, x1
        mov     w21, w2
        sub     w21, w21, #1
        mov     w22, #0                 /* bytes read so far */
        mov     w23, #-1                /* offset of the body, once known */
        mov     w24, #0                 /* content length */

1:      cmp     w22, w21
        b.hs    .Lreq_done
        mov     w0, w19
        add     x1, x20, w22, uxtw
        sub     w2, w21, w22
        mov     x16, #SYS_READ
        svc     #0x80
        b.cs    .Lreq_done
        cmp     w0, #0
        b.le    .Lreq_done
        add     w22, w22, w0
        strb    wzr, [x20, w22, uxtw]

        tbz     w23, #31, 3f            /* headers already located? */
        mov     x0, x20
        bl      SYM(http_body)
        cbz     x0, 1b
        sub     x9, x0, x20
        cmp     x9, #0
        b.eq    1b
        mov     w23, w9
        cmp     w23, w22                /* http_body returns the buffer itself
                                           when there is no blank line yet */
        b.hi    1b
        mov     x0, x20
        LEA     x1, s_clen_hdr
        bl      SYM(str_find_ci)
        cbz     x0, 2f
        ldrb    w9, [x0]                /* skip the space after the colon */
        cmp     w9, #' '
        b.ne    5f
        add     x0, x0, #1
5:      bl      SYM(str_to_u32)
        mov     w24, w0
2:
3:      add     w9, w23, w24            /* have we got the whole body? */
        tbnz    w23, #31, 1b
        cmp     w22, w9
        b.lo    1b

.Lreq_done:
        mov     w0, w22
        ldr     x25, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #80
        ret

/*
 * server_write - w0 = fd, x1 = buffer, w2 = length.
 * State lives in callee-saved registers: what a syscall leaves in the scratch
 * registers is not something to rely on across the loop.
 */
        .globl  SYM(server_write)
SYM(server_write):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]
        mov     w19, w0
        mov     x20, x1
        mov     w21, w2
1:      cbz     w21, 9f
        mov     w0, w19
        mov     x1, x20
        mov     w2, w21
        mov     x16, #SYS_WRITE
        svc     #0x80
        b.cs    9f
        cmp     w0, #0
        b.le    9f
        add     x20, x20, w0, uxtw
        sub     w21, w21, w0
        b       1b
9:      ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* server_close - w0 = fd */
        .globl  SYM(server_close)
SYM(server_close):
        mov     x16, #SYS_CLOSE
        svc     #0x80
        ret

        CSTR
s_clen_hdr:     .asciz "content-length:"

        BSS
        .p2align 4
srv_addr:       .space 16
one:            .space 8
