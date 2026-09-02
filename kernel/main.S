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

/*
 * The device tree, before anything else touches x0.
 *
 * It is the only thing the machine tells this kernel about itself, and it
 * arrives in the register every function is about to use for its first
 * argument. So it is put somewhere safe first and read afterwards - reading it
 * here, before the first print, meant that any trouble in the parser happened
 * with nothing on the wire and looked like a machine that never started.
 */
        LEA     x9, dtb_arg
        str     x0, [x9]

#ifdef ARMEDIT_PROBE_COMPAT
/*
 * One bit of output from a machine that has no console.
 *
 * macOS's Virtualization framework provides no legacy serial port - every
 * device it offers is virtio, and speaking virtio is precisely what this
 * kernel cannot do until it knows where the transport is. So the first
 * question about an unfamiliar machine cannot be asked through a console,
 * because the console is the thing being asked about.
 *
 * It goes first, before the boot message, and that placement is the whole
 * lesson. The probes were originally after it, and on a machine with no PL011
 * that write is a store to unmapped memory - a data abort, before the probe
 * ever ran. Every answer came back "no" and every "no" meant "this kernel died
 * on the way to being asked". A one-bit channel is only honest if nothing can
 * fail between the question and the answer.
 *
 * What it has found so far, on macOS's Virtualization framework: a device tree
 * does arrive, PCI ECAM is there, GICv3 is there, and there is no PL011, no
 * virtio-mmio and no simple-framebuffer. So the transport is virtio over PCI,
 * and a console there costs an ECAM walk and a virtio-pci driver rather than
 * the MMIO one this kernel already has.
 *
 * PSCI is the way out. Every virtual machine implements SYSTEM_OFF, and a
 * guest that powers itself off is a guest the host can see stop. So: look for
 * the node, and power off if it is there. Halted means yes; still running
 * means no. One bit per boot is slow and it is enough to find a transport.
 */
        LEA     x9, dtb_arg             /* the probe answers for itself: it runs
                                           before the rest of the kernel, so it
                                           cannot rely on anything the rest of
                                           the kernel would have done */
        ldr     x0, [x9]
        bl      SYM(dtb_init)

#ifdef ARMEDIT_PROBE_COUNT
        movz    w0, #0x1AF4
        movz    w1, #ARMEDIT_PROBE_DEVID
        bl      SYM(pci_count)
        cmp     w0, #ARMEDIT_PROBE_COUNT
        b.ne    1f
#elif defined(ARMEDIT_PROBE_HI)
        movz    w0, #0x1043
        bl      SYM(vpci_open)
        cmn     w0, #1
        b.eq    1f
        mov     w0, #ARMEDIT_PROBE_HI
        bl      SYM(vpci_offers_hi)
        cbz     w0, 1f
#elif defined(ARMEDIT_PROBE_OFFERS)
        movz    w0, #0x1043
        bl      SYM(vpci_open)
        cmn     w0, #1
        b.eq    1f
        mov     w0, #ARMEDIT_PROBE_OFFERS
        bl      SYM(vpci_offers)
        cbz     w0, 1f
#elif defined(ARMEDIT_PROBE_TXQ)
        movz    w0, #0x1043
        mov     w1, #ARMEDIT_PROBE_TXQ
        bl      SYM(vpci_txtest)
        cbz     w0, 1f
#elif defined(ARMEDIT_PROBE_NQ)
        movz    w0, #0x1043
        bl      SYM(vpci_open)
        cmn     w0, #1
        b.eq    1f
        bl      SYM(vpci_numq)
        cmp     w0, #ARMEDIT_PROBE_NQ
        b.ne    1f
#elif defined(ARMEDIT_PROBE_FEAT)
        movz    w0, #0x1AF4
        movz    w1, #0x1043
        bl      SYM(pci_find)
        cbz     x0, 1f
        mov     x19, x0
        bl      SYM(pci_assign)
        mov     x0, x19
        mov     w1, #1
        bl      SYM(vpci_structure)
        cbz     x0, 1f
        mov     x20, x0
        str     wzr, [x20, #0x00]       /* the low half of what it offers */
        ldr     w0, [x20, #0x04]
        tst     w0, #ARMEDIT_PROBE_FEAT
        b.eq    1f
#elif defined(ARMEDIT_PROBE_SELFTEST)
        movz    w0, #ARMEDIT_PROBE_SELFTEST
        bl      SYM(vpci_selftest)
        cbz     w0, 1f
#elif defined(ARMEDIT_PROBE_QDESC)
        bl      vcon_init
        cmn     w0, #1
        b.eq    1f
        bl      vcon_desc
        mov     x19, x0
        mov     w0, #1
        bl      SYM(vpci_qdesc)         /* does it hold what we wrote? */
        cmp     x0, x19
        b.ne    1f
#elif defined(ARMEDIT_PROBE_MULT)
        bl      vcon_init
        cmn     w0, #1
        b.eq    1f
        bl      SYM(vpci_mult)
        cmp     w0, #ARMEDIT_PROBE_MULT
        b.ne    1f
#elif defined(ARMEDIT_PROBE_NOFF)
        bl      vcon_init
        cmn     w0, #1
        b.eq    1f
        mov     w0, #1
        bl      SYM(vpci_notify_off)
        cmp     w0, #ARMEDIT_PROBE_NOFF
        b.ne    1f
#elif defined(ARMEDIT_PROBE_QENABLE)
        bl      vcon_init
        cmn     w0, #1
        b.eq    1f
        mov     w0, #1                  /* the transmit queue */
        bl      SYM(vpci_enabled)
        cbz     w0, 1f
#elif defined(ARMEDIT_PROBE_NUMQ)
        bl      vcon_init
        cmn     w0, #1
        b.eq    1f
        bl      SYM(vpci_numq)
        cmp     w0, #2                  /* at least a receive and a transmit */
        b.lo    1f
#elif defined(ARMEDIT_PROBE_UART)
        bl      uart_where              /* did we find a serial port? */
        cbz     x0, 1f
#elif defined(ARMEDIT_PROBE_DRIVEROK)
        movz    w0, #0x1043
        bl      SYM(vpci_open)
        cmn     w0, #1
        b.eq    1f
        bl      SYM(vpci_ready)
        bl      SYM(vpci_status)        /* is DRIVER_OK set? */
        tst     w0, #4
        b.eq    1f
#elif defined(ARMEDIT_PROBE_QSIZE)
        bl      vcon_init
        cmn     w0, #1
        b.eq    1f
        bl      vcon_qsize              /* did it accept eight? */
        cmp     w0, #8
        b.ne    1f
#elif defined(ARMEDIT_PROBE_WROTE)
        bl      vcon_init
        cmn     w0, #1
        b.eq    1f
        LEA     x0, m_boot              /* did the device take a buffer? */
        mov     w1, #5
        bl      vcon_write
        cbz     w0, 1f
#elif defined(ARMEDIT_PROBE_STATUS)
        movz    w0, #0x1AF4
        movz    w1, #0x1043
        bl      SYM(pci_find)
        cbz     x0, 1f
        mov     x19, x0
        bl      SYM(pci_assign)
        mov     x0, x19
        mov     w1, #1                  /* the common configuration */
        bl      SYM(vpci_structure)
        cbz     x0, 1f
        mov     x20, x0
        strb    wzr, [x20, #0x14]       /* reset, then acknowledge */
        mov     w9, #1
        strb    w9, [x20, #0x14]
        ldrb    w9, [x20, #0x14]        /* did the write stick? */
        tst     w9, #1
        b.eq    1f
#elif defined(ARMEDIT_PROBE_FEATURES)
        movz    w0, #0x1AF4
        movz    w1, #0x1043
        bl      SYM(pci_find)
        cbz     x0, 1f
        mov     x19, x0
        bl      SYM(pci_assign)
        mov     x0, x19
        mov     w1, #1
        bl      SYM(vpci_structure)
        cbz     x0, 1f
        mov     x20, x0
        mov     w9, #1                  /* does it offer VERSION_1 at all? */
        str     w9, [x20, #0x00]
        ldr     w9, [x20, #0x04]
        tst     w9, #1
        b.eq    1f
#elif defined(ARMEDIT_PROBE_WINDOW)
        bl      SYM(pci_window)         /* does the bridge declare a window? */
        cbz     x0, 1f
#elif defined(ARMEDIT_PROBE_ASSIGN)
        movz    w0, #0x1AF4
        movz    w1, #0x1043
        bl      SYM(pci_find)
        cbz     x0, 1f
        mov     x19, x0
        bl      SYM(pci_assign)
        mov     x0, x19
        mov     w1, #0
        bl      SYM(pci_bar)            /* did BAR 0 end up with an address? */
        cbz     x0, 1f
#elif defined(ARMEDIT_PROBE_STRUCT)
        movz    w0, #0x1AF4
        movz    w1, #0x1043
        bl      SYM(pci_find)
        cbz     x0, 1f
        mov     x19, x0
        bl      SYM(pci_assign)
        mov     x0, x19
        mov     w1, #ARMEDIT_PROBE_STRUCT
        bl      SYM(vpci_structure)
        cbz     x0, 1f
#elif defined(ARMEDIT_PROBE_BAR)
        movz    w0, #0x1AF4
        movz    w1, #0x1043
        bl      SYM(pci_find)
        cbz     x0, 1f
        mov     w1, #ARMEDIT_PROBE_BAR
        bl      SYM(pci_bar)
        cbz     x0, 1f
#elif defined(ARMEDIT_PROBE_VCON)
        bl      vcon_init               /* did a console come up? */
        cmn     w0, #1
        b.eq    1f
#elif defined(ARMEDIT_PROBE_VOPEN)
        movz    w0, #0x1043             /* the console, opened */
        bl      SYM(vpci_open)
        cmn     w0, #1
        b.eq    1f
#elif defined(ARMEDIT_PROBE_CAP)
        movz    w0, #0x1AF4
        movz    w1, #0x1043
        bl      SYM(pci_find)
        cbz     x0, 1f
        mov     w1, #0x09               /* any vendor capability at all */
        bl      SYM(pci_cap)
        cbz     x0, 1f
#elif defined(ARMEDIT_PROBE_PCI)
#ifdef ARMEDIT_PROBE_VENDOR
        movz    w0, ARMEDIT_PROBE_VENDOR
#else
        movz    w0, #0x1AF4             /* the virtio vendor */
#endif
#ifdef ARMEDIT_PROBE_DEV
        movz    w1, ARMEDIT_PROBE_DEV
#else
        movz    w1, #0xFFFF             /* any of its devices */
#endif
        bl      SYM(pci_find)
        cbz     x0, 1f
#elif defined(ARMEDIT_PROBE_ECAM)
        bl      SYM(pci_base)
        cbz     x0, 1f
#elif defined(ARMEDIT_PROBE_X0)
        LEA     x9, dtb_arg             /* was x0 even a pointer? */
        ldr     x0, [x9]
        cbz     x0, 1f
#elif defined(ARMEDIT_PROBE_TREE)
        bl      SYM(dtb_have)           /* was there a tree at all? */
        cbz     w0, 1f
#else
        LEA     x0, s_probe
        mov     w1, #0
        bl      SYM(dtb_reg)
        cbz     x0, 1f
#endif
        movz    w0, #0x0008
        movk    w0, #0x8400, lsl #16    /* PSCI SYSTEM_OFF */
        hvc     #0
1:      wfe                             /* not found: sit here and be seen to */
        b       1b
#endif


/*
 * Find out where this machine keeps things, and find a way to talk, before
 * saying anything at all.
 *
 * The order is the lesson. The boot message used to come first, which is fine
 * on a machine with a PL011 at the address this kernel assumed and useless on
 * one without: the write goes to unmapped memory, faults, and the machine
 * appears never to have started. Reading the tree costs nothing and finding a
 * console costs a bus walk, and both are cheaper than being mute.
 */
        LEA     x9, dtb_arg
        ldr     x0, [x9]
        bl      SYM(dtb_init)

/*
 * A virtio console, but only if there is no serial port.
 *
 * A machine with a PL011 already has the simplest possible channel, and
 * bringing up a PCI device it will never use costs a bus scan on every boot
 * for nothing. Asking first is one call and it keeps the common path exactly
 * as short as it was.
 */
        bl      uart_where
        cbnz    x0, 1f
        bl      vcon_init
1:
        LEA     x0, m_boot
        bl      platform_puts

#ifdef ARMEDIT_FAULT_TEST
/*
 * Break on purpose, so that not breaking is a thing that can be checked.
 *
 * An unaligned 32-bit load, which is legal on every machine this editor also
 * runs on and illegal here, because the MMU is off and Device memory does not
 * allow it. It is the single most common way this kernel goes wrong, and it
 * used to go wrong silently - so `make boot-fault` exists to prove that the
 * vectors are installed and that the report says what happened.
 */
        LEA     x0, m_boot
        add     x0, x0, #1
        ldr     w1, [x0]
#endif


#ifdef ARMEDIT_DTB_DUMP
/*
 * What the tree says about this machine, for when it is a new one.
 *
 * `make boot-dtb` turns this on. It exists because the first question on any
 * unfamiliar machine is "did the addresses come out right", and answering it
 * from inside a kernel with no debugger means printing them.
 */
        LEA     x0, m_dtb
        bl      platform_puts
        LEA     x9, dtb_arg             /* what actually arrived, in hex */
        ldr     x19, [x9]
        LEA     x0, m_two
        bl      platform_puts
        lsr     x0, x19, #32
        bl      uart_puthex
        mov     w0, w19
        bl      uart_puthex
        LEA     x0, m_nl2
        bl      platform_puts
        LEA     x0, m_two
        bl      platform_puts
        mov     x1, x19                 /* and the word it holds */
        bl      SYM(dtb_peek)
        bl      uart_puthex
        LEA     x0, m_nl2
        bl      platform_puts

        bl      SYM(dtb_have)
        LEA     x1, m_notree
        LEA     x2, m_tree
        cmp     w0, #0
        csel    x0, x2, x1, ne
        bl      platform_puts
        LEA     x0, s_c_virtio
        mov     w1, #0
        bl      SYM(dtb_reg)
        bl      dtb_show
        LEA     x0, s_c_pl011
        mov     w1, #0
        bl      SYM(dtb_reg)
        bl      dtb_show
        LEA     x0, s_c_pci
        mov     w1, #0
        bl      SYM(dtb_reg)
        bl      dtb_show
        LEA     x0, s_c_gpu
        mov     w1, #0
        bl      SYM(dtb_reg)
        bl      dtb_show
#endif

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

#ifdef ARMEDIT_DTB_DUMP
/*
 * dtb_show - x0 = an address the tree gave us, x1 = its size.
 *
 * Prints "  <addr> +<size>" or "  (absent)". Absent is the interesting answer:
 * it is how an unfamiliar machine says this kernel is looking for the wrong
 * thing, which beats reading a register that is not there.
 */
dtb_show:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     x19, x0
        mov     x20, x1
        cbnz    x19, 1f
        LEA     x0, m_absent
        bl      platform_puts
        b       9f
1:      LEA     x0, m_two
        bl      platform_puts
        lsr     x0, x19, #32
        bl      uart_puthex
        mov     w0, w19
        bl      uart_puthex
        LEA     x0, m_plus
        bl      platform_puts
        mov     w0, w20
        bl      uart_puthex
        LEA     x0, m_nl2
        bl      platform_puts
9:      ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret
#endif

        .section .bss
        .p2align 3
keybuf:   .space 256
        .p2align 3
dtb_arg:  .space 8

        .section .rodata
m_boot:   .asciz "armedit: boot\n"
#if defined(ARMEDIT_PROBE_COMPAT) && !defined(ARMEDIT_PROBE_TREE)
s_probe:  .asciz ARMEDIT_PROBE_COMPAT
#endif
#ifdef ARMEDIT_DTB_DUMP
m_dtb:    .asciz "armedit: what the device tree says (virtio, pl011, pci, gpu):\n"
m_absent: .asciz "  (absent)\n"
m_tree:   .asciz "  a tree was accepted\n"
m_notree: .asciz "  no device tree arrived in x0\n"
m_two:    .asciz "  "
m_plus:   .asciz " +"
m_nl2:    .asciz "\n"
s_c_virtio: .asciz "virtio,mmio"
s_c_pl011:  .asciz "arm,pl011"
s_c_pci:    .asciz "pci-host-ecam-generic"
s_c_gpu:    .asciz "simple-framebuffer"
#endif
m_ready:  .asciz "armedit: display up\n"
m_net:    .asciz "armedit: network device found\n"
m_nonet:  .asciz "armedit: no network device - Cmd+P has nowhere to go\n"
m_key:    .asciz "armedit: backend key accepted\n"
m_nokey:  .asciz "armedit: no key in fw_cfg - Cmd+P will do nothing\n"
s_keyfile: .asciz "opt/armedit/key"
s_keyname: .asciz "ARMEDIT_KEY"
m_nofb:   .asciz "armedit: no framebuffer on this machine, serial only\n"
m_keys:   .asciz "armedit: type in the display window, or here if this machine has no\n  keyboard. Use Ctrl for Cmd - macOS keeps the real Command key for\n  itself before QEMU ever sees it.\n  Ctrl+T new screen   Ctrl+left/right switch   Ctrl+H close\n  Ctrl+P rewrite      Ctrl+J hand over         Ctrl+0..9 colour\n"
