#include "asm.inc"
/*
 * dns.S - turning a name into an address, without a resolver library.
 *
 * armedit needs this the moment it can open a site at all: net_parse_addr
 * understands "93.184.216.34:80" and nothing else, and nobody types that.
 * So here is the smallest thing that answers "what address is this name" -
 * one A-record query over UDP, one answer parsed.
 *
 * What it deliberately is not: a resolver. There is no cache beyond the last
 * answer, no retry across multiple servers, no CNAME chasing beyond what a
 * server puts in the same reply, no TCP fallback for long answers, no DNSSEC.
 * Each of those is a real thing a real resolver does, and each would be
 * pretending: a text editor that fetches the occasional page needs an address,
 * and the operating system it usually runs on has a resolver already.
 *
 * The reply is parsed defensively for one reason. This is a UDP packet from a
 * machine on the network, which means the bytes are chosen by somebody else,
 * and a name in DNS wire format is a linked list with a compression scheme -
 * pointers that can point backwards, and in a hostile packet, at each other.
 * So every walk here is bounded by a step count as well as by the packet end,
 * and a malformed reply is abandoned rather than followed.
 */
#define SYS_READ        3
#define SYS_WRITE       4
#define SYS_CLOSE       6
#define SYS_OPEN        5
#define SYS_SOCKET      97
#define SYS_CONNECT     98
#define AF_INET         2
#define SOCK_DGRAM      2

#define DNS_PORT        53
#define PKT_MAX         512     /* a UDP DNS message, before EDNS */
#define HOPS_MAX        64      /* compression pointers we will follow */

        CODE
        .p2align 2

/*
 * dns_resolve - x0 = a hostname, out w0 = IPv4 in network byte order, or -1.
 *
 * A name that is already a dotted quad comes straight back, so callers do not
 * have to know which kind of thing they were handed.
 */
        .globl  SYM(dns_resolve)
SYM(dns_resolve):
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        mov     x19, x0

        mov     x0, x19                 /* "1.2.3.4" is already an answer */
        bl      dns_literal
        cmn     w0, #1
        b.ne    .Ldr_out

        bl      dns_server              /* who to ask */
        mov     w20, w0
        cmn     w20, #1
        b.eq    .Ldr_fail

/* ---- the query -------------------------------------------------------- */
        LEA     x21, qbuf
        mov     w9, #0x2A               /* an id; we only have one in flight, */
        strb    w9, [x21]               /* so it is a token, not a nonce */
        mov     w9, #0x7B
        strb    w9, [x21, #1]
        mov     w9, #0x01               /* recursion desired */
        strb    w9, [x21, #2]
        strb    wzr, [x21, #3]
        strb    wzr, [x21, #4]          /* one question */
        mov     w9, #1
        strb    w9, [x21, #5]
        strb    wzr, [x21, #6]
        strb    wzr, [x21, #7]
        strb    wzr, [x21, #8]
        strb    wzr, [x21, #9]
        strb    wzr, [x21, #10]
        strb    wzr, [x21, #11]

        add     x22, x21, #12           /* the name, as length-prefixed labels */
        mov     w23, #0                 /* where this label's length goes */
        mov     w24, #1                 /* where the next byte goes */
        strb    wzr, [x22]
1:      ldrb    w9, [x19], #1
        cbz     w9, 2f
        cmp     w24, #250
        b.hs    .Ldr_fail               /* a name too long to ask about */
        cmp     w9, #'.'
        b.ne    3f
        sub     w10, w24, w23           /* close the label off */
        sub     w10, w10, #1
        strb    w10, [x22, w23, uxtw]
        mov     w23, w24
        strb    wzr, [x22, w23, uxtw]
        add     w24, w24, #1
        b       1b
3:      strb    w9, [x22, w24, uxtw]
        add     w24, w24, #1
        b       1b
2:      sub     w10, w24, w23
        sub     w10, w10, #1
        cbz     w10, .Ldr_fail          /* a trailing dot, or nothing at all */
        strb    w10, [x22, w23, uxtw]
        strb    wzr, [x22, w24, uxtw]   /* the root label ends the name */
        add     w24, w24, #1

        mov     w9, #0                  /* QTYPE A, QCLASS IN */
        strb    w9, [x22, w24, uxtw]
        add     w24, w24, #1
        mov     w9, #1
        strb    w9, [x22, w24, uxtw]
        add     w24, w24, #1
        mov     w9, #0
        strb    w9, [x22, w24, uxtw]
        add     w24, w24, #1
        mov     w9, #1
        strb    w9, [x22, w24, uxtw]
        add     w24, w24, #1
        add     w24, w24, #12           /* the header we wrote first */

/* ---- ask -------------------------------------------------------------- */
        mov     x0, #AF_INET
        mov     x1, #SOCK_DGRAM
        mov     x2, #0
        mov     x16, #SYS_SOCKET
        svc     #0x80
        b.cs    .Ldr_fail
        mov     w21, w0                 /* the socket */

        LEA     x9, sabuf               /* struct sockaddr_in */
        mov     w10, #16
        strb    w10, [x9]
        mov     w10, #AF_INET
        strb    w10, [x9, #1]
        mov     w10, #DNS_PORT          /* network byte order, by hand */
        lsr     w11, w10, #8
        strb    w11, [x9, #2]
        strb    w10, [x9, #3]
        str     w20, [x9, #4]
        str     xzr, [x9, #8]

        mov     x0, x21
        mov     x1, x9
        mov     x2, #16
        mov     x16, #SYS_CONNECT
        svc     #0x80
        b.cs    .Ldr_close

        mov     x0, x21
        LEA     x1, qbuf
        mov     w2, w24
        mov     x16, #SYS_WRITE
        svc     #0x80
        b.cs    .Ldr_close

        mov     x0, x21
        LEA     x1, abuf
        mov     x2, #PKT_MAX
        mov     x16, #SYS_READ
        svc     #0x80
        b.cs    .Ldr_close
        mov     w22, w0                 /* how much came back */
        cmp     w22, #12
        b.lt    .Ldr_close

        mov     x0, x21
        mov     x16, #SYS_CLOSE
        svc     #0x80

        LEA     x0, abuf
        mov     w1, w22
        bl      dns_answer
        b       .Ldr_out

.Ldr_close:
        mov     x0, x21
        mov     x16, #SYS_CLOSE
        svc     #0x80
.Ldr_fail:
        mov     w0, #-1
.Ldr_out:
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

/*
 * dns_answer - x0 = the reply, w1 = its length.
 *   out w0 = the first A record's address, or -1.
 *
 * Everything here is bounded by the packet, because everything here was
 * written by somebody else.
 */
dns_answer:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0
        mov     w20, w1

        ldrb    w9, [x19, #3]           /* RCODE 0, or there is no answer */
        and     w9, w9, #0x0f
        cbnz    w9, .Lda_fail
        ldrb    w9, [x19, #6]           /* how many answers */
        ldrb    w10, [x19, #7]
        orr     w21, w10, w9, lsl #8
        cbz     w21, .Lda_fail

        ldrb    w9, [x19, #4]           /* skip the questions we asked */
        ldrb    w10, [x19, #5]
        orr     w22, w10, w9, lsl #8
        mov     w9, #12                 /* cursor */
1:      cbz     w22, 2f
        mov     w0, w9
        bl      dns_skip_name
        cmn     w0, #1
        b.eq    .Lda_fail
        add     w9, w0, #4              /* QTYPE and QCLASS */
        cmp     w9, w20
        b.hi    .Lda_fail
        sub     w22, w22, #1
        b       1b

2:      cbz     w21, .Lda_fail          /* each answer, until an A record */
        mov     w0, w9
        bl      dns_skip_name
        cmn     w0, #1
        b.eq    .Lda_fail
        mov     w9, w0
        add     w10, w9, #10            /* type, class, ttl, rdlength */
        cmp     w10, w20
        b.hi    .Lda_fail
        ldrb    w11, [x19, w9, uxtw]    /* TYPE */
        add     w12, w9, #1
        ldrb    w12, [x19, w12, uxtw]
        orr     w11, w12, w11, lsl #8
        add     w12, w9, #8             /* RDLENGTH */
        ldrb    w13, [x19, w12, uxtw]
        add     w12, w12, #1
        ldrb    w12, [x19, w12, uxtw]
        orr     w13, w12, w13, lsl #8
        add     w9, w9, #10             /* now at RDATA */
        add     w12, w9, w13
        cmp     w12, w20
        b.hi    .Lda_fail

        cmp     w11, #1                 /* A? */
        b.ne    3f
        cmp     w13, #4
        b.ne    3f
        ldrb    w0, [x19, w9, uxtw]     /* four bytes, network order */
        add     w10, w9, #1
        ldrb    w10, [x19, w10, uxtw]
        add     w11, w9, #2
        ldrb    w11, [x19, w11, uxtw]
        add     w12, w9, #3
        ldrb    w12, [x19, w12, uxtw]
        orr     w0, w0, w10, lsl #8
        orr     w0, w0, w11, lsl #16
        orr     w0, w0, w12, lsl #24
        b       .Lda_out
3:      mov     w9, w12                 /* not an A record: on to the next */
        sub     w21, w21, #1
        b       2b

.Lda_fail:
        mov     w0, #-1
.Lda_out:
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * dns_skip_name - w0 = offset of a name, out w0 = offset just past it, or -1.
 *
 * x19 is the packet and w20 its length, by arrangement with dns_answer.
 * A name is a chain of labels ending either in a zero byte or in a pointer to
 * somewhere earlier in the packet. The pointer is why this counts steps: a
 * packet is free to say that a name points at itself, and following that is a
 * hang rather than a crash, which is worse.
 */
dns_skip_name:
        mov     w9, w0
        mov     w10, #0                 /* labels stepped over */
1:      add     w10, w10, #1
        cmp     w10, #HOPS_MAX
        b.hi    9f
        cmp     w9, w20
        b.hs    9f
        ldrb    w11, [x19, w9, uxtw]
        cbz     w11, 2f
        and     w12, w11, #0xc0
        cmp     w12, #0xc0
        b.eq    3f                      /* a pointer: the name ends here */
        cmp     w11, #63
        b.hi    9f
        add     w9, w9, w11
        add     w9, w9, #1
        b       1b
2:      add     w0, w9, #1              /* the root label */
        ret
3:      add     w0, w9, #2              /* two bytes, and the name is done */
        cmp     w0, w20
        b.hi    9f
        ret
9:      mov     w0, #-1
        ret

/*
 * dns_literal - x0 = a string, out w0 = the address it spells, or -1.
 * Four decimal octets and three dots, and nothing else.
 */
dns_literal:
        mov     x9, x0
        mov     w1, #0                  /* the address being built */
        mov     w2, #0                  /* octets seen */
1:      mov     w3, #0                  /* this octet */
        mov     w4, #0                  /* digits in it */
2:      ldrb    w5, [x9]
        sub     w6, w5, #'0'
        cmp     w6, #9
        b.hi    3f
        mov     w7, #10
        mul     w3, w3, w7
        add     w3, w3, w6
        cmp     w3, #255
        b.hi    9f
        add     w4, w4, #1
        add     x9, x9, #1
        b       2b
3:      cbz     w4, 9f                  /* a dot with no digits before it */
        lsl     w1, w1, #8
        orr     w1, w1, w3
        add     w2, w2, #1
        cmp     w2, #4
        b.eq    4f
        cmp     w5, #'.'                /* more to come: it must be a dot */
        b.ne    9f
        add     x9, x9, #1
        b       1b

/*
 * Four octets. What may follow depends on where the string came from: the end
 * of a hostname, or the end of a word in a config file. So whitespace and a
 * comment both end it, and anything else - a fifth dot, a letter - means this
 * was never an address. Accepting a trailing dot here would make
 * "1.2.3.4.example.com" resolve to 1.2.3.4, which is a name, not an address.
 */
4:      cbz     w5, 5f
        cmp     w5, #' '
        b.ls    5f                      /* space, tab, CR, LF */
        cmp     w5, #'#'
        b.ne    9f
5:      rev     w0, w1                  /* host order to network order */
        ret
9:      mov     w0, #-1
        ret

/*
 * dns_server - out w0 = the resolver to ask, network byte order, or -1.
 *
 * ARMEDIT_DNS first, so this is always overridable. Then the first IPv4
 * nameserver in /etc/resolv.conf, which is the machine's own answer to this
 * question and the only one that is right on a private network.
 *
 * There is no public fallback on purpose. Quietly sending somebody's browsing
 * to a resolver they did not choose is not a default worth having, and a
 * machine with no resolver configured is better off saying so - the proxy path
 * still works, and it is the one that was going to be used anyway.
 */
dns_server:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]

        LEA     x0, s_env_dns
        bl      SYM(env_get)
        cbz     x0, 1f
        bl      dns_literal
        cmn     w0, #1
        b.ne    .Lds_out
1:
        LEA     x0, s_env_resolv        /* where to look, for a build that */
        bl      SYM(env_get)            /* keeps its config somewhere else */
        cbnz    x0, 6f
        LEA     x0, s_resolv
6:      mov     x1, #0
        mov     x2, #0
        mov     x16, #SYS_OPEN
        svc     #0x80
        b.cs    .Lds_fail
        mov     x19, x0
        LEA     x1, rcbuf
        mov     x2, #1023
        mov     x0, x19
        mov     x16, #SYS_READ
        svc     #0x80
        mov     w20, w0
        mov     x0, x19
        mov     x16, #SYS_CLOSE
        svc     #0x80
        cmp     w20, #1
        b.lt    .Lds_fail
        LEA     x19, rcbuf
        strb    wzr, [x19, w20, uxtw]

2:      mov     x0, x19                 /* each "nameserver <addr>" line */
        LEA     x1, s_nameserver
        bl      SYM(str_starts)
        cbz     w0, 4f
        add     x21, x19, #11
3:      ldrb    w9, [x21]
        cmp     w9, #' '
        b.ne    5f
        add     x21, x21, #1
        b       3b
5:      mov     x0, x21                 /* an IPv6 entry will simply not parse */
        bl      dns_literal
        cmn     w0, #1
        b.ne    .Lds_out
4:      ldrb    w9, [x19]
        cbz     w9, .Lds_fail
        add     x19, x19, #1
        cmp     w9, #'\n'
        b.ne    4b
        b       2b

.Lds_fail:
        mov     w0, #-1
.Lds_out:
        ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

        CSTR
s_env_dns:      .asciz "ARMEDIT_DNS"
s_resolv:       .asciz "/etc/resolv.conf"
s_env_resolv:   .asciz "ARMEDIT_RESOLV"
s_nameserver:   .asciz "nameserver "

        BSS
        .p2align 3
qbuf:   .space PKT_MAX
abuf:   .space PKT_MAX
sabuf:  .space 16
rcbuf:  .space 1024
