#include "asm.inc"
#include "editor.inc"
/*
 * window.S - hosted mode: the editor in a macOS window.
 *
 * The window is real AppKit, but nothing in AppKit draws a character.  Every
 * frame is rendered by editor/editor.S into a plain pixel buffer, handed to
 * the compositor as one image, and the pixel format is byte-identical to what
 * the kernel's ramfb scans out - the same renderer produces both.
 *
 * The view class does not exist until this program builds it: NSView is
 * subclassed at runtime with objc_allocateClassPair, and drawRect:, keyDown:,
 * performKeyEquivalent: and acceptsFirstResponder are implemented by the
 * assembly routines at the bottom of this file.
 *
 * NOTE on the MSG macros: `recv` and `arg` must be callee-saved registers
 * (x19-x28) or immediates - sel_registerName clobbers x0-x18, so a value in a
 * scratch register would be destroyed before objc_msgSend saw it.
 */
#define WIN_W           800
#define WIN_H           600
#define CG_XRGB32_LE    0x2006  /* kCGImageAlphaNoneSkipFirst | ByteOrder32Little */
#define NS_CMD_FLAG     0x100000
#define NS_SHIFT_FLAG   0x20000
#define NS_KEY_UP       0xF700
#define NS_KEY_DOWN     0xF701
#define NS_KEY_LEFT     0xF702
#define NS_KEY_RIGHT    0xF703

.macro  MSG0 recv, selstr
        LEA     x0, \selstr
        bl      _sel_registerName
        mov     x1, x0
        mov     x0, \recv
        bl      _objc_msgSend
.endm
.macro  MSG1 recv, selstr, arg
        LEA     x0, \selstr
        bl      _sel_registerName
        mov     x1, x0
        mov     x2, \arg
        mov     x0, \recv
        bl      _objc_msgSend
.endm
.macro  CLS name
        LEA     x0, \name
        bl      _objc_getClass
.endm
/* class_addMethod(cls, sel, imp, types) with cls in a callee-saved register */
.macro  ADDM cls, selstr, imp, types
        LEA     x0, \selstr
        bl      _sel_registerName
        mov     x1, x0
        LEA     x2, \imp
        LEA     x3, \types
        mov     x0, \cls
        bl      _class_addMethod
.endm

        CODE
        .p2align 2
        .globl  _main
_main:
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        stp     x27, x28, [sp, #80]

        mov     x27, x0                 /* argc/argv are unused; envp is not */
        mov     x0, x2
        bl      SYM(env_init)           /* ARMEDIT_BACKEND / ARMEDIT_KEY */
        mov     x0, x27
        bl      SYM(editor_init)
        bl      SYM(applet_clear)

        /* One video widget, so there is something to double-click. In a real
           session these arrive with the content; here it is a fixed clip so
           the drag path can be exercised at all. */
        LEA     x0, SYM(demo_clip)
        LEA     x9, SYM(demo_clip_end)
        sub     x9, x9, x0
        mov     w1, w9
        bl      SYM(video_open)
        cmn     w0, #1
        b.eq    1f
        bl      SYM(video_next)
        mov     w0, #AP_KIND_VIDEO
        mov     w1, #6200               /* right of centre, upper half */
        mov     w2, #1200
        mov     w3, #3200
        mov     w4, #3200
        mov     w5, #0
        LEA     x6, s_no_label
        bl      SYM(applet_add)
1:
        /* What everyone else decided about objects like these. */
        bl      SYM(behaviour_sync)
        LEA     x0, seed_text
        bl      SYM(editor_insert_str)
        bl      SYM(backend_session)    /* open with an instance attached */

        CLS     s_NSApplication
        mov     x27, x0
        MSG0    x27, s_sharedApplication
        mov     x19, x0                 /* NSApp */
        MSG1    x19, s_setActivationPolicy, #0

/* ------------------------------------------- build the view class from bare
   metal, so to speak: NSView plus four methods of our own */
        CLS     s_NSView
        mov     x27, x0
        LEA     x1, s_view_cls
        mov     x2, #0
        mov     x0, x27
        bl      _objc_allocateClassPair
        LEA     x9, drag_index          /* nothing is held to begin with, and */
        mov     w10, #-1                /* zero would mean applet zero */
        str     w10, [x9]

        mov     x27, x0
        ADDM    x27, s_drawRect, view_draw_rect, t_drawRect
        ADDM    x27, s_keyDown, view_key_down, t_void_id
        ADDM    x27, s_performKeyEquivalent, view_perform_key_equiv, t_bool_id
        ADDM    x27, s_acceptsFirstResponder, view_accepts_first, t_bool
        ADDM    x27, s_armeditFinish, view_armedit_finish, t_void
        ADDM    x27, s_armeditBlink, view_armedit_blink, t_void_id
        ADDM    x27, s_mouseDown, view_mouse_down, t_void_id
        ADDM    x27, s_mouseDragged, view_mouse_dragged, t_void_id
        ADDM    x27, s_mouseUp, view_mouse_up, t_void_id
        mov     x0, x27
        bl      _objc_registerClassPair
        MSG0    x27, s_alloc
        mov     x27, x0
        MSG0    x27, s_init
        mov     x26, x0                 /* the view instance */

/* ------------------------------------------------------------------ window */
        CLS     s_NSWindow
        mov     x27, x0
        MSG0    x27, s_alloc
        mov     x20, x0
        LEA     x0, s_initWithContentRect       /* resolve selectors before the */
        bl      _sel_registerName               /* float args: calls clobber    */
        mov     x1, x0                          /* v0-v7                        */
        mov     x2, #7                  /* titled | closable | miniaturizable */
        mov     x3, #2                  /* NSBackingStoreBuffered */
        mov     x4, #0
        fmov    d0, xzr
        fmov    d1, xzr
        mov     w9, #WIN_W
        ucvtf   d2, w9
        mov     w9, #WIN_H
        ucvtf   d3, w9
        mov     x0, x20
        bl      _objc_msgSend
        mov     x20, x0

        CLS     s_NSString
        mov     x27, x0
        LEA     x0, s_stringWithUTF8String
        bl      _sel_registerName
        mov     x1, x0
        LEA     x2, s_title
        mov     x0, x27
        bl      _objc_msgSend
        mov     x28, x0
        MSG1    x20, s_setTitle, x28

        MSG1    x20, s_setContentView, x26
        MSG1    x20, s_makeFirstResponder, x26
        LEA     x9, view_slot           /* app_redraw needs to find it later */
        str     x26, [x9]

        CLS     s_NSTimer               /* half a second, forever: the caret */
        mov     x27, x0
        LEA     x0, s_armeditBlink
        bl      _sel_registerName
        mov     x28, x0
        LEA     x0, s_scheduledTimer
        bl      _sel_registerName
        mov     x1, x0
        mov     x2, x26                 /* target: the view */
        mov     x3, x28                 /* selector: armeditBlink: */
        mov     x4, #0                  /* no userInfo */
        mov     x5, #1                  /* repeats */
        fmov    d0, #0.5
        mov     x0, x27
        bl      _objc_msgSend

/* -------------------------------- a delegate, so closing the window quits us */
        CLS     s_NSObject
        mov     x27, x0
        LEA     x1, s_delegate_cls
        mov     x2, #0
        mov     x0, x27
        bl      _objc_allocateClassPair
        mov     x27, x0
        ADDM    x27, s_shouldTerminate, delegate_should_terminate, t_bool_id
        mov     x0, x27
        bl      _objc_registerClassPair
        MSG0    x27, s_alloc
        mov     x27, x0
        MSG0    x27, s_init
        mov     x27, x0
        MSG1    x19, s_setDelegate, x27

        MSG0    x20, s_center
        MSG1    x20, s_makeKeyAndOrderFront, #0
        MSG1    x19, s_activateIgnoringOtherApps, #1
        MSG0    x19, s_run

        mov     w0, #0
        ldp     x27, x28, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

/* ============================ the view's methods ========================== */

/* - (void)drawRect:(NSRect)dirty  - render the editor, blit it, drop the temps */
        .p2align 2
view_draw_rect:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        str     x23, [sp, #48]

        LEA     x0, pixels
        mov     w1, #WIN_W
        mov     w2, #WIN_W
        mov     w3, #WIN_H
        bl      SYM(editor_render)

        LEA     x0, pixels              /* widgets sit on top of the text */
        mov     w1, #WIN_W
        mov     w2, #WIN_W
        mov     w3, #WIN_H
        bl      SYM(applet_render)

        bl      _CGColorSpaceCreateDeviceRGB
        mov     x19, x0
        LEA     x0, pixels
        mov     x1, #WIN_W
        mov     x2, #WIN_H
        mov     x3, #8
        mov     x4, #(WIN_W * 4)
        mov     x5, x19
        mov     x6, #CG_XRGB32_LE
        bl      _CGBitmapContextCreate
        mov     x20, x0
        bl      _CGBitmapContextCreateImage
        mov     x21, x0

        CLS     s_NSGraphicsContext     /* the AppKit context we were called in */
        mov     x23, x0
        MSG0    x23, s_currentContext
        mov     x23, x0
        MSG0    x23, s_CGContext
        mov     x22, x0

        mov     x0, x22                 /* CGContextDrawImage(ctx, rect, image) */
        mov     x1, x21
        fmov    d0, xzr
        fmov    d1, xzr
        mov     w9, #WIN_W
        ucvtf   d2, w9
        mov     w9, #WIN_H
        ucvtf   d3, w9
        bl      _CGContextDrawImage

        mov     x0, x21
        bl      _CGImageRelease
        mov     x0, x20
        bl      _CGContextRelease
        mov     x0, x19
        bl      _CGColorSpaceRelease

        ldr     x23, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/* - (void)keyDown:(NSEvent *)event */
        .p2align 2
view_key_down:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        mov     x1, x2                  /* event */
        bl      handle_event
        ldp     x29, x30, [sp], #32
        ret

/*
 * - (BOOL)performKeyEquivalent:(NSEvent *)event
 * Cmd combinations are offered here before they would ever reach keyDown:.
 * Claiming them is what makes Cmd+Left/Right/T/Backspace ours.
 */
        .p2align 2
view_perform_key_equiv:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     x19, x0                 /* self  - handle_event needs it back */
        mov     x20, x2                 /* event */
        MSG0    x20, s_modifierFlags
        tst     x0, #NS_CMD_FLAG
        b.eq    1f
        mov     x0, x19
        mov     x1, x20
        bl      handle_event
        mov     w0, #1                  /* handled */
        b       2f
1:      mov     w0, #0
2:      ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * - (void)mouseDown:(NSEvent *)event - drop the caret where the user pointed.
 * locationInWindow returns an NSPoint, which arrives as two doubles in d0/d1;
 * the window's y axis runs up from the bottom, ours runs down from the top.
 */
        .p2align 2
view_mouse_down:
        stp     x29, x30, [sp, #-80]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0                 /* self  */
        mov     x20, x2                 /* event */
        MSG0    x20, s_locationInWindow
        fcvtzu  w21, d0
        fcvtzu  w22, d1
        mov     w2, #WIN_H
        sub     w22, w2, w22

        MSG0    x20, s_clickCount
        str     w0, [sp, #56]

        mov     w0, w21                 /* did it land on an applet? */
        mov     w1, w22
        mov     w2, #WIN_W
        mov     w3, #WIN_H
        bl      SYM(applet_hit)
        cmn     w0, #1
        b.eq    .Lmd_text
        str     w0, [sp, #60]

        ldr     w9, [sp, #56]           /* twice: open what it stands for */
        cmp     w9, #2
        b.lo    1f
        ldr     w0, [sp, #60]
        bl      SYM(open_applet_screen)
        b       .Lmd_draw

1:      ldr     w0, [sp, #60]           /* once, and draggable: pick it up */
        bl      SYM(applet_flags)
        tbz     w0, #0, .Lmd_draw       /* AP_F_DRAG */
        ldr     w9, [sp, #60]
        LEA     x10, drag_index
        str     w9, [x10]

        mov     w0, w9                  /* remember where inside it we grabbed, */
        bl      SYM(applet_pos)         /* so it does not jump under the cursor */
        mov     w9, #WIN_W
        mul     w0, w0, w9
        mov     w9, #10000
        udiv    w0, w0, w9
        sub     w0, w21, w0
        LEA     x10, drag_dx
        str     w0, [x10]
        mov     w9, #WIN_H
        mul     w1, w1, w9
        mov     w9, #10000
        udiv    w1, w1, w9
        sub     w1, w22, w1
        LEA     x10, drag_dy
        str     w1, [x10]
        b       .Lmd_draw

.Lmd_text:
        mov     w0, w21
        mov     w1, w22
        bl      SYM(editor_click)
.Lmd_draw:
        MSG1    x19, s_setNeedsDisplay, #1
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #80
        ret

/*
 * - (void)mouseDragged: - carry a widget with the pointer.
 *
 * Only ever moves something already marked draggable, and nothing is by
 * default. The position goes straight back into basis points rather than
 * being kept in pixels, so a widget dragged in a window lands in the same
 * relative place on a phone: the drag edits the layout, not the screen.
 */
        .p2align 2
view_mouse_dragged:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0                 /* self  */
        mov     x21, x2                 /* event */
        LEA     x9, drag_index
        ldr     w20, [x9]
        cmn     w20, #1
        b.eq    9f

        MSG0    x21, s_locationInWindow
        fcvtzu  w0, d0
        fcvtzu  w1, d1
        mov     w2, #WIN_H
        sub     w1, w2, w1

        LEA     x9, drag_dx             /* keep the grab point under the cursor */
        ldr     w10, [x9]
        subs    w0, w0, w10
        csel    w0, w0, wzr, pl
        LEA     x9, drag_dy
        ldr     w10, [x9]
        subs    w1, w1, w10
        csel    w1, w1, wzr, pl

        mov     w9, #10000              /* pixels back into basis points */
        mul     w0, w0, w9
        mov     w10, #WIN_W
        udiv    w0, w0, w10
        mul     w1, w1, w9
        mov     w10, #WIN_H
        udiv    w1, w1, w10

        mov     w2, w1
        mov     w1, w0
        mov     w0, w20
        bl      SYM(applet_set_pos)
        MSG1    x19, s_setNeedsDisplay, #1
9:      ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * - (void)mouseUp: - the drag is over.
 *
 * The position stays on this device. What travels to the server is the rule
 * that made the thing draggable in the first place, not where this particular
 * person happened to put it - one is a decision about how video widgets work,
 * the other is where somebody's window happened to be.
 */
        .p2align 2
view_mouse_up:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        LEA     x19, drag_index
        ldr     w20, [x19]
        cmn     w20, #1
        b.eq    9f
        mov     w9, #-1
        str     w9, [x19]
9:      ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* - (BOOL)acceptsFirstResponder */
        .p2align 2
view_accepts_first:
        mov     w0, #1
        ret

/* - (BOOL)applicationShouldTerminateAfterLastWindowClosed: */
        .p2align 2
delegate_should_terminate:
        mov     w0, #1
        ret

/*
 * app_finish - called from the background thread when the answer is in.
 *
 * Everything after this has to happen where the drawing happens, so it is
 * handed to the main thread rather than done here.  performSelectorOnMainThread
 * is the platform's own way of saying that, and it needs no queue symbol.
 */
        .p2align 2
        .globl  SYM(app_finish)
SYM(app_finish):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        LEA     x9, view_slot
        ldr     x19, [x9]
        cbz     x19, 1f
        LEA     x0, s_armeditFinish     /* the selector to run over there */
        bl      _sel_registerName
        mov     x20, x0
        LEA     x0, s_performOnMain
        bl      _sel_registerName
        mov     x1, x0
        mov     x2, x20
        mov     x3, #0                  /* no argument */
        mov     x4, #0                  /* do not wait */
        mov     x0, x19
        bl      _objc_msgSend
1:      ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* - (void)armeditFinish - the main-thread half, installed on the view class */
        .p2align 2
view_armedit_finish:
        b       SYM(async_finish)

/*
 * - (void)armeditBlink - the caret's phase, twice a second.
 *
 * The editor decides whether anything changed: while a request is out there is
 * no caret to blink, so it says no and the screen is left alone.  A blink
 * during a wait would say "ready for you" at exactly the wrong moment.
 */
        .p2align 2
view_armedit_blink:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     x19, x0
        bl      SYM(editor_caret_blink)
        mov     w20, w0

        /* The same timer advances the clip. It is slower than the clip's own
           frame rate, which makes playback slow rather than jerky - the right
           way round for a widget that is scenery, and honest about the fact
           that nothing here is scheduling frames properly yet. */
        bl      SYM(video_ok)
        cbz     w0, 1f
        bl      SYM(video_next)
        mov     w20, #1
1:      cbz     w20, 2f
        MSG1    x19, s_setNeedsDisplay, #1
2:      ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * app_redraw - what async.S calls when the screen should be repainted.
 * Always on the main thread: the background half hops back before calling it.
 */
        .p2align 2
        .globl  SYM(app_redraw)
SYM(app_redraw):
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        LEA     x9, view_slot
        ldr     x19, [x9]
        cbz     x19, 1f
        MSG1    x19, s_setNeedsDisplay, #1
1:      ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/*
 * handle_event - x0 = the view, x1 = NSEvent.
 * Translates one AppKit key event into the editor's own key encoding, feeds it
 * in, and asks for a redraw.
 */
        .p2align 2
handle_event:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        str     x23, [sp, #48]
        mov     x19, x0                 /* view  */
        mov     x20, x1                 /* event */

        MSG0    x20, s_modifierFlags
        mov     x21, x0
        MSG0    x20, s_charactersIgnoringModifiers
        mov     x22, x0
        cbz     x22, .Lhe_out
        MSG0    x22, s_length
        cbz     w0, .Lhe_out
        MSG1    x22, s_characterAtIndex, #0
        and     w23, w0, #0xFFFF        /* unichar */

        mov     w9, #NS_KEY_LEFT        /* AppKit's function keys -> ours */
        cmp     w23, w9
        b.ne    1f
        mov     w23, #K_LEFT
        b       .Lhe_send
1:      mov     w9, #NS_KEY_RIGHT
        cmp     w23, w9
        b.ne    2f
        mov     w23, #K_RIGHT
        b       .Lhe_send
2:      mov     w9, #NS_KEY_UP
        cmp     w23, w9
        b.ne    3f
        mov     w23, #K_UP
        b       .Lhe_send
3:      mov     w9, #NS_KEY_DOWN
        cmp     w23, w9
        b.ne    4f
        mov     w23, #K_DOWN
        b       .Lhe_send
4:      cmp     w23, #0x0D              /* Return */
        b.ne    .Lhe_send
        mov     w23, #K_ENTER

.Lhe_send:
        tst     x21, #NS_CMD_FLAG
        b.eq    5f
        orr     w23, w23, #MOD_CMD
        tst     x21, #NS_SHIFT_FLAG     /* Cmd+Shift is its own binding */
        b.eq    5f
        orr     w23, w23, #MOD_SHIFT
5:      mov     w0, w23
        bl      SYM(editor_key)
        cbz     w0, 6f                  /* ED_SUBMIT or ED_AIFY: go to the backend,
                                           off this thread so the window keeps
                                           drawing while it waits */
        bl      SYM(async_ask)
6:      MSG1    x19, s_setNeedsDisplay, #1

.Lhe_out:
        ldr     x23, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

        CSTR
s_title:                .asciz "armedit"
seed_text:              .asciz "ARMEDIT SCREEN 1\nCMD+T NEW SCREEN   CMD+LEFT/RIGHT SWITCH\nCMD+DELETE CLOSE   CLICK TO PLACE THE CARET\nCMD+ENTER ASK       CMD+P REWRITE\n\nTYPE HERE.\n"
s_view_cls:             .asciz "ArmeditView"
s_delegate_cls:         .asciz "ArmeditDelegate"
t_drawRect:             .asciz "v@:{CGRect={CGPoint=dd}{CGSize=dd}}"
t_void_id:              .asciz "v@:@"
t_bool_id:              .asciz "c@:@"
t_bool:                 .asciz "c@:"
t_void:                 .asciz "v@:"
s_armeditFinish:        .asciz "armeditFinish"
s_armeditBlink:         .asciz "armeditBlink:"
s_NSTimer:              .asciz "NSTimer"
s_scheduledTimer:       .asciz "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"
s_performOnMain:        .asciz "performSelectorOnMainThread:withObject:waitUntilDone:"
s_NSApplication:        .asciz "NSApplication"
s_NSWindow:             .asciz "NSWindow"
s_NSString:             .asciz "NSString"
s_NSView:               .asciz "NSView"
s_NSObject:             .asciz "NSObject"
s_NSGraphicsContext:    .asciz "NSGraphicsContext"
s_sharedApplication:    .asciz "sharedApplication"
s_setActivationPolicy:  .asciz "setActivationPolicy:"
s_alloc:                .asciz "alloc"
s_init:                 .asciz "init"
s_initWithContentRect:  .asciz "initWithContentRect:styleMask:backing:defer:"
s_stringWithUTF8String: .asciz "stringWithUTF8String:"
s_setTitle:             .asciz "setTitle:"
s_setContentView:       .asciz "setContentView:"
s_makeFirstResponder:   .asciz "makeFirstResponder:"
s_shouldTerminate:      .asciz "applicationShouldTerminateAfterLastWindowClosed:"
s_setDelegate:          .asciz "setDelegate:"
s_center:               .asciz "center"
s_makeKeyAndOrderFront: .asciz "makeKeyAndOrderFront:"
s_activateIgnoringOtherApps: .asciz "activateIgnoringOtherApps:"
s_run:                  .asciz "run"
s_drawRect:             .asciz "drawRect:"
s_keyDown:              .asciz "keyDown:"
s_performKeyEquivalent: .asciz "performKeyEquivalent:"
s_acceptsFirstResponder:.asciz "acceptsFirstResponder"
s_currentContext:       .asciz "currentContext"
s_CGContext:            .asciz "CGContext"
s_modifierFlags:        .asciz "modifierFlags"
s_charactersIgnoringModifiers: .asciz "charactersIgnoringModifiers"
s_length:               .asciz "length"
s_characterAtIndex:     .asciz "characterAtIndex:"
s_setNeedsDisplay:      .asciz "setNeedsDisplay:"
s_mouseDown:            .asciz "mouseDown:"
s_mouseDragged:         .asciz "mouseDragged:"
s_mouseUp:              .asciz "mouseUp:"
s_clickCount:           .asciz "clickCount"
s_locationInWindow:     .asciz "locationInWindow"
/* No label: a video answers to its kind, which is what a shared rule
   about videos has to be written against. */
s_no_label:             .asciz ""

        .zerofill __DATA,__bss,pixels,(WIN_W*WIN_H*4),4
        .zerofill __DATA,__bss,view_slot,8,3
/* Which applet the mouse has hold of, -1 for none, and where inside it. */
        .zerofill __DATA,__bss,drag_index,4,2
        .zerofill __DATA,__bss,drag_dx,4,2
        .zerofill __DATA,__bss,drag_dy,4,2
