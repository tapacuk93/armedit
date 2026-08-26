#include "asm.inc"
/*
 * render.S - rasterize the bitmap font into a 32-bit-per-pixel buffer.
 *
 * This is the only glyph-to-pixel code in the project.  The macOS window mode
 * points it at a CoreGraphics-backed buffer; the kernel points it at the raw
 * ramfb framebuffer.  Neither one knows the difference, and no drawing library
 * is involved in either case.
 *
 * Pixels are 0xAARRGGBB as seen by the display, which little-endian byte order
 * makes R,G,B,A in memory - what both XRGB8888 ramfb and CGBitmapContext with
 * kCGImageAlphaPremultipliedLast expect.
 */
        CODE
        .p2align 2

/*
 * fb_fill - fill an axis-aligned rectangle.
 *   x0 = buffer, w1 = stride in pixels, w2 = x, w3 = y,
 *   w4 = width, w5 = height, w6 = colour
 */
        .globl  SYM(fb_fill)
SYM(fb_fill):
        cbz     w4, 9f
        cbz     w5, 9f
        mov     w7, #0                  /* row */
1:      add     w9, w3, w7
        mul     w9, w9, w1
        add     w9, w9, w2              /* index of (x, y+row) */
        mov     w10, #0                 /* column */
2:      add     w11, w9, w10
        str     w6, [x0, w11, uxtw #2]
        add     w10, w10, #1
        cmp     w10, w4
        b.lt    2b
        add     w7, w7, #1
        cmp     w7, w5
        b.lt    1b
9:      ret

/*
 * font_draw_text - draw a NUL-terminated string, glyph by glyph.
 *   x0 = buffer, w1 = stride in pixels, w2 = x, w3 = y,
 *   w4 = scale (one font pixel becomes scale x scale screen pixels),
 *   w5 = ink colour, x6 = string
 *   out: w0 = advance width consumed, in pixels
 * Background pixels are left untouched, so callers control their own backdrop.
 */
        .globl  SYM(font_draw_text)
SYM(font_draw_text):
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        stp     x27, x28, [sp, #80]
        mov     x19, x0                 /* buffer      */
        mov     w20, w1                 /* stride      */
        mov     w21, w2                 /* origin x    */
        mov     w22, w3                 /* origin y    */
        mov     w23, w4                 /* scale       */
        mov     w24, w5                 /* ink         */
        mov     x25, x6                 /* string      */
        mov     w26, w21                /* pen x       */

.Lchar:
        ldrb    w0, [x25], #1
        cbz     w0, .Ldone
        bl      SYM(font_index)
        mov     w1, #GLYPH_H
        mul     w1, w0, w1
        LEA     x2, SYM(font_glyphs)
        add     x27, x2, w1, uxtw       /* this glyph's scanlines */

        mov     w28, #0                 /* scanline */
.Lrow:
        ldrb    w9, [x27, w28, uxtw]    /* its bits */
        mov     w10, #0                 /* column   */
.Lcol:
        mov     w11, #(GLYPH_W - 1)
        sub     w11, w11, w10           /* bit 4 is the leftmost column */
        lsr     w12, w9, w11
        tbz     w12, #0, .Lnext_col

        mul     w13, w10, w23           /* screen x of this font pixel */
        add     w13, w13, w26
        mul     w14, w28, w23           /* screen y */
        add     w14, w14, w22
        mov     w15, #0                 /* dy */
.Lblk_y:
        add     w16, w14, w15
        mul     w16, w16, w20
        add     w16, w16, w13
        mov     w17, #0                 /* dx */
.Lblk_x:
        add     w1, w16, w17
        str     w24, [x19, w1, uxtw #2]
        add     w17, w17, #1
        cmp     w17, w23
        b.lt    .Lblk_x
        add     w15, w15, #1
        cmp     w15, w23
        b.lt    .Lblk_y

.Lnext_col:
        add     w10, w10, #1
        cmp     w10, #GLYPH_W
        b.lt    .Lcol
        add     w28, w28, #1
        cmp     w28, #GLYPH_H
        b.lt    .Lrow

        mov     w0, #GLYPH_ADV
        mul     w0, w0, w23
        add     w26, w26, w0            /* advance the pen */
        b       .Lchar

.Ldone:
        sub     w0, w26, w21
        ldp     x27, x28, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret
