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
_start:
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
