#include "asm.inc"
/*
 * str.S - the string and JSON primitives everything else is built from.
 *
 * There is no libc in this project, on either target, so this is where
 * strlen/strcpy/itoa live.  The JSON helpers are deliberately small: enough to
 * build a Messages API request and pull one string field back out of the
 * reply, and no more.
 */
        RODATA
b64_alphabet:
        .ascii  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

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
 * str_find - plain substring search.  out x0 = just past the match, or 0.
 * Used on XML replies, where case is meaningful.
 */
        .globl  SYM(str_find)
SYM(str_find):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
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
2:      mov     x0, x20
        bl      SYM(str_len)
        add     x0, x19, w0, uxtw
        b       9f
8:      mov     x0, #0
9:      ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * base64_encode - x0 = input, w1 = length, x2 = output (NUL-terminated).
 * EC2 takes instance user-data base64-encoded, which is the only reason this
 * exists.  out w0 = output length.
 */
        .globl  SYM(base64_encode)
SYM(base64_encode):
        LEA     x3, b64_alphabet
        mov     w4, #0                  /* input index  */
        mov     w5, #0                  /* output index */
1:      sub     w6, w1, w4
        cmp     w6, #0
        b.le    9f
        ldrb    w7, [x0, w4, uxtw]      /* byte 0 */
        lsr     w9, w7, #2
        ldrb    w10, [x3, w9, uxtw]
        strb    w10, [x2, w5, uxtw]
        add     w5, w5, #1
        and     w9, w7, #3
        lsl     w9, w9, #4
        cmp     w6, #1
        b.le    2f
        add     w11, w4, #1
        ldrb    w7, [x0, w11, uxtw]     /* byte 1 */
        lsr     w12, w7, #4
        orr     w9, w9, w12
        ldrb    w10, [x3, w9, uxtw]
        strb    w10, [x2, w5, uxtw]
        add     w5, w5, #1
        and     w9, w7, #0xF
        lsl     w9, w9, #2
        cmp     w6, #2
        b.le    3f
        add     w11, w4, #2
        ldrb    w7, [x0, w11, uxtw]     /* byte 2 */
        lsr     w12, w7, #6
        orr     w9, w9, w12
        ldrb    w10, [x3, w9, uxtw]
        strb    w10, [x2, w5, uxtw]
        add     w5, w5, #1
        and     w9, w7, #0x3F
        ldrb    w10, [x3, w9, uxtw]
        strb    w10, [x2, w5, uxtw]
        add     w5, w5, #1
        add     w4, w4, #3
        b       1b
2:      ldrb    w10, [x3, w9, uxtw]     /* one byte left: xx== */
        strb    w10, [x2, w5, uxtw]
        add     w5, w5, #1
        mov     w10, #'='
        strb    w10, [x2, w5, uxtw]
        add     w5, w5, #1
        strb    w10, [x2, w5, uxtw]
        add     w5, w5, #1
        b       9f
3:      ldrb    w10, [x3, w9, uxtw]     /* two bytes left: xxx= */
        strb    w10, [x2, w5, uxtw]
        add     w5, w5, #1
        mov     w10, #'='
        strb    w10, [x2, w5, uxtw]
        add     w5, w5, #1
9:      strb    wzr, [x2, w5, uxtw]
        mov     w0, w5
        ret

/*
 * str_redact - copy x1 to x0, keeping private lines out of it.
 *   x0 = destination, x1 = source, w2 = capacity; out w0 = bytes written
 *
 * A line beginning with $$name is a definition: the name is a reference and
 * the rest of the line is its content.  The name goes out, the content does
 * not.  So
 *
 *     $$apikey sk-live-8f3a...
 *
 * leaves here as
 *
 *     $$apikey
 *
 * which tells the far side that the thing exists and belongs on that line,
 * and nothing whatever about what it is.  References used inline elsewhere in
 * the text are already only names, so they pass through untouched.
 *
 * This runs on the device, before anything is sent.  That is the whole point:
 * a rule enforced at the other end is a promise, and a promise is not a
 * mechanism.
 */
        .globl  SYM(str_redact)
SYM(str_redact):
        mov     x3, x0                  /* where we started */
        sub     w2, w2, #1              /* room for the NUL */
        mov     w4, #0                  /* bytes written */

.Lline:
        ldrb    w5, [x1]
        cbz     w5, .Lred_done

        ldrb    w6, [x1, #1]            /* does this line open with "$$"? */
        cmp     w5, #'$'
        b.ne    .Lcopy_line
        cmp     w6, #'$'
        b.ne    .Lcopy_line

        /* Copy the reference itself: "$$" and the name that follows. */
        cmp     w4, w2
        b.hs    .Lred_done
        strb    w5, [x0, w4, uxtw]
        add     w4, w4, #1
        cmp     w4, w2
        b.hs    .Lred_done
        strb    w6, [x0, w4, uxtw]
        add     w4, w4, #1
        add     x1, x1, #2
1:      ldrb    w5, [x1]
        cbz     w5, .Lred_done
        cmp     w5, #'\n'
        b.eq    .Lred_eol
        sub     w6, w5, #'0'            /* names are letters, digits and _ */
        cmp     w6, #9
        b.ls    2f
        orr     w6, w5, #0x20
        sub     w6, w6, #'a'
        cmp     w6, #25
        b.ls    2f
        cmp     w5, #'_'
        b.ne    .Lskip_rest             /* the name ended: drop the content */
2:      cmp     w4, w2
        b.hs    .Lred_done
        strb    w5, [x0, w4, uxtw]
        add     w4, w4, #1
        add     x1, x1, #1
        b       1b

.Lskip_rest:                            /* everything up to the newline goes */
        ldrb    w5, [x1]
        cbz     w5, .Lred_done
        cmp     w5, #'\n'
        b.eq    .Lred_eol
        add     x1, x1, #1
        b       .Lskip_rest

.Lred_eol:
        cmp     w4, w2
        b.hs    .Lred_done
        mov     w5, #'\n'
        strb    w5, [x0, w4, uxtw]
        add     w4, w4, #1
        add     x1, x1, #1
        b       .Lline

.Lcopy_line:                            /* an ordinary line, as it stands */
        ldrb    w5, [x1]
        cbz     w5, .Lred_done
        cmp     w4, w2
        b.hs    .Lred_done
        strb    w5, [x0, w4, uxtw]
        add     w4, w4, #1
        add     x1, x1, #1
        cmp     w5, #'\n'
        b.eq    .Lline
        b       .Lcopy_line

.Lred_done:
        strb    wzr, [x0, w4, uxtw]
        mov     w0, w4
        ret

/*
 * str_to_u32 - read a decimal number from x0, out w0 (0 if there is none).
 */
        .globl  SYM(str_to_u32)
SYM(str_to_u32):
        mov     w1, #0
1:      ldrb    w2, [x0], #1
        sub     w3, w2, #'0'
        cmp     w3, #9
        b.hi    2f
        mov     w4, #10
        mul     w1, w1, w4
        add     w1, w1, w3
        b       1b
2:      mov     w0, w1
        ret

/*
 * str_find_ci - case-insensitive search for x1 (which must already be
 * lowercase) inside x0.  out x0 = just past the match, or 0.
 * HTTP header names arrive in whatever case the client felt like using.
 */
        .globl  SYM(str_find_ci)
SYM(str_find_ci):
        mov     x2, x0
1:      ldrb    w3, [x2]
        cbz     w3, 8f
        mov     x4, x2
        mov     x5, x1
2:      ldrb    w6, [x5], #1
        cbz     w6, 7f                  /* needle exhausted: matched */
        ldrb    w3, [x4], #1
        cbz     w3, 8f
        sub     w7, w3, #'A'            /* fold the haystack byte down */
        cmp     w7, #25
        b.hi    3f
        add     w3, w3, #32
3:      cmp     w3, w6
        b.ne    4f
        b       2b
4:      add     x2, x2, #1
        b       1b
7:      mov     x0, x4
        ret
8:      mov     x0, #0
        ret

/*
 * json_find - locate a string value in a JSON document.
 *   x0 = document, x1 = the quoted key, e.g. "\"text\""
 *   out x0 = first byte of the value, or 0
 * A scan, not a parser: it looks for one known key and then steps over the
 * colon, any whitespace, and the opening quote - real encoders differ on
 * spacing, and a matcher that only accepts one of them is a trap.
 */
/*
 * json_find     - x0 = document, x1 = quoted key; out x0 = first byte of the
 *                 string value, or 0.
 * json_find_num - the same, for a number: out x0 = its first digit, or 0.
 * Both are the one scanner below, differing only in what they accept after
 * the colon, so a key whose value is the wrong shape is skipped rather than
 * misread.
 */
        .globl  SYM(json_find)
SYM(json_find):
        mov     w2, #0
        b       json_scan

        .globl  SYM(json_find_num)
SYM(json_find_num):
        mov     w2, #1
        b       json_scan

json_scan:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0
        mov     x20, x1
        mov     w22, w2                 /* 0 = want a string, 1 = want a number */
.Lscan:
        ldrb    w9, [x19]
        cbz     w9, .Lmissing           /* end of document */
        mov     x0, x19
        mov     x1, x20
        bl      SYM(str_starts)
        cbnz    w0, .Lat_key
        add     x19, x19, #1
        b       .Lscan
.Lat_key:
        mov     x0, x20                 /* step over the key */
        bl      SYM(str_len)
        add     x21, x19, w0, uxtw
.Lpre_colon:
        ldrb    w9, [x21]
        cmp     w9, #' '
        b.eq    .Lskip1
        cmp     w9, #'\t'
        b.eq    .Lskip1
        cmp     w9, #'\n'
        b.eq    .Lskip1
        cmp     w9, #'\r'
        b.ne    .Lcolon
.Lskip1:
        add     x21, x21, #1
        b       .Lpre_colon
.Lcolon:
        cmp     w9, #':'
        b.ne    .Lnext_pos
        add     x21, x21, #1
.Lpre_quote:
        ldrb    w9, [x21]
        cmp     w9, #' '
        b.eq    .Lskip2
        cmp     w9, #'\t'
        b.eq    .Lskip2
        cmp     w9, #'\n'
        b.eq    .Lskip2
        cmp     w9, #'\r'
        b.ne    .Lquote
.Lskip2:
        add     x21, x21, #1
        b       .Lpre_quote
.Lquote:
        cbz     w22, 1f
        sub     w10, w9, #'0'           /* a number starts here, or it is not
                                           the key we are looking for */
        cmp     w10, #9
        b.hi    .Lnext_pos
        mov     x0, x21
        b       .Lfind_out
1:      cmp     w9, #'"'
        b.ne    .Lnext_pos
        add     x0, x21, #1
        b       .Lfind_out
.Lnext_pos:
        add     x19, x19, #1            /* that key was not a string value */
        b       .Lscan
.Lmissing:
        mov     x0, #0
.Lfind_out:
        ldp     x21, x22, [sp, #32]
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
