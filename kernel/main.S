#include "asm.inc"
/*
 * main.S - kernel entry proper: bring up the display, say hello.
 */
        .section .text
        .p2align 2
        .globl  kmain
kmain:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp

        LEA     x0, m_boot
        bl      uart_puts

        LEA     x0, SYM(framebuffer)    /* hand our buffer to the scanout */
        bl      console_geometry_args
        bl      ramfb_init
        tbnz    w0, #31, .Lno_display

        bl      console_init
        LEA     x0, m_banner
        bl      console_puts
        LEA     x0, m_ready
        bl      uart_puts
        b       .Lidle

.Lno_display:
        LEA     x0, m_nofb
        bl      uart_puts
.Lidle:
        ldp     x29, x30, [sp], #16
        ret

/* helper: fill w1/w2 with the console's framebuffer geometry, keeping x0 */
console_geometry_args:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     x19, x0
        bl      console_geometry
        mov     w2, w1
        mov     w1, w0
        mov     x0, x19
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

        .section .rodata
m_boot:   .asciz "asmedit: boot\n"
m_ready:  .asciz "asmedit: display up\n"
m_nofb:   .asciz "asmedit: no ramfb device, serial only\n"
m_banner: .asciz "ASMEDIT KERNEL\nHELLO WORLD\nBARE METAL AARCH64.\nNO OS UNDER THIS."
