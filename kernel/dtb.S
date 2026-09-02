#include "asm.inc"
/*
 * dtb.S - reading the device tree the firmware hands over.
 *
 * Every machine this kernel can boot on passes a flattened device tree in x0
 * and then says nothing else about itself. QEMU does, macOS's Virtualization
 * framework does, and m1n1 does. Until now this kernel ignored it and used the
 * addresses QEMU's `virt` machine happens to have - virtio at 0x0A000000, a
 * PL011 at 0x09000000 - which is correct on exactly one machine and silently
 * wrong everywhere else. Not wrong with an error: wrong by reading a device
 * register that is not there, which on bare metal is a fault or, worse, a zero
 * that looks like an answer.
 *
 * So the addresses come from the tree.
 *
 * <h2>The format, and the part that matters here</h2>
 *
 * A header, then a block of tokens. Each token is a big-endian 32-bit word:
 * BEGIN_NODE followed by a NUL-terminated name, PROP followed by a length, a
 * name offset and that many bytes, END_NODE, NOP, END. Property names live in
 * a separate string block and are referenced by offset. Everything multi-byte
 * is big-endian, which is worth saying because this CPU is not.
 *
 * <h2>Every read is byte-wise</h2>
 *
 * Not for endianness - that would only need a rev - but because the MMU is off
 * and all memory is therefore Device type, where an unaligned load faults. The
 * tokens themselves are four-byte aligned, but a `reg` property is a list of
 * 64-bit values sitting at a four-byte boundary, so reading one with an ldr
 * takes an alignment fault about half the time. That is the same fault that
 * cost a day in the video decoder, and it is the first thing this file would
 * have hit.
 *
 * <h2>A frame, because it calls something</h2>
 *
 * dtb_init reads one word before it decides anything, and reading a word is a
 * call. Without a stack frame its own ret goes to the instruction after that
 * call, and the machine sits on a `mov` forever - which is what it did, and
 * what a frozen program counter on an instruction that cannot loop always
 * means. This is the third function in this project to be written that way and
 * the third to be found by the same symptom.
 *
 * <h2>What it does not do</h2>
 *
 * No phandle resolution, no interrupt mapping, no ranges translation. A node's
 * `reg` is taken as a physical address, which is true for the buses this
 * kernel touches and would not be true under a bridge. It also assumes a
 * matching node has no children, which is true of every leaf device here -
 * state is reset when a child node begins, so a parent's properties would be
 * forgotten before its END_NODE arrives.
 *
 * And it only reports nodes that have a `reg`. That is the right answer for
 * finding hardware and the wrong answer for asking whether a node exists: an
 * interrupt-only node like the architected timer has no address, so dtb_reg
 * says "not here" about something that is. It came up immediately - a probe
 * for arm,armv8-timer under the Virtualization framework said absent, and the
 * timer is certainly there. A caller wanting existence rather than an address
 * needs a different question than this one.
 */

#define FDT_MAGIC       0xD00DFEED
#define FDT_BEGIN_NODE  1
#define FDT_END_NODE    2
#define FDT_PROP        3
#define FDT_NOP         4
#define FDT_END         9

        CODE
        .p2align 2

/*
 * dtb_init - x0 = whatever was in x0 at boot.
 *   out w0 = 0 if it looks like a device tree, -1 if it does not.
 *
 * Checked rather than trusted: x0 at boot is a promise, and a machine that
 * breaks it should be told about rather than followed into a parser.
 */
        .globl  SYM(dtb_init)
SYM(dtb_init):
        stp     x29, x30, [sp, #-32]!   /* it calls something, so it needs a
                                           frame - without one its ret goes to
                                           the instruction after its own bl,
                                           and the machine sits there forever */
        mov     x29, sp
        str     x19, [sp, #16]
        mov     x19, x0
        cbz     x19, 9f
        mov     x1, x19
        bl      dtb_be32                /* magic */
        movz    w2, #0xFEED
        movk    w2, #0xD00D, lsl #16
        cmp     w0, w2
        b.ne    9f
        LEA     x9, dtb_base
        str     x19, [x9]
        mov     w0, #0
        b       10f
9:      LEA     x9, dtb_base
        str     xzr, [x9]
        mov     w0, #-1
10:     ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/*
 * dtb_or - x0 = a compatible string, x1 = what to use if the tree is silent.
 *   out x0 = an address.
 *
 * The fallback is not laziness. This kernel is also loaded as an ELF, and a
 * loader that jumps to an entry point hands over no device tree at all - so a
 * machine that says nothing gets the address that was correct before any of
 * this existed, and a machine that speaks is believed. Refusing to boot
 * without a tree would break the way this kernel is usually run in order to
 * support the way it is not yet run at all.
 */
        .globl  SYM(dtb_or)
SYM(dtb_or):
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     x19, x1
        mov     w1, #0
        bl      SYM(dtb_reg)
        cbnz    x0, 9f
        mov     x0, x19
9:      ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/* dtb_peek - x1 = where, out w0 = the big-endian word there. For diagnosis. */
        .globl  SYM(dtb_peek)
SYM(dtb_peek):
        b       dtb_be32

/* dtb_have - w0 = 1 if a tree was accepted. */
        .globl  SYM(dtb_have)
SYM(dtb_have):
        LEA     x9, dtb_base
        ldr     x9, [x9]
        cmp     x9, #0
        cset    w0, ne
        ret

/*
 * dtb_reg - find the nth device with this compatible string.
 *   x0 = a compatible string, w1 = which match (0 for the first)
 *   out x0 = its address, x1 = its size, or x0 = 0 if there is no such thing.
 *
 * "compatible" is a list of NUL-separated strings, most specific first, and a
 * match against any of them counts - that is what the property means, and a
 * driver that only accepted the first would refuse hardware it can drive.
 */
/*
 * dtb_prop - x0 = a compatible string, w1 = which match, x2 = a property name.
 *   out x0 = the property's bytes, x1 = how many, or x0 = 0.
 *
 * The same walk dtb_reg does, stopping at a property the caller names instead
 * of at "reg". It exists because the first thing that needed it was the PSCI
 * node, which has no address at all - only a `method` saying whether the call
 * is hvc or smc - and getting that wrong is not a failed reboot but an
 * undefined instruction.
 */
        .globl  SYM(dtb_prop)
SYM(dtb_prop):
        LEA     x9, dtb_want
        str     x2, [x9]
        LEA     x9, dtb_key
        LEA     x10, s_compatible
        str     x10, [x9]
        b       dtb_walk

        .globl  SYM(dtb_reg)
SYM(dtb_reg):
        LEA     x9, dtb_want
        LEA     x10, s_reg
        str     x10, [x9]
        LEA     x9, dtb_key
        LEA     x10, s_compatible
        str     x10, [x9]
        b       dtb_walk

/*
 * dtb_memory - out x0 = where RAM starts, x1 = how much, or x0 = 0.
 *
 * The memory node is the one thing in the tree that does not say what it is
 * with a `compatible`. It says it with `device_type = "memory"`, which is
 * older than compatible strings and survives because everything already reads
 * it - so a reader that only knows how to match compatibles cannot find the
 * one node that says where the machine's memory is.
 *
 * Worth having for one reason: on the target, RAM starts above the
 * thirty-second bit, and the first thing anybody wants to know about an
 * unfamiliar machine is whether they are inside it. See report.S.
 */
        .globl  SYM(dtb_memory)
SYM(dtb_memory):
        LEA     x9, dtb_want
        LEA     x10, s_reg
        str     x10, [x9]
        LEA     x9, dtb_key
        LEA     x10, s_devtype
        str     x10, [x9]
        LEA     x0, s_memory
        mov     w1, #0
        b       dtb_walk

dtb_walk:
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        stp     x27, x28, [sp, #80]

        mov     x19, x0                 /* wanted compatible */
        mov     w20, w1                 /* how many to skip  */

        LEA     x9, dtb_base
        ldr     x21, [x9]
        cbz     x21, .Ldr_none

        mov     x1, x21                 /* off_dt_struct is at +8 */
        add     x1, x1, #8
        bl      dtb_be32
        mov     x22, x0
        add     x22, x21, x22           /* the struct block */
        mov     x1, x21
        add     x1, x1, #12
        bl      dtb_be32
        add     x23, x21, x0            /* the string block */

        mov     w24, #0                 /* is this node a match?     */
        mov     x25, #0                 /* its address, if it has one */
        mov     x26, #0                 /* its size                   */
        mov     w27, #0                 /* has a reg been seen?       */
        mov     x28, x22                /* the cursor                 */

/*
 * Address and size cells.
 *
 * Two and two on every arm64 machine this targets, and read rather than
 * assumed because a wrong guess here does not fail - it silently reads the
 * high half of an address as the whole of one.
 */
        mov     w0, #2
        LEA     x9, dtb_addr_cells
        str     w0, [x9]
        LEA     x9, dtb_size_cells
        str     w0, [x9]

.Ldr_token:
        mov     x1, x28
        bl      dtb_be32
        add     x28, x28, #4

        cmp     w0, #FDT_NOP
        b.eq    .Ldr_token
        cmp     w0, #FDT_END
        b.eq    .Ldr_none

        cmp     w0, #FDT_BEGIN_NODE
        b.ne    1f
        /* A new node: everything known about the last one is no longer true. */
        mov     w24, #0
        mov     w27, #0
        mov     x1, x28
        bl      dtb_skipstr
        mov     x28, x0
        b       .Ldr_token

1:      cmp     w0, #FDT_END_NODE
        b.ne    2f
        cbz     w24, .Ldr_token         /* not the droid */
        cbz     w27, .Ldr_token         /* matched, but says nothing about where */
        cbz     w20, .Ldr_found
        sub     w20, w20, #1
        mov     w24, #0
        mov     w27, #0
        b       .Ldr_token

2:      cmp     w0, #FDT_PROP
        b.ne    .Ldr_none               /* a token this does not know: stop */

        mov     x1, x28
        bl      dtb_be32
        mov     w9, w0                  /* length */
        LEA     x10, dtb_len
        str     w9, [x10]
        add     x1, x28, #4
        bl      dtb_be32
        add     x9, x23, x0             /* the property's name */
        LEA     x10, dtb_name
        str     x9, [x10]
        add     x28, x28, #8            /* past len and nameoff */

        LEA     x10, dtb_name
        ldr     x0, [x10]
        LEA     x1, dtb_key             /* "compatible" for most callers, and
                                           "device_type" for the memory node,
                                           which has no compatible at all */
        ldr     x1, [x1]
        bl      dtb_streq
        cbz     w0, 3f
        /* Does any string in the list match what we want? */
        LEA     x10, dtb_len
        ldr     w2, [x10]
        mov     x0, x28
        mov     x1, x19
        bl      dtb_listhas
        mov     w24, w0
        b       .Ldr_advance

3:      LEA     x10, dtb_name
        ldr     x0, [x10]
        LEA     x1, dtb_want            /* whichever property was asked for */
        ldr     x1, [x1]
        bl      dtb_streq
        cbz     w0, .Ldr_advance
        LEA     x10, dtb_found          /* where its bytes are, and how many -
                                           both captured now, because the walk
                                           carries on through the rest of the
                                           node's properties and dtb_len will
                                           be the last one's by the time this
                                           returns */
        str     x28, [x10]
        LEA     x10, dtb_len
        ldr     w10, [x10]
        LEA     x11, dtb_found_len
        str     w10, [x11]
        /* Two cells of address, then two of size - read as four words. */
        mov     x1, x28
        bl      dtb_be32
        mov     x25, x0
        lsl     x25, x25, #32
        add     x1, x28, #4
        bl      dtb_be32
        orr     x25, x25, x0
        add     x1, x28, #8
        bl      dtb_be32
        mov     x26, x0
        lsl     x26, x26, #32
        add     x1, x28, #12
        bl      dtb_be32
        orr     x26, x26, x0
        mov     w27, #1

.Ldr_advance:
        LEA     x10, dtb_len
        ldr     w9, [x10]
        add     x28, x28, x9
        add     x28, x28, #3            /* properties are padded to four */
        and     x28, x28, #0xFFFFFFFFFFFFFFFC
        b       .Ldr_token

.Ldr_found:
        /*
         * "reg" callers want the address decoded; everyone else wants the
         * bytes. Told apart by which property was asked for, since decoding a
         * `method` string as two address cells would return nonsense that
         * looks like an address.
         */
        LEA     x9, dtb_want
        ldr     x0, [x9]
        LEA     x1, s_reg
        bl      dtb_streq
        cbz     w0, 1f
        mov     x0, x25
        mov     x1, x26
        b       .Ldr_out
1:      LEA     x9, dtb_found
        ldr     x0, [x9]
        LEA     x9, dtb_found_len
        ldr     w1, [x9]
        b       .Ldr_out
.Ldr_none:
        mov     x0, #0
        mov     x1, #0
.Ldr_out:
        ldp     x27, x28, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

/*
 * dtb_be32 - x1 = where, out w0 = the big-endian word there.
 *
 * Four byte loads, not one word load and a rev. See the file comment: with the
 * MMU off this memory is Device type, and property data sits four-byte aligned
 * while carrying eight-byte values.
 */
dtb_be32:
        ldrb    w9, [x1]
        ldrb    w10, [x1, #1]
        ldrb    w11, [x1, #2]
        ldrb    w12, [x1, #3]
        lsl     w9, w9, #24
        orr     w9, w9, w10, lsl #16
        orr     w9, w9, w11, lsl #8
        orr     w0, w9, w12
        ret

/* dtb_skipstr - x1 = a NUL-terminated string, out x0 = past it, four-aligned. */
dtb_skipstr:
        mov     x0, x1
1:      ldrb    w9, [x0], #1
        cbnz    w9, 1b
        add     x0, x0, #3
        and     x0, x0, #0xFFFFFFFFFFFFFFFC
        ret

/* dtb_streq - x0, x1 = two NUL-terminated strings, out w0 = 1 if equal. */
dtb_streq:
        mov     x2, x0
        mov     x3, x1
1:      ldrb    w9, [x2]
        ldrb    w10, [x3]
        cmp     w9, w10
        b.ne    9f
        cbz     w9, 8f
        add     x2, x2, #1
        add     x3, x3, #1
        b       1b
8:      mov     w0, #1
        ret
9:      mov     w0, #0
        ret

/*
 * dtb_listhas - x0 = a NUL-separated list, x1 = a string, w2 = the list's length.
 *   out w0 = 1 if the string is one of them.
 */
dtb_listhas:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]
        mov     x19, x0
        mov     x20, x1
        add     x21, x0, w2, uxtw       /* one past the end */
1:      cmp     x19, x21
        b.hs    9f
        ldrb    w9, [x19]
        cbz     w9, 9f
        mov     x0, x19
        mov     x1, x20
        bl      dtb_streq
        cbnz    w0, 8f
2:      ldrb    w9, [x19], #1           /* on to the next string */
        cbnz    w9, 2b
        b       1b
8:      mov     w0, #1
        b       10f
9:      mov     w0, #0
10:     ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

        RODATA
s_compatible: .asciz "compatible"
s_devtype:    .asciz "device_type"
s_memory:     .asciz "memory"
s_reg:        .asciz "reg"

        BSS
        .p2align 3
/*
 * Eight-byte fields first, then the four-byte ones.
 *
 * Not tidiness. A pointer placed after a lone 32-bit field starts four bytes
 * into an eight-byte slot, and storing to it is an unaligned 64-bit access,
 * which with the MMU off is a data abort. This file's own header says so about
 * the device tree's data and it happened here, in this file's own variables,
 * the first time a pointer was added in the middle.
 */
dtb_base:        .space 8
dtb_name:        .space 8
dtb_want:        .space 8
dtb_key:         .space 8
dtb_found:       .space 8
dtb_len:         .space 4
dtb_found_len:   .space 4
dtb_addr_cells:  .space 4
dtb_size_cells:  .space 4
