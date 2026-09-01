#include "asm.inc"
/*
 * dns.S - what resolving a name means when there is no resolver.
 *
 * The hosted build's net/dns.S sends a real query over a real UDP socket, and
 * it does so with `socket` and `connect` - syscalls, which is to say requests
 * to an operating system. Here there is no operating system to ask. Linking
 * that file into the kernel would build cleanly and then trap on the first SVC,
 * because this kernel's exception handler now correctly reports "a syscall, and
 * there is no kernel below this one to take it".
 *
 * So bare metal answers the only question it can answer honestly: a dotted quad
 * is an address, and a name is not something this machine can turn into one.
 *
 * That is not a gap to apologise for - it is the reason the browser has two
 * routes. A machine with no resolver asks its backend to fetch the page, which
 * is the same thing every machine here does for https, and the route memory in
 * net/browse.S means it only discovers this once per host. Writing a UDP stack
 * and a resolver to avoid one round trip would be a lot of code in the client
 * to do slightly worse what the backend already does well.
 */

        CODE
        .p2align 2

/*
 * dns_resolve - x0 = a name, out w0 = IPv4 in wire order, or -1.
 *
 * Wire order, not host order: the bytes come out in the order they go on the
 * wire, because that is what every caller here does with them, and converting
 * twice is how an address ends up backwards.
 */
        .globl  SYM(dns_resolve)
SYM(dns_resolve):
        mov     x1, x0
        mov     w2, #0                  /* the address so far */
        mov     w3, #0                  /* how many octets    */

.Ldr_octet:
        mov     w4, #0                  /* this octet */
        mov     w5, #0                  /* digits in it */
1:      ldrb    w6, [x1]
        sub     w7, w6, #'0'
        cmp     w7, #9
        b.hi    2f
        cmp     w5, #3
        b.hs    .Ldr_no                 /* four digits is not an octet */
        mov     w8, #10
        madd    w4, w4, w8, w7
        add     w5, w5, #1
        add     x1, x1, #1
        b       1b
2:      cbz     w5, .Ldr_no             /* an empty octet */
        cmp     w4, #255
        b.hi    .Ldr_no

        /* Wire order: the first octet is the most significant byte on the
           wire, which is the lowest byte in the little-endian word we build. */
        lsl     w7, w4, #0
        lsl     w8, w3, #3
        lsl     w7, w7, w8
        orr     w2, w2, w7
        add     w3, w3, #1

        ldrb    w6, [x1]
        cmp     w6, #'.'
        b.ne    3f
        cmp     w3, #4
        b.hs    .Ldr_no                 /* five parts */
        add     x1, x1, #1
        b       .Ldr_octet
3:      cbnz    w6, .Ldr_no             /* trailing rubbish */
        cmp     w3, #4
        b.ne    .Ldr_no
        mov     w0, w2
        ret

.Ldr_no:
        mov     w0, #-1
        ret
