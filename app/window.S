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
        bl      SYM(env_init)           /* ASMEDIT_BACKEND / ASMEDIT_KEY */
        mov     x0, x27
        bl      SYM(editor_init)
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
        mov     x27, x0
        ADDM    x27, s_drawRect, view_draw_rect, t_drawRect
        ADDM    x27, s_keyDown, view_key_down, t_void_id
        ADDM    x27, s_performKeyEquivalent, view_perform_key_equiv, t_bool_id
        ADDM    x27, s_acceptsFirstResponder, view_accepts_first, t_bool
        ADDM    x27, s_mouseDown, view_mouse_down, t_void_id
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
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     x19, x0                 /* self  */
        mov     x20, x2                 /* event */
        MSG0    x20, s_locationInWindow
        fcvtzu  w0, d0
        fcvtzu  w1, d1
        mov     w2, #WIN_H
        sub     w1, w2, w1
        bl      SYM(editor_click)
        MSG1    x19, s_setNeedsDisplay, #1
        ldp     x19, x20, [sp, #16]
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
5:      mov     w0, w23
        bl      SYM(editor_key)
        cbz     w0, 6f                  /* ED_SUBMIT or ED_AIFY: go to the backend */
        bl      SYM(backend_submit)
6:      MSG1    x19, s_setNeedsDisplay, #1

.Lhe_out:
        ldr     x23, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

        CSTR
s_title:                .asciz "asmedit"
seed_text:              .asciz "ASMEDIT SCREEN 1\nCMD+T NEW SCREEN   CMD+LEFT/RIGHT SWITCH\nCMD+DELETE CLOSE   CLICK TO PLACE THE CARET\nCMD+ENTER ASK       CMD+P REWRITE\n\nTYPE HERE.\n"
s_view_cls:             .asciz "AsmeditView"
s_delegate_cls:         .asciz "AsmeditDelegate"
t_drawRect:             .asciz "v@:{CGRect={CGPoint=dd}{CGSize=dd}}"
t_void_id:              .asciz "v@:@"
t_bool_id:              .asciz "c@:@"
t_bool:                 .asciz "c@:"
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
s_locationInWindow:     .asciz "locationInWindow"

        .zerofill __DATA,__bss,pixels,(WIN_W*WIN_H*4),4
