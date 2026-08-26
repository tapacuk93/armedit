#include "asm.inc"
/*
 * aead.S - ChaCha20-Poly1305 AEAD, RFC 8439 section 2.8.
 *
 * The one cipher suite this TLS client offers.  Sealing is: derive a one-time
 * Poly1305 key from block zero of the keystream, encrypt from block one, then
 * authenticate aad || pad || ciphertext || pad || lengths.
 *
 * Opening verifies before it decrypts, and the comparison is constant time -
 * a tag check that returns early is a tag check that leaks.
 */
#define MAC_SCRATCH     20480

        CODE
        .p2align 2

/*
 * aead_mac - build the Poly1305 input and run it.
 *   x0 = one-time key, x1 = aad, w2 = aad length,
 *   x3 = ciphertext, w4 = ciphertext length, x5 = 16-byte tag out
 */
aead_mac:
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

        LEA     x25, mac_buf
        mov     w26, #0
        mov     w9, #0
1:      cmp     w9, w21                 /* aad */
        b.hs    2f
        ldrb    w10, [x20, w9, uxtw]
        strb    w10, [x25, w26, uxtw]
        add     w9, w9, #1
        add     w26, w26, #1
        b       1b
2:      ands    w9, w26, #15            /* pad to a 16-byte boundary */
        b.eq    3f
        strb    wzr, [x25, w26, uxtw]
        add     w26, w26, #1
        b       2b
3:      mov     w9, #0
4:      cmp     w9, w23                 /* ciphertext */
        b.hs    5f
        ldrb    w10, [x22, w9, uxtw]
        strb    w10, [x25, w26, uxtw]
        add     w9, w9, #1
        add     w26, w26, #1
        b       4b
5:      ands    w9, w26, #15
        b.eq    6f
        strb    wzr, [x25, w26, uxtw]
        add     w26, w26, #1
        b       5b
6:      add     x9, x25, w26, uxtw      /* the two lengths, little-endian */
        mov     x10, x21
        str     x10, [x9]
        mov     x10, x23
        str     x10, [x9, #8]
        add     w26, w26, #16

        mov     x0, x25
        mov     w1, w26
        mov     x2, x19
        mov     x3, x24
        bl      SYM(poly1305_mac)

        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

/*
 * aead_seal - x0 = 32-byte key, x1 = 12-byte nonce, x2 = aad, w3 = aad len,
 *             x4 = plaintext, w5 = plaintext len, x6 = ciphertext out,
 *             x7 = 16-byte tag out
 */
        .globl  SYM(aead_seal)
SYM(aead_seal):
        stp     x29, x30, [sp, #-112]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        stp     x27, x28, [sp, #80]
        mov     x19, x0
        mov     x20, x1
        mov     x21, x2
        mov     w22, w3
        mov     x23, x4
        mov     w24, w5
        mov     x25, x6
        mov     x26, x7

        LEA     x0, aead_state          /* block zero gives the one-time key */
        mov     x1, x19
        mov     x2, x20
        mov     w3, #0
        bl      SYM(chacha20_init)
        LEA     x0, aead_state
        LEA     x1, aead_otk_block
        bl      SYM(chacha20_block)

        LEA     x0, aead_state          /* the payload starts at block one */
        mov     x1, x19
        mov     x2, x20
        mov     w3, #1
        bl      SYM(chacha20_init)
        LEA     x0, aead_state
        mov     x1, x23
        mov     x2, x25
        mov     w3, w24
        bl      SYM(chacha20_xor)

        LEA     x0, aead_otk_block
        mov     x1, x21
        mov     w2, w22
        mov     x3, x25
        mov     w4, w24
        mov     x5, x26
        bl      aead_mac

        ldp     x27, x28, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #112
        ret

/*
 * aead_open - x0 = key, x1 = nonce, x2 = aad, w3 = aad len, x4 = ciphertext,
 *             w5 = ciphertext len, x6 = plaintext out, x7 = 16-byte tag
 *   out w0 = 0 if the tag verified (plaintext written), -1 if not (nothing
 *   written).
 */
        .globl  SYM(aead_open)
SYM(aead_open):
        stp     x29, x30, [sp, #-112]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        stp     x27, x28, [sp, #80]
        mov     x19, x0
        mov     x20, x1
        mov     x21, x2
        mov     w22, w3
        mov     x23, x4
        mov     w24, w5
        mov     x25, x6
        mov     x26, x7

        LEA     x0, aead_state
        mov     x1, x19
        mov     x2, x20
        mov     w3, #0
        bl      SYM(chacha20_init)
        LEA     x0, aead_state
        LEA     x1, aead_otk_block
        bl      SYM(chacha20_block)

        LEA     x0, aead_otk_block      /* authenticate first */
        mov     x1, x21
        mov     w2, w22
        mov     x3, x23
        mov     w4, w24
        LEA     x5, aead_tag
        bl      aead_mac

        LEA     x9, aead_tag            /* constant-time compare */
        mov     w11, #0
        mov     w10, #0
1:      ldrb    w12, [x9, w10, uxtw]
        ldrb    w13, [x26, w10, uxtw]
        eor     w12, w12, w13
        orr     w11, w11, w12
        add     w10, w10, #1
        cmp     w10, #16
        b.lo    1b
        cbnz    w11, .Lopen_bad

        LEA     x0, aead_state
        mov     x1, x19
        mov     x2, x20
        mov     w3, #1
        bl      SYM(chacha20_init)
        LEA     x0, aead_state
        mov     x1, x23
        mov     x2, x25
        mov     w3, w24
        bl      SYM(chacha20_xor)
        mov     w0, #0
        b       .Lopen_out
.Lopen_bad:
        mov     w0, #-1
.Lopen_out:
        ldp     x27, x28, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #112
        ret

        BSS
        .p2align 4
aead_state:     .space 64
aead_otk_block: .space 64
aead_tag:       .space 16
mac_buf:        .space MAC_SCRATCH
