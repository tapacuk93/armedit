#include "asm.inc"
/*
 * Open a site from the command line, and say which route it came by.
 *
 *     browsetest example.com
 *
 * The point of running it here rather than only in the editor is that the two
 * routes are hard to tell apart from inside a document: both produce text on a
 * screen. This prints the text and nothing else, so a route that silently
 * became the other one is visible.
 */
        CODE
        .p2align 2
        .globl  _main
_main:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     w19, w0
        mov     x20, x1
        mov     x0, x2
        bl      SYM(env_init)
        cmp     w19, #2
        b.lt    .Lfail

        ldr     x0, [x20, #8]
        LEA     x1, out
        mov     w2, #(1 << 16)
        bl      SYM(browse_open)
        cmn     w0, #1
        b.eq    .Lnone
        LEA     x9, out
        strb    wzr, [x9, w0, uxtw]
        LEA     x0, out
        bl      say
        LEA     x0, s_nl
        bl      say
        mov     x0, #0
        b       .Lexit
.Lnone: LEA     x0, s_none
        bl      say
.Lfail: mov     x0, #1
.Lexit: mov     x16, #1
        svc     #0x80

say:    stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x0, [sp, #16]
        bl      SYM(str_len)
        mov     x2, x0
        ldr     x1, [sp, #16]
        mov     x0, #1
        mov     x16, #4
        svc     #0x80
        ldp     x29, x30, [sp], #32
        ret

        RODATA
s_nl:   .asciz "\n"
s_none: .asciz "neither route produced a page\n"
        BSS
        .p2align 3
out:    .space (1 << 16)
