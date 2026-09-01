#include "asm.inc"
/* Load a blob from argv[1], run it on the remaining arguments, print. */
#define ARGS 8
        CODE
        .p2align 2
        .globl  _main
_main:
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        mov     w19, w0
        mov     x20, x1
        mov     x0, x2
        bl      SYM(env_init)
        cmp     w19, #3
        b.lt    .Lfail

        ldr     x0, [x20, #8]           /* the blob */
        mov     x1, #0
        mov     x2, #0
        mov     x16, #5
        svc     #0x80
        b.cs    .Lfail
        mov     x21, x0
        LEA     x1, blob
        mov     x2, #65536
        mov     x0, x21
        mov     x16, #3
        svc     #0x80
        b.cs    .Lfail
        mov     w22, w0
        mov     x0, x21
        mov     x16, #6
        svc     #0x80

        LEA     x0, blob
        mov     w1, w22
        bl      SYM(op_install)
        cbz     x0, .Lfail
        mov     x21, x0                 /* where it lives now */

/*
 * Every argument after the blob is one operand, in the order the operation was
 * compiled with: its own variables first, then screen, subject, selection.
 * Slots the caller left off are empty strings rather than zero - a compiled op
 * dereferences what it is handed, and an absent argument is "" here just as it
 * is on the server.
 */
        LEA     x0, s_tagenv            /* JS takes tagged values, NativeOp
                                           takes raw pointers - two ABIs, and
                                           the op table says which. Asked once,
                                           here, so that every slot including
                                           the empty ones agrees. */
        bl      SYM(env_get)
        mov     x26, #0
        cbz     x0, 0f
        mov     x26, #1
0:      mov     w23, #0
1:      cmp     w23, #ARGS
        b.hs    2f
        LEA     x10, values             /* recomputed: the call above ate x9-x15 */
        LEA     x11, emptystr           /* aligned, so it can carry a tag */
        orr     x11, x11, x26
        str     x11, [x10, w23, uxtw #3]
        add     w23, w23, #1
        b       1b

2:      mov     w23, #0
1:      add     w24, w23, #2
        cmp     w24, w19
        b.hs    3f
        cmp     w23, #ARGS
        b.hs    3f
        mov     w25, #256
        mul     w25, w25, w23
        LEA     x0, argcopy             /* str_copy is (destination, source) */
        add     x0, x0, w25, uxtw
        ldr     x1, [x20, w24, uxtw #3]
        bl      SYM(str_copy)
        mov     w25, #256               /* recomputed after the call */
        mul     w25, w25, w23
        LEA     x24, argcopy
        add     x24, x24, w25, uxtw
        orr     x24, x24, x26
        LEA     x10, values
        str     x24, [x10, w23, uxtw #3]
        add     w23, w23, #1
        b       1b

3:      mov     x0, x21
        LEA     x1, values
        LEA     x2, outbuf
        mov     w3, #4096
        bl      SYM(op_run)
        cmn     w0, #1
        b.ne    5f
        LEA     x0, s_declined
        bl      say
        b       6f
5:      LEA     x9, outbuf
        strb    wzr, [x9, w0, uxtw]
        LEA     x0, outbuf
        bl      say
6:      LEA     x0, s_nl
        bl      say

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

        CSTR
s_arrow:    .asciz " -> "
s_tagenv:   .asciz "ARMEDIT_TAG"
s_declined: .asciz "(declined - ask the server)"
s_nl:       .asciz "\n"
        BSS
        .p2align 3
emptystr: .space 8      /* an aligned "" */
blob:    .space 65536
values:  .space 64
        .p2align 3
argcopy: .space 256 * ARGS
outbuf:  .space 4096
