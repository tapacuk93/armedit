#include "asm.inc"
/*
 * storedev_file.S - the document's backing store when there is an OS underneath.
 *
 * The same three calls kernel/storedev_usb.S provides, over a file instead of
 * a disk. store.S does not know the difference and must not: the app and the
 * boot are supposed to hold the same document, and the way to be sure of that
 * is for the header, the magic, the checksum and the autosave delay to be one
 * piece of code with two backings rather than two implementations that agree
 * for now.
 *
 * Sectors are kept as the unit even though a file has no sectors. That is what
 * makes the formats identical: a document written by the app is byte for byte
 * a document the booted machine will load off a disk, and an image of one can
 * be dd'd onto the other.
 *
 * <h2>Where the file goes</h2>
 *
 * $HOME/.sue-document. On macOS that is the home directory; on iOS it is the
 * app's container, which is the same thing from inside the sandbox. No
 * directory is made, because a path with no directory in it cannot fail to
 * have one.
 */

#define SECTOR          512

#define SYS_READ        3
#define SYS_WRITE       4
#define SYS_OPEN        5
#define SYS_CLOSE       6
#define SYS_FSYNC       95
#define SYS_PREAD       153
#define SYS_PWRITE      154

#define O_RDWR          0x0002
#define O_CREAT         0x0200

        CODE
        .p2align 2

/*
 * store_dev_ready - out w0 = 1 if the document file can be opened.
 *
 * Opening is the test. A path that exists, a path that can be created and a
 * path on a full or read-only volume are told apart by trying, and nothing
 * short of trying tells them apart.
 */
        .globl  SYM(store_dev_ready)
SYM(store_dev_ready):
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        bl      sd_open
        cmp     w0, #0
        b.lt    9f
        bl      sd_close
        mov     w0, #1
        b       8f
9:      mov     w0, #0
8:      ldp     x29, x30, [sp], #32
        ret

/*
 * store_dev_read - w0 = sector, w1 = how many, x2 = where. out w0 = 0 or -1.
 *
 * A short read is not an error here: a document file that is smaller than the
 * sectors asked for is the ordinary state of a file that has just been made,
 * and store.S has already decided from the header how much of it means
 * anything. What it must not do is leave the buffer holding whatever was there
 * before, so the tail is zeroed.
 */
        .globl  SYM(store_dev_read)
SYM(store_dev_read):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     w19, w0
        mov     w20, w1
        mov     x21, x2

        bl      sd_open
        cmp     w0, #0
        b.lt    9f
        mov     w22, w0

        lsl     w9, w20, #9             /* how many bytes were asked for */
        mov     w10, #0
1:      cmp     w10, w9                 /* clear it first, then read over it */
        b.hs    2f
        strb    wzr, [x21, w10, uxtw]
        add     w10, w10, #1
        b       1b
2:
        mov     x0, x22
        mov     x1, x21
        mov     w2, w9
        lsl     x3, x19, #9             /* the sector, as an offset */
        mov     x16, #SYS_PREAD
        svc     #0x80
        b.cs    8f                      /* a failed read leaves it zeroed */
8:      mov     x0, x22
        bl      sd_close
        mov     w0, #0
        b       7f
9:      mov     w0, #-1
7:      ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * store_dev_write - the same, the other way.
 *
 * A short write is an error, unlike a short read. store.S writes the header
 * last precisely so that a half-finished save leaves the previous document
 * intact, and that only holds if a write that did not finish says so.
 */
        .globl  SYM(store_dev_write)
SYM(store_dev_write):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     w19, w0
        mov     w20, w1
        mov     x21, x2

        bl      sd_open
        cmp     w0, #0
        b.lt    9f
        mov     w22, w0

        lsl     w9, w20, #9
        mov     x0, x22
        mov     x1, x21
        mov     w2, w9
        lsl     x3, x19, #9
        mov     x16, #SYS_PWRITE
        svc     #0x80
        b.cs    1f
        lsl     w9, w20, #9
        cmp     w0, w9
        b.ne    1f
/*
 * And ask for it to be on the disk rather than merely accepted. The booted
 * machine loses power without warning and this one gets force-quit, which is
 * near enough the same event to deserve the same answer.
 */
        mov     x0, x22
        mov     x16, #SYS_FSYNC
        svc     #0x80
        mov     x0, x22
        bl      sd_close
        mov     w0, #0
        b       8f
1:      mov     x0, x22
        bl      sd_close
9:      mov     w0, #-1
8:      ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * sd_open - out w0 = a file descriptor, or negative.
 *
 * Opened and closed around every access rather than held. A document is
 * written once every second and a half at the very most, so the cost is
 * nothing, and a descriptor that is not held is a descriptor that cannot be
 * left open across a fork, a suspend, or a crash.
 */
sd_open:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        str     x19, [sp, #16]
        bl      sd_path
        mov     x19, x0
        cbz     x19, 9f
        mov     x0, x19
        mov     x1, #(O_RDWR | O_CREAT)
        mov     x2, #0x1A0      /* rw for its owner and nobody else */
        mov     x16, #SYS_OPEN
        svc     #0x80
        b.cs    9f
        b       8f
9:      mov     w0, #-1
8:      ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

sd_close:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        mov     x16, #SYS_CLOSE
        svc     #0x80
        ldp     x29, x30, [sp], #16
        ret

/*
 * sd_path - out x0 = "$HOME/.sue-document", or 0 if there is no home.
 *
 * Built once and kept. No home directory means no document, rather than a file
 * called ".sue-document" in whatever directory the process happens to be
 * standing in - which would be a different document every time it was started
 * from somewhere else.
 */
sd_path:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        LEA     x9, sd_built
        ldr     w9, [x9]
        cbz     w9, 1f
        LEA     x0, sd_buf
        b       8f
1:      LEA     x0, s_home
        bl      SYM(env_get)
        cbz     x0, 9f
        mov     x19, x0
        LEA     x20, sd_buf
        mov     w9, #0
2:      ldrb    w10, [x19, w9, uxtw]
        cbz     w10, 3f
        cmp     w9, #200
        b.hs    3f
        strb    w10, [x20, w9, uxtw]
        add     w9, w9, #1
        b       2b
3:      LEA     x11, s_leaf
        mov     w12, #0
4:      ldrb    w10, [x11, w12, uxtw]
        strb    w10, [x20, w9, uxtw]
        cbz     w10, 5f
        add     w9, w9, #1
        add     w12, w12, #1
        b       4b
5:      LEA     x9, sd_built
        mov     w10, #1
        str     w10, [x9]
        LEA     x0, sd_buf
        b       8f
9:      mov     x0, #0
8:      ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* store_dev_now - out x0 = milliseconds; see the note in storedev_usb.S. */
        .globl  SYM(store_dev_now)
SYM(store_dev_now):
        b       SYM(now_millis)

        RODATA
s_home: .asciz "HOME"
s_leaf: .asciz "/.sue-document"

        BSS
        .p2align 3
sd_built: .space 4
sd_buf:   .space 256
