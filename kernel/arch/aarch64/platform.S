#include "asm.inc"
/*
 * platform.S - the aarch64/QEMU-virt side of the port layer.
 *
 * Everything a machine has to provide before the portable half of the kernel
 * will run: a framebuffer to draw into and a channel to complain down. The
 * console, the font and the editor above this know none of it - they ask
 * platform_fb where the pixels are and get on with it.
 *
 * A different CPU or a different board replaces this file and the three
 * beside it. See kernel/PORTING.md for the whole contract; it is four
 * functions long on purpose.
 */
#define FB_W    800
#define FB_H    600

        .section .text
        .p2align 2

/*
 * platform_init - bring up whatever this machine draws on.
 *   out w0 = 0 if there is a framebuffer, -1 if this board has none
 *
 * Here that means handing our buffer to QEMU's ramfb over fw_cfg. On another
 * board it might mean a real display controller, or nothing at all - a kernel
 * with only a serial line is a legitimate outcome, and the caller is expected
 * to cope.
 */
        .globl  platform_init
platform_init:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LEA     x0, fb_store
        mov     w1, #FB_W
        mov     w2, #FB_H
        bl      ramfb_init
        ldp     x29, x30, [sp], #16
        ret

/*
 * platform_fb - where the pixels are, and how many.
 *   x0 = out pointer to the base address
 *   x1 = out width in pixels, x2 = out height
 * Stride is the width: this board has no padding between rows.
 */
        .globl  platform_fb
platform_fb:
        LEA     x9, fb_store
        str     x9, [x0]
        mov     w9, #FB_W
        str     w9, [x1]
        mov     w9, #FB_H
        str     w9, [x2]
        ret

/*
 * platform_puts - the debug channel, before and after a display exists.
 * x0 = NUL-terminated string.
 */
        .globl  platform_puts
platform_puts:
        b       uart_puts

/*
 * platform_getc - one byte from the console, or -1 if none is waiting.
 * The editor polls this rather than blocking on it, because a blocked kernel
 * is a kernel whose caret has stopped for the wrong reason.
 */
        .globl  platform_getc
platform_getc:
        b       uart_getc

/*
 * platform_ticks - milliseconds since the machine started.
 *
 * The editor needs this for one thing only: deciding when the caret has been
 * on long enough. That is a small purpose for a port contract entry, but the
 * alternative is a caret that blinks at whatever rate the key-polling loop
 * happens to run at, which is to say a different rate on every machine.
 *
 * The generic timer is architectural on aarch64, so this is one of the few
 * places where the port layer gets an easy answer. A port to a CPU without
 * one counts something else and scales it the same way.
 */
        .globl  platform_ticks
platform_ticks:
        mrs     x0, cntvct_el0
        mrs     x1, cntfrq_el0
        cbz     x1, 1f
        mov     x2, #1000
        mul     x0, x0, x2
        udiv    x0, x0, x1
        ret
1:      mov     x0, #0                  /* no timer: a caret that never blinks
                                           beats a division by zero */
        ret

        .section .bss
        .p2align 4
fb_store:
        .space  (FB_W * FB_H * 4)
