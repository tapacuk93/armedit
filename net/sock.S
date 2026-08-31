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
