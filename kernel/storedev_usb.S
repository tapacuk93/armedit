#include "asm.inc"
/*
 * storedev_usb.S - the document's backing store when this is the whole machine.
 *
 * store.S holds the document logic - the header, the magic, the autosave
 * delay - and nothing about where the bytes go. This is where they go when
 * sue is what booted: the USB disk, addressed as sectors, which is all a
 * disk is once there is no filesystem in the way.
 *
 * The point of the split is not tidiness. The app and the boot have to hold
 * the same document, in the same format, with the same rules about when it is
 * written - and the only honest way to get that is for both to run the same
 * code and differ only in the last three calls.
 */

#define SECTOR          512

        CODE
        .p2align 2

/*
 * store_dev_ready - out w0 = 1 if there is somewhere to put a document.
 *
 * A disk, and one with the sector size the format assumes. A 4096-byte disk is
 * not refused because it would be hard - it is refused because writing 512
 * bytes to it would silently mean something else.
 */
        .globl  SYM(store_dev_ready)
SYM(store_dev_ready):
        LEA     x9, SYM(usbmsc_slot)
        ldr     w9, [x9]
        cbz     w9, 9f
        LEA     x9, SYM(usbmsc_bsize)
        ldr     w9, [x9]
        cmp     w9, #SECTOR
        b.ne    9f
        mov     w0, #1
        ret
9:      mov     w0, #0
        ret

/* store_dev_read - w0 = sector, w1 = how many, x2 = where. out w0 = 0 or -1. */
        .globl  SYM(store_dev_read)
SYM(store_dev_read):
        b       SYM(usbmsc_read)

/* store_dev_write - the same, the other way. */
        .globl  SYM(store_dev_write)
SYM(store_dev_write):
        b       SYM(usbmsc_write)

/*
 * store_dev_now - out x0 = milliseconds, counting from anything.
 *
 * The autosave delay needs a clock and there is no clock both builds share:
 * this one has the machine's timer, the hosted one has the OS. Only the
 * difference between two readings is ever used, so where zero is does not
 * matter - only that it does not go backwards.
 */
        .globl  SYM(store_dev_now)
SYM(store_dev_now):
        b       platform_ticks
