#include "asm.inc"
/*
 * pci.S - finding devices on a PCI bus, by looking.
 *
 * macOS's Virtualization framework puts its virtio devices on PCI rather than
 * on the memory-mapped transport this kernel already speaks. That was found by
 * asking the device tree: ECAM is there, virtio-mmio is not. So a console on
 * that machine - and therefore any output at all from it - starts here.
 *
 * <h2>ECAM, which is the whole of the bus interface</h2>
 *
 * Configuration space is memory. A device's 4KB of registers lives at
 *
 *     base + (bus << 20) + (device << 15) + (function << 12)
 *
 * and reading it is a load. There is no port I/O, no configuration address
 * register, none of the older ceremony: the firmware told us the base through
 * the device tree, and everything else is arithmetic. That is the entire
 * reason this file is short.
 *
 * <h2>What it does and does not do</h2>
 *
 * It enumerates and it reads BARs. It does not assign them - the firmware has
 * already done that, and a kernel that reassigned addresses the firmware
 * handed out would have to know about bridges, windows and every device it did
 * not come here to drive.
 *
 * It also does not walk bridges. Everything this needs is on bus zero on both
 * machines it targets, and a recursive scan would be code that has never once
 * been right because it has never once run.
 *
 * <h2>Reads are 32-bit and aligned, deliberately</h2>
 *
 * Configuration space is Device memory even when the MMU is on, and certainly
 * is here with it off. Every access is a naturally-aligned word; the 16-bit
 * fields are extracted by shifting rather than by a halfword load, because an
 * unaligned or undersized access to config space is undefined behaviour on the
 * bus rather than merely on the CPU.
 */

#define ECAM_STRIDE     4096            /* one function's config space */
#define CFG_VENDOR      0x00            /* vendor and device, one word */
#define CFG_CLASS       0x08            /* revision and class codes */
#define CFG_HEADER      0x0C            /* cache line, latency, header type */
#define CFG_BAR0        0x10
#define CFG_CAP_PTR     0x34

#define VENDOR_NONE     0xFFFF          /* what an empty slot reads as */

        CODE
        .p2align 2

/*
 * pci_base - out x0 = where configuration space is, or 0.
 *
 * From the device tree, because the address is the machine's to choose. The
 * result is remembered: this is asked once per device lookup and the tree walk
 * is not free.
 */
        .globl  SYM(pci_base)
SYM(pci_base):
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LEA     x9, pci_ecam
        ldr     x0, [x9]
        cbnz    x0, 9f
        LEA     x0, s_c_ecam
        mov     w1, #0
        bl      SYM(dtb_reg)
        LEA     x9, pci_ecam            /* recomputed: the call ate x9-x15 */
        str     x0, [x9]
9:      ldp     x29, x30, [sp], #16
        ret

/*
 * pci_find - x0 = vendor, x1 = device, out x0 = a config-space address, or 0.
 *
 * A device id of 0xFFFF means "any device from this vendor", which is how
 * virtio is looked for: the transitional and modern devices have different
 * ids for the same thing, and a driver that only accepted one would refuse
 * hardware it can drive.
 */
        .globl  SYM(pci_find)
SYM(pci_find):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        mov     w19, w0                 /* wanted vendor */
        mov     w20, w1                 /* wanted device */

        bl      SYM(pci_base)
        cbz     x0, .Lpf_none
        mov     x21, x0

        mov     w22, #0                 /* device number, bus zero only */
.Lpf_dev:
        cmp     w22, #32
        b.hs    .Lpf_none
        mov     w23, #0                 /* function */
.Lpf_fn:
        cmp     w23, #8
        b.hs    .Lpf_next_dev

        lsl     x24, x22, #15
        add     x24, x24, x23, lsl #12
        add     x24, x21, x24           /* this function's config space */

        ldr     w9, [x24, #CFG_VENDOR]
        and     w10, w9, #0xFFFF
        mov     w12, #VENDOR_NONE       /* cmp takes 12 bits; this needs 16 */
        cmp     w10, w12
        b.eq    .Lpf_next_fn            /* nothing in this slot */

        cmp     w10, w19
        b.ne    .Lpf_multi
        lsr     w11, w9, #16
        mov     w12, #0xFFFF
        cmp     w20, w12                /* "any device from this vendor" */
        b.eq    .Lpf_found
        cmp     w11, w20
        b.eq    .Lpf_found

.Lpf_multi:
        /*
         * Function zero says whether there are others. Scanning all eight
         * regardless would work and would also read config space for functions
         * the device says do not exist, which on real hardware is a way to
         * find out that undefined behaviour is undefined.
         */
        cbnz    w23, .Lpf_next_fn
        ldr     w9, [x24, #CFG_HEADER]
        lsr     w9, w9, #16
        tbz     w9, #7, .Lpf_next_dev   /* not multi-function */
.Lpf_next_fn:
        add     w23, w23, #1
        b       .Lpf_fn
.Lpf_next_dev:
        add     w22, w22, #1
        b       .Lpf_dev

.Lpf_found:
        mov     x0, x24
        b       .Lpf_out
.Lpf_none:
        mov     x0, #0
.Lpf_out:
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * pci_bar - x0 = a config-space address, w1 = which BAR, out x0 = its address.
 *
 * Memory BARs only, and 64-bit ones are read as a pair. An I/O BAR comes back
 * as zero rather than as an address, because this machine has no port I/O and
 * a caller that got one would use it as if it were memory.
 */
        .globl  SYM(pci_bar)
SYM(pci_bar):
        add     x2, x0, #CFG_BAR0
        add     x2, x2, w1, uxtw #2
        ldr     w3, [x2]
        tbnz    w3, #0, 9f              /* bit 0 set: this is I/O space */
        and     w4, w3, #6              /* bits 2:1 say how wide it is */
        cmp     w4, #4                  /* 0b10: 64-bit */
        b.ne    1f
        ldr     w5, [x2, #4]
        and     x0, x3, #0xFFFFFFF0
        orr     x0, x0, x5, lsl #32
        ret
1:      mov     w0, w3
        and     x0, x0, #0xFFFFFFF0
        ret
9:      mov     x0, #0
        ret

/*
 * pci_enable - x0 = a config-space address.
 *
 * Sets the memory-space and bus-master bits. Firmware often leaves both off,
 * and a device whose memory space is disabled answers reads from its BAR with
 * ones - which looks exactly like a register full of ones rather than like a
 * device that was never switched on.
 */
        .globl  SYM(pci_enable)
SYM(pci_enable):
        ldr     w1, [x0, #4]            /* command and status */
        orr     w1, w1, #0x2            /* memory space */
        orr     w1, w1, #0x4            /* bus master   */
        str     w1, [x0, #4]
        ret

/*
 * pci_cap - x0 = config space, w1 = a capability id, out x0 = its address, or 0.
 *
 * Walks the capability list, which is how a virtio device says where its
 * registers are: the id alone is not enough, and the structure behind it
 * carries which BAR and what offset within it.
 *
 * Bounded by a step count as well as by the terminator. A capability list is a
 * linked list in memory the device controls, and a device that pointed one
 * entry at another would hang this loop forever.
 */
        .globl  SYM(pci_cap)
SYM(pci_cap):
        ldr     w2, [x0, #CFG_CAP_PTR]
        and     w2, w2, #0xFC           /* offsets are word-aligned */
        mov     w3, #48                 /* no list is longer than this */
1:      cbz     w2, 9f
        cbz     w3, 9f
        sub     w3, w3, #1
        add     x4, x0, w2, uxtw
        ldr     w5, [x4]
        and     w6, w5, #0xFF
        cmp     w6, w1
        b.eq    8f
        lsr     w2, w5, #8
        and     w2, w2, #0xFC
        b       1b
8:      mov     x0, x4
        ret
9:      mov     x0, #0
        ret

        .section .rodata
s_c_ecam: .asciz "pci-host-ecam-generic"

        .section .bss
        .p2align 3
pci_ecam: .space 8
