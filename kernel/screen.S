#include "asm.inc"
/*
 * screen.S - finding a display that somebody else has already started.
 *
 * There are two ways a bootloader hands over a running framebuffer, and this
 * kernel now meets both.
 *
 * m1n1 passes its own boot_args when it starts a raw payload, and that carries
 * the framebuffer directly - see bootargs.S. But m1n1 also boots Linux-style
 * images, and armedit is one of those now: it has the arm64 image header, so
 * the loader hands it a flattened device tree instead. In that tree is a
 * `simple-framebuffer` node, which is the same information in the form the
 * rest of the world uses.
 *
 * So the second way is the one more likely to run on a real Mac, and it is
 * also the one that works on the hundred other arm64 boards whose loaders
 * produce the same node. Supporting it is not a concession to portability - it
 * is the shorter path to the actual target.
 *
 * <h2>What "already started" buys</h2>
 *
 * Everything. Bringing up an Apple display means DisplayPort, a controller
 * with no public documentation, and an IOMMU in front of it. A framebuffer
 * somebody else initialised means none of that: an address, a stride, a
 * format, and the picture appears.
 */

        CODE
        .p2align 2

/*
 * screen_find - x0..x4 = out base, width, height, stride, depth. May be null.
 *   out w0 = 0 if there is a screen, -1 if there is not.
 *
 * Boot arguments first, because a machine that passed them passed them for
 * this, and its numbers are the display controller's own rather than a
 * description of them.
 */
        .globl  SYM(screen_find)
SYM(screen_find):
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        mov     x19, x0
        mov     x20, x1
        mov     x21, x2
        mov     x22, x3
        mov     x23, x4

        bl      SYM(bootargs_have)
        cbz     w0, .Lsf_dtb
        mov     x0, x19
        mov     x1, x20
        mov     x2, x21
        mov     x3, x22
        mov     x4, x23
        bl      SYM(bootargs_fb)
        b       .Lsf_out

.Lsf_dtb:
        LEA     x0, s_c_simplefb
        mov     w1, #0
        bl      SYM(dtb_reg)
        cbz     x0, .Lsf_none
        cbz     x19, 1f
        str     x0, [x19]
1:
        LEA     x0, s_c_simplefb
        LEA     x1, s_p_width
        bl      screen_cell
        cbz     x20, 2f
        str     x0, [x20]
2:      mov     x24, x0                 /* kept, in case the stride is absent */

        LEA     x0, s_c_simplefb
        LEA     x1, s_p_height
        bl      screen_cell
        cbz     x21, 3f
        str     x0, [x21]
3:
        LEA     x0, s_c_simplefb
        LEA     x1, s_p_stride
        bl      screen_cell
        cbnz    x0, 4f
/*
 * No stride means no padding between rows, which is the ordinary case and the
 * one the property exists to contradict. Four bytes a pixel, because every
 * format this understands is four bytes a pixel.
 */
        lsl     x0, x24, #2
4:      cbz     x22, 5f
        str     x0, [x22]
5:
        cbz     x23, 6f
        bl      screen_depth
        str     x0, [x23]
6:      mov     w0, #0
        b       .Lsf_out

.Lsf_none:
        mov     w0, #-1
.Lsf_out:
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

/*
 * screen_cell - x0 = compatible, x1 = property. out x0 = its first cell, or 0.
 *
 * A device tree cell is a big-endian 32-bit word, and width, height and stride
 * are one cell each. Read byte-wise, for the reason every read in dtb.S is:
 * the MMU is off, so all memory is Device type.
 */
screen_cell:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     x19, x1
        mov     w1, #0
        mov     x2, x19
        bl      SYM(dtb_prop)
        cbz     x0, 9f
        cmp     w1, #4
        b.lo    9f
        ldrb    w9, [x0]
        ldrb    w10, [x0, #1]
        ldrb    w11, [x0, #2]
        ldrb    w12, [x0, #3]
        lsl     w9, w9, #24
        orr     w9, w9, w10, lsl #16
        orr     w9, w9, w11, lsl #8
        orr     w9, w9, w12
        mov     x0, x9
        b       8f
9:      mov     x0, #0
8:      ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/*
 * screen_depth - out x0 = bits per pixel, from the format string.
 *
 * The node names its format rather than counting bits: "x8r8g8b8" is the
 * common one and "x2r10g10b10" is what an Apple panel usually reports. Both
 * are four bytes a pixel and they are not interchangeable - ten-bit channels
 * written as eight-bit ones produce a picture that is dim and wrong rather
 * than absent, which is the kind of wrong that gets shipped.
 *
 * Anything unrecognised is called 32, because that is the assumption that
 * costs the least when it is wrong.
 */
screen_depth:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        LEA     x0, s_c_simplefb
        mov     w1, #0
        LEA     x2, s_p_format
        bl      SYM(dtb_prop)
        cbz     x0, 9f
        mov     x19, x0
        LEA     x1, s_fmt_r10
        bl      screen_streq
        cbz     w0, 1f
        mov     x0, #30
        b       8f
1:      mov     x0, x19
        LEA     x1, s_fmt_a2r10
        bl      screen_streq
        cbz     w0, 9f
        mov     x0, #30
        b       8f
9:      mov     x0, #32
8:      ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/* screen_streq - x0, x1 = NUL-terminated strings, out w0 = 1 if equal. */
screen_streq:
        mov     x2, x0
        mov     x3, x1
1:      ldrb    w9, [x2]
        ldrb    w10, [x3]
        cmp     w9, w10
        b.ne    9f
        cbz     w9, 8f
        add     x2, x2, #1
        add     x3, x3, #1
        b       1b
8:      mov     w0, #1
        ret
9:      mov     w0, #0
        ret

        RODATA
s_c_simplefb: .asciz "simple-framebuffer"
s_p_width:    .asciz "width"
s_p_height:   .asciz "height"
s_p_stride:   .asciz "stride"
s_p_format:   .asciz "format"
s_fmt_r10:    .asciz "x2r10g10b10"
s_fmt_a2r10:  .asciz "a2r10g10b10"
