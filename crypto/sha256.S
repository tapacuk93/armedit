#include "asm.inc"
/*
 * sha256.S - SHA-256, FIPS 180-4, in software.
 *
 * The backend needs this twice over: AWS SigV4 hashes the request and derives
 * its signing key through HMAC-SHA256, and asmedit keys are hashed rather than
 * stored.  Written out longhand rather than using the ARMv8 SHA extensions, so
 * the same object code runs on the bare-metal target too.
 *
 * ctx layout (112 bytes):
 *    0..31   state h0..h7
 *   32..39   message length in bytes so far
 *   40..103  the partial block
 *  104..107  how many bytes of it are filled
 */
#define CTX_STATE       0
#define CTX_LEN         32
#define CTX_BUF         40
#define CTX_FILL        104
#define CTX_SZ          112

        CODE
        .p2align 2

/*
 * sha256_block - fold one 64-byte block into the state.
 *   x0 = ctx, x1 = block
 */
        .globl  SYM(sha256_block)
SYM(sha256_block):
        stp     x29, x30, [sp, #-160]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        stp     x27, x28, [sp, #80]
        sub     sp, sp, #272            /* W[64] */
        mov     x15, sp
        mov     x19, x0

        mov     w9, #0                  /* W[0..15] = the block, big-endian */
1:      ldr     w10, [x1, w9, uxtw #2]
        rev     w10, w10
        str     w10, [x15, w9, uxtw #2]
        add     w9, w9, #1
        cmp     w9, #16
        b.lo    1b

2:      cmp     w9, #64                 /* W[16..63] = the schedule */
        b.hs    3f
        sub     w11, w9, #15
        ldr     w10, [x15, w11, uxtw #2]
        ror     w12, w10, #7
        ror     w13, w10, #18
        eor     w12, w12, w13
        lsr     w13, w10, #3
        eor     w12, w12, w13           /* s0 */
        sub     w11, w9, #2
        ldr     w10, [x15, w11, uxtw #2]
        ror     w13, w10, #17
        ror     w14, w10, #19
        eor     w13, w13, w14
        lsr     w14, w10, #10
        eor     w13, w13, w14           /* s1 */
        sub     w11, w9, #16
        ldr     w10, [x15, w11, uxtw #2]
        add     w10, w10, w12
        sub     w11, w9, #7
        ldr     w12, [x15, w11, uxtw #2]
        add     w10, w10, w12
        add     w10, w10, w13
        str     w10, [x15, w9, uxtw #2]
        add     w9, w9, #1
        b       2b
3:
        ldp     w20, w21, [x19, #CTX_STATE]      /* a, b */
        ldp     w22, w23, [x19, #(CTX_STATE + 8)]
        ldp     w24, w25, [x19, #(CTX_STATE + 16)]
        ldp     w26, w27, [x19, #(CTX_STATE + 24)]

        LEA     x14, sha256_k
        mov     w28, #0
.Lround:
        ror     w9, w24, #6                     /* S1(e) */
        ror     w10, w24, #11
        eor     w9, w9, w10
        ror     w10, w24, #25
        eor     w9, w9, w10
        and     w10, w24, w25                   /* Ch(e,f,g) */
        bic     w11, w26, w24
        eor     w10, w10, w11
        add     w12, w27, w9
        add     w12, w12, w10
        ldr     w13, [x14, w28, uxtw #2]
        add     w12, w12, w13
        ldr     w13, [x15, w28, uxtw #2]
        add     w12, w12, w13                   /* T1 */

        ror     w9, w20, #2                     /* S0(a) */
        ror     w10, w20, #13
        eor     w9, w9, w10
        ror     w10, w20, #22
        eor     w9, w9, w10
        and     w10, w20, w21                   /* Maj(a,b,c) */
        and     w11, w20, w22
        eor     w10, w10, w11
        and     w11, w21, w22
        eor     w10, w10, w11
        add     w13, w9, w10                    /* T2 */

        mov     w27, w26
        mov     w26, w25
        mov     w25, w24
        add     w24, w23, w12
        mov     w23, w22
        mov     w22, w21
        mov     w21, w20
        add     w20, w12, w13

        add     w28, w28, #1
        cmp     w28, #64
        b.lo    .Lround

        ldp     w9, w10, [x19, #CTX_STATE]      /* fold back in */
        add     w9, w9, w20
        add     w10, w10, w21
        stp     w9, w10, [x19, #CTX_STATE]
        ldp     w9, w10, [x19, #(CTX_STATE + 8)]
        add     w9, w9, w22
        add     w10, w10, w23
        stp     w9, w10, [x19, #(CTX_STATE + 8)]
        ldp     w9, w10, [x19, #(CTX_STATE + 16)]
        add     w9, w9, w24
        add     w10, w10, w25
        stp     w9, w10, [x19, #(CTX_STATE + 16)]
        ldp     w9, w10, [x19, #(CTX_STATE + 24)]
        add     w9, w9, w26
        add     w10, w10, w27
        stp     w9, w10, [x19, #(CTX_STATE + 24)]

        add     sp, sp, #272
        ldp     x27, x28, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #160
        ret

/* sha256_init - x0 = ctx */
        .globl  SYM(sha256_init)
SYM(sha256_init):
        LEA     x1, sha256_iv
        ldp     x2, x3, [x1]
        stp     x2, x3, [x0, #CTX_STATE]
        ldp     x2, x3, [x1, #16]
        stp     x2, x3, [x0, #(CTX_STATE + 16)]
        str     xzr, [x0, #CTX_LEN]
        str     wzr, [x0, #CTX_FILL]
        ret

/* sha256_update - x0 = ctx, x1 = data, w2 = length */
        .globl  SYM(sha256_update)
SYM(sha256_update):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        str     x23, [sp, #48]
        mov     x19, x0
        mov     x20, x1
        mov     w21, w2

        ldr     x9, [x19, #CTX_LEN]     /* running length */
        add     x9, x9, w21, uxtw
        str     x9, [x19, #CTX_LEN]

1:      cbz     w21, 9f
        ldr     w22, [x19, #CTX_FILL]
        add     x23, x19, #CTX_BUF
        ldrb    w9, [x20], #1
        strb    w9, [x23, w22, uxtw]
        add     w22, w22, #1
        sub     w21, w21, #1
        str     w22, [x19, #CTX_FILL]
        cmp     w22, #64
        b.lo    1b
        mov     x0, x19                 /* a full block: fold it */
        add     x1, x19, #CTX_BUF
        bl      SYM(sha256_block)
        str     wzr, [x19, #CTX_FILL]
        b       1b
9:      ldr     x23, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/* sha256_final - x0 = ctx, x1 = 32-byte output */
        .globl  SYM(sha256_final)
SYM(sha256_final):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]
        mov     x19, x0
        mov     x20, x1

        ldr     x21, [x19, #CTX_LEN]    /* the length goes in before padding */
        lsl     x21, x21, #3            /* in bits */

        ldr     w9, [x19, #CTX_FILL]    /* 0x80, then zeros */
        add     x10, x19, #CTX_BUF
        mov     w11, #0x80
        strb    w11, [x10, w9, uxtw]
        add     w9, w9, #1
1:      cmp     w9, #56
        b.eq    3f
        cmp     w9, #64
        b.lo    2f
        mov     x0, x19                 /* no room for the length: flush */
        add     x1, x19, #CTX_BUF
        bl      SYM(sha256_block)
        mov     w9, #0
        add     x10, x19, #CTX_BUF
2:      strb    wzr, [x10, w9, uxtw]
        add     w9, w9, #1
        b       1b
3:      rev     x21, x21                /* big-endian bit count */
        add     x10, x19, #CTX_BUF
        str     x21, [x10, #56]
        mov     x0, x19
        add     x1, x19, #CTX_BUF
        bl      SYM(sha256_block)

        mov     w9, #0                  /* state out, big-endian */
4:      ldr     w10, [x19, w9, uxtw #2]
        rev     w10, w10
        lsl     w11, w9, #2
        str     w10, [x20, w11, uxtw]
        add     w9, w9, #1
        cmp     w9, #8
        b.lo    4b

        ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* sha256 - one shot. x0 = data, w1 = len, x2 = 32-byte output */
        .globl  SYM(sha256)
SYM(sha256):
        stp     x29, x30, [sp, #-160]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0
        mov     w20, w1
        mov     x21, x2
        add     x22, sp, #48            /* ctx on the stack */
        mov     x0, x22
        bl      SYM(sha256_init)
        mov     x0, x22
        mov     x1, x19
        mov     w2, w20
        bl      SYM(sha256_update)
        mov     x0, x22
        mov     x1, x21
        bl      SYM(sha256_final)
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #160
        ret

/* hex_encode - x0 = bytes, w1 = count, x2 = output (2*count + NUL) */
        .globl  SYM(hex_encode)
SYM(hex_encode):
        mov     w3, #0
1:      cmp     w3, w1
        b.hs    9f
        ldrb    w4, [x0, w3, uxtw]
        lsr     w5, w4, #4
        and     w6, w4, #0xF
        lsl     w7, w3, #1
        cmp     w5, #10
        b.lo    2f
        add     w5, w5, #('a' - 10)
        b       3f
2:      add     w5, w5, #'0'
3:      strb    w5, [x2, w7, uxtw]
        add     w7, w7, #1
        cmp     w6, #10
        b.lo    4f
        add     w6, w6, #('a' - 10)
        b       5f
4:      add     w6, w6, #'0'
5:      strb    w6, [x2, w7, uxtw]
        add     w3, w3, #1
        b       1b
9:      lsl     w7, w1, #1
        strb    wzr, [x2, w7, uxtw]
        ret

        RODATA
        .p2align 4
sha256_iv:
        .word 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
        .word 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
sha256_k:
        .word 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5
        .word 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
        .word 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3
        .word 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
        .word 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc
        .word 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
        .word 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7
        .word 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
        .word 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13
        .word 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
        .word 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3
        .word 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
        .word 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5
        .word 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
        .word 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208
        .word 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
