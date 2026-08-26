#include "asm.inc"
/*
 * uart.S - PL011 serial output, polled.
 *
 * The `virt` machine puts a PL011 at 0x09000000.  Two registers matter: DR to
 * push a byte out, and FR bit 5 (TXFF) telling us the FIFO is full.  This is
 * the kernel's only debug channel before the framebuffer is alive.
 */
#define UART_BASE       0x09000000
#define UART_DR         0x00
#define UART_FR         0x18
#define UART_FR_TXFF    5               /* bit index */

        .section .text
        .p2align 2

        .globl  uart_putc
uart_putc:
        mov     x1, #UART_BASE
1:      ldr     w2, [x1, #UART_FR]
        tbnz    w2, #UART_FR_TXFF, 1b   /* spin while the TX FIFO is full */
        strb    w0, [x1, #UART_DR]
        ret

        .globl  uart_puts
uart_puts:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     x19, x0
1:      ldrb    w0, [x19], #1
        cbz     w0, 2f
        cmp     w0, #'\n'
        b.ne    3f
        mov     w0, #'\r'               /* serial wants CR before LF */
        bl      uart_putc
        mov     w0, #'\n'
3:      bl      uart_putc
        b       1b
2:      ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/* uart_puthex - w0 as 8 hex digits, for poking at registers. */
        .globl  uart_puthex
uart_puthex:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     w19, w0
        mov     w20, #28
1:      lsr     w0, w19, w20
        and     w0, w0, #0xF
        cmp     w0, #10
        b.lo    2f
        add     w0, w0, #('A' - 10)
        b       3f
2:      add     w0, w0, #'0'
3:      bl      uart_putc
        subs    w20, w20, #4
        b.ge    1b
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret
