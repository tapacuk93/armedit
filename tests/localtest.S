#include "asm.inc"
/*
 * Ask the built-in operations something, from the command line.
 *
 *     localtest "colours blue"        ->  #COLOUR 3
 *     localtest "colours chartreuse"  ->  (declined)
 *     localtest "hello"               ->  (declined)
 *
 * The point is the third case as much as the first. An editor that answers
 * everything locally is one that has stopped asking, and the whole design
 * depends on "not me" being cheap and common.
 */
        CODE
        .p2align 2
        .globl  _main
_main:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     w19, w0
        mov     x20, x1
        mov     x0, x2
        bl      SYM(env_init)
        cmp     w19, #2
        b.lt    .Lfail

/*
 * Learn one at run time before asking anything, so the two tables can be told
 * apart: this pattern is not in the built-in table, and answering it proves
 * the operation arrived rather than shipped.
 */
        LEA     x9, blob
        mov     w10, #0
1:      cmp     w10, #16
        b.hs    2f
        LEA     x11, probe_code
        ldrb    w12, [x11, w10, uxtw]
        strb    w12, [x9, w10, uxtw]
        add     w10, w10, #1
        b       1b
2:      LEA     x0, s_learned_pat
        mov     w1, #0
        LEA     x2, blob
        mov     w3, #16
        bl      SYM(localop_learn)
        LEA     x0, s_learn_ok
        cmn     w0, #1
        b.ne    3f
        LEA     x0, s_learn_no
3:      bl      say

        mov     w21, #1
1:      cmp     w21, w19
        b.hs    .Ldone

        ldr     x0, [x20, w21, uxtw #3]
        bl      say
        LEA     x0, s_arrow
        bl      say

        ldr     x0, [x20, w21, uxtw #3]
        LEA     x1, s_screen            /* a screen, so the ambient argument is
                                           not empty and a wrong index shows */
        LEA     x2, s_empty
        LEA     x3, s_empty
        LEA     x4, outbuf
        mov     w5, #4096
        bl      SYM(localop_run)
        cmn     w0, #1
        b.ne    2f
        LEA     x0, s_declined
        bl      say
        b       3f
2:      LEA     x9, outbuf
        strb    wzr, [x9, w0, uxtw]
        LEA     x0, outbuf
        bl      say
3:      LEA     x0, s_nl
        bl      say
        add     w21, w21, #1
        b       1b

.Ldone: mov     x0, #0
        b       .Lexit
.Lfail: mov     x0, #1
.Lexit: mov     x16, #1
        svc     #0x80

say:    stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x0, [sp, #16]
        bl      SYM(str_len)
        mov     x2, x0
        ldr     x1, [sp, #16]
        mov     x0, #1
        mov     x16, #4
        svc     #0x80
        ldp     x29, x30, [sp], #32
        ret

        RODATA
        .p2align 1
s_arrow:    .asciz "  ->  "
s_declined: .asciz "(declined)"
s_nl:       .asciz "\n"
s_empty:    .asciz ""
s_screen:   .asciz "a document that was already on the screen"
s_learned_pat: .asciz "arrived at runtime"
s_learn_ok:    .asciz "learned an operation at run time\n"
s_learn_no:    .asciz "could not learn at run time\n"
        .p2align 2
/*
 * The smallest operation that answers.
 *
 * op_run hands a blob the values, an output buffer and its size, and expects
 * bytes written back - not a tagged value. A blob that returns 0 has declined,
 * which is a perfectly good answer and a useless test, so this one writes a
 * character and says it wrote one. It exists to prove the runtime table is
 * consulted at all; what it writes does not matter.
 *
 *     mov  w9, #'!'      strb w9, [x1]      mov w0, #1      ret
 */
probe_code:
        .long   0x52800429
        .long   0x39000029
        .long   0x52800020
        .long   0xD65F03C0

        BSS
        .p2align 3
outbuf:     .space 4096
        .p2align 2
blob:       .space 64
