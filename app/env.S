#include "asm.inc"
/*
 * env.S - environment lookup without libc.
 *
 * main() is handed envp as its third argument; we keep it and walk it.  That
 * avoids reaching for libSystem's `environ` through the GOT, and it is the
 * same few lines the kernel build would need for its own config block.
 */
#define ENV_OVER        4               /* how many values may be told to us */
#define ENV_NAME        32
#define ENV_VALUE       160
#define ENV_ENTRY       (ENV_NAME + ENV_VALUE)

        CODE
        .p2align 2

/* env_init - x0 = envp, as passed to main */
        .globl  SYM(env_init)
SYM(env_init):
        LEA     x1, envp_slot
        str     x0, [x1]
        ret

/*
 * env_put - x0 = "NAME", x1 = its value.
 *
 * For machines that have no environment to inherit. The bare-metal build reads
 * its configuration out of fw_cfg at boot and puts it here, so that everything
 * above - resolve_backend, and whatever comes after it - asks the same
 * question on every target rather than knowing which one it is on.
 */
        .globl  SYM(env_put)
SYM(env_put):
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        LEA     x9, over_count
        ldr     w10, [x9]
        cmp     w10, #ENV_OVER
        b.hs    9f
        mov     w11, #ENV_ENTRY
        mul     w11, w10, w11
        LEA     x12, over_table
        add     x12, x12, w11, uxtw
        mov     w13, #0
1:      cmp     w13, #(ENV_NAME - 1)            /* the name */
        b.hs    2f
        ldrb    w14, [x0, w13, uxtw]
        strb    w14, [x12, w13, uxtw]
        cbz     w14, 2f
        add     w13, w13, #1
        b       1b
2:      strb    wzr, [x12, w13, uxtw]
        add     x12, x12, #ENV_NAME
        mov     w13, #0
3:      cmp     w13, #(ENV_VALUE - 1)           /* and the value */
        b.hs    4f
        ldrb    w14, [x1, w13, uxtw]
        strb    w14, [x12, w13, uxtw]
        cbz     w14, 4f
        add     w13, w13, #1
        b       3b
4:      strb    wzr, [x12, w13, uxtw]
        add     w10, w10, #1
        str     w10, [x9]
9:      ldp     x29, x30, [sp], #32
        ret

/*
 * env_get - x0 = "NAME", out x0 = pointer to the value, or 0.
 * Matches NAME= at the start of an entry.  Anything env_put set is consulted
 * first, since a machine that had to be told its configuration has no envp to
 * fall back on anyway.
 */
        .globl  SYM(env_get)
SYM(env_get):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     x19, x0
        LEA     x9, over_count
        ldr     w20, [x9]
        cbz     w20, .Lenv_real
        mov     w9, #0
1:      cmp     w9, w20
        b.hs    .Lenv_real
        mov     w10, #ENV_ENTRY
        mul     w10, w9, w10
        LEA     x11, over_table
        add     x11, x11, w10, uxtw
        stp     x9, x11, [sp, #32]
        mov     x0, x11
        mov     x1, x19
        bl      SYM(str_eq)
        ldp     x9, x11, [sp, #32]
        cbz     w0, 2f
        add     x0, x11, #ENV_NAME
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret
2:      add     w9, w9, #1
        b       1b
.Lenv_real:
        mov     x0, x19
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        b       env_get_envp

env_get_envp:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]
        mov     x19, x0
        LEA     x0, envp_slot
        ldr     x20, [x0]
        cbz     x20, .Lnone
1:      ldr     x21, [x20], #8
        cbz     x21, .Lnone
        mov     x0, x21                 /* does this entry start with NAME? */
        mov     x1, x19
        bl      SYM(str_starts)
        cbz     w0, 1b
        mov     x0, x19
        bl      SYM(str_len)
        add     x0, x21, w0, uxtw
        ldrb    w1, [x0]
        cmp     w1, #'='                /* NAME must be followed by '=' */
        b.ne    1b
        add     x0, x0, #1
        b       .Lenv_out
.Lnone: mov     x0, #0
.Lenv_out:
        ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

        BSS
        .p2align 3
over_count: .space 8
over_table: .space (ENV_OVER * ENV_ENTRY)
envp_slot:      .space 8
