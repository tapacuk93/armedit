#include "asm.inc"
/*
 * report.S - what this machine turned out to be, on the machine's own screen.
 *
 * Every other diagnostic here goes to the serial port, and on every machine
 * this has run on so far that was the same thing as going somewhere. The
 * target is not such a machine. A MacBook booted from its own disk has no
 * serial port a person can reach without a special cable and a second
 * computer, so a kernel that says "no framebuffer on this machine, serial
 * only" over the serial port has said nothing at all - and "the kernel printed
 * an explanation nobody can read" is indistinguishable from "the kernel died
 * before it printed anything", which is the worst pair of outcomes to be
 * unable to tell apart on a first boot.
 *
 * So this goes to both. The same lines, through the framebuffer console as
 * well as the wire, and then presented - because writing into the back buffer
 * is not the same as putting it on the display, and on a machine with nothing
 * else to say the difference is the whole message.
 *
 * <h2>What is worth a line</h2>
 *
 * Only what was discovered rather than assumed. The exception level and the
 * CPU come out of registers and say whether the loader put us where it said it
 * would. The handover pointer says which of the two shapes arrived. The
 * framebuffer, the serial port and the watchdog are the three things read out
 * of the tree, and each is a place where an unfamiliar machine says "you are
 * looking for the wrong thing" by returning nothing.
 *
 * Anything absent prints as absent. That is the useful answer, not the missing
 * one: a line that is not there could always be a line that was never written.
 *
 * <h2>Staying on screen</h2>
 *
 * If there is a keyboard the editor starts and paints over this within a
 * moment, and the copy on the wire is the one that lasts. If there is not, the
 * report stays: the editor is an editor, a machine nobody can type at has
 * nothing to offer past this page, and a screen holding the addresses is worth
 * more than a screen holding an empty document. That is the expected first
 * boot on the target, where the keyboard is behind a USB stack that does not
 * exist yet.
 */

        CODE
        .p2align 2

/*
 * report_show - x0 = whatever arrived in x0 at boot.
 *
 * Called once the display is up and before anything that might fault, so that
 * a machine which dies later still has this on it.
 */
        .globl  SYM(report_show)
SYM(report_show):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        mov     x19, x0

        LEA     x0, m_head
        bl      report_puts

/* Where the loader left us, which is the first thing to be wrong about. */
        LEA     x0, m_el
        bl      report_puts
        mrs     x0, CurrentEL
        lsr     x0, x0, #2
        and     x0, x0, #3
        bl      report_dec
        bl      report_nl

        LEA     x0, m_cpu
        bl      report_puts
        mrs     x0, midr_el1
        bl      report_hex
        bl      report_nl

/*
 * The handover. Both shapes arrive in x0 and neither says which it is, so the
 * pointer and the answer are both printed: a wrong guess about this is a
 * kernel reading a framebuffer address out of something that is not one.
 */
        LEA     x0, m_hand
        bl      report_puts
        mov     x0, x19
        bl      report_hex
        LEA     x0, m_space
        bl      report_puts
        bl      SYM(bootargs_have)
        cbz     w0, 1f
        LEA     x0, m_bootargs
        b       2f
1:      LEA     x0, m_devtree
2:      bl      report_puts
        bl      report_nl

/* The screen this is being printed on, described by whoever handed it over. */
        LEA     x0, m_screen
        bl      report_puts
        LEA     x0, r_fb
        LEA     x1, r_w
        LEA     x2, r_h
        LEA     x3, r_stride
        LEA     x4, r_depth
        bl      SYM(screen_find)
        cmn     w0, #1
        b.ne    3f
/*
 * Nobody handed one over, and yet there is a picture: this is ramfb, which the
 * guest describes to QEMU rather than being told about. Saying "absent" here
 * would be true about the tree and a lie about the screen the sentence is
 * being printed on, and the two paths are different code - which one ran is
 * the fact worth carrying.
 */
        LEA     x0, m_ramfb
        bl      report_puts
        LEA     x0, r_fb
        LEA     x1, r_w
        LEA     x2, r_h
        bl      platform_fb
        LEA     x9, r_w
        ldr     w0, [x9]
        bl      report_dec
        LEA     x0, m_by
        bl      report_puts
        LEA     x9, r_h
        ldr     w0, [x9]
        bl      report_dec
        bl      report_nl
        b       4f
3:      LEA     x0, m_given
        bl      report_puts
        LEA     x9, r_fb
        ldr     x0, [x9]
        bl      report_hex
        LEA     x0, m_space
        bl      report_puts
        LEA     x9, r_w
        ldr     x0, [x9]
        bl      report_dec
        LEA     x0, m_by
        bl      report_puts
        LEA     x9, r_h
        ldr     x0, [x9]
        bl      report_dec
        LEA     x0, m_stride
        bl      report_puts
        LEA     x9, r_stride
        ldr     x0, [x9]
        bl      report_dec
        LEA     x0, m_depth
        bl      report_puts
        LEA     x9, r_depth
        ldr     x0, [x9]
        bl      report_dec
        bl      report_nl
4:

/* The serial port, and which kind - Apple's is not a PL011 and says so. */
        LEA     x0, m_serial
        bl      report_puts
        bl      SYM(uart_where)
        mov     x20, x0
        cbnz    x20, 5f
        LEA     x0, m_absent
        bl      report_puts
        bl      report_nl
        b       6f
5:      mov     x0, x20
        bl      report_hex
        LEA     x0, m_space
        bl      report_puts
        bl      SYM(uart_which)
        cmp     w0, #2
        b.ne    7f
        LEA     x0, m_s5l
        b       8f
7:      LEA     x0, m_pl011
8:      bl      report_puts
        bl      report_nl
6:

/* How this machine restarts, which is the first thing anybody will try. */
        LEA     x0, m_restart
        bl      report_puts
        LEA     x0, s_psci_02
        LEA     x1, s_method
        bl      report_psci
        cbnz    x0, 9f
        LEA     x0, s_psci_10
        LEA     x1, s_method
        bl      report_psci
9:      cbz     x0, 10f
        ldrb    w9, [x0]
        cmp     w9, #'s'
        b.ne    11f
        LEA     x0, m_smc
        b       12f
11:     LEA     x0, m_hvc
        b       12f
10:     bl      SYM(wdt_find)
        cbz     x0, 13f
        mov     x21, x0
        LEA     x0, m_wdt
        bl      report_puts
        mov     x0, x21
        bl      report_hex
        bl      report_nl
        b       14f
13:     LEA     x0, m_absent
12:     bl      report_puts
        bl      report_nl
14:

/* And whether anybody can type at it, which decides what happens next. */
        LEA     x0, m_keyboard
        bl      report_puts
        bl      platform_haskbd
        cbz     w0, 15f
        LEA     x0, m_yes
        b       16f
15:     LEA     x0, m_no
16:     bl      report_puts
        bl      report_nl

        bl      platform_present

        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * report_hold - stay on this page, because there is nothing else to show.
 *
 * Only reached on a machine with no keyboard. It is not a hang: a hang is a
 * machine that stopped without deciding to, and this one has decided. The
 * distinction matters to whoever is looking at it, which is why the last line
 * says so.
 */
        .globl  SYM(report_hold)
SYM(report_hold):
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LEA     x0, m_hold
        bl      report_puts
        bl      platform_present
1:      wfe
        b       1b

/*
 * report_psci - x0 = compatible, x1 = property. out x0 = its bytes, or 0.
 *
 * The same lookup platform_reboot makes, repeated here rather than shared,
 * because sharing it would mean exporting a function whose only other caller
 * is a diagnostic - and a reboot path with an extra entry point for the
 * benefit of a printout is a reboot path that is harder to be sure of.
 */
report_psci:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        mov     x2, x1
        mov     w1, #0
        bl      SYM(dtb_prop)
        ldp     x29, x30, [sp], #16
        ret

/* report_puts - x0 = a string, to the wire and to the glass both. */
report_puts:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     x19, x0
        bl      platform_puts
        mov     x0, x19
        bl      console_puts
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

report_nl:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LEA     x0, m_nl
        bl      report_puts
        ldp     x29, x30, [sp], #16
        ret

/*
 * report_hex - x0 as sixteen hex digits.
 *
 * Sixteen and not eight. On this machine an address is 0x40200000 and eight is
 * plenty; on the target, memory starts above the thirty-second bit and an
 * eight-digit print of a real address is a different number that looks
 * plausible. That is exactly the kind of wrong this page exists to prevent.
 */
report_hex:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     x19, x0
        LEA     x1, r_text
        mov     w2, #16
1:      sub     w2, w2, #1
        lsr     x9, x19, #60
        lsl     x19, x19, #4
        cmp     w9, #10
        b.lo    2f
        add     w9, w9, #('a' - 10)
        b       3f
2:      add     w9, w9, #'0'
3:      strb    w9, [x1]
        add     x1, x1, #1
        cbnz    w2, 1b
        strb    wzr, [x1]
        LEA     x0, r_text
        bl      report_puts
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/* report_dec - x0 in decimal, because a resolution in hex helps nobody. */
report_dec:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        LEA     x1, r_text
        add     x1, x1, #23
        strb    wzr, [x1]
        mov     x9, #10
4:      udiv    x10, x0, x9
        msub    x11, x10, x9, x0
        add     w11, w11, #'0'
        sub     x1, x1, #1
        strb    w11, [x1]
        mov     x0, x10
        cbnz    x0, 4b
        mov     x0, x1
        bl      report_puts
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

        RODATA
m_head:     .asciz "this machine\n"
m_el:       .asciz "  running at EL"
m_cpu:      .asciz "  cpu           "
m_hand:     .asciz "  handover      "
m_bootargs: .asciz "boot arguments"
m_devtree:  .asciz "device tree"
m_screen:   .asciz "  screen        "
m_serial:   .asciz "  serial        "
m_restart:  .asciz "  restart       "
m_keyboard: .asciz "  keyboard      "
m_wdt:      .asciz "watchdog at "
m_hvc:      .asciz "psci, hvc"
m_smc:      .asciz "psci, smc"
m_pl011:    .asciz "pl011"
m_s5l:      .asciz "apple s5l"
m_absent:   .asciz "absent"
m_ramfb:    .asciz "ramfb, asked for by this kernel, "
m_given:    .asciz "handed over at "
m_yes:      .asciz "yes"
m_no:       .asciz "no"
m_by:       .asciz "x"
m_stride:   .asciz ", stride "
m_depth:    .asciz ", depth "
m_space:    .asciz " "
m_nl:       .asciz "\n"
m_hold:     .asciz "\nnothing to type at. this page is the machine's answer.\n"
s_psci_02:  .asciz "arm,psci-0.2"
s_psci_10:  .asciz "arm,psci-1.0"
s_method:   .asciz "method"

        BSS
        .p2align 3
r_fb:     .space 8
r_w:      .space 8
r_h:      .space 8
r_stride: .space 8
r_depth:  .space 8
r_text:   .space 32
