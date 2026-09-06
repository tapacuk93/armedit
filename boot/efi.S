/*
 * efi.S - armedit as an EFI application.
 *
 * The Virtualization framework's virtio console has never carried a byte for
 * this kernel, and several rounds of narrowing established that the device
 * works, the transport works, receive works, and transmit does not - without
 * finding why. This is the way around it: the framework will also boot a guest
 * through EFI, and EFI firmware hands an application a text console and a
 * framebuffer before it has to know anything about the hardware underneath.
 *
 * That is worth having beyond this one machine. EFI is how a great many arm64
 * boards start something, and an image that boots this way is one fewer
 * platform backend to write for each of them.
 *
 * <h2>What the firmware hands over</h2>
 *
 * Two arguments, in the Microsoft calling convention that EFI uses on aarch64:
 * x0 is this image's handle and x1 is the system table. Everything else is
 * reached by walking that table - the console is a pointer at a fixed offset
 * into it, and the framebuffer is a protocol looked up through boot services.
 *
 * Strings are UTF-16. Not "may be" - the console's OutputString takes nothing
 * else, which is why every message here is written out as .short pairs rather
 * than as text.
 *
 * <h2>Why this is separate from the kernel</h2>
 *
 * The kernel boots from a raw arm64 image with the MMU off and owns the
 * machine from its first instruction. An EFI application starts with the MMU
 * on, a firmware that owns the machine, and services it may call. Those are
 * different enough that pretending they are one program would mean a kernel
 * full of branches about which world it is in. This is the smaller thing:
 * establish that the framework boots it and that the console works, and then
 * hand over.
 */

#include "efidtb.inc"

/* Offsets into EFI_SYSTEM_TABLE, past its 24-byte header. */
#define ST_CONOUT       64
#define ST_BOOTSERVICES 96
#define ST_NTABLES      104
#define ST_TABLES       112

/* Offsets into EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL. */
#define OUT_STRING      8

/*
 * Offsets into EFI_BOOT_SERVICES. Every entry is a pointer and they are in the
 * order the specification lists them, so these are counted rather than looked
 * up - which is worth saying because a miscount here calls a different service
 * with this one's arguments.
 */
#define BS_GETMEMORYMAP         56
#define BS_ALLOCATEPOOL         64
#define BS_ALLOCATEPAGES        40
#define BS_EXITBOOTSERVICES     232
#define BS_LOCATEPROTOCOL       320

/* AllocatePages takes an allocation type and a memory type, both counted. */
#define ALLOCATE_ANY            0
#define EFI_LOADER_DATA         2

/* Offsets into EFI_GRAPHICS_OUTPUT_PROTOCOL and the mode it describes. */
#define GOP_MODE        24
#define MODE_INFO       8
#define MODE_FB_BASE    24
#define MODE_FB_SIZE    32
#define INFO_WIDTH      4
#define INFO_HEIGHT     8
#define INFO_FORMAT     12
#define INFO_STRIDE     32

        .text
        .globl  efi_main
efi_main:
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        mov     x19, x1                 /* the system table */
        adrp    x9, systab
        str     x19, [x9, :lo12:systab]
        adrp    x9, image_handle
        str     x0, [x9, :lo12:image_handle]

        adrp    x0, hello
        add     x0, x0, :lo12:hello
        bl      efi_say

/*
 * Ask the firmware for the display.
 *
 * This is the whole reason an EFI application is worth having on this machine.
 * The framework offers a guest virtio-gpu and nothing else, and a kernel that
 * has to bring that up before it can say anything has no way to report what
 * went wrong bringing it up. The firmware has already done it, and hands over
 * an address, a size and a stride - which is the same handover a real loader
 * makes on the target, from a different direction.
 */
        ldr     x20, [x19, #ST_BOOTSERVICES]
        cbz     x20, 9f
        ldr     x9, [x20, #BS_LOCATEPROTOCOL]
        adrp    x0, gop_guid
        add     x0, x0, :lo12:gop_guid
        mov     x1, #0
        adrp    x2, gop
        add     x2, x2, :lo12:gop
        blr     x9
        cbnz    x0, .Lno_gop

        adrp    x9, gop
        ldr     x9, [x9, :lo12:gop]
        cbz     x9, .Lno_gop
        ldr     x21, [x9, #GOP_MODE]
        cbz     x21, .Lno_gop
        ldr     x22, [x21, #MODE_FB_BASE]
        ldr     x23, [x21, #MODE_INFO]
        cbz     x23, .Lno_gop
/*
 * A display the firmware will only draw on through Blt has no address at all,
 * and says so with a base of zero and a format of three. Writing to it is
 * writing to address zero, which on this machine is a guest that stops without
 * a word - so it is checked before it is used rather than after.
 */
        cbz     x22, .Lblt_only
        ldr     w9, [x23, #INFO_FORMAT]
        cmp     w9, #3
        b.eq    .Lblt_only

        adrp    x0, m_screen
        add     x0, x0, :lo12:m_screen
        bl      efi_say
        mov     x0, x22
        bl      efi_hex
        adrp    x0, m_space
        add     x0, x0, :lo12:m_space
        bl      efi_say
        ldr     w0, [x23, #INFO_WIDTH]
        bl      efi_dec
        adrp    x0, m_by
        add     x0, x0, :lo12:m_by
        bl      efi_say
        ldr     w0, [x23, #INFO_HEIGHT]
        bl      efi_dec
        adrp    x0, m_stride
        add     x0, x0, :lo12:m_stride
        bl      efi_say
        ldr     w0, [x23, #INFO_STRIDE]
        bl      efi_dec
        adrp    x0, m_format
        add     x0, x0, :lo12:m_format
        bl      efi_say
        ldr     w0, [x23, #INFO_FORMAT]
        bl      efi_dec
        adrp    x0, m_nl
        add     x0, x0, :lo12:m_nl
        bl      efi_say

/*
 * And draw on it, because a printed address is a claim and a coloured screen
 * is not. Four bands, so that a stride read wrongly shows as a slant rather
 * than as a picture that happens to look right.
 */
        ldr     w24, [x23, #INFO_STRIDE]
        ldr     w25, [x23, #INFO_HEIGHT]
        ldr     w26, [x23, #INFO_WIDTH]
        mov     w9, #0                          /* the row */
1:      cmp     w9, w25
        b.hs    3f
        mov     w10, #0                         /* the column */
        umull   x11, w9, w24
        add     x11, x22, x11, lsl #2
2:      cmp     w10, w26
        b.hs    4f
        lsr     w12, w9, #6                     /* a band every sixty-four rows */
        and     w12, w12, #3
        adrp    x13, bands
        add     x13, x13, :lo12:bands
        ldr     w14, [x13, w12, uxtw #2]
        str     w14, [x11, w10, uxtw #2]
        add     w10, w10, #1
        b       2b
4:      add     w9, w9, #1
        b       1b
3:
        adrp    x0, m_drawn
        add     x0, x0, :lo12:m_drawn
        bl      efi_say

/*
 * And now hand over, which is the whole point of the thing.
 *
 * What the kernel expects is what m1n1 gives it: a raw arm64 image somewhere
 * two-megabyte aligned, and x0 pointing at a flattened tree with a
 * simple-framebuffer in it. That is a different world from the one this
 * application is standing in - the MMU is on, the firmware owns the machine,
 * and there are services - so the last three things done here are to make
 * somewhere for the kernel to live, tell it where the screen is, and give the
 * machine back.
 */
        bl      efi_handover
        b       9f

.Lblt_only:
        adrp    x0, m_blt
        add     x0, x0, :lo12:m_blt
        bl      efi_say
        b       9f

.Lno_gop:
        adrp    x0, m_nogop
        add     x0, x0, :lo12:m_nogop
        bl      efi_say

/*
 * Stop, and stay stopped.
 *
 * Returning from an EFI application hands control back to the firmware, which
 * on a machine with nothing else to boot means the boot menu or a reset - and
 * either way the message is gone before anybody reads it. Waiting is the whole
 * of what this milestone does.
 */
9:      wfe
        b       9b

/*
 * efi_handover - put the kernel somewhere it can run, and go there.
 *
 * Does not return when it works. Returning means one of the three steps was
 * refused, and the caller says so and stops - which is better than jumping to
 * an address nothing was copied to.
 *
 * On entry x19 is the system table, x20 boot services, x22 the framebuffer,
 * x23 the mode information.
 */
efi_handover:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x27, x28, [sp, #16]
        str     x21, [sp, #32]

/*
 * Room for the kernel, and two megabytes more than it asks for.
 *
 * The image header says how much memory the whole thing wants - text, data
 * and the bss it has not got yet - and the header also says it must start on a
 * two-megabyte boundary. AllocatePages promises pages and says nothing about
 * two megabytes, so the way to get one is to ask for enough to contain the
 * alignment and then step forward to it.
 */
        adrp    x9, kernel_image
        add     x9, x9, :lo12:kernel_image
        ldr     x27, [x9, #16]                  /* the image size it declares */
        cbz     x27, .Lho_fail
        add     x0, x27, #0x200000
        add     x0, x0, #0xFFF
        lsr     x2, x0, #12                     /* in pages */
        mov     x0, #ALLOCATE_ANY
        mov     x1, #EFI_LOADER_DATA
        sub     sp, sp, #16
        mov     x3, sp
        ldr     x9, [x20, #BS_ALLOCATEPAGES]
        blr     x9
        ldr     x28, [sp]
        add     sp, sp, #16
        cbnz    x0, .Lho_fail
        cbz     x28, .Lho_fail

        add     x28, x28, #0x200000
        sub     x28, x28, #1
        mov     x9, #0x1FFFFF
        bic     x28, x28, x9                    /* where the kernel will live */

/*
 * Copy the image and clear the rest. The kernel's bss is inside the size it
 * declared and is not in the file, so what is not copied has to be zeroed -
 * a kernel whose bss holds whatever the firmware left there is one that works
 * until it reads a variable it has not written.
 */
        adrp    x0, kernel_image
        add     x0, x0, :lo12:kernel_image
        adrp    x1, kernel_end
        add     x1, x1, :lo12:kernel_end
        sub     x1, x1, x0
        mov     x2, x28
        mov     x9, #0
1:      cmp     x9, x1
        b.hs    2f
        ldrb    w10, [x0, x9]
        strb    w10, [x2, x9]
        add     x9, x9, #1
        b       1b
2:      cmp     x9, x27
        b.hs    3f
        strb    wzr, [x2, x9]
        add     x9, x9, #1
        b       2b
3:

/* Tell it where the screen is, in the tree it is going to be handed. */
        adrp    x21, efi_dtb
        add     x21, x21, :lo12:efi_dtb
        mov     x0, x22
        add     x1, x21, #EFI_DTB_REG
        bl      efi_put64
        ldr     w0, [x23, #INFO_WIDTH]
        add     x1, x21, #EFI_DTB_WIDTH
        bl      efi_put32
        ldr     w0, [x23, #INFO_HEIGHT]
        add     x1, x21, #EFI_DTB_HEIGHT
        bl      efi_put32
        ldr     w0, [x23, #INFO_STRIDE]
        lsl     w0, w0, #2                      /* the tree counts bytes a row,
                                                   the firmware counts pixels */
        add     x1, x21, #EFI_DTB_STRIDE
        bl      efi_put32
        ldr     w0, [x23, #INFO_WIDTH]
        ldr     w1, [x23, #INFO_HEIGHT]
        umull   x0, w0, w1
        lsl     x0, x0, #2
        add     x1, x21, #(EFI_DTB_REG + 8)     /* and how much of it there is */
        bl      efi_put64

/*
 * And where configuration space is, which an EFI machine says in ACPI.
 *
 * There is no device tree to copy this out of - that is the point of a loader
 * here - so it is walked out of the tables the firmware publishes: the
 * configuration table for the one with ACPI's identifier, the root pointer for
 * the extended table list, that list for the one signed MCFG, and MCFG's first
 * entry for the address. Four hops, each a fixed offset, and every one of them
 * checked, because a firmware without ACPI is a machine this simply has no bus
 * on rather than a reason to read whatever is at those addresses.
 */
        ldr     x9, [x19, #ST_NTABLES]
        ldr     x10, [x19, #ST_TABLES]
        cbz     x9, .Lno_acpi
        cbz     x10, .Lno_acpi
        adrp    x11, acpi_guid
        add     x11, x11, :lo12:acpi_guid
        ldp     x12, x13, [x11]
9:      cbz     x9, .Lno_acpi
        ldp     x14, x15, [x10]
        cmp     x14, x12
        b.ne    10f
        cmp     x15, x13
        b.eq    11f
10:     add     x10, x10, #24                   /* a guid and a pointer */
        sub     x9, x9, #1
        b       9b
11:     ldr     x10, [x10, #16]                 /* the root pointer */
        cbz     x10, .Lno_acpi
        ldr     x10, [x10, #24]                 /* the extended table list */
        cbz     x10, .Lno_acpi

        ldr     w9, [x10, #4]                   /* how long the list is */
        cmp     w9, #36
        b.ls    .Lno_acpi
        sub     w9, w9, #36
        lsr     w9, w9, #3                      /* how many tables */
        add     x11, x10, #36
12:     cbz     w9, .Lno_acpi
        ldr     x12, [x11]
        cbz     x12, 13f
        ldr     w13, [x12]
        movz    w14, #0x434D                    /* "MCFG", as it lies in memory: */
        movk    w14, #0x4746, lsl #16           /* M then C then F then G, and a
                                                   word read of it is therefore
                                                   0x4746434d and not the two
                                                   halves swapped, which is a
                                                   signature no table has */
        cmp     w13, w14
        b.eq    14f
13:     add     x11, x11, #8
        sub     w9, w9, #1
        b       12b

14:     ldr     w13, [x12, #4]                  /* is there an entry in it? */
        cmp     w13, #60
        b.lo    .Lno_acpi
        ldr     x13, [x12, #44]                 /* where configuration space is */
        cbz     x13, .Lno_acpi
        ldrb    w14, [x12, #54]                 /* the first bus it covers */
        ldrb    w15, [x12, #55]                 /* and the last */
        sub     w15, w15, w14
        add     w15, w15, #1
        lsl     x15, x15, #20                   /* a megabyte a bus */
        mov     x0, x13
        add     x1, x21, #EFI_DTB_ECAM
        bl      efi_put64
        mov     x0, x15
        add     x1, x21, #(EFI_DTB_ECAM + 8)
        bl      efi_put64
        adrp    x0, m_bus
        add     x0, x0, :lo12:m_bus
        bl      efi_say
        adrp    x9, efi_dtb
        add     x9, x9, :lo12:efi_dtb
        ldr     x0, [x9, #EFI_DTB_ECAM]
        rev     x0, x0
        bl      efi_hex
        adrp    x0, m_nl
        add     x0, x0, :lo12:m_nl
        bl      efi_say
.Lno_acpi:

/*
 * And where memory is, out of the firmware's own map.
 *
 * The largest run of ordinary memory, which on every machine this could boot
 * is the machine's memory - the rest of the map is firmware, devices and the
 * pieces it has handed out. Taking the largest rather than the first matters:
 * the first is usually a small hole below whatever the firmware put at the
 * bottom.
 */
        adrp    x0, map_size
        add     x0, x0, :lo12:map_size
        mov     x10, #16384
        str     x10, [x0]
        adrp    x1, map_buf
        add     x1, x1, :lo12:map_buf
        adrp    x2, map_key
        add     x2, x2, :lo12:map_key
        adrp    x3, map_dsize
        add     x3, x3, :lo12:map_dsize
        adrp    x4, map_dver
        add     x4, x4, :lo12:map_dver
        ldr     x10, [x20, #BS_GETMEMORYMAP]
        blr     x10
        cbnz    x0, 7f

        adrp    x9, map_buf
        add     x9, x9, :lo12:map_buf
        adrp    x10, map_size
        ldr     x10, [x10, :lo12:map_size]
        add     x10, x9, x10                    /* one past the last entry */
        adrp    x11, map_dsize
        ldr     x11, [x11, :lo12:map_dsize]
        cbz     x11, 7f
        mov     x12, #0                         /* the best base so far */
        mov     x13, #0                         /* and how big it was */
5:      add     x14, x9, x11
        cmp     x14, x10
        b.hi    6f
        ldr     w15, [x9]
        cmp     w15, #7                         /* ordinary memory */
        b.ne    8f
        ldr     x14, [x9, #24]                  /* how many pages */
        lsl     x14, x14, #12
        cmp     x14, x13
        b.ls    8f
        mov     x13, x14
        ldr     x12, [x9, #8]                   /* where it starts */
8:      add     x9, x9, x11
        b       5b
6:      cbz     x13, 7f
        mov     x0, x12
        add     x1, x21, #EFI_DTB_MEM
        bl      efi_put64
        mov     x0, x13
        add     x1, x21, #(EFI_DTB_MEM + 8)
        bl      efi_put64
7:

/*
 * Give the machine back.
 *
 * ExitBootServices needs the key of the current memory map, and the map
 * changes whenever anything is allocated - including by the call that asks for
 * it. So the loop is not defensiveness: the first attempt is expected to be
 * refused, and asking again with the newer key is how this is meant to be
 * done.
 */
        mov     w9, #0
4:      cmp     w9, #8
        b.hs    .Lho_fail
        add     w9, w9, #1
        stp     x9, x10, [sp, #-16]!

        adrp    x0, map_size
        add     x0, x0, :lo12:map_size
        mov     x10, #16384
        str     x10, [x0]
        adrp    x1, map_buf
        add     x1, x1, :lo12:map_buf
        adrp    x2, map_key
        add     x2, x2, :lo12:map_key
        adrp    x3, map_dsize
        add     x3, x3, :lo12:map_dsize
        adrp    x4, map_dver
        add     x4, x4, :lo12:map_dver
        ldr     x10, [x20, #BS_GETMEMORYMAP]
        blr     x10

        adrp    x0, map_key
        add     x0, x0, :lo12:map_key
        ldr     x1, [x0]
        adrp    x0, image_handle
        add     x0, x0, :lo12:image_handle
        ldr     x0, [x0]
        ldr     x10, [x20, #BS_EXITBOOTSERVICES]
        blr     x10
        ldp     x9, x10, [sp], #16
        cbnz    x0, 4b

/*
 * And go. Everything the kernel is told, it is told in x0; the rest are zero
 * because the arm64 boot contract says they are reserved and a kernel is
 * entitled to assume it.
 */
        mov     x0, x21
        mov     x1, #0
        mov     x2, #0
        mov     x3, #0
        br      x28

.Lho_fail:
        ldr     x21, [sp, #32]
        ldp     x27, x28, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/* efi_put64 / efi_put32 - x0 = a value, x1 = where, big-endian as a tree is. */
efi_put64:
        lsr     x9, x0, #56
        strb    w9, [x1]
        lsr     x9, x0, #48
        strb    w9, [x1, #1]
        lsr     x9, x0, #40
        strb    w9, [x1, #2]
        lsr     x9, x0, #32
        strb    w9, [x1, #3]
        lsr     x9, x0, #24
        strb    w9, [x1, #4]
        lsr     x9, x0, #16
        strb    w9, [x1, #5]
        lsr     x9, x0, #8
        strb    w9, [x1, #6]
        strb    w0, [x1, #7]
        ret

efi_put32:
        lsr     w9, w0, #24
        strb    w9, [x1]
        lsr     w9, w0, #16
        strb    w9, [x1, #1]
        lsr     w9, w0, #8
        strb    w9, [x1, #2]
        strb    w0, [x1, #3]
        ret

/*
 * efi_say - x0 = a UTF-16 string. The console takes nothing else.
 *
 * Not "prefers": OutputString has one argument and it is two bytes a
 * character, which is why every message in this file is written out as .short
 * pairs rather than as text a person would rather read.
 */
efi_say:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     x19, x0
        adrp    x9, systab
        ldr     x9, [x9, :lo12:systab]
        cbz     x9, 8f
        ldr     x0, [x9, #ST_CONOUT]
        cbz     x0, 8f
        ldr     x2, [x0, #OUT_STRING]
        mov     x1, x19
        blr     x2
8:      ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/* efi_hex - x0 as sixteen hex digits, built two bytes a character. */
efi_hex:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     x19, x0
        adrp    x1, numtext
        add     x1, x1, :lo12:numtext
        mov     w2, #16
1:      sub     w2, w2, #1
        lsr     x9, x19, #60
        lsl     x19, x19, #4
        cmp     w9, #10
        b.lo    2f
        add     w9, w9, #('a' - 10)
        b       3f
2:      add     w9, w9, #'0'
3:      strh    w9, [x1]
        add     x1, x1, #2
        cbnz    w2, 1b
        strh    wzr, [x1]
        adrp    x0, numtext
        add     x0, x0, :lo12:numtext
        bl      efi_say
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/* efi_dec - w0 in decimal, because a resolution in hex helps nobody. */
efi_dec:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        adrp    x1, numtext
        add     x1, x1, :lo12:numtext
        add     x1, x1, #40
        strh    wzr, [x1]
        mov     w9, #10
1:      udiv    w10, w0, w9
        msub    w11, w10, w9, w0
        add     w11, w11, #'0'
        sub     x1, x1, #2
        strh    w11, [x1]
        mov     w0, w10
        cbnz    w0, 1b
        mov     x0, x1
        bl      efi_say
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

        .section .data,"dw"
        .p2align 3
systab:  .quad 0
gop:     .quad 0
image_handle: .quad 0
map_size:  .quad 0
map_key:   .quad 0
map_dsize: .quad 0
map_dver:  .quad 0
numtext: .space 64
        .p2align 3
map_buf: .space 16384

/*
 * The kernel, carried inside this application.
 *
 * Reading it off the volume would mean the file protocols, and a loader that
 * can only boot what it was built with is the honest description of what this
 * is - a way to get one image onto a machine, not a boot manager. It lives in
 * a data section so that the firmware loads it along with everything else.
 */
        .p2align 12
        .globl  kernel_image
kernel_image:
        .incbin "build/kernel.img"
        .globl  kernel_end
kernel_end:

        .section .rdata,"dr"
        .p2align 1
hello:
        .short  'a', 'r', 'm', 'e', 'd', 'i', 't', ':', ' '
        .short  'E', 'F', 'I', ' ', 'c', 'o', 'n', 's', 'o', 'l', 'e', ' '
        .short  'i', 's', ' ', 'a', 'l', 'i', 'v', 'e'
        .short  13, 10, 0
m_screen:
        .short  'a', 'r', 'm', 'e', 'd', 'i', 't', ':', ' '
        .short  's', 'c', 'r', 'e', 'e', 'n', ' ', 'a', 't', ' ', 0
m_space:  .short ' ', 0
m_by:     .short 'x', 0
m_stride: .short ',', ' ', 's', 't', 'r', 'i', 'd', 'e', ' ', 0
m_format: .short ',', ' ', 'f', 'o', 'r', 'm', 'a', 't', ' ', 0
m_bus: .short 'a','r','m','e','d','i','t',':',' ','b','u','s',' ','a','t',' ',0
m_nl:     .short 13, 10, 0
m_blt:
        .short  'a', 'r', 'm', 'e', 'd', 'i', 't', ':', ' '
        .short  'd', 'i', 's', 'p', 'l', 'a', 'y', ' ', 'i', 's'
        .short  ' ', 'b', 'l', 't', ' ', 'o', 'n', 'l', 'y', 13, 10, 0
m_drawn:
        .short  'a', 'r', 'm', 'e', 'd', 'i', 't', ':', ' '
        .short  'd', 'r', 'a', 'w', 'n', 13, 10, 0
m_nogop:
        .short  'a', 'r', 'm', 'e', 'd', 'i', 't', ':', ' '
        .short  'n', 'o', ' ', 'd', 'i', 's', 'p', 'l', 'a', 'y', 13, 10, 0

/*
 * The identifier the firmware knows the display by. A GUID's first three
 * fields go on the wire little-endian and the rest as written, which is why
 * this is bytes rather than something more readable: written any other way it
 * would be a different protocol, and the firmware would simply say it has none.
 */
/*
 * ACPI's identifier among the firmware's tables. The second revision, because
 * the first has no extended list and therefore no table above four gigabytes -
 * which on a machine that puts its configuration space up there is the
 * difference between finding the bus and not.
 */
        .p2align 3
acpi_guid:
        .byte 0x71, 0xe8, 0x68, 0x88, 0xf1, 0xe4, 0xd3, 0x11
        .byte 0xbc, 0x22, 0x00, 0x80, 0xc7, 0x3c, 0x88, 0x81

        .p2align 3
gop_guid:
        .byte 0xde, 0xa9, 0x42, 0x90, 0xdc, 0x23, 0x38, 0x4a
        .byte 0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a

        .p2align 2
bands:  .word 0xFF141618, 0xFF1D2228, 0xFF3A4048, 0xFF8AE2B8
