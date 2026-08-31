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
#define FB_W    1280
#define FB_H    800

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
        stp     x0, x1, [sp, #-16]!     /* a keyboard is optional; a display
                                           is what decides whether we run */
        bl      kbd_init
        LEA     x9, kbd_present
        cmn     w0, #1
        cset    w10, ne
        str     w10, [x9]
        cbnz    w10, 9f
        LEA     x0, m_nokbd
        bl      uart_puts
        b       8f
9:      LEA     x0, m_kbd
        bl      uart_puts
8:      ldp     x0, x1, [sp], #16
        ldp     x29, x30, [sp], #16
        ret

/*
 * platform_fb - where to draw, and how much of it there is.
 *   x0 = out pointer to the base address
 *   x1 = out width in pixels, x2 = out height
 * Stride is the width: this board has no padding between rows.
 *
 * This hands back the *back* buffer, not the one the display is scanning out.
 * The editor draws a frame by clearing the surface and then painting it, and
 * ramfb shows whatever is in the scanout buffer at the moment it looks - so
 * drawing straight into it means the cleared screen is on display for as long
 * as the painting takes. Which is exactly as much flicker as it sounds like.
 *
 * platform_present copies the finished frame across.
 */
        .globl  platform_fb
platform_fb:
        LEA     x9, fb_back
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
/*
 * platform_present - the finished frame goes to the display.
 *
 * A straight copy, eight bytes at a time. It can still tear, in the sense that
 * the display may catch it half done - but a half-updated picture of two
 * frames is not something an eye notices, whereas a fully cleared screen
 * between every pair of frames very much is.
 */
        .globl  platform_present
platform_present:
        LEA     x0, fb_back
        LEA     x1, fb_store
        mov     x2, #0
        movz    x3, #((FB_W * FB_H * 4) & 0xFFFF)
        movk    x3, #((FB_W * FB_H * 4) >> 16), lsl #16
1:      cmp     x2, x3
        b.hs    2f
        ldr     x4, [x0, x2]
        str     x4, [x1, x2]
        add     x2, x2, #8
        b       1b
2:      ret

        .globl  platform_puts
platform_puts:
        b       uart_puts

/*
 * platform_getc - one byte from the console, or -1 if none is waiting.
 * The editor polls this rather than blocking on it, because a blocked kernel
 * is a kernel whose caret has stopped for the wrong reason.
 */
/*
 * platform_getc - one key, or -1.
 *
 * A machine with a keyboard uses it, and does not also read the serial line.
 * That is deliberate: the serial port is shared with QEMU's monitor, so
 * treating it as a second keyboard turns anything printed there into
 * keystrokes - which showed up as characters nobody typed appearing between
 * the ones they did. A console is for saying things, not for being typed into,
 * once there is somewhere better to type.
 *
 * A machine with no keyboard still has the wire, which is how this kernel was
 * driven before the driver existed.
 */
        .globl  platform_getc
platform_getc:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LEA     x9, kbd_present
        ldr     w9, [x9]
        cbz     w9, 1f
        bl      kbd_getc
        b       2f
1:      bl      uart_getc
2:      ldp     x29, x30, [sp], #16
        ret

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

        .section .rodata
m_kbd:    .asciz "armedit: keyboard found\n"
m_nokbd:  .asciz "armedit: no keyboard device\n"

        .section .bss
        .p2align 2
kbd_present:    .space 4
        .p2align 4
fb_store:
        .space  (FB_W * FB_H * 4)       /* what the display scans out */
        .p2align 4
fb_back:
        .space  (FB_W * FB_H * 4)       /* what we draw into */
