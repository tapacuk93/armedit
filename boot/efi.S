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

/* Offsets into EFI_SYSTEM_TABLE, past its 24-byte header. */
#define ST_CONOUT       64

/* Offsets into EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL. */
#define OUT_STRING      8

        .text
        .globl  efi_main
efi_main:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     x19, x1                 /* the system table */

        ldr     x0, [x19, #ST_CONOUT]   /* ConOut */
        cbz     x0, 9f
        ldr     x2, [x0, #OUT_STRING]
        adrp    x1, hello
        add     x1, x1, :lo12:hello
        blr     x2

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

        .section .rdata,"dr"
        .p2align 1
hello:
        .short  'a', 'r', 'm', 'e', 'd', 'i', 't', ':', ' '
        .short  'E', 'F', 'I', ' ', 'c', 'o', 'n', 's', 'o', 'l', 'e', ' '
        .short  'i', 's', ' ', 'a', 'l', 'i', 'v', 'e'
        .short  13, 10, 0
