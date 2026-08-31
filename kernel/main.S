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
/*
 * The network, and then the one thing this machine has to be told.
 *
 * A kernel has no environment to inherit, so the key that says which backend
 * to talk to arrives through fw_cfg - which is how a QEMU guest is handed
 * anything at boot:
 *
 *     -fw_cfg name=opt/armedit/key,string=<key>@10.0.2.2:8090
 *
 * It goes into the same place env_get looks on every other target, so nothing
 * above here knows which kind of machine it is running on.
 */
        bl      net_init
        cmn     w0, #1
        b.eq    1f
        movz    w0, #0x000A                     /* 10.0.2.15, and 10.0.2.2 for */
        movk    w0, #0x0F02, lsl #16            /* the gateway: QEMU's user
                                                   network uses fixed,
                                                   documented addresses, so
                                                   they can be told rather than
                                                   discovered */
        movz    w1, #0x000A
        movk    w1, #0x0202, lsl #16
        bl      SYM(ip_configure)
        LEA     x0, m_net
        bl      platform_puts

        LEA     x0, s_keyfile
        bl      fwcfg_find_file
        tbnz    w0, #31, 2f
        lsl     w0, w0, #16
        mov     w9, #(0x02 | 0x08)              /* select, then read */
        orr     w0, w0, w9
        mov     w1, #255
        LEA     x2, keybuf
        bl      fwcfg_dma
        LEA     x9, keybuf
        ldrb    w10, [x9]
        cbz     w10, 2f
        LEA     x0, s_keyname
        LEA     x1, keybuf
        bl      SYM(env_put)
        LEA     x0, m_key
        bl      platform_puts
        b       3f
2:      LEA     x0, m_nokey
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
keybuf:   .space 256

        .section .rodata
m_boot:   .asciz "armedit: boot\n"
m_ready:  .asciz "armedit: display up\n"
m_net:    .asciz "armedit: network device found\n"
m_nonet:  .asciz "armedit: no network device - Cmd+P has nowhere to go\n"
m_key:    .asciz "armedit: backend key accepted\n"
m_nokey:  .asciz "armedit: no key in fw_cfg - Cmd+P will do nothing\n"
s_keyfile: .asciz "opt/armedit/key"
s_keyname: .asciz "ARMEDIT_KEY"
m_nofb:   .asciz "armedit: no framebuffer on this machine, serial only\n"
m_keys:   .asciz "armedit: type in the display window, or here if this machine has no\n  keyboard. Use Ctrl for Cmd - macOS keeps the real Command key for\n  itself before QEMU ever sees it.\n  Ctrl+T new screen   Ctrl+left/right switch   Ctrl+H close\n  Ctrl+P rewrite      Ctrl+J hand over         Ctrl+0..9 colour\n"
