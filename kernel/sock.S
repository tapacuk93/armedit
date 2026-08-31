#include "asm.inc"
/*
 * sock.S - the bare-metal half of the seam net/http.S sits on.
 *
 * The same four names the hosted build gets from the operating system, over
 * the kernel's own TCP. There is exactly one connection, so the handle is a
 * formality: it is always zero, and opening a second before closing the first
 * would quietly reuse the same state. That is a real limit and it is here
 * rather than hidden, because the alternative - a table of sockets - is a
 * design decision this kernel has not needed to make yet.
 *
 * The read side is unusual and worth explaining. tcp_recv already waits for
 * the far side to finish and returns the whole body at once, because a
 * request-response exchange has a definite end. So the first read hands back
 * everything and every read after it reports end-of-stream, which is exactly
 * what the loop in http.S expects to see.
 */
        CODE
        .p2align 2

        .globl  SYM(sock_open)
SYM(sock_open):
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        bl      SYM(tcp_connect)
        cmn     w0, #1
        b.eq    1f
        LEA     x9, sock_drained
        str     wzr, [x9]
        mov     w0, #0                  /* the one handle there is */
        b       9f
1:      mov     w0, #-1
9:      ldp     x29, x30, [sp], #32
        ret

        .globl  SYM(sock_write)
SYM(sock_write):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     w19, w2
        mov     x0, x1
        mov     w1, w2
        bl      SYM(tcp_send)
        cmn     w0, #1
        b.eq    1f
        mov     w0, w19                 /* all of it, or none */
        b       9f
1:      mov     w0, #-1
9:      ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

        .globl  SYM(sock_read)
SYM(sock_read):
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        LEA     x9, sock_drained
        ldr     w9, [x9]
        cbnz    w9, 1f                  /* said everything already */
        mov     x0, x1
        mov     w1, w2
        bl      SYM(tcp_recv)
        LEA     x9, sock_drained
        mov     w10, #1
        str     w10, [x9]
        b       9f
1:      mov     w0, #0                  /* end of stream */
9:      ldp     x29, x30, [sp], #32
        ret

        .globl  SYM(sock_close)
SYM(sock_close):
        b       SYM(tcp_close)

        BSS
        .p2align 2
sock_drained:   .space 4
