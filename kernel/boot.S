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

2:      bl      kmain                   /* x0 still holds the DTB pointer */

3:      wfe                             /* kmain is not expected to return */
        b       3b
