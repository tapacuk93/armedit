#include "asm.inc"
#include "editor.inc"
/*
 * virtio_input.S - a keyboard, so the display window is a computer.
 *
 * Until this existed the kernel's only input was the UART, which meant the
 * window drew correctly and could not be typed into at all: the keystrokes go
 * to an emulated keyboard nobody was reading. A screen you cannot type into is
 * not an editor, so here is the smallest driver that fixes it.
 *
 * virtio-mmio, polled. No interrupts, because the editor already runs a poll
 * loop and adding a vector table to service one device would be the wrong
 * order to do things in - the kernel has no exception vectors at all yet, and
 * the first one installed should be the one that reports faults.
 *
 * <h2>What a virtqueue is, briefly</h2>
 *
 * Three arrays shared with the device. The descriptor table says where the
 * buffers are; the available ring is what the driver has offered; the used
 * ring is what the device has filled in. We offer every buffer once at startup
 * and then, forever after, take back whatever the device has finished with and
 * immediately offer it again. A keyboard produces events slowly and we consume
 * them promptly, so the ring never needs to be larger than a handful.
 *
 * <h2>Alignment, again</h2>
 *
 * The MMU is off, which makes all of memory Device-type, where unaligned
 * access faults and a kernel with no vectors answers a fault by hanging. The
 * rings are therefore page-aligned and every field is read at its natural
 * width. This is the second time that has mattered; see the note in
 * gfx/video.S for the first.
 */

/* QEMU's virt machine puts 32 virtio-mmio transports here, 512 bytes apart. */
/*
 * Where virtio lives when the machine does not say.
 *
 * QEMU's virt machine puts them here, and for years that was written down as a
 * constant because QEMU was the only machine this booted on. It is the
 * fallback now rather than the answer: dtb_or asks the device tree first, so
 * the same binary works on a machine that puts them somewhere else.
 */
#define VIRTIO_BASE     0x0A000000
#define VIRTIO_STRIDE   0x200
#define VIRTIO_SLOTS    32

#define VIRTIO_MAGIC    0x000           /* "virt" */
#define VIRTIO_VERSION  0x004
#define VIRTIO_DEVICE   0x008
#define VIRTIO_DEVFEAT  0x010
#define VIRTIO_DEVFSEL  0x014
#define VIRTIO_DRVFEAT  0x020
#define VIRTIO_DRVFSEL  0x024
#define VIRTIO_QSEL     0x030
#define VIRTIO_QNUMMAX  0x034
#define VIRTIO_QNUM     0x038
#define VIRTIO_QREADY   0x044
#define VIRTIO_QNOTIFY  0x050
#define VIRTIO_ISTATUS  0x060
#define VIRTIO_IACK     0x064
#define VIRTIO_STATUS   0x070
#define VIRTIO_QDESC_LO 0x080
#define VIRTIO_QDESC_HI 0x084
#define VIRTIO_QAVAIL_LO 0x090
#define VIRTIO_QAVAIL_HI 0x094
#define VIRTIO_QUSED_LO 0x0A0
#define VIRTIO_QUSED_HI 0x0A4

#define DEV_INPUT       18

#define ST_ACK          1
#define ST_DRIVER       2
#define ST_DRIVER_OK    4
#define ST_FEATURES_OK  8

/*
 * Sixty-four buffers, not eight.
 *
 * A keyboard is slow in human terms and anything but in queue terms: every
 * keystroke is a press, a sync, a release and another sync, so a line typed at
 * speed is hundreds of events in a moment. With eight buffers the device fills
 * the ring, drops the rest on the floor, and "hello from the window" arrives
 * as "shel" - which reads like a driver bug and is really just a ring too
 * small to hold a fast typist.
 */
#define QSIZE           64
#define EVENT_SZ        8               /* u16 type, u16 code, u32 value */

/* Linux input event types and the codes we care about. */
#define EV_KEY          1

/* How far the keycode tables run; anything past this is a key we ignore. */
#define KEYMAP_LEN      90

        .section .text
        .p2align 2

/*
 * kbd_init - find a virtio input device and bring it up.
 *   out w0 = 0 if there is a keyboard, -1 if this machine has none.
 *
 * A machine without one is not an error: the serial line still works, and that
 * is how this kernel was driven before any of this existed.
 */
        .globl  kbd_init
kbd_init:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]

        LEA     x0, s_c_virtio_mmio     /* where this machine keeps them */
        mov     x1, #VIRTIO_BASE
        bl      SYM(dtb_or)
        mov     x19, x0
        mov     w20, #0
1:      cmp     w20, #VIRTIO_SLOTS
        b.hs    .Lkb_none
        ldr     w9, [x19, #VIRTIO_MAGIC]
        movz    w10, #0x6976
        movk    w10, #0x7472, lsl #16   /* "virt", little-endian */
        cmp     w9, w10
        b.ne    2f
        ldr     w9, [x19, #VIRTIO_DEVICE]
        cmp     w9, #DEV_INPUT
        b.eq    3f
2:      add     x19, x19, #VIRTIO_STRIDE
        add     w20, w20, #1
        b       1b
3:
        ldr     w9, [x19, #VIRTIO_VERSION]
        cmp     w9, #2                  /* only the modern transport; the
                                           legacy one lays its queue out
                                           differently and QEMU offers this */
        b.ne    .Lkb_none

        LEA     x9, kbd_dev
        str     x19, [x9]

/* ---- the handshake, in the order the specification insists on ---------- */
        str     wzr, [x19, #VIRTIO_STATUS]      /* reset */
        mov     w9, #ST_ACK
        str     w9, [x19, #VIRTIO_STATUS]
        mov     w9, #(ST_ACK | ST_DRIVER)
        str     w9, [x19, #VIRTIO_STATUS]

/*
 * Features come in 32-bit words, selected one at a time. Of the ones a
 * keyboard offers we want none - but VIRTIO_F_VERSION_1 is not optional. It is
 * bit 32, which is bit 0 of the second word, and it is how the driver says it
 * speaks the modern layout rather than the legacy one. Leave it out and the
 * handshake still appears to succeed: the device sets FEATURES_OK, accepts the
 * queue addresses, and then never puts anything in the ring. Which is a
 * confusing way to spend an afternoon.
 */
        str     wzr, [x19, #VIRTIO_DEVFSEL]
        ldr     w9, [x19, #VIRTIO_DEVFEAT]
        str     wzr, [x19, #VIRTIO_DRVFSEL]
        str     wzr, [x19, #VIRTIO_DRVFEAT]     /* nothing from the first word */
        mov     w9, #1
        str     w9, [x19, #VIRTIO_DEVFSEL]
        ldr     w9, [x19, #VIRTIO_DEVFEAT]
        mov     w9, #1
        str     w9, [x19, #VIRTIO_DRVFSEL]
        mov     w9, #1                          /* VIRTIO_F_VERSION_1 */
        str     w9, [x19, #VIRTIO_DRVFEAT]

        mov     w9, #(ST_ACK | ST_DRIVER | ST_FEATURES_OK)
        str     w9, [x19, #VIRTIO_STATUS]
        ldr     w9, [x19, #VIRTIO_STATUS]
        tbz     w9, #3, .Lkb_fail               /* it refused our features */

/* ---- queue 0, the event queue ----------------------------------------- */
        str     wzr, [x19, #VIRTIO_QSEL]
        ldr     w9, [x19, #VIRTIO_QNUMMAX]
        cbz     w9, .Lkb_fail
        mov     w10, #QSIZE
        cmp     w9, w10
        csel    w10, w9, w10, lo                /* whichever is smaller */
        LEA     x9, kbd_qsize
        str     w10, [x9]
        str     w10, [x19, #VIRTIO_QNUM]

        LEA     x9, kbd_desc                    /* where the three rings are */
        mov     x0, x9
        str     w0, [x19, #VIRTIO_QDESC_LO]
        lsr     x1, x0, #32
        str     w1, [x19, #VIRTIO_QDESC_HI]
        LEA     x9, kbd_avail
        mov     x0, x9
        str     w0, [x19, #VIRTIO_QAVAIL_LO]
        lsr     x1, x0, #32
        str     w1, [x19, #VIRTIO_QAVAIL_HI]
        LEA     x9, kbd_used
        mov     x0, x9
        str     w0, [x19, #VIRTIO_QUSED_LO]
        lsr     x1, x0, #32
        str     w1, [x19, #VIRTIO_QUSED_HI]

/*
 * One descriptor per buffer, each writable by the device, and every one of
 * them offered straight away. There is nothing to hold back: the device fills
 * them with key events as they happen and we hand each back the moment we have
 * read it.
 */
        LEA     x20, kbd_desc
        LEA     x21, kbd_buf
        mov     w22, #0
1:      LEA     x9, kbd_qsize
        ldr     w9, [x9]
        cmp     w22, w9
        b.hs    2f
        lsl     w10, w22, #4                    /* 16 bytes per descriptor */
        add     x11, x20, w10, uxtw
        mov     w12, #EVENT_SZ
        mul     w12, w22, w12
        add     x12, x21, w12, uxtw
        str     x12, [x11]                      /* address */
        mov     w13, #EVENT_SZ
        str     w13, [x11, #8]                  /* length */
        mov     w13, #2                         /* VIRTQ_DESC_F_WRITE */
        strh    w13, [x11, #12]
        strh    wzr, [x11, #14]                 /* next; not a chain */

        LEA     x9, kbd_avail                   /* offer it */
        add     x9, x9, #4                      /* past flags and idx */
        strh    w22, [x9, w22, uxtw #1]
        add     w22, w22, #1
        b       1b
2:
        LEA     x9, kbd_avail
        strh    wzr, [x9]                       /* flags */
        LEA     x10, kbd_qsize
        ldr     w10, [x10]
        strh    w10, [x9, #2]                   /* idx: all of them, at once */
        LEA     x9, kbd_last
        strh    wzr, [x9]

        dsb     sy                              /* the rings must be visible
                                                   before the device is told
                                                   to look at them */
        mov     w9, #1
        str     w9, [x19, #VIRTIO_QREADY]
        mov     w9, #(ST_ACK | ST_DRIVER | ST_FEATURES_OK | ST_DRIVER_OK)
        str     w9, [x19, #VIRTIO_STATUS]
        str     wzr, [x19, #VIRTIO_QNOTIFY]

        mov     w0, #0
        b       .Lkb_out
.Lkb_fail:
        mov     w9, #128                        /* FAILED, so the device knows */
        str     w9, [x19, #VIRTIO_STATUS]
.Lkb_none:
        LEA     x9, kbd_dev
        str     xzr, [x9]
        mov     w0, #-1
.Lkb_out:
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * kbd_getc - one editor key code, or -1 if nothing has been pressed.
 *
 * Releases are discarded except for the modifiers, which are the only keys
 * whose being *held* means anything. Everything else reports on the way down,
 * which is what a text editor wants: holding a letter should not type it twice
 * because it was also let go.
 */
kbd_next:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]

        LEA     x9, kbd_dev
        ldr     x19, [x9]
        cbz     x19, .Lkg_none

.Lkg_next:
        LEA     x9, kbd_used
        ldrh    w10, [x9, #2]                   /* the device's index */
        LEA     x11, kbd_last
        ldrh    w12, [x11]
        cmp     w10, w12
        b.eq    .Lkg_none                       /* nothing new */

        LEA     x13, kbd_qsize
        ldr     w13, [x13]
        sub     w14, w13, #1                    /* qsize is a power of two */
        and     w14, w12, w14
        add     x9, x9, #4                      /* past flags and idx */
        lsl     w15, w14, #3                    /* 8 bytes per used element */
        add     x9, x9, w15, uxtw
        ldr     w16, [x9]                       /* which descriptor came back */

        add     w12, w12, #1                    /* consume it */
        strh    w12, [x11]

        and     w16, w16, #0xff
        cmp     w16, w13
        b.hs    .Lkg_next                       /* a nonsense index: let it go
                                                   rather than re-offer it and
                                                   read whatever the last event
                                                   happened to leave behind */                    /* a nonsense index; drop it */

        LEA     x9, kbd_buf
        mov     w17, #EVENT_SZ
        mul     w17, w16, w17
        add     x9, x9, w17, uxtw
        ldrh    w20, [x9]                       /* type */
        ldrh    w21, [x9, #2]                   /* code */
        ldr     w22, [x9, #4]                   /* value: 1 down, 0 up, 2 held */

.Lkg_recycle:
        LEA     x9, kbd_avail                   /* offer the buffer again */
        ldrh    w10, [x9, #2]
        sub     w14, w13, #1
        and     w15, w10, w14
        add     x11, x9, #4
        strh    w16, [x11, w15, uxtw #1]
        add     w10, w10, #1
        dsb     sy
        strh    w10, [x9, #2]
        str     wzr, [x19, #VIRTIO_QNOTIFY]

        cmp     w20, #EV_KEY
        b.ne    .Lkg_next

/* Shift and the command keys are state, not characters. */
        mov     w9, #42                         /* KEY_LEFTSHIFT */
        cmp     w21, w9
        b.eq    .Lkg_shift
        mov     w9, #54                         /* KEY_RIGHTSHIFT */
        cmp     w21, w9
        b.eq    .Lkg_shift
        mov     w9, #29                         /* KEY_LEFTCTRL */
        cmp     w21, w9
        b.eq    .Lkg_cmd
        mov     w9, #97                         /* KEY_RIGHTCTRL */
        cmp     w21, w9
        b.eq    .Lkg_cmd
        mov     w9, #125                        /* KEY_LEFTMETA - a real Cmd */
        cmp     w21, w9
        b.eq    .Lkg_cmd
        mov     w9, #126                        /* KEY_RIGHTMETA */
        cmp     w21, w9
        b.eq    .Lkg_cmd

        cbz     w22, .Lkg_next                  /* a release of anything else */

        mov     w0, w21
        bl      kbd_translate
        cmn     w0, #1
        b.eq    .Lkg_next
        b       .Lkg_out

.Lkg_shift:
        LEA     x9, kbd_shift
        cmp     w22, #0
        cset    w10, ne
        str     w10, [x9]
        b       .Lkg_next
.Lkg_cmd:
        LEA     x9, kbd_cmd
        cmp     w22, #0
        cset    w10, ne
        str     w10, [x9]
        b       .Lkg_next

.Lkg_none:
        mov     w0, #-1
.Lkg_out:
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * A place for keys to wait, so that being busy is not the same as being deaf.
 *
 * The device's used ring holds 64 events, which is a few seconds of not
 * looking and about twenty keystrokes - and a Cmd+P that has to reach a
 * backend is exactly a few seconds of not looking. Past that the ring is full,
 * the device stops delivering, and what the person typed while waiting is not
 * late, it is gone.
 *
 * So the ring is drained on a timer that has nothing to do with the editor's
 * loop: anything that waits calls platform_idle, and platform_idle empties the
 * device into here. The editor still reads one key at a time and still cannot
 * act on them until it is free, but the difference between "acted on late" and
 * "never happened" is the whole of what a keyboard is for.
 */
/*
 * Words, not bytes.
 *
 * platform_getc returns editor keys rather than characters, and the editor's
 * keys do not fit in a byte: the arrows start at 0x100 and every Cmd
 * combination is above them. A byte-wide ring truncated Cmd+P to plain "p",
 * which typed a letter into the document instead of asking anything - a bug
 * that looks exactly like the modifier not being pressed.
 */
#define KRING           256

        .globl  kbd_pump
kbd_pump:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
1:      bl      kbd_next
        cmn     w0, #1
        b.eq    9f
        mov     w19, w0
        LEA     x9, kring_head
        ldr     w10, [x9]
        LEA     x9, kring_tail
        ldr     w11, [x9]
        add     w12, w10, #1
        and     w12, w12, #(KRING - 1)
        cmp     w12, w11
        b.eq    1b                      /* full: the oldest keys are the ones
                                           worth keeping, so drop this one and
                                           keep draining the device */
        LEA     x9, kring
        str     w19, [x9, w10, uxtw #2]
        LEA     x9, kring_head
        str     w12, [x9]
        b       1b
9:      ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

        .globl  kbd_getc
kbd_getc:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        bl      kbd_pump
        LEA     x9, kring_head
        ldr     w10, [x9]
        LEA     x9, kring_tail
        ldr     w11, [x9]
        cmp     w10, w11
        b.eq    1f
        LEA     x9, kring
        ldr     w0, [x9, w11, uxtw #2]
        add     w11, w11, #1
        and     w11, w11, #(KRING - 1)
        LEA     x9, kring_tail
        str     w11, [x9]
        b       2f
1:      mov     w0, #-1
2:      ldp     x29, x30, [sp], #16
        ret

/*
 * kbd_translate - w0 = a Linux keycode, out w0 = an editor key or -1.
 *
 * The table is the unshifted character for each code; shift picks the second
 * table. Codes past the end of both are keys this editor has no use for.
 */
kbd_translate:
        mov     w9, w0
        mov     w10, #103                       /* the arrows and the edges */
        cmp     w9, w10
        b.ne    1f
        mov     w0, #K_UP
        b       .Lkt_mods
1:      mov     w10, #108
        cmp     w9, w10
        b.ne    2f
        mov     w0, #K_DOWN
        b       .Lkt_mods
2:      mov     w10, #105
        cmp     w9, w10
        b.ne    3f
        mov     w0, #K_LEFT
        b       .Lkt_mods
3:      mov     w10, #106
        cmp     w9, w10
        b.ne    4f
        mov     w0, #K_RIGHT
        b       .Lkt_mods
4:      mov     w10, #102
        cmp     w9, w10
        b.ne    5f
        mov     w0, #K_HOME
        b       .Lkt_mods
5:      mov     w10, #107
        cmp     w9, w10
        b.ne    6f
        mov     w0, #K_END
        b       .Lkt_mods
6:      cmp     w9, #28                         /* KEY_ENTER */
        b.ne    7f
        mov     w0, #K_ENTER
        b       .Lkt_mods
7:      cmp     w9, #14                         /* KEY_BACKSPACE */
        b.ne    8f
        mov     w0, #K_BS
        b       .Lkt_mods
8:      cmp     w9, #15                         /* KEY_TAB */
        b.ne    9f
        mov     w0, #K_TAB
        b       .Lkt_mods

9:      cmp     w9, #KEYMAP_LEN                 /* an ordinary character */
        b.hs    .Lkt_no
        LEA     x10, keymap_plain
        LEA     x11, keymap_shift
        LEA     x12, kbd_shift
        ldr     w12, [x12]
        cbz     w12, 10f
        mov     x10, x11
10:     ldrb    w0, [x10, w9, uxtw]
        cbz     w0, .Lkt_no

.Lkt_mods:
        LEA     x9, kbd_cmd
        ldr     w9, [x9]
        cbz     w9, 1f
        orr     w0, w0, #MOD_CMD
1:      LEA     x9, kbd_shift
        ldr     w9, [x9]
        cbz     w9, 2f
        mov     w10, #0x100                     /* only the named keys carry */
        cmp     w0, w10                         /* shift; a letter already is */
        b.lo    2f                              /* its shifted self */
        orr     w0, w0, #MOD_SHIFT
2:      ret
.Lkt_no:
        mov     w0, #-1
        ret

        .section .rodata
s_c_virtio_mmio: .asciz "virtio,mmio"

        .p2align 2
/*
 * Linux keycode to character. Index is the keycode; zero means "not a
 * character". This is a US layout because that is what the emulator presents;
 * a real machine would read the layout from somewhere rather than assume.
 */
keymap_plain:
        .byte 0, 0, '1', '2', '3', '4', '5', '6', '7', '8'      /*  0-9  */
        .byte '9', '0', '-', '=', 0, 0, 'q', 'w', 'e', 'r'      /* 10-19 */
        .byte 't', 'y', 'u', 'i', 'o', 'p', '[', ']', 0, 0      /* 20-29 */
        .byte 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';'  /* 30-39 */
        .byte '\'', '`', 0, '\\', 'z', 'x', 'c', 'v', 'b', 'n'  /* 40-49 */
        .byte 'm', ',', '.', '/', 0, '*', 0, ' ', 0, 0          /* 50-59 */
        .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0                      /* 60-69 */
        .byte 0, 0, 0, 0, '-', 0, 0, 0, '+', 0                  /* 70-79 */
        .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0                      /* 80-89 */
        .p2align 2
keymap_shift:
        .byte 0, 0, '!', '@', '#', '$', '%', '^', '&', '*'
        .byte '(', ')', '_', '+', 0, 0, 'Q', 'W', 'E', 'R'
        .byte 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', 0, 0
        .byte 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':'
        .byte '"', '~', 0, '|', 'Z', 'X', 'C', 'V', 'B', 'N'
        .byte 'M', '<', '>', '?', 0, '*', 0, ' ', 0, 0
        .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        .byte 0, 0, 0, 0, '-', 0, 0, 0, '+', 0
        .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

        .section .bss
/*
 * The rings are shared with the device, so they are page-aligned and read at
 * their natural widths - see the note at the top about the MMU being off.
 */
        .p2align 12
kbd_desc:       .space (16 * QSIZE)
        .p2align 12
kbd_avail:      .space (6 + 2 * QSIZE)
        .p2align 12
kbd_used:       .space (6 + 8 * QSIZE)
        .p2align 12
kbd_buf:        .space (EVENT_SZ * QSIZE)
        .p2align 2
kring:          .space (4 * KRING)
kring_head:     .space 4
kring_tail:     .space 4
        .p2align 3
kbd_dev:        .space 8
kbd_qsize:      .space 4
kbd_last:       .space 4
kbd_shift:      .space 4
kbd_cmd:        .space 4
