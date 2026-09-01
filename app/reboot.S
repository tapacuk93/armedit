#include "asm.inc"
/*
 * reboot.S - what "restart the machine" means when there is no machine.
 *
 * The OS build can restart: it owns the hardware, and PSCI is one call away.
 * The macOS and iOS builds are programs inside somebody else's operating
 * system, and a program that restarted the computer because a document asked
 * it to would be a program nobody should run.
 *
 * So this declines, and declining is the whole implementation. The directive
 * still arrives, is still recognised, and still does nothing here - which is
 * the same shape as an operation that matches and returns nothing, and reads
 * the same way to everything upstream.
 */
        CODE
        .p2align 2
        .globl  SYM(platform_reboot)
SYM(platform_reboot):
        mov     w0, #-1
        ret
