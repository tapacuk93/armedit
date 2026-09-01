#include "asm.inc"
/*
 * localops.S - answering without asking anybody.
 *
 * The editor's first move on Cmd+P used to be a network request, and its
 * behaviour with no network was to say so. That is wrong in a way that got
 * worse as the system got better: by the time an operation has been asked for
 * by enough people, compiled, agreed by several models and shipped inside this
 * binary, the one thing it should not need is a server to tell it what it
 * already knows.
 *
 * So the order is inverted. What is built in is tried first, the network is
 * the fallback rather than the path, and a machine with no link is a machine
 * that has fewer answers rather than none.
 *
 * <h2>What matching means here</h2>
 *
 * The table carries patterns with their types already spent: `colours {}` and
 * `explain {*}`, one word and the rest. The device does not re-check that a
 * word is a colour, because it has no colour table and shipping one would put
 * the same judgement in two places that can disagree. It matches shape, runs
 * the operation, and lets the operation decline - which is what it would have
 * done on the server too, since an operation that does not recognise its
 * argument returns nothing either way.
 *
 * <h2>Declining is a normal answer</h2>
 *
 * An operation that matches and returns nothing has not failed. It has said
 * "not me", and the request continues to the backend exactly as though the
 * table had been empty. That is the difference between a cache and a
 * shortcut: this may answer, and when it does not, nothing about the request
 * has changed.
 */

/*
 * Table records: name, pattern, variable count, code, length.
 *
 * The first, second and fourth are offsets from the table itself rather than
 * addresses - see tools/mkops.py for why - so reading one is a load and an
 * add, and the table stays in read-only memory where a table of entry points
 * belongs.
 *
 * They are signed. Everything they point at is emitted before the table, so
 * every offset is negative, and reading one with an unsigned extend turns a
 * small negative number into four billion - which does not fault, because
 * nothing here dereferences it as a pointer to anything but a string that
 * happens to be a zero byte. The symptom was every operation declining.
 */
#define REC_NAME        0
#define REC_PATTERN     4
#define REC_NVARS       8
#define REC_CODE        12
#define REC_LEN         16
#define REC_SZ          20

#define MAX_VARS        4
#define VAR_SZ          128             /* per captured word, aligned */

        CODE
        .p2align 2

/*
 * localop_run - try the built-in operations against one instruction.
 *
 *   x0 = the instruction, NUL-terminated
 *   x1 = the whole screen
 *   x2 = the subject
 *   x3 = the selection
 *   x4 = output buffer
 *   w5 = its size
 *
 *   out w0 = bytes written, or -1 if nothing here answers
 *
 * The ambient arguments come last and in this order, because that is the order
 * the operation was compiled with: its own variables, then screen, subject,
 * selection. A blob addresses its arguments by index, so this order is not a
 * convention that can be changed later - it is part of what the bytes mean.
 */
        .globl  SYM(localop_run)
SYM(localop_run):
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        str     x27, [sp, #80]

        mov     x19, x0                 /* instruction */
        mov     x20, x1                 /* screen      */
        mov     x21, x2                 /* subject     */
        mov     x22, x3                 /* selection   */
        mov     x23, x4                 /* out         */
        mov     w24, w5                 /* out size    */

        LEA     x9, SYM(ops_builtin_count)
        ldr     x25, [x9]
        cbz     x25, .Lnone
        mov     x26, #0                 /* which record */

.Lnext:
        cmp     x26, x25
        b.hs    .Lnone

        /* The record, recomputed each time round: the calls below eat x9-x15. */
        LEA     x9, SYM(ops_builtin)
        mov     x10, #REC_SZ
        madd    x27, x26, x10, x9

        LEA     x10, SYM(ops_builtin)
        ldrsw   x11, [x27, #REC_PATTERN] /* signed: the strings and the code are
                                            emitted before the table, so every
                                            offset in it is negative */
        add     x0, x10, x11
        mov     x1, x19
        bl      localop_match
        cbz     w0, .Lskip

        /* It matched. Install the code, once, and keep the entry point. */
        mov     x0, x26
        bl      localop_entry
        cbz     x0, .Lskip
        mov     x1, x0                  /* the entry point */

        /* Build the argument vector: captured words, then the ambient three. */
        LEA     x9, localop_values
        LEA     x10, localop_vars
        LEA     x11, SYM(ops_builtin)
        mov     x12, #REC_SZ
        madd    x11, x26, x12, x11
        ldr     w12, [x11, #REC_NVARS]
        mov     x13, #0
1:      cmp     x13, x12
        b.hs    2f
        mov     x14, #VAR_SZ
        madd    x14, x13, x14, x10
        orr     x14, x14, #1            /* tagged as a string; VAR_SZ is even,
                                           so every slot starts on an even byte
                                           and the tag bit is free to set */
        str     x14, [x9, x13, lsl #3]
        add     x13, x13, #1
        b       1b
2:      orr     x14, x20, #1
        str     x14, [x9, x13, lsl #3]
        add     x13, x13, #1
        orr     x14, x21, #1
        str     x14, [x9, x13, lsl #3]
        add     x13, x13, #1
        orr     x14, x22, #1
        str     x14, [x9, x13, lsl #3]

        mov     x0, x1                  /* entry */
        LEA     x1, localop_values
        mov     x2, x23
        mov     w3, w24
        bl      SYM(op_run)
        cmn     w0, #1
        b.eq    .Lskip                  /* it declined */
        cbz     w0, .Lskip              /* an empty answer is also declining */
        b       .Lout

.Lskip:
        add     x26, x26, #1
        b       .Lnext

.Lnone: mov     w0, #-1
.Lout:  ldr     x27, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

/*
 * localop_entry - x0 = record index, out x0 = entry point, or 0.
 *
 * Installing means making pages executable, which is a syscall on a hosted
 * system and a cache maintenance sequence on bare metal - either way not
 * something to redo per keystroke. The result is remembered, so the second
 * "colours blue" costs a table lookup.
 */
localop_entry:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     x19, x0

        LEA     x9, localop_installed
        ldr     x0, [x9, x19, lsl #3]
        cbnz    x0, 9f

        LEA     x9, SYM(ops_builtin)
        mov     x10, #REC_SZ
        madd    x20, x19, x10, x9
        LEA     x9, SYM(ops_builtin)
        ldrsw   x11, [x20, #REC_CODE]
        add     x0, x9, x11
        ldr     w1, [x20, #REC_LEN]
        bl      SYM(op_install)
        LEA     x9, localop_installed   /* after the call, not before it */
        str     x0, [x9, x19, lsl #3]

9:      ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/*
 * localop_match - x0 = pattern, x1 = instruction, out w0 = 1 if it matched.
 *
 * Word by word. A literal must be there, case folded, because people type
 * "Colours Blue" and mean what the pattern says. `{}` takes one word and `{*}`
 * takes the rest, and the rest may not be empty - a pattern ending in {*} that
 * matched an empty tail would match its own literal prefix, and every request
 * beginning with the right word would be answered by the wrong operation.
 *
 * Captured words are copied into localop_vars rather than pointed at, because
 * the operation is handed NUL-terminated strings and the instruction has
 * spaces where those terminators would have to go.
 */
localop_match:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        mov     x19, x0                 /* pattern cursor */
        mov     x20, x1                 /* input cursor   */
        mov     x21, #0                 /* which variable */

.Lm_loop:
        bl      localop_skip_pat
        bl      localop_skip_in
        ldrb    w9, [x19]
        cbz     w9, .Lm_end             /* pattern exhausted */

        /* A variable? */
        cmp     w9, #'{'
        b.ne    .Lm_literal
        ldrb    w9, [x19, #1]
        cmp     w9, #'*'
        b.eq    .Lm_rest

        /* {} - exactly one word. */
        add     x19, x19, #2            /* past "{}" */
        ldrb    w9, [x20]
        cbz     w9, .Lm_no              /* nothing left to bind */
        cmp     x21, #MAX_VARS
        b.hs    .Lm_no
        mov     x22, x20
1:      ldrb    w9, [x20]
        cbz     w9, 2f
        cmp     w9, #' '
        b.ls    2f
        add     x20, x20, #1
        b       1b
2:      sub     x23, x20, x22           /* how long the word was */
        mov     x0, x21
        mov     x1, x22
        mov     x2, x23
        bl      localop_capture
        add     x21, x21, #1
        b       .Lm_loop

.Lm_rest:
        /* {*} - all of it, and there must be some. */
        add     x19, x19, #3            /* past "{*}" */
        ldrb    w9, [x20]
        cbz     w9, .Lm_no
        cmp     x21, #MAX_VARS
        b.hs    .Lm_no
        mov     x0, x21
        mov     x1, x20
        bl      localop_capture_rest
        add     x21, x21, #1
        /* Only a trailing {*} is supported, so the pattern must end here. */
        bl      localop_skip_pat
        ldrb    w9, [x19]
        cbnz    w9, .Lm_no
        b       .Lm_yes

.Lm_literal:
        /* Compare one word of pattern against one word of input, folded. */
1:      ldrb    w9, [x19]
        ldrb    w10, [x20]
        cbz     w9, 3f
        cmp     w9, #' '
        b.ls    3f
        cbz     w10, .Lm_no
        cmp     w10, #' '
        b.ls    .Lm_no
        cmp     w9, #'A'
        b.lo    2f
        cmp     w9, #'Z'
        b.hi    2f
        add     w9, w9, #32
2:      cmp     w10, #'A'
        b.lo    4f
        cmp     w10, #'Z'
        b.hi    4f
        add     w10, w10, #32
4:      cmp     w9, w10
        b.ne    .Lm_no
        add     x19, x19, #1
        add     x20, x20, #1
        b       1b
3:      /* The pattern word ended; the input word must end too. */
        ldrb    w10, [x20]
        cbz     w10, .Lm_loop
        cmp     w10, #' '
        b.hi    .Lm_no
        b       .Lm_loop

.Lm_end:
        /* Pattern done: the input must be done as well. */
        bl      localop_skip_in
        ldrb    w9, [x20]
        cbnz    w9, .Lm_no
.Lm_yes:
        mov     w0, #1
        b       .Lm_out
.Lm_no: mov     w0, #0
.Lm_out:
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * Whitespace is not only the space character.
 *
 * The instruction comes out of the editor as a line of a document, and a line
 * of a document ends in a newline. Matching "colours blue" against "colours
 * blue\n" failed on the last check - pattern exhausted, input not - and the
 * whole offline path silently declined every request. Anything at or below a
 * space separates words; a NUL ends them.
 */
localop_skip_pat:
1:      ldrb    w9, [x19]
        cbz     w9, 9f
        cmp     w9, #' '
        b.hi    9f
        add     x19, x19, #1
        b       1b
9:      ret

localop_skip_in:
1:      ldrb    w9, [x20]
        cbz     w9, 9f
        cmp     w9, #' '
        b.hi    9f
        add     x20, x20, #1
        b       1b
9:      ret

/*
 * localop_capture - x0 = slot, x1 = start, x2 = length.
 *
 * Folded to lower case, because the server binds its variables out of the
 * normalised instruction and an operation compiled against that comparison
 * expects it. "COLOURS Blue" answered on the server and declined here until
 * this did the same thing - and an operation that behaves differently offline
 * is worse than one that does not exist offline, because the difference only
 * shows up when the network is already gone.
 */
localop_capture:
        LEA     x9, localop_vars
        mov     x10, #VAR_SZ
        madd    x9, x0, x10, x9
        mov     x11, #(VAR_SZ - 1)
        cmp     x2, x11
        csel    x2, x2, x11, lo
        mov     x12, #0
1:      cmp     x12, x2
        b.hs    2f
        ldrb    w13, [x1, x12]
        cmp     w13, #'A'
        b.lo    3f
        cmp     w13, #'Z'
        b.hi    3f
        add     w13, w13, #32
3:      strb    w13, [x9, x12]
        add     x12, x12, #1
        b       1b
2:      strb    wzr, [x9, x12]
        ret

/* localop_capture_rest - x0 = slot, x1 = the remainder of the instruction. */
localop_capture_rest:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        mov     x2, #0
1:      ldrb    w9, [x1, x2]
        cbz     w9, 2f
        add     x2, x2, #1
        b       1b
2:      bl      localop_capture
        ldp     x29, x30, [sp], #16
        ret


/*
 * localop_colour - x0 = text, out w0 = a palette slot, or -1.
 *
 * The same directive the backend reads, read here, because an operation that
 * answers offline has to be able to say the same things an operation answering
 * online can. If the device understood #COLOUR only when a server relayed it,
 * every appearance change would quietly stop working the moment the link did.
 */
        .globl  SYM(localop_colour)
SYM(localop_colour):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]
        mov     x19, x0                 /* where we are in the text */

.Lc_scan:
        ldrb    w9, [x19]
        cbz     w9, .Lc_none
        cmp     w9, #'#'
        b.ne    .Lc_next

        add     x20, x19, #1            /* just past the marker */
        mov     x0, x20
        LEA     x1, s_colour
        bl      localop_starts          /* this eats x30, hence the frame */
        cbz     w0, 1f
        add     x21, x20, #6            /* "colour" */
        b       2f
1:      mov     x0, x20
        LEA     x1, s_color
        bl      localop_starts
        cbz     w0, .Lc_next
        add     x21, x20, #5            /* "color" */

2:      ldrb    w9, [x21]               /* a separator has to follow the word,
                                           or "#COLOURFUL" would parse */
        cmp     w9, #' '
        b.hi    .Lc_next
        cbz     w9, .Lc_next
3:      ldrb    w9, [x21]
        cmp     w9, #' '
        b.hi    4f
        cbz     w9, .Lc_next
        add     x21, x21, #1
        b       3b
4:      ldrb    w9, [x21]
        sub     w9, w9, #'0'
        cmp     w9, #9
        b.hi    .Lc_next
        mov     w0, w9
        b       .Lc_out

.Lc_next:
        add     x19, x19, #1
        b       .Lc_scan
.Lc_none:
        mov     w0, #-1
.Lc_out:
        ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * localop_starts - x0 = text, x1 = a lower-case prefix, out w0 = 1 if it fits.
 * A leaf, so it may be called without ceremony - but only by something that
 * has saved its own return address first.
 */
localop_starts:
1:      ldrb    w9, [x1]
        cbz     w9, 8f
        ldrb    w10, [x0]
        cbz     w10, 9f
        cmp     w10, #'A'
        b.lo    2f
        cmp     w10, #'Z'
        b.hi    2f
        add     w10, w10, #32
2:      cmp     w9, w10
        b.ne    9f
        add     x0, x0, #1
        add     x1, x1, #1
        b       1b
8:      mov     w0, #1
        ret
9:      mov     w0, #0
        ret

/*
 * localop_strip - x0 = a buffer, rewritten in place.
 *
 * Drops whole lines that begin with a directive marker. The backend does this
 * on every route out, for a reason it learned the hard way: a directive that
 * survives has not been acted on, and showing it to the person is strictly
 * worse than dropping it. An operation running on the device answers through
 * the same door, so it needs the same doorman.
 */
        .globl  SYM(localop_strip)
SYM(localop_strip):
        mov     x1, x0                  /* read  */
        mov     x2, x0                  /* write */
.Lstrip_line:
        ldrb    w9, [x1]
        cbz     w9, .Lstrip_end
        cmp     w9, #'#'
        b.ne    .Lstrip_keep
        /* A marker only if what follows is two or more capitals. */
        ldrb    w9, [x1, #1]
        cmp     w9, #'A'
        b.lo    .Lstrip_keep
        cmp     w9, #'Z'
        b.hi    .Lstrip_keep
        ldrb    w9, [x1, #2]
        cmp     w9, #'A'
        b.lo    .Lstrip_keep
        cmp     w9, #'Z'
        b.hi    .Lstrip_keep
1:      ldrb    w9, [x1]                /* skip to just past the newline */
        cbz     w9, .Lstrip_end
        add     x1, x1, #1
        cmp     w9, #'\n'
        b.ne    1b
        b       .Lstrip_line
.Lstrip_keep:
1:      ldrb    w9, [x1]
        cbz     w9, .Lstrip_end
        add     x1, x1, #1
        strb    w9, [x2], #1
        cmp     w9, #'\n'
        b.ne    1b
        b       .Lstrip_line
.Lstrip_end:
        strb    wzr, [x2]
        ret

        RODATA
s_colour:   .asciz "colour"
s_color:    .asciz "color"

        BSS
        .p2align 3
localop_installed:  .space (8 * 32)
localop_values:     .space (8 * (MAX_VARS + 3))
        .p2align 3
localop_vars:       .space (VAR_SZ * MAX_VARS)
