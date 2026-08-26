#include "asm.inc"
/*
 * poly1305.S - Poly1305, RFC 8439.
 *
 * The authenticator half of ChaCha20-Poly1305.  Arithmetic is mod 2^130-5,
 * carried in five 26-bit limbs so every partial product fits a 64-bit
 * register with room for the five-term sums - no 128-bit intermediates and no
 * carry-less multiply needed.
 *
 * h and r live in callee-saved registers for the whole message:
 *   h0..h4 = w19..w23,  r0..r4 = w24..w28
 */
        CODE
        .p2align 2

/*
 * poly1305_mac - x0 = message, w1 = length, x2 = 32-byte key, x3 = 16-byte tag
 */
        .globl  SYM(poly1305_mac)
SYM(poly1305_mac):
        stp     x29, x30, [sp, #-128]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        stp     x27, x28, [sp, #80]
        stp     x0, x1, [sp, #96]       /* message, length */
        stp     x2, x3, [sp, #112]      /* key, tag out    */

        mov     w14, #0xFFFF            /* 0x3ffffff, the limb mask */
        movk    w14, #0x3FF, lsl #16

        ldr     w9, [x2, #0]            /* clamp r */
        ldr     w10, [x2, #4]
        ldr     w11, [x2, #8]
        ldr     w12, [x2, #12]
        and     w24, w9, w14

        lsr     w15, w9, #26
        orr     w15, w15, w10, lsl #6
        mov     w16, #0xFF03
        movk    w16, #0x3FF, lsl #16
        and     w25, w15, w16

        lsr     w15, w10, #20
        orr     w15, w15, w11, lsl #12
        mov     w16, #0xC0FF
        movk    w16, #0x3FF, lsl #16
        and     w26, w15, w16

        lsr     w15, w11, #14
        orr     w15, w15, w12, lsl #18
        mov     w16, #0x3FFF
        movk    w16, #0x3F0, lsl #16
        and     w27, w15, w16

        lsr     w15, w12, #8
        mov     w16, #0xFFFF
        movk    w16, #0xF, lsl #16
        and     w28, w15, w16

        mov     w19, #0                 /* h = 0 */
        mov     w20, #0
        mov     w21, #0
        mov     w22, #0
        mov     w23, #0

        ldp     x0, x1, [sp, #96]
.Lblock:
        cmp     w1, #0
        b.le    .Lfinal

        mov     w2, #16                 /* this block, and its high bit */
        cmp     w1, w2
        b.hs    1f
        mov     w2, w1                  /* short final block: zero-pad it */
        sub     sp, sp, #16
        mov     x3, sp
        stp     xzr, xzr, [x3]
        mov     w4, #0
2:      cmp     w4, w2
        b.hs    3f
        ldrb    w5, [x0, w4, uxtw]
        strb    w5, [x3, w4, uxtw]
        add     w4, w4, #1
        b       2b
3:      mov     w5, #1                  /* the 1 byte goes right after */
        strb    w5, [x3, w2, uxtw]
        mov     x6, x3
        mov     w7, #0                  /* hibit already in the padding */
        b       4f
1:      mov     x6, x0
        mov     w7, #1                  /* full block: hibit = 1 << 24 */
4:
        ldr     w9, [x6, #0]            /* fold the block into h */
        ldr     w10, [x6, #4]
        ldr     w11, [x6, #8]
        ldr     w12, [x6, #12]

        and     w15, w9, w14
        add     w19, w19, w15
        lsr     w15, w9, #26
        orr     w15, w15, w10, lsl #6
        and     w15, w15, w14
        add     w20, w20, w15
        lsr     w15, w10, #20
        orr     w15, w15, w11, lsl #12
        and     w15, w15, w14
        add     w21, w21, w15
        lsr     w15, w11, #14
        orr     w15, w15, w12, lsl #18
        and     w15, w15, w14
        add     w22, w22, w15
        lsr     w15, w12, #8
        cbz     w7, 5f
        mov     w16, #1                 /* 2^128 */
        lsl     w16, w16, #24
        orr     w15, w15, w16
5:      add     w23, w23, w15

        cbz     w7, 6f                  /* restore sp after a padded block */
        b       7f
6:      add     sp, sp, #16
7:
        bl      poly_mul                /* h = h * r mod 2^130-5 */

        ldp     x0, x1, [sp, #96]       /* advance */
        cmp     w1, #16
        b.lo    .Lfinal_after
        add     x0, x0, #16
        sub     w1, w1, #16
        stp     x0, x1, [sp, #96]
        b       .Lblock
.Lfinal_after:
        mov     w1, #0
        stp     x0, x1, [sp, #96]

.Lfinal:
        bl      poly_carry              /* full carry, then the final reduce */

        mov     w9, w19                 /* h + 5, and take it if it did not
                                           borrow: that is h mod p */
        add     w9, w9, #5
        lsr     w10, w9, #26
        and     w9, w9, w14
        add     w10, w10, w20
        lsr     w11, w10, #26
        and     w10, w10, w14
        add     w11, w11, w21
        lsr     w12, w11, #26
        and     w11, w11, w14
        add     w12, w12, w22
        lsr     w13, w12, #26
        and     w12, w12, w14
        add     w13, w13, w23
        mov     w16, #1                 /* g4 -= 2^26, not 1: the borrow out
                                           of the top limb is what decides
                                           whether h was already below p */
        lsl     w16, w16, #26
        sub     w13, w13, w16
        lsr     w13, w13, #31           /* 0 if h >= p, 1 if h < p */
        sub     w15, w13, #1            /* mask: all ones if h >= p */
        and     w9, w9, w15
        and     w10, w10, w15
        and     w11, w11, w15
        and     w12, w12, w15
        mvn     w16, w15
        and     w19, w19, w16
        and     w20, w20, w16
        and     w21, w21, w16
        and     w22, w22, w16
        orr     w19, w19, w9
        orr     w20, w20, w10
        orr     w21, w21, w11
        orr     w22, w22, w12

        orr     w9, w19, w20, lsl #26   /* limbs back to four 32-bit words */
        lsr     w10, w20, #6
        orr     w10, w10, w21, lsl #20
        lsr     w11, w21, #12
        orr     w11, w11, w22, lsl #14
        lsr     w12, w22, #18
        orr     w12, w12, w23, lsl #8

        ldp     x2, x3, [sp, #112]      /* tag = h + s, 128-bit little-endian */
        ldr     w4, [x2, #16]
        ldr     w5, [x2, #20]
        ldr     w6, [x2, #24]
        ldr     w7, [x2, #28]
        adds    w9, w9, w4
        adcs    w10, w10, w5
        adcs    w11, w11, w6
        adc     w12, w12, w7
        str     w9, [x3, #0]
        str     w10, [x3, #4]
        str     w11, [x3, #8]
        str     w12, [x3, #12]

        ldp     x27, x28, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #128
        ret

/*
 * poly_mul - h = h * r mod 2^130-5, limbs in w19..w23 and w24..w28.
 * The s_i are r_i * 5, which is where the reduction happens: a limb that
 * overflows 2^130 comes back multiplied by 5.
 */
poly_mul:
        mov     w9, #5
        mul     w4, w25, w9             /* s1 */
        mul     w5, w26, w9             /* s2 */
        mul     w6, w27, w9             /* s3 */
        mul     w7, w28, w9             /* s4 */

        umull   x10, w19, w24           /* d0 */
        umaddl  x10, w20, w7, x10
        umaddl  x10, w21, w6, x10
        umaddl  x10, w22, w5, x10
        umaddl  x10, w23, w4, x10

        umull   x11, w19, w25           /* d1 */
        umaddl  x11, w20, w24, x11
        umaddl  x11, w21, w7, x11
        umaddl  x11, w22, w6, x11
        umaddl  x11, w23, w5, x11

        umull   x12, w19, w26           /* d2 */
        umaddl  x12, w20, w25, x12
        umaddl  x12, w21, w24, x12
        umaddl  x12, w22, w7, x12
        umaddl  x12, w23, w6, x12

        umull   x13, w19, w27           /* d3 */
        umaddl  x13, w20, w26, x13
        umaddl  x13, w21, w25, x13
        umaddl  x13, w22, w24, x13
        umaddl  x13, w23, w7, x13

        umull   x15, w19, w28           /* d4 */
        umaddl  x15, w20, w27, x15
        umaddl  x15, w21, w26, x15
        umaddl  x15, w22, w25, x15
        umaddl  x15, w23, w24, x15

        and     w19, w10, w14           /* carry the products down */
        lsr     x9, x10, #26
        add     x11, x11, x9
        and     w20, w11, w14
        lsr     x9, x11, #26
        add     x12, x12, x9
        and     w21, w12, w14
        lsr     x9, x12, #26
        add     x13, x13, x9
        and     w22, w13, w14
        lsr     x9, x13, #26
        add     x15, x15, x9
        and     w23, w15, w14
        lsr     x9, x15, #26
        mov     x16, #5                 /* the wrap-around, times five */
        mul     x9, x9, x16
        add     x9, x9, x19
        and     w19, w9, w14
        lsr     x9, x9, #26
        add     w20, w20, w9
        ret

/* poly_carry - one full carry chain over h, no multiply involved */
poly_carry:
        lsr     w9, w19, #26
        and     w19, w19, w14
        add     w20, w20, w9
        lsr     w9, w20, #26
        and     w20, w20, w14
        add     w21, w21, w9
        lsr     w9, w21, #26
        and     w21, w21, w14
        add     w22, w22, w9
        lsr     w9, w22, #26
        and     w22, w22, w14
        add     w23, w23, w9
        lsr     w9, w23, #26
        and     w23, w23, w14
        mov     w10, #5
        mul     w9, w9, w10
        add     w19, w19, w9
        lsr     w9, w19, #26
        and     w19, w19, w14
        add     w20, w20, w9
        ret
