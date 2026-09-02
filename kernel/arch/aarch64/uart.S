#include "asm.inc"
/*
 * uart.S - PL011 serial output, polled.
 *
 * The `virt` machine puts a PL011 at 0x09000000.  Two registers matter: DR to
 * push a byte out, and FR bit 5 (TXFF) telling us the FIFO is full.  This is
 * the kernel's only debug channel before the framebuffer is alive.
 */
/*
 * Where the PL011 is when there is one.
 *
 * The `virt` machine puts it here. Other machines put it elsewhere, and macOS's
 * Virtualization framework has none at all - where writing to this address is
 * a store to unmapped memory, which with the MMU off is a data abort. So the
 * address is asked for, and "no PL011" is an answer this file now has a way to
 * give.
 */
#define UART_BASE       0x09000000

/*
 * And the other serial port this kernel may find.
 *
 * Apple's is not a PL011. It is the s5l, inherited from the iPhone, and it
 * disagrees about everything: different registers, different bits, different
 * polarity of the one that says whether a byte can be written. Two registers
 * matter - UTRSTAT to ask, UTXH to send - and getting the wrong chip's offsets
 * means writing a character into a control register, which on a serial port is
 * how you reconfigure the baud rate by accident.
 *
 * Which one is present comes from the device tree, so nothing here has to
 * guess and a machine with neither is a machine that says so.
 */
#define S5L_UTRSTAT     0x10
#define S5L_UTXH        0x20
#define S5L_URXH        0x24
#define S5L_RXD         0               /* bit: something to read */
#define S5L_TXBE        1               /* bit: room to write */

#define UART_NONE       0
#define UART_PL011      1
#define UART_S5L        2
#define UART_DR         0x00
#define UART_FR         0x18
#define UART_FR_TXFF    5               /* bit index */
#define UART_FR_RXFE    4

        CODE
        .p2align 2

/*
 * uart_where - out x0 = the PL011's address, or 0 if this machine has none.
 *
 * Asked once. A machine with no tree gets the historical address, because a
 * kernel loaded as an ELF is told nothing and has always been on QEMU.
 */
/*
 * uart_forget - ask again next time.
 *
 * The address is worked out once and kept, which is right on a machine that
 * boots once and wrong in a test that hands it several. Nothing in the kernel
 * calls this.
 */
        .globl  SYM(uart_forget)
SYM(uart_forget):
        LEA     x9, uart_addr
        str     xzr, [x9]
        LEA     x9, uart_kind
        str     wzr, [x9]
        ret

/* uart_which - out w0 = which sort of serial port was found. */
        .globl  SYM(uart_which)
SYM(uart_which):
        LEA     x9, uart_kind
        ldr     w0, [x9]
        ret

        .globl  SYM(uart_where)
SYM(uart_where):
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LEA     x9, uart_addr
        ldr     x0, [x9]
        cbnz    x0, 9f
        bl      SYM(dtb_have)
        cbnz    w0, 1f
        mov     x0, #UART_BASE          /* no tree: the way it always was */
        LEA     x9, uart_kind
        mov     w10, #UART_PL011
        str     w10, [x9]
        b       2f
1:      LEA     x0, s_c_pl011
        mov     w1, #0
        bl      SYM(dtb_reg)
        cbz     x0, 4f
        LEA     x9, uart_kind
        mov     w10, #UART_PL011
        str     w10, [x9]
        b       2f
/*
 * No PL011, so try the other one this kernel can drive.
 *
 * An Apple machine has an s5l, which is a different chip with different
 * registers - see the definitions above. Asking the tree for both is what lets
 * one binary boot on a board with either.
 */
4:      LEA     x0, s_c_s5l
        mov     w1, #0
        bl      SYM(dtb_reg)
        cbz     x0, 2f
        LEA     x9, uart_kind
        mov     w10, #UART_S5L
        str     w10, [x9]
2:      LEA     x9, uart_addr           /* recomputed: the calls ate x9-x15 */
        cbnz    x0, 3f
        mov     x1, #1                  /* remember "none" as something */
        str     x1, [x9]
        mov     x0, #0
        b       9f
3:      str     x0, [x9]
9:      LEA     x9, uart_addr
        ldr     x0, [x9]
        cmp     x0, #1
        csel    x0, xzr, x0, eq
        ldp     x29, x30, [sp], #16
        ret

        .globl  SYM(uart_putc)
SYM(uart_putc):
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     w19, w0
        bl      SYM(uart_where)
        mov     x1, x0
        cbz     x1, 8f
        mov     w0, w19
        bl      uart_putc_at
8:      ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/* uart_putc_at - w0 = a byte, x1 = wherever the serial port turned out to be. */
uart_putc_at:
        LEA     x3, uart_kind
        ldr     w3, [x3]
        cmp     w3, #UART_S5L
        b.eq    2f
1:      ldr     w2, [x1, #UART_FR]
        tbnz    w2, #UART_FR_TXFF, 1b   /* spin while the TX FIFO is full */
        strb    w0, [x1, #UART_DR]
        ret
/*
 * The Apple one waits for room rather than for the absence of fullness, which
 * is the same thing said the other way round and the reason these cannot share
 * a loop: TXBE set means send, where TXFF set means wait.
 */
2:      ldr     w2, [x1, #S5L_UTRSTAT]
        tbz     w2, #S5L_TXBE, 2b
        str     w0, [x1, #S5L_UTXH]
        ret

        .globl  SYM(uart_puts)
SYM(uart_puts):
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     x19, x0
1:      ldrb    w0, [x19], #1
        cbz     w0, 2f
        cmp     w0, #'\n'
        b.ne    3f
        mov     w0, #'\r'               /* serial wants CR before LF */
        bl      SYM(uart_putc)
        mov     w0, #'\n'
3:      bl      SYM(uart_putc)
        b       1b
2:      ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/*
 * uart_getc - one byte if the receiver has one, otherwise -1.
 * RXFE (bit 4 of FR) is clear when there is something to read.
 */
        .globl  SYM(uart_getc)
SYM(uart_getc):
        stp     x29, x30, [sp, #-16]!   /* it calls something, so it has a frame:
                                           without one the ret goes back into
                                           this function and stays there */
        mov     x29, sp
        bl      SYM(uart_where)              /* this machine may have none */
        mov     x1, x0
        cbz     x1, 1f
        LEA     x3, uart_kind
        ldr     w3, [x3]
        cmp     w3, #UART_S5L
        b.eq    2f
        ldr     w2, [x1, #UART_FR]
        tbnz    w2, #UART_FR_RXFE, 1f
        ldrb    w0, [x1, #UART_DR]
        ldp     x29, x30, [sp], #16
        ret
2:      ldr     w2, [x1, #S5L_UTRSTAT]
        tbz     w2, #S5L_RXD, 1f
        ldr     w0, [x1, #S5L_URXH]
        and     w0, w0, #0xFF
        ldp     x29, x30, [sp], #16
        ret
1:      mov     w0, #-1
        ldp     x29, x30, [sp], #16
        ret

/* uart_puthex - w0 as 8 hex digits, for poking at registers. */
        .globl  SYM(uart_puthex)
SYM(uart_puthex):
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
3:      bl      SYM(uart_putc)
        subs    w20, w20, #4
        b.ge    1b
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

        RODATA
s_c_pl011: .asciz "arm,pl011"
s_c_s5l:   .asciz "apple,s5l-uart"

        BSS
        .p2align 3
uart_addr: .space 8
uart_kind: .space 4
