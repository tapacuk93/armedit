#include "asm.inc"
/*
 * virtio_net.S - Ethernet frames in and out, and nothing above that.
 *
 * The transport is the same virtio-mmio handshake the keyboard uses, so the
 * shape of this file will look familiar: find the device, negotiate, set up
 * two queues, then poll. What differs is that a network device has traffic in
 * both directions and buffers that must be posted before anything can arrive.
 *
 * Queue 0 is receive and queue 1 is transmit, which is fixed by the
 * specification rather than chosen here. Every receive buffer is posted at
 * startup and re-posted the moment its frame has been copied out; a frame that
 * arrives with nowhere to go is a frame the device drops, and the whole point
 * of a receive ring is to make that rare.
 *
 * Every buffer carries a twelve-byte virtio_net_hdr in front of the frame.
 * Under VIRTIO_F_VERSION_1 that size is fixed - the legacy transport used ten
 * unless a feature was negotiated, which is one more reason this driver only
 * speaks the modern one.
 *
 * What this deliberately does not do: interrupts, checksum offload, multiple
 * queues, or anything that would make it fast. A text editor asking a backend
 * a question every few seconds is not a workload; it is a conversation.
 */

/*
 * Where virtio lives when the machine does not say.
 *
 * QEMU's virt machine puts them here, and for years that was written down as a
 * constant because QEMU was the only machine this booted on. It is the
 * fallback now rather than the answer: dtb_or asks the device tree first, so
 * the same binary works on a machine that puts them somewhere else.
 */
#define VIRTIO_BASE     0x0A000000
#define VIRTIO_STRIDE   0x200
#define VIRTIO_SLOTS    32

#define VIRTIO_MAGIC    0x000
#define VIRTIO_VERSION  0x004
#define VIRTIO_DEVICE   0x008
#define VIRTIO_DEVFEAT  0x010
#define VIRTIO_DEVFSEL  0x014
#define VIRTIO_DRVFEAT  0x020
#define VIRTIO_DRVFSEL  0x024
#define VIRTIO_QSEL     0x030
#define VIRTIO_QNUMMAX  0x034
#define VIRTIO_QNUM     0x038
#define VIRTIO_QREADY   0x044
#define VIRTIO_QNOTIFY  0x050
#define VIRTIO_STATUS   0x070
#define VIRTIO_QDESC_LO 0x080
#define VIRTIO_QDESC_HI 0x084
#define VIRTIO_QAVAIL_LO 0x090
#define VIRTIO_QAVAIL_HI 0x094
#define VIRTIO_QUSED_LO 0x0A0
#define VIRTIO_QUSED_HI 0x0A4
#define VIRTIO_CONFIG   0x100

#define DEV_NET         1

#define ST_ACK          1
#define ST_DRIVER       2
#define ST_DRIVER_OK    4
#define ST_FEATURES_OK  8

#define VNET_F_MAC      5               /* the config space carries our MAC */

#define NQ              16              /* buffers per direction */
#define BUFSZ           2048            /* header, frame, and room to spare */
#define NET_HDR         12              /* virtio_net_hdr under VERSION_1 */
#define FRAME_MAX       (BUFSZ - NET_HDR)

        .section .text
        .p2align 2

/*
 * net_init - find a virtio network device and bring it up.
 *   out w0 = 0 if there is one, -1 otherwise.
 */
        .globl  net_init
net_init:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]

        LEA     x0, s_c_virtio_mmio
        mov     x1, #VIRTIO_BASE
        bl      SYM(dtb_or)
        mov     x19, x0
        mov     w20, #0
1:      cmp     w20, #VIRTIO_SLOTS
        b.hs    .Lni_none
        ldr     w9, [x19, #VIRTIO_MAGIC]
        movz    w10, #0x6976
        movk    w10, #0x7472, lsl #16
        cmp     w9, w10
        b.ne    2f
        ldr     w9, [x19, #VIRTIO_DEVICE]
        cmp     w9, #DEV_NET
        b.eq    3f
2:      add     x19, x19, #VIRTIO_STRIDE
        add     w20, w20, #1
        b       1b
3:      ldr     w9, [x19, #VIRTIO_VERSION]
        cmp     w9, #2
        b.ne    .Lni_none

        LEA     x9, vnet_dev
        str     x19, [x9]

        str     wzr, [x19, #VIRTIO_STATUS]
        mov     w9, #ST_ACK
        str     w9, [x19, #VIRTIO_STATUS]
        mov     w9, #(ST_ACK | ST_DRIVER)
        str     w9, [x19, #VIRTIO_STATUS]

/*
 * Of everything a network card offers we want one thing - to be told our own
 * MAC address - and VIRTIO_F_VERSION_1, which is not a feature so much as a
 * declaration of which rulebook we are using.
 */
        str     wzr, [x19, #VIRTIO_DEVFSEL]
        ldr     w21, [x19, #VIRTIO_DEVFEAT]
        mov     w9, #(1 << VNET_F_MAC)
        and     w9, w9, w21                     /* only if it offers it */
        str     wzr, [x19, #VIRTIO_DRVFSEL]
        str     w9, [x19, #VIRTIO_DRVFEAT]
        LEA     x10, vnet_has_mac
        str     w9, [x10]

        mov     w9, #1
        str     w9, [x19, #VIRTIO_DEVFSEL]
        ldr     w9, [x19, #VIRTIO_DEVFEAT]
        mov     w9, #1
        str     w9, [x19, #VIRTIO_DRVFSEL]
        mov     w9, #1                          /* VIRTIO_F_VERSION_1 */
        str     w9, [x19, #VIRTIO_DRVFEAT]

        mov     w9, #(ST_ACK | ST_DRIVER | ST_FEATURES_OK)
        str     w9, [x19, #VIRTIO_STATUS]
        ldr     w9, [x19, #VIRTIO_STATUS]
        tbz     w9, #3, .Lni_fail

/* ---- our own address, if the device will say ------------------------- */
        LEA     x9, vnet_has_mac
        ldr     w9, [x9]
        cbz     w9, 4f
        LEA     x10, vnet_mac
        mov     w11, #0
5:      cmp     w11, #6
        b.hs    4f
        add     x12, x19, #VIRTIO_CONFIG
        ldrb    w13, [x12, w11, uxtw]
        strb    w13, [x10, w11, uxtw]
        add     w11, w11, #1
        b       5b
4:

/* ---- queue 0, receive ------------------------------------------------ */
        str     wzr, [x19, #VIRTIO_QSEL]
        mov     w0, #0
        LEA     x1, rx_desc
        LEA     x2, rx_avail
        LEA     x3, rx_used
        bl      vnet_queue

/* Every receive buffer posted at once: a frame with nowhere to land is a
   frame the device throws away. */
        LEA     x20, rx_desc
        LEA     x21, rx_buf
        mov     w22, #0
1:      cmp     w22, #NQ
        b.hs    2f
        lsl     w9, w22, #4
        add     x10, x20, w9, uxtw
        mov     w11, #BUFSZ
        mul     w11, w22, w11
        add     x11, x21, w11, uxtw
        str     x11, [x10]
        mov     w12, #BUFSZ
        str     w12, [x10, #8]
        mov     w12, #2                         /* device writes into it */
        strh    w12, [x10, #12]
        strh    wzr, [x10, #14]
        LEA     x9, rx_avail
        add     x9, x9, #4
        strh    w22, [x9, w22, uxtw #1]
        add     w22, w22, #1
        b       1b
2:      LEA     x9, rx_avail
        strh    wzr, [x9]
        mov     w10, #NQ
        strh    w10, [x9, #2]
        LEA     x9, rx_last
        strh    wzr, [x9]

/* ---- queue 1, transmit ----------------------------------------------- */
        mov     w9, #1
        str     w9, [x19, #VIRTIO_QSEL]
        mov     w0, #1
        LEA     x1, tx_desc
        LEA     x2, tx_avail
        LEA     x3, tx_used
        bl      vnet_queue
        LEA     x9, tx_avail
        strh    wzr, [x9]
        strh    wzr, [x9, #2]
        LEA     x9, tx_last
        strh    wzr, [x9]
        LEA     x9, tx_next
        str     wzr, [x9]

        dsb     sy
        mov     w9, #(ST_ACK | ST_DRIVER | ST_FEATURES_OK | ST_DRIVER_OK)
        str     w9, [x19, #VIRTIO_STATUS]
        str     wzr, [x19, #VIRTIO_QNOTIFY]     /* here are your buffers */

        mov     w0, #0
        b       .Lni_out
.Lni_fail:
        mov     w9, #128
        str     w9, [x19, #VIRTIO_STATUS]
.Lni_none:
        LEA     x9, vnet_dev
        str     xzr, [x9]
        mov     w0, #-1
.Lni_out:
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * vnet_queue - w0 = which queue, x1/x2/x3 = descriptor, available, used.
 * The selector has already been written by the caller.
 */
vnet_queue:
        LEA     x9, vnet_dev
        ldr     x9, [x9]
        mov     w10, #NQ
        str     w10, [x9, #VIRTIO_QNUM]
        str     w1, [x9, #VIRTIO_QDESC_LO]
        lsr     x10, x1, #32
        str     w10, [x9, #VIRTIO_QDESC_HI]
        str     w2, [x9, #VIRTIO_QAVAIL_LO]
        lsr     x10, x2, #32
        str     w10, [x9, #VIRTIO_QAVAIL_HI]
        str     w3, [x9, #VIRTIO_QUSED_LO]
        lsr     x10, x3, #32
        str     w10, [x9, #VIRTIO_QUSED_HI]
        mov     w10, #1
        str     w10, [x9, #VIRTIO_QREADY]
        ret

/*
 * net_send - x0 = the frame, w1 = its length.
 *   out w0 = 0, or -1 if there is no device.
 *
 * The frame is copied into a transmit buffer behind a zeroed header. Copying
 * rather than pointing at the caller's memory is the right trade here: the
 * caller gets its buffer back immediately, and a frame is fifteen hundred
 * bytes at the very most.
 */
        .globl  net_send
net_send:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        LEA     x9, vnet_dev
        ldr     x9, [x9]
        cbz     x9, .Lns_fail
        mov     w10, #FRAME_MAX
        cmp     w1, w10
        b.hi    .Lns_fail

        LEA     x10, tx_next                    /* round robin */
        ldr     w11, [x10]
        add     w12, w11, #1
        cmp     w12, #NQ
        csel    w12, w12, wzr, lo
        str     w12, [x10]

        mov     w13, #BUFSZ
        mul     w13, w11, w13
        LEA     x14, tx_buf
        add     x14, x14, w13, uxtw

        mov     w15, #0                         /* the header is all zeroes */
1:      cmp     w15, #NET_HDR
        b.hs    2f
        strb    wzr, [x14, w15, uxtw]
        add     w15, w15, #1
        b       1b
2:      add     x16, x14, #NET_HDR
        mov     w15, #0
3:      cmp     w15, w1
        b.hs    4f
        ldrb    w17, [x0, w15, uxtw]
        strb    w17, [x16, w15, uxtw]
        add     w15, w15, #1
        b       3b
4:
        lsl     w15, w11, #4                    /* its descriptor */
        LEA     x16, tx_desc
        add     x16, x16, w15, uxtw
        str     x14, [x16]
        add     w17, w1, #NET_HDR
        str     w17, [x16, #8]
        strh    wzr, [x16, #12]                 /* the device only reads it */
        strh    wzr, [x16, #14]

        LEA     x16, tx_avail                   /* offer it */
        ldrh    w17, [x16, #2]
        and     w15, w17, #(NQ - 1)
        add     x14, x16, #4
        strh    w11, [x14, w15, uxtw #1]
        add     w17, w17, #1
        dsb     sy
        strh    w17, [x16, #2]
        mov     w15, #1
        str     w15, [x9, #VIRTIO_QNOTIFY]

        mov     w0, #0
        b       .Lns_out
.Lns_fail:
        mov     w0, #-1
.Lns_out:
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * net_recv - x0 = where to put it, w1 = how much room.
 *   out w0 = the frame's length, or -1 if nothing has arrived.
 *
 * The buffer is handed straight back to the device afterwards, because a
 * receive ring that is not replenished stops receiving.
 */
        .globl  net_recv
net_recv:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        LEA     x9, vnet_dev
        ldr     x9, [x9]
        cbz     x9, .Lnr_none

        LEA     x10, rx_used
        ldrh    w11, [x10, #2]
        LEA     x12, rx_last
        ldrh    w13, [x12]
        cmp     w11, w13
        b.eq    .Lnr_none

        and     w14, w13, #(NQ - 1)
        add     x15, x10, #4
        lsl     w16, w14, #3
        add     x15, x15, w16, uxtw
        ldr     w16, [x15]                      /* descriptor id */
        ldr     w17, [x15, #4]                  /* bytes written */
        add     w13, w13, #1
        strh    w13, [x12]

        and     w16, w16, #(NQ - 1)
        sub     w17, w17, #NET_HDR              /* past the virtio header */
        tbnz    w17, #31, .Lnr_repost
        cmp     w17, w1
        csel    w17, w17, w1, ls                /* never past the caller's end */

        mov     w19, #BUFSZ
        mul     w19, w16, w19
        LEA     x20, rx_buf
        add     x20, x20, w19, uxtw
        add     x20, x20, #NET_HDR
        mov     w19, #0
1:      cmp     w19, w17
        b.hs    2f
        ldrb    w9, [x20, w19, uxtw]
        strb    w9, [x0, w19, uxtw]
        add     w19, w19, #1
        b       1b
2:
.Lnr_repost:
        LEA     x9, rx_avail                    /* the device gets it back */
        ldrh    w10, [x9, #2]
        and     w11, w10, #(NQ - 1)
        add     x12, x9, #4
        strh    w16, [x12, w11, uxtw #1]
        add     w10, w10, #1
        dsb     sy
        strh    w10, [x9, #2]
        LEA     x9, vnet_dev
        ldr     x9, [x9]
        str     wzr, [x9, #VIRTIO_QNOTIFY]

        tbnz    w17, #31, .Lnr_none
        mov     w0, w17
        b       .Lnr_out
.Lnr_none:
        mov     w0, #-1
.Lnr_out:
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* net_mac - x0 = where to put six bytes of our own address. */
        .globl  net_mac
net_mac:
        LEA     x9, vnet_mac
        mov     w10, #0
1:      cmp     w10, #6
        b.hs    9f
        ldrb    w11, [x9, w10, uxtw]
        strb    w11, [x0, w10, uxtw]
        add     w10, w10, #1
        b       1b
9:      ret

        .section .rodata
s_c_virtio_mmio: .asciz "virtio,mmio"

        .section .bss
/* Shared with the device, so page-aligned - the MMU is off and unaligned
   access faults; see the note in gfx/video.S. */
        .p2align 12
rx_desc:        .space (16 * NQ)
        .p2align 12
rx_avail:       .space (6 + 2 * NQ)
        .p2align 12
rx_used:        .space (6 + 8 * NQ)
        .p2align 12
tx_desc:        .space (16 * NQ)
        .p2align 12
tx_avail:       .space (6 + 2 * NQ)
        .p2align 12
tx_used:        .space (6 + 8 * NQ)
        .p2align 12
rx_buf:         .space (BUFSZ * NQ)
        .p2align 12
tx_buf:         .space (BUFSZ * NQ)
        .p2align 3
vnet_dev:       .space 8
vnet_mac:       .space 8
vnet_has_mac:   .space 4
rx_last:        .space 4
tx_last:        .space 4
tx_next:        .space 4
