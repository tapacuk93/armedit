#include "asm.inc"
/*
 * x25519.S - X25519 (RFC 7748): the key agreement TLS 1.3 runs on.
 *
 * Field elements are five 51-bit limbs in five 64-bit words, so a product of
 * two limbs fits a 128-bit accumulator built from mul/umulh pairs.  Reduction
 * mod 2^255-19 is folded into the multiply: whatever overflows the top limb
 * comes back multiplied by 19.
 *
 * The scalar multiply is the Montgomery ladder from the RFC, with a constant
 * time conditional swap: the loop does the same work whatever the scalar bits
 * are, and never branches on them.
 */
#define FE_SZ   40

        CODE
        .p2align 2

/* acc (x14:x15) += a * b */
.macro  MAC a, b
        mul     x16, \a, \b
        umulh   x17, \a, \b
        adds    x14, x14, x16
        adc     x15, x15, x17
.endm

/* fe_mul - x0 = h, x1 = f, x2 = g;  h = f * g mod 2^255-19 */
        .globl  SYM(fe_mul)
SYM(fe_mul):
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        stp     x27, x28, [sp, #80]
        sub     sp, sp, #112
        mov     x13, sp
        str     x0, [x13, #96]          /* h, out of the way of the scratch */

        ldp     x19, x20, [x1]          /* f0..f4 */
        ldp     x21, x22, [x1, #16]
        ldr     x23, [x1, #32]
        ldp     x24, x25, [x2]          /* g0..g4 */
        ldp     x26, x27, [x2, #16]
        ldr     x28, [x2, #32]

        mov     x0, #19                 /* 19*f1 .. 19*f4 */
        mul     x9, x20, x0
        mul     x10, x21, x0
        mul     x11, x22, x0
        mul     x12, x23, x0

        mul     x14, x19, x24           /* t0 = f0g0 + 19f4g1 + 19f3g2 */
        umulh   x15, x19, x24           /*         + 19f2g3 + 19f1g4   */
        MAC     x12, x25
        MAC     x11, x26
        MAC     x10, x27
        MAC     x9, x28
        stp     x14, x15, [x13, #0]

        mul     x14, x19, x25           /* t1 */
        umulh   x15, x19, x25
        MAC     x20, x24
        MAC     x12, x26
        MAC     x11, x27
        MAC     x10, x28
        stp     x14, x15, [x13, #16]

        mul     x14, x19, x26           /* t2 */
        umulh   x15, x19, x26
        MAC     x20, x25
        MAC     x21, x24
        MAC     x12, x27
        MAC     x11, x28
        stp     x14, x15, [x13, #32]

        mul     x14, x19, x27           /* t3 */
        umulh   x15, x19, x27
        MAC     x20, x26
        MAC     x21, x25
        MAC     x22, x24
        MAC     x12, x28
        stp     x14, x15, [x13, #48]

        mul     x14, x19, x28           /* t4 */
        umulh   x15, x19, x28
        MAC     x20, x27
        MAC     x21, x26
        MAC     x22, x25
        MAC     x23, x24
        stp     x14, x15, [x13, #64]

/* ---- carry the 128-bit accumulators down into 51-bit limbs -------------- */
        mov     x24, #0xFFFFFFFFFFFF    /* mask51 = 2^51 - 1 */
        movk    x24, #0x7, lsl #48

        ldp     x14, x15, [x13, #0]
        and     x19, x14, x24
        extr    x9, x15, x14, #51       /* a 128-bit shift right by 51 */

        ldp     x14, x15, [x13, #16]
        adds    x14, x14, x9
        adc     x15, x15, xzr
        and     x20, x14, x24
        extr    x9, x15, x14, #51

        ldp     x14, x15, [x13, #32]
        adds    x14, x14, x9
        adc     x15, x15, xzr
        and     x21, x14, x24
        extr    x9, x15, x14, #51

        ldp     x14, x15, [x13, #48]
        adds    x14, x14, x9
        adc     x15, x15, xzr
        and     x22, x14, x24
        extr    x9, x15, x14, #51

        ldp     x14, x15, [x13, #64]
        adds    x14, x14, x9
        adc     x15, x15, xzr
        and     x23, x14, x24
        extr    x9, x15, x14, #51       /* what wrapped past 2^255 */

        mov     x10, #19                /* it comes back times 19, in 128 bits:
                                           the shift can exceed 2^60 */
        mul     x11, x9, x10
        umulh   x12, x9, x10
        adds    x11, x11, x19
        adc     x12, x12, xzr
        and     x19, x11, x24
        extr    x9, x12, x11, #51
        add     x20, x20, x9
        lsr     x9, x20, #51
        and     x20, x20, x24
        add     x21, x21, x9

        ldr     x0, [x13, #96]
        stp     x19, x20, [x0]
        stp     x21, x22, [x0, #16]
        str     x23, [x0, #32]

        add     sp, sp, #112
        ldp     x27, x28, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

/* fe_sq - x0 = h, x1 = f */
        .globl  SYM(fe_sq)
SYM(fe_sq):
        mov     x2, x1
        b       SYM(fe_mul)

/* fe_add - x0 = h, x1 = f, x2 = g */
        .globl  SYM(fe_add)
SYM(fe_add):
        ldp     x9, x10, [x1]
        ldp     x11, x12, [x2]
        add     x9, x9, x11
        add     x10, x10, x12
        stp     x9, x10, [x0]
        ldp     x9, x10, [x1, #16]
        ldp     x11, x12, [x2, #16]
        add     x9, x9, x11
        add     x10, x10, x12
        stp     x9, x10, [x0, #16]
        ldr     x9, [x1, #32]
        ldr     x11, [x2, #32]
        add     x9, x9, x11
        str     x9, [x0, #32]
        ret

/*
 * fe_sub - x0 = h, x1 = f, x2 = g;  h = f - g.
 * 2p is added first so no limb can go negative; the constants are chosen to
 * be a multiple of p that dominates any reduced limb.
 */
        .globl  SYM(fe_sub)
SYM(fe_sub):
        mov     x13, #1                 /* 2^54 - 152 */
        lsl     x13, x13, #54
        sub     x14, x13, #152
        sub     x13, x13, #8            /* 2^54 - 8 */
        ldr     x9, [x1]
        ldr     x11, [x2]
        add     x9, x9, x14
        sub     x9, x9, x11
        str     x9, [x0]
        ldr     x9, [x1, #8]
        ldr     x11, [x2, #8]
        add     x9, x9, x13
        sub     x9, x9, x11
        str     x9, [x0, #8]
        ldr     x9, [x1, #16]
        ldr     x11, [x2, #16]
        add     x9, x9, x13
        sub     x9, x9, x11
        str     x9, [x0, #16]
        ldr     x9, [x1, #24]
        ldr     x11, [x2, #24]
        add     x9, x9, x13
        sub     x9, x9, x11
        str     x9, [x0, #24]
        ldr     x9, [x1, #32]
        ldr     x11, [x2, #32]
        add     x9, x9, x13
        sub     x9, x9, x11
        str     x9, [x0, #32]
        ret

/*
 * fe_mul121665 - x0 = h, x1 = f;  the ladder's only scalar multiply.
 * Scratch registers only: the caller's callee-saved set is left alone.
 */
        .globl  SYM(fe_mul121665)
SYM(fe_mul121665):
        mov     x13, #0xDB41            /* 121665 */
        movk    x13, #0x1, lsl #16
        mov     x17, #0xFFFFFFFFFFFF    /* mask51 */
        movk    x17, #0x7, lsl #48

        ldr     x9, [x1]
        mul     x10, x9, x13
        umulh   x11, x9, x13
        and     x15, x10, x17           /* r0 */
        extr    x12, x11, x10, #51

        ldr     x9, [x1, #8]
        mul     x10, x9, x13
        umulh   x11, x9, x13
        adds    x10, x10, x12
        adc     x11, x11, xzr
        and     x16, x10, x17           /* r1 */
        extr    x12, x11, x10, #51

        ldr     x9, [x1, #16]
        mul     x10, x9, x13
        umulh   x11, x9, x13
        adds    x10, x10, x12
        adc     x11, x11, xzr
        and     x14, x10, x17
        str     x14, [x0, #16]
        extr    x12, x11, x10, #51

        ldr     x9, [x1, #24]
        mul     x10, x9, x13
        umulh   x11, x9, x13
        adds    x10, x10, x12
        adc     x11, x11, xzr
        and     x14, x10, x17
        str     x14, [x0, #24]
        extr    x12, x11, x10, #51

        ldr     x9, [x1, #32]
        mul     x10, x9, x13
        umulh   x11, x9, x13
        adds    x10, x10, x12
        adc     x11, x11, xzr
        and     x14, x10, x17
        str     x14, [x0, #32]
        extr    x12, x11, x10, #51

        mov     x9, #19                 /* the wrap-around */
        mul     x12, x12, x9
        add     x15, x15, x12
        lsr     x12, x15, #51
        and     x15, x15, x17
        add     x16, x16, x12
        stp     x15, x16, [x0]
        ret

/* fe_copy - x0 = h, x1 = f */
        .globl  SYM(fe_copy)
SYM(fe_copy):
        ldp     x9, x10, [x1]
        stp     x9, x10, [x0]
        ldp     x9, x10, [x1, #16]
        stp     x9, x10, [x0, #16]
        ldr     x9, [x1, #32]
        str     x9, [x0, #32]
        ret

/* fe_0 / fe_1 */
        .globl  SYM(fe_0)
SYM(fe_0):
        stp     xzr, xzr, [x0]
        stp     xzr, xzr, [x0, #16]
        str     xzr, [x0, #32]
        ret
        .globl  SYM(fe_1)
SYM(fe_1):
        mov     x9, #1
        str     x9, [x0]
        stp     xzr, xzr, [x0, #8]
        stp     xzr, xzr, [x0, #24]
        ret

/*
 * fe_cswap - x0 = a, x1 = b, w2 = swap (0 or 1).
 * Branch-free: the mask is derived from the bit, never tested.
 */
        .globl  SYM(fe_cswap)
SYM(fe_cswap):
        neg     x2, x2                  /* 0 -> 0, 1 -> all ones */
        mov     w9, #0
1:      ldr     x10, [x0, w9, uxtw]
        ldr     x11, [x1, w9, uxtw]
        eor     x12, x10, x11
        and     x12, x12, x2
        eor     x10, x10, x12
        eor     x11, x11, x12
        str     x10, [x0, w9, uxtw]
        str     x11, [x1, w9, uxtw]
        add     w9, w9, #8
        cmp     w9, #FE_SZ
        b.lo    1b
        ret

/* fe_frombytes - x0 = h, x1 = 32 little-endian bytes (top bit ignored) */
        .globl  SYM(fe_frombytes)
SYM(fe_frombytes):
        mov     x14, #0xFFFFFFFFFFFF
        movk    x14, #0x7, lsl #48
        ldp     x9, x10, [x1]
        ldp     x11, x12, [x1, #16]
        and     x13, x9, x14
        str     x13, [x0]
        extr    x13, x10, x9, #51
        and     x13, x13, x14
        str     x13, [x0, #8]
        extr    x13, x11, x10, #38
        and     x13, x13, x14
        str     x13, [x0, #16]
        extr    x13, x12, x11, #25
        and     x13, x13, x14
        str     x13, [x0, #24]
        lsr     x13, x12, #12
        and     x13, x13, x14
        str     x13, [x0, #32]
        ret

/* fe_tobytes - x0 = 32 bytes out, x1 = f (fully reduced first) */
        .globl  SYM(fe_tobytes)
SYM(fe_tobytes):
        mov     x2, #0xFFFFFFFFFFFF
        movk    x2, #0x7, lsl #48
        ldp     x9, x10, [x1]
        ldp     x11, x12, [x1, #16]
        ldr     x13, [x1, #32]

        .rept   2                       /* two passes settle every carry */
        lsr     x14, x9, #51
        and     x9, x9, x2
        add     x10, x10, x14
        lsr     x14, x10, #51
        and     x10, x10, x2
        add     x11, x11, x14
        lsr     x14, x11, #51
        and     x11, x11, x2
        add     x12, x12, x14
        lsr     x14, x12, #51
        and     x12, x12, x2
        add     x13, x13, x14
        lsr     x14, x13, #51
        and     x13, x13, x2
        mov     x15, #19
        mul     x14, x14, x15
        add     x9, x9, x14
        .endr

        add     x14, x9, #19            /* is it >= p?  add 19 and watch the
                                           carry out of the top limb */
        lsr     x14, x14, #51
        add     x14, x14, x10
        lsr     x14, x14, #51
        add     x14, x14, x11
        lsr     x14, x14, #51
        add     x14, x14, x12
        lsr     x14, x14, #51
        add     x14, x14, x13
        lsr     x14, x14, #51           /* 1 if it was, 0 if not */
        mov     x15, #19
        mul     x14, x14, x15
        add     x9, x9, x14
        lsr     x14, x9, #51
        and     x9, x9, x2
        add     x10, x10, x14
        lsr     x14, x10, #51
        and     x10, x10, x2
        add     x11, x11, x14
        lsr     x14, x11, #51
        and     x11, x11, x2
        add     x12, x12, x14
        lsr     x14, x12, #51
        and     x12, x12, x2
        add     x13, x13, x14
        and     x13, x13, x2           /* drop the 2^255 bit */

        orr     x14, x9, x10, lsl #51   /* limbs back into four words */
        lsr     x15, x10, #13
        orr     x15, x15, x11, lsl #38
        lsr     x16, x11, #26
        orr     x16, x16, x12, lsl #25
        lsr     x17, x12, #39
        orr     x17, x17, x13, lsl #12
        stp     x14, x15, [x0]
        stp     x16, x17, [x0, #16]
        ret

/* fe_sq_n - x0 = h, x1 = f, w2 = how many times to square */
        .globl  SYM(fe_sq_n)
SYM(fe_sq_n):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]
        mov     x19, x0
        mov     x20, x1
        mov     w21, w2
        cbz     w21, 9f
        mov     x0, x19
        mov     x1, x20
        bl      SYM(fe_sq)
        sub     w21, w21, #1
1:      cbz     w21, 9f
        mov     x0, x19
        mov     x1, x19
        bl      SYM(fe_sq)
        sub     w21, w21, #1
        b       1b
9:      ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * fe_invert - x0 = out, x1 = z;  out = z^(p-2), which is 1/z mod p.
 * The addition chain is the standard one: 254 squarings and 11 multiplies.
 */
        .globl  SYM(fe_invert)
SYM(fe_invert):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        sub     sp, sp, #320            /* z2 z9 z11 z5_0 z10_0 z20_0 z50_0
                                           z100_0 t */
        mov     x21, sp
        mov     x19, x0
        mov     x20, x1

#define IZ2     0
#define IZ9     40
#define IZ11    80
#define I5      120
#define I10     160
#define I20     200
#define I50     240
#define I100    280

        add     x0, x21, #IZ2           /* z^2 */
        mov     x1, x20
        bl      SYM(fe_sq)
        add     x0, x21, #IZ9           /* z^8 */
        add     x1, x21, #IZ2
        mov     w2, #2
        bl      SYM(fe_sq_n)
        add     x0, x21, #IZ9           /* z^9 */
        add     x1, x21, #IZ9
        mov     x2, x20
        bl      SYM(fe_mul)
        add     x0, x21, #IZ11          /* z^11 */
        add     x1, x21, #IZ9
        add     x2, x21, #IZ2
        bl      SYM(fe_mul)
        add     x0, x21, #I5            /* z^22 */
        add     x1, x21, #IZ11
        bl      SYM(fe_sq)
        add     x0, x21, #I5            /* 2^5 - 2^0 */
        add     x1, x21, #I5
        add     x2, x21, #IZ9
        bl      SYM(fe_mul)

        add     x0, x21, #I10
        add     x1, x21, #I5
        mov     w2, #5
        bl      SYM(fe_sq_n)
        add     x0, x21, #I10           /* 2^10 - 2^0 */
        add     x1, x21, #I10
        add     x2, x21, #I5
        bl      SYM(fe_mul)

        add     x0, x21, #I20
        add     x1, x21, #I10
        mov     w2, #10
        bl      SYM(fe_sq_n)
        add     x0, x21, #I20           /* 2^20 - 2^0 */
        add     x1, x21, #I20
        add     x2, x21, #I10
        bl      SYM(fe_mul)

        add     x0, x21, #I50
        add     x1, x21, #I20
        mov     w2, #20
        bl      SYM(fe_sq_n)
        add     x0, x21, #I50           /* 2^40 - 2^0 */
        add     x1, x21, #I50
        add     x2, x21, #I20
        bl      SYM(fe_mul)
        add     x0, x21, #I50
        add     x1, x21, #I50
        mov     w2, #10
        bl      SYM(fe_sq_n)
        add     x0, x21, #I50           /* 2^50 - 2^0 */
        add     x1, x21, #I50
        add     x2, x21, #I10
        bl      SYM(fe_mul)

        add     x0, x21, #I100
        add     x1, x21, #I50
        mov     w2, #50
        bl      SYM(fe_sq_n)
        add     x0, x21, #I100          /* 2^100 - 2^0 */
        add     x1, x21, #I100
        add     x2, x21, #I50
        bl      SYM(fe_mul)

        add     x0, x19, #0             /* borrow the output as scratch */
        add     x1, x21, #I100
        mov     w2, #100
        bl      SYM(fe_sq_n)
        mov     x0, x19                 /* 2^200 - 2^0 */
        mov     x1, x19
        add     x2, x21, #I100
        bl      SYM(fe_mul)
        mov     x0, x19
        mov     x1, x19
        mov     w2, #50
        bl      SYM(fe_sq_n)
        mov     x0, x19                 /* 2^250 - 2^0 */
        mov     x1, x19
        add     x2, x21, #I50
        bl      SYM(fe_mul)
        mov     x0, x19
        mov     x1, x19
        mov     w2, #5
        bl      SYM(fe_sq_n)
        mov     x0, x19                 /* 2^255 - 21 */
        mov     x1, x19
        add     x2, x21, #IZ11
        bl      SYM(fe_mul)

        add     sp, sp, #320
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * x25519 - x0 = 32-byte shared secret out, x1 = 32-byte scalar,
 *          x2 = 32-byte u coordinate.
 * RFC 7748's ladder, one bit at a time from 254 down to 0.
 */
#define WX1     0
#define WX2     40
#define WZ2     80
#define WX3     120
#define WZ3     160
#define WA      200
#define WAA     240
#define WB      280
#define WBB     320
#define WE      360
#define WC      400
#define WD      440
#define WDA     480
#define WCB     520
#define WT0     560
#define WSCAL   600     /* the clamped scalar */

        .globl  SYM(x25519)
SYM(x25519):
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        sub     sp, sp, #656
        mov     x21, sp
        mov     x19, x0

        mov     w9, #0                  /* clamp the scalar, RFC 7748 5 */
1:      ldrb    w10, [x1, w9, uxtw]
        add     x11, x21, #WSCAL
        strb    w10, [x11, w9, uxtw]
        add     w9, w9, #1
        cmp     w9, #32
        b.lo    1b
        add     x11, x21, #WSCAL
        ldrb    w10, [x11]
        and     w10, w10, #248
        strb    w10, [x11]
        ldrb    w10, [x11, #31]
        and     w10, w10, #127
        orr     w10, w10, #64
        strb    w10, [x11, #31]

        add     x0, x21, #WX1
        mov     x1, x2
        bl      SYM(fe_frombytes)
        add     x0, x21, #WX2
        bl      SYM(fe_1)
        add     x0, x21, #WZ2
        bl      SYM(fe_0)
        add     x0, x21, #WX3
        add     x1, x21, #WX1
        bl      SYM(fe_copy)
        add     x0, x21, #WZ3
        bl      SYM(fe_1)

        mov     w22, #254               /* bit index */
        mov     w23, #0                 /* whether the pair is swapped */
.Lladder:
        add     x11, x21, #WSCAL        /* k_t */
        lsr     w9, w22, #3
        ldrb    w10, [x11, w9, uxtw]
        and     w9, w22, #7
        lsr     w10, w10, w9
        and     w24, w10, #1

        eor     w9, w23, w24
        add     x0, x21, #WX2
        add     x1, x21, #WX3
        mov     w2, w9
        bl      SYM(fe_cswap)
        eor     w9, w23, w24
        add     x0, x21, #WZ2
        add     x1, x21, #WZ3
        mov     w2, w9
        bl      SYM(fe_cswap)
        mov     w23, w24

        add     x0, x21, #WA            /* A = x2 + z2 */
        add     x1, x21, #WX2
        add     x2, x21, #WZ2
        bl      SYM(fe_add)
        add     x0, x21, #WAA           /* AA = A^2 */
        add     x1, x21, #WA
        bl      SYM(fe_sq)
        add     x0, x21, #WB            /* B = x2 - z2 */
        add     x1, x21, #WX2
        add     x2, x21, #WZ2
        bl      SYM(fe_sub)
        add     x0, x21, #WBB           /* BB = B^2 */
        add     x1, x21, #WB
        bl      SYM(fe_sq)
        add     x0, x21, #WE            /* E = AA - BB */
        add     x1, x21, #WAA
        add     x2, x21, #WBB
        bl      SYM(fe_sub)
        add     x0, x21, #WC            /* C = x3 + z3 */
        add     x1, x21, #WX3
        add     x2, x21, #WZ3
        bl      SYM(fe_add)
        add     x0, x21, #WD            /* D = x3 - z3 */
        add     x1, x21, #WX3
        add     x2, x21, #WZ3
        bl      SYM(fe_sub)
        add     x0, x21, #WDA           /* DA = D * A */
        add     x1, x21, #WD
        add     x2, x21, #WA
        bl      SYM(fe_mul)
        add     x0, x21, #WCB           /* CB = C * B */
        add     x1, x21, #WC
        add     x2, x21, #WB
        bl      SYM(fe_mul)

        add     x0, x21, #WT0           /* x3 = (DA + CB)^2 */
        add     x1, x21, #WDA
        add     x2, x21, #WCB
        bl      SYM(fe_add)
        add     x0, x21, #WX3
        add     x1, x21, #WT0
        bl      SYM(fe_sq)

        add     x0, x21, #WT0           /* z3 = x1 * (DA - CB)^2 */
        add     x1, x21, #WDA
        add     x2, x21, #WCB
        bl      SYM(fe_sub)
        add     x0, x21, #WT0
        add     x1, x21, #WT0
        bl      SYM(fe_sq)
        add     x0, x21, #WZ3
        add     x1, x21, #WT0
        add     x2, x21, #WX1
        bl      SYM(fe_mul)

        add     x0, x21, #WX2           /* x2 = AA * BB */
        add     x1, x21, #WAA
        add     x2, x21, #WBB
        bl      SYM(fe_mul)

        add     x0, x21, #WT0           /* z2 = E * (AA + 121665*E) */
        add     x1, x21, #WE
        bl      SYM(fe_mul121665)
        add     x0, x21, #WT0
        add     x1, x21, #WT0
        add     x2, x21, #WAA
        bl      SYM(fe_add)
        add     x0, x21, #WZ2
        add     x1, x21, #WE
        add     x2, x21, #WT0
        bl      SYM(fe_mul)

        subs    w22, w22, #1
        b.ge    .Lladder

        add     x0, x21, #WX2           /* undo the last swap */
        add     x1, x21, #WX3
        mov     w2, w23
        bl      SYM(fe_cswap)
        add     x0, x21, #WZ2
        add     x1, x21, #WZ3
        mov     w2, w23
        bl      SYM(fe_cswap)

        add     x0, x21, #WT0           /* out = x2 / z2 */
        add     x1, x21, #WZ2
        bl      SYM(fe_invert)
        add     x0, x21, #WT0
        add     x1, x21, #WX2
        add     x2, x21, #WT0
        bl      SYM(fe_mul)
        mov     x0, x19
        add     x1, x21, #WT0
        bl      SYM(fe_tobytes)

        add     sp, sp, #656
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret
