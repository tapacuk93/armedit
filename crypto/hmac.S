#include "asm.inc"
/*
 * hmac.S - HMAC-SHA256, RFC 2104.
 *
 * AWS derives its signing key by chaining four of these, so this is on the
 * critical path for every call the backend makes to EC2.
 */
#define CTX_SZ  112
#define BLK     64

        CODE
        .p2align 2

/*
 * hmac_sha256 - x0 = key, w1 = key length, x2 = data, w3 = data length,
 *               x4 = 32-byte output
 */
        .globl  SYM(hmac_sha256)
SYM(hmac_sha256):
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        str     x27, [sp, #80]
        sub     sp, sp, #(CTX_SZ + BLK + 64)
        mov     x23, sp                 /* ctx           */
        add     x24, sp, #CTX_SZ        /* pad[64]       */
        add     x25, x24, #BLK          /* hashed key    */
        add     x27, x25, #32           /* inner digest - must NOT share the
                                           buffer holding the hashed key */
        mov     x19, x0
        mov     w20, w1
        mov     x21, x2
        mov     w22, w3
        mov     x26, x4

        cmp     w20, #BLK               /* long keys are hashed down first */
        b.ls    1f
        mov     x0, x19
        mov     w1, w20
        mov     x2, x25
        bl      SYM(sha256)
        mov     x19, x25
        mov     w20, #32
1:
        mov     w9, #0                  /* ipad */
        mov     w11, #0x36              /* not a bitmask immediate */
2:      cmp     w9, w20
        b.hs    3f
        ldrb    w10, [x19, w9, uxtw]
        eor     w10, w10, w11
        strb    w10, [x24, w9, uxtw]
        add     w9, w9, #1
        b       2b
3:      cmp     w9, #BLK
        b.hs    4f
        mov     w10, w11
        strb    w10, [x24, w9, uxtw]
        add     w9, w9, #1
        b       3b
4:
        mov     x0, x23                 /* inner = H(ipad || data) */
        bl      SYM(sha256_init)
        mov     x0, x23
        mov     x1, x24
        mov     w2, #BLK
        bl      SYM(sha256_update)
        mov     x0, x23
        mov     x1, x21
        mov     w2, w22
        bl      SYM(sha256_update)
        mov     x0, x23
        mov     x1, x27
        bl      SYM(sha256_final)

        mov     w9, #0                  /* opad */
        mov     w11, #0x5C
5:      cmp     w9, w20
        b.hs    6f
        ldrb    w10, [x19, w9, uxtw]
        eor     w10, w10, w11
        strb    w10, [x24, w9, uxtw]
        add     w9, w9, #1
        b       5b
6:      cmp     w9, #BLK
        b.hs    7f
        mov     w10, w11
        strb    w10, [x24, w9, uxtw]
        add     w9, w9, #1
        b       6b
7:
        mov     x0, x23                 /* out = H(opad || inner) */
        bl      SYM(sha256_init)
        mov     x0, x23
        mov     x1, x24
        mov     w2, #BLK
        bl      SYM(sha256_update)
        mov     x0, x23
        mov     x1, x27
        mov     w2, #32
        bl      SYM(sha256_update)
        mov     x0, x23
        mov     x1, x26
        bl      SYM(sha256_final)

        add     sp, sp, #(CTX_SZ + BLK + 64)
        ldr     x27, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret
