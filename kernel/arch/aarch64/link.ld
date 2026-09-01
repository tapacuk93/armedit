/* Bare-metal layout for QEMU virt: RAM starts at 0x40000000, and the arm64
   boot convention puts the image 0x80000 into it. */
ENTRY(_start)
SECTIONS
{
    . = 0x40080000;
    .text : { KEEP(*(.text.boot)) *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    . = ALIGN(16);
    __bss_start = .;
    .bss : { *(.bss*) *(COMMON) }
    . = ALIGN(16);
    __bss_end = .;
    . = ALIGN(4096);
    . = . + 0x20000;            /* 128K of stack */
    __stack_top = .;

    /*
     * How big the image says it is.
     *
     * The arm64 image header carries this so a loader knows how much memory to
     * leave alone, and it has to include .bss and the stack: those are not in
     * the file, but they are certainly in use, and a loader that placed a
     * device tree in them would be within its rights.
     */
    __image_end = .;
    __image_size = __image_end - 0x40080000;
}
