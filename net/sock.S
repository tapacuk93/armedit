#include "asm.inc"
/*
 * sock.S - the hosted half of the seam net/http.S sits on.
 *
 * Four calls: open a connection, write, read, close. Under an operating system
 * they are BSD sockets reached through raw syscalls; on bare metal the kernel
 * supplies the same four names over its own TCP. Everything above them - the
 * request text, the header parsing - is written once.
 *
 * Darwin reports syscall failure by setting the carry flag, which is what
 * every b.cs below is testing.
 */
#define SYS_READ        3
#define SYS_WRITE       4
#define SYS_CLOSE       6
#define SYS_SOCKET      97
#define SYS_CONNECT     98
#define SYS_SETSOCKOPT  105
#define SOL_SOCKET      0xFFFF
#define SO_RCVTIMEO     0x1006
#define SO_SNDTIMEO     0x1005
#define READ_SECONDS    20
#define AF_INET         2
#define SOCK_STREAM     1

        CODE
        .p2align 2

/* sock_open - w0 = address (network order), w1 = port (host order).
   out w0 = a handle, or -1. */
        .globl  SYM(sock_open)
SYM(sock_open):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     w19, w0
        mov     w20, w1

        mov     x0, #AF_INET
        mov     x1, #SOCK_STREAM
        mov     x2, #0
        mov     x16, #SYS_SOCKET
        svc     #0x80
        b.cs    1f
        mov     w9, w0

        LEA     x10, sockaddr
        mov     w11, #16
        strb    w11, [x10]              /* sin_len    */
        mov     w11, #AF_INET
        strb    w11, [x10, #1]          /* sin_family */
        rev16   w11, w20                /* the port goes big-endian */
        strh    w11, [x10, #2]
        str     w19, [x10, #4]
        str     xzr, [x10, #8]

        mov     w19, w9                 /* the handle, across the call */
        mov     w0, w9
        mov     x1, x10
        mov     x2, #16
        mov     x16, #SYS_CONNECT
        svc     #0x80
        b.cs    2f

/*
 * A read that can wait forever is a program that can stop forever.
 *
 * Every read here is on a socket to somebody else's machine, and "somebody
 * else's machine stops answering without closing the connection" is not an
 * unusual event - it is what a dropped route, a stalled proxy or an overloaded
 * server looks like from this side. Without a timeout the editor waits on it
 * with no caret, no key handling and no way out, which is a hang that looks
 * exactly like a crash.
 *
 * Twenty seconds is long enough that a slow page still arrives and short
 * enough that a dead one gives up while somebody is still watching. Failing to
 * set it is not fatal: the socket still works, it just works the old way, and
 * refusing to connect over it would trade a rare hang for a common failure.
 */
        LEA     x10, rcvtimeo
        mov     x11, #READ_SECONDS
        str     x11, [x10]
        str     wzr, [x10, #8]
        mov     w0, w19
        mov     x1, #SOL_SOCKET
        mov     x2, #SO_RCVTIMEO
        LEA     x3, rcvtimeo
        mov     x4, #16
        mov     x16, #SYS_SETSOCKOPT
        svc     #0x80

        LEA     x10, rcvtimeo
        mov     x11, #READ_SECONDS
        str     x11, [x10]
        str     wzr, [x10, #8]
        mov     w0, w19
        mov     x1, #SOL_SOCKET
        mov     x2, #SO_SNDTIMEO
        LEA     x3, rcvtimeo
        mov     x4, #16
        mov     x16, #SYS_SETSOCKOPT
        svc     #0x80

        mov     w0, w19
        b       9f
2:      mov     w0, w19                 /* connected to nothing: let it go */
        mov     x16, #SYS_CLOSE
        svc     #0x80
1:      mov     w0, #-1
9:      ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* sock_write - w0 = handle, x1 = bytes, w2 = count.  out w0 = written, or -1 */
        .globl  SYM(sock_write)
SYM(sock_write):
        mov     x16, #SYS_WRITE
        svc     #0x80
        b.cs    1f
        ret
1:      mov     w0, #-1
        ret

/* sock_read - w0 = handle, x1 = where, w2 = room.  out w0 = read, 0 at end */
        .globl  SYM(sock_read)
SYM(sock_read):
        mov     x16, #SYS_READ
        svc     #0x80
        b.cs    1f
        ret
1:      mov     w0, #0
        ret

/* sock_close - w0 = handle */
        .globl  SYM(sock_close)
SYM(sock_close):
        mov     x16, #SYS_CLOSE
        svc     #0x80
        ret

        BSS
        .p2align 3
sockaddr:   .space 16
rcvtimeo:   .space 16
