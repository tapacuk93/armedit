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
 * Nothing calls this yet; it is here because the contract names it and a
 * kernel that cannot be typed into is only half a kernel.
 */
        .globl  platform_getc
platform_getc:
        b       uart_getc

        .section .bss
        .p2align 4
fb_store:
        .space  (FB_W * FB_H * 4)
