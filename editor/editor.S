#include "asm.inc"
#include "editor.inc"
/*
 * editor.S - the editor itself: screens, a text buffer per screen, a cursor,
 * and the drawing of all of it.
 *
 * This file knows nothing about macOS or about bare metal.  It is handed
 * translated keys and a pixel buffer, which is why the identical object code
 * backs both front ends.
 *
 * Each screen is a flat byte buffer with the cursor as an index into it.
 * Inserting memmoves the tail - for 8K of text that costs less than the frame
 * it is drawn in, and it keeps the representation honest and inspectable.
 */
        CODE
        .p2align 2

/* ---------------------------------------------------------------- helpers */

/* cur_screen_ptr -> x0 */
ed_cur:
        LEA     x9, ed_state
        ldr     w10, [x9, #0]           /* current screen index */
        mov     w11, #SCR_STRIDE
        mul     w10, w10, w11
        LEA     x0, ed_screens
        add     x0, x0, w10, uxtw
        ret

/* editor_init - one empty screen, cursor at the top. */
        .globl  SYM(editor_init)
SYM(editor_init):
        LEA     x9, ed_state
        str     wzr, [x9, #0]           /* current = 0 */
        mov     w10, #1
        str     w10, [x9, #4]           /* count = 1  */
        LEA     x0, ed_screens
        str     wzr, [x0, #SCR_LEN_OFF]
        str     wzr, [x0, #SCR_CUR_OFF]
        str     wzr, [x0, #SCR_SCROLL_OFF]
        str     wzr, [x0, #SCR_BASELEN_OFF]
        ret

/* editor_screen_info - w0 = current index, w1 = count */
        .globl  SYM(editor_screen_info)
SYM(editor_screen_info):
        LEA     x9, ed_state
        ldr     w0, [x9, #0]
        ldr     w1, [x9, #4]
        ret

/* ------------------------------------------------------------ text editing */

/* ed_insert - w0 = byte to insert at the cursor */
ed_insert:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     w19, w0
        bl      ed_cur
        ldr     w9, [x0, #SCR_LEN_OFF]
        ldr     w10, [x0, #SCR_CUR_OFF]
        mov     w11, #(SCR_BUF_SZ - 1)
        cmp     w9, w11
        b.hs    1f                      /* buffer full: drop the keystroke */
        add     x12, x0, #SCR_TEXT_OFF
        mov     w13, w9                 /* shift [cur..len) up one, backwards */
2:      cmp     w13, w10
        b.ls    3f
        sub     w14, w13, #1
        ldrb    w15, [x12, w14, uxtw]
        strb    w15, [x12, w13, uxtw]
        sub     w13, w13, #1
        b       2b
3:      strb    w19, [x12, w10, uxtw]
        add     w9, w9, #1
        add     w10, w10, #1
        str     w9, [x0, #SCR_LEN_OFF]
        str     w10, [x0, #SCR_CUR_OFF]
1:      ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/* ed_backspace - delete the byte before the cursor */
ed_backspace:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        bl      ed_cur
        ldr     w9, [x0, #SCR_LEN_OFF]
        ldr     w10, [x0, #SCR_CUR_OFF]
        cbz     w10, 1f
        add     x12, x0, #SCR_TEXT_OFF
        mov     w13, w10
2:      cmp     w13, w9
        b.hs    3f
        sub     w14, w13, #1
        ldrb    w15, [x12, w13, uxtw]
        strb    w15, [x12, w14, uxtw]
        add     w13, w13, #1
        b       2b
3:      sub     w9, w9, #1
        sub     w10, w10, #1
        str     w9, [x0, #SCR_LEN_OFF]
        str     w10, [x0, #SCR_CUR_OFF]
1:      ldp     x29, x30, [sp], #16
        ret

/* ----------------------------------------------------------- screen switch */

/* ed_screen_new - append a fresh screen and switch to it */
ed_screen_new:
        LEA     x9, ed_state
        ldr     w10, [x9, #4]           /* count */
        cmp     w10, #MAX_SCREENS
        b.hs    1f
        mov     w11, #SCR_STRIDE
        mul     w12, w10, w11
        LEA     x13, ed_screens
        add     x13, x13, w12, uxtw
        str     wzr, [x13, #SCR_LEN_OFF]
        str     wzr, [x13, #SCR_CUR_OFF]
        str     wzr, [x13, #SCR_SCROLL_OFF]
        str     wzr, [x13, #SCR_BASELEN_OFF]
        str     w10, [x9, #0]           /* make it current */
        add     w10, w10, #1
        str     w10, [x9, #4]
1:      ret

/* ed_screen_close - drop the current screen; the last one is never closed */
ed_screen_close:
        LEA     x9, ed_state
        ldr     w0, [x9, #0]            /* current */
        ldr     w1, [x9, #4]            /* count   */
        cmp     w1, #2
        b.lo    9f
        mov     w2, #SCR_STRIDE
        mul     w3, w0, w2              /* byte offset of current */
        LEA     x4, ed_screens
        add     x5, x4, w3, uxtw        /* dst */
        add     w6, w0, #1
1:      cmp     w6, w1                  /* slide the later screens down */
        b.hs    2f
        mul     w7, w6, w2
        add     x10, x4, w7, uxtw       /* src */
        mov     w11, #0
3:      ldr     w12, [x10, w11, uxtw]
        str     w12, [x5, w11, uxtw]
        add     w11, w11, #4
        cmp     w11, w2
        b.lo    3b
        add     x5, x5, w2, uxtw
        add     w6, w6, #1
        b       1b
2:      sub     w1, w1, #1
        str     w1, [x9, #4]
        cmp     w0, w1
        b.lo    4f
        sub     w0, w1, #1
4:      str     w0, [x9, #0]
9:      ret

/* ed_screen_step - w0 = +1 or -1, wrapping */
ed_screen_step:
        LEA     x9, ed_state
        ldr     w1, [x9, #0]
        ldr     w2, [x9, #4]
        add     w1, w1, w0
        cmp     w1, #0
        b.ge    1f
        sub     w1, w2, #1              /* wrap to the last screen */
1:      cmp     w1, w2
        b.lo    2f
        mov     w1, #0                  /* wrap to the first */
2:      str     w1, [x9, #0]
        ret

/* ------------------------------------------------------------ key dispatch */

/*
 * editor_key - w0 = key code, optionally OR'd with MOD_CMD.
 * The command set the user asked for:
 *   Cmd + Left / Right   previous / next screen
 *   Cmd + T              new screen
 *   Cmd + Backspace      close this screen
 *   Cmd + Enter          hand this screen to the backend
 *   Cmd + Up / Down      page up / page down
 *   Cmd + P              rewrite what is on screen, in place
 *
 * Returns ED_NONE, ED_SUBMIT or ED_AIFY.  The editor core does no I/O: the
 * front end owns the network, and neither of them knows what is on the far
 * side of the backend.
 */
        .globl  SYM(editor_key)
SYM(editor_key):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     w19, w0
        mov     w20, #ED_NONE           /* what to tell the front end */

        tst     w19, #MOD_CMD
        b.eq    .Lplain

        and     w19, w19, #0xFFF        /* strip the modifier */
        mov     w9, #K_LEFT
        cmp     w19, w9
        b.ne    1f
        mov     w0, #-1
        bl      ed_screen_step
        b       .Lkey_out
1:      mov     w9, #K_RIGHT
        cmp     w19, w9
        b.ne    1f
        mov     w0, #1
        bl      ed_screen_step
        b       .Lkey_out
1:      mov     w9, #K_UP
        cmp     w19, w9
        b.ne    1f
        mov     w0, #-1
        bl      ed_page
        b       .Lkey_out
1:      mov     w9, #K_DOWN
        cmp     w19, w9
        b.ne    2f
        mov     w0, #1
        bl      ed_page
        b       .Lkey_out
2:      cmp     w19, #'t'
        b.eq    3f
        cmp     w19, #'T'
        b.ne    2f
3:      bl      ed_screen_new
        b       .Lkey_out
2:      cmp     w19, #'p'
        b.eq    .Laify
        cmp     w19, #'P'
        b.ne    4f
.Laify: mov     w20, #ED_AIFY
        b       .Lkey_out
4:      cmp     w19, #K_ENTER
        b.eq    .Lsubmit
        cmp     w19, #0x0D
        b.eq    .Lsubmit
        cmp     w19, #K_BS
        b.eq    5f
        cmp     w19, #0x7F              /* macOS sends DEL for Backspace */
        b.ne    .Lkey_out
5:      bl      ed_screen_close
        b       .Lkey_out
.Lsubmit:
        mov     w20, #ED_SUBMIT
        b       .Lkey_out

.Lplain:
        cmp     w19, #K_BS
        b.eq    .Lback
        cmp     w19, #0x7F
        b.eq    .Lback
        mov     w9, #K_LEFT
        cmp     w19, w9
        b.eq    .Lcurs_left
        mov     w9, #K_RIGHT
        cmp     w19, w9
        b.eq    .Lcurs_right
        mov     w9, #K_UP
        cmp     w19, w9
        b.eq    .Lcurs_up
        mov     w9, #K_DOWN
        cmp     w19, w9
        b.eq    .Lcurs_down
        cmp     w19, #0x0D              /* CR from a terminal */
        b.ne    6f
        mov     w19, #K_ENTER
6:      cmp     w19, #K_ENTER
        b.eq    7f
        cmp     w19, #0x20              /* anything else must be printable */
        b.lo    .Lkey_out
        cmp     w19, #0x7E
        b.hi    .Lkey_out
7:      mov     w0, w19
        bl      ed_insert
        b       .Lkey_out

.Lback: bl      ed_backspace
        b       .Lkey_out

.Lcurs_left:
        bl      ed_cur
        ldr     w9, [x0, #SCR_CUR_OFF]
        cbz     w9, .Lkey_out
        sub     w9, w9, #1
        str     w9, [x0, #SCR_CUR_OFF]
        b       .Lkey_out
.Lcurs_right:
        bl      ed_cur
        ldr     w9, [x0, #SCR_CUR_OFF]
        ldr     w10, [x0, #SCR_LEN_OFF]
        cmp     w9, w10
        b.hs    .Lkey_out
        add     w9, w9, #1
        str     w9, [x0, #SCR_CUR_OFF]
        b       .Lkey_out
.Lcurs_up:
        mov     w0, #-1
        bl      ed_cursor_line
        b       .Lkey_out
.Lcurs_down:
        mov     w0, #1
        bl      ed_cursor_line

.Lkey_out:
        mov     w0, w20
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * ed_page - move the cursor a screenful, w0 = -1 (up) or +1 (down).
 * A page is however many rows the last render fitted, less one line of
 * overlap so the reader keeps their place.
 */
ed_page:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     w19, w0
        LEA     x9, ed_state
        ldr     w20, [x9, #12]          /* visible rows */
        cmp     w20, #2
        b.hs    1f
        mov     w20, #2
1:      sub     w20, w20, #1
2:      cbz     w20, 3f
        mov     w0, w19
        bl      ed_cursor_line
        sub     w20, w20, #1
        b       2b
3:      ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * ed_cursor_line - move the cursor one display line, w0 = -1 or +1.
 * Lines are delimited by '\n'; the column is preserved where the target line
 * is long enough, clamped to its end where it is not.
 */
ed_cursor_line:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     w19, w0
        bl      ed_cur
        mov     x20, x0
        add     x21, x20, #SCR_TEXT_OFF
        ldr     w22, [x20, #SCR_CUR_OFF]
        ldr     w9, [x20, #SCR_LEN_OFF]

        mov     w10, w22                /* find the start of this line */
1:      cbz     w10, 2f
        sub     w11, w10, #1
        ldrb    w12, [x21, w11, uxtw]
        cmp     w12, #'\n'
        b.eq    2f
        sub     w10, w10, #1
        b       1b
2:      sub     w13, w22, w10           /* column */

        cmp     w19, #0
        b.gt    .Ldown

        cbz     w10, .Lline_out         /* already on the first line */
        sub     w14, w10, #1            /* end of the previous line */
        mov     w15, w14
3:      cbz     w15, 4f
        sub     w11, w15, #1
        ldrb    w12, [x21, w11, uxtw]
        cmp     w12, #'\n'
        b.eq    4f
        sub     w15, w15, #1
        b       3b
4:      sub     w16, w14, w15           /* length of that line */
        cmp     w13, w16
        csel    w13, w13, w16, lo
        add     w22, w15, w13
        b       .Lline_store

.Ldown:
        mov     w15, w22                /* find the start of the next line */
5:      cmp     w15, w9
        b.hs    .Lline_out
        ldrb    w12, [x21, w15, uxtw]
        add     w15, w15, #1
        cmp     w12, #'\n'
        b.ne    5b
        mov     w16, #0                 /* its length */
        mov     w17, w15
6:      cmp     w17, w9
        b.hs    7f
        ldrb    w12, [x21, w17, uxtw]
        cmp     w12, #'\n'
        b.eq    7f
        add     w16, w16, #1
        add     w17, w17, #1
        b       6b
7:      cmp     w13, w16
        csel    w13, w13, w16, lo
        add     w22, w15, w13

.Lline_store:
        str     w22, [x20, #SCR_CUR_OFF]
.Lline_out:
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * editor_insert_str - x0 = NUL-terminated text, inserted at the cursor.
 * Used to seed a screen and, later, to drop Claude's replies into the buffer.
 */
        .globl  SYM(editor_insert_str)
SYM(editor_insert_str):
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     x19, x0
1:      ldrb    w0, [x19], #1
        cbz     w0, 2f
        bl      ed_insert
        b       1b
2:      ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/*
 * editor_click - put the cursor where the pointer is.
 *   w0 = x in pixels, w1 = y in pixels, both in the editor's own surface
 * A click in the screen bar selects that screen instead.
 */
        .globl  SYM(editor_click)
SYM(editor_click):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]
        mov     w19, w0
        mov     w20, w1

        cmp     w20, #ED_BAR_H
        b.hs    .Lclick_text
        mov     w9, #(10 * ED_CELL_W)   /* the digits start after the brand */
        subs    w9, w19, w9
        b.mi    .Lclick_out
        mov     w10, #(2 * ED_CELL_W)
        udiv    w9, w9, w10             /* which digit was hit */
        bl      SYM(editor_screen_info) /* w0 = current, w1 = count */
        cmp     w9, w1
        b.hs    .Lclick_out
        LEA     x10, ed_state
        str     w9, [x10, #0]
        b       .Lclick_out

.Lclick_text:
        bl      ed_cur
        mov     x21, x0
        LEA     x10, ed_state
        ldr     w11, [x10, #8]          /* scroll */
        ldr     w12, [x10, #16]         /* columns */
        cbz     w12, .Lclick_out
        sub     w13, w20, #ED_BAR_H
        mov     w14, #ED_CELL_H
        udiv    w13, w13, w14
        add     w13, w13, w11           /* target row */
        mov     w14, #ED_CELL_W
        udiv    w14, w19, w14           /* target column */

        ldr     w15, [x21, #SCR_LEN_OFF]
        add     x16, x21, #SCR_TEXT_OFF
        mov     w9, #0                  /* index */
        mov     w10, #0                 /* row   */
        mov     w17, #0                 /* col   */
1:      cmp     w9, w15
        b.hs    2f
        cmp     w10, w13
        b.hi    2f
        b.lo    3f
        cmp     w17, w14                /* on the target row, at the column? */
        b.hs    2f
3:      ldrb    w0, [x16, w9, uxtw]
        add     w9, w9, #1
        cmp     w0, #'\n'
        b.ne    4f
        cmp     w10, w13
        b.eq    5f                      /* line ended before that column */
        add     w10, w10, #1
        mov     w17, #0
        b       1b
4:      add     w17, w17, #1
        cmp     w17, w12
        b.lo    1b
        mov     w17, #0
        add     w10, w10, #1
        b       1b
5:      sub     w9, w9, #1              /* park before the newline */
2:      str     w9, [x21, #SCR_CUR_OFF]

.Lclick_out:
        ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * editor_baseline - copy the snapshot the backend last saw.
 *   x0 = destination, w1 = capacity; out w0 = bytes copied
 */
        .globl  SYM(editor_baseline)
SYM(editor_baseline):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]
        mov     x19, x0
        mov     w20, w1
        bl      ed_cur
        ldr     w9, [x0, #SCR_BASELEN_OFF]
        sub     w10, w20, #1
        cmp     w9, w10
        csel    w9, w9, w10, lo
        mov     w13, #SCR_BASE_OFF      /* too wide for an ADD immediate */
        add     x21, x0, w13, uxtw
        mov     w11, #0
1:      cmp     w11, w9
        b.hs    2f
        ldrb    w12, [x21, w11, uxtw]
        strb    w12, [x19, w11, uxtw]
        add     w11, w11, #1
        b       1b
2:      strb    wzr, [x19, w11, uxtw]
        mov     w0, w11
        ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * editor_mark_synced - the backend has now seen the current text; make it the
 * baseline, so the next Cmd+P describes the edit since this moment.
 */
        .globl  SYM(editor_mark_synced)
SYM(editor_mark_synced):
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        bl      ed_cur
        ldr     w9, [x0, #SCR_LEN_OFF]
        add     x10, x0, #SCR_TEXT_OFF
        mov     w14, #SCR_BASE_OFF
        add     x11, x0, w14, uxtw
        mov     w12, #0
1:      cmp     w12, w9
        b.hs    2f
        ldrb    w13, [x10, w12, uxtw]
        strb    w13, [x11, w12, uxtw]
        add     w12, w12, #1
        b       1b
2:      str     w9, [x0, #SCR_BASELEN_OFF]
        ldp     x29, x30, [sp], #16
        ret

/* editor_view - w0 = first visible row, w1 = visible row count */
        .globl  SYM(editor_view)
SYM(editor_view):
        LEA     x9, ed_state
        ldr     w0, [x9, #8]
        ldr     w1, [x9, #12]
        ret

/*
 * editor_screen_set - replace the current screen's text with x0, cursor home.
 * This is what Cmd+P's answer lands in.
 */
        .globl  SYM(editor_screen_set)
SYM(editor_screen_set):
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     x19, x0
        bl      ed_cur
        str     wzr, [x0, #SCR_LEN_OFF]
        str     wzr, [x0, #SCR_CUR_OFF]
        str     wzr, [x0, #SCR_SCROLL_OFF]
        mov     x0, x19
        bl      SYM(editor_insert_str)
        bl      ed_cur
        str     wzr, [x0, #SCR_CUR_OFF]
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/*
 * editor_context - copy the current screen's text out for Claude.
 *   x0 = destination, w1 = capacity (NUL is always written)
 *   out w0 = bytes copied
 */
        .globl  SYM(editor_context)
SYM(editor_context):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]
        mov     x19, x0
        mov     w20, w1
        bl      ed_cur
        ldr     w9, [x0, #SCR_LEN_OFF]
        sub     w10, w20, #1
        cmp     w9, w10
        csel    w9, w9, w10, lo         /* clamp to the caller's buffer */
        add     x21, x0, #SCR_TEXT_OFF
        mov     w11, #0
1:      cmp     w11, w9
        b.hs    2f
        ldrb    w12, [x21, w11, uxtw]
        strb    w12, [x19, w11, uxtw]
        add     w11, w11, #1
        b       1b
2:      strb    wzr, [x19, w11, uxtw]
        mov     w0, w11
        ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* ----------------------------------------------------------------- drawing */

/*
 * editor_render - draw the current screen into a 32bpp buffer.
 *   x0 = buffer, w1 = stride in pixels, w2 = width, w3 = height
 *
 * Two passes over the text: the first locates the cursor's row and column and
 * settles the scroll offset, the second draws only the rows that are on
 * screen.  Row/column state lives on the stack across the draw calls because
 * every callee-saved register is already spoken for.
 */
        .globl  SYM(editor_render)
SYM(editor_render):
        stp     x29, x30, [sp, #-160]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        stp     x27, x28, [sp, #80]
        mov     x19, x0                 /* buffer */
        mov     w20, w1                 /* stride */
        mov     w21, w2                 /* width  */
        mov     w22, w3                 /* height */

        mov     x0, x19                 /* backdrop */
        mov     w1, w20
        mov     w2, #0
        mov     w3, #0
        mov     w4, w21
        mov     w5, w22
        LDCOL   w6, COL_BG_LO, COL_BG_HI
        bl      SYM(fb_fill)

        mov     x0, x19                 /* screen bar */
        mov     w1, w20
        mov     w2, #0
        mov     w3, #0
        mov     w4, w21
        mov     w5, #ED_BAR_H
        LDCOL   w6, COL_BAR_LO, COL_BAR_HI
        bl      SYM(fb_fill)

        mov     w9, #ED_CELL_W          /* text grid that fits */
        udiv    w23, w21, w9
        sub     w10, w22, #ED_BAR_H
        mov     w9, #ED_CELL_H
        udiv    w24, w10, w9

        bl      ed_cur
        mov     x25, x0
        ldr     w26, [x25, #SCR_LEN_OFF]
        ldr     w27, [x25, #SCR_CUR_OFF]
        ldr     w28, [x25, #SCR_SCROLL_OFF]

/* pass one: where is the cursor, in rows and columns? */
        mov     w9, #0                  /* index */
        mov     w10, #0                 /* row   */
        mov     w11, #0                 /* col   */
        add     x17, x25, #SCR_TEXT_OFF
1:      cmp     w9, w27
        b.ne    2f
        str     w10, [sp, #96]
        str     w11, [sp, #100]
2:      cmp     w9, w26
        b.hs    3f
        ldrb    w13, [x17, w9, uxtw]
        add     w9, w9, #1
        cmp     w13, #'\n'
        b.ne    4f
        add     w10, w10, #1
        mov     w11, #0
        b       1b
4:      add     w11, w11, #1
        cmp     w11, w23
        b.lo    1b
        mov     w11, #0
        add     w10, w10, #1
        b       1b
3:

        ldr     w13, [sp, #96]          /* keep the cursor on screen */
        cmp     w13, w28
        b.hs    5f
        mov     w28, w13
5:      add     w14, w28, w24
        cmp     w13, w14
        b.lo    6f
        sub     w28, w13, w24
        add     w28, w28, #1
6:      str     w28, [x25, #SCR_SCROLL_OFF]
        LEA     x9, ed_state            /* remember the viewport: the client
                                           reports it, and clicks need it */
        str     w28, [x9, #8]
        str     w24, [x9, #12]
        str     w23, [x9, #16]

/* pass two: draw the visible rows */
        str     wzr, [sp, #112]         /* index */
        str     wzr, [sp, #116]         /* row   */
        str     wzr, [sp, #120]         /* col   */
.Ldraw:
        ldr     w9, [sp, #112]
        cmp     w9, w26
        b.hs    .Ldraw_done
        add     x17, x25, #SCR_TEXT_OFF
        ldrb    w12, [x17, w9, uxtw]
        add     w9, w9, #1
        str     w9, [sp, #112]
        cmp     w12, #'\n'
        b.eq    .Ldraw_nl

        ldr     w10, [sp, #116]
        ldr     w11, [sp, #120]
        sub     w15, w10, w28           /* row on screen; unsigned wrap hides */
        cmp     w15, w24                /* everything above the scroll point  */
        b.hs    .Ldraw_adv

        mov     w16, #ED_CELL_W
        mul     w16, w11, w16
        mov     w17, #ED_CELL_H
        mul     w17, w15, w17
        add     w17, w17, #ED_BAR_H
        strb    w12, [sp, #104]         /* a one-character string */
        strb    wzr, [sp, #105]
        mov     x0, x19
        mov     w1, w20
        mov     w2, w16
        mov     w3, w17
        mov     w4, #ED_SCALE
        LDCOL   w5, COL_FG_LO, COL_FG_HI
        add     x6, sp, #104
        bl      SYM(font_draw_text)

.Ldraw_adv:
        ldr     w11, [sp, #120]
        add     w11, w11, #1
        cmp     w11, w23
        b.lo    7f
        mov     w11, #0
        ldr     w10, [sp, #116]
        add     w10, w10, #1
        str     w10, [sp, #116]
7:      str     w11, [sp, #120]
        b       .Ldraw
.Ldraw_nl:
        str     wzr, [sp, #120]
        ldr     w10, [sp, #116]
        add     w10, w10, #1
        str     w10, [sp, #116]
        b       .Ldraw
.Ldraw_done:

        ldr     w13, [sp, #96]          /* the caret */
        ldr     w14, [sp, #100]
        sub     w15, w13, w28
        cmp     w15, w24
        b.hs    .Lbar
        mov     w16, #ED_CELL_W
        mul     w16, w14, w16
        mov     w17, #ED_CELL_H
        mul     w17, w15, w17
        add     w17, w17, #ED_BAR_H
        mov     x0, x19
        mov     w1, w20
        mov     w2, w16
        mov     w3, w17
        mov     w4, #(2 * ED_SCALE)
        mov     w5, #ED_CELL_H
        LDCOL   w6, COL_CURSOR_LO, COL_CURSOR_HI
        bl      SYM(fb_fill)

/* the screen bar: one digit per screen, the current one lit */
.Lbar:
        mov     x0, x19
        mov     w1, w20
        mov     w2, #(2 * ED_SCALE)
        mov     w3, #(2 * ED_SCALE)
        mov     w4, #ED_SCALE
        LDCOL   w5, COL_DIM_LO, COL_DIM_HI
        LEA     x6, s_brand
        bl      SYM(font_draw_text)

        str     wzr, [sp, #128]         /* screen index */
.Lbar_loop:
        ldr     w9, [sp, #128]
        bl      SYM(editor_screen_info) /* w0 = current, w1 = count */
        ldr     w9, [sp, #128]
        cmp     w9, w1
        b.hs    .Lrender_out
        mov     w10, #ED_CELL_W         /* x = brand width + slot */
        mul     w10, w9, w10
        lsl     w10, w10, #1
        add     w10, w10, #(10 * ED_CELL_W)
        add     w11, w9, #'1'           /* screens are 1-based on screen */
        strb    w11, [sp, #104]
        strb    wzr, [sp, #105]
        cmp     w9, w0
        b.ne    8f
        LDCOL   w5, COL_CURSOR_LO, COL_CURSOR_HI
        b       9f
8:      LDCOL   w5, COL_DIM_LO, COL_DIM_HI
9:      mov     x0, x19
        mov     w1, w20
        mov     w2, w10
        mov     w3, #(2 * ED_SCALE)
        mov     w4, #ED_SCALE
        add     x6, sp, #104
        bl      SYM(font_draw_text)
        ldr     w9, [sp, #128]
        add     w9, w9, #1
        str     w9, [sp, #128]
        b       .Lbar_loop

.Lrender_out:
        ldp     x27, x28, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #160
        ret

        RODATA
s_brand:        .asciz "ASMEDIT"

        BSS
        .p2align 4
ed_screens:                             /* private: the screens themselves */
        .space  (MAX_SCREENS * SCR_STRIDE)
ed_state:
        .space  16                      /* current index, screen count */
