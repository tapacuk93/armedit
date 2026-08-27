#include "asm.inc"
/*
 * html.S - a page becomes text.
 *
 * armedit has one way of showing anything, which is text in a screen, so a
 * web page has to arrive as text or it cannot arrive at all. That is not a
 * limitation worked around here - it is the whole design. A site opened in
 * armedit is a screen like any other: the caret goes into it, Cmd+P rewrites
 * a line of it, a swipe selects words of it. There is no browser mode to
 * leave, because there is no browser mode.
 *
 * What this does is therefore narrow and complete: take the bytes of an HTML
 * document and produce the text a reader would see, plus the links, which
 * become applets so they can be clicked. What it deliberately does not do is
 * CSS, layout, or scripting. A page whose meaning lives in its stylesheet is
 * a page this shows badly, and that is the honest trade for a renderer that
 * fits in a kernel with no allocator.
 *
 * The parser is span-based rather than character-state-based: find a tag's
 * '<' and its matching '>', then decide what the span means. That is less
 * clever than a full tokenizer and much easier to be sure of, which matters
 * for code that parses bytes off the network.
 */

/* One link: where its text landed, how long it is, and where it points. */
#define HL_OFF          0
#define HL_LEN          4
#define HL_HREF         8
#define HL_HREF_MAX     127
#define HL_SZ           144

/* What we do with whitespace we have not committed to yet. */
#define PEND_NONE       0
#define PEND_SPACE      1
#define PEND_BREAK      2

        CODE
        .p2align 2

/*
 * html_render - x0 = document, w1 = its length,
 *               x2 = text out, w3 = capacity,
 *               x4 = link table, w5 = how many links it holds
 *   out w0 = bytes of text produced (always NUL-terminated within capacity)
 *
 * x4 may be null, in which case links are still followed for their text but
 * not recorded.
 */
        .globl  SYM(html_render)
SYM(html_render):
        stp     x29, x30, [sp, #-192]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        stp     x27, x28, [sp, #80]

        mov     x19, x0
        mov     w20, w1
        mov     x21, x2
        mov     w22, w3
        mov     x26, x4
        mov     w27, w5

        mov     w23, #0                 /* bytes written */
        mov     x24, #0                 /* cursor into the document */
        mov     w25, #PEND_NONE         /* low byte pending, next byte the
                                           last character committed - both
                                           live in one register because every
                                           other callee-saved one is spoken
                                           for, and a stack slot would be read
                                           from two different frame depths */
        mov     w28, #0                 /* links recorded */
        mov     w9, #-1
        str     w9, [sp, #112]          /* the link we are inside, if any */

        cbz     w22, .Lhr_done
        sub     w22, w22, #1            /* leave room for the terminator */

.Lhr_scan:
        cmp     x24, w20, uxtw
        b.hs    .Lhr_done
        ldrb    w9, [x19, x24]
        cmp     w9, #'<'
        b.eq    .Lhr_tag

/* ---- ordinary text ----------------------------------------------------- */
        cmp     w9, #' '                /* any control character or space is */
        b.hi    1f                      /* just whitespace as far as we care */
        and     w11, w25, #0xff
        cmp     w11, #PEND_BREAK
        b.eq    0f                      /* a break already pending outranks it */
        mov     w10, #PEND_SPACE
        bfi     w25, w10, #0, #8
0:      add     x24, x24, #1
        b       .Lhr_scan

1:      cmp     w9, #'&'
        b.ne    2f
        bl      .Lhr_entity             /* w9 = the character it stood for */
        cbz     w9, .Lhr_scan
        b       3f
2:      add     x24, x24, #1
3:      mov     w0, w9
        bl      .Lhr_put
        b       .Lhr_scan

/* ---- a tag ------------------------------------------------------------- */
.Lhr_tag:
        add     x9, x24, #1             /* comments and declarations */
        cmp     x9, w20, uxtw
        b.hs    .Lhr_done
        ldrb    w10, [x19, x9]
        cmp     w10, #'!'
        b.eq    .Lhr_decl
        cmp     w10, #'?'
        b.eq    .Lhr_decl

        add     x9, x19, x24            /* the tag begins here - as a pointer, */
        str     x9, [sp, #120]          /* because the attribute scanner walks
                                           it directly rather than by index */
        bl      .Lhr_tagend             /* x24 -> just past its '>' */
        add     x9, x19, x24
        str     x9, [sp, #128]

        ldr     x0, [sp, #120]
        add     x0, x0, #1
        ldrb    w9, [x0]
        cmp     w9, #'/'
        cset    w10, eq                 /* closing? */
        str     w10, [sp, #136]
        add     x0, x0, w10, uxtw

        add     x1, sp, #96             /* the name, folded to lower case */
        mov     w2, #0
1:      cmp     w2, #15
        b.hs    2f
        ldrb    w9, [x0, w2, uxtw]
        cbz     w9, 2f
        cmp     w9, #' '
        b.ls    2f
        cmp     w9, #'>'
        b.eq    2f
        cmp     w9, #'/'
        b.eq    2f
        cmp     w9, #'A'
        b.lo    3f
        cmp     w9, #'Z'
        b.hi    3f
        add     w9, w9, #32
3:      strb    w9, [x1, w2, uxtw]
        add     w2, w2, #1
        b       1b
2:      strb    wzr, [x1, w2, uxtw]
        cbz     w2, .Lhr_scan           /* "<>" - nothing to do */

        add     x0, sp, #96             /* script and style are not content */
        LEA     x1, s_script
        bl      SYM(str_eq)
        cbnz    w0, .Lhr_skipbody
        add     x0, sp, #96
        LEA     x1, s_style
        bl      SYM(str_eq)
        cbnz    w0, .Lhr_skipbody

        add     x0, sp, #96             /* <a> opens or closes a link */
        LEA     x1, s_a
        bl      SYM(str_eq)
        cbnz    w0, .Lhr_anchor

        add     x0, sp, #96             /* <br> is a break wherever it is */
        LEA     x1, s_br
        bl      SYM(str_eq)
        cbnz    w0, .Lhr_break

        add     x0, sp, #96             /* everything else: block or inline */
        bl      .Lhr_isblock
        cbz     w0, .Lhr_scan
.Lhr_break:
        mov     w10, #PEND_BREAK
        bfi     w25, w10, #0, #8
        b       .Lhr_scan

.Lhr_decl:
        add     x24, x24, #1            /* to the next '>', quotes and all */
1:      cmp     x24, w20, uxtw
        b.hs    .Lhr_done
        ldrb    w9, [x19, x24]
        add     x24, x24, #1
        cmp     w9, #'>'
        b.ne    1b
        b       .Lhr_scan

/*
 * Skipping a script or a style means skipping to its closing tag, not to the
 * next '<': script bodies are full of '<' that are not tags at all.
 */
.Lhr_skipbody:
        ldr     w9, [sp, #136]
        cbnz    w9, .Lhr_scan           /* it was the closing tag already */
1:      cmp     x24, w20, uxtw
        b.hs    .Lhr_done
        ldrb    w9, [x19, x24]
        cmp     w9, #'<'
        b.ne    2f
        add     x9, x24, #1
        cmp     x9, w20, uxtw
        b.hs    .Lhr_done
        ldrb    w10, [x19, x9]
        cmp     w10, #'/'
        b.ne    2f
        add     x0, x19, x24
        add     x1, sp, #96
        bl      .Lhr_closes             /* is this "</name"? */
        cbz     w0, 2f
        bl      .Lhr_tagend
        mov     w10, #PEND_BREAK
        bfi     w25, w10, #0, #8
        b       .Lhr_scan
2:      add     x24, x24, #1
        b       1b

/* ---- <a> ---------------------------------------------------------------- */
.Lhr_anchor:
        ldr     w9, [sp, #136]
        cbnz    w9, .Lhr_aclose

        cbz     x26, .Lhr_scan          /* nobody is collecting links */
        cmp     w28, w27
        b.hs    .Lhr_scan               /* the table is full */
        bl      .Lhr_flush              /* the link starts at the next real
                                           character, not before the space */
        mov     w9, #HL_SZ
        mul     w9, w28, w9
        add     x9, x26, w9, uxtw
        str     w23, [x9, #HL_OFF]
        str     wzr, [x9, #HL_LEN]
        strb    wzr, [x9, #HL_HREF]
        str     w28, [sp, #112]

        ldr     x0, [sp, #120]          /* pull href out of the tag span */
        ldr     x1, [sp, #128]
        add     x2, x9, #HL_HREF
        mov     w3, #HL_HREF_MAX
        bl      .Lhr_href
        b       .Lhr_scan

.Lhr_aclose:
        ldr     w9, [sp, #112]
        cmn     w9, #1
        b.eq    .Lhr_scan
        mov     w10, #-1
        str     w10, [sp, #112]
        mov     w10, #HL_SZ
        mul     w10, w9, w10
        add     x10, x26, w10, uxtw
        ldr     w11, [x10, #HL_OFF]
        sub     w11, w23, w11           /* how much text it covered */
        str     w11, [x10, #HL_LEN]
        cbz     w11, .Lhr_scan          /* an empty link is not a link */
        ldrb    w11, [x10, #HL_HREF]
        cbz     w11, .Lhr_scan          /* nor is one that points nowhere */
        add     w28, w28, #1
        b       .Lhr_scan

.Lhr_done:
        bl      .Lhr_flush
        strb    wzr, [x21, w23, uxtw]
        mov     w0, w23
        LEA     x9, html_links
        str     w28, [x9]
        ldp     x27, x28, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #192
        ret

/*
 * .Lhr_put - commit one character, settling the pending whitespace first.
 * Leading whitespace is dropped and runs of blank lines collapse to one,
 * because a page's indentation is not information a reader wants.
 */
.Lhr_put:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     w0, [sp, #24]
        bl      .Lhr_flush
        ldr     w0, [sp, #24]
        cmp     w23, w22
        b.hs    1f
        strb    w0, [x21, w23, uxtw]
        add     w23, w23, #1
        bfi     w25, w0, #8, #8         /* remember it, for the collapser */
1:      ldp     x29, x30, [sp], #32
        ret

/*
 * .Lhr_flush - turn pending whitespace into an actual space or newline.
 * Touches no memory but the output, so it is safe to call from any depth.
 */
.Lhr_flush:
        and     w10, w25, #0xff
        cmp     w10, #PEND_NONE
        b.eq    9f
        cbz     w23, 8f                 /* never at the very beginning */
        cmp     w23, w22
        b.hs    8f
        ubfx    w9, w25, #8, #8         /* what went out last */
        cmp     w10, #PEND_BREAK
        b.ne    2f
        cmp     w9, #'\n'
        b.eq    8f                      /* one blank line is enough */
        mov     w9, #'\n'
        b       3f
2:      cmp     w9, #'\n'
        b.eq    8f                      /* no space after a line break */
        mov     w9, #' '
3:      strb    w9, [x21, w23, uxtw]
        add     w23, w23, #1
        bfi     w25, w9, #8, #8
8:      and     w25, w25, #0xffffff00
9:      ret

/*
 * .Lhr_tagend - advance x24 past the '>' that closes the tag it points at,
 * ignoring any '>' that sits inside a quoted attribute value.
 */
.Lhr_tagend:
        add     x24, x24, #1
        mov     w11, #0                 /* the quote we are inside, if any */
1:      cmp     x24, w20, uxtw
        b.hs    9f
        ldrb    w9, [x19, x24]
        add     x24, x24, #1
        cbz     w11, 2f
        cmp     w9, w11
        b.ne    1b
        mov     w11, #0
        b       1b
2:      cmp     w9, #'"'
        b.eq    3f
        cmp     w9, #'\''
        b.eq    3f
        cmp     w9, #'>'
        b.eq    9f
        b       1b
3:      mov     w11, w9
        b       1b
9:      ret

/*
 * .Lhr_closes - x0 points at "</...", x1 at a lowercased name.
 *   out w0 = 1 when this is that name's closing tag.
 */
.Lhr_closes:
        add     x0, x0, #2
        mov     w2, #0
1:      ldrb    w3, [x1, w2, uxtw]
        cbz     w3, 2f
        ldrb    w4, [x0, w2, uxtw]
        cmp     w4, #'A'
        b.lo    3f
        cmp     w4, #'Z'
        b.hi    3f
        add     w4, w4, #32
3:      cmp     w3, w4
        b.ne    8f
        add     w2, w2, #1
        b       1b
2:      ldrb    w4, [x0, w2, uxtw]      /* the name must end here */
        cmp     w4, #'>'
        b.eq    9f
        cmp     w4, #' '
        b.ls    9f
8:      mov     w0, #0
        ret
9:      mov     w0, #1
        ret

/*
 * .Lhr_href - x0 = start of the tag, x1 = one past its end,
 *             x2 = where to put it, w3 = room there.
 * Finds href= and copies the value, quoted or bare.
 */
.Lhr_href:
        strb    wzr, [x2]
1:      add     x9, x0, #4
        cmp     x9, x1
        b.hs    9f
        ldrb    w9, [x0]
        cmp     w9, #'h'
        b.eq    2f
        cmp     w9, #'H'
        b.ne    3f
2:      ldrb    w9, [x0, #1]
        orr     w9, w9, #32
        cmp     w9, #'r'
        b.ne    3f
        ldrb    w9, [x0, #2]
        orr     w9, w9, #32
        cmp     w9, #'e'
        b.ne    3f
        ldrb    w9, [x0, #3]
        orr     w9, w9, #32
        cmp     w9, #'f'
        b.ne    3f
        ldrb    w9, [x0, #4]            /* href= or href = */
        add     x0, x0, #4
4:      cmp     x0, x1
        b.hs    9f
        ldrb    w9, [x0]
        cmp     w9, #' '
        b.ls    5f
        cmp     w9, #'='
        b.eq    6f
        b       3f                      /* "hrefsomething" - not our attribute */
5:      add     x0, x0, #1
        b       4b
6:      add     x0, x0, #1
7:      cmp     x0, x1                  /* skip space after '=' */
        b.hs    9f
        ldrb    w9, [x0]
        cmp     w9, #' '
        b.hi    8f
        add     x0, x0, #1
        b       7b
8:      mov     w10, #0                 /* the quote, if it is quoted */
        cmp     w9, #'"'
        b.eq    10f
        cmp     w9, #'\''
        b.ne    11f
10:     mov     w10, w9
        add     x0, x0, #1
11:     mov     w4, #0
12:     cmp     x0, x1
        b.hs    13f
        cmp     w4, w3
        b.hs    13f
        ldrb    w9, [x0]
        cbz     w10, 14f
        cmp     w9, w10
        b.eq    13f
        b       15f
14:     cmp     w9, #' '
        b.ls    13f
        cmp     w9, #'>'
        b.eq    13f
15:     strb    w9, [x2, w4, uxtw]
        add     w4, w4, #1
        add     x0, x0, #1
        b       12b
13:     strb    wzr, [x2, w4, uxtw]
        ret
3:      add     x0, x0, #1
        b       1b
9:      ret

/*
 * .Lhr_entity - x24 points at '&'. Produces the character in w9 and steps
 * x24 past the reference. An '&' that begins nothing recognised is just an
 * ampersand, which is what most of them are in practice.
 */
.Lhr_entity:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        add     x9, x24, #1
        mov     w10, #0                 /* how many name characters */
        add     x11, sp, #32
1:      cmp     w10, #10
        b.hs    2f
        cmp     x9, w20, uxtw
        b.hs    2f
        ldrb    w12, [x19, x9]
        cmp     w12, #';'
        b.eq    3f
        cmp     w12, #'a'
        b.lo    4f
        cmp     w12, #'z'
        b.ls    5f
4:      cmp     w12, #'A'
        b.lo    6f
        cmp     w12, #'Z'
        b.ls    5f
6:      cmp     w12, #'0'
        b.lo    7f
        cmp     w12, #'9'
        b.ls    5f
7:      cmp     w12, #'#'
        b.ne    2f
5:      strb    w12, [x11, w10, uxtw]
        add     w10, w10, #1
        add     x9, x9, #1
        b       1b
2:      mov     w9, #'&'                /* no ';' - a bare ampersand */
        add     x24, x24, #1
        b       .Lhr_ent_out
3:      strb    wzr, [x11, w10, uxtw]
        cbz     w10, 2b
        add     x24, x9, #1             /* past the ';' */

        ldrb    w12, [x11]
        cmp     w12, #'#'
        b.ne    .Lhr_ent_name

        add     x0, x11, #1             /* &#38; or &#x26; */
        ldrb    w12, [x0]
        orr     w13, w12, #32
        cmp     w13, #'x'
        b.ne    8f
        add     x0, x0, #1
        mov     w14, #0
9:      ldrb    w12, [x0], #1
        cbz     w12, 10f
        orr     w13, w12, #32
        cmp     w13, #'a'
        b.lo    11f
        cmp     w13, #'f'
        b.hi    10f
        sub     w12, w13, #('a' - 10)
        b       12f
11:     sub     w12, w12, #'0'
        cmp     w12, #9
        b.hi    10f
12:     lsl     w14, w14, #4
        add     w14, w14, w12
        b       9b
8:      mov     w14, #0
13:     ldrb    w12, [x0], #1
        cbz     w12, 10f
        sub     w12, w12, #'0'
        cmp     w12, #9
        b.hi    10f
        mov     w15, #10
        mul     w14, w14, w15
        add     w14, w14, w12
        b       13b
10:     mov     w9, w14
        cmp     w9, #0x7F               /* we have no glyphs past ASCII; a */
        b.ls    .Lhr_ent_out            /* placeholder beats a broken byte */
        mov     w9, #'?'
        cbnz    w14, .Lhr_ent_out
        mov     w9, #'&'
        b       .Lhr_ent_out

.Lhr_ent_name:
        LEA     x13, ent_names
        str     x13, [sp, #48]          /* str_eq may clobber x13 */
1:      ldr     x13, [sp, #48]
        ldrb    w12, [x13]
        cbz     w12, 2f                 /* end of the table */
        add     x0, sp, #32
        mov     x1, x13
        bl      SYM(str_eq)
        cbnz    w0, 3f
        ldr     x0, [sp, #48]           /* step over the name and its value */
        bl      SYM(str_len)
        ldr     x13, [sp, #48]
        add     x13, x13, w0, uxtw
        add     x13, x13, #2
        str     x13, [sp, #48]
        b       1b
3:      ldr     x0, [sp, #48]
        bl      SYM(str_len)
        ldr     x13, [sp, #48]
        add     x13, x13, w0, uxtw
        ldrb    w9, [x13, #1]
        b       .Lhr_ent_out
2:      mov     w9, #'?'
.Lhr_ent_out:
        ldp     x29, x30, [sp], #64
        ret

/*
 * .Lhr_isblock - x0 = a lowercased tag name, out w0 = 1 if it breaks the line.
 * Inline tags (b, i, span, em, strong, code, a, img) are absent on purpose:
 * breaking on those would shred every sentence that contains emphasis.
 */
.Lhr_isblock:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        str     x0, [sp, #24]           /* the name we are asking about */
        LEA     x9, block_tags
        str     x9, [sp, #32]           /* where we are in the table */
1:      ldr     x9, [sp, #32]
        ldrb    w10, [x9]
        cbz     w10, 8f
        ldr     x0, [sp, #24]
        mov     x1, x9
        bl      SYM(str_eq)
        cbnz    w0, 9f
        ldr     x0, [sp, #32]
        bl      SYM(str_len)
        ldr     x9, [sp, #32]
        add     x9, x9, w0, uxtw
        add     x9, x9, #1
        str     x9, [sp, #32]
        b       1b
8:      mov     w0, #0
        ldp     x29, x30, [sp], #48
        ret
9:      mov     w0, #1
        ldp     x29, x30, [sp], #48
        ret

/* html_link_count - how many links the last render found */
        .globl  SYM(html_link_count)
SYM(html_link_count):
        LEA     x9, html_links
        ldr     w0, [x9]
        ret

        RODATA
        .p2align 3
s_script:   .asciz "script"
s_style:    .asciz "style"
s_a:        .asciz "a"
s_br:       .asciz "br"

/*
 * Names and the single character each stands for, back to back, ending with
 * an empty name. Only the ones that actually appear in prose are here.
 */
ent_names:
        .asciz "amp"
        .byte '&'
        .asciz "lt"
        .byte '<'
        .asciz "gt"
        .byte '>'
        .asciz "quot"
        .byte '"'
        .asciz "apos"
        .byte '\''
        .asciz "nbsp"
        .byte ' '
        .asciz "ndash"
        .byte '-'
        .asciz "mdash"
        .byte '-'
        .asciz "hellip"
        .byte '.'
        .asciz "middot"
        .byte '.'
        .asciz "bull"
        .byte '*'
        .asciz "copy"
        .byte 'C'
        .asciz "reg"
        .byte 'R'
        .asciz "trade"
        .byte 'T'
        .asciz "rsquo"
        .byte '\''
        .asciz "lsquo"
        .byte '\''
        .asciz "rdquo"
        .byte '"'
        .asciz "ldquo"
        .byte '"'
        .byte 0

block_tags:
        .asciz "p"
        .asciz "div"
        .asciz "h1"
        .asciz "h2"
        .asciz "h3"
        .asciz "h4"
        .asciz "h5"
        .asciz "h6"
        .asciz "li"
        .asciz "ul"
        .asciz "ol"
        .asciz "dl"
        .asciz "dt"
        .asciz "dd"
        .asciz "tr"
        .asciz "td"
        .asciz "th"
        .asciz "table"
        .asciz "thead"
        .asciz "tbody"
        .asciz "section"
        .asciz "article"
        .asciz "header"
        .asciz "footer"
        .asciz "nav"
        .asciz "main"
        .asciz "aside"
        .asciz "blockquote"
        .asciz "pre"
        .asciz "form"
        .asciz "hr"
        .asciz "body"
        .asciz "html"
        .asciz "head"
        .asciz "title"
        .asciz "figure"
        .asciz "figcaption"
        .asciz "option"
        .asciz "label"
        .asciz "fieldset"
        .byte 0

        BSS
        .p2align 2
html_links: .space 4
