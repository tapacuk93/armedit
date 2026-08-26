#include "asm.inc"
/*
 * console.S - a scrolling text console over the raw framebuffer.
 *
 * Characters are drawn by the shared rasterizer in font/render.S - the same
 * code the macOS window mode uses.  The kernel owns the pixels: there is no
 * text layer, no terminal emulator and no firmware print service underneath.
 */
#define FB_W            800
#define FB_H            600
#define CON_SCALE       3
#define CELL_W          (GLYPH_ADV * CON_SCALE)
#define CELL_H          ((GLYPH_H + 2) * CON_SCALE)
#define CON_COLS        (FB_W / CELL_W)
#define CON_ROWS        (FB_H / CELL_H)
#define COL_BG          0xFF141618
#define COL_FG          0xFF8AE2B8

        .section .text
        .p2align 2

/* console_init - clear the screen and home the cursor. */
        .globl  console_init
console_init:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LEA     x9, con_state
        str     wzr, [x9, #0]           /* column */
        str     wzr, [x9, #4]           /* row    */
        LEA     x0, SYM(framebuffer)
        mov     w1, #FB_W
        mov     w2, #0
        mov     w3, #0
        mov     w4, #FB_W
        mov     w5, #FB_H
        ldr     w6, =COL_BG
        bl      SYM(fb_fill)
        ldp     x29, x30, [sp], #16
        ret

/* console_putc - w0 = character. Handles '\n', wrapping and scrolling. */
        .globl  console_putc
console_putc:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     w19, w0

        cmp     w19, #'\n'
        b.eq    .Lnewline

        LEA     x9, con_state
        ldr     w10, [x9, #0]           /* column */
        cmp     w10, #CON_COLS
        b.lo    1f
        bl      .Lnewline_inner
1:
        LEA     x9, con_state
        ldr     w10, [x9, #0]
        ldr     w11, [x9, #4]
        mov     w12, #CELL_W            /* pixel origin of this cell */
        mul     w12, w10, w12
        mov     w13, #CELL_H
        mul     w13, w11, w13

        strb    w19, [sp, #24]          /* a one-character string on the stack */
        strb    wzr, [sp, #25]

        LEA     x0, SYM(framebuffer)
        mov     w1, #FB_W
        mov     w2, w12
        mov     w3, w13
        mov     w4, #CON_SCALE
        ldr     w5, =COL_FG
        add     x6, sp, #24
        bl      SYM(font_draw_text)

        LEA     x9, con_state           /* advance the cursor */
        ldr     w10, [x9, #0]
        add     w10, w10, #1
        str     w10, [x9, #0]
        b       .Lputc_out

.Lnewline:
        bl      .Lnewline_inner
.Lputc_out:
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/* Column 0 of the next row, scrolling if that would fall off the bottom. */
.Lnewline_inner:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LEA     x9, con_state
        str     wzr, [x9, #0]
        ldr     w10, [x9, #4]
        add     w10, w10, #1
        cmp     w10, #CON_ROWS
        b.lo    1f
        bl      console_scroll
        mov     w10, #(CON_ROWS - 1)
1:      LEA     x9, con_state
        str     w10, [x9, #4]
        ldp     x29, x30, [sp], #16
        ret

/* console_scroll - move the image up one text row and clear the last one. */
        .globl  console_scroll
console_scroll:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LEA     x0, SYM(framebuffer)
        mov     w1, #(CELL_H * FB_W)    /* pixels in one text row */
        ldr     w2, =(FB_W * FB_H)      /* too wide for a MOV immediate */
        sub     w2, w2, w1              /* pixels that survive the scroll */
        mov     w3, #0                  /* destination index */
1:      add     w4, w3, w1
        ldr     w5, [x0, w4, uxtw #2]
        str     w5, [x0, w3, uxtw #2]
        add     w3, w3, #1
        cmp     w3, w2
        b.lo    1b

        LEA     x0, SYM(framebuffer)    /* blank the freed row */
        mov     w1, #FB_W
        mov     w2, #0
        mov     w3, #(FB_H - CELL_H)
        mov     w4, #FB_W
        mov     w5, #CELL_H
        ldr     w6, =COL_BG
        bl      SYM(fb_fill)
        ldp     x29, x30, [sp], #16
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

/* console_geometry - w0 = framebuffer width, w1 = height. */
        .globl  console_geometry
console_geometry:
        mov     w0, #FB_W
        mov     w1, #FB_H
        ret

        .section .bss
        .p2align 4
        .globl  SYM(framebuffer)
SYM(framebuffer):
        .space  (FB_W * FB_H * 4)
con_state:
        .space  16                      /* column, row */
