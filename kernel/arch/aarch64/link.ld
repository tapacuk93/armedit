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
}
