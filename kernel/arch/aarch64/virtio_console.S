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

        movz    w0, #VCON_DEVICE
        bl      SYM(vpci_open)
        cmn     w0, #1
        b.eq    .Lvi_no

        /* The receive queue, enabled and ignored. See the header. */
        mov     w0, #RXQ
        LEA     x1, rx_desc
        LEA     x2, rx_avail
        LEA     x3, rx_used
        mov     w4, #QSIZE
        bl      SYM(vpci_queue)

        mov     w0, #TXQ
        LEA     x1, tx_desc
        LEA     x2, tx_avail
        LEA     x3, tx_used
        mov     w4, #QSIZE
        bl      SYM(vpci_queue)
        cmn     w0, #1
        b.eq    .Lvi_no
        LEA     x9, tx_size
        str     w0, [x9]

/*
 * Somewhere for input to go, before the device is told it may run.
 *
 * Nothing here reads it. It exists because a device with an empty receive
 * queue has nowhere to put a keystroke, and an implementation that checks for
 * that before doing anything at all would refuse to transmit either - which is
 * a plausible reason for a correctly configured queue to sit untouched.
 */
        LEA     x9, rx_desc
        LEA     x10, rx_buf
        str     x10, [x9, #DESC_ADDR]
        mov     w11, #64
        str     w11, [x9, #DESC_LEN]
        mov     w11, #2                 /* device-writable */
        strh    w11, [x9, #DESC_FLAGS]
        strh    wzr, [x9, #DESC_NEXT]
        LEA     x9, rx_avail
        strh    wzr, [x9, #AVAIL_RING]
        dsb     sy
        mov     w11, #1
        strh    w11, [x9, #AVAIL_IDX]
        dsb     sy

/*
 * Every queue the device declares, configured, whether or not this driver
 * intends to use it.
 *
 * The framework's console reports four - the port's pair and a control pair -
 * and the specification does not require a driver to configure queues it will
 * not use. An implementation that walks all of them at DRIVER_OK and finds two
 * disabled is a plausible reason for a correctly configured transmit queue to
 * sit untouched, and giving them rings costs two pages.
 */
        bl      SYM(vpci_numq)
        mov     w19, w0
        cmp     w19, #2
        b.ls    3f
        mov     w0, #2
        LEA     x1, c0_desc
        LEA     x2, c0_avail
        LEA     x3, c0_used
        mov     w4, #QSIZE
        bl      SYM(vpci_queue)
        cmp     w19, #3
        b.ls    3f
        mov     w0, #3
        LEA     x1, c1_desc
        LEA     x2, c1_avail
        LEA     x3, c1_used
        mov     w4, #QSIZE
        bl      SYM(vpci_queue)
3:
        bl      SYM(vpci_ready)

        mov     w0, #RXQ                /* and tell it there is one */
        bl      SYM(vpci_kick_queue)

        LEA     x9, vcon_up
        mov     w10, #1
        str     w10, [x9]
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
        /* One descriptor, device-readable, pointing at what we just copied. */
        LEA     x9, tx_desc
        str     x21, [x9, #DESC_ADDR]
        str     w20, [x9, #DESC_LEN]
        strh    wzr, [x9, #DESC_FLAGS]
        strh    wzr, [x9, #DESC_NEXT]

        /*
         * Offer it. The index is not masked - it is a free-running counter and
         * the device does the masking - but the slot it names is, which is the
         * one place a driver commonly gets this backwards.
         */
        LEA     x9, tx_avail
        ldrh    w10, [x9, #AVAIL_IDX]
        LEA     x11, tx_size
        ldr     w11, [x11]
        sub     w12, w11, #1
        and     w12, w10, w12
        add     x13, x9, #AVAIL_RING
        strh    wzr, [x13, w12, uxtw #1]        /* descriptor zero */
        dsb     sy
        add     w10, w10, #1
        strh    w10, [x9, #AVAIL_IDX]
        dsb     sy

        mov     w0, #TXQ
        bl      SYM(vpci_kick_queue)

        /*
         * Wait for it to be taken. Bounded, because a device that never
         * answers must not stop a kernel whose only remaining job is to say
         * what went wrong.
         */
        LEA     x9, tx_used
        ldrh    w10, [x9, #USED_IDX]
        LEA     x11, tx_last
        ldrh    w12, [x11]
        mov     w13, #0
3:      LEA     x9, tx_used
        ldrh    w10, [x9, #USED_IDX]
        cmp     w10, w12
        b.ne    4f
        add     w13, w13, #1
        mov     w14, #0x8000
        movk    w14, #0x000F, lsl #16   /* about a million turns */
        cmp     w13, w14
        b.lo    3b
        mov     w19, #0                 /* gave up: the message is lost, not the kernel */
        b       .Lvw_done
4:      LEA     x11, tx_last
        strh    w10, [x11]
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

        .section .bss
        .p2align 12
tx_desc:   .space (16 * QSIZE)
        .p2align 12
tx_avail:  .space (6 + 2 * QSIZE)
        .p2align 12
tx_used:   .space (6 + 8 * QSIZE)
        .p2align 12
rx_desc:   .space (16 * QSIZE)
        .p2align 12
rx_avail:  .space (6 + 2 * QSIZE)
        .p2align 12
rx_used:   .space (6 + 8 * QSIZE)
        .p2align 12
tx_buf:    .space 512
        .p2align 12
rx_buf:    .space 64
        .p2align 12
c0_desc:   .space (16 * QSIZE)
        .p2align 12
c0_avail:  .space (6 + 2 * QSIZE)
        .p2align 12
c0_used:   .space (6 + 8 * QSIZE)
        .p2align 12
c1_desc:   .space (16 * QSIZE)
        .p2align 12
c1_avail:  .space (6 + 2 * QSIZE)
        .p2align 12
c1_used:   .space (6 + 8 * QSIZE)
        .p2align 3
vcon_up:   .space 4
tx_size:   .space 4
tx_last:   .space 4
