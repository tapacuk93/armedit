#include "asm.inc"
/*
 * tty.S - hosted mode, no window: rasterize the banner as text on stdout.
 *
 * Same font, same glyph lookup as the kernel; the only difference is that a
 * "pixel" here is the character '#'.  Output goes out through one raw write
 * syscall - no libc, no stdio.
 */
#define SYS_EXIT        1
#define SYS_WRITE       4
#define STDOUT          1
#define OUTBUF_SZ       16384

        CODE
        .p2align 2
        .globl  _main
_main:
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        stp     x27, x28, [sp, #80]

        cmp     w0, #2                  /* argv[1] overrides the banner */
        b.lt    1f
        ldr     x19, [x1, #8]
        b       2f
1:      LEA     x19, default_msg
2:      LEA     x21, outbuf
        mov     x20, x21                /* write cursor */
        mov     w22, #0                 /* scanline */

.Lrow:
        mov     x23, x19
.Lchar:
        sub     x0, x20, x21            /* keep the buffer honest */
        mov     x1, #(OUTBUF_SZ - 16)
        cmp     x0, x1
        b.hs    .Lrow_end
        ldrb    w0, [x23], #1
        cbz     w0, .Lrow_end

        bl      SYM(font_index)
        mov     w1, #GLYPH_H
        mul     w1, w0, w1
        LEA     x2, SYM(font_glyphs)
        add     x24, x2, w1, uxtw
        ldrb    w25, [x24, w22, uxtw]   /* this scanline's bits */

        mov     w26, #0
.Lcol:
        mov     w1, #(GLYPH_W - 1)
        sub     w1, w1, w26
        lsr     w2, w25, w1
        tst     w2, #1
        mov     w3, #' '
        mov     w4, #'#'
        csel    w3, w4, w3, ne
        strb    w3, [x20], #1
        add     w26, w26, #1
        cmp     w26, #GLYPH_W
        b.lt    .Lcol
        mov     w3, #' '                /* inter-glyph gap */
        strb    w3, [x20], #1
        b       .Lchar

.Lrow_end:
        mov     w3, #'\n'
        strb    w3, [x20], #1
        add     w22, w22, #1
        cmp     w22, #GLYPH_H
        b.lt    .Lrow

        sub     x2, x20, x21            /* write(1, outbuf, len) */
        mov     x1, x21
        mov     x0, #STDOUT
        mov     x16, #SYS_WRITE
        svc     #0x80

        mov     w0, #0
        ldp     x27, x28, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

        CSTR
default_msg:    .asciz "ASMEDIT"

        BSS
        .p2align 4
outbuf:         .space OUTBUF_SZ
