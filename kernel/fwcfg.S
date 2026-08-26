#include "asm.inc"
/*
 * fwcfg.S - QEMU fw_cfg over its DMA interface, and ramfb setup.
 *
 * ramfb is the simplest display QEMU offers: you hand the host the physical
 * address of a plain pixel buffer, and it scans it out.  No PCI enumeration,
 * no GPU command rings - which is exactly what a kernel with no drivers wants.
 * The handoff goes through fw_cfg: find the "etc/ramfb" entry in the firmware
 * file directory, then DMA-write a 28-byte config blob to it.
 *
 * Every fw_cfg field is big-endian, so everything crossing the interface goes
 * through `rev`.
 */
#define FWCFG_BASE      0x09020000
#define FWCFG_DMA_OFF   0x10

#define FWCFG_FILE_DIR  0x0019

#define DMA_ERROR       0x01
#define DMA_READ        0x02
#define DMA_SELECT      0x08
#define DMA_WRITE       0x10

        .section .text
        .p2align 2

/*
 * fwcfg_dma - run one DMA transfer.
 *   w0 = control word (host order), w1 = length, x2 = buffer address
 *   out: w0 = 0 on success, -1 if the host flagged an error
 */
        .globl  fwcfg_dma
fwcfg_dma:
        LEA     x3, dma_req
        rev     w4, w0
        str     w4, [x3, #0]            /* control */
        rev     w4, w1
        str     w4, [x3, #4]            /* length  */
        rev     x4, x2
        str     x4, [x3, #8]            /* address */
        dsb     sy
        mov     x5, #FWCFG_BASE
        rev     x6, x3
        str     x6, [x5, #FWCFG_DMA_OFF]  /* kick it off */
        dsb     sy
1:      ldr     w4, [x3]                /* host clears control when done */
        rev     w4, w4
        tst     w4, #DMA_ERROR
        b.ne    2f
        cbnz    w4, 1b
        mov     w0, #0
        ret
2:      mov     w0, #-1
        ret

/*
 * fwcfg_find_file - look up a name in the fw_cfg file directory.
 *   x0 = NUL-terminated name, out: w0 = selector key, or -1 if absent
 */
        .globl  fwcfg_find_file
fwcfg_find_file:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0

        mov     w0, #FWCFG_FILE_DIR     /* select the directory, read the count */
        lsl     w0, w0, #16
        mov     w3, #(DMA_SELECT | DMA_READ)    /* not a bitmask immediate */
        orr     w0, w0, w3
        mov     w1, #4
        LEA     x2, fw_scratch
        bl      fwcfg_dma
        tbnz    w0, #31, .Lnotfound
        LEA     x2, fw_scratch
        ldr     w20, [x2]
        rev     w20, w20                /* number of entries */
        mov     w21, #0

.Lentry:
        cmp     w21, w20
        b.hs    .Lnotfound
        mov     w0, #DMA_READ           /* reads continue where the last left off */
        mov     w1, #64                 /* sizeof(FWCfgFile) */
        LEA     x2, fw_scratch
        bl      fwcfg_dma
        tbnz    w0, #31, .Lnotfound

        LEA     x22, fw_scratch
        add     x0, x22, #8             /* entry.name */
        mov     x1, x19
        bl      str_eq
        cbz     w0, .Lnext
        LEA     x22, fw_scratch
        ldrh    w0, [x22, #4]           /* entry.select, big-endian */
        rev16   w0, w0
        and     w0, w0, #0xFFFF
        b       .Lfound
.Lnext:
        add     w21, w21, #1
        b       .Lentry

.Lnotfound:
        mov     w0, #-1
.Lfound:
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/* str_eq - x0, x1 NUL-terminated; w0 = 1 if equal, 0 otherwise. */
        .globl  str_eq
str_eq:
1:      ldrb    w2, [x0], #1
        ldrb    w3, [x1], #1
        cmp     w2, w3
        b.ne    2f
        cbnz    w2, 1b
        mov     w0, #1
        ret
2:      mov     w0, #0
        ret

/*
 * ramfb_init - point the host's scanout at our buffer.
 *   x0 = framebuffer address, w1 = width, w2 = height
 *   out: w0 = 0 on success, -1 if the machine has no ramfb device
 */
        .globl  ramfb_init
ramfb_init:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0
        mov     w20, w1
        mov     w21, w2

        LEA     x0, s_ramfb
        bl      fwcfg_find_file
        tbnz    w0, #31, .Lno_ramfb
        mov     w22, w0                 /* selector key */

        LEA     x3, ramfb_cfg           /* all fields big-endian */
        rev     x4, x19
        str     x4, [x3, #0]            /* address */
        mov     w4, #0x5258             /* DRM_FORMAT_XRGB8888 = 'XR24' */
        movk    w4, #0x3432, lsl #16
        rev     w4, w4
        str     w4, [x3, #8]            /* fourcc */
        str     wzr, [x3, #12]          /* flags */
        rev     w4, w20
        str     w4, [x3, #16]           /* width */
        rev     w4, w21
        str     w4, [x3, #20]           /* height */
        lsl     w4, w20, #2             /* stride = width * 4 bytes */
        rev     w4, w4
        str     w4, [x3, #24]

        lsl     w0, w22, #16
        mov     w3, #(DMA_SELECT | DMA_WRITE)
        orr     w0, w0, w3
        mov     w1, #28                 /* sizeof(RAMFBCfg) */
        LEA     x2, ramfb_cfg
        bl      fwcfg_dma
        b       .Lramfb_out
.Lno_ramfb:
        mov     w0, #-1
.Lramfb_out:
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

        .section .rodata
s_ramfb:        .asciz "etc/ramfb"

        .section .bss
        .p2align 4
dma_req:        .space 16               /* FWCfgDmaAccess */
ramfb_cfg:      .space 32               /* RAMFBCfg, padded */
fw_scratch:     .space 64               /* one FWCfgFile at a time */
