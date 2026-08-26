#include "asm.inc"
/*
 * chacha20.S - ChaCha20, RFC 8439.
 *
 * The stream cipher half of TLS 1.3's ChaCha20-Poly1305 suite, and the
 * generator behind the one-time pad layer.  Chosen over AES-GCM because it is
 * pure add-rotate-xor: no tables, no carry-less multiply, nothing that would
 * behave differently on the bare-metal target than it does here.
 *
 * The sixteen state words live in w0-w15 for the whole permutation, which is
 * why the pointers are parked in x16/x17.
 */
        CODE
        .p2align 2

.macro  QR a, b, c, d
        add     w\a, w\a, w\b
        eor     w\d, w\d, w\a
        ror     w\d, w\d, #16           /* rotl 16 */
        add     w\c, w\c, w\d
        eor     w\b, w\b, w\c
        ror     w\b, w\b, #20           /* rotl 12 */
        add     w\a, w\a, w\b
        eor     w\d, w\d, w\a
        ror     w\d, w\d, #24           /* rotl 8  */
        add     w\c, w\c, w\d
        eor     w\b, w\b, w\c
        ror     w\b, w\b, #25           /* rotl 7  */
.endm

.macro  OUTW i
        ldr     w19, [x16, #(\i * 4)]
        add     w\i, w\i, w19
        str     w\i, [x17, #(\i * 4)]
.endm

/*
 * chacha20_block - x0 = the 16-word state, x1 = 64 bytes of keystream out.
 * The state is left untouched.
 */
        .globl  SYM(chacha20_block)
SYM(chacha20_block):
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     x16, x0
        mov     x17, x1
        ldp     w0, w1, [x16, #0]
        ldp     w2, w3, [x16, #8]
        ldp     w4, w5, [x16, #16]
        ldp     w6, w7, [x16, #24]
        ldp     w8, w9, [x16, #32]
        ldp     w10, w11, [x16, #40]
        ldp     w12, w13, [x16, #48]
        ldp     w14, w15, [x16, #56]

        .rept   10                      /* twenty rounds, as ten doubles */
        QR      0, 4, 8, 12
        QR      1, 5, 9, 13
        QR      2, 6, 10, 14
        QR      3, 7, 11, 15
        QR      0, 5, 10, 15
        QR      1, 6, 11, 12
        QR      2, 7, 8, 13
        QR      3, 4, 9, 14
        .endr

        OUTW    0
        OUTW    1
        OUTW    2
        OUTW    3
        OUTW    4
        OUTW    5
        OUTW    6
        OUTW    7
        OUTW    8
        OUTW    9
        OUTW    10
        OUTW    11
        OUTW    12
        OUTW    13
        OUTW    14
        OUTW    15

        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/*
 * chacha20_init - lay out a state block.
 *   x0 = state (64 bytes), x1 = 32-byte key, x2 = 12-byte nonce,
 *   w3 = initial block counter
 */
        .globl  SYM(chacha20_init)
SYM(chacha20_init):
        mov     w4, #0x7865             /* "expand 32-byte k" */
        movk    w4, #0x6170, lsl #16
        str     w4, [x0, #0]
        mov     w4, #0x646E
        movk    w4, #0x3320, lsl #16
        str     w4, [x0, #4]
        mov     w4, #0x2D32
        movk    w4, #0x7962, lsl #16
        str     w4, [x0, #8]
        mov     w4, #0x6574
        movk    w4, #0x6B20, lsl #16
        str     w4, [x0, #12]
        mov     w5, #0
1:      ldr     w4, [x1, w5, uxtw #2]   /* key, little-endian words */
        add     w6, w5, #4
        str     w4, [x0, w6, uxtw #2]
        add     w5, w5, #1
        cmp     w5, #8
        b.lo    1b
        str     w3, [x0, #48]           /* counter */
        ldr     w4, [x2, #0]
        str     w4, [x0, #52]           /* nonce */
        ldr     w4, [x2, #4]
        str     w4, [x0, #56]
        ldr     w4, [x2, #8]
        str     w4, [x0, #60]
        ret

/*
 * chacha20_xor - encrypt or decrypt; they are the same operation.
 *   x0 = state (already initialised), x1 = input, x2 = output, w3 = length
 * The state's counter advances as it goes.
 */
        .globl  SYM(chacha20_xor)
SYM(chacha20_xor):
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        sub     sp, sp, #64
        mov     x24, sp                 /* one block of keystream */
        mov     x19, x0
        mov     x20, x1
        mov     x21, x2
        mov     w22, w3

1:      cbz     w22, 9f
        mov     x0, x19
        mov     x1, x24
        bl      SYM(chacha20_block)
        ldr     w9, [x19, #48]          /* next block */
        add     w9, w9, #1
        str     w9, [x19, #48]

        mov     w23, #64
        cmp     w22, w23
        csel    w23, w22, w23, lo       /* partial final block */
        mov     w9, #0
2:      cmp     w9, w23
        b.hs    3f
        ldrb    w10, [x20, w9, uxtw]
        ldrb    w11, [x24, w9, uxtw]
        eor     w10, w10, w11
        strb    w10, [x21, w9, uxtw]
        add     w9, w9, #1
        b       2b
3:      add     x20, x20, w23, uxtw
        add     x21, x21, w23, uxtw
        sub     w22, w22, w23
        b       1b

9:      add     sp, sp, #64
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret
