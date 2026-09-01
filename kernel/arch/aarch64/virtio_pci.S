#include "asm.inc"
/*
 * virtio_pci.S - the same devices, reached the other way.
 *
 * This kernel already speaks virtio over the memory-mapped transport, which is
 * what QEMU's virt machine offers. macOS's Virtualization framework offers the
 * same devices over PCI instead, so a machine that has no PL011 and no
 * framebuffer also has no way to say anything until this exists. A console
 * there is the first thing that makes the port debuggable, and everything
 * after it is ordinary work.
 *
 * <h2>Where the registers are</h2>
 *
 * Not at a fixed offset. A modern virtio device describes itself through
 * vendor-specific PCI capabilities, each saying "this structure is in BAR n at
 * offset o": the common configuration, the notification area, the interrupt
 * status, and the device-specific part. So finding the registers is a walk
 * through a linked list in config space, and the answer differs per device and
 * per machine. That indirection is the price of not having a fixed transport
 * window, and it is why this file is longer than the MMIO one.
 *
 * <h2>Sixty-four bit fields, written in halves</h2>
 *
 * The queue addresses are 64-bit and the specification permits writing them as
 * two 32-bit accesses. That is what happens here, not for convenience: with
 * the MMU off every access is Device memory, where the CPU will not split an
 * unaligned 64-bit store for us, and a structure that begins at a four-byte
 * boundary puts those fields four bytes out. Two aligned halves always work;
 * one 64-bit store works only if the device happened to be placed favourably.
 *
 * <h2>What is left out</h2>
 *
 * No interrupts - the queue is polled, exactly as the MMIO drivers here poll.
 * No indirect descriptors, no event index, no MSI-X. This exists to carry
 * characters out of a machine that cannot otherwise speak, and every feature
 * not needed for that is a feature that could be wrong without being noticed.
 */

/* Vendor-specific capability, and the structures it points at. */
#define CAP_VENDOR      0x09
#define CFG_COMMON      1
#define CFG_NOTIFY      2
#define CFG_ISR         3
#define CFG_DEVICE      4

#define CAP_CFG_TYPE    3               /* offsets within the capability */
#define CAP_BAR         4
#define CAP_OFFSET      8
#define CAP_LENGTH      12
#define CAP_NOTIFY_MULT 16

/* virtio_pci_common_cfg */
#define COMMON_DFSELECT 0x00
#define COMMON_DF       0x04
#define COMMON_GFSELECT 0x08
#define COMMON_GF       0x0C
#define COMMON_NUMQ     0x12
#define COMMON_STATUS   0x14
#define COMMON_QSELECT  0x16
#define COMMON_QSIZE    0x18
#define COMMON_QENABLE  0x1C
#define COMMON_QNOTIFY  0x1E
#define COMMON_QDESC    0x20
#define COMMON_QDRIVER  0x28
#define COMMON_QDEVICE  0x30

#define ST_ACK          1
#define ST_DRIVER       2
#define ST_DRIVER_OK    4
#define ST_FEATURES_OK  8

#define VIRTIO_VENDOR   0x1AF4

        CODE
        .p2align 2

/*
 * vpci_open - w0 = a modern virtio device id, out w0 = 0 if it is ready.
 *
 * Finds the device, switches its memory space on, locates the two structures
 * that matter, and takes it through the specified handshake as far as
 * FEATURES_OK. Queues are set up afterwards, by the caller that knows how many
 * it wants.
 */
        .globl  SYM(vpci_open)
SYM(vpci_open):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        str     x23, [sp, #48]
        mov     w19, w0

        movz    w0, #VIRTIO_VENDOR
        mov     w1, w19
        bl      SYM(pci_find)
        cbz     x0, .Lvo_fail
        mov     x20, x0

        /*
         * Give it addresses if it has none, and switch it on either way.
         * pci_assign enables at the end of its own work; a device that was
         * already assigned needs only the second half.
         */
        mov     x0, x20
        mov     w1, #0
        bl      SYM(pci_bar)
        cbnz    x0, 1f
        mov     x0, x20
        bl      SYM(pci_assign)
        b       2f
1:      mov     x0, x20
        bl      SYM(pci_enable)
2:

        /* The common configuration: status, features, queue selection. */
        mov     x0, x20
        mov     w1, #CFG_COMMON
        bl      vpci_structure
        cbz     x0, .Lvo_fail
        LEA     x9, vpci_common
        str     x0, [x9]

        /* And the notification area, which is how a queue is kicked. */
        mov     x0, x20
        mov     w1, #CFG_NOTIFY
        bl      vpci_structure
        cbz     x0, .Lvo_fail
        LEA     x9, vpci_notify
        str     x0, [x9]

        /*
         * The handshake. Status is written in steps and read back, because
         * a device that refuses the feature set clears FEATURES_OK rather than
         * failing a write - so the only way to learn it said no is to ask.
         */
        LEA     x9, vpci_common
        ldr     x21, [x9]

/*
 * Reset, and then wait for it.
 *
 * The specification says a driver that writes zero to the status register must
 * wait for a read to return zero before touching the device again, and this
 * did not - it wrote zero and then immediately wrote ACKNOWLEDGE. On QEMU that
 * is invisible. Under the Virtualization framework the reset was still in
 * progress, the acknowledgement went into it, and the register read back as
 * zero: a device that appeared not to accept writes at all, on a machine whose
 * only console was the device.
 */
        strb    wzr, [x21, #COMMON_STATUS]
        mov     w22, #0
1:      ldrb    w9, [x21, #COMMON_STATUS]
        cbz     w9, 2f
        add     w22, w22, #1
        mov     w23, #0x8000
        movk    w23, #0x0001, lsl #16   /* a bounded wait, not a promise */
        cmp     w22, w23
        b.lo    1b
        b       .Lvo_fail
2:
        mov     w9, #ST_ACK
        strb    w9, [x21, #COMMON_STATUS]
        mov     w9, #(ST_ACK | ST_DRIVER)
        strb    w9, [x21, #COMMON_STATUS]

        /*
         * VIRTIO_F_VERSION_1, and nothing else.
         *
         * Bit 32, which is why the feature registers are selected in halves.
         * It is not optional: a modern device that is not offered it stays in
         * legacy mode, which is a different queue layout and a driver this is
         * not. That exact mistake cost a day on the MMIO side - the handshake
         * appeared to succeed and the ring never filled.
         */
        mov     w9, #0
        str     w9, [x21, #COMMON_GFSELECT]
        str     wzr, [x21, #COMMON_GF]          /* nothing from the low half */
        mov     w9, #1
        str     w9, [x21, #COMMON_GFSELECT]
        mov     w9, #1                          /* bit 32 is bit 0 up here */
        str     w9, [x21, #COMMON_GF]

        mov     w9, #(ST_ACK | ST_DRIVER | ST_FEATURES_OK)
        strb    w9, [x21, #COMMON_STATUS]
        ldrb    w9, [x21, #COMMON_STATUS]
        tst     w9, #ST_FEATURES_OK
        b.eq    .Lvo_fail                       /* it declined */

        mov     w0, #0
        b       .Lvo_out
.Lvo_fail:
        mov     w0, #-1
.Lvo_out:
        ldr     x23, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * vpci_structure - x0 = config space, w1 = which cfg_type.
 *   out x0 = where that structure lives, or 0.
 *
 * The capability says which BAR and what offset within it. Both are needed:
 * two structures often share a BAR, and the offset is the only thing that
 * tells them apart.
 */
        .globl  SYM(vpci_structure)
SYM(vpci_structure):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        str     x23, [sp, #48]
        mov     x19, x0
        mov     w20, w1
        mov     w21, #0                 /* how many capabilities we have tried */
        mov     x22, #0                 /* the walk cursor, as an offset */

        ldr     w9, [x19, #0x34]        /* capability pointer */
        and     w22, w9, #0xFC

1:      cbz     w22, .Lvs_none
        cmp     w21, #48                /* the same bound pci_cap uses */
        b.hs    .Lvs_none
        add     w21, w21, #1

        add     x23, x19, w22, uxtw
        ldr     w9, [x23]
        and     w10, w9, #0xFF
        cmp     w10, #CAP_VENDOR
        b.ne    2f

        ldrb    w10, [x23, #CAP_CFG_TYPE]
        cmp     w10, w20
        b.ne    2f

        /* This is the one. Which BAR, and where in it. */
        ldrb    w10, [x23, #CAP_BAR]
        mov     x0, x19
        mov     w1, w10
        bl      SYM(pci_bar)
        cbz     x0, .Lvs_none
        ldr     w9, [x23, #CAP_OFFSET]
        add     x0, x0, w9, uxtw

        /* The notification area also carries how far apart its queues are. */
        cmp     w20, #CFG_NOTIFY
        b.ne    .Lvs_out
        ldr     w9, [x23, #CAP_NOTIFY_MULT]
        LEA     x10, vpci_notify_mult
        str     w9, [x10]
        b       .Lvs_out

2:      ldr     w9, [x23]
        lsr     w9, w9, #8
        and     w22, w9, #0xFC
        b       1b

.Lvs_none:
        mov     x0, #0
.Lvs_out:
        ldr     x23, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * vpci_queue - w0 = which queue, x1 = descriptors, x2 = available, x3 = used,
 *              w4 = how many entries those rings hold.
 *   out w0 = the queue's size, or -1.
 *
 * The rings are the caller's memory. With the MMU off a virtual address is a
 * physical one, so what the device is told is what the caller allocated -
 * which will stop being true the day this kernel turns the MMU on, and is the
 * one assumption here worth remembering.
 */
        .globl  SYM(vpci_queue)
SYM(vpci_queue):
        LEA     x9, vpci_common
        ldr     x9, [x9]
        cbz     x9, 9f

        strh    w0, [x9, #COMMON_QSELECT]
        ldrh    w10, [x9, #COMMON_QSIZE]
        cbz     w10, 9f                 /* a queue the device does not have */

/*
 * Shrink the queue to the rings we actually allocated.
 *
 * The device proposes a size - sixty-four, a hundred and twenty-eight - and a
 * driver may write a smaller one. Not doing so is not a performance question:
 * the index is masked with the queue size, so a device that thinks the ring
 * holds sixty-four entries will read and write past the end of eight, into
 * whatever is next in .bss. It looked exactly like a device that ignored
 * everything, because the entries it read were never the ones we wrote.
 */
        cmp     w10, w4
        b.ls    1f
        strh    w4, [x9, #COMMON_QSIZE]
        ldrh    w10, [x9, #COMMON_QSIZE]        /* read back: a device may
                                                   decline to shrink, and
                                                   assuming it agreed is how
                                                   the mask ends up disagreeing
                                                   with the device's */
        cmp     w10, w4
        b.hi    9f                              /* it kept a size we cannot serve */
1:

        /* Sixty-four bit fields, two aligned halves each. See the header. */
        str     w1, [x9, #COMMON_QDESC]
        lsr     x11, x1, #32
        str     w11, [x9, #(COMMON_QDESC + 4)]
        str     w2, [x9, #COMMON_QDRIVER]
        lsr     x11, x2, #32
        str     w11, [x9, #(COMMON_QDRIVER + 4)]
        str     w3, [x9, #COMMON_QDEVICE]
        lsr     x11, x3, #32
        str     w11, [x9, #(COMMON_QDEVICE + 4)]

        /* Where a kick for this queue goes, worked out once and kept. */
        ldrh    w11, [x9, #COMMON_QNOTIFY]
        LEA     x12, vpci_notify_mult
        ldr     w12, [x12]
        mul     w11, w11, w12
        LEA     x12, vpci_notify
        ldr     x12, [x12]
        add     x12, x12, w11, uxtw
        LEA     x13, vpci_kick
        str     x12, [x13]

        mov     w11, #1
        strh    w11, [x9, #COMMON_QENABLE]
        mov     w0, w10
        ret
9:      mov     w0, #-1
        ret

/* vpci_ready - the device may start. Called once every queue is enabled. */
        .globl  SYM(vpci_ready)
SYM(vpci_ready):
        LEA     x9, vpci_common
        ldr     x9, [x9]
        cbz     x9, 9f
        mov     w10, #(ST_ACK | ST_DRIVER | ST_FEATURES_OK | ST_DRIVER_OK)
        strb    w10, [x9, #COMMON_STATUS]
9:      ret

/* vpci_status - out w0 = the device's status byte, for asking what it thinks. */
        .globl  SYM(vpci_status)
SYM(vpci_status):
        LEA     x9, vpci_common
        ldr     x9, [x9]
        cbz     x9, 9f
        ldrb    w0, [x9, #COMMON_STATUS]
        ret
9:      mov     w0, #0
        ret

/* vpci_kick_queue - w0 = which queue. Tells the device to look. */
        .globl  SYM(vpci_kick_queue)
SYM(vpci_kick_queue):
        LEA     x9, vpci_kick
        ldr     x9, [x9]
        cbz     x9, 9f
        dsb     sy                      /* the ring must be visible first */
        strh    w0, [x9]
9:      ret

        .section .bss
        .p2align 3
vpci_common:      .space 8
vpci_notify:      .space 8
vpci_kick:        .space 8
vpci_notify_mult: .space 4
