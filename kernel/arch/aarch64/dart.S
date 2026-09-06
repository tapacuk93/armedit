#include "asm.inc"
/*
 * dart.S - the address translator in front of everything on an Apple machine.
 *
 * Every driver here hands a controller a physical address and expects the
 * controller to read it. On this hardware that is not what happens. Apple puts
 * a DART - a Device Address Resolution Table, which is an IOMMU - in front of
 * its peripherals, and a device behind an unprogrammed one reads nothing at
 * any address it is given. The USB stack in xhci.S will therefore find the
 * controller, reset it, read its shape correctly, and then get silence from
 * every ring, which is exactly the failure the step numbers in the report
 * exist to tell apart.
 *
 * <h2>Bypass, not a page table</h2>
 *
 * A DART can be programmed with translation tables, and eventually should be:
 * it is the only thing that stops a device writing anywhere in memory, and
 * that protection is worth having. It can also be told to pass addresses
 * through untranslated, and that is what this does.
 *
 * The reason is what this kernel is. There is no MMU on, no allocator, and no
 * distinction between what a driver may touch and what it may not - a page
 * table here would describe the whole of memory and protect nothing, at the
 * cost of a page-table walker written to be correct on hardware nobody here
 * can test against. Bypass is one register write per stream and says plainly
 * what it does.
 *
 * <h2>What is honest about this file</h2>
 *
 * It has never run. There is no DART in QEMU and none in any emulator; the
 * only machine that has one is the target. So it is written to be as small as
 * a thing can be that still does the job, and everything that can be
 * discovered is discovered rather than assumed: which DART, from the phandle
 * the controller itself names; which stream, from the number beside it.
 *
 * The register offsets are the exception and cannot be otherwise - they are
 * Linux's apple-dart driver's, for the t8020 family that covers the M1, and
 * this project has no way to check them short of the machine. tests/ covers
 * the half that can be checked: that the right DART is found, that the right
 * stream is chosen, and that the write lands at the offset it should, against
 * memory standing in for registers.
 *
 * If it is wrong, the machine report says so in the way that costs least: USB
 * will stop at the step where a ring goes unanswered, with the DART's address
 * printed above it.
 */

/*
 * Per-stream translation control. Linux's names, because they are the only
 * published ones and inventing new ones would hide where these came from.
 */
#define DART_TCR        0x100           /* four bytes per stream */
#define TCR_TRANSLATE   (1 << 7)
#define TCR_BYPASS_DART (1 << 8)
#define TCR_BYPASS_DAPF (1 << 12)

#define MAX_STREAM      16

        CODE
        .p2align 2

/*
 * dart_find - x0 = a compatible string naming a device that sits behind one.
 *   out w0 = 0 if a translator was found, -1 if there was none.
 *   On success dart_at and dart_stream say which, and nothing has been written.
 *
 * Separate from opening it for the same reason the watchdog's search is
 * separate from its arming: the search can be tested against a real device
 * tree on any machine, and the write cannot be tested anywhere but the target
 * - so a test that had to call both could only ever call neither.
 *
 * A device says which translator is in front of it, and with which stream, in
 * its own `iommus` property: a phandle and a number. Both are read from there
 * rather than searched for, because a machine has several DARTs that all match
 * the same compatible string and the one that matters is the one this device
 * points at.
 *
 * A machine with no DART at all is not a failure. It is QEMU, and every other
 * board, where addresses mean what they say - so the answer is "there was
 * none" and the caller carries on unchanged.
 */
        .globl  SYM(dart_find)
SYM(dart_find):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        str     x23, [sp, #48]
        mov     x19, x0

        LEA     x9, SYM(dart_at)
        str     xzr, [x9]
        LEA     x9, SYM(dart_stream)
        mov     w10, #-1
        str     w10, [x9]

        mov     x0, x19
        mov     w1, #0
        LEA     x2, s_iommus
        bl      SYM(dtb_prop)
        cbz     x0, .Ldo_none
        cmp     w1, #8                          /* a phandle and a stream */
        b.lo    .Ldo_none
        mov     x20, x0

/*
 * Read byte-wise, as everything in a device tree is here: the MMU is off, so
 * all memory is Device type, and a property's bytes are aligned to four only
 * by accident of what precedes them.
 */
        mov     x0, x20
        bl      dart_be32
        mov     w21, w0                         /* which translator */
        add     x0, x20, #4
        bl      dart_be32
        mov     w22, w0                         /* and which stream of it */
        cmp     w22, #MAX_STREAM
        b.hs    .Ldo_none

        mov     w0, w21
        bl      SYM(dtb_byphandle)
        cbz     x0, .Ldo_none
        mov     x23, x0

        LEA     x9, SYM(dart_at)
        str     x23, [x9]
        LEA     x9, SYM(dart_stream)
        str     w22, [x9]
        mov     w0, #0
        b       .Ldo_out
.Ldo_none:
        mov     w0, #-1
.Ldo_out:
        ldr     x23, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * dart_open - x0 = a compatible string. Find the translator and open it.
 *   out w0 = 0 if there was one, -1 if there was not.
 */
        .globl  SYM(dart_open)
SYM(dart_open):
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        bl      SYM(dart_find)
        cmn     w0, #1
        b.eq    9f
        LEA     x9, SYM(dart_at)
        ldr     x0, [x9]
        LEA     x9, SYM(dart_stream)
        ldr     w1, [x9]
        bl      SYM(dart_bypass)
        mov     w0, #0
9:      ldp     x29, x30, [sp], #16
        ret

/*
 * dart_bypass - x0 = a translator's registers, w1 = which stream.
 *
 * One word. Translation off, and both bypasses on: the address filter as well
 * as the table, because leaving the filter enabled while the table is bypassed
 * is a device that is allowed to reach nothing.
 *
 * Separate from the search so that the search can be tested against a real
 * tree and this against memory - which is the only half of either that can be
 * checked without the machine.
 */
        .globl  SYM(dart_bypass)
SYM(dart_bypass):
        add     x9, x0, #DART_TCR
        mov     w10, #(TCR_BYPASS_DART | TCR_BYPASS_DAPF)
        str     w10, [x9, w1, uxtw #2]
        dsb     sy
        ret

/* dart_be32 - x0 = four bytes, big-endian as the tree writes them. */
dart_be32:
        ldrb    w9, [x0]
        ldrb    w10, [x0, #1]
        ldrb    w11, [x0, #2]
        ldrb    w12, [x0, #3]
        lsl     w9, w9, #24
        orr     w9, w9, w10, lsl #16
        orr     w9, w9, w11, lsl #8
        orr     w0, w9, w12
        ret

        RODATA
s_iommus:   .asciz "iommus"

        BSS
        .p2align 3
        .globl  SYM(dart_at)
        .globl  SYM(dart_stream)
SYM(dart_at):     .space 8
SYM(dart_stream): .space 4
