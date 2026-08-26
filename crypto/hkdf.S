#include "asm.inc"
/*
 * hkdf.S - HKDF-SHA256 (RFC 5869) and TLS 1.3's HKDF-Expand-Label.
 *
 * The whole TLS 1.3 key schedule is these two functions applied in a fixed
 * order, so everything from handshake traffic keys to the application secrets
 * comes out of here.
 */
        CODE
        .p2align 2

/*
 * hkdf_extract - x0 = salt, w1 = salt length, x2 = ikm, w3 = ikm length,
 *                x4 = 32-byte PRK out.  An empty salt means 32 zero bytes.
 */
        .globl  SYM(hkdf_extract)
SYM(hkdf_extract):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        cbnz    w1, 1f
        LEA     x0, hk_zeros
        mov     w1, #32
1:      mov     x19, x2
        mov     w20, w3
        mov     x2, x19
        mov     w3, w20
        bl      SYM(hmac_sha256)
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * hkdf_expand - x0 = 32-byte PRK, x1 = info, w2 = info length,
 *               x3 = output, w4 = output length (up to 255*32)
 */
        .globl  SYM(hkdf_expand)
SYM(hkdf_expand):
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        mov     x19, x0                 /* prk    */
        mov     x20, x1                 /* info   */
        mov     w21, w2                 /* infolen*/
        mov     x22, x3                 /* out    */
        mov     w23, w4                 /* outlen */
        mov     w24, #0                 /* written */
        mov     w25, #1                 /* block counter */

1:      cmp     w24, w23
        b.hs    9f
        LEA     x26, hk_tin             /* T(n-1) || info || n */
        mov     w9, #0
        cmp     w25, #1
        b.eq    3f
        LEA     x10, hk_t
2:      ldrb    w11, [x10, w9, uxtw]    /* the previous block */
        strb    w11, [x26, w9, uxtw]
        add     w9, w9, #1
        cmp     w9, #32
        b.lo    2b
3:      mov     w10, #0
4:      cmp     w10, w21
        b.hs    5f
        ldrb    w11, [x20, w10, uxtw]
        strb    w11, [x26, w9, uxtw]
        add     w9, w9, #1
        add     w10, w10, #1
        b       4b
5:      strb    w25, [x26, w9, uxtw]
        add     w9, w9, #1

        mov     x0, x19                 /* T(n) = HMAC(prk, that) */
        mov     w1, #32
        mov     x2, x26
        mov     w3, w9
        LEA     x4, hk_t
        bl      SYM(hmac_sha256)

        mov     w9, #0
6:      cmp     w24, w23
        b.hs    7f
        cmp     w9, #32
        b.hs    7f
        LEA     x10, hk_t
        ldrb    w11, [x10, w9, uxtw]
        strb    w11, [x22, w24, uxtw]
        add     w9, w9, #1
        add     w24, w24, #1
        b       6b
7:      add     w25, w25, #1
        b       1b

9:      ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

/*
 * hkdf_expand_label - TLS 1.3's flavour of expand, RFC 8446 section 7.1.
 *   x0 = 32-byte secret, x1 = label (without the "tls13 " prefix),
 *   w2 = label length, x3 = context, w4 = context length,
 *   x5 = output, w6 = output length
 *
 * HkdfLabel is uint16 length, then the label and context each with a one-byte
 * length in front.
 */
        .globl  SYM(hkdf_expand_label)
SYM(hkdf_expand_label):
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        mov     x19, x0
        mov     x20, x1
        mov     w21, w2
        mov     x22, x3
        mov     w23, w4
        mov     x24, x5
        mov     w25, w6

        LEA     x26, hk_label
        lsr     w9, w25, #8             /* uint16 length, big-endian */
        strb    w9, [x26, #0]
        strb    w25, [x26, #1]
        add     w9, w21, #6             /* "tls13 " + label */
        strb    w9, [x26, #2]
        mov     w10, #3
        LEA     x11, s_tls13
        mov     w12, #0
1:      ldrb    w13, [x11, w12, uxtw]
        cbz     w13, 2f
        strb    w13, [x26, w10, uxtw]
        add     w10, w10, #1
        add     w12, w12, #1
        b       1b
2:      mov     w12, #0
3:      cmp     w12, w21
        b.hs    4f
        ldrb    w13, [x20, w12, uxtw]
        strb    w13, [x26, w10, uxtw]
        add     w10, w10, #1
        add     w12, w12, #1
        b       3b
4:      strb    w23, [x26, w10, uxtw]   /* context, length-prefixed */
        add     w10, w10, #1
        mov     w12, #0
5:      cmp     w12, w23
        b.hs    6f
        ldrb    w13, [x22, w12, uxtw]
        strb    w13, [x26, w10, uxtw]
        add     w10, w10, #1
        add     w12, w12, #1
        b       5b
6:
        mov     x0, x19
        mov     x1, x26
        mov     w2, w10
        mov     x3, x24
        mov     w4, w25
        bl      SYM(hkdf_expand)

        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

        CSTR
s_tls13:        .asciz "tls13 "

        BSS
        .p2align 4
hk_zeros:       .space 32
hk_t:           .space 32
hk_tin:         .space 512
hk_label:       .space 512
