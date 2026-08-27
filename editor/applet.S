#include "asm.inc"
#include "editor.inc"
/*
 * applet.S - clickable things, drawn the same way the text is.
 *
 * An applet is a rectangle with a label and an action: a button, a key, later
 * a picture or a frame of video. They are drawn by the same rasterizer that
 * draws the text, hit-tested by the same click that places the caret, and
 * described in the same terms whatever they are - so an on-screen keyboard is
 * not a special case, it is forty-odd key applets laid out in rows.
 *
 * Positions are proportional, in basis points of the surface (0..10000), not
 * pixels. That is what lets the same layout move between a phone in portrait,
 * the same phone rotated, and a desktop window: the applet keeps its share of
 * the surface rather than its pixel address. A layout authored on one device
 * is correct on the next one without anybody recomputing it.
 */
#define AP_MAX          72
#define AP_SZ           40

#define AP_ID           0
#define AP_KIND         4
#define AP_X            8       /* all four in basis points of the surface */
#define AP_Y            10
#define AP_W            12
#define AP_H            14
#define AP_ACTION       16
#define AP_LABEL        20      /* up to 11 characters and a NUL */
#define AP_FLAGS        32
#define AP_DATA         36      /* whose picture, whose video */

/* Kinds and flags live in editor.inc: both front ends build and hit-test these. */

#define BP              10000

/*
 * Keyboard geometry, in basis points of the surface. Four rows across the
 * bottom two fifths, which leaves the text the rest whatever the device.
 */
#define KB_TOP          5800
#define KB_KEY_H        900
#define KB_GAP          60
#define KB_STR_STRIDE   12      /* the padded length of one keyboard row */

/* Key faces, dark enough to sit under the same text the editor draws. */
#define COL_KEY_LO      0x2A32
#define COL_KEY_HI      0xFF22
#define COL_KEYTOP_LO   0x3A44
#define COL_KEYTOP_HI   0xFF2E
#define COL_KEYTXT_LO   0xE2C8
#define COL_KEYTXT_HI   0xFFC8

        CODE
        .p2align 2

/* applet_clear - forget every applet. */
        .globl  SYM(applet_clear)
SYM(applet_clear):
        LEA     x9, ap_count
        str     wzr, [x9]
        ret

/*
 * applet_mark / applet_truncate - a menu is applets that come and go.
 * Mark the count before adding one, truncate back to it to take it away,
 * and the keyboard underneath is untouched either way.
 */
        .globl  SYM(applet_mark)
SYM(applet_mark):
        LEA     x9, ap_count
        ldr     w0, [x9]
        ret

        .globl  SYM(applet_truncate)
SYM(applet_truncate):
        LEA     x9, ap_count
        ldr     w10, [x9]
        cmp     w0, w10
        b.hs    1f
        str     w0, [x9]
1:      ret

/* applet_count - how many there are */
        .globl  SYM(applet_count)
SYM(applet_count):
        LEA     x9, ap_count
        ldr     w0, [x9]
        ret

/*
 * applet_add - w0 = kind, w1 = x, w2 = y, w3 = w, w4 = h (all basis points),
 *              w5 = action, x6 = label
 *   out w0 = its index, or -1 when the table is full
 */
        .globl  SYM(applet_add)
SYM(applet_add):
        LEA     x9, ap_count
        ldr     w10, [x9]
        cmp     w10, #AP_MAX
        b.hs    9f
        mov     w11, #AP_SZ
        mul     w11, w10, w11
        LEA     x12, ap_table
        add     x12, x12, w11, uxtw
        str     w10, [x12, #AP_ID]
        str     w0, [x12, #AP_KIND]
        strh    w1, [x12, #AP_X]
        strh    w2, [x12, #AP_Y]
        strh    w3, [x12, #AP_W]
        strh    w4, [x12, #AP_H]
        str     w5, [x12, #AP_ACTION]
        str     wzr, [x12, #AP_FLAGS]   /* nothing is draggable until said so */
        str     wzr, [x12, #AP_DATA]
        add     x13, x12, #AP_LABEL
        mov     w14, #0
1:      cmp     w14, #11
        b.hs    2f
        ldrb    w15, [x6, w14, uxtw]
        strb    w15, [x13, w14, uxtw]
        cbz     w15, 3f
        add     w14, w14, #1
        b       1b
2:      mov     w15, #0
3:      strb    wzr, [x13, w14, uxtw]
        add     w10, w10, #1
        str     w10, [x9]
        sub     w0, w10, #1
        ret
9:      mov     w0, #-1
        ret

/*
 * applet_render - x0 = buffer, w1 = stride, w2 = width, w3 = height.
 *
 * Basis points become pixels here and nowhere else, which is the whole trick:
 * the same table draws correctly on any surface.
 */
        .globl  SYM(applet_render)
SYM(applet_render):
        stp     x29, x30, [sp, #-144]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        stp     x27, x28, [sp, #80]
        mov     x19, x0
        mov     w20, w1
        mov     w21, w2
        mov     w22, w3

        LEA     x9, ap_count
        ldr     w23, [x9]
        cbz     w23, .Lap_done
        mov     w24, #0                 /* index */

.Lap_next:
        cmp     w24, w23
        b.hs    .Lap_done
        mov     w9, #AP_SZ
        mul     w9, w24, w9
        LEA     x25, ap_table
        add     x25, x25, w9, uxtw
        ldr     w9, [x25, #AP_KIND]
        cbz     w9, .Lap_step

        ldrh    w9, [x25, #AP_X]        /* basis points -> pixels */
        mul     w26, w9, w21
        mov     w10, #BP
        udiv    w26, w26, w10           /* x */
        ldrh    w9, [x25, #AP_Y]
        mul     w27, w9, w22
        udiv    w27, w27, w10           /* y */
        ldrh    w9, [x25, #AP_W]
        mul     w28, w9, w21
        udiv    w28, w28, w10           /* w */
        ldrh    w9, [x25, #AP_H]
        mul     w9, w9, w22
        udiv    w9, w9, w10             /* h */
        str     w9, [sp, #128]

        cbz     w28, .Lap_step
        cbz     w9, .Lap_step

        ldr     w10, [x25, #AP_KIND]    /* a video draws itself */
        cmp     w10, #AP_KIND_VIDEO
        b.ne    .Lap_face
        mov     x0, x19
        mov     w1, w20
        mov     w2, w26
        mov     w3, w27
        mov     w4, w28
        ldr     w5, [sp, #128]
        bl      SYM(video_present)
        b       .Lap_step

.Lap_face:
        mov     x0, x19                 /* the face */
        mov     w1, w20
        mov     w2, w26
        mov     w3, w27
        mov     w4, w28
        ldr     w5, [sp, #128]
        LDCOL   w6, COL_KEY_LO, COL_KEY_HI
        bl      SYM(fb_fill)

        mov     x0, x19                 /* a lit top edge, so it reads as a key */
        mov     w1, w20
        mov     w2, w26
        mov     w3, w27
        mov     w4, w28
        mov     w5, #2
        LDCOL   w6, COL_KEYTOP_LO, COL_KEYTOP_HI
        bl      SYM(fb_fill)

/* The label is centred by measuring it: glyph advance times its length. */
        add     x0, x25, #AP_LABEL
        bl      SYM(str_len)
        mov     w9, w0
        cbz     w9, .Lap_step
        ldr     w10, [sp, #128]         /* pick a scale that fits the key */
        mov     w11, #(GLYPH_H + 4)
        udiv    w10, w10, w11
        cbz     w10, .Lap_step
        mov     w11, #GLYPH_ADV
        mul     w11, w11, w9            /* label width at scale 1 */
1:      cmp     w10, #1
        b.ls    2f
        mul     w12, w11, w10
        cmp     w12, w28
        b.ls    2f
        sub     w10, w10, #1            /* too wide: shrink until it fits */
        b       1b
2:      mul     w12, w11, w10
        sub     w13, w28, w12
        lsr     w13, w13, #1
        add     w13, w26, w13           /* centred x */
        mov     w14, #GLYPH_H
        mul     w14, w14, w10
        ldr     w15, [sp, #128]
        sub     w15, w15, w14
        lsr     w15, w15, #1
        add     w15, w27, w15           /* centred y */

        mov     x0, x19
        mov     w1, w20
        mov     w2, w13
        mov     w3, w15
        mov     w4, w10
        LDCOL   w5, COL_KEYTXT_LO, COL_KEYTXT_HI
        add     x6, x25, #AP_LABEL
        bl      SYM(font_draw_text)

.Lap_step:
        add     w24, w24, #1
        b       .Lap_next

.Lap_done:
        ldp     x27, x28, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #144
        ret

/*
 * applet_hit - w0 = x, w1 = y, w2 = surface width, w3 = surface height
 *   out w0 = index, or -1 for a miss
 * Searched last-first, so the most recently added applet is on top.
 */
        .globl  SYM(applet_hit)
SYM(applet_hit):
        LEA     x9, ap_count
        ldr     w9, [x9]
        cbz     w9, 9f
        mov     w10, #BP
.Lhit_next:
        sub     w9, w9, #1
        mov     w11, #AP_SZ
        mul     w11, w9, w11
        LEA     x12, ap_table
        add     x12, x12, w11, uxtw
        ldr     w11, [x12, #AP_KIND]
        cbz     w11, .Lhit_step

        ldrh    w13, [x12, #AP_X]
        mul     w13, w13, w2
        udiv    w13, w13, w10           /* x0 */
        ldrh    w14, [x12, #AP_W]
        mul     w14, w14, w2
        udiv    w14, w14, w10
        add     w14, w13, w14           /* x1 */
        cmp     w0, w13
        b.lo    .Lhit_step
        cmp     w0, w14
        b.hs    .Lhit_step

        ldrh    w15, [x12, #AP_Y]
        mul     w15, w15, w3
        udiv    w15, w15, w10           /* y0 */
        ldrh    w16, [x12, #AP_H]
        mul     w16, w16, w3
        udiv    w16, w16, w10
        add     w16, w15, w16           /* y1 */
        cmp     w1, w15
        b.lo    .Lhit_step
        cmp     w1, w16
        b.hs    .Lhit_step
        mov     w0, w9
        ret
.Lhit_step:
        cbnz    w9, .Lhit_next
9:      mov     w0, #-1
        ret

/*
 * applet_pos / applet_set_pos - where it is, in basis points.
 *   applet_pos:     w0 = index, out w0 = x, w1 = y
 *   applet_set_pos: w0 = index, w1 = x, w2 = y
 *
 * Positions were read-only while a layout was something authored once. They
 * are not any more: a dragged widget is a layout being edited, and the basis
 * points are what makes that survive the trip to a different screen.
 */
        .globl  SYM(applet_pos)
SYM(applet_pos):
        mov     w9, #AP_SZ
        mul     w9, w0, w9
        LEA     x10, ap_table
        add     x10, x10, w9, uxtw
        ldrh    w0, [x10, #AP_X]
        ldrh    w1, [x10, #AP_Y]
        ret

        .globl  SYM(applet_set_pos)
SYM(applet_set_pos):
        mov     w9, #AP_SZ
        mul     w9, w0, w9
        LEA     x10, ap_table
        add     x10, x10, w9, uxtw
        ldrh    w11, [x10, #AP_W]       /* keep it on the surface: a widget */
        mov     w12, #BP                /* dragged off the edge is a widget */
        sub     w12, w12, w11           /* nobody can get back */
        cmp     w1, w12
        csel    w1, w1, w12, ls
        tbz     w1, #31, 1f
        mov     w1, #0
1:      ldrh    w11, [x10, #AP_H]
        mov     w12, #BP
        sub     w12, w12, w11
        cmp     w2, w12
        csel    w2, w2, w12, ls
        tbz     w2, #31, 2f
        mov     w2, #0
2:      strh    w1, [x10, #AP_X]
        strh    w2, [x10, #AP_Y]
        ldr     w11, [x10, #AP_FLAGS]
        orr     w11, w11, #AP_F_MOVED
        str     w11, [x10, #AP_FLAGS]
        ret

/* applet_flags / applet_set_flags - what it may do. w0 = index. */
        .globl  SYM(applet_flags)
SYM(applet_flags):
        mov     w9, #AP_SZ
        mul     w9, w0, w9
        LEA     x10, ap_table
        add     x10, x10, w9, uxtw
        ldr     w0, [x10, #AP_FLAGS]
        ret

        .globl  SYM(applet_set_flags)
SYM(applet_set_flags):
        mov     w9, #AP_SZ
        mul     w9, w0, w9
        LEA     x10, ap_table
        add     x10, x10, w9, uxtw
        str     w1, [x10, #AP_FLAGS]
        ret

/* applet_data / applet_set_data - which object this applet stands for. */
        .globl  SYM(applet_data)
SYM(applet_data):
        mov     w9, #AP_SZ
        mul     w9, w0, w9
        LEA     x10, ap_table
        add     x10, x10, w9, uxtw
        ldr     w0, [x10, #AP_DATA]
        ret

        .globl  SYM(applet_set_data)
SYM(applet_set_data):
        mov     w9, #AP_SZ
        mul     w9, w0, w9
        LEA     x10, ap_table
        add     x10, x10, w9, uxtw
        str     w1, [x10, #AP_DATA]
        ret

/* applet_kind / applet_action - what a hit means. w0 = index. */
        .globl  SYM(applet_kind)
SYM(applet_kind):
        mov     w9, #AP_SZ
        mul     w9, w0, w9
        LEA     x10, ap_table
        add     x10, x10, w9, uxtw
        ldr     w0, [x10, #AP_KIND]
        ret

        .globl  SYM(applet_action)
SYM(applet_action):
        mov     w9, #AP_SZ
        mul     w9, w0, w9
        LEA     x10, ap_table
        add     x10, x10, w9, uxtw
        ldr     w0, [x10, #AP_ACTION]
        ret

/*
 * keyboard_build - lay out a keyboard as applets, w0 = 1 for shifted.
 *
 * Four rows across the bottom of the surface, in basis points, so it lands
 * correctly on a phone held either way and on a desktop window alike. This is
 * a built-in layout; the same table is what a server-described keyboard would
 * fill in, which is the point of building it out of applets at all.
 */
        .globl  SYM(keyboard_build)
SYM(keyboard_build):
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        mov     w26, w0                 /* shifted? */

        bl      SYM(applet_clear)

        LEA     x19, kb_rows            /* row descriptors */
        mov     w20, #0                 /* row index */
.Lrow:
        cmp     w20, #3                 /* three rows of letters */
        b.hs    .Lspecials
        mov     w9, #4                  /* two shorts per row */
        mul     w9, w20, w9
        add     x21, x19, w9, uxtw
        ldrh    w23, [x21]              /* left inset, basis points */
        ldrh    w24, [x21, #2]          /* key width */
        LEA     x22, kb_strings         /* rows are a fixed stride apart, so
                                           the address is arithmetic rather
                                           than a stored pointer: Mach-O makes
                                           every labelled constant its own atom
                                           and iOS refuses the relocation a
                                           pointer or a label difference would
                                           need */
        mov     w9, #KB_STR_STRIDE
        madd    x22, x20, x9, x22

        mov     w9, #KB_TOP             /* y = top + row * (h + gap) */
        mov     w10, #(KB_KEY_H + KB_GAP)
        madd    w25, w20, w10, w9

        mov     w10, #0                 /* column */
.Lkey:
        ldrb    w0, [x22, w10, uxtw]
        cbz     w0, .Lrow_done
        stp     x9, x10, [sp, #80]

        cbz     w26, 1f                 /* shift: fold to upper case */
        sub     w9, w0, #'a'
        cmp     w9, #25
        b.hi    1f
        sub     w0, w0, #32
1:      LEA     x11, kb_label           /* a one-character label */
        strb    w0, [x11]
        strb    wzr, [x11, #1]
        mov     w5, w0                  /* action: the key itself */
        mov     w0, #AP_KIND_KEY
        ldp     x9, x10, [sp, #80]
        mov     w1, #KB_GAP
        madd    w1, w10, w1, w23        /* x = inset + col * (w + gap) */
        madd    w1, w10, w24, w1
        mov     w2, w25
        mov     w3, w24
        mov     w4, #KB_KEY_H
        LEA     x6, kb_label
        bl      SYM(applet_add)

        ldp     x9, x10, [sp, #80]
        add     w10, w10, #1
        b       .Lkey
.Lrow_done:
        add     w20, w20, #1
        b       .Lrow

/*
 * The bottom row is not letters, so it is spelled out rather than generated:
 * a wide space bar between backspace and enter, which is the shape a thumb
 * expects.
 */
.Lspecials:
        mov     w9, #KB_TOP
        mov     w10, #(KB_KEY_H + KB_GAP)
        mov     w11, #3
        madd    w25, w11, w10, w9

        mov     w0, #AP_KIND_KEY
        mov     w1, #200
        mov     w2, w25
        mov     w3, #1400
        mov     w4, #KB_KEY_H
        mov     w5, #K_BS
        LEA     x6, kb_back
        bl      SYM(applet_add)

        mov     w0, #AP_KIND_KEY
        mov     w1, #1700
        mov     w2, w25
        mov     w3, #5600
        mov     w4, #KB_KEY_H
        mov     w5, #' '
        LEA     x6, kb_space
        bl      SYM(applet_add)

        mov     w0, #AP_KIND_KEY
        mov     w1, #7400
        mov     w2, w25
        mov     w3, #2400
        mov     w4, #KB_KEY_H
        mov     w5, #K_ENTER
        LEA     x6, kb_enter
        bl      SYM(applet_add)

.Lkb_done:
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

/*
 * menu_build - the two things a long press on empty space offers.
 *   w0 = x, w1 = y in pixels, w2 = surface width, w3 = surface height
 *
 * Cmd+Enter and Cmd+P are the two AI actions, and a phone has neither key, so
 * a long press on nothing in particular puts them under the finger that asked.
 */
        .globl  SYM(menu_build)
SYM(menu_build):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]

        mov     w19, #BP                /* pixels back into basis points */
        mul     w9, w0, w19
        udiv    w19, w9, w2             /* x  */
        mov     w9, #BP
        mul     w9, w1, w9
        udiv    w20, w9, w3             /* y  */

        mov     w9, #(BP - 4800)        /* keep both buttons on the surface */
        cmp     w19, w9
        csel    w19, w19, w9, lo
        mov     w9, #(BP - 900)
        cmp     w20, w9
        csel    w20, w20, w9, lo

        mov     w0, #AP_KIND_BUTTON
        mov     w1, w19
        mov     w2, w20
        mov     w3, #2200
        mov     w4, #800
        mov     w5, #AP_ACT_ASK
        LEA     x6, m_ask
        bl      SYM(applet_add)

        add     w1, w19, #2400
        mov     w0, #AP_KIND_BUTTON
        mov     w2, w20
        mov     w3, #2400
        mov     w4, #800
        mov     w5, #AP_ACT_REWRITE
        LEA     x6, m_rewrite
        bl      SYM(applet_add)

        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

        RODATA
m_ask:      .asciz "ASK"
m_rewrite:  .asciz "REWRITE"
        .p2align 3
/*
 * Row descriptors: the characters, then the left inset and key width in basis
 * points. The bottom row carries shift, space, backspace and enter, whose
 * labels are their own characters here and are given meaning by the front end.
 */
kb_rows:
        .short  200, 900                /* inset and key width, per row */
        .short  700, 900
        .short  1200, 900

/* One row per KB_STR_STRIDE bytes, padded, so row n starts at n*stride. */
kb_strings:
        .asciz  "qwertyuiop"
        .byte   0
        .asciz  "asdfghjkl"
        .byte   0, 0
        .asciz  "zxcvbnm"
        .byte   0, 0, 0, 0
kb_back:  .asciz "<-"
kb_space: .asciz "SPACE"
kb_enter: .asciz "ENTER"

        BSS
        .p2align 4
ap_table:       .space (AP_MAX * AP_SZ)
ap_count:       .space 8
kb_label:       .space 8

        CODE
        .p2align 2
/*
 * open_applet_screen - w0 = applet index.
 *
 * Double-clicking a widget opens a screen about that widget, the same way
 * long-pressing a word opens a screen about the word. What binds the screen is
 * its subject, and the subject here is deliberately the *kind* of thing rather
 * than this particular one: "video", not "video number three". Somebody who
 * writes "draggable" on that screen is saying something about video widgets,
 * which is what makes the answer worth sharing with anyone else who has one.
 * A subject naming the instance would make every such lesson unrepeatable.
 */
        .globl  SYM(open_applet_screen)
SYM(open_applet_screen):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     w19, w0

        mov     w9, #AP_SZ
        mul     w9, w19, w9
        LEA     x20, ap_table
        add     x20, x20, w9, uxtw

        ldrb    w9, [x20, #AP_LABEL]    /* what it calls itself, if anything */
        cbz     w9, 1f
        add     x0, x20, #AP_LABEL
        b       2f
1:      ldr     w9, [x20, #AP_KIND]     /* otherwise, what kind of thing it is */
        cmp     w9, #AP_KIND_VIDEO
        b.ne    3f
        LEA     x0, s_kind_video
        b       2f
3:      cmp     w9, #AP_KIND_KEY
        b.ne    4f
        LEA     x0, s_kind_key
        b       2f
4:      LEA     x0, s_kind_widget
2:      bl      SYM(editor_screen_open)

        bl      SYM(editor_length)      /* a blank screen says nothing about */
        cbnz    w0, 5f                  /* what it is for */
        LEA     x0, s_seed_widget
        bl      SYM(editor_insert_str)
5:      ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

        RODATA
s_kind_video:   .asciz "video"
s_kind_key:     .asciz "key"
s_kind_widget:  .asciz "widget"
s_seed_widget:  .asciz "say what this should do, then ask.\nfor example: draggable\n\n"

        CODE
        .p2align 2
/*
 * applet_name - w0 = index, out x0 = what this applet answers to.
 *
 * Its label if it has one, otherwise the name of its kind. This is the name a
 * shared behaviour rule is written against, which is why it has to be the same
 * on every device: "video" is a thing everybody has, "the third applet" is not.
 */
        .globl  SYM(applet_name)
SYM(applet_name):
        mov     w9, #AP_SZ
        mul     w9, w0, w9
        LEA     x10, ap_table
        add     x10, x10, w9, uxtw
        add     x11, x10, #AP_LABEL
        ldrb    w12, [x11]
        cbz     w12, 1f
        mov     x0, x11
        ret
1:      ldr     w12, [x10, #AP_KIND]
        cmp     w12, #AP_KIND_VIDEO
        b.ne    2f
        LEA     x0, s_kind_video
        ret
2:      cmp     w12, #AP_KIND_KEY
        b.ne    3f
        LEA     x0, s_kind_key
        ret
3:      LEA     x0, s_kind_widget
        ret

/*
 * applet_mark_draggable - x0 = a target name; mark everything that answers to
 * it. A rule names a kind of object, so it applies to all of them or none.
 */
        .globl  SYM(applet_mark_draggable)
SYM(applet_mark_draggable):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]
        mov     x19, x0
        bl      SYM(applet_count)
        mov     w20, w0
        mov     w21, #0
1:      cmp     w21, w20
        b.hs    9f
        mov     w0, w21
        bl      SYM(applet_name)
        mov     x1, x19
        bl      SYM(str_eq)
        cbz     w0, 2f
        mov     w0, w21
        bl      SYM(applet_flags)
        orr     w1, w0, #AP_F_DRAG
        mov     w0, w21
        bl      SYM(applet_set_flags)
2:      add     w21, w21, #1
        b       1b
9:      ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret
