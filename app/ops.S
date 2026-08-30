#include "asm.inc"
/*
 * ops.S - running code the backend sent.
 *
 * The caching went: the model answers, then the server answers from what the
 * model taught it, then - here - nobody answers, because the device was handed
 * the operation itself as machine code and runs it.
 *
 * What arrives is aarch64 with no relocations in it: literals are reached with
 * ADR and the only calls out are indirect through the helper table below, so
 * installing a blob is a copy into executable memory and nothing else. No
 * loader, no symbol table, no patching.
 *
 * <b>The device is executing code the server sent it.</b> Two properties bound
 * what a buggy generator can do, and neither makes a hostile server safe:
 *
 * The blob has no way to name memory it was not handed - no absolute addresses
 * exist in it. And it cannot overflow the output, because it never copies
 * anything itself; every byte goes through op_append below, which is bounded,
 * and which is code that was here before any download. The safety lives in the
 * half nobody downloaded.
 *
 * What makes the rest defensible is whose server it is. This is the user's own
 * backend, reached with the one key that already holds their cloud
 * credentials. A server that wanted to harm this device has had easier ways
 * all along. That is an argument about trust, not a technical guarantee, and
 * it is the honest one.
 */
#define SYS_MMAP        197
#define SYS_MPROTECT    74
#define SYS_MUNMAP      73

#define PROT_READ       1
#define PROT_WRITE      2
#define PROT_EXEC       4
#define MAP_PRIVATE     0x0002
#define MAP_ANON        0x1000

#define OPS_MAX         16
#define OP_NAME_MAX     32

        CODE
        .p2align 2

/*
 * op_append - x0 = cursor, x1 = source, x2 = one past the last writable byte.
 *   out x0 = the new cursor.
 *
 * The one thing generated code is allowed to write with, which is why the
 * bound is checked here rather than trusted there. A source that would not fit
 * is truncated, not refused: half an answer on screen is a bug somebody can
 * see, and a smashed heap is not.
 */
        .globl  SYM(op_append)
SYM(op_append):
        cbz     x1, 9f
1:      cmp     x0, x2
        b.hs    9f
        ldrb    w3, [x1], #1
        cbz     w3, 9f
        strb    w3, [x0], #1
        b       1b
9:      ret

/*
 * op_install - x0 = the code, w1 = how many bytes.
 *   out x0 = an address it can be called at, or 0.
 *
 * Mapped writable, filled, then made executable and not writable. The two
 * permissions are never held at once, which is the only part of this that is
 * a real defence rather than an argument.
 */
        .globl  SYM(op_install)
SYM(op_install):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0
        mov     w20, w1
        cbz     w20, .Loi_fail

        mov     x0, #0
        mov     w1, w20
        mov     x2, #(PROT_READ | PROT_WRITE)
        mov     x3, #(MAP_PRIVATE | MAP_ANON)
        mov     x4, #-1
        mov     x5, #0
        mov     x16, #SYS_MMAP
        svc     #0x80
        b.cs    .Loi_fail
        mov     x21, x0

        mov     w9, #0                  /* the blob, byte for byte */
1:      cmp     w9, w20
        b.hs    2f
        ldrb    w10, [x19, w9, uxtw]
        strb    w10, [x21, w9, uxtw]
        add     w9, w9, #1
        b       1b
2:
        mov     x0, x21
        mov     w1, w20
        mov     x2, #(PROT_READ | PROT_EXEC)
        mov     x16, #SYS_MPROTECT
        svc     #0x80
        b.cs    .Loi_unmap

/*
 * Nothing has run from these addresses before, and the instruction cache does
 * not know that. Who fixes it differs between the two builds, which is one of
 * the few places they genuinely diverge:
 *
 * Under an OS, mprotect is the thing that made the page executable and the
 * kernel does the maintenance as part of it. It also has to: DC CVAU and IC
 * IVAU trap at EL0 on Darwin, so a program that tried to do this itself would
 * take an illegal instruction rather than being helpful.
 *
 * On bare metal there is nobody else to do it, and we are at EL1 where those
 * instructions are ours to use.
 */
#ifndef __MACH__
        mov     x0, x21
        mov     w1, w20
        bl      op_sync_icache
#endif

        mov     x0, x21
        b       .Loi_out
.Loi_unmap:
        mov     x0, x21
        mov     w1, w20
        mov     x16, #SYS_MUNMAP
        svc     #0x80
.Loi_fail:
        mov     x0, #0
.Loi_out:
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * op_sync_icache - x0 = address, w1 = length.
 *
 * Clean the data cache to the point of unification, then invalidate the
 * instruction cache over the same range. Without this the core may execute
 * whatever those addresses held before, which on a fresh mapping is zeroes -
 * and a page of zeroes decodes as UDF, so the failure is a crash rather than
 * anything subtle. The line size comes from CTR_EL0 because it is not the same
 * on every part.
 */
#ifndef __MACH__
op_sync_icache:
        add     x2, x0, w1, uxtw        /* end */
        mrs     x3, ctr_el0
        ubfx    x4, x3, #16, #4         /* log2 of the i-cache line, in words */
        mov     x5, #4
        lsl     x5, x5, x4              /* i-cache line size */
        and     x4, x3, #15             /* log2 of the d-cache line, in words */
        mov     x6, #4
        lsl     x6, x6, x4              /* d-cache line size */

        sub     x7, x6, #1
        bic     x9, x0, x7              /* down to a line boundary */
1:      cmp     x9, x2
        b.hs    2f
        dc      cvau, x9
        add     x9, x9, x6
        b       1b
2:      dsb     ish

        sub     x7, x5, #1
        bic     x9, x0, x7
3:      cmp     x9, x2
        b.hs    4f
        ic      ivau, x9
        add     x9, x9, x5
        b       3b
4:      dsb     ish
        isb
        ret
#endif

/*
 * op_run - x0 = the installed code, x1 = the values, x2 = out, w3 = capacity.
 *   out w0 = bytes written, or -1 if the operation declined.
 *
 * A decline is not a failure. It means the operation looked at what it was
 * given and knew it was the wrong tool, and the caller should ask the server
 * exactly as if the operation had not been installed.
 */
        .globl  SYM(op_run)
SYM(op_run):
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        mov     x9, x0
        mov     x0, x1                  /* values  */
        mov     x1, x2                  /* out     */
        add     x2, x2, w3, uxtw        /* limit   */
        sub     x2, x2, #1              /* room for a terminator */
        LEA     x3, SYM(op_helpers)
        blr     x9
        ldp     x29, x30, [sp], #32
        ret

        DATA
        .p2align 3
/*
 * The only things generated code can call. Keeping this to two entries is
 * deliberate: it is the entire surface a blob has on the rest of the program.
 */
        .globl  SYM(op_helpers)
SYM(op_helpers):
        .quad   SYM(str_eq)
        .quad   SYM(op_append)
