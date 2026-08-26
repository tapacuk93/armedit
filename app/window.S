#include "asm.inc"
/*
 * window.S - hosted mode, windowed: the same glyphs, on a real macOS window.
 *
 * The letters are rasterized by font/render.S into a plain pixel buffer - no
 * text API and no UI widget draws a glyph.  AppKit and CoreGraphics appear
 * only to obtain a window and hand the finished buffer to the compositor, and
 * they are driven through the bare Objective-C runtime (objc_getClass /
 * sel_registerName / objc_msgSend) rather than any convenience layer.
 *
 * The pixel format is XRGB8888 little-endian, byte-identical to what the
 * kernel's ramfb scans out, so both modes share one renderer and one palette.
 */
#define SCALE           14
#define PAD             24
#define MAXCHARS        24
#define STRIDE          (MAXCHARS*GLYPH_ADV*SCALE + 2*PAD)
#define WIN_H           (GLYPH_H*SCALE + 2*PAD)
#define CG_XRGB32_LE    0x2006  /* kCGImageAlphaNoneSkipFirst | ByteOrder32Little */

/*
 * Objective-C sends.  NOTE: `recv` and `arg` must be callee-saved registers
 * (x19-x28) or immediates - sel_registerName clobbers x0-x18, so a value left
 * in a scratch register would be destroyed before objc_msgSend saw it.
 */
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

        cmp     w0, #2                  /* argv[1] overrides the banner */
        b.lt    1f
        ldr     x21, [x1, #8]
        b       2f
1:      LEA     x21, default_msg
2:
        mov     w23, #0                 /* measure, clamped to the buffer */
3:      ldrb    w9, [x21, w23, uxtw]
        cbz     w9, 4f
        add     w23, w23, #1
        cmp     w23, #MAXCHARS
        b.lt    3b
4:
        mov     w0, #(GLYPH_ADV*SCALE)  /* image width for this string */
        mul     w24, w23, w0
        sub     w24, w24, #SCALE        /* the trailing gap is not drawn */
        add     w24, w24, #(2*PAD)

        LEA     x22, pixels             /* backdrop */
        mov     x0, x22
        mov     w1, #STRIDE
        mov     w2, #0
        mov     w3, #0
        mov     w4, w24
        mov     w5, #WIN_H
        mov     w6, #0x1618
        movk    w6, #0xFF14, lsl #16
        bl      SYM(fb_fill)

        mov     x0, x22                 /* the letters themselves */
        mov     w1, #STRIDE
        mov     w2, #PAD
        mov     w3, #PAD
        mov     w4, #SCALE
        mov     w5, #0xE2B8
        movk    w5, #0xFF8A, lsl #16
        mov     x6, x21
        bl      SYM(font_draw_text)

/* ---------------------------------------------- wrap the buffer as a CGImage */
        bl      _CGColorSpaceCreateDeviceRGB
        mov     x25, x0
        mov     x0, x22
        mov     w1, w24                 /* width  */
        mov     x2, #WIN_H              /* height */
        mov     x3, #8                  /* bits per component */
        mov     x4, #(STRIDE*4)         /* bytes per row */
        mov     x5, x25
        mov     x6, #CG_XRGB32_LE
        bl      _CGBitmapContextCreate
        bl      _CGBitmapContextCreateImage
        mov     x26, x0                 /* CGImageRef */

/* ------------------------------------------------------------ NSApplication */
        CLS     s_NSApplication
        mov     x27, x0
        MSG0    x27, s_sharedApplication
        mov     x19, x0                 /* NSApp */
        MSG1    x19, s_setActivationPolicy, #0

/* ------------------------------------------------------------------ window */
        CLS     s_NSWindow
        mov     x27, x0
        MSG0    x27, s_alloc
        mov     x20, x0
        LEA     x0, s_initWithContentRect       /* resolve the selector before */
        bl      _sel_registerName               /* the float args: calls may   */
        mov     x1, x0                          /* clobber v0-v7               */
        mov     x2, #7                  /* titled | closable | miniaturizable */
        mov     x3, #2                  /* NSBackingStoreBuffered */
        mov     x4, #0                  /* defer: NO */
        fmov    d0, xzr                 /* NSRect origin.x */
        fmov    d1, xzr                 /* NSRect origin.y */
        ucvtf   d2, w24                 /* NSRect size.width  */
        mov     w9, #WIN_H
        ucvtf   d3, w9                  /* NSRect size.height */
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

/* --------------------------------------------- NSImage/NSImageView as canvas */
        CLS     s_NSImage
        mov     x27, x0
        MSG0    x27, s_alloc
        mov     x27, x0
        LEA     x0, s_initWithCGImage
        bl      _sel_registerName
        mov     x1, x0
        mov     x2, x26
        ucvtf   d0, w24                 /* NSSize width  */
        mov     w9, #WIN_H
        ucvtf   d1, w9                  /* NSSize height */
        mov     x0, x27
        bl      _objc_msgSend
        mov     x28, x0                 /* NSImage */

        CLS     s_NSImageView
        mov     x27, x0
        MSG1    x27, s_imageViewWithImage, x28
        mov     x28, x0
        MSG1    x20, s_setContentView, x28

/* ------------------------------- a delegate, so closing the window quits us */
        CLS     s_NSObject
        mov     x27, x0
        LEA     x1, s_delegate_cls
        mov     x2, #0
        mov     x0, x27
        bl      _objc_allocateClassPair
        mov     x27, x0
        LEA     x0, s_shouldTerminate
        bl      _sel_registerName
        mov     x1, x0
        LEA     x2, _delegate_should_terminate
        LEA     x3, s_types
        mov     x0, x27
        bl      _class_addMethod
        mov     x0, x27
        bl      _objc_registerClassPair
        MSG0    x27, s_alloc
        mov     x27, x0
        MSG0    x27, s_init
        mov     x27, x0
        MSG1    x19, s_setDelegate, x27

/* -------------------------------------------------------------------- show */
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

/* BOOL applicationShouldTerminateAfterLastWindowClosed:(NSApplication *) */
        .p2align 2
_delegate_should_terminate:
        mov     w0, #1
        ret

        CSTR
default_msg:            .asciz "ASMEDIT"
s_title:                .asciz "asmedit"
s_NSApplication:        .asciz "NSApplication"
s_NSWindow:             .asciz "NSWindow"
s_NSString:             .asciz "NSString"
s_NSImage:              .asciz "NSImage"
s_NSImageView:          .asciz "NSImageView"
s_NSObject:             .asciz "NSObject"
s_delegate_cls:         .asciz "AsmeditDelegate"
s_types:                .asciz "c@:@"
s_sharedApplication:    .asciz "sharedApplication"
s_setActivationPolicy:  .asciz "setActivationPolicy:"
s_alloc:                .asciz "alloc"
s_init:                 .asciz "init"
s_initWithContentRect:  .asciz "initWithContentRect:styleMask:backing:defer:"
s_stringWithUTF8String: .asciz "stringWithUTF8String:"
s_setTitle:             .asciz "setTitle:"
s_initWithCGImage:      .asciz "initWithCGImage:size:"
s_imageViewWithImage:   .asciz "imageViewWithImage:"
s_setContentView:       .asciz "setContentView:"
s_shouldTerminate:      .asciz "applicationShouldTerminateAfterLastWindowClosed:"
s_setDelegate:          .asciz "setDelegate:"
s_center:               .asciz "center"
s_makeKeyAndOrderFront: .asciz "makeKeyAndOrderFront:"
s_activateIgnoringOtherApps: .asciz "activateIgnoringOtherApps:"
s_run:                  .asciz "run"

        .zerofill __DATA,__bss,pixels,(STRIDE*WIN_H*4),4
