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


/*
 * pci_assign - x0 = a config-space address. Give this device its addresses.
 *
 * On QEMU something has already done this and the BARs read back as real
 * addresses. Under macOS's Virtualization framework they are all zero: there
 * is no firmware between the machine and the kernel, and a Linux guest assigns
 * its own. So must this one, or every BAR is nothing and every device is
 * unreachable - which is exactly how the console failed, silently, on a
 * machine whose only way to report the failure was that console.
 *
 * The window comes from the host bridge's `ranges`, because inventing an
 * address would put a device somewhere the bridge does not forward.
 *
 * Sizing is the standard trick: write ones, read back, and the bits that
 * stayed zero are the ones the device does not decode. The original value is
 * not restored, because it was zero - this only runs on unassigned devices,
 * and running it on an assigned one would move hardware somebody else is
 * already talking to.
 */
        .globl  SYM(pci_assign)
SYM(pci_assign):
        stp     x29, x30, [sp, #-80]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        str     x25, [sp, #64]
        mov     x19, x0

        bl      pci_window              /* where this bridge forwards memory */
        cbz     x0, .Lpa_out
        mov     x20, x0                 /* the next free address */

        mov     w21, #0                 /* which BAR */
.Lpa_bar:
        cmp     w21, #6
        b.hs    .Lpa_done
        add     x22, x19, #CFG_BAR0
        add     x22, x22, w21, uxtw #2

        ldr     w23, [x22]
        tbnz    w23, #0, .Lpa_next      /* I/O: this machine has none */
        and     w24, w23, #6
        cmp     w24, #4                 /* 64-bit, so it takes two slots */
        cset    w25, eq

        /* How much space does it want? */
        mov     w9, #-1
        str     w9, [x22]
        ldr     w9, [x22]
        and     w9, w9, #0xFFFFFFF0
        cbz     w9, .Lpa_skip           /* decodes nothing: unimplemented */
        neg     w9, w9                  /* ~mask + 1, which is the size */

        /* Align the cursor up to that size, then take it. */
        sub     x10, x9, #1
        add     x20, x20, x10
        bic     x20, x20, x10

        str     w20, [x22]
        cbz     w25, 1f
        lsr     x10, x20, #32
        str     w10, [x22, #4]
1:      add     x20, x20, x9

.Lpa_skip:
        cbz     w25, .Lpa_next
        add     w21, w21, #1            /* the upper half of a 64-bit BAR */
.Lpa_next:
        add     w21, w21, #1
        b       .Lpa_bar

.Lpa_done:
        mov     x0, x19
        bl      SYM(pci_enable)         /* only now is it safe to switch on */
.Lpa_out:
        ldr     x25, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #80
        ret

/*
 * pci_window - out x0 = the first address the bridge forwards to memory.
 *
 * From `ranges`, whose entries are seven cells each: three describing the
 * address on the PCI side, two on the CPU side, two of size. The top byte of
 * the first cell says what kind of space it is, and 0b10 in bits 25:24 means
 * 32-bit memory - which is what is wanted here, because a 32-bit BAR cannot
 * hold anything else and the console's BARs are 32-bit.
 *
 * Remembered after the first call, since the allocator must not hand the same
 * address to two devices by starting over.
 */
        .globl  SYM(pci_window)
SYM(pci_window):
        stp     x29, x30, [sp, #-80]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        str     x25, [sp, #64]

        LEA     x9, pci_next
        ldr     x0, [x9]
        cbnz    x0, 9f

        LEA     x0, s_c_ecam
        mov     w1, #0
        LEA     x2, s_ranges
        bl      SYM(dtb_prop)
        cbz     x0, 8f
        mov     x19, x0
        mov     w20, w1                 /* how many bytes of it */

/*
 * Either kind of memory range, 32-bit preferred.
 *
 * Bits 25:24 say which: 0b10 is 32-bit memory and 0b11 is 64-bit. QEMU offers
 * both; the Virtualization framework offers only 64-bit, and looking for the
 * 32-bit one alone found nothing at all - so every BAR stayed unassigned and
 * the console stayed silent about it.
 *
 * The preference matters because a 32-bit BAR cannot hold an address above
 * four gigabytes. Taking the low window when there is one keeps such a device
 * addressable; when there is not, a device with only 32-bit BARs is one this
 * cannot place, and that will be a real limitation on a real machine rather
 * than a hypothetical.
 */
        mov     w21, #0
        mov     x24, #0                 /* the best window so far */
        mov     w25, #0                 /* what kind it was */
1:      add     w9, w21, #28
        cmp     w9, w20
        b.hi    3f
        add     x0, x19, w21, uxtw
        bl      pci_be32                /* phys.hi */
        ubfx    w9, w0, #24, #2
        cmp     w9, #2
        b.eq    2f
        cmp     w9, #3
        b.ne    4f
2:      cmp     w25, #2                 /* already have a 32-bit one */
        b.eq    4f
        mov     w25, w9
        add     x0, x19, w21, uxtw
        add     x0, x0, #12             /* past three child cells */
        bl      pci_be32                /* the CPU-side address, high half */
        mov     x10, x0
        lsl     x10, x10, #32
        add     x0, x19, w21, uxtw
        add     x0, x0, #16
        bl      pci_be32
        orr     x24, x10, x0
4:      add     w21, w21, #28
        b       1b
3:      cbz     x24, 8f
        LEA     x9, pci_next
        str     x24, [x9]
        mov     x0, x24
        b       9f

8:      mov     x0, #0
9:      ldr     x25, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #80
        ret

/* pci_be32 - x0 = where, out w0 = the big-endian word there, read byte-wise. */
pci_be32:
        ldrb    w9, [x0]
        ldrb    w10, [x0, #1]
        ldrb    w11, [x0, #2]
        ldrb    w12, [x0, #3]
        lsl     w9, w9, #24
        orr     w9, w9, w10, lsl #16
        orr     w9, w9, w11, lsl #8
        orr     w0, w9, w12
        ret

        .section .rodata
s_c_ecam: .asciz "pci-host-ecam-generic"
s_ranges: .asciz "ranges"

        .section .bss
        .p2align 3
pci_ecam: .space 8
pci_next: .space 8
