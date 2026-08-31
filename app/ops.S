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

#ifndef __MACH__
/*
 * Bare metal has no mmap to ask, and no memory protection to ask it about:
 * the kernel maps its RAM once, executable, and there is no W^X here to
 * uphold. So the blob is already at an address it can be called from, and
 * installing it is only the cache maintenance below.
 *
 * That is a smaller guarantee than the hosted build gives, and it is worth
 * saying plainly rather than letting the shared function name imply
 * otherwise. When this kernel grows page tables, this is one of the places
 * that has to change.
 */
        mov     x21, x19
        mov     x0, x21
        mov     w1, w20
        bl      op_sync_icache
        mov     x0, x21
        b       .Loi_out
#endif

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
 * op_available - can this device run code that arrived over the wire at all?
 *   out w0 = 1 yes, 0 no.
 *
 * Asked rather than assumed, because the answer is a property of the platform
 * and not of the build. macOS and bare metal say yes. iOS says no on a real
 * device: every executable page must be signed, so the mprotect below fails,
 * and the one sanctioned way round it - MAP_JIT with a dynamic-codesigning
 * entitlement - is not available to ordinary applications.
 *
 * That is not a problem to work around, it is a fork in the delivery. An
 * operation is a small enough thing that the server can send either the
 * machine code or the description it was generated from, and a device that
 * cannot run the first asks for the second. Same operation, same answers, one
 * of them a little slower.
 *
 * The probe installs and runs two instructions rather than reasoning about
 * what the platform ought to permit. A mapping that takes the permission but
 * faults on the first instruction would look identical to a working one from
 * any lesser test.
 */
        .globl  SYM(op_available)
SYM(op_available):
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        LEA     x9, op_probe
        LEA     x10, op_probe_end
        sub     x10, x10, x9
        mov     x0, x9
        mov     w1, w10
        bl      SYM(op_install)
        cbz     x0, 9f
        mov     x19, x0
        blr     x19                     /* it returns 0x5A if it really ran */
        cmp     w0, #0x5A
        cset    w0, eq
        b       8f
9:      mov     w0, #0
8:      ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

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

        RODATA
        .p2align 2
/* movz w0, #0x5A ; ret - the smallest thing that proves a page really ran. */
op_probe:
        .long   0x52800B40
        .long   0xD65F03C0
op_probe_end:

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
        .quad   SYM(js_concat)
        .quad   SYM(js_truthy)
        .quad   SYM(js_render)

        CODE
        .p2align 2
/*
 * The JavaScript runtime, such as it is.
 *
 * Compiled script computes with tagged words - an integer is n<<1, a string is
 * a pointer with the bottom bit set - and calls in here for anything that
 * needs memory. That division is the point: generated code never allocates,
 * never copies and never computes an address, so the whole question of what it
 * might reach is answered by what it was handed.
 *
 * The arena below is fixed and never freed. A page's script runs, produces a
 * string, and the arena is reset for the next one; there is no collector
 * because there is nothing here that outlives a single run. That is a real
 * limit - a script that concatenates in a long loop will exhaust it - and the
 * failure is a truncated string rather than a smashed heap.
 */
#define JS_ARENA_SZ     65536

/* js_truthy - x0 = tagged, out x0 = 0 or 1.  The host decides, so "" is falsy. */
        .globl  SYM(js_truthy)
SYM(js_truthy):
        tbnz    x0, #0, 1f
        cmp     x0, #0                  /* an integer: zero is false */
        cset    w0, ne
        ret
1:      bic     x9, x0, #1              /* a string: empty is false */
        ldrb    w9, [x9]
        cmp     w9, #0
        cset    w0, ne
        ret

/*
 * js_concat - x0, x1 = tagged, out x0 = a tagged string.
 * Either side may be a number, which is where "1" + 1 becomes "11" - the one
 * piece of JavaScript coercion this subset implements, because it is the one
 * page scripts actually rely on.
 */
        .globl  SYM(js_concat)
SYM(js_concat):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0
        mov     x20, x1

        bl      js_arena_here
        mov     x21, x0                 /* where the answer starts */
        mov     x22, x0

        mov     x0, x19
        mov     x1, x22
        bl      js_write
        mov     x22, x0
        mov     x0, x20
        mov     x1, x22
        bl      js_write
        mov     x22, x0
        strb    wzr, [x22]
        add     x22, x22, #1
        mov     x0, x22
        bl      js_arena_take

        orr     x0, x21, #1             /* tagged as a string */
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * js_render - x0 = tagged, x1 = out, x2 = limit, out x0 = bytes written.
 * What op_run hands back to the caller.
 */
        .globl  SYM(js_render)
SYM(js_render):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     x19, x1
        mov     x20, x2
        mov     x1, x19
        bl      js_write_bounded
        sub     x0, x0, x19
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * js_write - x0 = tagged, x1 = destination, out x0 = one past what was written.
 * Unbounded, because its only caller is js_concat, which reserved the room.
 */
js_write:
        tbnz    x0, #0, .Ljw_str
        mov     x2, x0                  /* an integer, in decimal */
        asr     x2, x2, #1
        mov     x0, x1
        cmp     x2, #0
        b.ge    1f
        mov     w3, #'-'
        strb    w3, [x0], #1
        neg     x2, x2
1:      mov     x3, x0                  /* digits come out backwards */
        mov     x4, #10
2:      udiv    x5, x2, x4
        msub    x6, x5, x4, x2
        add     w6, w6, #'0'
        strb    w6, [x0], #1
        mov     x2, x5
        cbnz    x2, 2b
        sub     x5, x0, #1              /* reverse them into place */
3:      cmp     x3, x5
        b.hs    9f
        ldrb    w6, [x3]
        ldrb    w7, [x5]
        strb    w7, [x3], #1
        strb    w6, [x5], #-1
        b       3b
9:      ret
.Ljw_str:
        bic     x2, x0, #1
        mov     x0, x1
1:      ldrb    w3, [x2], #1
        cbz     w3, 9f
        strb    w3, [x0], #1
        b       1b
9:      ret

/* js_write_bounded - as js_write, but x20 is a hard stop. */
js_write_bounded:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        str     x19, [sp, #16]
        tbnz    x0, #0, 1f
        bl      js_write                /* a number is at most 20 digits */
        b       9f
1:      bic     x2, x0, #1
        mov     x0, x1
2:      cmp     x0, x20
        b.hs    9f
        ldrb    w3, [x2], #1
        cbz     w3, 9f
        strb    w3, [x0], #1
        b       2b
9:      ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* js_arena_here / js_arena_take / js_reset - the whole memory manager. */
js_arena_here:
        LEA     x9, js_top
        ldr     x0, [x9]
        cbnz    x0, 1f
        LEA     x0, js_arena
1:      ret

/*
 * js_arena_take - x0 = one past what was just used.
 *
 * Rounded up to eight, and that rounding is load-bearing rather than tidy: a
 * string is tagged by setting the bottom bit of its address, so a string that
 * starts at an odd address cannot be tagged at all - the bit is already set,
 * and untagging it later hands back an address one byte to the left. The
 * symptom is a concatenation that works once and returns nothing the second
 * time, because "ab\0" leaves the arena on an odd byte.
 */
js_arena_take:
        add     x0, x0, #7
        and     x0, x0, #0xFFFFFFFFFFFFFFF8
        LEA     x9, js_arena
        add     x9, x9, #JS_ARENA_SZ
        sub     x9, x9, #64             /* never hand out the last of it */
        cmp     x0, x9
        csel    x0, x0, x9, lo
        LEA     x9, js_top
        str     x0, [x9]
        ret

/* js_reset - between scripts.  There is nothing to collect because nothing
   survives a run. */
        .globl  SYM(js_reset)
SYM(js_reset):
        LEA     x9, js_top
        LEA     x10, js_arena
        str     x10, [x9]
        ret

        BSS
        .p2align 3
js_top:     .space 8
js_arena:   .space JS_ARENA_SZ
