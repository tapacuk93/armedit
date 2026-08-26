#include "asm.inc"
/*
 * main.S - what the kernel does, as opposed to what the machine is.
 *
 * Nothing in this file names a register block, a peripheral or an
 * instruction-set feature.  It asks the port layer to bring up a display and
 * then uses the same console, font and rasterizer the desktop and phone
 * builds use.  Porting to another CPU means rewriting kernel/arch/<cpu>/ and
 * transliterating files like this one - not redesigning them.
 */
        .section .text
        .p2align 2
        .globl  kmain
kmain:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp

        LEA     x0, m_boot
        bl      platform_puts

        bl      platform_init           /* a display, if this machine has one */
        tbnz    w0, #31, .Lno_display
        bl      console_init
        tbnz    w0, #31, .Lno_display

        LEA     x0, m_banner
        bl      console_puts
        LEA     x0, m_ready
        bl      platform_puts
        b       .Lidle

.Lno_display:
        LEA     x0, m_nofb              /* serial only is a valid outcome */
        bl      platform_puts
.Lidle:
        ldp     x29, x30, [sp], #16
        ret

        .section .rodata
m_boot:   .asciz "asmedit: boot\n"
m_ready:  .asciz "asmedit: display up\n"
m_nofb:   .asciz "asmedit: no framebuffer on this machine, serial only\n"
m_banner: .asciz "ASMEDIT KERNEL\nHELLO WORLD\nBARE METAL AARCH64.\nNO OS UNDER THIS."
