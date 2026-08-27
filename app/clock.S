#include "asm.inc"
/*
 * clock.S - what time it is, in assembly.
 *
 * A press and a long press differ only in how long the finger stayed down, so
 * the front ends need a clock.  This is the gettimeofday syscall directly
 * rather than libc's wrapper, for the same reason everything else here is: the
 * OS-mode build has no libc to call, and a front end that reaches for one
 * would not map onto it.
 */
#define SYS_GETTIMEOFDAY        116

        CODE
        .p2align 2

/* now_millis - out x0 = milliseconds since the epoch */
        .globl  SYM(now_millis)
SYM(now_millis):
        sub     sp, sp, #32
        mov     x0, sp
        mov     x1, #0
        mov     x2, #0
        mov     x16, #SYS_GETTIMEOFDAY
        svc     #0x80
        ldr     x9, [sp]                /* seconds      */
        ldr     x10, [sp, #8]           /* microseconds */
        mov     x11, #1000
        mul     x9, x9, x11
        udiv    x10, x10, x11
        add     x0, x9, x10
        add     sp, sp, #32
        ret
