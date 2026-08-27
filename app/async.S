#include "asm.inc"
#include "editor.inc"
/*
 * async.S - asking the backend without freezing the screen.
 *
 * A model can take a minute.  Done on the thread that draws, that minute is a
 * window that does not repaint, does not scroll and does not answer - the
 * caret sits there and the whole thing looks dead or, worse, looks like it is
 * still waiting for you to type.
 *
 * So the call goes to a background queue and the screen keeps its own thread.
 * Before it leaves, the editor is marked busy, which replaces the caret with a
 * mark that could only mean waiting; when the answer lands the work hops back
 * to the main queue to clear the mark and redraw, because touching UIKit or
 * AppKit from anywhere else is not allowed.
 *
 * GCD is the platform's own scheduler rather than a library of ours - the same
 * relationship the window has with AppKit.  On the bare-metal build there is
 * no queue and no main thread to return to, and this file has no part in it.
 */
        CODE
        .p2align 2

/*
 * async_ask - w0 = ED_SUBMIT, ED_AIFY or ED_SWIPE.
 *
 * Returns immediately.  The screen redraws once showing the waiting mark, the
 * request goes out on a background queue, and the answer arrives back on the
 * main one.
 */
        .globl  SYM(async_ask)
SYM(async_ask):
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        LEA     x9, async_mode
        str     w0, [x9]

        mov     w0, #1                  /* the caret becomes a waiting mark */
        bl      SYM(editor_busy)
        bl      SYM(app_redraw)

        mov     x0, #0                  /* DISPATCH_QUEUE_PRIORITY_DEFAULT */
        mov     x1, #0
        bl      _dispatch_get_global_queue
        mov     x1, #0
        LEA     x2, async_work
        bl      _dispatch_async_f

        ldp     x29, x30, [sp], #32
        ret

/*
 * The request itself, on somebody else's thread.
 *
 * Only the fetch happens here.  Applying the answer means rewriting the
 * screen's text, and doing that from a background thread would rewrite the
 * buffer underneath a redraw that is reading it - so that half waits for the
 * main thread, which app_finish arranges.
 */
        .p2align 2
async_work:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        LEA     x9, async_mode
        ldr     w0, [x9]
        bl      SYM(backend_fetch)
        bl      SYM(app_finish)         /* hops to the main thread and calls
                                           async_finish there */
        ldp     x29, x30, [sp], #32
        ret

/*
 * async_finish - the main thread, once the answer is in.  The front end calls
 * this from its own hop, so everything below runs where the drawing runs.
 */
        .p2align 2
        .globl  SYM(async_finish)
SYM(async_finish):
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        LEA     x9, async_mode
        ldr     w0, [x9]
        bl      SYM(backend_apply)
        mov     w0, #0
        bl      SYM(editor_busy)
        bl      SYM(app_redraw)
        ldp     x29, x30, [sp], #32
        ret

        BSS
        .p2align 2
async_mode:     .space 8
