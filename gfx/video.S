#include "asm.inc"
/*
 * video.S - the ARMV1 decoder (see docs/armv1.md).
 *
 * This is the whole of video playback in armedit: a palette, a run-length
 * decoder for key frames, a skip/copy decoder for deltas, and an expansion
 * into the one pixel format the rest of the program uses. There is no library
 * underneath it and there is no second implementation for the bootable mode -
 * the kernel plays video with these same instructions.
 *
 * The decoder holds exactly one frame of state, the index plane, because a
 * delta frame is defined against the frame before it and nothing earlier.
 * That is what keeps the memory here fixed and the code short enough to trust.
 *
 * Every loop below is bounded twice: by the payload it was given and by the
 * pixel count of the frame. A file that lies about either - truncated in
 * transit, or deliberately malformed - runs out of one bound or the other and
 * stops, leaving a partial frame rather than walking off the buffer. A decoder
 * that reads bytes off the network is not a place to trust a length field.
 */

#define VID_MAX_W       320
#define VID_MAX_H       240
#define VID_MAX_PX      (VID_MAX_W * VID_MAX_H)

/* Blit descriptor, shared with gfx/image.S. */
#define BL_DST          0
#define BL_STRIDE       8
#define BL_DX           12
#define BL_DY           16
#define BL_DW           20
#define BL_DH           24
#define BL_SRC          32
#define BL_SW           40
#define BL_SH           44

        CODE
        .p2align 2

/*
 * video_open - x0 = the file bytes, w1 = how many.
 *   out w0 = 0 when it is a video we can play, -1 when it is not.
 *
 * Nothing is copied. The caller owns the bytes and must keep them alive for
 * as long as it intends to keep decoding, which is the same contract the
 * image loader has.
 */
        .globl  SYM(video_open)
SYM(video_open):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0
        mov     w20, w1

        LEA     x21, vid_open           /* any failure below leaves it shut */
        str     wzr, [x21]

        cmp     w20, #16
        b.lo    .Lvo_bad

        ldr     w9, [x19]               /* "ARMV" */
        movz    w10, #0x5241
        movk    w10, #0x564D, lsl #16
        cmp     w9, w10
        b.ne    .Lvo_bad
        ldrb    w9, [x19, #4]
        cmp     w9, #1
        b.ne    .Lvo_bad

        ldrh    w22, [x19, #6]          /* width */
        cbz     w22, .Lvo_bad
        mov     w9, #VID_MAX_W
        cmp     w22, w9
        b.hi    .Lvo_bad
        ldrh    w9, [x19, #8]           /* height */
        cbz     w9, .Lvo_bad
        mov     w10, #VID_MAX_H
        cmp     w9, w10
        b.hi    .Lvo_bad

        LEA     x10, vid_w
        str     w22, [x10]
        LEA     x10, vid_h
        str     w9, [x10]

        ldrh    w10, [x19, #10]         /* frame count */
        cbz     w10, .Lvo_bad
        LEA     x11, vid_count
        str     w10, [x11]
        ldrh    w10, [x19, #12]         /* fps; 0 would divide by zero later */
        cbnz    w10, 1f
        mov     w10, #12
1:      LEA     x11, vid_fps
        str     w10, [x11]

        ldrh    w10, [x19, #14]         /* palette entries */
        cbz     w10, .Lvo_bad
        mov     w11, #256
        cmp     w10, w11
        b.hi    .Lvo_bad
        LEA     x11, vid_ncol
        str     w10, [x11]

        add     x11, x19, #16           /* the palette itself */
        LEA     x12, vid_pal
        str     x11, [x12]

        add     w12, w10, w10, lsl #1   /* 3 * entries */
        add     x11, x11, w12, uxtw     /* first frame record */
        add     x13, x19, w20, uxtw     /* one past the last byte */
        cmp     x11, x13
        b.hi    .Lvo_bad

        LEA     x12, vid_data
        str     x19, [x12]
        LEA     x12, vid_end
        str     x13, [x12]
        LEA     x12, vid_first
        str     x11, [x12]
        LEA     x12, vid_pos
        str     x11, [x12]
        LEA     x12, vid_at
        str     wzr, [x12]

        mul     w9, w22, w9             /* a fresh plane, so a first frame that */
        LEA     x10, vid_plane          /* is somehow a delta starts from black */
        mov     w11, #0
2:      cmp     w11, w9
        b.hs    3f
        strb    wzr, [x10, w11, uxtw]
        add     w11, w11, #1
        b       2b
3:
        mov     w9, #1
        str     w9, [x21]               /* open */
        mov     w0, #0
        b       .Lvo_out
.Lvo_bad:
        mov     w0, #-1
.Lvo_out:
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * video_next - decode the frame after the one showing, into the plane and
 * then into pixels.
 *   out w0 = 0, or -1 when nothing is open.
 *
 * At the end of the clip it returns to the beginning. That is safe precisely
 * because frame 0 is always a key frame: rewinding never lands on a delta
 * whose reference frame has been thrown away.
 */
        .globl  SYM(video_next)
SYM(video_next):
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        stp     x27, x28, [sp, #80]

        LEA     x9, vid_open
        ldr     w9, [x9]
        cbz     w9, .Lvn_bad

        LEA     x9, vid_at              /* wrap */
        ldr     w10, [x9]
        LEA     x11, vid_count
        ldr     w11, [x11]
        cmp     w10, w11
        b.lo    1f
        str     wzr, [x9]
        LEA     x11, vid_first
        ldr     x11, [x11]
        LEA     x12, vid_pos
        str     x11, [x12]
1:
        LEA     x9, vid_pos
        ldr     x19, [x9]               /* the record */
        LEA     x9, vid_end
        ldr     x20, [x9]

        add     x9, x19, #5             /* a record is 4 + 1 + payload */
        cmp     x9, x20
        b.hi    .Lvn_bad

        ldr     w21, [x19]              /* payload length */
        ldrb    w22, [x19, #4]          /* kind */
        add     x23, x19, #5            /* payload */
        add     x9, x23, w21, uxtw
        cmp     x9, x20
        b.hi    .Lvn_bad                /* it claims more than the file holds */

        LEA     x9, vid_w
        ldr     w24, [x9]
        LEA     x9, vid_h
        ldr     w9, [x9]
        mul     w24, w24, w9            /* pixels in a frame */
        LEA     x25, vid_plane

        cbnz    w22, .Lvn_delta

/* --- key frame: (count, index) pairs over the whole plane --------------- */
        mov     w26, #0                 /* payload cursor */
        mov     w27, #0                 /* pixel cursor */
1:      cmp     w27, w24                /* clear first: a short stream must */
        b.hs    2f                      /* leave black, not the frame before */
        strb    wzr, [x25, w27, uxtw]
        add     w27, w27, #1
        b       1b
2:      mov     w27, #0
.Lvn_krun:
        add     w9, w26, #1
        cmp     w9, w21
        b.hs    .Lvn_show               /* fewer than two bytes left */
        cmp     w27, w24
        b.hs    .Lvn_show
        ldrb    w10, [x23, w26, uxtw]   /* run */
        ldrb    w11, [x23, w9, uxtw]    /* index */
        add     w26, w26, #2
        cbz     w10, .Lvn_krun          /* a zero run would not advance */
        sub     w12, w24, w27           /* clamp to what is left of the frame */
        cmp     w10, w12
        csel    w10, w10, w12, ls
        add     w12, w27, w10
1:      cmp     w27, w12
        b.hs    2f
        strb    w11, [x25, w27, uxtw]
        add     w27, w27, #1
        b       1b
2:      b       .Lvn_krun

/* --- delta frame: skip runs and copy runs over the previous plane ------- */
.Lvn_delta:
        mov     w26, #0
        mov     w27, #0
.Lvn_dop:
        cmp     w26, w21
        b.hs    .Lvn_show
        cmp     w27, w24
        b.hs    .Lvn_show
        ldrb    w10, [x23, w26, uxtw]
        add     w26, w26, #1
        and     w11, w10, #0x7f
        add     w11, w11, #1            /* run, 1..128 */
        sub     w12, w24, w27
        cmp     w11, w12
        csel    w11, w11, w12, ls       /* clamp to the frame */
        tbz     w10, #7, .Lvn_dskip

        sub     w12, w21, w26           /* clamp to the payload too */
        cmp     w11, w12
        csel    w11, w11, w12, ls
        add     w12, w27, w11
1:      cmp     w27, w12
        b.hs    2f
        ldrb    w13, [x23, w26, uxtw]
        strb    w13, [x25, w27, uxtw]
        add     w26, w26, #1
        add     w27, w27, #1
        b       1b
2:      b       .Lvn_dop
.Lvn_dskip:
        add     w27, w27, w11           /* untouched: it keeps its colour */
        b       .Lvn_dop

/* --- indices become pixels --------------------------------------------- */
.Lvn_show:
        add     x9, x19, #5
        add     x9, x9, w21, uxtw
        LEA     x10, vid_pos
        str     x9, [x10]
        LEA     x10, vid_at
        ldr     w11, [x10]
        add     w11, w11, #1
        str     w11, [x10]

        bl      SYM(video_expand)
        mov     w0, #0
        b       .Lvn_out
.Lvn_bad:
        mov     w0, #-1
.Lvn_out:
        ldp     x27, x28, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

/*
 * video_expand - the index plane through the palette into 0xAARRGGBB.
 *
 * An index past the end of the palette is a corrupt file, not a reason to
 * read past the palette, so it reads as entry zero.
 */
        .globl  SYM(video_expand)
SYM(video_expand):
        LEA     x9, vid_w
        ldr     w9, [x9]
        LEA     x10, vid_h
        ldr     w10, [x10]
        mul     w9, w9, w10             /* pixels */
        LEA     x11, vid_plane
        LEA     x12, vid_rgba
        LEA     x13, vid_pal
        ldr     x13, [x13]
        LEA     x14, vid_ncol
        ldr     w14, [x14]
        mov     w15, #0
1:      cmp     w15, w9
        b.hs    9f
        ldrb    w16, [x11, w15, uxtw]
        cmp     w16, w14
        csel    w16, w16, wzr, lo
        add     w17, w16, w16, lsl #1   /* 3 * index */
        ldrb    w0, [x13, w17, uxtw]    /* r */
        add     w1, w17, #1
        ldrb    w1, [x13, w1, uxtw]     /* g */
        add     w2, w17, #2
        ldrb    w2, [x13, w2, uxtw]     /* b */
        orr     w2, w2, w1, lsl #8
        orr     w2, w2, w0, lsl #16
        movz    w3, #0
        movk    w3, #0xFF00, lsl #16
        orr     w2, w2, w3              /* opaque */
        str     w2, [x12, w15, uxtw #2]
        add     w15, w15, #1
        b       1b
9:      ret

/*
 * video_present - x0 = surface, w1 = stride in pixels,
 *                 w2 = x, w3 = y, w4 = w, w5 = h.
 *
 * The frame is scaled to whatever rectangle the applet occupies, by the same
 * box filter that scales an image, so a video widget resizes with the window
 * exactly the way a picture does.
 */
        .globl  SYM(video_present)
SYM(video_present):
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp

        LEA     x9, vid_open
        ldr     w9, [x9]
        cbz     w9, 9f
        cbz     w4, 9f
        cbz     w5, 9f

        str     x0, [sp, #48 + BL_DST]
        str     w1, [sp, #48 + BL_STRIDE]
        str     w2, [sp, #48 + BL_DX]
        str     w3, [sp, #48 + BL_DY]
        str     w4, [sp, #48 + BL_DW]
        str     w5, [sp, #48 + BL_DH]
        LEA     x9, vid_rgba
        str     x9, [sp, #48 + BL_SRC]
        LEA     x9, vid_w
        ldr     w9, [x9]
        str     w9, [sp, #48 + BL_SW]
        LEA     x9, vid_h
        ldr     w9, [x9]
        str     w9, [sp, #48 + BL_SH]

        add     x0, sp, #48
        bl      SYM(image_blit)
9:      ldp     x29, x30, [sp], #96
        ret

/* video_ok - is there a clip loaded? */
        .globl  SYM(video_ok)
SYM(video_ok):
        LEA     x9, vid_open
        ldr     w0, [x9]
        ret

/* video_dims - w0 = width, w1 = height */
        .globl  SYM(video_dims)
SYM(video_dims):
        LEA     x9, vid_w
        ldr     w0, [x9]
        LEA     x9, vid_h
        ldr     w1, [x9]
        ret

/* video_fps - frames per second, as the file asked for */
        .globl  SYM(video_fps)
SYM(video_fps):
        LEA     x9, vid_fps
        ldr     w0, [x9]
        ret

/* video_count - how many frames the clip has */
        .globl  SYM(video_count)
SYM(video_count):
        LEA     x9, vid_count
        ldr     w0, [x9]
        ret

/* video_frame - which frame comes next */
        .globl  SYM(video_frame)
SYM(video_frame):
        LEA     x9, vid_at
        ldr     w0, [x9]
        ret

/* video_pixels - the decoded frame, for anyone who wants the bytes */
        .globl  SYM(video_pixels)
SYM(video_pixels):
        LEA     x0, vid_rgba
        ret

/* video_close - forget the clip; the bytes were never ours to free */
        .globl  SYM(video_close)
SYM(video_close):
        LEA     x9, vid_open
        str     wzr, [x9]
        ret

        BSS
        .p2align 3
vid_data:   .space 8
vid_end:    .space 8
vid_pos:    .space 8
vid_first:  .space 8
vid_pal:    .space 8
vid_w:      .space 4
vid_h:      .space 4
vid_count:  .space 4
vid_fps:    .space 4
vid_ncol:   .space 4
vid_at:     .space 4
vid_open:   .space 4
        .p2align 3
vid_plane:  .space VID_MAX_PX
        .p2align 3
vid_rgba:   .space (VID_MAX_PX * 4)
