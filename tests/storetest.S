#include "asm.inc"
/*
 * The document, saved and loaded, on the host - and in the format the booted
 * machine reads.
 *
 * The point of this test is not that a file can be written. It is that the app
 * and the boot hold the same document: store.S is one piece of code with two
 * backings, and this exercises the hosted one and then leaves the file behind
 * for the build to check byte for byte against the layout kernel/store.S
 * writes to a disk. If those ever diverge, a document typed on the phone stops
 * being one the machine can open, and nothing else would say so.
 */
        CODE
        .p2align 2
        .globl  _main
_main:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     w19, #0                 /* failures */
        mov     w20, w0                 /* argc: an argument means the second
                                           case, which needs its own home */
        mov     x0, x2
        bl      SYM(env_init)
        cmp     w20, #1
        b.hi    .Lstranger

        bl      SYM(store_dev_ready)
        cmp     w0, #1
        LEA     x0, t_ready
        mov     x2, x0
        mov     x0, #1
        mov     x1, #1
        bl      expect_eq

/* ---- what is typed is what comes back ---- */
        bl      SYM(editor_init)
        LEA     x0, s_doc
        bl      SYM(editor_insert_str)
        bl      SYM(store_save)
        cmn     w0, #1
        LEA     x0, t_saved
        bl      expect_ne

        bl      SYM(editor_init)        /* an empty machine, as after a boot */
        bl      SYM(editor_length)
        mov     x1, #0
        mov     x2, x0
        LEA     x0, t_empty
        mov     x3, x0
        mov     x0, x2
        mov     x2, x3
        bl      expect_eq

        bl      SYM(store_load)
        mov     w20, w0
        mov     x0, x20
        mov     x1, #43                 /* the document below, in characters */
        LEA     x2, t_length
        bl      expect_eq

        mov     w0, #0
        mov     w1, w20
        LEA     x2, back
        mov     w3, #512
        bl      SYM(editor_range_text)
        LEA     x0, back
        LEA     x1, s_doc
        bl      SYM(str_eq)
        cmp     w0, #0
        LEA     x0, t_same
        bl      expect_ne

        b       .Ldone

/*
 * A file this did not write is not read as a document.
 *
 * Run as a second process with a different home rather than by changing this
 * one's: the path is worked out from the environment once and the environment
 * is not something a program changes underneath itself. Two homes, two runs,
 * which is also how the two cases would actually happen.
 */
.Lstranger:
        bl      SYM(editor_init)
        bl      SYM(store_load)
        cmn     w0, #1
        LEA     x0, t_stranger
        bl      expect_eq_flag

.Ldone:
        LEA     x0, s_done
        bl      say
        mov     w0, w19
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/* expect_eq - x0, x1 = what and what it should be, x2 = the line to print. */
expect_eq:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        stp     x20, x21, [sp, #16]
        mov     x20, x0
        mov     x21, x1
        mov     x0, x2
        bl      say
        cmp     x20, x21
        b.eq    1f
        LEA     x0, s_fail
        add     w19, w19, #1
        b       2f
1:      LEA     x0, s_ok
2:      bl      say
        ldp     x20, x21, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/* expect_ne - the flags are set; report ok when they are not equal. */
expect_ne:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        b.eq    1f
        bl      say
        LEA     x0, s_ok
        b       2f
1:      bl      say
        LEA     x0, s_fail
        add     w19, w19, #1
2:      bl      say
        ldp     x29, x30, [sp], #16
        ret

/* expect_eq_flag - the flags are set; report ok when they are equal. */
expect_eq_flag:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        b.ne    1f
        bl      say
        LEA     x0, s_ok
        b       2f
1:      bl      say
        LEA     x0, s_fail
        add     w19, w19, #1
2:      bl      say
        ldp     x29, x30, [sp], #16
        ret

#define SYS_WRITE       4
say:    stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        mov     x1, x0
        mov     w2, #0
1:      ldrb    w9, [x1, w2, uxtw]
        cbz     w9, 2f
        add     w2, w2, #1
        b       1b
2:      mov     x0, #1
        mov     x16, #SYS_WRITE
        svc     #0x80
        ldp     x29, x30, [sp], #32
        ret

        RODATA
s_doc:    .asciz "the same document, whichever way it started"
t_ready:    .asciz "  there is somewhere to keep a document                    "
t_saved:    .asciz "  ...it is written                                         "
t_empty:    .asciz "  ...a fresh editor has nothing in it                      "
t_length:   .asciz "  ...and reading it back gives every byte                  "
t_same:     .asciz "  ...the same bytes, in the same order                     "
t_stranger: .asciz "  a file this did not write is not read as a document      "
s_done:     .asciz "\n"
s_ok:       .asciz "ok\n"
s_fail:     .asciz "FAIL\n"

        BSS
        .p2align 3
back:   .space 512
