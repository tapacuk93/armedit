#include "asm.inc"
/*
 * image.S - putting a picture on the screen at a size that is not its own.
 *
 * A photograph is a few thousand pixels across and a screen here is a few
 * hundred, so something has to decide what happens to the twenty-odd source
 * pixels that fall under each destination one. Taking one of them and
 * discarding the rest - nearest neighbour - is what most simple blitters do,
 * and it is why downscaled images look like they have been chewed: a thin
 * line either survives whole or vanishes, depending on where the sampling
 * grid happened to land.
 *
 * This averages the whole box instead. Each destination pixel covers a
 * rectangle of source pixels, and its colour is their mean, so a thin line
 * becomes a faint one rather than disappearing. Upscaling falls out of the
 * same code: when the box is a single pixel the average is that pixel, which
 * is nearest neighbour, and blocky is what this font wants anyway.
 *
 * Pixels are 0xAARRGGBB throughout, the format every surface in this project
 * already uses, so the channels are pulled apart and averaged separately -
 * averaging the packed words would bleed red into green.
 */
#define BL_DST          0
#define BL_STRIDE       8
#define BL_DX           12
#define BL_DY           16
#define BL_DW           20
#define BL_DH           24
#define BL_SRC          32
#define BL_SW           40
#define BL_SH           44

        CODE
        .p2align 2

/*
 * image_blit - x0 = a blit descriptor (see the offsets above).
 *
 * Draws the whole source image into the dw x dh rectangle at (dx, dy),
 * scaling either way. Nothing is clipped here: the caller is expected to have
 * chosen a rectangle that fits, because an applet already knows its bounds.
 */
        .globl  SYM(image_blit)
SYM(image_blit):
        stp     x29, x30, [sp, #-160]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        stp     x27, x28, [sp, #80]

        ldr     x19, [x0, #BL_DST]
        ldr     w20, [x0, #BL_STRIDE]
        ldr     w21, [x0, #BL_DX]
        ldr     w22, [x0, #BL_DY]
        ldr     w23, [x0, #BL_DW]
        ldr     w24, [x0, #BL_DH]
        ldr     x25, [x0, #BL_SRC]
        ldr     w26, [x0, #BL_SW]
        ldr     w27, [x0, #BL_SH]

        cbz     w23, .Lbl_out
        cbz     w24, .Lbl_out
        cbz     w26, .Lbl_out
        cbz     w27, .Lbl_out

        str     wzr, [sp, #96]          /* destination row */
.Lbl_row:
        ldr     w9, [sp, #96]
        cmp     w9, w24
        b.hs    .Lbl_out

        mul     w10, w9, w27            /* sy0 = y * sh / dh */
        udiv    w10, w10, w24
        add     w11, w9, #1
        mul     w11, w11, w27           /* sy1 = (y+1) * sh / dh */
        udiv    w11, w11, w24
        cmp     w11, w10                /* an empty box means we are scaling */
        b.hi    1f                      /* up: take the single pixel */
        add     w11, w10, #1
1:      cmp     w11, w27
        b.ls    2f
        mov     w11, w27
2:      str     w10, [sp, #100]         /* sy0 */
        str     w11, [sp, #104]         /* sy1 */

        str     wzr, [sp, #108]         /* destination column */
.Lbl_col:
        ldr     w9, [sp, #108]
        cmp     w9, w23
        b.hs    .Lbl_row_done

        mul     w10, w9, w26            /* sx0 = x * sw / dw */
        udiv    w10, w10, w23
        add     w11, w9, #1
        mul     w11, w11, w26
        udiv    w11, w11, w23           /* sx1 */
        cmp     w11, w10
        b.hi    3f
        add     w11, w10, #1
3:      cmp     w11, w26
        b.ls    4f
        mov     w11, w26
4:

/* ---- average the box ---------------------------------------------------- */
        mov     w12, #0                 /* red   */
        mov     w13, #0                 /* green */
        mov     w14, #0                 /* blue  */
        mov     w15, #0                 /* how many went in */
        ldr     w16, [sp, #100]         /* sy */
.Lbl_by:
        ldr     w17, [sp, #104]
        cmp     w16, w17
        b.hs    .Lbl_box_done
        mul     w17, w16, w26           /* row offset in the source */
        mov     w28, w10                /* sx */
.Lbl_bx:
        cmp     w28, w11
        b.hs    .Lbl_bx_done
        add     w0, w17, w28
        ldr     w1, [x25, w0, uxtw #2]
        ubfx    w2, w1, #16, #8         /* 0xAARRGGBB, split before summing:  */
        add     w12, w12, w2            /* averaging the packed word would    */
        ubfx    w2, w1, #8, #8          /* bleed red into green               */
        add     w13, w13, w2
        and     w2, w1, #0xFF
        add     w14, w14, w2
        add     w15, w15, #1
        add     w28, w28, #1
        b       .Lbl_bx
.Lbl_bx_done:
        add     w16, w16, #1
        b       .Lbl_by

.Lbl_box_done:
        cbz     w15, .Lbl_col_step
        udiv    w12, w12, w15
        udiv    w13, w13, w15
        udiv    w14, w14, w15
        mov     w0, #0xFF
        lsl     w0, w0, #24             /* opaque: these surfaces ignore alpha
                                           but a zero there reads as clear */
        orr     w0, w0, w12, lsl #16
        orr     w0, w0, w13, lsl #8
        orr     w0, w0, w14

        ldr     w1, [sp, #96]           /* where it lands */
        add     w1, w1, w22
        mul     w1, w1, w20
        ldr     w2, [sp, #108]
        add     w1, w1, w2
        add     w1, w1, w21
        str     w0, [x19, w1, uxtw #2]

.Lbl_col_step:
        ldr     w9, [sp, #108]
        add     w9, w9, #1
        str     w9, [sp, #108]
        b       .Lbl_col

.Lbl_row_done:
        ldr     w9, [sp, #96]
        add     w9, w9, #1
        str     w9, [sp, #96]
        b       .Lbl_row

.Lbl_out:
        ldp     x27, x28, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #160
        ret

/*
 * image_fit - work out the largest rectangle with the image's own proportions
 * that fits inside a box, and centre it.
 *   w0 = source width, w1 = source height, w2 = box width, w3 = box height
 *   x4 = out x, x5 = out y, x6 = out width, x7 = out height (all u32*)
 *
 * A picture stretched to fill a key is a picture nobody recognises, so the
 * aspect ratio is kept and the leftover space is split evenly.
 */
        .globl  SYM(image_fit)
SYM(image_fit):
        cbz     w0, 9f
        cbz     w1, 9f
        mul     w9, w2, w1              /* compare sw*bh against bw*sh to see  */
        mul     w10, w0, w3             /* which axis runs out first           */
        cmp     w9, w10
        b.ls    1f
        mov     w11, w3                 /* height-limited */
        mul     w12, w3, w0
        udiv    w12, w12, w1
        b       2f
1:      mov     w12, w2                 /* width-limited */
        mul     w11, w2, w1
        udiv    w11, w11, w0
2:      sub     w13, w2, w12            /* centre what is left over */
        lsr     w13, w13, #1
        sub     w14, w3, w11
        lsr     w14, w14, #1
        str     w13, [x4]
        str     w14, [x5]
        str     w12, [x6]
        str     w11, [x7]
        ret
9:      str     wzr, [x4]
        str     wzr, [x5]
        str     wzr, [x6]
        str     wzr, [x7]
        ret
