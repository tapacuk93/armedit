/*
 * asm.inc - the two-target shim.
 *
 * Every source file in this repo is assembled twice over its life: once for
 * Mach-O (the macOS window/tty modes and the backend daemon) and once for
 * bare-metal ELF (the kernel).  The instruction set is identical; only symbol
 * naming, section names and the address-of-a-symbol idiom differ.  Those three
 * differences live here and nowhere else.
 */
#ifndef ARMEDIT_ASM_INC
#define ARMEDIT_ASM_INC

#ifdef __MACH__
# define SYM(name)  _##name
# define RODATA     .section __TEXT,__const
# define CSTR       .section __TEXT,__cstring
# define CODE       .section __TEXT,__text
# define BSS        .section __DATA,__bss
# define DATA       .section __DATA,__data
#else
# define SYM(name)  name
# define RODATA     .section .rodata
# define CSTR       .section .rodata
# define CODE       .section .text
# define BSS        .section .bss
# define DATA       .section .data
#endif

/* LEA reg, sym - put the address of `sym` in `reg`. */
#ifdef __MACH__
.macro  LEA reg, sym
        adrp    \reg, \sym@PAGE
        add     \reg, \reg, \sym@PAGEOFF
.endm
#else
.macro  LEA reg, sym
        adrp    \reg, \sym
        add     \reg, \reg, :lo12:\sym
.endm
#endif

/* Font geometry, shared by every renderer. */
#define GLYPH_W   5
#define GLYPH_H   7
#define GLYPH_ADV 6     /* glyph cell width including the 1px gap */
#define IDX_SPACE 26    /* slot of ' ' in the key table */

#endif /* ARMEDIT_ASM_INC */
