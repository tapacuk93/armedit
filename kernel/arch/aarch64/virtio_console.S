#include "asm.inc"
/*
 * virtio_console.S - saying something on a machine with no serial port.
 *
 * macOS's Virtualization framework offers a virtio console and nothing else:
 * no PL011, no framebuffer, no way at all for a kernel to report on itself.
 * Until this file existed, every question about that machine had to be asked
 * one bit at a time by powering off or not - which works, and is a miserable
 * way to find a bug.
 *
 * <h2>One descriptor, and no receive queue</h2>
 *
 * Output only, one buffer at a time, polled to completion before returning.
 * That is not a placeholder: a debug channel that queues is a debug channel
 * that loses the last thing printed before a crash, which is the thing worth
 * having. Waiting for the device to take each write costs nothing that
 * matters and means a message on the wire is a message that arrived.
 *
 * The receive queue is set up because the specification requires every queue a
 * device advertises to be enabled before DRIVER_OK, and then never used. Input
 * on this machine comes from somewhere else.
 *
 * <h2>The rings are ordinary memory</h2>
 *
 * With the MMU off a virtual address is a physical one, so the device is told
 * where these arrays are and that is where it looks. Page-aligned, which is
 * more than the specification asks - descriptors need sixteen bytes, the
 * available ring two, the used ring four - because the cost is nothing and an
 * alignment fault in a driver whose job is to report faults would be a poor
 * way to spend an afternoon.
 */

#define VCON_DEVICE     0x1043          /* modern virtio console */
#define QSIZE           8               /* we use one entry of it */
#define VCON_MAX        4               /* consoles to try before giving up */

#define DESC_ADDR       0
#define DESC_LEN        8
#define DESC_FLAGS      12
#define DESC_NEXT       14

#define AVAIL_FLAGS     0
#define AVAIL_IDX       2
#define AVAIL_RING      4

#define USED_FLAGS      0
#define USED_IDX        2

#define TXQ             1               /* queue 0 receives, queue 1 transmits */
#define RXQ             0

        .section .text
        .p2align 2

/*
 * vcon_init - out w0 = 0 if there is a console here.
 *
 * Called once, early, and allowed to fail quietly: a machine with a real
 * serial port has no need of this and should not be slowed down by it.
 */
        .globl  vcon_init
vcon_init:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]

/*
 * Packed rings, because this device does not answer split ones.
 *
 * Every configuration step verified correct and the device took nothing, on
 * any of its queues, in either direction - while the entropy device on the
 * same bus, through the same code, serviced a split ring immediately. The
 * console offers VIRTIO_F_RING_PACKED and the difference between the two
 * devices is which layout each actually implements.
 *
 * A packed ring is one array instead of three. A descriptor is available when
 * its AVAIL flag matches the driver's wrap counter and its USED flag does not;
 * the device flips USED to match when it is done. There is no separate
 * available ring and no used ring - the flags in the descriptor are both.
 */
        mov     w0, #1
        bl      SYM(vpci_packed)

/*
 * Whichever console the host is actually listening to.
 *
 * There is more than one on this bus and only one of them has anything
 * attached to its far end. Both accept every register write, both enable their
 * queues, and only one ever completes a descriptor - so the way to tell them
 * apart is to write to each and see which answers. A newline is the quietest
 * thing to send.
 */
        mov     w19, #0
.Lvi_try:
        cmp     w19, #VCON_MAX
        b.hs    .Lvi_no
        movz    w0, #VCON_DEVICE
        mov     w1, w19
        bl      SYM(vpci_open_n)
        cmn     w0, #1
        b.eq    .Lvi_next

        /* The receive queue, enabled and ignored. See the header. */
        mov     w0, #RXQ
        LEA     x1, rx_desc
        LEA     x2, rx_drv
        LEA     x3, rx_dev
        mov     w4, #QSIZE
        bl      SYM(vpci_queue)

        mov     w0, #TXQ
        LEA     x1, tx_desc
        LEA     x2, tx_drv
        LEA     x3, tx_dev
        mov     w4, #QSIZE
        bl      SYM(vpci_queue)
        cmn     w0, #1
        b.eq    .Lvi_no
        LEA     x9, tx_size
        str     w0, [x9]

        bl      SYM(vpci_numq)
        mov     w19, w0
        cmp     w19, #2
        b.ls    3f
        mov     w0, #2
        LEA     x1, c0_desc
        LEA     x2, c0_drv
        LEA     x3, c0_dev
        mov     w4, #QSIZE
        bl      SYM(vpci_queue)
        cmp     w19, #3
        b.ls    3f
        mov     w0, #3
        LEA     x1, c1_desc
        LEA     x2, c1_drv
        LEA     x3, c1_dev
        mov     w4, #QSIZE
        bl      SYM(vpci_queue)
3:
        bl      SYM(vpci_ready)

        LEA     x9, vcon_up             /* provisionally, so vcon_write runs */
        mov     w10, #1
        str     w10, [x9]

        LEA     x0, s_probe_nl          /* does anything answer? */
        mov     w1, #1
        bl      vcon_write
        cbnz    w0, .Lvi_yes

        LEA     x9, vcon_up             /* no: put it back and try the next */
        str     wzr, [x9]
.Lvi_next:
        add     w19, w19, #1
        LEA     x9, tx_next             /* a fresh ring for a fresh device */
        str     wzr, [x9]
        b       .Lvi_try

.Lvi_yes:
        mov     w0, #0
        b       .Lvi_out
.Lvi_no:
        mov     w0, #-1
.Lvi_out:
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/* vcon_desc - out x0 = where we told the device our descriptors are. */
        .globl  vcon_desc
vcon_desc:
        LEA     x0, tx_desc
        ret

/* vcon_qsize - w0 = the transmit ring size actually in force. */
        .globl  vcon_qsize
vcon_qsize:
        LEA     x9, tx_size
        ldr     w0, [x9]
        ret

/* vcon_ready - w0 = 1 if there is somewhere to write. */
        .globl  vcon_ready
vcon_ready:
        LEA     x9, vcon_up
        ldr     w0, [x9]
        ret

/*
 * vcon_write - x0 = bytes, w1 = how many.
 *
 * Copied into a buffer of ours before being handed over, because the caller's
 * string may be in read-only memory or on a stack that is about to change, and
 * the device reads it after this function has been entered rather than while.
 */
        .globl  vcon_write
vcon_write:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]
        mov     x19, x0
        mov     w20, w1

        LEA     x9, vcon_up
        ldr     w9, [x9]
        cbz     w9, .Lvw_out
        cbz     w20, .Lvw_out

        mov     w9, #512                /* what the staging buffer holds */
        cmp     w20, w9
        csel    w20, w20, w9, lo

        LEA     x21, tx_buf
        mov     w9, #0
1:      cmp     w9, w20
        b.hs    2f
        ldrb    w10, [x19, w9, uxtw]
        strb    w10, [x21, w9, uxtw]
        add     w9, w9, #1
        b       1b
2:
/*
 * One packed descriptor, made available.
 *
 * addr, len, id, then the flags last - the flags are what publishes it, so
 * everything the device will read has to be in memory before they are written,
 * which is what the barrier between them is for.
 */
        LEA     x9, tx_desc
        LEA     x10, tx_next
        ldr     w11, [x10]              /* which slot */
        mov     w12, #16
        madd    x9, x11, x12, x9

        str     x21, [x9, #0]           /* addr */
        str     w20, [x9, #8]           /* len  */
        strh    w11, [x9, #12]          /* id, which comes back in the used one */
        dsb     sy

        LEA     x10, tx_wrap
        ldr     w13, [x10]
        cbz     w13, 5f
        mov     w14, #0x0080            /* AVAIL set, USED clear */
        b       6f
5:      mov     w14, #0x8000            /* the other way round on odd laps */
6:      strh    w14, [x9, #14]
        dsb     sy

        mov     w0, #TXQ
        bl      SYM(vpci_kick_queue)

/*
 * Wait for the device to turn it round.
 *
 * A descriptor is used when its two flags agree with the wrap counter, which
 * is the packed ring's whole completion protocol: there is nowhere else to
 * look, because there is no used ring.
 */
        LEA     x9, tx_desc
        LEA     x10, tx_next
        ldr     w11, [x10]
        mov     w12, #16
        madd    x9, x11, x12, x9
        mov     w15, #0
7:      ldrh    w16, [x9, #14]
        and     w17, w16, #0x0080
        lsr     w17, w17, #7
        and     w0, w16, #0x8000
        lsr     w0, w0, #15
        cmp     w17, w0
        b.ne    8f                      /* still ours */
        LEA     x10, tx_wrap
        ldr     w13, [x10]
        cmp     w17, w13
        b.eq    9f                      /* the device has finished with it */
8:      add     w15, w15, #1
        mov     w0, #0x8000
        movk    w0, #0x000F, lsl #16
        cmp     w15, w0
        b.lo    7b
        mov     w19, #0
        b       .Lvw_done

9:      /* On to the next slot, flipping the lap when it wraps. */
        LEA     x10, tx_next
        ldr     w11, [x10]
        add     w11, w11, #1
        cmp     w11, #QSIZE
        b.lo    10f
        mov     w11, #0
        LEA     x12, tx_wrap
        ldr     w13, [x12]
        eor     w13, w13, #1
        str     w13, [x12]
        LEA     x10, tx_next
10:     str     w11, [x10]
        mov     w19, #1

.Lvw_done:
        mov     w0, w19
        ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

.Lvw_out:
        mov     w0, #0
        ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* vcon_puts - x0 = a NUL-terminated string. */
        .globl  vcon_puts
vcon_puts:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     x19, x0
        bl      SYM(str_len)
        mov     w1, w0
        mov     x0, x19
        bl      vcon_write
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

        .section .rodata
s_probe_nl: .asciz "\n"

        .section .bss
        .p2align 12
tx_desc:   .space (16 * QSIZE)
        .p2align 12
tx_drv:    .space 8        /* driver event suppression */
        .p2align 12
tx_dev:    .space 8        /* device event suppression */
        .p2align 12
rx_desc:   .space (16 * QSIZE)
        .p2align 12
rx_drv:    .space 8
        .p2align 12
rx_dev:    .space 8
        .p2align 12
c0_desc:   .space (16 * QSIZE)
        .p2align 12
c0_drv:    .space 8
        .p2align 12
c0_dev:    .space 8
        .p2align 12
c1_desc:   .space (16 * QSIZE)
        .p2align 12
c1_drv:    .space 8
        .p2align 12
c1_dev:    .space 8
        .p2align 12
tx_buf:    .space 512
        .p2align 3
vcon_up:   .space 4
tx_size:   .space 4
tx_next:   .space 4
tx_wrap:   .space 4
