#include "asm.inc"
/*
 * tcp.S - one connection at a time, opened, used, and closed.
 *
 * This is a client, not a stack. It opens a single connection, sends what it
 * was given, collects what comes back until the far side is finished, and
 * closes. Two connections at once is not a thing it can do, and the single
 * block of state below is where that limit lives.
 *
 * The parts of TCP that are absent are absent knowingly:
 *
 * Nothing is retransmitted. A lost segment ends the exchange and the caller is
 * told the backend could not be reached. Across a virtual link to a process on
 * the same machine that is a fair bet; across a real network it is not, and a
 * retransmit timer is the first thing this would need to grow.
 *
 * Segments that arrive out of order are dropped rather than held, so a network
 * that reorders would look like a network that lost. Holding them means a
 * reassembly queue, and a stack without one should say so rather than seem to
 * work until the day it matters.
 *
 * The window advertised is simply the room left in the receive buffer, and the
 * data sent goes out as one segment. There is no congestion control at all.
 * For a few kilobytes of text to a backend this is fine; as a transport for
 * anything else it is not.
 */

#define ETH_HDR         14
#define IP_HDR          20
#define TCP_HDR         20
#define IP_TCP          6

#define TCP_FIN         0x01
#define TCP_SYN         0x02
#define TCP_RST         0x04
#define TCP_PSH         0x08
#define TCP_ACK         0x10

#define S_CLOSED        0
#define S_SYNSENT       1
#define S_OPEN          2
#define S_DONE          3

#define FRAMEBUF        2048
#define RXBUF           32768
#define MSS             1400

/*
 * How long to wait, in milliseconds, using the machine's actual clock.
 *
 * This was a spin count to begin with, which is wrong in the way that only
 * shows up later: the number of iterations a loop manages in a second depends
 * on the host, the emulator and what else is running, so the same count is
 * minutes on one machine and a fraction of a second on another. It was short
 * enough here that a model taking a second and a half to answer looked exactly
 * like a backend that was not there.
 */
#define WAIT_MS         30000

        CODE
        .p2align 2

/*
 * tcp_connect - w0 = address, w1 = port, both in host order for the port.
 *   out w0 = 0 when the handshake completed, -1 otherwise.
 */
        .globl  SYM(tcp_connect)
SYM(tcp_connect):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     w19, w0
        mov     w20, w1

        LEA     x9, t_state                     /* one connection, so start it
                                                   from a known place every
                                                   time rather than trusting
                                                   whatever the last one left */
        mov     w10, #S_CLOSED
        str     w10, [x9]
        LEA     x9, t_peer
        str     w19, [x9]
        LEA     x9, t_dport
        str     w20, [x9]
        LEA     x9, t_rxlen
        str     wzr, [x9]
        LEA     x9, t_finished
        str     wzr, [x9]

        LEA     x9, t_sport                     /* a port of our own; anything
                                                   ephemeral will do when there
                                                   is only ever one */
        mov     w10, #40000
        LEA     x11, t_seq
        ldr     w12, [x11]
        add     w10, w10, w12
        and     w10, w10, #0x7fff
        orr     w10, w10, #0x8000
        str     w10, [x9]

        mov     w10, #1                         /* our first sequence number */
        LEA     x9, t_snd
        str     w10, [x9]
        LEA     x9, t_rcv
        str     wzr, [x9]

        LEA     x0, t_gwmac                     /* who to hand packets to */
        LEA     x9, t_peer
        ldr     w0, [x9]
        LEA     x1, t_gwmac
        bl      SYM(arp_resolve)
        cmn     w0, #1
        b.eq    .Ltc_fail

        mov     w0, #TCP_SYN
        mov     x1, #0
        mov     w2, #0
        bl      tcp_emit
        LEA     x9, t_snd                       /* a SYN occupies a sequence
                                                   number even though it
                                                   carries no data - forget
                                                   that and every segment after
                                                   it claims a number the far
                                                   side has already seen, which
                                                   it answers with RST */
        ldr     w10, [x9]
        add     w10, w10, #1
        str     w10, [x9]
        LEA     x9, t_state
        mov     w10, #S_SYNSENT
        str     w10, [x9]

        bl      platform_ticks
        mov     x21, x0                         /* when we started asking */
1:      bl      tcp_pump
        LEA     x9, t_state
        ldr     w9, [x9]
        cmp     w9, #S_OPEN
        b.eq    .Ltc_ok
        cmp     w9, #S_CLOSED
        b.eq    .Ltc_fail                       /* refused */
        bl      platform_ticks
        sub     x9, x0, x21
        movz    x10, #(WAIT_MS & 0xFFFF)
        movk    x10, #(WAIT_MS >> 16), lsl #16
        cmp     x9, x10
        b.lo    1b
.Ltc_fail:
        mov     w0, #-1
        b       .Ltc_out
.Ltc_ok:
        mov     w0, #0
.Ltc_out:
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * tcp_send - x0 = bytes, w1 = how many.  out w0 = 0 or -1.
 *
 * Cut into segments of at most one MSS, because a request is only small until
 * it isn't. This began as a single segment on the reasoning that the requests
 * it carried were smaller than one - true of an empty screen asking for a
 * hello world, and false the moment the screen has a program on it. Past 1400
 * bytes it simply refused to send, which the editor reported as the backend
 * being unreachable: the most misleading possible description of a message
 * that was never put on the wire.
 *
 * Between segments we pump the receive side. The far side acknowledges as it
 * goes, and a ring nobody drains is a ring that overflows - dropping the very
 * acknowledgements that say the request arrived.
 */
        .globl  SYM(tcp_send)
SYM(tcp_send):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0                         /* where we are in the buffer */
        mov     w20, w1                         /* what is left of it */
        LEA     x9, t_state
        ldr     w9, [x9]
        cmp     w9, #S_OPEN
        b.ne    .Lts_fail

1:      cbz     w20, .Lts_done
        mov     w21, #MSS                       /* this segment's worth */
        cmp     w20, w21
        csel    w21, w20, w21, ls

        mov     w0, #(TCP_ACK | TCP_PSH)
        mov     x1, x19
        mov     w2, w21
        bl      tcp_emit
        LEA     x9, t_snd                       /* our sequence advances by
                                                   exactly what went out */
        ldr     w10, [x9]
        add     w10, w10, w21
        str     w10, [x9]

        add     x19, x19, w21, uxtw
        sub     w20, w20, w21
        bl      tcp_pump                        /* take their acknowledgements */
        b       1b

.Lts_done:
        mov     w0, #0
        b       .Lts_out
.Lts_fail:
        mov     w0, #-1
.Lts_out:
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * tcp_recv - x0 = where to put it, w1 = how much room.
 *   out w0 = bytes collected.
 *
 * Reads until the far side says it is finished or nothing has arrived for a
 * long time. A request-response exchange has a definite end, which is what
 * makes that a reasonable thing to wait for.
 */
        .globl  SYM(tcp_recv)
SYM(tcp_recv):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0
        mov     w20, w1
        bl      platform_ticks
        mov     x21, x0                         /* when anything last arrived */

1:      LEA     x9, t_finished
        ldr     w9, [x9]
        cbnz    w9, .Ltr_done
        LEA     x9, t_rxlen
        ldr     w22, [x9]
        bl      tcp_pump
        LEA     x9, t_rxlen
        ldr     w9, [x9]
        cmp     w9, w22
        b.eq    2f
        bl      platform_ticks                  /* progress; wait afresh */
        mov     x21, x0
        b       1b
2:      bl      platform_ticks
        sub     x9, x0, x21
        movz    x10, #(WAIT_MS & 0xFFFF)
        movk    x10, #(WAIT_MS >> 16), lsl #16
        cmp     x9, x10
        b.lo    1b

.Ltr_done:
        LEA     x9, t_rxlen
        ldr     w9, [x9]
        cmp     w9, w20
        csel    w9, w9, w20, ls
        LEA     x10, t_rxbuf
        mov     w11, #0
3:      cmp     w11, w9
        b.hs    4f
        ldrb    w12, [x10, w11, uxtw]
        strb    w12, [x19, w11, uxtw]
        add     w11, w11, #1
        b       3b
4:      mov     w0, w9
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/* tcp_close - say goodbye; the far side may already have. */
        .globl  SYM(tcp_close)
SYM(tcp_close):
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        LEA     x9, t_state
        ldr     w9, [x9]
        cmp     w9, #S_OPEN
        b.ne    1f
        mov     w0, #(TCP_ACK | TCP_FIN)
        mov     x1, #0
        mov     w2, #0
        bl      tcp_emit
1:      LEA     x9, t_state
        mov     w10, #S_CLOSED
        str     w10, [x9]
        ldp     x29, x30, [sp], #32
        ret

/*
 * tcp_pump - take one frame off the wire, if there is one, and act on it.
 * Everything arrives through net_take, which routes it back here.
 */
tcp_pump:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        LEA     x0, t_frame
        mov     w1, #FRAMEBUF
        bl      net_recv
        cmn     w0, #1
        b.eq    1f
        mov     w1, w0
        LEA     x0, t_frame
        bl      SYM(net_take)
1:      ldp     x29, x30, [sp], #32
        ret

/*
 * tcp_take - x0 = a TCP segment, w1 = its length. Called by net_take.
 */
        .globl  SYM(tcp_take)
SYM(tcp_take):
        stp     x29, x30, [sp, #-80]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        mov     x19, x0
        mov     w20, w1
        cmp     w20, #TCP_HDR
        b.lo    .Ltk_out

        ldrb    w9, [x19, #2]                   /* is it for our port? */
        ldrb    w10, [x19, #3]
        orr     w9, w10, w9, lsl #8
        LEA     x11, t_sport
        ldr     w11, [x11]
        cmp     w9, w11
        b.ne    .Ltk_out

        ldrb    w21, [x19, #13]                 /* flags */
        ldrb    w9, [x19, #12]                  /* data offset, in words */
        lsr     w9, w9, #4
        lsl     w22, w9, #2                     /* the header's real length */
        cmp     w22, #TCP_HDR
        b.lo    .Ltk_out
        cmp     w22, w20
        b.hi    .Ltk_out

        tbz     w21, #2, 1f                     /* RST: it is over */
        LEA     x9, t_state
        mov     w10, #S_CLOSED
        str     w10, [x9]
        LEA     x9, t_finished
        mov     w10, #1
        str     w10, [x9]
        b       .Ltk_out
1:
        ldrb    w9, [x19, #4]                   /* their sequence number */
        ldrb    w10, [x19, #5]
        ldrb    w11, [x19, #6]
        ldrb    w12, [x19, #7]
        lsl     w23, w9, #24
        orr     w23, w23, w10, lsl #16
        orr     w23, w23, w11, lsl #8
        orr     w23, w23, w12

        LEA     x9, t_state
        ldr     w9, [x9]
        cmp     w9, #S_SYNSENT
        b.ne    .Ltk_open

/* The handshake: their SYN+ACK, our ACK, and we are talking. */
        mov     w11, #(TCP_SYN | TCP_ACK)       /* 0x12 is two separate bits,
                                                   which is not a shape the
                                                   logical immediate encoding
                                                   can hold */
        and     w10, w21, w11
        cmp     w10, w11
        b.ne    .Ltk_out
        add     w23, w23, #1                    /* their SYN counts as a byte */
        LEA     x9, t_rcv
        str     w23, [x9]
        LEA     x9, t_state
        mov     w10, #S_OPEN
        str     w10, [x9]
        mov     w0, #TCP_ACK
        mov     x1, #0
        mov     w2, #0
        bl      tcp_emit
        b       .Ltk_out

.Ltk_open:
        cmp     w9, #S_OPEN
        b.ne    .Ltk_out

        LEA     x9, t_rcv                       /* only what comes next */
        ldr     w24, [x9]
        cmp     w23, w24
        b.ne    .Ltk_ack                        /* out of order, or a repeat:
                                                   acknowledge what we do have
                                                   and drop this */

        sub     w9, w20, w22                    /* how much data it carries */
        cbz     w9, .Ltk_fin
        LEA     x10, t_rxlen
        ldr     w11, [x10]
        mov     w12, #RXBUF
        sub     w12, w12, w11                   /* room left */
        cmp     w9, w12
        csel    w9, w9, w12, ls
        add     x13, x19, w22, uxtw             /* past the header */
        LEA     x14, t_rxbuf
        add     x14, x14, w11, uxtw
        mov     w15, #0
1:      cmp     w15, w9
        b.hs    2f
        ldrb    w16, [x13, w15, uxtw]
        strb    w16, [x14, w15, uxtw]
        add     w15, w15, #1
        b       1b
2:      add     w11, w11, w9
        str     w11, [x10]
        add     w24, w24, w9
        LEA     x9, t_rcv
        str     w24, [x9]

.Ltk_fin:
        tbz     w21, #0, .Ltk_ack               /* their FIN */
        add     w24, w24, #1
        LEA     x9, t_rcv
        str     w24, [x9]
        LEA     x9, t_finished
        mov     w10, #1
        str     w10, [x9]
.Ltk_ack:
        mov     w0, #TCP_ACK
        mov     x1, #0
        mov     w2, #0
        bl      tcp_emit
.Ltk_out:
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #80
        ret

/*
 * tcp_emit - w0 = flags, x1 = payload (or 0), w2 = its length.
 *
 * Builds the whole frame - Ethernet, IP, TCP - and hands it to the device.
 * The TCP checksum covers a pseudo-header of addresses and length that is
 * never actually transmitted, which is the one genuinely surprising thing
 * about the protocol and the usual reason a first implementation does not work.
 */
tcp_emit:
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        mov     w19, w0
        mov     x20, x1
        mov     w21, w2

        LEA     x22, t_out

/* ---- Ethernet -------------------------------------------------------- */
        LEA     x9, t_gwmac
        mov     w10, #0
1:      cmp     w10, #6
        b.hs    2f
        ldrb    w11, [x9, w10, uxtw]
        strb    w11, [x22, w10, uxtw]
        add     w10, w10, #1
        b       1b
2:      add     x0, x22, #6
        bl      net_mac
        mov     w9, #0x08
        strb    w9, [x22, #12]
        strb    wzr, [x22, #13]

/* ---- IPv4 ------------------------------------------------------------ */
        add     x23, x22, #ETH_HDR
        mov     w9, #0x45                       /* version 4, 20-byte header */
        strb    w9, [x23]
        strb    wzr, [x23, #1]                  /* no differentiated services */
        add     w9, w21, #(IP_HDR + TCP_HDR)
        lsr     w10, w9, #8
        strb    w10, [x23, #2]
        strb    w9, [x23, #3]
        strb    wzr, [x23, #4]                  /* identification; we never
                                                   fragment, so it is free */
        strb    wzr, [x23, #5]
        mov     w9, #0x40                       /* do not fragment */
        strb    w9, [x23, #6]
        strb    wzr, [x23, #7]
        mov     w9, #64                         /* time to live */
        strb    w9, [x23, #8]
        mov     w9, #IP_TCP
        strb    w9, [x23, #9]
        strb    wzr, [x23, #10]                 /* checksum, filled in below */
        strb    wzr, [x23, #11]
        LEA     x9, SYM(my_ip)
        ldr     w11, [x9]
        add     x12, x23, #12
        bl      tcp_put_ip
        LEA     x9, t_peer
        ldr     w11, [x9]
        add     x12, x23, #16
        bl      tcp_put_ip

        mov     x0, x23                         /* the header checksums itself */
        mov     w1, #IP_HDR
        mov     w2, #0
        bl      SYM(ip_sum)
        bl      SYM(ip_fold)
        lsr     w9, w0, #8
        strb    w9, [x23, #10]
        strb    w0, [x23, #11]

/* ---- TCP -------------------------------------------------------------- */
        add     x24, x23, #IP_HDR
        LEA     x9, t_sport
        ldr     w9, [x9]
        lsr     w10, w9, #8
        strb    w10, [x24]
        strb    w9, [x24, #1]
        LEA     x9, t_dport
        ldr     w9, [x9]
        lsr     w10, w9, #8
        strb    w10, [x24, #2]
        strb    w9, [x24, #3]
        LEA     x9, t_snd
        ldr     w11, [x9]
        add     x12, x24, #4
        bl      tcp_put32
        LEA     x9, t_rcv
        ldr     w11, [x9]
        add     x12, x24, #8
        bl      tcp_put32
        mov     w9, #0x50                       /* five words of header */
        strb    w9, [x24, #12]
        strb    w19, [x24, #13]
        mov     w9, #(RXBUF >> 8)               /* the window is the room left */
        strb    w9, [x24, #14]
        strb    wzr, [x24, #15]
        strb    wzr, [x24, #16]                 /* checksum */
        strb    wzr, [x24, #17]
        strb    wzr, [x24, #18]                 /* no urgent pointer */
        strb    wzr, [x24, #19]

        add     x9, x24, #TCP_HDR               /* the payload */
        mov     w10, #0
3:      cmp     w10, w21
        b.hs    4f
        ldrb    w11, [x20, w10, uxtw]
        strb    w11, [x9, w10, uxtw]
        add     w10, w10, #1
        b       3b
4:
/*
 * The pseudo-header: source, destination, zero, protocol, TCP length. It is
 * summed but not sent, which is what ties a segment to the addresses it was
 * meant for.
 */
        LEA     x12, t_pseudo
        LEA     x9, SYM(my_ip)
        ldr     w11, [x9]
        bl      tcp_put_ip
        LEA     x9, t_peer
        ldr     w11, [x9]
        LEA     x12, t_pseudo
        add     x12, x12, #4
        bl      tcp_put_ip
        LEA     x12, t_pseudo
        strb    wzr, [x12, #8]
        mov     w9, #IP_TCP
        strb    w9, [x12, #9]
        add     w9, w21, #TCP_HDR
        lsr     w10, w9, #8
        strb    w10, [x12, #10]
        strb    w9, [x12, #11]

        LEA     x0, t_pseudo
        mov     w1, #12
        mov     w2, #0
        bl      SYM(ip_sum)
        mov     w2, w0
        mov     x0, x24
        add     w1, w21, #TCP_HDR
        bl      SYM(ip_sum)
        bl      SYM(ip_fold)
        lsr     w9, w0, #8
        strb    w9, [x24, #16]
        strb    w0, [x24, #17]

        LEA     x0, t_out
        add     w1, w21, #(ETH_HDR + IP_HDR + TCP_HDR)
        bl      net_send

        LEA     x9, t_seq                       /* nudge, so the next connection
                                                   picks a different port */
        ldr     w10, [x9]
        add     w10, w10, #1
        str     w10, [x9]

        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

/*
 * Two ways to put four bytes on the wire, because two different things live in
 * these fields.
 *
 * A sequence number is an integer, and integers go big-endian: most
 * significant byte first. An address is not an integer - it is four bytes in a
 * fixed order, and it is held here the way net_ip4 packs one, first byte in
 * the low bits, so that an address means the same thing on both sides of the
 * seam with net/http.S.
 *
 * Using one routine for both is what made the first version send its SYN
 * announcing sequence number 16777216 instead of 1. The checksums were all
 * valid; the numbers were simply backwards, which is why the far side kept
 * politely repeating itself.
 */
tcp_put32:                                      /* an integer */
        lsr     w13, w11, #24
        strb    w13, [x12]
        lsr     w13, w11, #16
        strb    w13, [x12, #1]
        lsr     w13, w11, #8
        strb    w13, [x12, #2]
        strb    w11, [x12, #3]
        ret

tcp_put_ip:                                     /* four bytes in wire order */
        strb    w11, [x12]
        lsr     w13, w11, #8
        strb    w13, [x12, #1]
        lsr     w13, w11, #16
        strb    w13, [x12, #2]
        lsr     w13, w11, #24
        strb    w13, [x12, #3]
        ret

        BSS
        .p2align 3
t_out:      .space FRAMEBUF
t_frame:    .space FRAMEBUF
t_rxbuf:    .space RXBUF
t_pseudo:   .space 16
t_gwmac:    .space 8
        .p2align 2
t_peer:     .space 4
t_sport:    .space 4
t_dport:    .space 4
t_snd:      .space 4
t_rcv:      .space 4
t_state:    .space 4
t_rxlen:    .space 4
t_finished: .space 4
t_seq:      .space 4
