#include "asm.inc"
/*
 * net.S - ARP, IPv4 and just enough TCP to ask a question and hear the answer.
 *
 * This is the part of a network stack a text editor actually needs: find the
 * gateway's hardware address, put a packet in front of it, open one connection
 * at a time, and read the reply. Everything a real stack does that this does
 * not - fragmentation, reassembly, congestion control, window scaling,
 * selective acknowledgement, more than one socket - is missing on purpose, and
 * the honest description is not "a TCP implementation" but "a client that can
 * complete one exchange over TCP".
 *
 * <h2>What that costs, precisely</h2>
 *
 * No retransmission. A dropped segment ends the exchange rather than being
 * repaired, and the editor reports that it could not reach the backend. Over a
 * virtual link to a host on the same machine, loss is not a thing that
 * happens; over a real network it very much is, and this would need to grow a
 * retransmit timer before anybody trusted it there.
 *
 * No congestion control. The window this advertises is a fixed buffer and the
 * data sent is one segment. That is defensible only because the exchange is a
 * few kilobytes of text; it is not a general transport.
 *
 * Out-of-order segments are dropped rather than held. A stack that reassembles
 * needs a queue and a reassembly policy, and a stack that has neither should
 * say so rather than appear to work until the day the network reorders.
 *
 * <h2>Checksums</h2>
 *
 * Computed rather than offloaded, in one place, because the same one's
 * complement sum serves IP, TCP and ICMP - the only difference is what is fed
 * into it.
 */

#define ETH_HDR         14
#define ETH_ARP         0x0806
#define ETH_IP          0x0800

#define IP_TCP          6
#define IP_ICMP         1

#define TCP_FIN         0x01
#define TCP_SYN         0x02
#define TCP_RST         0x04
#define TCP_PSH         0x08
#define TCP_ACK         0x10

#define FRAMEBUF        2048
#define RXWIN           16384           /* what we can hold, so what we advertise */

/* Connection states, few enough to name. */
#define S_CLOSED        0
#define S_SYNSENT       1
#define S_OPEN          2
#define S_DONE          3

        CODE
        .p2align 2

/*
 * ip_configure - w0 = our address, w1 = the gateway, all network byte order.
 *
 * There is no DHCP here. QEMU's user-mode network hands out fixed, documented
 * addresses, so for the one machine this kernel runs on they can be told to it
 * rather than discovered. A board on a real network would need the discovery,
 * and this is where it would go.
 */
        .globl  SYM(ip_configure)
SYM(ip_configure):
        LEA     x9, SYM(my_ip)
        str     w0, [x9]
        LEA     x9, gw_ip
        str     w1, [x9]
        LEA     x9, arp_ok
        str     wzr, [x9]
        ret

/* ---------------------------------------------------------------- checksum */

/*
 * ip_sum - x0 = bytes, w1 = how many, w2 = a sum to continue from.
 *   out w0 = the running one's complement sum, not yet folded.
 */
        .globl  SYM(ip_sum)
SYM(ip_sum):
        mov     w3, w2
        mov     w4, #0
1:      add     w5, w4, #1
        cmp     w5, w1
        b.hs    2f
        ldrb    w6, [x0, w4, uxtw]
        ldrb    w7, [x0, w5, uxtw]
        orr     w6, w7, w6, lsl #8              /* big-endian, as the wire is */
        add     w3, w3, w6
        add     w4, w4, #2
        b       1b
2:      cmp     w4, w1                          /* an odd tail byte is padded */
        b.hs    3f
        ldrb    w6, [x0, w4, uxtw]
        lsl     w6, w6, #8
        add     w3, w3, w6
3:      mov     w0, w3
        ret

/* ip_fold - w0 = a running sum, out w0 = the sixteen-bit checksum. */
        .globl  SYM(ip_fold)
SYM(ip_fold):
1:      lsr     w1, w0, #16
        cbz     w1, 2f
        and     w0, w0, #0xffff
        add     w0, w0, w1
        b       1b
2:      mvn     w0, w0
        and     w0, w0, #0xffff
        ret

/* ------------------------------------------------------------------- ARP */

/*
 * arp_resolve - w0 = an address, x1 = where to put six bytes of hardware
 * address.  out w0 = 0 on success, -1 if nobody answered.
 *
 * One entry of cache, because this kernel talks to exactly one thing: the
 * gateway. A second entry would be a table, and a table would be a design
 * decision made before it was needed.
 */
        .globl  SYM(arp_resolve)
SYM(arp_resolve):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     w19, w0
        mov     x20, x1

.Lar_check:                                     /* already known? */
        LEA     x9, arp_ok
        ldr     w10, [x9]
        cbz     w10, .Lar_ask
        LEA     x9, arp_ip
        ldr     w10, [x9]
        cmp     w10, w19
        b.ne    .Lar_ask
        LEA     x9, arp_mac
        mov     w10, #0
1:      cmp     w10, #6
        b.hs    9f
        ldrb    w11, [x9, w10, uxtw]
        strb    w11, [x20, w10, uxtw]
        add     w10, w10, #1
        b       1b
9:      mov     w0, #0
        b       .Lar_out

.Lar_ask:
        mov     w21, #0                         /* how many times we have asked */
.Lar_again:
        LEA     x0, txframe
        bl      arp_build_request
        LEA     x0, txframe
        mov     w1, #42                         /* 14 of Ethernet, 28 of ARP */
        bl      net_send

        mov     w22, #0                         /* how long we have waited */
.Lar_wait:
        LEA     x0, rxframe
        mov     w1, #FRAMEBUF
        bl      net_recv
        cmn     w0, #1
        b.eq    .Lar_tick
        mov     w1, w0
        LEA     x0, rxframe
        bl      net_take                        /* it might be anything */
        LEA     x9, arp_ok                      /* answered: the cache is warm
                                                   now, so read it out rather
                                                   than asking all over again */
        ldr     w9, [x9]
        cbnz    w9, .Lar_check
.Lar_tick:
        add     w22, w22, #1
        movz    w9, #(200000 & 0xFFFF)
        movk    w9, #(200000 >> 16), lsl #16
        cmp     w22, w9
        b.lo    .Lar_wait
        add     w21, w21, #1
        cmp     w21, #3
        b.lo    .Lar_again
        mov     w0, #-1
.Lar_out:
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * arp_build_request - x0 = a frame buffer; asks who has gw_ip.
 *
 * x19 holds the frame and the ARP header is recomputed from it after every
 * call, because net_mac uses x9 for its own purposes - and a pointer left in a
 * scratch register across a call is how this first went out asking about
 * 0.0.0.0.
 */
arp_build_request:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     x19, x0

        mov     w9, #0xff                       /* to everyone */
        mov     w10, #0
1:      cmp     w10, #6
        b.hs    2f
        strb    w9, [x19, w10, uxtw]
        add     w10, w10, #1
        b       1b
2:      add     x0, x19, #6                     /* and from us */
        bl      net_mac
        mov     w9, #0x08                       /* ethertype ARP */
        strb    w9, [x19, #12]
        mov     w9, #0x06
        strb    w9, [x19, #13]

        add     x9, x19, #ETH_HDR
        strb    wzr, [x9]                       /* hardware type 1, Ethernet */
        mov     w10, #1
        strb    w10, [x9, #1]
        mov     w10, #0x08                      /* protocol type IPv4 */
        strb    w10, [x9, #2]
        strb    wzr, [x9, #3]
        mov     w10, #6                         /* six bytes of hardware */
        strb    w10, [x9, #4]
        mov     w10, #4                         /* four of protocol */
        strb    w10, [x9, #5]
        strb    wzr, [x9, #6]
        mov     w10, #1                         /* a request */
        strb    w10, [x9, #7]

        add     x0, x19, #(ETH_HDR + 8)         /* our hardware address */
        bl      net_mac

        add     x9, x19, #ETH_HDR               /* recomputed, deliberately */
        LEA     x10, SYM(my_ip)
        ldr     w11, [x10]
        add     x12, x9, #14
        bl      put32

        add     x9, x19, #ETH_HDR               /* the answer goes here, so it */
        add     x12, x9, #18                    /* starts empty */
        mov     w10, #0
3:      cmp     w10, #6
        b.hs    4f
        strb    wzr, [x12, w10, uxtw]
        add     w10, w10, #1
        b       3b
4:      add     x9, x19, #ETH_HDR
        LEA     x10, gw_ip
        ldr     w11, [x10]
        add     x12, x9, #24
        bl      put32

        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/* put32 - w11 into the four bytes at x12, in the order it already has. */
put32:
        lsr     w13, w11, #24
        strb    w13, [x12]
        lsr     w13, w11, #16
        strb    w13, [x12, #1]
        lsr     w13, w11, #8
        strb    w13, [x12, #2]
        strb    w11, [x12, #3]
        ret

/* get32 - four bytes at x0 as one word, in the order they were sent. */
get32:
        ldrb    w9, [x0]
        ldrb    w10, [x0, #1]
        ldrb    w11, [x0, #2]
        ldrb    w12, [x0, #3]
        lsl     w9, w9, #24
        orr     w9, w9, w10, lsl #16
        orr     w9, w9, w11, lsl #8
        orr     w0, w9, w12
        ret

/* get16 - two bytes at x0, big-endian. */
get16:
        ldrb    w9, [x0]
        ldrb    w10, [x0, #1]
        orr     w0, w10, w9, lsl #8
        ret

/*
 * net_take - x0 = a received frame, w1 = its length.
 *
 * Everything that arrives comes through here, because a poll loop that only
 * looked for what it was waiting for would drop the ARP reply it needs and
 * never notice.
 */
        .globl  SYM(net_take)
SYM(net_take):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     x19, x0
        mov     w20, w1
        cmp     w20, #ETH_HDR
        b.ls    .Lnt_out

        add     x0, x19, #12                    /* ethertype */
        bl      get16
        mov     w9, #ETH_ARP
        cmp     w0, w9
        b.eq    .Lnt_arp
        movz    w9, #ETH_IP
        cmp     w0, w9
        b.eq    .Lnt_ip
        b       .Lnt_out

.Lnt_arp:
        add     x9, x19, #ETH_HDR
        add     x0, x9, #6                      /* operation */
        bl      get16
        cmp     w0, #2                          /* a reply */
        b.ne    .Lnt_out
        add     x9, x19, #ETH_HDR
        add     x0, x9, #14                     /* whose address it is */
        bl      get32
        mov     w10, w0
        LEA     x11, arp_ip
        str     w10, [x11]
        LEA     x11, arp_mac
        add     x9, x19, #ETH_HDR
        add     x9, x9, #8
        mov     w12, #0
1:      cmp     w12, #6
        b.hs    2f
        ldrb    w13, [x9, w12, uxtw]
        strb    w13, [x11, w12, uxtw]
        add     w12, w12, #1
        b       1b
2:      LEA     x9, arp_ok
        mov     w10, #1
        str     w10, [x9]
        b       .Lnt_out

.Lnt_ip:
        add     x9, x19, #ETH_HDR
        ldrb    w10, [x9]
        and     w11, w10, #0x0f                 /* header length, in words */
        lsl     w11, w11, #2
        cmp     w11, #20
        b.lo    .Lnt_out
        ldrb    w12, [x9, #9]                   /* protocol */
        cmp     w12, #IP_TCP
        b.ne    .Lnt_out

        mov     w20, w11                        /* the header length, kept
                                                   somewhere a call cannot
                                                   reach - get16 uses x9, and
                                                   x9 is the IP header */
        add     x0, x9, #2                      /* total length */
        bl      get16
        mov     w13, w0
        add     x9, x19, #ETH_HDR               /* recomputed after the call */
        add     x0, x9, w20, uxtw               /* the TCP segment */
        sub     w1, w13, w20
        bl      tcp_take
.Lnt_out:
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

        BSS
        .p2align 2
        .globl  SYM(my_ip)
SYM(my_ip): .space 4
gw_ip:      .space 4
arp_ip:     .space 4
arp_ok:     .space 4
arp_mac:    .space 8
        .p2align 3
txframe:    .space FRAMEBUF
rxframe:    .space FRAMEBUF
