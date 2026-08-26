#include "asm.inc"
/*
 * str.S - the string and JSON primitives everything else is built from.
 *
 * There is no libc in this project, on either target, so this is where
 * strlen/strcpy/itoa live.  The JSON helpers are deliberately small: enough to
 * build a Messages API request and pull one string field back out of the
 * reply, and no more.
 */
        CODE
        .p2align 2

/* str_len - x0 = string, out w0 = length */
        .globl  SYM(str_len)
SYM(str_len):
        mov     x1, x0
1:      ldrb    w2, [x0], #1
        cbnz    w2, 1b
        sub     x0, x0, x1
        sub     w0, w0, #1
        ret

/* str_copy - x0 = dst, x1 = src; copies the NUL, returns the address of it */
        .globl  SYM(str_copy)
SYM(str_copy):
1:      ldrb    w2, [x1], #1
        strb    w2, [x0], #1
        cbnz    w2, 1b
        sub     x0, x0, #1
        ret

/* str_eq - x0, x1; out w0 = 1 if equal */
        .globl  SYM(str_eq)
SYM(str_eq):
1:      ldrb    w2, [x0], #1
        ldrb    w3, [x1], #1
        cmp     w2, w3
        b.ne    2f
        cbnz    w2, 1b
        mov     w0, #1
        ret
2:      mov     w0, #0
        ret

/*
 * str_starts - does x0 begin with x1?  out w0 = 1/0
 */
        .globl  SYM(str_starts)
SYM(str_starts):
1:      ldrb    w3, [x1], #1
        cbz     w3, 2f
        ldrb    w2, [x0], #1
        cmp     w2, w3
        b.ne    3f
        b       1b
2:      mov     w0, #1
        ret
3:      mov     w0, #0
        ret

/*
 * u32_dec - write w1 as decimal at x0 (no NUL), out x0 = one past the last
 * digit.  Digits come out backwards, so they are staged and reversed.
 */
        .globl  SYM(u32_dec)
SYM(u32_dec):
        sub     sp, sp, #32
        mov     x2, sp
        mov     w3, #0                  /* digit count */
        mov     w4, #10
1:      udiv    w5, w1, w4
        msub    w6, w5, w4, w1          /* w6 = w1 - w5*10 */
        add     w6, w6, #'0'
        strb    w6, [x2, w3, uxtw]
        add     w3, w3, #1
        mov     w1, w5
        cbnz    w1, 1b
2:      sub     w3, w3, #1
        ldrb    w6, [x2, w3, uxtw]
        strb    w6, [x0], #1
        cbnz    w3, 2b
        add     sp, sp, #32
        ret

/*
 * json_escape - copy x1 into x0 as a JSON string body (no surrounding quotes),
 * escaping what must be escaped.  w2 caps the output.  out x0 = end pointer.
 */
        .globl  SYM(json_escape)
SYM(json_escape):
        add     x3, x0, w2, uxtw
        sub     x3, x3, #8              /* headroom for the longest escape */
1:      cmp     x0, x3
        b.hs    9f
        ldrb    w4, [x1], #1
        cbz     w4, 9f
        cmp     w4, #'"'
        b.eq    .Lesc_quote
        cmp     w4, #'\\'
        b.eq    .Lesc_back
        cmp     w4, #'\n'
        b.eq    .Lesc_nl
        cmp     w4, #'\r'
        b.eq    .Lesc_cr
        cmp     w4, #'\t'
        b.eq    .Lesc_tab
        cmp     w4, #0x20               /* other control bytes: drop them */
        b.lo    1b
        strb    w4, [x0], #1
        b       1b
.Lesc_quote:
        mov     w5, #'\\'
        strb    w5, [x0], #1
        mov     w5, #'"'
        strb    w5, [x0], #1
        b       1b
.Lesc_back:
        mov     w5, #'\\'
        strb    w5, [x0], #1
        strb    w5, [x0], #1
        b       1b
.Lesc_nl:
        mov     w5, #'\\'
        strb    w5, [x0], #1
        mov     w5, #'n'
        strb    w5, [x0], #1
        b       1b
.Lesc_cr:
        mov     w5, #'\\'
        strb    w5, [x0], #1
        mov     w5, #'r'
        strb    w5, [x0], #1
        b       1b
.Lesc_tab:
        mov     w5, #'\\'
        strb    w5, [x0], #1
        mov     w5, #'t'
        strb    w5, [x0], #1
        b       1b
9:      ret

/*
 * json_find - locate a string value in a JSON document.
 *   x0 = document, x1 = the quoted key, e.g. "\"text\""
 *   out x0 = first byte of the value, or 0
 * A scan, not a parser: it looks for one known key and then steps over the
 * colon, any whitespace, and the opening quote - real encoders differ on
 * spacing, and a matcher that only accepts one of them is a trap.
 */
        .globl  SYM(json_find)
SYM(json_find):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]
        mov     x19, x0
        mov     x20, x1
1:      ldrb    w9, [x19]
        cbz     w9, 8f
        mov     x0, x19
        mov     x1, x20
        bl      SYM(str_starts)
        cbnz    w0, 2f
        add     x19, x19, #1
        b       1b
2:      mov     x0, x20                 /* step over the key */
        bl      SYM(str_len)
        add     x21, x19, w0, uxtw
3:      ldrb    w9, [x21]               /* whitespace, then ':' */
        cmp     w9, #' '
        b.eq    4f
        cmp     w9, #'\t'
        b.eq    4f
        cmp     w9, #'\n'
        b.eq    4f
        cmp     w9, #'\r'
        b.ne    5f
4:      add     x21, x21, #1
        b       3b
5:      cmp     w9, #':'
        b.ne    .Lnext_pos
        add     x21, x21, #1
6:      ldrb    w9, [x21]               /* whitespace, then the open quote */
        cmp     w9, #' '
        b.eq    7f
        cmp     w9, #'\t'
        b.eq    7f
        cmp     w9, #'\n'
        b.eq    7f
        cmp     w9, #'\r'
        b.ne    8f
7:      add     x21, x21, #1
        b       6b
8:      cmp     w9, #'"'
        b.ne    .Lnext_pos
        add     x0, x21, #1
        b       9f
.Lnext_pos:
        add     x19, x19, #1            /* that key was not a string value */
        b       1b
8:      mov     x0, #0
9:      ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * json_unescape - copy a JSON string body from x1 to x0 until the closing
 * quote, undoing escapes.  w2 caps the output.  out w0 = bytes written.
 */
        .globl  SYM(json_unescape)
SYM(json_unescape):
        mov     x3, x0
        add     x4, x0, w2, uxtw
        sub     x4, x4, #2
1:      cmp     x0, x4
        b.hs    9f
        ldrb    w5, [x1], #1
        cbz     w5, 9f
        cmp     w5, #'"'
        b.eq    9f
        cmp     w5, #'\\'
        b.ne    2f
        ldrb    w5, [x1], #1
        cbz     w5, 9f
        cmp     w5, #'n'
        b.ne    3f
        mov     w5, #'\n'
        b       2f
3:      cmp     w5, #'r'
        b.ne    4f
        mov     w5, #'\r'
        b       2f
4:      cmp     w5, #'t'
        b.ne    5f
        mov     w5, #'\t'
        b       2f
5:      cmp     w5, #'u'                /* \uXXXX: emit '?' rather than lie */
        b.ne    2f
        add     x1, x1, #4
        mov     w5, #'?'
2:      strb    w5, [x0], #1
        b       1b
9:      strb    wzr, [x0]
        sub     w0, w0, w3
        ret
