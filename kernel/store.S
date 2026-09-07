#include "asm.inc"
/*
 * store.S - keeping what was written.
 *
 * Everything else about this machine is now there: a screen, a keyboard, a
 * network, a disk. What was missing is the one thing that makes it somewhere
 * to work rather than something to look at - text typed into it survived
 * exactly as long as the power did.
 *
 * <h2>No filesystem, and why that is the right amount</h2>
 *
 * The disk is written as sectors, with a header in the first one and the text
 * after it. There is no directory, no allocation and no second document,
 * because none of those is what is missing: what is missing is that closing
 * the machine loses the work. A filesystem is a large, careful thing to write
 * and the day it is needed is the day there is a second document - and on that
 * day it can be written knowing what it is for, rather than guessed at now.
 *
 * <h2>The header is a refusal, not a formality</h2>
 *
 * The magic is checked before anything is loaded. A disk that was never
 * written by this - somebody's photographs, an installer, an empty file - is
 * not a document, and reading eight kilobytes of it into the editor as text
 * would be the sort of thing that looks like a corrupted file and is actually
 * a machine treating a stranger's data as its own.
 */

#define SECTOR          512
#define TEXT_MAX        8192            /* one screen, per include/editor.inc */
#define TEXT_LBA        1               /* the header has the first sector */

        CODE
        .p2align 2

/*
 * store_save - out w0 = 0 if it is on the disk, -1 if it is not.
 *
 * The header is written last. Until it is, the disk still describes whatever
 * was there before - so a machine that loses power halfway through this comes
 * back with the previous document rather than with half of two.
 */
        .globl  SYM(store_save)
SYM(store_save):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]

        bl      SYM(store_dev_ready)
        cbz     w0, 9f

        bl      SYM(editor_length)
        mov     w19, w0
        cmp     w19, #TEXT_MAX
        b.hi    9f

        mov     w0, #0
        mov     w1, w19
        LEA     x2, st_text
        mov     w3, #TEXT_MAX
        bl      SYM(editor_range_text)
        mov     w19, w0

/* Whole sectors, and the tail of the last one cleared rather than left. */
        add     w20, w19, #(SECTOR - 1)
        lsr     w20, w20, #9
        cbnz    w20, 1f
        mov     w20, #1                 /* an empty document is still a write */
1:      lsl     w9, w20, #9
        mov     w10, w19
2:      cmp     w10, w9
        b.hs    3f
        LEA     x11, st_text
        strb    wzr, [x11, w10, uxtw]
        add     w10, w10, #1
        b       2b
3:
        mov     w0, #TEXT_LBA
        mov     w1, w20
        LEA     x2, st_text
        bl      SYM(store_dev_write)
        cmn     w0, #1
        b.eq    9f

        LEA     x0, st_sector
        mov     x1, #SECTOR
        bl      st_zero
        LEA     x9, st_sector
        LEA     x10, s_magic
        mov     w11, #0
4:      cmp     w11, #8
        b.hs    5f
        ldrb    w12, [x10, w11, uxtw]
        strb    w12, [x9, w11, uxtw]
        add     w11, w11, #1
        b       4b
5:      str     w19, [x9, #8]           /* how many bytes are the document */
        mov     w0, #0
        mov     w1, #1
        LEA     x2, st_sector
        bl      SYM(store_dev_write)
        cmn     w0, #1
        b.eq    9f
        mov     w0, #0
        b       8f
9:      mov     w0, #-1
8:      ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * store_load - out w0 = how many bytes were put on the screen, or -1.
 *
 * Called at boot, before anybody has typed anything. It inserts rather than
 * replaces because there is nothing to replace: an editor that had text in it
 * and then read a document over the top would be a machine that eats what you
 * were doing every time it finds a disk.
 */
        .globl  SYM(store_load)
SYM(store_load):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]

        bl      SYM(store_dev_ready)
        cbz     w0, 9f

        mov     w0, #0
        mov     w1, #1
        LEA     x2, st_sector
        bl      SYM(store_dev_read)
        cmn     w0, #1
        b.eq    9f

/*
 * Is this ours? Eight bytes decide it. A disk with anything else on it is
 * left alone: reading it as text would put a stranger's bytes on the screen
 * and call them the last thing you wrote.
 */
        LEA     x9, st_sector
        LEA     x10, s_magic
        mov     w11, #0
1:      cmp     w11, #8
        b.hs    2f
        ldrb    w12, [x9, w11, uxtw]
        ldrb    w13, [x10, w11, uxtw]
        cmp     w12, w13
        b.ne    9f
        add     w11, w11, #1
        b       1b
2:      ldr     w19, [x9, #8]
        cbz     w19, 9f
        cmp     w19, #TEXT_MAX
        b.hi    9f

        add     w20, w19, #(SECTOR - 1)
        lsr     w20, w20, #9
        mov     w0, #TEXT_LBA
        mov     w1, w20
        LEA     x2, st_text
        bl      SYM(store_dev_read)
        cmn     w0, #1
        b.eq    9f

        LEA     x9, st_text             /* the editor takes a string */
        strb    wzr, [x9, w19, uxtw]
        LEA     x0, st_text
        bl      SYM(editor_insert_str)
        mov     w0, w19
        b       8f
9:      mov     w0, #-1
8:      ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

#ifdef SUE_DISK_TEST
/*
 * store_peek - out w0 = the first four bytes of sector zero, as they are.
 *
 * For deciding whether the disk the guest is talking to is the file the host
 * is looking at. If the host writes a mark into the file and the guest reads
 * it back, they are the same object and a disagreement afterwards is the
 * guest's; if the guest sees something else, the argument was never about the
 * driver.
 */
        .globl  SYM(store_peek)
SYM(store_peek):
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        mov     w0, #0
        mov     w1, #1
        LEA     x2, st_sector
        bl      SYM(store_dev_read)
        cmn     w0, #1
        b.eq    9f
        LEA     x9, st_sector
        ldrb    w0, [x9]
        ldrb    w10, [x9, #1]
        ldrb    w11, [x9, #2]
        ldrb    w12, [x9, #3]
        orr     w0, w0, w10, lsl #8
        orr     w0, w0, w11, lsl #16
        orr     w0, w0, w12, lsl #24
        b       8f
9:      mov     w0, #-1
8:      ldp     x29, x30, [sp], #32
        ret

/*
 * store_scribble - fill both buffers with a byte that is nobody's data.
 *
 * Only for the disk test, and only because a read that does not happen is
 * indistinguishable from one that does when the buffer already holds what the
 * read would have fetched. Scribbling first makes the next read answer for
 * itself.
 */
        .globl  SYM(store_scribble)
SYM(store_scribble):
        LEA     x9, st_sector
        mov     w10, #0
1:      cmp     w10, #SECTOR
        b.hs    2f
        mov     w11, #0xAA
        strb    w11, [x9, w10, uxtw]
        add     w10, w10, #1
        b       1b
2:      LEA     x9, st_text
        mov     w10, #0
3:      cmp     w10, #TEXT_MAX
        b.hs    4f
        mov     w11, #0xAA
        strb    w11, [x9, w10, uxtw]
        add     w10, w10, #1
        b       3b
4:      ret
#endif

/*
 * store_tick - called on the idle tick. Writes the document if it changed.
 *
 * Autosave rather than a key, because a key is a thing to forget and the
 * reason to have a disk at all is that closing the machine should not lose the
 * work. What is saved is whatever is on the screen, whenever it stops being
 * what was last saved.
 *
 * Two guards keep it from writing constantly. A checksum decides whether
 * anything actually changed - typing a character and deleting it is not a
 * change - and a delay after the last keystroke decides when: a disk write per
 * character would put a USB transfer between every letter and the next, which
 * is felt.
 */
        .globl  SYM(store_tick)
SYM(store_tick):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]

        bl      SYM(store_dev_ready)
        cbz     w0, 8f

        bl      st_sum
        mov     w19, w0
        LEA     x9, st_saved
        ldr     w10, [x9]
        cmp     w19, w10
        b.eq    8f                      /* what is on screen is what is on disk */

        bl      SYM(store_dev_now)
        mov     x20, x0
        LEA     x9, st_changed
        ldr     w11, [x9]
        cmp     w19, w11
        b.eq    1f
/*
 * It changed since the last look, so the clock starts again. Somebody in the
 * middle of a sentence is not somebody who has finished one.
 */
        str     w19, [x9]
        LEA     x9, st_when
        str     x20, [x9]
        b       8f
1:      LEA     x9, st_when
        ldr     x9, [x9]
        sub     x9, x20, x9
        cmp     x9, #1500               /* milliseconds of quiet */
        b.lo    8f

        bl      SYM(store_save)
        cmn     w0, #1
        b.eq    8f
        LEA     x9, st_saved
        str     w19, [x9]
8:      ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * st_sum - a number that changes when the text does.
 *
 * Not a hash anybody should rely on for anything else: it is compared only
 * against itself, to answer "is this the same text as last time". The length
 * is folded in so that two documents differing only in trailing spaces are
 * still two documents.
 */
st_sum:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        bl      SYM(editor_length)
        mov     w19, w0
        cmp     w19, #TEXT_MAX
        b.ls    1f
        mov     w19, #TEXT_MAX
1:      mov     w0, #0
        mov     w1, w19
        LEA     x2, st_text
        mov     w3, #TEXT_MAX
        bl      SYM(editor_range_text)
        mov     w1, w0                  /* how much actually came back */
        mov     w2, #0x811C             /* a plain FNV, walked byte-wise */
        movk    w2, #0x9DC5, lsl #16
        mov     w9, #0
2:      cmp     w9, w1
        b.hs    3f
        LEA     x10, st_text
        ldrb    w11, [x10, w9, uxtw]
        eor     w2, w2, w11
        mov     w12, #0x0193
        movk    w12, #0x0100, lsl #16
        mul     w2, w2, w12
        add     w9, w9, #1
        b       2b
3:      eor     w0, w2, w1              /* and the length, so it counts too */
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

st_zero:
        add     x2, x0, x1
1:      cmp     x0, x2
        b.hs    2f
        strb    wzr, [x0]
        add     x0, x0, #1
        b       1b
2:      ret

        RODATA
/*
 * Eight bytes that say this disk is a document and which version of one. The
 * digit is there so that a later format can refuse an earlier one rather than
 * misread it - which is the whole reason to have a magic at all.
 */
s_magic:  .ascii "SUEDISK1"

        BSS
        .p2align 3
st_sector: .space SECTOR
st_text:   .space (TEXT_MAX + 8)
        .p2align 3
st_when:   .space 8                     /* when it last changed */
st_saved:  .space 4                     /* what is on the disk */
st_changed: .space 4                    /* and what it was a tick ago */
