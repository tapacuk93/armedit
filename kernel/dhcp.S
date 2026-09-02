#include "asm.inc"
/*
 * dhcp.S - asking for an address instead of assuming one.
 *
 * The kernel knew its own address by being told it at compile time: 10.0.2.15,
 * with 10.0.2.2 for the gateway. Those are QEMU's user-mode network's fixed,
 * documented addresses, and on the one machine this kernel ran on they were
 * correct. They are correct nowhere else. A board on a real network - a USB
 * Ethernet adapter on bare metal, or a radio when there is one - has no
 * address until it asks for one, and a machine that assumes 10.0.2.15 on such
 * a network is a machine that cannot be reached and does not know it.
 *
 * <h2>Why this is the reachable half of "wifi"</h2>
 *
 * Joining a wireless network is two problems that get spoken of as one. The
 * radio - association, WPA, firmware - is silicon-specific, undocumented on
 * this hardware, and cannot be emulated to test against. Everything after the
 * link comes up is not: it is DHCP, and it is identical on wired and wireless,
 * and QEMU's user networking runs a DHCP server, so it can be written and
 * proved here rather than guessed at and discovered on hardware.
 *
 * <h2>Four packets</h2>
 *
 *   DISCOVER  broadcast, because we have no address and do not know the server
 *   OFFER     a server proposes one
 *   REQUEST   broadcast again, naming the offer and the server it came from
 *   ACK       that server confirms it
 *
 * The second broadcast is not redundant. More than one server may offer, and
 * the request is broadcast so the ones whose offer was not taken hear it and
 * release what they had reserved. On a network with one server it changes
 * nothing; on a network with two, sending it only to the chosen server leaks
 * an address from the other every time a machine boots.
 *
 * <h2>Built and read a byte at a time</h2>
 *
 * The MMU is off, so all memory is Device type and any load wider than its
 * alignment is a fault rather than a slow access. A DHCP packet has a
 * four-byte address at offset 16 of a payload that begins 42 bytes into a
 * frame, so almost nothing in it is aligned to its own width. Reading it
 * byte-wise is not caution here, it is the only thing that works.
 */

#define ETH_HDR         14
#define IP_HDR          20
#define UDP_HDR         8
#define DHCP_AT         (ETH_HDR + IP_HDR + UDP_HDR)

/* Within the DHCP payload. */
#define D_OP            0
#define D_HTYPE         1
#define D_HLEN          2
#define D_XID           4
#define D_FLAGS         10
#define D_YIADDR        16
#define D_CHADDR        28
#define D_COOKIE        236
#define D_OPTIONS       240

#define DHCP_DISCOVER   1
#define DHCP_OFFER      2
#define DHCP_REQUEST    3
#define DHCP_ACK        5

#define OPT_MASK        1
#define OPT_ROUTER      3
#define OPT_DNS         6
#define OPT_REQUESTED   50
#define OPT_TYPE        53
#define OPT_SERVER      54
#define OPT_PARAMS      55
#define OPT_END         255

#define FRAME_LEN       (DHCP_AT + D_OPTIONS + 24)
#define RX_MAX          1600

        CODE
        .p2align 2

/*
 * dhcp_configure - out w0 = 0 if this machine now has an address, -1 if not.
 *
 * On success the address and gateway are handed to ip_configure, which is the
 * same call the hard-coded pair used to make - everything above the network
 * layer is unchanged and does not know which way the numbers arrived.
 *
 * Failure is not fatal to anything. A machine that cannot get a lease has no
 * network, which is a state this editor already handles: the built-in
 * operations answer and the backend is unreachable. Saying so beats stopping.
 */
        .globl  SYM(dhcp_configure)
SYM(dhcp_configure):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        str     x23, [sp, #48]

/*
 * A transaction id that is different every boot. The server matches replies to
 * requests by it, and two machines booting from the same image with the same
 * id would each accept the other's lease.
 */
        mrs     x9, cntvct_el0
        LEA     x10, dh_xid
        str     w9, [x10]

        LEA     x9, dh_yi               /* nothing offered yet */
        str     wzr, [x9]
        LEA     x9, dh_server
        str     wzr, [x9]
        LEA     x9, dh_router
        str     wzr, [x9]
        LEA     x9, SYM(dhcp_dns)
        str     wzr, [x9]

        mov     w19, #0                 /* how many times we have asked */
.Ldh_discover:
        cmp     w19, #4
        b.hs    .Ldh_fail
        add     w19, w19, #1

        mov     w0, #DHCP_DISCOVER
        bl      dh_build
        LEA     x0, dh_tx
        mov     w1, #FRAME_LEN
        bl      net_send

        mov     w0, #DHCP_OFFER
        bl      dh_await
        cmn     w0, #1
        b.eq    .Ldh_discover

/*
 * An offer with no address in it is not an offer. Checking beats trusting a
 * well-formed packet: the field is where the reply says the address is, and
 * accepting a zero would configure this machine as 0.0.0.0 and report success.
 */
        LEA     x9, dh_yi
        ldr     w20, [x9]
        cbz     w20, .Ldh_discover

        mov     w21, #0
.Ldh_request:
        cmp     w21, #4
        b.hs    .Ldh_discover           /* the offer went stale; start again */
        add     w21, w21, #1

        mov     w0, #DHCP_REQUEST
        bl      dh_build
        LEA     x0, dh_tx
        mov     w1, #FRAME_LEN
        bl      net_send

        mov     w0, #DHCP_ACK
        bl      dh_await
        cmn     w0, #1
        b.eq    .Ldh_request

        LEA     x9, dh_yi
        ldr     w0, [x9]
        cbz     w0, .Ldh_fail
        LEA     x9, dh_router
        ldr     w1, [x9]
        bl      SYM(ip_configure)
        mov     w0, #0
        b       .Ldh_out
.Ldh_fail:
        mov     w0, #-1
.Ldh_out:
        ldr     x23, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * dh_await - w0 = the message type wanted. out w0 = 0 if it came, -1 if not.
 *
 * Frames that are not the reply are handed to net_take rather than dropped.
 * This runs before anything else uses the network, so almost nothing else
 * arrives - but an ARP request from the gateway does, and a machine that
 * ignored it would be unreachable afterwards for a reason that had nothing to
 * do with DHCP.
 */
dh_await:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]
        mov     w19, w0
        mov     w20, #0
1:      cmp     w20, #0x200000
        b.hs    9f
        add     w20, w20, #1
        LEA     x0, dh_rx
        mov     w1, #RX_MAX
        bl      net_recv
        cmn     w0, #1
        b.eq    1b
        mov     w21, w0

        LEA     x0, dh_rx
        mov     w1, w21
        bl      dh_parse
        cmp     w0, w19
        b.eq    8f
        /* Somebody else's frame. Let the stack have it and keep waiting. */
        LEA     x0, dh_rx
        mov     w1, w21
        bl      SYM(net_take)
        b       1b
8:      mov     w0, #0
        b       10f
9:      mov     w0, #-1
10:     ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * dh_parse - x0 = a frame, w1 = its length. out w0 = its DHCP type, or -1.
 *
 * Everything is checked before it is used, because this is the one part of the
 * kernel that reads bytes chosen by whoever else is on the network. A frame
 * that is too short, is not IP, is not UDP, is not for port 68, or does not
 * carry the magic cookie is not a DHCP reply, and each of those is a way for a
 * shorter packet to have its later fields read out of whatever follows it.
 */
dh_parse:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        str     x23, [sp, #48]
        mov     x19, x0
        mov     w20, w1

        mov     w9, #(DHCP_AT + D_OPTIONS)
        cmp     w20, w9
        b.lo    9f

        add     x0, x19, #12            /* ethertype */
        bl      dh_get16
        movz    w9, #0x0800
        cmp     w0, w9
        b.ne    9f

        ldrb    w9, [x19, #(ETH_HDR + 9)]       /* protocol */
        cmp     w9, #17                         /* UDP */
        b.ne    9f

        add     x0, x19, #(ETH_HDR + IP_HDR + 2)  /* destination port */
        bl      dh_get16
        cmp     w0, #68
        b.ne    9f

        add     x21, x19, #DHCP_AT
        add     x0, x21, #D_COOKIE
        bl      dh_get32
        movz    w9, #0x6382, lsl #16
        movk    w9, #0x5363
        cmp     w0, w9
        b.ne    9f

/*
 * Ours, or somebody else's. The id is written to the wire most significant
 * byte first and read back the same way, so what comes out of dh_get32 is the
 * value that went in and comparing it needs no swap - a swap here rejected
 * every reply, including the correct ones the server was sending back within
 * a millisecond.
 */
        add     x0, x21, #D_XID
        bl      dh_get32
        LEA     x9, dh_xid
        ldr     w9, [x9]
        cmp     w0, w9
        b.ne    9f

/*
 * It is a reply to us. Take the address it offers and walk the options.
 */
        add     x0, x21, #D_YIADDR
        bl      dh_get32
        rev     w0, w0                          /* keep addresses in wire order */
        LEA     x9, dh_yi
        str     w0, [x9]

        mov     w22, #-1                        /* the message type, if it says */
        add     x23, x21, #D_OPTIONS
        add     x10, x19, w20, uxtw             /* one past the frame */
2:      cmp     x23, x10
        b.hs    8f
        ldrb    w9, [x23]
        cmp     w9, #OPT_END
        b.eq    8f
        cmp     w9, #0                          /* padding */
        b.eq    3f
        add     x11, x23, #1
        cmp     x11, x10
        b.hs    8f
        ldrb    w12, [x23, #1]                  /* its length */
        add     x11, x23, #2
        add     x11, x11, w12, uxtw
        cmp     x11, x10                        /* does it fit in the frame? */
        b.hi    8f
        add     x13, x23, #2                    /* its bytes */

        cmp     w9, #OPT_TYPE
        b.ne    4f
        ldrb    w22, [x13]
        b       5f
4:      cmp     w9, #OPT_SERVER
        b.ne    6f
        mov     x0, x13
        bl      dh_get32
        rev     w0, w0
        LEA     x14, dh_server
        str     w0, [x14]
        b       5f
6:      cmp     w9, #OPT_ROUTER
        b.ne    7f
        mov     x0, x13
        bl      dh_get32
        rev     w0, w0
        LEA     x14, dh_router
        str     w0, [x14]
        b       5f
7:      cmp     w9, #OPT_DNS
        b.ne    5f
        mov     x0, x13
        bl      dh_get32
        rev     w0, w0
        LEA     x14, SYM(dhcp_dns)
        str     w0, [x14]
5:      ldrb    w12, [x23, #1]
        add     x23, x23, #2
        add     x23, x23, w12, uxtw
        b       2b
3:      add     x23, x23, #1
        b       2b

8:      mov     w0, w22
        b       10f
9:      mov     w0, #-1
10:     ldr     x23, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * dh_build - w0 = the message type. Fills dh_tx with a complete frame.
 *
 * Everything is broadcast and everything comes from 0.0.0.0, including the
 * request. That is not laziness about the second exchange: until the ACK
 * arrives the address is not this machine's, and sending from it would be
 * claiming an address a server has only offered.
 */
dh_build:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]
        mov     w19, w0

        LEA     x0, dh_tx
        mov     w1, #FRAME_LEN
        bl      dh_zero

        LEA     x20, dh_tx
        mov     w9, #0xFF                       /* to everybody */
        mov     w10, #0
1:      cmp     w10, #6
        b.hs    2f
        strb    w9, [x20, w10, uxtw]
        add     w10, w10, #1
        b       1b
2:      add     x0, x20, #6                     /* from us */
        bl      net_mac
        add     x0, x20, #12
        movz    w1, #0x0800
        bl      dh_put16

/* The IP header, with its length and checksum filled in at the end. */
        add     x21, x20, #ETH_HDR
        mov     w9, #0x45
        strb    w9, [x21]
        add     x0, x21, #2
        mov     w1, #(FRAME_LEN - ETH_HDR)
        bl      dh_put16
        mov     w9, #64
        strb    w9, [x21, #8]                   /* time to live */
        mov     w9, #17
        strb    w9, [x21, #9]                   /* UDP */
        add     x0, x21, #16                    /* to 255.255.255.255 */
        mov     w1, #-1
        bl      dh_put32
        mov     x0, x21
        mov     w1, #IP_HDR
        mov     w2, #0
        bl      SYM(ip_sum)
        bl      SYM(ip_fold)
        add     x1, x21, #10
        mov     w2, w0
        mov     x0, x1
        mov     w1, w2
        bl      dh_put16

/*
 * The UDP header. Its checksum is left at zero, which IPv4 permits and which
 * says "not computed" rather than "computed as zero" - the one value that
 * cannot be a real checksum is reserved for exactly this.
 */
        add     x0, x21, #IP_HDR
        mov     w1, #68
        bl      dh_put16
        add     x0, x21, #(IP_HDR + 2)
        mov     w1, #67
        bl      dh_put16
        add     x0, x21, #(IP_HDR + 4)
        mov     w1, #(FRAME_LEN - ETH_HDR - IP_HDR)
        bl      dh_put16

        add     x21, x20, #DHCP_AT
        mov     w9, #1
        strb    w9, [x21, #D_OP]                /* a request */
        strb    w9, [x21, #D_HTYPE]             /* over Ethernet */
        mov     w9, #6
        strb    w9, [x21, #D_HLEN]
        LEA     x9, dh_xid
        ldr     w1, [x9]
        add     x0, x21, #D_XID
        bl      dh_put32
        add     x0, x21, #D_FLAGS               /* answer by broadcast: we have */
        movz    w1, #0x8000                     /* no address to answer to yet */
        bl      dh_put16
        add     x0, x21, #D_CHADDR
        bl      net_mac
        add     x0, x21, #D_COOKIE
        movz    w1, #0x6382, lsl #16
        movk    w1, #0x5363
        bl      dh_put32

        add     x21, x21, #D_OPTIONS
        mov     w9, #OPT_TYPE
        strb    w9, [x21]
        mov     w9, #1
        strb    w9, [x21, #1]
        strb    w19, [x21, #2]
        add     x21, x21, #3

        cmp     w19, #DHCP_REQUEST
        b.ne    3f
        mov     w9, #OPT_REQUESTED              /* the address we were offered */
        strb    w9, [x21]
        mov     w9, #4
        strb    w9, [x21, #1]
        LEA     x9, dh_yi
        ldr     w1, [x9]
        rev     w1, w1
        add     x0, x21, #2
        bl      dh_put32
        add     x21, x21, #6
        mov     w9, #OPT_SERVER                 /* and whose offer it was */
        strb    w9, [x21]
        mov     w9, #4
        strb    w9, [x21, #1]
        LEA     x9, dh_server
        ldr     w1, [x9]
        rev     w1, w1
        add     x0, x21, #2
        bl      dh_put32
        add     x21, x21, #6

3:      mov     w9, #OPT_PARAMS                 /* what we would like told */
        strb    w9, [x21]
        mov     w9, #3
        strb    w9, [x21, #1]
        mov     w9, #OPT_MASK
        strb    w9, [x21, #2]
        mov     w9, #OPT_ROUTER
        strb    w9, [x21, #3]
        mov     w9, #OPT_DNS
        strb    w9, [x21, #4]
        add     x21, x21, #5
        mov     w9, #OPT_END
        strb    w9, [x21]

        ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* Byte at a time, both ways, for the reason at the top of this file. */
dh_put16:
        lsr     w9, w1, #8
        strb    w9, [x0]
        strb    w1, [x0, #1]
        ret

dh_put32:
        lsr     w9, w1, #24
        strb    w9, [x0]
        lsr     w9, w1, #16
        strb    w9, [x0, #1]
        lsr     w9, w1, #8
        strb    w9, [x0, #2]
        strb    w1, [x0, #3]
        ret

dh_get16:
        ldrb    w9, [x0]
        ldrb    w10, [x0, #1]
        orr     w0, w10, w9, lsl #8
        ret

dh_get32:
        ldrb    w9, [x0]
        ldrb    w10, [x0, #1]
        ldrb    w11, [x0, #2]
        ldrb    w12, [x0, #3]
        lsl     w9, w9, #24
        orr     w9, w9, w10, lsl #16
        orr     w9, w9, w11, lsl #8
        orr     w0, w9, w12
        ret

dh_zero:
        mov     w9, #0
1:      cmp     w9, w1
        b.hs    2f
        strb    wzr, [x0, w9, uxtw]
        add     w9, w9, #1
        b       1b
2:      ret

        BSS
        .p2align 3
        .globl  SYM(dhcp_dns)
SYM(dhcp_dns): .space 4                 /* what it told us to resolve with */
dh_xid:        .space 4
dh_yi:         .space 4                 /* the address offered, in wire order */
dh_server:     .space 4
dh_router:     .space 4
        .p2align 3
dh_tx:         .space FRAME_LEN
        .p2align 3
dh_rx:         .space RX_MAX
