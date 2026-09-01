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
1:      bl      uart_key
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

/*
 * platform_reboot - start again.
 *
 * PSCI SYSTEM_RESET, through the hypervisor call. Every machine this kernel
 * targets implements PSCI: QEMU does, macOS's Virtualization framework does,
 * and on real Apple hardware m1n1 does. It is the one way to restart that does
 * not require knowing anything about the board.
 *
 * The conduit is HVC and not SMC. A device tree says which through the psci
 * node's `method` property, and this does not read it - not out of laziness
 * but because guessing wrong is not a failed reboot: SMC from EL1 with no
 * secure monitor beneath is an undefined instruction, which faults, which on
 * this kernel means halting with a report about a reboot that never happened.
 * A call that returns is a machine that declined, and returning is safe.
 *
 * It does not come back when it works, so there is nothing to report.
 */
        .globl  platform_reboot
platform_reboot:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]

/*
 * Which instruction makes the call.
 *
 * The device tree says, through the psci node's `method`, and asking is not
 * pedantry: QEMU's virt machine with EL2 disabled expects SMC, and an HVC
 * there does nothing at all - which is what happened the first time this ran.
 * No fault, no restart, no message. Guessing the other way is worse: SMC with
 * no monitor beneath is an undefined instruction, and this kernel would report
 * a fault about a reboot instead of performing one.
 *
 * Three spellings of the same node, because the property is stable and the
 * compatible string is not.
 */
        mov     w19, #0                 /* 0 unknown, 1 hvc, 2 smc */
        LEA     x0, s_psci_02
        bl      reboot_method
        cbnz    w0, 1f
        LEA     x0, s_psci_10
        bl      reboot_method
        cbnz    w0, 1f
        LEA     x0, s_psci
        bl      reboot_method
1:      mov     w19, w0

        movz    w0, #0x0009
        movk    w0, #0x8400, lsl #16    /* PSCI SYSTEM_RESET */
        cmp     w19, #2
        b.eq    2f
        hvc     #0                      /* hvc, and by default */
        b       3f
2:      smc     #0
3:      mov     w0, #-1                 /* still here: it declined */
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/* reboot_method - x0 = a compatible string, out w0 = 0 none, 1 hvc, 2 smc. */
reboot_method:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        mov     w1, #0
        LEA     x2, s_method
        bl      SYM(dtb_prop)
        cbz     x0, 9f
        ldrb    w9, [x0]
        cmp     w9, #'s'
        b.ne    8f
        mov     w0, #2
        b       10f
8:      mov     w0, #1
        b       10f
9:      mov     w0, #0
10:     ldp     x29, x30, [sp], #16
        ret

/*
 * platform_idle - something is waiting; keep the machine listening.
 *
 * Called from the places that spin: waiting for a handshake, for an
 * acknowledgement, for a reply. None of those has anything to do with the
 * keyboard, and that is exactly the problem - the device's ring fills after a
 * few dozen events and then stops delivering, so a Cmd+P that takes two
 * seconds used to cost every key pressed during those two seconds.
 *
 * It does not deliver keys anywhere. It moves them off the device and into a
 * ring the editor will read when it is free again, which is all that is needed
 * for typing during a request to be typing that happened.
 */
        .globl  platform_idle
platform_idle:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LEA     x9, kbd_present
        ldr     w9, [x9]
        cbz     w9, 1f
        bl      kbd_pump
1:      ldp     x29, x30, [sp], #16
        ret

        .section .rodata
s_psci_02: .asciz "arm,psci-0.2"
s_psci_10: .asciz "arm,psci-1.0"
s_psci:    .asciz "arm,psci"
s_method:  .asciz "method"
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
