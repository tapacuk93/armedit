#include "asm.inc"
/*
 * What m1n1 hands over, parsed, without a Mac to hand it over.
 *
 * The structure is an ABI: iBoot's format, which m1n1 passes through. So the
 * useful test is not "does it work on the machine" - that needs the machine -
 * but "does this read the fields the ABI says are there". A synthetic
 * structure with known values in known places answers that, and it answers it
 * before anybody repartitions anything.
 *
 * The rejection cases matter as much. Whatever is in x0 on a real boot is a
 * device tree, or boot arguments, or neither, and reading a framebuffer
 * address out of "neither" and drawing to it is the worst available outcome.
 */
        CODE
        .p2align 2
        .globl  _main
_main:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     w19, #0                 /* failures */

/* ---- a plausible handover is accepted, and read correctly ---- */
        bl      build_args
        LEA     x0, args
        bl      SYM(bootargs_init)
        cmn     w0, #1
        LEA     x0, t_accept
        bl      expect_ne

        LEA     x0, fb
        LEA     x1, w
        LEA     x2, h
        LEA     x3, stride
        LEA     x4, depth
        bl      SYM(bootargs_fb)

        LEA     x9, fb
        ldr     x0, [x9]
        movz    x1, #0x0000
        movk    x1, #0xBEEF, lsl #16
        LEA     x2, t_base
        bl      expect_eq

        LEA     x9, w
        ldr     x0, [x9]
        mov     x1, #1512
        LEA     x2, t_width
        bl      expect_eq

        LEA     x9, h
        ldr     x0, [x9]
        mov     x1, #982
        LEA     x2, t_height
        bl      expect_eq

        LEA     x9, stride
        ldr     x0, [x9]
        mov     x1, #6144
        LEA     x2, t_stride
        bl      expect_eq

/* The depth field carries flags above its low byte; only the byte is depth. */
        LEA     x9, depth
        ldr     x0, [x9]
        mov     x1, #30
        LEA     x2, t_depth
        bl      expect_eq

/* ---- and things that are not a handover are refused ---- */
        mov     x0, #0
        bl      SYM(bootargs_init)
        cmn     w0, #1
        LEA     x0, t_null
        bl      expect_eq_flag

        bl      build_args              /* a framebuffer at zero is not one */
        LEA     x9, args
        mov     w10, #0
        strb    w10, [x9, #40]
        strb    w10, [x9, #41]
        strb    w10, [x9, #42]
        strb    w10, [x9, #43]
        strb    w10, [x9, #44]
        strb    w10, [x9, #45]
        strb    w10, [x9, #46]
        strb    w10, [x9, #47]
        LEA     x0, args
        bl      SYM(bootargs_init)
        cmn     w0, #1
        LEA     x0, t_nofb
        bl      expect_eq_flag

        bl      build_args              /* revision zero is nobody's */
        LEA     x9, args
        strb    wzr, [x9]
        strb    wzr, [x9, #1]
        LEA     x0, args
        bl      SYM(bootargs_init)
        cmn     w0, #1
        LEA     x0, t_norev
        bl      expect_eq_flag

/* ---- and the other handover: a device tree with a framebuffer in it ---- */
        LEA     x0, SYM(fdt_sample)
        bl      SYM(dtb_init)
        cmn     w0, #1
        LEA     x0, t_fdt
        bl      expect_ne

        LEA     x0, fb
        LEA     x1, w
        LEA     x2, h
        LEA     x3, stride
        LEA     x4, depth
        bl      SYM(screen_find)
        cmn     w0, #1
        LEA     x0, t_screen
        bl      expect_ne

        LEA     x9, fb
        ldr     x0, [x9]
        movz    x1, #0x0000
        movk    x1, #0x9C00, lsl #16
        LEA     x2, t_sfb_base
        bl      expect_eq

        LEA     x9, w
        ldr     x0, [x9]
        mov     x1, #1512
        LEA     x2, t_sfb_width
        bl      expect_eq

        LEA     x9, stride
        ldr     x0, [x9]
        mov     x1, #6144
        LEA     x2, t_sfb_stride
        bl      expect_eq

/* "x2r10g10b10" is ten bits a channel, and saying so is the difference between
   a picture and a dim wrong one. */
        LEA     x9, depth
        ldr     x0, [x9]
        mov     x1, #30
        LEA     x2, t_sfb_depth
        bl      expect_eq

/* ---- and an Apple-shaped tree picks the Apple serial port ---- */
        LEA     x0, SYM(fdt_apple)
        bl      SYM(dtb_init)
        bl      SYM(uart_forget)        /* the answer is cached; ask afresh */
        bl      SYM(uart_where)
        movz    x1, #0x0000
        movk    x1, #0x3520, lsl #16
        movk    x1, #0x0002, lsl #32
        LEA     x2, t_s5l_addr
        bl      expect_eq

        bl      SYM(uart_which)
        mov     x1, #2                  /* UART_S5L */
        LEA     x2, t_s5l_kind
        bl      expect_eq

/* ...and a machine with neither says so rather than writing into nothing. */
        LEA     x0, SYM(fdt_sample)     /* a tree with a screen and no serial */
        bl      SYM(dtb_init)
        bl      SYM(uart_forget)
        bl      SYM(uart_where)
        mov     x1, #0
        LEA     x2, t_no_uart
        bl      expect_eq

/*
 * ---- restarting a machine that has no PSCI ----
 *
 * Apple Silicon has no secure monitor to make a PSCI call to, so the reboot
 * everything else performs with one instruction is three stores to a watchdog
 * here. The address comes from the tree, and the compatible it is found under
 * is the general half of a list whose specific half names the chip - so this
 * is also the only test that the reader looks inside the list.
 */
        LEA     x0, SYM(fdt_apple)
        bl      SYM(dtb_init)
        bl      SYM(wdt_find)
        movz    x1, #0x0000
        movk    x1, #0x3d2b, lsl #16
        movk    x1, #0x0002, lsl #32    /* 0x23d2b0000 */
        LEA     x2, t_wdt_addr
        bl      expect_eq

/* A tree with no watchdog says so, rather than returning a base of zero that
   the next three stores would happily write to. */
        LEA     x0, SYM(fdt_sample)
        bl      SYM(dtb_init)
        bl      SYM(wdt_find)
        mov     x1, #0
        LEA     x2, t_wdt_none
        bl      expect_eq

/*
 * And the writes themselves, aimed at ordinary memory so they can be read
 * back. This is the whole of the mechanism: what a real watchdog does with
 * these three words is the one thing no test without the machine can show.
 *
 * Values, not order. The order the three go out in matters - see wdt.S - and
 * memory that has been written three times cannot say which came first. That
 * one is held by the source and by review, and pretending a read-back proved
 * it would be worse than admitting it did not.
 */
        LEA     x0, wdt
        mov     x1, #0
1:      cmp     x1, #64
        b.hs    2f
        mov     w2, #0xAA
        strb    w2, [x0, x1]            /* poison, so "zero" means written */
        add     x1, x1, #1
        b       1b
2:      LEA     x0, wdt
        bl      SYM(wdt_arm)

        LEA     x9, wdt
        ldr     w0, [x9, #0x1c]
        mov     x1, #4                  /* reset enable, bit two */
        LEA     x2, t_wdt_ctrl
        bl      expect_eq

        LEA     x9, wdt
        ldr     w0, [x9, #0x14]
        mov     x1, #0
        LEA     x2, t_wdt_bite
        bl      expect_eq

        LEA     x9, wdt
        ldr     w0, [x9, #0x10]
        mov     x1, #0
        LEA     x2, t_wdt_cur
        bl      expect_eq

/*
 * Offset zero is the first watchdog, which the system uses. Writing there
 * instead of the second is the mistake this catches, and it is one that would
 * look like it worked right up until something else wanted that timer.
 */
        LEA     x9, wdt
        ldr     w0, [x9]
        movz    w1, #0xAAAA
        movk    w1, #0xAAAA, lsl #16
        LEA     x2, t_wdt_first
        bl      expect_eq

        cbz     w19, 1f
        mov     x0, #1
        b       2f
1:      mov     x0, #0
2:      mov     x16, #1
        svc     #0x80

/*
 * A handover as m1n1 would write one: a 14-inch screen at thirty bits, with a
 * colour-space flag set above the depth so the masking is actually exercised.
 */
build_args:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LEA     x0, args
        mov     x1, #0
1:      cmp     x1, #768
        b.hs    2f
        strb    wzr, [x0, x1]
        add     x1, x1, #1
        b       1b
2:
        mov     w1, #3                  /* revision */
        strb    w1, [x0]
        mov     w1, #0
        strb    w1, [x0, #1]

        movz    x1, #0x0000             /* framebuffer at 0xBEEF0000 */
        movk    x1, #0xBEEF, lsl #16
        add     x2, x0, #40
        bl      put64
        mov     x1, #1512               /* width */
        LEA     x0, args
        add     x2, x0, #64
        bl      put64
        mov     x1, #982                /* height */
        LEA     x0, args
        add     x2, x0, #72
        bl      put64
        mov     x1, #6144               /* stride */
        LEA     x0, args
        add     x2, x0, #56
        bl      put64
        movz    x1, #30                 /* depth, with a flag above it */
        movk    x1, #0x0001, lsl #16
        LEA     x0, args
        add     x2, x0, #80
        bl      put64
        ldp     x29, x30, [sp], #16
        ret

/* put64 - x1 = value, x2 = where, little-endian, byte at a time. */
put64:
        mov     x3, #0
1:      cmp     x3, #8
        b.hs    2f
        lsl     w4, w3, #3
        lsr     x5, x1, x4
        strb    w5, [x2, x3]
        add     x3, x3, #1
        b       1b
2:      ret

/* expect_eq - x0 = got, x1 = wanted, x2 = what it is called. */
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
t_accept: .asciz "  a plausible handover is accepted                         "
t_base:   .asciz "  the framebuffer address is read                          "
t_width:  .asciz "  ...and its width                                         "
t_height: .asciz "  ...and its height                                        "
t_stride: .asciz "  ...and its stride, which is not the width                "
t_depth:  .asciz "  ...and its depth, without the flags above it             "
t_null:   .asciz "  a null pointer is refused                                "
t_nofb:   .asciz "  so is a handover with no framebuffer                     "
t_norev:  .asciz "  and one with no revision                                 "
t_fdt:    .asciz "  a device tree is accepted                                "
t_screen: .asciz "  ...and a simple-framebuffer in it is a screen            "
t_sfb_base:   .asciz "  ...at the address its reg gives                          "
t_sfb_width:  .asciz "  ...with the width it declares                            "
t_sfb_stride: .asciz "  ...the stride it declares, not the width                 "
t_sfb_depth:  .asciz "  ...and ten bits a channel when it says so                "
t_s5l_addr:   .asciz "  an Apple tree gives the s5l serial port's address        "
t_s5l_kind:   .asciz "  ...and it is driven as an s5l, not as a PL011            "
t_no_uart:    .asciz "  a machine with no serial port says so                    "
t_wdt_addr:   .asciz "  the watchdog is found under the general half of its list "
t_wdt_none:   .asciz "  a machine with no watchdog says so                       "
t_wdt_ctrl:   .asciz "  arming it enables reset                                  "
t_wdt_bite:   .asciz "  ...sets the bite time to zero                            "
t_wdt_cur:    .asciz "  ...and the current time to zero                          "
t_wdt_first:  .asciz "  ...and does not touch the system's own watchdog          "
s_ok:     .asciz "ok\n"
s_fail:   .asciz "FAIL\n"

        BSS
        .p2align 3
args:   .space 768
fb:     .space 8
w:      .space 8
h:      .space 8
stride: .space 8
depth:  .space 8
wdt:    .space 64
