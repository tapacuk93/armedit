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
         * The video widget is built and works - see gfx/video.S and the demo
         * clip - but it is scenery while the editor is the thing being used,
         * and a square bouncing in the corner of a text screen is a
         * distraction. Left out rather than deleted: applet_add is one call.
         */

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
        bl      platform_present        /* and only now to the display */
        mov     w23, #0
/*
 * Every key that is waiting, before drawing anything.
 *
 * Redrawing between one keystroke and the next sounds harmless and is not: a
 * frame is a million pixels, and while it is being painted the keyboard's ring
 * fills and the device starts dropping events. Typed at speed, "hello from the
 * window" arrived as "te". So the loop takes everything that has arrived,
 * applies it, and paints once - which is also what makes typing feel like
 * typing rather than like a teletype.
 */
1:
        bl      platform_getc
        cmn     w0, #1
        b.eq    .Lke_tick
        bl      SYM(editor_key)         /* platform_getc hands us keys, not
                                           bytes: whatever this machine has for
                                           a keyboard is the port's business */
        mov     w23, #1
        cmp     w0, #ED_AIFY
        b.eq    .Lke_ask
        cmp     w0, #ED_SUBMIT
        b.eq    .Lke_ask
        b       1b

/*
 * The two keys that need a far side.
 *
 * Synchronously, unlike the hosted builds, which hand this to another thread
 * and keep drawing. There is no other thread here - no scheduler, one stack -
 * so the editor stops until the answer comes back. The caret stops blinking,
 * which is the same signal it gives everywhere else, and for the same reason.
 */
.Lke_ask:
        mov     w25, w0                 /* not w19: that is the framebuffer */
        LEA     x0, m_asking            /* a wait with no sign of life is
                                           indistinguishable from a key that
                                           did nothing, and the two get
                                           reported the same way */
        bl      platform_puts
        mov     w0, #1
        bl      SYM(editor_busy)
        mov     w23, #1
        mov     w0, w25
        bl      SYM(backend_submit)
        LEA     x0, m_answered
        bl      platform_puts
        mov     w0, #0
        bl      SYM(editor_busy)
        mov     w23, #1
        b       1b

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

        .section .rodata
/* A video answers to its kind, which is what a shared rule is written against. */
s_unlabelled:
        .asciz ""
m_asking:   .asciz "armedit: asking the backend...\n"
m_answered: .asciz "armedit: ...answered\n"
m_nolink:
        .asciz "armedit: no link yet - the editor works, the far side does not\n"
