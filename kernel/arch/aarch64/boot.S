#include "asm.inc"
/*
 * boot.S - the first instructions the machine executes.
 *
 * QEMU's `virt` machine drops us here at EL1 with the MMU and caches off, the
 * kernel image loaded at the link address below, x0 pointing at a device tree.
 * There is no firmware underneath us and no bootloader: this is the whole
 * power-on path.  Set up a stack, zero .bss (it is NOBITS, so nobody else
 * will), and hand over to kmain.
 */
        .section .text.boot
        .globl  _start
/*
 * The arm64 Linux image header, sixty-four bytes of it.
 *
 * Not because this is Linux, but because "an arm64 kernel image" is a format
 * with exactly one definition, and every loader worth booting on implements
 * that one: QEMU, macOS's Virtualization framework, and m1n1. A loader given
 * an ELF instead will happily jump to its entry point and tell the kernel
 * nothing - which is what used to happen here, and is why x0 held no device
 * tree despite a comment saying it did. The machine was never asked in a way
 * that obliged it to answer.
 *
 * The first word must be a branch, because the loader enters at offset zero.
 * flags bit 3 says the image may be placed anywhere 2MB-aligned rather than as
 * low as possible, which is only safe because everything here is PC-relative -
 * LEA is adrp, the operation table holds offsets rather than addresses, and
 * the vector base is installed from a computed address. An absolute pointer
 * anywhere in this image would make that bit a lie.
 */
_start:
        b       .Lreal                  /* code0: the loader enters here */
        .long   0                       /* code1 */
        .quad   0                       /* text_offset: we are position-independent */
        .quad   __image_size            /* image_size, bss included */
        .quad   8                       /* flags: 2MB-aligned, anywhere */
        .quad   0                       /* res2 */
        .quad   0                       /* res3 */
        .quad   0                       /* res4 */
        .ascii  "ARM\x64"               /* magic */
        .long   0                       /* res5 */

.Lreal:
        LEA     x1, __stack_top
        mov     sp, x1

        LEA     x1, __bss_start         /* .bss is ours to clear */
        LEA     x2, __bss_end
1:      cmp     x1, x2
        b.hs    2f
        str     xzr, [x1], #8
        b       1b

/*
 * Somewhere to land when something goes wrong, installed before anything can.
 *
 * VBAR_EL1 comes out of reset holding whatever it holds, so until this runs a
 * fault vectors into nowhere and the machine stops without a word. That was
 * the behaviour for the whole first half of this kernel's life, and it is the
 * reason two separate bugs each took a day: a silent stop looks the same
 * whether the cause was a bad pointer or an infinite loop.
 *
 * It goes here, before .bss is even useful, because the window it protects
 * includes the driver bring-up that is most likely to fault.
 */
2:      LEA     x2, trap_vectors
/*
 * Whichever exception level we actually woke up at.
 *
 * QEMU's virt machine starts us at EL1 with virtualization off and at EL2 with
 * it on, and the vector base is a different register in each - writing the
 * wrong one is accepted silently and does exactly nothing, which is
 * indistinguishable from not having written it at all. That is a trap-handling
 * bug that only shows up as the absence of trap handling, so it is worth the
 * three instructions to ask rather than assume.
 */
        mrs     x1, CurrentEL
        lsr     x1, x1, #2
        cmp     x1, #2
        b.lo    3f
        msr     vbar_el2, x2
        b       4f
3:      msr     vbar_el1, x2
4:      isb

        bl      kmain                   /* x0 still holds the DTB pointer */

3:      wfe                             /* kmain is not expected to return */
        b       3b
