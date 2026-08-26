#include "asm.inc"
/*
 * util.S - the odds and ends the daemon needs: pulling a field out of a JSON
 * body, minting a key from the kernel's entropy, and formatting UTC for AWS.
 *
 * The date arithmetic is the civil-from-days algorithm, done in integers.
 * There is no libc to ask, and AWS rejects a signature whose timestamp it
 * disagrees with, so this has to be right.
 */
#define SYS_OPEN        5
#define SYS_READ        3
#define SYS_CLOSE       6
#define SYS_GETTIMEOFDAY 116

        CODE
        .p2align 2

/*
 * json_get_str - pull one string field out of a JSON body.
 *   x0 = document, x1 = quoted key, x2 = destination, w3 = capacity
 *   out w0 = length, or -1 when the key is absent
 */
        .globl  SYM(json_get_str)
SYM(json_get_str):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]
        mov     x19, x2
        mov     w20, w3
        bl      SYM(json_find)
        cbz     x0, 1f
        mov     x1, x0
        mov     x0, x19
        mov     w2, w20
        bl      SYM(json_unescape)
        b       2f
1:      strb    wzr, [x19]
        mov     w0, #-1
2:      ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * rand_hex - x0 = destination, w1 = number of random bytes (hex is twice that
 * plus a NUL).  Entropy comes from /dev/urandom; there is no PRNG here to get
 * wrong.  out w0 = 0, or -1 if the device could not be read.
 */
        .globl  SYM(rand_hex)
SYM(rand_hex):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0
        mov     w20, w1
        cmp     w20, #64
        b.ls    1f
        mov     w20, #64
1:      LEA     x0, s_urandom
        mov     x1, #0                  /* O_RDONLY */
        mov     x2, #0
        mov     x16, #SYS_OPEN
        svc     #0x80
        b.cs    .Lrand_fail
        mov     w21, w0
        LEA     x22, rand_buf
        mov     w0, w21
        mov     x1, x22
        mov     w2, w20
        mov     x16, #SYS_READ
        svc     #0x80
        b.cs    .Lrand_close
        cmp     w0, w20
        b.ne    .Lrand_close
        mov     w0, w21
        mov     x16, #SYS_CLOSE
        svc     #0x80
        LEA     x0, rand_buf
        mov     w1, w20
        mov     x2, x19
        bl      SYM(hex_encode)
        mov     w0, #0
        b       .Lrand_out
.Lrand_close:
        mov     w0, w21
        mov     x16, #SYS_CLOSE
        svc     #0x80
.Lrand_fail:
        strb    wzr, [x19]
        mov     w0, #-1
.Lrand_out:
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * time_utc - x0 = 17-byte buffer for "YYYYMMDDTHHMMSSZ",
 *            x1 = 9-byte buffer for "YYYYMMDD"
 */
        .globl  SYM(time_utc)
SYM(time_utc):
        stp     x29, x30, [sp, #-112]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        stp     x27, x28, [sp, #80]
        mov     x19, x0
        mov     x20, x1

        LEA     x0, tv
        mov     x1, #0
        mov     x2, #0
        mov     x16, #SYS_GETTIMEOFDAY
        svc     #0x80
        LEA     x9, tv
        ldr     x27, [x9]               /* seconds since the epoch */

        mov     x9, #0x5180
        movk    x9, #0x1, lsl #16       /* 86400 */
        udiv    x10, x27, x9            /* whole days */
        msub    x11, x10, x9, x27       /* seconds within the day */

        mov     x12, #3600
        udiv    x24, x11, x12           /* hour */
        msub    x11, x24, x12, x11
        mov     x12, #60
        udiv    x25, x11, x12           /* minute */
        msub    x26, x25, x12, x11      /* second */

        mov     x9, #0xFA6C             /* civil from days */
        movk    x9, #0xA, lsl #16       /* 719468 */
        add     x10, x10, x9
        mov     x9, #0x3AB1
        movk    x9, #0x2, lsl #16       /* 146097 */
        udiv    x12, x10, x9            /* era */
        msub    x13, x12, x9, x10       /* doe */

        mov     x9, #1460
        udiv    x0, x13, x9
        sub     x1, x13, x0
        mov     x9, #0x8EAC
        movk    x9, #0x0, lsl #16       /* 36524 */
        udiv    x0, x13, x9
        add     x1, x1, x0
        mov     x9, #0x3AB0
        movk    x9, #0x2, lsl #16       /* 146096 */
        udiv    x0, x13, x9
        sub     x1, x1, x0
        mov     x9, #365
        udiv    x1, x1, x9              /* yoe */

        mov     x9, #400
        madd    x21, x12, x9, x1        /* year, before the Jan/Feb shift */
        mov     x9, #365
        mul     x0, x1, x9
        lsr     x9, x1, #2
        add     x0, x0, x9
        mov     x9, #100
        udiv    x9, x1, x9
        sub     x0, x0, x9
        sub     x3, x13, x0             /* doy */
        mov     x9, #5
        mul     x0, x3, x9
        add     x0, x0, #2
        mov     x9, #153
        udiv    x4, x0, x9              /* mp */
        mov     x9, #153
        mul     x0, x4, x9
        add     x0, x0, #2
        mov     x9, #5
        udiv    x0, x0, x9
        sub     x23, x3, x0
        add     x23, x23, #1            /* day */
        cmp     x4, #10
        b.lo    1f
        sub     x22, x4, #9             /* month */
        add     x21, x21, #1            /* Jan and Feb belong to the next year
                                           in this scheme */
        b       2f
1:      add     x22, x4, #3
2:
        mov     x0, x19                 /* everything lives in callee-saved
                                           registers now: pad_num is free to
                                           use the scratch ones */
        mov     w1, w21
        mov     w2, #4
        bl      pad_num
        mov     w1, w22
        mov     w2, #2
        bl      pad_num
        mov     w1, w23
        mov     w2, #2
        bl      pad_num
        mov     w9, #'T'
        strb    w9, [x0], #1
        mov     w1, w24
        mov     w2, #2
        bl      pad_num
        mov     w1, w25
        mov     w2, #2
        bl      pad_num
        mov     w1, w26
        mov     w2, #2
        bl      pad_num
        mov     w9, #'Z'
        strb    w9, [x0], #1
        strb    wzr, [x0]

        mov     w9, #0                  /* the datestamp is its first 8 bytes */
3:      ldrb    w10, [x19, w9, uxtw]
        strb    w10, [x20, w9, uxtw]
        add     w9, w9, #1
        cmp     w9, #8
        b.lo    3b
        strb    wzr, [x20, #8]

        ldp     x27, x28, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #112
        ret

/* pad_num - write w1 at x0 in exactly w2 digits, zero padded; x0 advances.
   Uses only scratch registers, by design: its callers keep live values in
   x19-x28. */
pad_num:
        mov     w9, w2
        add     x10, x0, w2, uxtw
        mov     x11, x10
1:      sub     x11, x11, #1
        mov     w12, #10
        udiv    w13, w1, w12
        msub    w14, w13, w12, w1
        add     w14, w14, #'0'
        strb    w14, [x11]
        mov     w1, w13
        subs    w9, w9, #1
        b.ne    1b
        mov     x0, x10
        ret

        CSTR
s_urandom:      .asciz "/dev/urandom"

        BSS
        .p2align 4
tv:             .space 16
rand_buf:       .space 64
