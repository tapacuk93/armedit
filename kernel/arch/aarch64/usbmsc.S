#include "asm.inc"
/*
 * usbmsc.S - somewhere to keep what you write.
 *
 * The machine can be typed at and can reach a network, and everything typed
 * into it disappears when it restarts. That is the difference between a
 * demonstration and something a person can work on, and it is the last thing
 * missing before this editor can be used to change itself.
 *
 * On the target the disk is USB, like everything else: the same controller the
 * keyboard is on, the same bulk endpoints the network adapter uses, one more
 * driver on top. It is also what the machine already booted from - an EFI
 * volume is a disk somebody else read - so writing to it closes the loop.
 *
 * <h2>Bulk-only transport, which is three transfers and a convention</h2>
 *
 * There is no protocol here in the sense the network has one. A command is
 * thirty-one bytes on the out endpoint saying what SCSI command follows and
 * how many bytes will move; then the bytes move, in whichever direction the
 * command said; then thirteen bytes come back on the in endpoint saying
 * whether it worked. Three transfers, always in that order, and the tag ties
 * the answer to the question.
 *
 * The commands themselves are SCSI, which is a much older thing than USB and
 * arrived here by being wrapped rather than replaced. Four of them are enough
 * to use a disk: ask whether it is ready, ask how big it is, read, write.
 */

#define CBW_LEN         31
#define CSW_LEN         13
#define CBW_SIG         0x43425355      /* "USBC", as it goes on the wire */
#define CSW_SIG         0x53425355      /* "USBS" */
#define DIR_IN          0x80

#define SCSI_TEST_READY 0x00
#define SCSI_READ_CAP   0x25
#define SCSI_READ10     0x28
#define SCSI_WRITE10    0x2A

#define SECTOR_MAX      4096

        CODE
        .p2align 2

/*
 * usbmsc_start - w0 = the slot, x1 = its configuration, w2 = how many bytes.
 *   out w0 = 0 if there is a disk to talk to, -1 if there is not.
 */
        .globl  SYM(usbmsc_start)
SYM(usbmsc_start):
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        str     x27, [sp, #80]
        mov     w19, w0
        mov     x20, x1
        mov     w21, w2

/*
 * The interface has to be all three things. Class eight is mass storage,
 * subclass six says the commands inside are SCSI, and protocol eighty says
 * they travel this way rather than one of the two older ways nobody should
 * write again. A device that is only the first of those speaks something else.
 */
        mov     w0, #1                  /* looking for the interface */
        bl      ms_step
        mov     w22, #0                 /* bulk in */
        mov     w23, #0                 /* bulk out */
        mov     w24, #0                 /* how big its packets are */
        mov     w25, #0                 /* inside the right interface? */
        ldrb    w26, [x20, #5]          /* which configuration this is */
        mov     w27, #9
1:      cmp     w27, w21
        b.hs    5f
        add     x9, x20, w27, uxtw
        ldrb    w10, [x9]
        cbz     w10, 5f
        ldrb    w11, [x9, #1]

        cmp     w11, #4
        b.ne    2f
        mov     w25, #0
        ldrb    w12, [x9, #5]
        cmp     w12, #8
        b.ne    4f
        ldrb    w12, [x9, #6]
        cmp     w12, #6
        b.ne    4f
        ldrb    w12, [x9, #7]
        cmp     w12, #0x50
        b.ne    4f
        mov     w25, #1
        b       4f

2:      cmp     w11, #5
        b.ne    4f
        cbz     w25, 4f
        ldrb    w12, [x9, #3]
        and     w12, w12, #3
        cmp     w12, #2                 /* bulk, and nothing else */
        b.ne    4f
        ldrb    w12, [x9, #2]
        ldrb    w13, [x9, #4]
        ldrb    w14, [x9, #5]
        orr     w24, w13, w14, lsl #8
        tbz     w12, #7, 3f
        mov     w22, w12
        b       4f
3:      mov     w23, w12
4:      add     w27, w27, w10
        b       1b
5:      cbz     w22, .Lms_fail
        cbz     w23, .Lms_fail
        mov     w0, #2                  /* choosing the configuration */
        bl      ms_step

        LEA     x9, SYM(xhci_req)
        strb    wzr, [x9]
        mov     w10, #9                 /* SET_CONFIGURATION */
        strb    w10, [x9, #1]
        strb    w26, [x9, #2]
        strb    wzr, [x9, #3]
        strb    wzr, [x9, #4]
        strb    wzr, [x9, #5]
        strb    wzr, [x9, #6]
        strb    wzr, [x9, #7]
        mov     w0, w19
        mov     x1, #0
        mov     w2, #0
        bl      SYM(xhci_control)
        cmn     w0, #1
        b.eq    .Lms_fail

        mov     w0, #3                  /* describing the endpoints */
        bl      ms_step
        bl      SYM(xhci_beginctx)
        mov     w0, w19
        mov     w1, w22
        mov     w2, #6                  /* bulk in */
        mov     w3, w24
        LEA     x4, ms_inring
        bl      SYM(xhci_addep)
        LEA     x9, ms_indci
        str     w0, [x9]
        mov     w20, w0

        mov     w0, w19
        mov     w1, w23
        mov     w2, #2                  /* bulk out */
        mov     w3, w24
        LEA     x4, ms_outring
        bl      SYM(xhci_addep)
        LEA     x9, ms_outdci
        str     w0, [x9]

        cmp     w0, w20
        csel    w1, w0, w20, hi
        mov     w0, w19
        bl      SYM(xhci_slotctx)
        mov     w0, w19
        bl      SYM(xhci_applyctx)
        cmn     w0, #1
        b.eq    .Lms_fail

        LEA     x9, SYM(usbmsc_slot)
        str     w19, [x9]

/*
 * Ask whether it is ready before asking anything else. A disk that has just
 * been plugged in answers the first command with "not ready" and the second
 * normally, which is not a fault but is indistinguishable from one if the
 * first command asked something that mattered.
 */
        mov     w0, #4                  /* waiting for it to be ready */
        bl      ms_step
        mov     w9, #0
6:      cmp     w9, #8
        b.hs    .Lms_fail
        stp     x9, x10, [sp, #-16]!
        bl      ms_ready
        ldp     x9, x10, [sp], #16
        cbz     w0, 7f
        add     w9, w9, #1
        b       6b
7:      mov     w0, #5                  /* asking how big it is */
        bl      ms_step
        bl      SYM(usbmsc_capacity)
        cmn     w0, #1
        b.eq    .Lms_fail
        mov     w0, #0
        bl      ms_step
        mov     w0, #0
        b       .Lms_out
.Lms_fail:
        LEA     x9, SYM(usbmsc_slot)
        str     wzr, [x9]
        mov     w0, #-1
.Lms_out:
        ldr     x27, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

/*
 * ms_command - x0 = the command bytes, w1 = how many, x2 = a data buffer,
 *   w3 = how many bytes of data, w4 = non-zero if the data comes to us.
 *   out w0 = 0 if the disk said it worked, -1 otherwise.
 *
 * The whole transport in one place, because it is always the same three
 * transfers and the only thing that varies is what is in the middle. Splitting
 * it per command would mean writing the wrapper four times and getting the tag
 * wrong in one of them.
 */
ms_command:
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        mov     x19, x0
        mov     w20, w1
        mov     x21, x2
        mov     w22, w3
        mov     w23, w4

        LEA     x9, SYM(usbmsc_slot)
        ldr     w24, [x9]
        cbz     w24, 9f

/* A tag that changes every time, so an answer cannot be last time's. */
        LEA     x9, ms_tag
        ldr     w25, [x9]
        add     w25, w25, #1
        str     w25, [x9]

        LEA     x26, ms_cbw
        mov     x0, x26
        mov     x1, #CBW_LEN
        bl      ms_zero
        movz    w9, #0x5355
        movk    w9, #0x4342, lsl #16    /* "USBC" as a little-endian word */
        str     w9, [x26]
        str     w25, [x26, #4]
        str     w22, [x26, #8]
        mov     w9, #0
        cbz     w23, 1f
        mov     w9, #DIR_IN
1:      strb    w9, [x26, #12]
        strb    wzr, [x26, #13]         /* the first unit, and the only one */
        strb    w20, [x26, #14]
        mov     w9, #0
2:      cmp     w9, w20
        b.hs    3f
        ldrb    w10, [x19, w9, uxtw]
        add     x11, x26, #15
        strb    w10, [x11, w9, uxtw]
        add     w9, w9, #1
        b       2b
3:
        mov     w0, w24
        LEA     x9, ms_outdci
        ldr     w1, [x9]
        mov     x2, x26
        mov     w3, #CBW_LEN
        LEA     x4, ms_outring
        LEA     x5, ms_outpos
        bl      SYM(xhci_bulk)
        cmn     w0, #1
        b.eq    9f

        cbz     w22, 4f
        mov     w0, w24
        LEA     x9, ms_indci
        ldr     w1, [x9]
        cbnz    w23, 5f
        LEA     x9, ms_outdci
        ldr     w1, [x9]
5:      mov     x2, x21
        mov     w3, w22
        cbnz    w23, 6f
        LEA     x4, ms_outring
        LEA     x5, ms_outpos
        b       7f
6:      LEA     x4, ms_inring
        LEA     x5, ms_inpos
7:      bl      SYM(xhci_bulk)
        cmn     w0, #1
        b.eq    9f
4:
        LEA     x0, ms_csw
        mov     x1, #CSW_LEN
        bl      ms_zero
        mov     w0, w24
        LEA     x9, ms_indci
        ldr     w1, [x9]
        LEA     x2, ms_csw
        mov     w3, #CSW_LEN
        LEA     x4, ms_inring
        LEA     x5, ms_inpos
        bl      SYM(xhci_bulk)
        cmn     w0, #1
        b.eq    9f

/*
 * The answer has to be about this question. A signature that is not "USBS" is
 * a device out of step with us, and a tag that is not the one just sent is an
 * answer to something earlier - either way what came back in the data is not
 * what was asked for, and reporting success would hand the caller somebody
 * else's sector.
 */
        LEA     x9, ms_csw
        ldr     w10, [x9]
        movz    w11, #0x5355
        movk    w11, #0x5342, lsl #16
        cmp     w10, w11
        b.ne    9f
        ldr     w10, [x9, #4]
        cmp     w10, w25
        b.ne    9f
        ldrb    w10, [x9, #12]
        cbnz    w10, 9f
        mov     w0, #0
        b       10f
9:      mov     w0, #-1
10:     ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

/* ms_ready - out w0 = 0 when the disk says it is. */
ms_ready:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LEA     x0, ms_cdb
        mov     x1, #16
        bl      ms_zero
        LEA     x0, ms_cdb
        mov     w1, #6
        mov     x2, #0
        mov     w3, #0
        mov     w4, #0
        bl      ms_command
        ldp     x29, x30, [sp], #16
        ret

/*
 * usbmsc_capacity - out w0 = 0, and usbmsc_blocks and usbmsc_bsize say how
 *   much there is. -1 if it would not say.
 *
 * The disk reports the last block's number rather than how many there are, so
 * the count is one more than it said. That is the sort of thing that costs
 * exactly one sector at the end and is invisible until the day it matters.
 */
        .globl  SYM(usbmsc_capacity)
SYM(usbmsc_capacity):
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LEA     x0, ms_cdb
        mov     x1, #16
        bl      ms_zero
        LEA     x9, ms_cdb
        mov     w10, #SCSI_READ_CAP
        strb    w10, [x9]
        LEA     x0, ms_cdb
        mov     w1, #10
        LEA     x2, ms_data
        mov     w3, #8
        mov     w4, #1
        bl      ms_command
        cmn     w0, #1
        b.eq    9f
        LEA     x9, ms_data
        mov     x0, x9
        bl      ms_be32
        add     w0, w0, #1
        LEA     x9, SYM(usbmsc_blocks)
        str     w0, [x9]
        LEA     x9, ms_data
        add     x0, x9, #4
        bl      ms_be32
        LEA     x9, SYM(usbmsc_bsize)
        str     w0, [x9]
        mov     w0, #0
        b       8f
9:      mov     w0, #-1
8:      ldp     x29, x30, [sp], #16
        ret

/*
 * usbmsc_read - w0 = which block, w1 = how many, x2 = where to put them.
 * usbmsc_write - the same, the other way.
 *   out w0 = 0, or -1.
 */
        .globl  SYM(usbmsc_read)
SYM(usbmsc_read):
        mov     w3, #SCSI_READ10
        mov     w4, #1
        b       ms_transfer

        .globl  SYM(usbmsc_write)
SYM(usbmsc_write):
        mov     w3, #SCSI_WRITE10
        mov     w4, #0
        b       ms_transfer

ms_transfer:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        str     x23, [sp, #48]
        mov     w19, w0
        mov     w20, w1
        mov     x21, x2
        mov     w22, w3
        mov     w23, w4

        LEA     x0, ms_cdb
        mov     x1, #16
        bl      ms_zero
        LEA     x9, ms_cdb
        strb    w22, [x9]
        add     x0, x9, #2              /* the block, most significant first */
        mov     w1, w19
        bl      ms_put32
        lsr     w10, w20, #8
        strb    w10, [x9, #7]           /* and how many, the same way */
        strb    w20, [x9, #8]

        LEA     x9, SYM(usbmsc_bsize)
        ldr     w9, [x9]
        mul     w9, w9, w20
        LEA     x0, ms_cdb
        mov     w1, #10
        mov     x2, x21
        mov     w3, w9
        mov     w4, w23
        bl      ms_command
        ldr     x23, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/* Bytes, most significant first, which is how SCSI writes a number. */
ms_be32:
        ldrb    w9, [x0]
        ldrb    w10, [x0, #1]
        ldrb    w11, [x0, #2]
        ldrb    w12, [x0, #3]
        lsl     w9, w9, #24
        orr     w9, w9, w10, lsl #16
        orr     w9, w9, w11, lsl #8
        orr     w0, w9, w12
        ret

ms_put32:
        lsr     w9, w1, #24
        strb    w9, [x0]
        lsr     w9, w1, #16
        strb    w9, [x0, #1]
        lsr     w9, w1, #8
        strb    w9, [x0, #2]
        strb    w1, [x0, #3]
        ret

ms_step:
        LEA     x9, SYM(usbmsc_stage)
        str     w0, [x9]
        ret

ms_zero:
        add     x2, x0, x1
1:      cmp     x0, x2
        b.hs    2f
        strb    wzr, [x0]
        add     x0, x0, #1
        b       1b
2:      ret

        BSS
        .p2align 3
        .globl  SYM(usbmsc_slot)
        .globl  SYM(usbmsc_blocks)
        .globl  SYM(usbmsc_bsize)
        .globl  SYM(usbmsc_stage)
SYM(usbmsc_slot):   .space 4
SYM(usbmsc_blocks): .space 4
SYM(usbmsc_bsize):  .space 4
SYM(usbmsc_stage):  .space 4
ms_indci:   .space 4
ms_outdci:  .space 4
ms_tag:     .space 4
        .p2align 3
ms_inpos:   .space 8
ms_outpos:  .space 8
        .p2align 6
ms_inring:  .space (16 * 16)
ms_outring: .space (16 * 16)
        .p2align 6
ms_cbw:     .space 32
ms_csw:     .space 16
ms_cdb:     .space 16
ms_data:    .space 64
