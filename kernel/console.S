#include "asm.inc"
/*
 * console.S - a scrolling text console over whatever the machine draws on.
 *
 * Characters are drawn by the shared rasterizer in font/render.S - the same
 * code the macOS window and the iPhone use.  The kernel owns the pixels:
 * there is no text layer, no terminal emulator and no firmware print service
 * underneath.
 *
 * Nothing here knows what board it is on.  The framebuffer arrives from
 * platform_fb and its size decides the grid, so this file is unchanged on any
 * port that supplies one - see kernel/PORTING.md.
 */
#define CON_SCALE       3
#define CELL_W          (GLYPH_ADV * CON_SCALE)
#define CELL_H          ((GLYPH_H + 2) * CON_SCALE)
#define COL_BG          0xFF141618
#define COL_FG          0xFF8AE2B8

/* con_state */
#define CS_BASE         0
#define CS_W            8
#define CS_H            12
#define CS_COLS         16
#define CS_ROWS         20
#define CS_COL          24
#define CS_ROW          28
#define CS_SZ           32

        .section .text
        .p2align 2

/*
 * console_init - find out what we are drawing on, work out the grid, clear it.
 *   out w0 = 0, or -1 if this machine has no framebuffer
 */
        .globl  console_init
console_init:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]

        LEA     x19, con_state
        add     x0, x19, #CS_BASE
        add     x1, x19, #CS_W
        add     x2, x19, #CS_H
        bl      platform_fb

        ldr     x9, [x19, #CS_BASE]
        cbz     x9, .Lcon_none
        ldr     w10, [x19, #CS_W]
        ldr     w11, [x19, #CS_H]
        cbz     w10, .Lcon_none
        cbz     w11, .Lcon_none

        mov     w12, #CELL_W            /* the grid this surface gives us */
        udiv    w12, w10, w12
        str     w12, [x19, #CS_COLS]
        mov     w12, #CELL_H
        udiv    w12, w11, w12
        str     w12, [x19, #CS_ROWS]
        str     wzr, [x19, #CS_COL]
        str     wzr, [x19, #CS_ROW]

        mov     x0, x9
        mov     w1, w10
        mov     w2, #0
        mov     w3, #0
        mov     w4, w10
        mov     w5, w11
        ldr     w6, =COL_BG
        bl      SYM(fb_fill)
        mov     w0, #0
        b       .Lcon_out
.Lcon_none:
        mov     w0, #-1
.Lcon_out:
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* console_putc - w0 = character.  Handles '\n', wrapping and scrolling. */
        .globl  console_putc
console_putc:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     w19, w0
        LEA     x20, con_state
        ldr     x9, [x20, #CS_BASE]
        cbz     x9, .Lputc_out

        cmp     w19, #'\n'
        b.eq    .Lnewline

        ldr     w10, [x20, #CS_COL]
        ldr     w11, [x20, #CS_COLS]
        cmp     w10, w11
        b.lo    1f
        bl      console_newline
1:
        ldr     w10, [x20, #CS_COL]
        ldr     w11, [x20, #CS_ROW]
        mov     w12, #CELL_W
        mul     w12, w10, w12
        mov     w13, #CELL_H
        mul     w13, w11, w13

        strb    w19, [sp, #40]          /* a one-character string */
        strb    wzr, [sp, #41]

        ldr     x0, [x20, #CS_BASE]
        ldr     w1, [x20, #CS_W]
        mov     w2, w12
        mov     w3, w13
        mov     w4, #CON_SCALE
        ldr     w5, =COL_FG
        add     x6, sp, #40
        bl      SYM(font_draw_text)

        ldr     w10, [x20, #CS_COL]
        add     w10, w10, #1
        str     w10, [x20, #CS_COL]
        b       .Lputc_out
.Lnewline:
        bl      console_newline
.Lputc_out:
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* console_newline - column zero of the next row, scrolling at the bottom. */
        .globl  console_newline
console_newline:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        LEA     x19, con_state
        str     wzr, [x19, #CS_COL]
        ldr     w9, [x19, #CS_ROW]
        add     w9, w9, #1
        ldr     w10, [x19, #CS_ROWS]
        cmp     w9, w10
        b.lo    1f
        bl      console_scroll
        ldr     w10, [x19, #CS_ROWS]
        sub     w9, w10, #1
1:      str     w9, [x19, #CS_ROW]
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/* console_scroll - move the image up one text row and clear the last one. */
        .globl  console_scroll
console_scroll:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        LEA     x19, con_state
        ldr     x0, [x19, #CS_BASE]
        ldr     w1, [x19, #CS_W]
        ldr     w2, [x19, #CS_H]

        mov     w3, #CELL_H             /* pixels in one text row */
        mul     w3, w3, w1
        mul     w4, w1, w2              /* pixels in the whole surface */
        sub     w4, w4, w3              /* what survives the scroll */
        mov     w5, #0
1:      add     w6, w5, w3
        ldr     w7, [x0, w6, uxtw #2]
        str     w7, [x0, w5, uxtw #2]
        add     w5, w5, #1
        cmp     w5, w4
        b.lo    1b

        ldr     x0, [x19, #CS_BASE]     /* blank the row that freed up */
        ldr     w1, [x19, #CS_W]
        ldr     w9, [x19, #CS_H]
        mov     w2, #0
        mov     w3, #CELL_H
        sub     w3, w9, w3
        mov     w4, w1
        mov     w5, #CELL_H
        ldr     w6, =COL_BG
        bl      SYM(fb_fill)

        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* console_puts - x0 = NUL-terminated string. */
        .globl  console_puts
console_puts:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     x19, x0
1:      ldrb    w0, [x19], #1
        cbz     w0, 2f
        bl      console_putc
        b       1b
2:      ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

        .section .bss
        .p2align 4
con_state:
        .space  CS_SZ
