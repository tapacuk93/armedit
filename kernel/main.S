#include "asm.inc"
/*
 * main.S - what the kernel does, as opposed to what the machine is.
 *
 * Nothing in this file names a register block, a peripheral or an
 * instruction-set feature.  It asks the port layer to bring up a display and
 * then uses the same console, font and rasterizer the desktop and phone
 * builds use.  Porting to another CPU means rewriting kernel/arch/<cpu>/ and
 * transliterating files like this one - not redesigning them.
 */
        .section .text
        .p2align 2
        .globl  kmain
kmain:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp

        LEA     x0, m_boot
        bl      platform_puts

        bl      platform_init           /* a display, if this machine has one */
        tbnz    w0, #31, .Lno_display
        bl      console_init
        tbnz    w0, #31, .Lno_display

        LEA     x0, m_ready
        bl      platform_puts
        LEA     x0, m_keys
        bl      platform_puts
/* A self-test before the editor: can this machine reach anything at all? */
        bl      net_init
        cmn     w0, #1
        b.eq    1f
        LEA     x0, m_net
        bl      platform_puts
        movz    w0, #0x0A00                     /* 10.0.2.15, what QEMU's */
        movk    w0, #0x020F, lsl #0             /* user network hands out */
        movz    w0, #0x020F
        movk    w0, #0x0A00, lsl #16
        movz    w1, #0x0202                     /* 10.0.2.2, the gateway */
        movk    w1, #0x0A00, lsl #16
        bl      SYM(ip_configure)
        movz    w0, #0x0202
        movk    w0, #0x0A00, lsl #16
        mov     w1, #8090
        bl      SYM(tcp_connect)
        cmn     w0, #1
        b.eq    2f
        LEA     x0, m_conn
        bl      platform_puts

        LEA     x0, m_get                       /* ask it something real */
        bl      SYM(str_len)
        mov     w1, w0
        LEA     x0, m_get
        bl      SYM(tcp_send)
        LEA     x0, httpbuf
        mov     w1, #4095
        bl      SYM(tcp_recv)
        LEA     x9, httpbuf
        strb    wzr, [x9, w0, uxtw]
        LEA     x0, m_reply
        bl      platform_puts
        LEA     x0, httpbuf
        bl      platform_puts
        LEA     x0, m_nl
        bl      platform_puts
        bl      SYM(tcp_close)
        b       3f
2:      LEA     x0, m_noconn
        bl      platform_puts
        b       3f
1:      LEA     x0, m_nonet
        bl      platform_puts
3:
        bl      kedit_run               /* the editor is the operating system */
        b       .Lidle

.Lno_display:
        LEA     x0, m_nofb              /* serial only is a valid outcome */
        bl      platform_puts
.Lidle:
        ldp     x29, x30, [sp], #16
        ret

        .section .bss
        .p2align 3
httpbuf:  .space 4096

        .section .rodata
m_boot:   .asciz "armedit: boot\n"
m_ready:  .asciz "armedit: display up\n"
m_net:    .asciz "armedit: network device found\n"
m_nonet:  .asciz "armedit: no network device\n"
m_conn:   .asciz "armedit: connected to the backend\n"
m_noconn: .asciz "armedit: could not connect\n"
m_get:    .asciz "GET /api/health HTTP/1.1\r\nHost: 10.0.2.2\r\nConnection: close\r\n\r\n"
m_reply:  .asciz "armedit: the backend said --\n"
m_nl:     .asciz "\n-- end\n"
m_nofb:   .asciz "armedit: no framebuffer on this machine, serial only\n"
m_keys:   .asciz "armedit: type in the display window if this machine has a keyboard,\n  otherwise here on the serial line, where Ctrl stands in for Cmd.\n  Cmd+T new screen   Cmd+left/right switch   Cmd+Delete close\n  Cmd+P rewrite      Cmd+Enter hand over     Cmd+0..9 colour\n"
