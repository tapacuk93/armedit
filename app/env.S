#include "asm.inc"
/*
 * env.S - environment lookup without libc.
 *
 * main() is handed envp as its third argument; we keep it and walk it.  That
 * avoids reaching for libSystem's `environ` through the GOT, and it is the
 * same few lines the kernel build would need for its own config block.
 */
        CODE
        .p2align 2

/* env_init - x0 = envp, as passed to main */
        .globl  SYM(env_init)
SYM(env_init):
        LEA     x1, envp_slot
        str     x0, [x1]
        ret

/*
 * env_get - x0 = "NAME", out x0 = pointer to the value, or 0.
 * Matches NAME= at the start of an entry.
 */
        .globl  SYM(env_get)
SYM(env_get):
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
envp_slot:      .space 8
