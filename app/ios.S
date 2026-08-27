#include "asm.inc"
#include "editor.inc"
/*
 * ios.S - armedit on iPhone.
 *
 * The same editor core, the same rasterizer, the same pixels.  UIKit appears
 * only to obtain a window and a touch stream; it draws no glyph and lays out
 * no text.  As on macOS, the view class does not exist until this program
 * builds it: UIView is subclassed at runtime and every method below is an
 * assembly routine installed with class_addMethod.
 *
 * What is different from the desktop is the shape of the surface.  A phone
 * rotates, so nothing here assumes a size: the editor renders at whatever
 * bounds the view currently has, and a rotation is just another drawRect.
 *
 * Typing comes from UIKeyInput - the system keyboard talking to insertText:
 * and deleteBackward - and a two-finger tap pastes.  A keyboard drawn by us,
 * from applets the server describes, is the next step; this one exists so the
 * thing can be typed into today.
 *
 * NOTE on the MSG macros: `recv` and `arg` must be callee-saved registers
 * (x19-x28) or immediates - sel_registerName clobbers x0-x18, so a value in a
 * scratch register would be destroyed before objc_msgSend saw it.
 */
#define MAX_W           1400            /* the widest surface we will render */
#define MAX_H           1400
#define KB_TOP_BP       5800    /* must match applet.S's keyboard geometry */
#define CG_XRGB32_LE    0x2006  /* kCGImageAlphaNoneSkipFirst | ByteOrder32Little */

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
        mov     w19, w0                 /* argc */
        mov     x20, x1                 /* argv */

        mov     x0, x2
        bl      SYM(env_init)           /* ARMEDIT_KEY, when there is one */
        bl      SYM(editor_init)
        LEA     x0, seed_text
        bl      SYM(editor_insert_str)
        mov     w0, #0                  /* our keyboard, not the system's */
        bl      SYM(keyboard_build)

        bl      build_classes

        CLS     s_NSString              /* UIApplicationMain wants the delegate
                                           class as an NSString, not a C string */
        mov     x21, x0
        LEA     x0, s_stringWithUTF8String
        bl      _sel_registerName
        mov     x1, x0
        LEA     x2, s_delegate_cls
        mov     x0, x21
        bl      _objc_msgSend
        mov     x22, x0

        mov     w0, w19                 /* UIApplicationMain(argc, argv, nil,   */
        mov     x1, x20                 /*                   ArmeditDelegate)   */
        mov     x2, #0
        mov     x3, x22
        bl      _UIApplicationMain

        mov     w0, #0
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

/* ------------------------------------------------ the classes, at runtime */
build_classes:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]

        CLS     s_NSObject              /* the app delegate */
        mov     x19, x0
        LEA     x1, s_delegate_cls
        mov     x2, #0
        mov     x0, x19
        bl      _objc_allocateClassPair
        mov     x19, x0
        ADDM    x19, s_didFinishLaunching, app_did_finish, t_bool_id_id
        mov     x0, x19
        bl      _objc_registerClassPair

        CLS     s_UIView                /* the surface */
        mov     x20, x0
        LEA     x1, s_view_cls
        mov     x2, #0
        mov     x0, x20
        bl      _objc_allocateClassPair
        mov     x20, x0
        ADDM    x20, s_drawRect, view_draw_rect, t_drawRect
        ADDM    x20, s_touchesBegan, view_touches_began, t_void_id_id
        mov     x0, x20
        bl      _objc_registerClassPair

        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* ------------------------------------------------------- the app delegate */
/*
 * - (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(id)o
 * Build a window the size of the screen, put a view controller in it holding
 * our surface, and let the surface take the keyboard.
 */
        .p2align 2
app_did_finish:
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]

        CLS     s_UIScreen              /* [[UIScreen mainScreen] bounds] */
        mov     x19, x0
        MSG0    x19, s_mainScreen
        mov     x19, x0
        LEA     x0, s_bounds
        bl      _sel_registerName
        mov     x1, x0
        mov     x0, x19
        bl      _objc_msgSend           /* CGRect comes back in d0-d3 */
        fmov    d4, d0                  /* keep it while we allocate */
        fmov    d5, d1
        fmov    d6, d2
        fmov    d7, d3

        CLS     s_UIWindow
        mov     x19, x0
        MSG0    x19, s_alloc
        mov     x19, x0
        LEA     x0, s_initWithFrame
        bl      _sel_registerName
        mov     x1, x0
        mov     x0, x19
        fmov    d0, d4
        fmov    d1, d5
        fmov    d2, d6
        fmov    d3, d7
        bl      _objc_msgSend
        mov     x20, x0                 /* the window */

        LEA     x0, s_view_cls          /* our surface, same frame */
        bl      _objc_getClass
        mov     x21, x0
        MSG0    x21, s_alloc
        mov     x21, x0
        LEA     x0, s_initWithFrame
        bl      _sel_registerName
        mov     x1, x0
        mov     x0, x21
        fmov    d0, d4
        fmov    d1, d5
        fmov    d2, d6
        fmov    d3, d7
        bl      _objc_msgSend
        mov     x21, x0

        CLS     s_UIViewController      /* a window needs one to show anything */
        mov     x22, x0
        MSG0    x22, s_alloc
        mov     x22, x0
        MSG0    x22, s_init
        mov     x22, x0
        MSG1    x22, s_setView, x21
        MSG1    x20, s_setRootViewController, x22
        MSG0    x20, s_makeKeyAndVisible

        LEA     x9, window_slot         /* the window must outlive this call */
        str     x20, [x9]
        LEA     x9, view_slot
        str     x21, [x9]

        mov     w0, #1
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

/* ------------------------------------------------------ the view's methods */

/*
 * - (void)drawRect:(CGRect)dirty
 *
 * Render at whatever size the view is now: a rotation arrives here as nothing
 * more than different bounds.  iOS hands us a flipped context, so the image is
 * drawn through a flip rather than upside down.
 */
        .p2align 2
view_draw_rect:
        stp     x29, x30, [sp, #-112]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        stp     x27, x28, [sp, #80]
        mov     x19, x0                 /* self */

        LEA     x0, s_bounds            /* how big are we this time? */
        bl      _sel_registerName
        mov     x1, x0
        mov     x0, x19
        bl      _objc_msgSend
        fcvtzu  w23, d2                 /* width  */
        fcvtzu  w24, d3                 /* height */
        mov     w9, #MAX_W
        cmp     w23, w9
        csel    w23, w23, w9, lo
        mov     w9, #MAX_H
        cmp     w24, w9
        csel    w24, w24, w9, lo
        cbz     w23, .Ldraw_out
        cbz     w24, .Ldraw_out
        LEA     x9, s_view_h            /* the flip and hit testing both need
                                           the surface these were drawn on */
        str     w24, [x9]
        LEA     x9, s_view_w
        str     w23, [x9]

        LEA     x0, s_safeAreaInsets    /* keep clear of the island and the bar */
        bl      _sel_registerName
        mov     x1, x0
        mov     x0, x19
        bl      _objc_msgSend           /* UIEdgeInsets: top, left, bottom, right */
        fcvtzu  w25, d0                 /* top    */
        fcvtzu  w26, d2                 /* bottom */
        add     w9, w25, w26
        cmp     w24, w9
        b.ls    1f
        sub     w24, w24, w9            /* the height actually available */
1:

        mov     w9, #KB_TOP_BP          /* the text gets the space above the keys */
        mul     w9, w24, w9
        mov     w10, #10000
        udiv    w28, w9, w10
        LEA     x0, pixels
        mov     w1, #MAX_W
        mov     w2, w23
        mov     w3, w28
        bl      SYM(editor_render)

        LEA     x0, pixels              /* clear the band the keys sit on */
        mov     w1, #MAX_W
        mov     w2, #0
        mov     w3, w28
        mov     w4, w23
        sub     w5, w24, w28
        mov     w6, #0x1618
        movk    w6, #0xFF14, lsl #16
        bl      SYM(fb_fill)

        LEA     x0, pixels
        mov     w1, #MAX_W
        mov     w2, w23
        mov     w3, w24
        bl      SYM(applet_render)

        bl      _CGColorSpaceCreateDeviceRGB
        mov     x20, x0
        LEA     x0, pixels
        mov     w1, w23
        mov     w2, w24
        mov     x3, #8
        mov     x4, #(MAX_W * 4)
        mov     x5, x20
        mov     x6, #CG_XRGB32_LE
        bl      _CGBitmapContextCreate
        mov     x21, x0
        bl      _CGBitmapContextCreateImage
        mov     x22, x0

        bl      _UIGraphicsGetCurrentContext
        mov     x27, x0
        cbz     x27, .Ldraw_free

        mov     x0, x27                 /* undo UIKit's flip for the blit */
        LEA     x9, s_view_h
        ldr     w9, [x9]
        fmov    d0, xzr
        ucvtf   d1, w9
        bl      _CGContextTranslateCTM
        mov     x0, x27
        fmov    d0, #1.0
        fmov    d1, #-1.0
        bl      _CGContextScaleCTM

        /* In the flipped space a rect's bottom lands at (viewHeight - y), so
           placing the image's top edge at the safe-area inset means drawing it
           at y = bottomInset. */
        mov     x0, x27
        mov     x1, x22
        fmov    d0, xzr
        ucvtf   d1, w26
        ucvtf   d2, w23
        ucvtf   d3, w24
        bl      _CGContextDrawImage

.Ldraw_free:
        mov     x0, x22
        bl      _CGImageRelease
        mov     x0, x21
        bl      _CGContextRelease
        mov     x0, x20
        bl      _CGColorSpaceRelease
.Ldraw_out:
        ldp     x27, x28, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #112
        ret

/*
 * - (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
 *
 * One finger places the caret where you touched.  Two fingers paste, because
 * a phone has no Cmd+V and a long-press menu is a worse first answer than a
 * gesture that always works.
 */
        .p2align 2
view_touches_began:
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        str     x25, [sp, #64]
        mov     x19, x0                 /* self */
        mov     x20, x2                 /* touches */

        MSG0    x20, s_count
        cmp     x0, #2
        b.lo    1f
        bl      paste_from_board
        b       .Ltouch_redraw

1:      MSG0    x20, s_anyObject
        mov     x21, x0
        cbz     x21, .Ltouch_out
        LEA     x0, s_locationInView
        bl      _sel_registerName
        mov     x1, x0
        mov     x2, x19
        mov     x0, x21
        bl      _objc_msgSend           /* CGPoint in d0/d1 */
        fcvtzu  w22, d0
        fcvtzu  w23, d1

        LEA     x9, s_view_w            /* the surface the layout was drawn on */
        ldr     w24, [x9]
        LEA     x9, s_view_h
        ldr     w25, [x9]
        mov     w0, w22
        mov     w1, w23
        mov     w2, w24
        mov     w3, w25
        bl      SYM(applet_hit)
        tbnz    w0, #31, 2f
        bl      SYM(applet_action)      /* a key: feed it in like any other */
        bl      SYM(editor_key)
        b       .Ltouch_redraw
2:      mov     w0, w22                 /* no key there: place the caret */
        mov     w1, w23
        bl      SYM(editor_click)

.Ltouch_redraw:
        MSG0    x19, s_setNeedsDisplay
.Ltouch_out:
        ldr     x25, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

/* - (void)insertText:(NSString *)text - the system keyboard, one string at a time */
        .p2align 2
view_insert_text:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     x19, x0                 /* self */
        mov     x20, x2                 /* the text */
        cbz     x20, .Lins_out
        LEA     x0, s_UTF8String
        bl      _sel_registerName
        mov     x1, x0
        mov     x0, x20
        bl      _objc_msgSend
        cbz     x0, .Lins_out
        mov     x20, x0
1:      ldrb    w0, [x20], #1           /* feed it in as keys, so every path
                                           through the editor stays the same */
        cbz     w0, 2f
        cmp     w0, #'\n'
        b.ne    3f
        mov     w0, #K_ENTER
3:      bl      SYM(editor_key)
        b       1b
2:      MSG1    x19, s_setNeedsDisplay, #0
.Lins_out:
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* - (void)deleteBackward */
        .p2align 2
view_delete_backward:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     x19, x0
        mov     w0, #K_BS
        bl      SYM(editor_key)
        MSG0    x19, s_setNeedsDisplay
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/* paste_from_board - whatever is on the pasteboard, typed in at the caret */
        .p2align 2
paste_from_board:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        CLS     s_UIPasteboard
        mov     x19, x0
        MSG0    x19, s_generalPasteboard
        mov     x19, x0
        cbz     x19, .Lpaste_out
        MSG0    x19, s_string
        cbz     x0, .Lpaste_out
        mov     x19, x0
        LEA     x0, s_UTF8String
        bl      _sel_registerName
        mov     x1, x0
        mov     x0, x19
        bl      _objc_msgSend
        cbz     x0, .Lpaste_out
        mov     x20, x0
1:      ldrb    w0, [x20], #1
        cbz     w0, .Lpaste_out
        cmp     w0, #'\n'
        b.ne    2f
        mov     w0, #K_ENTER
2:      bl      SYM(editor_key)
        b       1b
.Lpaste_out:
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* - (BOOL)canBecomeFirstResponder / hasText */
        .p2align 2
view_yes:
        mov     w0, #1
        ret

        CSTR
seed_text:              .asciz "ARMEDIT ON IPHONE\nOUR KEYBOARD, NOT THE SYSTEM ONE\nTAP TEXT TO PLACE THE CARET\nTWO FINGERS TO PASTE\n\n"
s_delegate_cls:         .asciz "ArmeditDelegate"
s_view_cls:             .asciz "ArmeditView"
s_NSObject:             .asciz "NSObject"
s_NSString:             .asciz "NSString"
s_UIView:               .asciz "UIView"
s_UIWindow:             .asciz "UIWindow"
s_UIScreen:             .asciz "UIScreen"
s_UIViewController:     .asciz "UIViewController"
s_UIPasteboard:         .asciz "UIPasteboard"
s_UIKeyInput:           .asciz "UIKeyInput"
s_didFinishLaunching:   .asciz "application:didFinishLaunchingWithOptions:"
s_drawRect:             .asciz "drawRect:"
s_touchesBegan:         .asciz "touchesBegan:withEvent:"
s_canBecomeFirstResponder: .asciz "canBecomeFirstResponder"
s_insertText:           .asciz "insertText:"
s_deleteBackward:       .asciz "deleteBackward"
s_hasText:              .asciz "hasText"
s_alloc:                .asciz "alloc"
s_init:                 .asciz "init"
s_initWithFrame:        .asciz "initWithFrame:"
s_bounds:               .asciz "bounds"
s_mainScreen:           .asciz "mainScreen"
s_setView:              .asciz "setView:"
s_setRootViewController:.asciz "setRootViewController:"
s_makeKeyAndVisible:    .asciz "makeKeyAndVisible"
s_becomeFirstResponder: .asciz "becomeFirstResponder"
s_setNeedsDisplay:      .asciz "setNeedsDisplay"
s_locationInView:       .asciz "locationInView:"
s_safeAreaInsets:       .asciz "safeAreaInsets"
s_anyObject:            .asciz "anyObject"
s_count:                .asciz "count"
s_generalPasteboard:    .asciz "generalPasteboard"
s_string:               .asciz "string"
s_UTF8String:           .asciz "UTF8String"
s_stringWithUTF8String: .asciz "stringWithUTF8String:"
t_drawRect:             .asciz "v@:{CGRect={CGPoint=dd}{CGSize=dd}}"
t_void_id:              .asciz "v@:@"
t_void_id_id:           .asciz "v@:@@"
t_void:                 .asciz "v@:"
t_bool:                 .asciz "c@:"
t_bool_id_id:           .asciz "c@:@@"

        .zerofill __DATA,__bss,pixels,(MAX_W*MAX_H*4),4
        .zerofill __DATA,__bss,s_view_h,8,2
        .zerofill __DATA,__bss,s_view_w,8,2
        .zerofill __DATA,__bss,window_slot,8,3
        .zerofill __DATA,__bss,view_slot,8,3
