#include "asm.inc"
/*
 * bootargs.S - what m1n1 hands over on a real Apple machine.
 *
 * Bare metal on Apple Silicon is the target, and the way in is m1n1: Asahi's
 * bootloader, which iBoot starts and which then starts something else. It does
 * not pass a device tree the way QEMU and the Virtualization framework do. It
 * passes a structure of its own, and the most important thing in it is a
 * framebuffer that is already initialised - m1n1 has talked to the display
 * controller so that its payload does not have to.
 *
 * That is the whole of first light on that machine: take the framebuffer,
 * draw. No display driver, no DisplayPort, no dart, none of the work that
 * makes bringing up a modern Apple GPU a project rather than a file.
 *
 * <h2>Telling it apart from a device tree</h2>
 *
 * Both arrive in x0 and neither says which it is. A flattened device tree
 * begins with 0xd00dfeed, so anything that does not is tried as boot args -
 * and boot args are checked for a plausible revision and a framebuffer that
 * could exist, because "not a device tree" is not the same as "is this".
 *
 * <h2>The offsets are an ABI, not a guess</h2>
 *
 * They are m1n1's struct boot_args, which iBoot's own format dictates. They
 * are written out here rather than derived, because a header this kernel could
 * include does not exist and inventing one would only hide the numbers
 * somewhere else.
 */

#define BA_REVISION     0               /* u16 */
#define BA_VERSION      2               /* u16 */
#define BA_VIRT_BASE    8
#define BA_PHYS_BASE    16
#define BA_MEM_SIZE     24
#define BA_TOP_OF_KDATA 32
#define BA_FB_BASE      40
#define BA_FB_DISPLAY   48
#define BA_FB_STRIDE    56
#define BA_FB_WIDTH     64
#define BA_FB_HEIGHT    72
#define BA_FB_DEPTH     80
#define BA_MACHINE_TYPE 88              /* u32 */
#define BA_DEVTREE      96
#define BA_DEVTREE_SIZE 104             /* u32 */
#define BA_CMDLINE      108             /* 608 bytes */

        CODE
        .p2align 2

/*
 * bootargs_init - x0 = whatever was in x0 at boot.
 *   out w0 = 0 if this looks like m1n1's boot arguments, -1 if it does not.
 *
 * Every field is read byte-wise, for the reason the device tree parser gives:
 * the MMU is off, so all memory is Device type, and a 64-bit load from an
 * address that is only four-byte aligned is an alignment fault rather than a
 * slow read. The structure is aligned in practice and this does not depend on
 * it being so.
 */
        .globl  SYM(bootargs_init)
SYM(bootargs_init):
        stp     x29, x30, [sp, #-48]!   /* it calls something, so it has a frame */
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]
        mov     x19, x0

        LEA     x9, ba_base
        str     xzr, [x9]
        cbz     x19, .Lba_no

        /*
         * A revision this kernel has seen, and a framebuffer that could be
         * one. Neither test is strong on its own - the point is only to reject
         * a pointer that is not this structure, because reading a framebuffer
         * address out of something else and drawing to it is the worst
         * available outcome.
         */
        ldrb    w9, [x19, #BA_REVISION]
        ldrb    w10, [x19, #(BA_REVISION + 1)]
        orr     w9, w9, w10, lsl #8
        cbz     w9, .Lba_no             /* revision zero is nobody's */
        cmp     w9, #16
        b.hi    .Lba_no

        add     x0, x19, #BA_FB_BASE
        bl      bootargs_u64
        cbz     x0, .Lba_no             /* a framebuffer at zero is not one */
        mov     x20, x0

        add     x0, x19, #BA_FB_WIDTH
        bl      bootargs_u64
        cbz     x0, .Lba_no
        mov     x9, #16384
        cmp     x0, x9
        b.hi    .Lba_no                 /* nobody has a screen this wide */
        mov     x21, x0

        LEA     x9, ba_base
        str     x19, [x9]
        mov     w0, #0
        b       .Lba_out
.Lba_no:
        mov     w0, #-1
.Lba_out:
        ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* bootargs_have - w0 = 1 if boot arguments were accepted. */
        .globl  SYM(bootargs_have)
SYM(bootargs_have):
        LEA     x9, ba_base
        ldr     x9, [x9]
        cmp     x9, #0
        cset    w0, ne
        ret

/*
 * bootargs_fb - x0 = base out, x1 = width out, x2 = height out,
 *               x3 = stride out, x4 = depth out.  All may be null.
 *   out w0 = 0 if there is a framebuffer, -1 if there is not.
 *
 * Stride in bytes and depth in bits, both as m1n1 reports them. The depth
 * field carries flags above its low byte on some machines, so only the byte is
 * taken: a depth of 30 with a colour-space flag set is still thirty bits, and
 * a caller that read the whole word would decide the screen was millions of
 * bits deep.
 */
        .globl  SYM(bootargs_fb)
SYM(bootargs_fb):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        mov     x19, x0
        mov     x20, x1
        mov     x21, x2
        mov     x22, x3
        mov     x23, x4

        LEA     x9, ba_base
        ldr     x24, [x9]
        cbz     x24, 9f

        cbz     x19, 1f
        add     x0, x24, #BA_FB_BASE
        bl      bootargs_u64
        str     x0, [x19]
1:      cbz     x20, 2f
        add     x0, x24, #BA_FB_WIDTH
        bl      bootargs_u64
        str     x0, [x20]
2:      cbz     x21, 3f
        add     x0, x24, #BA_FB_HEIGHT
        bl      bootargs_u64
        str     x0, [x21]
3:      cbz     x22, 4f
        add     x0, x24, #BA_FB_STRIDE
        bl      bootargs_u64
        str     x0, [x22]
4:      cbz     x23, 5f
        add     x0, x24, #BA_FB_DEPTH
        bl      bootargs_u64
        and     x0, x0, #0xFF           /* the flags above it are not depth */
        str     x0, [x23]
5:      mov     w0, #0
        b       8f
9:      mov     w0, #-1
8:      ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * bootargs_adt - out x0 = Apple's device tree, x1 = its size, or x0 = 0.
 *
 * Not the flattened device tree this kernel already reads: Apple's own format,
 * which is a different thing with a different layout. Nothing here parses it
 * yet. It is exposed because everything past first light - the interrupt
 * controller, the timers, the serial port - is described in it and nowhere
 * else, and a kernel that reached that point without a way to find it would
 * have to boot again to get one.
 */
        .globl  SYM(bootargs_adt)
SYM(bootargs_adt):
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        LEA     x9, ba_base
        ldr     x19, [x9]
        cbz     x19, 9f
        add     x0, x19, #BA_DEVTREE
        bl      bootargs_u64
        mov     x9, x0
        add     x0, x19, #BA_DEVTREE_SIZE
        bl      bootargs_u32
        mov     x1, x0
        mov     x0, x9
        b       8f
9:      mov     x0, #0
        mov     x1, #0
8:      ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/* bootargs_u64 - x0 = where, out x0 = the little-endian value, byte at a time. */
bootargs_u64:
        mov     x1, x0
        mov     x0, #0
        mov     w2, #0
1:      cmp     w2, #8
        b.hs    9f
        ldrb    w3, [x1, w2, uxtw]
        lsl     w4, w2, #3
        lsl     x3, x3, x4
        orr     x0, x0, x3
        add     w2, w2, #1
        b       1b
9:      ret

/* bootargs_u32 - the same, four bytes. */
bootargs_u32:
        ldrb    w1, [x0]
        ldrb    w2, [x0, #1]
        ldrb    w3, [x0, #2]
        ldrb    w4, [x0, #3]
        orr     w1, w1, w2, lsl #8
        orr     w1, w1, w3, lsl #16
        orr     w0, w1, w4, lsl #24
        ret

        BSS
        .p2align 3
ba_base:  .space 8
