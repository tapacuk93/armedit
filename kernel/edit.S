#include "asm.inc"
#include "editor.inc"
/*
 * edit.S - armedit as the machine, rather than as a program on one.
 *
 * This is the OS mode: the same editor core the window and the phone run,
 * driven by a keyboard that is a serial line and drawing into a framebuffer
 * the firmware handed us. Nothing in this file names a peripheral - keys come
 * from platform_getc, time from platform_ticks, pixels from platform_fb - so
 * a port supplies those three and this file is unchanged.
 *
 * Two things differ from the hosted front ends, and both are consequences of
 * there being no operating system here rather than decisions:
 *
 * A serial console has no Cmd key, so Ctrl stands in for it. Ctrl+P is Cmd+P,
 * Ctrl+T opens a screen, and so on. That mapping is not a compromise for the
 * kernel's benefit - it is what the editor core already expected, because
 * editor.inc has said "Ctrl on the serial console" since the key codes were
 * written.
 *
 * And there is no network yet, so Cmd+P and Cmd+Enter have nowhere to send
 * the screen. Rather than silently doing nothing, they say so. This is the
 * same path the hosted build takes when the backend is unreachable: the
 * editor keeps editing, and the two keys that need a far side are the only
 * things that stop working.
 */

/* Where we are in an escape sequence, since getc never blocks. */
#define ESC_NONE        0
#define ESC_ESC         1               /* seen 0x1B */
#define ESC_BRACKET     2               /* seen 0x1B '[' or 0x1B 'O' */

#define BLINK_MS        500

        .section .text
        .p2align 2

/*
 * kedit_run - the editor, forever. Never returns.
 *   w0 = 0 on entry means the machine has a framebuffer; anything else and
 *   we should not have been called.
 */
        .globl  kedit_run
kedit_run:
        stp     x29, x30, [sp, #-128]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]

        add     x0, sp, #96             /* base */
        add     x1, sp, #104            /* width */
        add     x2, sp, #108            /* height */
        bl      platform_fb
        ldr     x19, [sp, #96]
        ldr     w20, [sp, #104]
        ldr     w21, [sp, #108]
        cbz     x19, .Lke_out

        bl      SYM(editor_init)
        bl      SYM(applet_clear)

        /*
         * The same video widget the window build shows, decoded by the same
         * ARMV1 decoder. Nothing about it is different here - which is the
         * point of the editor core being shared rather than reimplemented.
         */
        LEA     x0, SYM(demo_clip)
        LEA     x9, SYM(demo_clip_end)
        sub     x9, x9, x0
        mov     w1, w9
        bl      SYM(video_open)
        cmn     w0, #1
        b.eq    1f
        bl      SYM(video_next)
        mov     w0, #AP_KIND_VIDEO
        mov     w1, #6000               /* basis points, so the same layout */
        mov     w2, #1000               /* lands correctly on any surface */
        mov     w3, #3400
        mov     w4, #3400
        mov     w5, #0
        LEA     x6, s_unlabelled
        bl      SYM(applet_add)
1:

        mov     w22, #ESC_NONE
        mov     w23, #1                 /* redraw wanted */
        bl      platform_ticks
        mov     x24, x0                 /* when the caret last flipped */

.Lke_loop:
        cbz     w23, 1f
        mov     x0, x19
        mov     w1, w20                 /* this board's stride is its width */
        mov     w2, w20
        mov     w3, w21
        bl      SYM(editor_render)
        mov     x0, x19                 /* widgets sit on top of the text */
        mov     w1, w20
        mov     w2, w20
        mov     w3, w21
        bl      SYM(applet_render)
        mov     w23, #0
1:
        bl      platform_getc
        cmn     w0, #1
        b.eq    .Lke_tick
        bl      .Lke_translate          /* w0 = an editor key, or -1 */
        cmn     w0, #1
        b.eq    .Lke_loop
        bl      SYM(editor_key)
        mov     w23, #1
        cmp     w0, #ED_AIFY
        b.eq    .Lke_nolink
        cmp     w0, #ED_SUBMIT
        b.eq    .Lke_nolink
        b       .Lke_loop

/*
 * The two keys that need a far side. Saying nothing would be indistinguishable
 * from a hung machine, and saying it in the text would mean taking it out
 * again later, so it goes to the serial line where a note belongs.
 */
.Lke_nolink:
        LEA     x0, m_nolink
        bl      platform_puts
        b       .Lke_loop

.Lke_tick:
        bl      platform_ticks
        sub     x9, x0, x24
        mov     x10, #BLINK_MS
        cmp     x9, x10
        b.lo    .Lke_loop
        mov     x24, x0
        bl      SYM(editor_caret_blink)
        orr     w23, w23, w0            /* it says nothing changed while busy */
        bl      SYM(video_ok)           /* the clip advances on the same tick */
        cbz     w0, .Lke_loop
        bl      SYM(video_next)
        mov     w23, #1
        b       .Lke_loop

.Lke_out:
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #128
        ret

/*
 * .Lke_translate - w0 = a byte off the wire, out w0 = an editor key or -1.
 *
 * w22 carries the escape state between calls and w25 the numeric parameter,
 * because the bytes of a sequence arrive on separate polls and there is
 * nothing to block on in between.
 *
 * The awkward part of a serial keyboard is that the control codes are already
 * spoken for. Ctrl+M *is* Return and Ctrl+H *is* Backspace - a terminal sends
 * the same byte either way, so those two Ctrl combinations cannot be told
 * apart from the plain keys and cannot carry Cmd. The two that are left over
 * take their place: Ctrl+J, which is what Ctrl+Enter sends on a real keyboard
 * anyway, and DEL against Ctrl+H for the two kinds of erase.
 */
.Lke_translate:
        cmp     w22, #ESC_NONE
        b.eq    .Lkt_plain
        cmp     w22, #ESC_ESC
        b.eq    .Lkt_esc

/* Inside a sequence: digits and ';' are the parameters, a letter ends it. */
        cmp     w0, #'0'
        b.lo    1f
        cmp     w0, #'9'
        b.hi    1f
        mov     w9, #10                 /* accumulate this parameter */
        mul     w25, w25, w9
        sub     w9, w0, #'0'
        add     w25, w25, w9
        mov     w0, #-1
        ret
1:      cmp     w0, #';'
        b.ne    2f
        mov     w25, #0                 /* the modifier is the last one */
        mov     w0, #-1
        ret

2:      mov     w22, #ESC_NONE
        mov     w26, #0                 /* what the parameter says was held */
        cmp     w25, #2
        b.lo    3f
        sub     w9, w25, #1             /* xterm: 1 + shift + 2*alt + 4*ctrl */
        tbz     w9, #0, 4f
        mov     w26, #MOD_SHIFT
4:      tbz     w9, #2, 3f
        orr     w26, w26, #MOD_CMD      /* Ctrl stands in for Cmd here too */
3:      mov     w25, #0

        cmp     w0, #'A'
        b.ne    5f
        mov     w0, #K_UP
        b       .Lkt_mod
5:      cmp     w0, #'B'
        b.ne    6f
        mov     w0, #K_DOWN
        b       .Lkt_mod
6:      cmp     w0, #'C'
        b.ne    7f
        mov     w0, #K_RIGHT
        b       .Lkt_mod
7:      cmp     w0, #'D'
        b.ne    8f
        mov     w0, #K_LEFT
        b       .Lkt_mod
8:      cmp     w0, #'H'
        b.ne    9f
        mov     w0, #K_HOME
        b       .Lkt_mod
9:      cmp     w0, #'F'
        b.ne    10f
        mov     w0, #K_END
        b       .Lkt_mod
10:     mov     w0, #-1                 /* some sequence we do not speak */
        ret
.Lkt_mod:
        orr     w0, w0, w26
        ret

.Lkt_esc:
        cmp     w0, #'['
        b.eq    1f
        cmp     w0, #'O'
        b.eq    1f
        mov     w22, #ESC_NONE          /* ESC then something else: a bare ESC */
        mov     w0, #-1
        ret
1:      mov     w22, #ESC_BRACKET
        mov     w25, #0
        mov     w0, #-1
        ret

.Lkt_plain:
        cmp     w0, #0x1B
        b.ne    1f
        mov     w22, #ESC_ESC
        mov     w0, #-1
        ret

1:      cmp     w0, #0x7F               /* DEL: erase a character */
        b.ne    2f
        mov     w0, #K_BS
        ret
2:      cmp     w0, #0x08               /* Ctrl+H: erase the screen */
        b.ne    3f
        mov     w0, #K_BS
        orr     w0, w0, #MOD_CMD
        ret
3:      cmp     w0, #'\r'               /* Return */
        b.ne    4f
        mov     w0, #K_ENTER
        ret
4:      cmp     w0, #'\n'               /* Ctrl+J: hand the screen over */
        b.ne    5f
        mov     w0, #K_ENTER
        orr     w0, w0, #MOD_CMD
        ret

5:      cmp     w0, #0x01               /* every other Ctrl+letter is Cmd+it */
        b.lo    6f
        cmp     w0, #0x1A
        b.hi    6f
        add     w0, w0, #('a' - 1)
        orr     w0, w0, #MOD_CMD
        ret
6:      cmp     w0, #' '                /* anything printable is itself */
        b.lo    7f
        cmp     w0, #0x7E
        b.hi    7f
        ret
7:      mov     w0, #-1
        ret

        .section .rodata
/* A video answers to its kind, which is what a shared rule is written against. */
s_unlabelled:
        .asciz ""
m_nolink:
        .asciz "armedit: no link yet - the editor works, the far side does not\n"
