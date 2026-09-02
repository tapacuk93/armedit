#include "asm.inc"
/*
 * xhci.S - finding and waking the USB host controller.
 *
 * <h2>Why USB and not wifi</h2>
 *
 * The machine this is aimed at needs two things it has not got: something to
 * type on, and a network. Wifi on it is Broadcom silicon behind PCIe, behind
 * an IOMMU, wanting firmware that lives in the macOS install, and then 802.11
 * and a WPA supplicant on top - each of those a project, and none of them
 * testable without the machine.
 *
 * USB is one thing that answers both. A keyboard is USB. An Ethernet adapter
 * is USB, and this kernel already has IP and TCP waiting behind it. So the
 * cheapest road to a machine that can be typed at and can reach a backend runs
 * through one controller rather than through a radio.
 *
 * <h2>Why xHCI is the right register interface for an Apple machine</h2>
 *
 * Apple's USB ports are not xHCI devices on a PCI bus - they are a DesignWare
 * dwc3 controller described in the device tree as a platform device. But dwc3
 * in host mode *is* an xHCI: its host registers are the standard ones at
 * offset zero of the controller's region, with dwc3's own global registers
 * further in. So the same driver reaches both, and the only thing that differs
 * is how the base address is found.
 *
 * Which is why it is found two ways. The device tree first, because that is
 * what the target has and what a dwc3 is described by; PCI class 0x0C0330
 * second, because that is what QEMU has and therefore what can be tested here
 * before the machine exists.
 *
 * <h2>What this does and does not do</h2>
 *
 * It finds the controller, reads what it says about itself, resets it, and
 * reports which of its root ports have something plugged in. That is the whole
 * of it: no rings, no transfers, no devices addressed. Bring-up is the part
 * that is wrong first on unfamiliar hardware and the part a report can show
 * without a driver behind it, so it is worth having on its own.
 */

/* Capability registers, at the base. */
#define XHCI_CAPLENGTH  0x00            /* byte: how far to the operational set */
#define XHCI_HCIVERSION 0x02            /* half:  0x0100 for xHCI 1.0 */
#define XHCI_HCSPARAMS1 0x04            /* slots, interrupters, ports */
#define XHCI_DBOFF      0x14            /* where the doorbells are */
#define XHCI_RTSOFF     0x18            /* where the runtime registers are */

/* Operational registers, at base + CAPLENGTH. */
#define XHCI_USBCMD     0x00
#define XHCI_USBSTS     0x04
#define XHCI_CRCR       0x18            /* the command ring, 64 bits */
#define XHCI_DCBAAP     0x30            /* the slot array, 64 bits */
#define XHCI_CONFIG     0x38            /* how many slots we mean to use */
#define XHCI_PORTSC     0x400           /* first port; 0x10 apart after that */

/* Runtime registers, at base + RTSOFF. Interrupter zero begins at 0x20. */
#define XHCI_ERSTSZ     0x28
#define XHCI_ERSTBA     0x30            /* 64 bits */
#define XHCI_ERDP       0x38            /* 64 bits */

#define TRB_SZ          16
#define RING_TRBS       16
#define TRB_CYCLE       (1 << 0)
#define TRB_TC          (1 << 1)        /* a link TRB that turns the cycle over */
#define TRB_LINK        (6 << 10)
#define TRB_NOOP_CMD    (23 << 10)
#define TRB_CMD_DONE    33              /* the event a command produces */

#define CMD_RUN         (1 << 0)
#define CMD_HCRST       (1 << 1)
#define STS_HCH         (1 << 0)        /* halted */
#define STS_CNR         (1 << 11)       /* controller not ready */
#define PORTSC_CCS      (1 << 0)        /* something is plugged in */

/*
 * How far the key table runs: eighty-three entries, ending at the up arrow.
 * Written out rather than computed from the labels, because a label difference
 * is not something the assembler will fold into a compare immediate - and
 * because getting it wrong reads one byte past a table into whatever follows,
 * which is a key nobody pressed.
 */
/*
 * How many places the controller is given to write into, and how many are kept
 * outstanding. Eight and six: enough that a burst of typing between two polls
 * of the idle loop has somewhere to land, and small enough to sit in a ring of
 * sixteen with room for the link entry that closes it.
 */
#define REPORTS_N       8
#define REPORTS_OUT     6

#define HID_LAST_N      83

#define XHCI_CLASS      0x0C0330        /* serial bus, USB, xHCI interface */

        CODE
        .p2align 2

/*
 * xhci_find - out x0 = the controller's registers, or 0.
 *
 * Cached, because both the report and anything that ever drives it will ask,
 * and the search walks the whole bus.
 */
        .globl  SYM(xhci_find)
SYM(xhci_find):
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]

        LEA     x9, xhci_base
        ldr     x0, [x9]
        cbnz    x0, 8f
        LEA     x9, xhci_looked
        ldr     w9, [x9]
        cbnz    w9, 9f
        LEA     x9, xhci_looked
        mov     w10, #1
        str     w10, [x9]

/*
 * The tree first. A dwc3 names itself three ways - the SoC's own string, then
 * Apple's generic one, then Synopsys' - and the last is the one every other
 * operating system matches, so it is the one to ask for.
 */
        LEA     x0, s_dwc3
        mov     w1, #0
        bl      SYM(dtb_reg)
        cbnz    x0, 7f
        LEA     x0, s_xhci_dt
        mov     w1, #0
        bl      SYM(dtb_reg)
        cbnz    x0, 7f

/*
 * Then the bus. By class, not by maker: the register interface is specified
 * and the vendor is not, and asking for one vendor's part would refuse every
 * other machine's for no reason.
 */
        movz    w0, #0x000C, lsl #16    /* class 0x0C, subclass 0x03, */
        movk    w0, #0x0330             /* interface 0x30: 0x0C0330 */
        bl      SYM(pci_class)
        cbz     x0, 9f
        mov     x19, x0
        mov     x0, x19
        bl      SYM(pci_assign)         /* a bus nobody laid out yet */
        mov     x0, x19
        bl      SYM(pci_enable)
        mov     x0, x19
        mov     w1, #0
        bl      SYM(pci_bar)
        cbz     x0, 9f

7:      LEA     x9, xhci_base
        str     x0, [x9]
8:      ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret
9:      mov     x0, #0
        b       8b

/*
 * xhci_ports - out w0 = how many root ports, or 0 if there is no controller.
 *
 * Straight out of HCSPARAMS1's top byte. A controller reports its own shape
 * and there is no other way to know it: the number of ports is a property of
 * the silicon, and a driver with a guess in it is a driver that reads a port
 * register belonging to something else on the next machine.
 */
        .globl  SYM(xhci_ports)
SYM(xhci_ports):
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        bl      SYM(xhci_find)
        cbz     x0, 9f
        ldr     w0, [x0, #XHCI_HCSPARAMS1]
        lsr     w0, w0, #24
        b       8f
9:      mov     w0, #0
8:      ldp     x29, x30, [sp], #16
        ret

/*
 * xhci_slots - out w0 = how many device slots the controller has.
 *
 * The low byte of the same word. Reported rather than used, for now: it is the
 * number that decides how much memory a device context array wants, and seeing
 * it is how the next piece of work starts.
 */
        .globl  SYM(xhci_slots)
SYM(xhci_slots):
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        bl      SYM(xhci_find)
        cbz     x0, 9f
        ldr     w0, [x0, #XHCI_HCSPARAMS1]
        and     w0, w0, #0xFF
        b       8f
9:      mov     w0, #0
8:      ldp     x29, x30, [sp], #16
        ret

/*
 * xhci_version - out w0 = the interface version, 0x0100 for xHCI 1.0.
 *
 * Out of the same word as CAPLENGTH, and that is not a shortcut. These
 * registers are thirty-two bits wide and a controller is entitled to answer
 * anything narrower with nothing: read a byte at a time this returned zero,
 * so the version printed as 0.0 and - worse - the capability length printed as
 * zero too, which puts the operational registers at the wrong address and
 * every port read after it somewhere that is not a port.
 *
 * It is the failure mode that looks like it worked: the numbers were plausible
 * and one of the eight "ports" even reported something attached.
 */
        .globl  SYM(xhci_version)
SYM(xhci_version):
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        bl      SYM(xhci_find)
        cbz     x0, 9f
        ldr     w0, [x0]                /* CAPLENGTH low, HCIVERSION high */
        lsr     w0, w0, #16
        b       8f
9:      mov     w0, #0
8:      ldp     x29, x30, [sp], #16
        ret

/*
 * xhci_caplength - out w0 = how far past the base the operational set begins.
 *
 * The low byte of the first word, for the reason above: taken with a word-wide
 * read and masked here rather than fetched as a byte from the bus.
 */
        .globl  SYM(xhci_caplength)
SYM(xhci_caplength):
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        bl      SYM(xhci_find)
        cbz     x0, 9f
        ldr     w0, [x0]
        and     w0, w0, #0xFF
        b       8f
9:      mov     w0, #0
8:      ldp     x29, x30, [sp], #16
        ret

/*
 * xhci_reset - stop the controller and start it over. out w0 = 0, or -1.
 *
 * Whatever ran before this - firmware, a loader, another operating system -
 * left the controller in a state this kernel did not choose, with rings
 * pointing at memory that is now somebody else's. Resetting is not tidiness:
 * it is the only way to know what the registers mean.
 *
 * The order is fixed by the specification and each wait is a real one. Halt
 * before reset, because resetting a running controller is undefined. Then wait
 * for the reset bit to clear, and then for Controller Not Ready, which is a
 * second and later condition - a controller can have finished resetting and
 * still be reading its own state out of memory, and writing to it in that
 * window is how a driver gets a machine that works on one board and not on the
 * next.
 */
        .globl  SYM(xhci_reset)
SYM(xhci_reset):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]

        bl      SYM(xhci_find)
        cbz     x0, 9f
        mov     x19, x0
        bl      SYM(xhci_caplength)
        add     x20, x19, w0, uxtw      /* the operational registers */

        ldr     w9, [x20, #XHCI_USBCMD]         /* halt it first */
        and     w9, w9, #~CMD_RUN
        str     w9, [x20, #XHCI_USBCMD]
        mov     w21, #0
1:      ldr     w9, [x20, #XHCI_USBSTS]
        tbnz    w9, #0, 2f                      /* HCH: halted */
        add     w21, w21, #1
        cmp     w21, #0x100000
        b.hs    9f
        b       1b

2:      ldr     w9, [x20, #XHCI_USBCMD]
        orr     w9, w9, #CMD_HCRST
        str     w9, [x20, #XHCI_USBCMD]
        mov     w21, #0
3:      ldr     w9, [x20, #XHCI_USBCMD]
        tbz     w9, #1, 4f                      /* HCRST cleared */
        add     w21, w21, #1
        cmp     w21, #0x100000
        b.hs    9f
        b       3b

4:      mov     w21, #0
5:      ldr     w9, [x20, #XHCI_USBSTS]
        tbz     w9, #11, 6f                     /* CNR cleared */
        add     w21, w21, #1
        cmp     w21, #0x100000
        b.hs    9f
        b       5b
6:      mov     w0, #0
        b       8f
9:      mov     w0, #-1
8:      ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * xhci_start - give the controller its rings and let it run.
 *   out w0 = 0, or -1 if it will not.
 *
 * Three pieces of memory, and the controller reads all of them by physical
 * address:
 *
 *   the slot array, which will hold one pointer per addressed device and is
 *   empty for now, because nothing has been addressed;
 *
 *   the command ring, which is where this kernel puts requests;
 *
 *   the event ring, which is where the controller puts answers, found through
 *   a segment table that says where the ring is and how long - one segment,
 *   since one is enough for anything this does.
 *
 * <h2>The cycle bit</h2>
 *
 * A ring has no head and tail pointer. Producer and consumer agree instead on
 * a bit in every entry: entries whose cycle bit matches the reader's current
 * state are new, and the state flips each time the reader wraps. Both sides
 * start at one, which is why the command ring's control register is written
 * with its Ring Cycle State set and why the event ring is read expecting ones.
 *
 * Getting this wrong does not fault. It produces a controller that never
 * appears to answer, or one that answers with an entry from the last lap.
 *
 * <h2>Physical addresses, and the thing that is missing</h2>
 *
 * The addresses handed over are this kernel's own, which is correct here
 * because the MMU is off and there is nothing between the controller and
 * memory. On the target there is: Apple puts a DART in front of its dwc3, and
 * a controller behind an IOMMU that has not been programmed reads nothing at
 * whatever address it is given. That is the next piece of work and it is not
 * done, so this is expected to find the controller on real hardware and expected
 * not to get an answer out of it.
 */
        .globl  SYM(xhci_start)
SYM(xhci_start):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        str     x23, [sp, #48]

        bl      SYM(xhci_find)
        cbz     x0, 9f
        mov     x19, x0
        bl      SYM(xhci_caplength)
        add     x20, x19, w0, uxtw              /* operational */

/* Clear the rings, so a second start does not read the first one's leavings. */
        LEA     x0, xhci_cmd
        mov     x1, #(RING_TRBS * TRB_SZ)
        bl      xhci_zero
        LEA     x0, xhci_evt
        mov     x1, #(RING_TRBS * TRB_SZ)
        bl      xhci_zero
        LEA     x0, xhci_dcbaa
        mov     x1, #512
        bl      xhci_zero

/*
 * The last entry of the command ring points back at the first and turns the
 * cycle over, so the ring is a ring. Without it the controller walks off the
 * end into whatever follows in memory and executes it as commands.
 */
        LEA     x9, xhci_cmd
        add     x10, x9, #((RING_TRBS - 1) * TRB_SZ)
        str     x9, [x10]                       /* where to go back to */
        str     wzr, [x10, #8]
        mov     w11, #(TRB_LINK | TRB_TC | TRB_CYCLE)
        str     w11, [x10, #12]

/* How many slots we mean to use: all of them the controller has. */
        bl      SYM(xhci_slots)
        str     w0, [x20, #XHCI_CONFIG]

        LEA     x9, xhci_dcbaa
        mov     x0, x9
        add     x1, x20, #XHCI_DCBAAP
        bl      xhci_put64

/* The command ring, with the cycle state we are going to produce with. */
        LEA     x9, xhci_cmd
        orr     x0, x9, #TRB_CYCLE              /* RCS */
        add     x1, x20, #XHCI_CRCR
        bl      xhci_put64

/* One event ring segment, described by a table of one. */
        LEA     x9, xhci_erst
        LEA     x10, xhci_evt
        str     x10, [x9]
        mov     w11, #RING_TRBS
        str     w11, [x9, #8]
        str     wzr, [x9, #12]

        ldr     w0, [x19, #XHCI_RTSOFF]
        and     w0, w0, #0xFFFFFFE0
        add     x21, x19, w0, uxtw              /* runtime */
        add     x22, x21, #0x20                 /* interrupter zero */
        LEA     x9, xhci_intr
        str     x22, [x9]

        mov     w9, #1
        str     w9, [x22, #(XHCI_ERSTSZ - 0x20)]
        LEA     x0, xhci_evt
        add     x1, x22, #(XHCI_ERDP - 0x20)
        bl      xhci_put64
        LEA     x0, xhci_erst
        add     x1, x22, #(XHCI_ERSTBA - 0x20)  /* last: it starts the search */
        bl      xhci_put64

        LEA     x9, xhci_evt                    /* where we will read next */
        LEA     x10, xhci_next
        str     x9, [x10]
        LEA     x10, xhci_cycle
        mov     w11, #1
        str     w11, [x10]
        LEA     x10, xhci_put
        LEA     x9, xhci_cmd
        str     x9, [x10]

        dsb     sy
        ldr     w9, [x20, #XHCI_USBCMD]
        orr     w9, w9, #CMD_RUN
        str     w9, [x20, #XHCI_USBCMD]
        dsb     sy

        mov     w23, #0
1:      ldr     w9, [x20, #XHCI_USBSTS]
        tbz     w9, #0, 2f                      /* HCH clear: it is running */
        add     w23, w23, #1
        cmp     w23, #0x100000
        b.hs    9f
        b       1b
2:      mov     w0, #0
        b       8f
9:      mov     w0, #-1
8:      ldr     x23, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * xhci_noop - ask the controller for nothing, and see whether it answers.
 *   out w0 = 0 if it completed the command, -1 if it did not.
 *
 * A No-Op command is the one request whose meaning cannot be got wrong: it has
 * no arguments, it changes nothing, and the only thing its completion proves
 * is the thing worth proving first - that the controller is reading commands
 * out of memory this kernel wrote, executing them, and writing answers back
 * where this kernel is looking.
 *
 * Everything that goes wrong in a ring implementation goes wrong here, before
 * any device is involved: a physical address the controller cannot reach, a
 * cycle bit the wrong way round, a doorbell at the wrong offset, an event ring
 * pointer never handed over. Each of those produces exactly the same symptom -
 * silence - and none of them is about USB.
 */
        .globl  SYM(xhci_noop)
SYM(xhci_noop):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        str     x23, [sp, #48]

        bl      SYM(xhci_find)
        cbz     x0, 9f
        mov     x19, x0

/* The command: a type, a cycle bit, and nothing else to be wrong about. */
        LEA     x9, xhci_put
        ldr     x20, [x9]
        str     xzr, [x20]
        str     wzr, [x20, #8]
        mov     w10, #(TRB_NOOP_CMD | TRB_CYCLE)
        str     w10, [x20, #12]
        add     x20, x20, #TRB_SZ
        str     x20, [x9]

/*
 * Ring the doorbell. Zero is the controller's own, and the value written is
 * zero too - a doorbell is a notification, not a message, and the only thing
 * it carries is which ring has something new on it.
 */
        dsb     sy
        ldr     w9, [x19, #XHCI_DBOFF]
        and     w9, w9, #0xFFFFFFFC
        add     x21, x19, w9, uxtw
        str     wzr, [x21]
        dsb     sy

/* And wait for the answer to appear where we said we would look for it. */
        mov     w0, #TRB_CMD_DONE
        bl      xhci_wait
        cmn     w0, #1
        b.eq    9f
        mov     w0, #0
        b       8f
9:      mov     w0, #-1
8:      ldr     x23, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * xhci_wait - w0 = the event type wanted. out w0 = 0 if it came, -1 if not.
 *
 * Events that are not the one being waited for are stepped over rather than
 * treated as failure. That is not tolerance, it is how the ring works: a port
 * reset produces a Port Status Change event, and it arrives before the
 * completion of whatever command is issued next. A loop that took the first
 * event to appear and required it to be its own answer therefore failed on the
 * first command after any reset - which is every enumeration, and which looked
 * exactly like a controller refusing to allocate a slot.
 */
xhci_wait:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     w19, w0
        mov     w20, #0
1:      cmp     w20, #0x800000
        b.hs    9f
        add     w20, w20, #1
        bl      xhci_event
        cmn     w0, #1
        b.eq    1b
        cmp     w0, w19
        b.ne    1b                              /* somebody else's news */
        mov     w0, #0
        b       8f
9:      mov     w0, #-1
8:      ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * xhci_event - out w0 = the type of the next event, or -1 if there is none.
 *
 * "Is there one" is answered by the cycle bit and nothing else. The ring is
 * not cleared and entries are not consumed in any way the controller can see:
 * a stale entry from the previous lap looks exactly like a fresh one except
 * for that bit, which is why it is the only thing tested.
 */
xhci_event:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]

        LEA     x19, xhci_next
        ldr     x20, [x19]
        LEA     x9, xhci_cycle
        ldr     w21, [x9]

        ldr     w9, [x20, #12]
        and     w10, w9, #1
        cmp     w10, w21
        b.ne    9f                              /* not written yet */

/*
 * Kept whole. The type alone answers "did something happen"; the rest answers
 * what, and a caller that has to ask a second time cannot - the entry is gone
 * as soon as the ring moves on and the controller may overwrite it.
 */
        LEA     x11, xhci_last
        ldr     x12, [x20]
        str     x12, [x11]
        ldr     w12, [x20, #8]
        str     w12, [x11, #8]
        str     w9, [x11, #12]

        lsr     w0, w9, #10
        and     w0, w0, #0x3F                   /* the type */

        add     x20, x20, #TRB_SZ
        LEA     x9, xhci_evt
        add     x10, x9, #(RING_TRBS * TRB_SZ)
        cmp     x20, x10
        b.lo    1f
        mov     x20, x9                         /* wrapped: the far side of the
                                                   ring is now the other cycle */
        eor     w21, w21, #1
        LEA     x9, xhci_cycle
        str     w21, [x9]
1:      str     x20, [x19]

/*
 * Tell the controller how far we have read.
 *
 * Nothing so far has needed this: a handful of events fit in the ring and it
 * has never come round. It will. A keyboard produces an event per keypress,
 * and a controller whose dequeue pointer never moves eventually decides the
 * ring is full and stops writing to it - which presents as a device that
 * worked for the first sixteen keys.
 *
 * The busy bit is cleared by writing it back, which is why it is set here
 * rather than masked out.
 */
        LEA     x9, xhci_intr
        ldr     x9, [x9]
        cbz     x9, 8f
        mov     w21, w0                         /* the type, which is the answer:
                                                   x0 is about to be the pointer,
                                                   and returning that instead
                                                   made every event look like a
                                                   different one */
        orr     x0, x20, #(1 << 3)              /* Event Handler Busy */
        add     x1, x9, #0x18                   /* ERDP, which is where in the
                                                   interrupter this goes - it
                                                   was being written to the
                                                   interrupter's first register
                                                   instead, so the controller
                                                   never saw the ring being
                                                   emptied and stopped with
                                                   Event Ring Full after
                                                   sixteen events, which is two
                                                   keys */
        bl      xhci_put64
        mov     w0, w21
        b       8f
9:      mov     w0, #-1
8:      ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * xhci_put64 - x0 = a value, x1 = a 64-bit register. Written as two words.
 *
 * Low half first, which is the order the specification requires for every
 * 64-bit register here: some controllers act on the write to the low half and
 * would act on an address whose top is still whatever it was.
 */
xhci_put64:
        str     w0, [x1]
        lsr     x9, x0, #32
        str     w9, [x1, #4]
        ret

/* xhci_zero - x0 = where, x1 = how many bytes, eight at a time. */
xhci_zero:
        add     x2, x0, x1
1:      cmp     x0, x2
        b.hs    2f
        str     xzr, [x0]
        add     x0, x0, #8
        b       1b
2:      ret

/*
 * xhci_enumerate - wake the first device that is plugged in and ask what it is.
 *   out w0 = 0 if it answered, -1 if it did not.
 *
 * On success xhci_vendor, xhci_product and xhci_class hold what it said.
 *
 * This is the first thing here that is USB rather than xHCI. Everything before
 * it was one machine talking to one controller; this is the controller talking
 * to something on the other end of a wire that was manufactured by somebody
 * else and has its own opinions about timing.
 *
 * <h2>The order, and why each step is separate</h2>
 *
 *   reset the port      until this happens the device is attached and not
 *                       listening; a port with something in it is not a port
 *                       you can talk to
 *   enable a slot       the controller allocates one and tells us which
 *   describe the device an input context saying "this is on port N, at this
 *                       speed, and its control endpoint's ring is here"
 *   address it          the controller does the USB address assignment itself
 *   ask it              a control transfer, which is three TRBs and the first
 *                       time anything is sent to the device rather than to
 *                       the controller
 *
 * Every one of those can fail on its own and each failure means something
 * different, which is why they are not folded together.
 */
        .globl  SYM(xhci_enumerate)
SYM(xhci_enumerate):
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        str     x27, [sp, #80]

        mov     w0, #1                          /* finding the controller */
        bl      xhci_step
        bl      SYM(xhci_find)
        cbz     x0, .Lxe_fail
        mov     x19, x0
        bl      SYM(xhci_caplength)
        add     x20, x19, w0, uxtw              /* operational */

/* Which port has something in it. The first is enough; there is one device. */
        mov     w0, #2                          /* finding an occupied port */
        bl      xhci_step
        bl      SYM(xhci_ports)
        mov     w21, w0
        cbz     w21, .Lxe_fail
        mov     w22, #0
1:      cmp     w22, w21
        b.hs    .Lxe_fail
        add     x23, x20, #XHCI_PORTSC
        add     x23, x23, x22, lsl #4
        ldr     w9, [x23]
        tbnz    w9, #0, 2f                      /* CCS */
        add     w22, w22, #1
        b       1b

/*
 * Reset it, and take care what is written back.
 *
 * PORTSC is mostly write-one-to-clear: the change bits above it, and Port
 * Enabled at bit one, which a driver clears by *setting*. Reading the register
 * and writing it back with the reset bit added would therefore disable the
 * port it was trying to reset and acknowledge every event it had not looked
 * at yet. So those bits are masked out of what is written, and only the reset
 * bit is put in.
 */
2:      mov     w0, #3                          /* resetting the port */
        bl      xhci_step
        ldr     w9, [x23]
        movz    w10, #0x00FE, lsl #16           /* the change bits, 17..23 */
        orr     w10, w10, #(1 << 1)             /* and Port Enabled */
        bic     w9, w9, w10
        orr     w9, w9, #(1 << 4)               /* Port Reset */
        str     w9, [x23]
        dsb     sy

        mov     w24, #0
3:      ldr     w9, [x23]
        tbnz    w9, #21, 4f                     /* PRC: the reset finished */
        add     w24, w24, #1
        cmp     w24, #0x400000
        b.hs    .Lxe_fail
        b       3b
4:      mov     w0, #4                          /* waiting for it to enable */
        bl      xhci_step
        ldr     w9, [x23]
        tbz     w9, #1, .Lxe_fail               /* PED: it did not come up */
        lsr     w25, w9, #10
        and     w25, w25, #0xF                  /* the speed it came up at */

/* A slot for it. The controller picks the number and reports it back. */
        mov     w0, #5                          /* asking for a slot */
        bl      xhci_step
        mov     w0, #(9 << 10)                  /* Enable Slot */
        mov     x1, #0
        mov     w2, #0
        bl      xhci_command
        cmn     w0, #1
        b.eq    .Lxe_fail
        LEA     x9, xhci_last
        ldr     w9, [x9, #12]
        lsr     w26, w9, #24                    /* the slot id */
        cbz     w26, .Lxe_fail

/*
 * Describe it to the controller.
 *
 * The input context is this kernel telling the controller what it believes
 * about the device; the device context is what the controller writes back
 * having addressed it. Both are read by physical address, and the second is
 * found through the slot array rather than passed - which is what the slot
 * array is for.
 */
        LEA     x0, xhci_input
        mov     x1, #(33 * 64)
        bl      xhci_zero
        LEA     x0, xhci_devctx
        mov     x1, #(32 * 64)
        bl      xhci_zero
        LEA     x0, xhci_ep0
        mov     x1, #(RING_TRBS * TRB_SZ)
        bl      xhci_zero

        bl      xhci_ctxsize
        mov     w27, w0

/* Add the slot and the control endpoint, and nothing else. */
        LEA     x9, xhci_input
        mov     w10, #3
        str     w10, [x9, #4]

/* The slot: one context below this one, and which root port it is on. */
        LEA     x9, xhci_input
        add     x9, x9, w27, uxtw               /* the slot context */
        mov     w10, #(1 << 27)                 /* context entries = 1 */
        orr     w10, w10, w25, lsl #20          /* the speed */
        str     w10, [x9]
        add     w11, w22, #1                    /* ports are numbered from one */
        lsl     w11, w11, #16
        str     w11, [x9, #4]

/*
 * The control endpoint. Its maximum packet size is decided by the speed and
 * not by asking, because asking requires a control transfer and a control
 * transfer requires this field - the specification breaks the circle by fixing
 * what each speed starts at.
 */
        LEA     x9, xhci_input
        add     x9, x9, w27, uxtw
        add     x9, x9, w27, uxtw               /* endpoint zero's context */
        mov     w10, #(4 << 3)                  /* type: control */
        orr     w10, w10, #(3 << 1)             /* three errors before giving up */
        mov     w12, #8                         /* low and full speed */
        cmp     w25, #3
        b.ne    5f
        mov     w12, #64                        /* high */
5:      cmp     w25, #4
        b.lo    6f
        mov     w12, #512                       /* super and above */
6:      orr     w10, w10, w12, lsl #16
        str     w10, [x9, #4]
        LEA     x10, xhci_ep0
        orr     x10, x10, #1                    /* the ring's cycle state */
        str     x10, [x9, #8]
        mov     w11, #8                         /* average transfer length */
        str     w11, [x9, #16]

        LEA     x9, xhci_dcbaa
        LEA     x10, xhci_devctx
        str     x10, [x9, w26, uxtw #3]

        LEA     x9, xhci_ep0                    /* where the next one goes */
        LEA     x10, xhci_ep0put
        str     x9, [x10]

        mov     w0, #6                          /* addressing the device */
        bl      xhci_step
        LEA     x0, xhci_input
        mov     w1, #(11 << 10)                 /* Address Device */
        mov     x2, x0
        mov     w0, w1
        mov     x1, x2
        mov     w2, w26
        bl      xhci_command
        cmn     w0, #1
        b.eq    .Lxe_fail

/* And now ask the device itself. */
        mov     w0, #7                          /* asking what it is */
        bl      xhci_step
        mov     w0, w26
        movz    w1, #0x0100                     /* the device descriptor */
        LEA     x2, xhci_desc
        mov     w3, #18
        bl      xhci_ask
        cmn     w0, #1
        b.eq    .Lxe_fail

        LEA     x9, xhci_desc
        ldrb    w10, [x9, #4]
        LEA     x11, SYM(xhci_class)
        str     w10, [x11]
        ldrb    w10, [x9, #8]
        ldrb    w11, [x9, #9]
        orr     w10, w10, w11, lsl #8
        LEA     x11, SYM(xhci_vendor)
        str     w10, [x11]
        ldrb    w10, [x9, #10]
        ldrb    w11, [x9, #11]
        orr     w10, w10, w11, lsl #8
        LEA     x11, SYM(xhci_product)
        str     w10, [x11]

/*
 * And if it might be something to type on, set it up to be.
 *
 * A device descriptor's class is zero on every keyboard ever made: it means
 * "the interfaces say what this is", and the interfaces are in the
 * configuration descriptor. So this is tried on anything that has not already
 * declared itself something else, and failing is ordinary - a mouse gets this
 * far and then has no boot keyboard interface in it.
 */
        LEA     x9, SYM(xhci_class)
        ldr     w9, [x9]
        cbnz    w9, 1f
        mov     w0, w26
        bl      SYM(xhci_keyboard)
1:
        mov     w0, #0
        bl      xhci_step
        mov     w0, #0
        b       .Lxe_out
.Lxe_fail:
        mov     w0, #-1
.Lxe_out:
        ldr     x27, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

/*
 * xhci_keyboard - w0 = the slot. Set the device up to report key presses.
 *   out w0 = 0 if it will, -1 if it will not.
 *
 * <h2>What a configuration descriptor is</h2>
 *
 * Not one descriptor. It is a header saying how many bytes follow, and then
 * those bytes are a run of descriptors of different kinds packed end to end -
 * interfaces, endpoints, and class-specific ones this kernel does not
 * understand. Each begins with its own length, and walking by that length is
 * the only way through: the kinds are not fixed, their order is not fixed, and
 * a device is allowed to put things in the middle that nobody else has heard
 * of.
 *
 * <h2>Why the boot protocol</h2>
 *
 * A HID device describes its own report format in a report descriptor, which
 * is a small stack language, and parsing it is a real piece of work. The boot
 * protocol exists so that a machine which has not got that far can still be
 * typed at: a keyboard in boot protocol sends eight fixed bytes - modifiers,
 * a reserved byte, and up to six keys held down - and every keyboard that
 * claims boot support sends exactly that.
 *
 * It is the right thing here for a second reason. This is the code that has to
 * work on a machine with nothing else working, and a report-descriptor parser
 * is a lot of surface to be wrong on the day the screen is the only output.
 */
        .globl  SYM(xhci_keyboard)
SYM(xhci_keyboard):
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        str     x27, [sp, #80]
        mov     w19, w0

        mov     w0, #8                          /* reading the configuration */
        bl      xhci_step

/* The header first, because it says how much there is. */
        mov     w0, w19
        movz    w1, #0x0200
        LEA     x2, xhci_cfg
        mov     w3, #9
        bl      xhci_ask
        cmn     w0, #1
        b.eq    .Lxk_fail

        LEA     x9, xhci_cfg
        ldrb    w10, [x9, #2]
        ldrb    w11, [x9, #3]
        orr     w20, w10, w11, lsl #8           /* how many bytes in total */
        cmp     w20, #256
        b.ls    1f
        mov     w20, #256                       /* more than we keep; take what
                                                   fits - the interface we want
                                                   is at the front of every
                                                   keyboard ever made */
1:      mov     w0, w19
        movz    w1, #0x0200
        LEA     x2, xhci_cfg
        mov     w3, w20
        bl      xhci_ask
        cmn     w0, #1
        b.eq    .Lxk_fail

        LEA     x9, xhci_cfg
        ldrb    w21, [x9, #5]                   /* which configuration this is */

/*
 * Walk it. Interfaces first: a boot keyboard is class 3, subclass 1, protocol
 * 1, and the endpoint that follows it is the one that will carry key presses.
 */
        mov     w22, #0                         /* the interface, once found */
        mov     w23, #0                         /* its endpoint address */
        mov     w24, #0                         /* and how big its packets are */
        mov     w25, #0                         /* have we found the interface? */
        mov     w26, #9                         /* where we are in the bytes */
2:      cmp     w26, w20
        b.hs    3f
        LEA     x9, xhci_cfg
        add     x9, x9, w26, uxtw
        ldrb    w10, [x9]                       /* this descriptor's length */
        cbz     w10, 3f
        ldrb    w11, [x9, #1]                   /* and its kind */

        cmp     w11, #4                         /* an interface */
        b.ne    4f
        ldrb    w12, [x9, #5]
        cmp     w12, #3                         /* human interface device */
        b.ne    5f
        ldrb    w12, [x9, #6]
        cmp     w12, #1                         /* which supports boot */
        b.ne    5f
        ldrb    w12, [x9, #7]
        cmp     w12, #1                         /* as a keyboard */
        b.ne    5f
        ldrb    w22, [x9, #2]                   /* this one */
        mov     w25, #1
        b       6f
5:      mov     w25, #0                         /* some other interface; its
                                                   endpoints are not ours */
        b       6f

4:      cmp     w11, #5                         /* an endpoint */
        b.ne    6f
        cbz     w25, 6f                         /* not under our interface */
        ldrb    w12, [x9, #2]
        tbz     w12, #7, 6f                     /* must carry data to us */
        ldrb    w13, [x9, #3]
        and     w13, w13, #3
        cmp     w13, #3                         /* and must be an interrupt */
        b.ne    6f
        mov     w23, w12
        ldrb    w12, [x9, #4]
        ldrb    w13, [x9, #5]
        orr     w24, w12, w13, lsl #8
        b       3f                              /* found both; stop looking */

6:      add     w26, w26, w10
        b       2b
3:      cbz     w23, .Lxk_fail

/*
 * Choose the configuration. Until this is done the device is addressed and
 * has no endpoints beyond the control one - it is listening and has nothing
 * to say.
 */
        mov     w0, #9                          /* choosing a configuration */
        bl      xhci_step
        LEA     x9, xhci_req
        strb    wzr, [x9]                       /* OUT, standard, to the device */
        mov     w10, #9                         /* SET_CONFIGURATION */
        strb    w10, [x9, #1]
        strb    w21, [x9, #2]
        strb    wzr, [x9, #3]
        strb    wzr, [x9, #4]
        strb    wzr, [x9, #5]
        strb    wzr, [x9, #6]
        strb    wzr, [x9, #7]
        mov     w0, w19
        mov     x1, #0
        mov     w2, #0
        bl      SYM(xhci_control)
        cmn     w0, #1
        b.eq    .Lxk_fail

/*
 * And tell the controller about the endpoint, which is a separate thing from
 * the device knowing about it: the device is configured, and the controller
 * still has no ring to put its reports on.
 *
 * The index is the controller's, not USB's: endpoint N carrying data to the
 * host is 2N+1, because the two directions of one number are two endpoints
 * here and the control endpoint is one.
 */
        mov     w0, #10                         /* configuring the endpoint */
        bl      xhci_step
        and     w27, w23, #0xF
        lsl     w27, w27, #1
        add     w27, w27, #1                    /* its index */

        LEA     x0, xhci_input
        mov     x1, #(33 * 64)
        bl      xhci_zero
        LEA     x0, xhci_intring
        mov     x1, #(RING_TRBS * TRB_SZ)
        bl      xhci_zero
        bl      xhci_ctxsize
        mov     w9, w0

        LEA     x10, xhci_input
        mov     w11, #1
        lsl     w11, w11, w27
        orr     w11, w11, #1                    /* the slot, which we are changing */
        str     w11, [x10, #4]

/*
 * The slot context has to be sent again, and its "context entries" field has
 * to name the highest endpoint now in use. A controller told about an endpoint
 * the slot does not admit to having ignores it, and the ring stays silent.
 */
        LEA     x12, xhci_devctx
        add     x10, x10, w9, uxtw
        ldr     w13, [x12]                      /* as the controller left it */
        bic     w13, w13, #(0x1F << 27)
        orr     w13, w13, w27, lsl #27
        str     w13, [x10]
        ldr     w13, [x12, #4]
        str     w13, [x10, #4]

/*
 * Where this endpoint's context goes.
 *
 * The input context is a run of equal-sized contexts: the control one first,
 * then the slot, then one per endpoint index. So the endpoint with index d
 * sits at (d + 1) contexts in, and computing it as d put every field one
 * context early - over the top of the endpoint below it. The controller
 * accepted the command, and the ring it then polled was the wrong one, which
 * is a keyboard that enumerates perfectly and produces nothing.
 */
        LEA     x10, xhci_input
        add     w13, w27, #1
        madd    x10, x9, x13, x10
        mov     w13, #(7 << 3)                  /* interrupt, carrying to us */
        orr     w13, w13, #(3 << 1)             /* three errors before giving up */
        orr     w13, w13, w24, lsl #16          /* its packet size */
        str     w13, [x10, #4]
        LEA     x11, xhci_intring
        orr     x11, x11, #1
        str     x11, [x10, #8]
        str     w24, [x10, #16]

/*
 * Close the interrupt ring with a link back to its start, so that topping it
 * up for ever does not walk off the end into whatever follows in memory.
 */
        LEA     x9, xhci_intring
        add     x10, x9, #((RING_TRBS - 1) * TRB_SZ)
        str     x9, [x10]
        str     wzr, [x10, #8]
        mov     w11, #(TRB_LINK | TRB_TC)
        str     w11, [x10, #12]

        LEA     x10, xhci_intput
        str     x9, [x10]
        LEA     x10, xhci_intcycle
        mov     w11, #1
        str     w11, [x10]
        LEA     x10, xhci_prod
        str     wzr, [x10]
        LEA     x10, xhci_cons
        str     wzr, [x10]
        LEA     x10, SYM(xhci_intdci)
        str     w27, [x10]

        mov     w0, #(12 << 10)                 /* Configure Endpoint */
        LEA     x1, xhci_input
        mov     w2, w19
        bl      xhci_command
        cmn     w0, #1
        b.eq    .Lxk_fail

/*
 * Ask for the boot protocol by name. A keyboard that supports it may still be
 * in report protocol, and the difference is not cosmetic: the two send
 * different bytes for the same key.
 */
        mov     w0, #11                         /* asking for boot protocol */
        bl      xhci_step
        LEA     x9, xhci_req
        mov     w10, #0x21                      /* OUT, class, to the interface */
        strb    w10, [x9]
        mov     w10, #0x0B                      /* SET_PROTOCOL */
        strb    w10, [x9, #1]
        strb    wzr, [x9, #2]                   /* boot */
        strb    wzr, [x9, #3]
        strb    w22, [x9, #4]                   /* of that interface */
        strb    wzr, [x9, #5]
        strb    wzr, [x9, #6]
        strb    wzr, [x9, #7]
        mov     w0, w19
        mov     x1, #0
        mov     w2, #0
        bl      SYM(xhci_control)
        /* A device that refuses this is still usable if it was already in boot
           protocol, which most are, so the answer is not checked. */

        LEA     x9, SYM(xhci_kbdslot)
        str     w19, [x9]
        mov     w0, #0
        bl      xhci_step
        mov     w0, #0
        b       .Lxk_out
.Lxk_fail:
        mov     w0, #-1
.Lxk_out:
        ldr     x27, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

/*
 * xhci_key - out w0 = an editor key, or -1 if nobody has pressed one.
 *
 * Never waits. It is called from the editor's idle loop, which also blinks a
 * caret and pumps everything else, so a keyboard that blocked would be a
 * keyboard that stopped the clock.
 *
 * <h2>A report is what is held down, not what was pressed</h2>
 *
 * The boot protocol sends eight bytes: modifiers, a byte nobody uses, and up
 * to six keys currently held. Holding a key sends the same report over and
 * over, so a reader that returned everything in every report would type one
 * character a thousand times. What is new is what is in this report and was
 * not in the last one, which is why the last one is kept.
 *
 * <h2>One layout, two sources</h2>
 *
 * The translation is the virtio keyboard's - the same tables, the same shift
 * handling, the same editor key codes. What differs is only the numbering the
 * hardware uses, so that is all this converts. Two layouts would be two things
 * to keep in step, and they would disagree the first time somebody added a
 * key to one of them.
 */
        .globl  SYM(xhci_key)
SYM(xhci_key):
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        str     x23, [sp, #48]

        LEA     x9, SYM(xhci_kbdslot)
        ldr     w19, [x9]
        cbz     w19, 9f

/* Keep the device supplied with somewhere to write. */
        bl      xhci_topup

        bl      xhci_event
        cmn     w0, #1
        b.eq    9f
        cmp     w0, #32                         /* a transfer event */
        b.ne    9f

/*
 * Which buffer this completion is for. They complete in the order they were
 * queued, so the oldest outstanding one is the answer and no search is needed.
 */
        LEA     x9, xhci_cons
        ldr     w9, [x9]
        and     w10, w9, #(REPORTS_N - 1)
        LEA     x20, xhci_reports
        add     x20, x20, w10, uxtw #3
        add     w9, w9, #1
        LEA     x10, xhci_cons
        str     w9, [x10]

/*
 * Modifiers first, because the translation reads them out of the same place
 * the other keyboard leaves them. Only shift and the command key matter to
 * this editor; control is the emulator's stand-in for command elsewhere and
 * is not one here, where there is a real one.
 */
        ldrb    w9, [x20]
        mov     w11, #0x22                      /* either shift; two separate
                                                   bits are not a logical
                                                   immediate, so it is a
                                                   register */
        tst     w9, w11
        cset    w10, ne
        LEA     x11, SYM(kbd_shift)
        str     w10, [x11]
        mov     w11, #0x88                      /* either command */
        tst     w9, w11
        cset    w10, ne
        LEA     x11, SYM(kbd_cmd)
        str     w10, [x11]

/* The first key here that was not in the report before it. */
        mov     w21, #2
2:      cmp     w21, #8
        b.hs    7f
        ldrb    w22, [x20, w21, uxtw]
        cbz     w22, 6f
        mov     w23, #2
3:      cmp     w23, #8
        b.hs    4f
        LEA     x9, xhci_before
        ldrb    w9, [x9, w23, uxtw]
        cmp     w9, w22
        b.eq    6f                              /* still held; not news */
        add     w23, w23, #1
        b       3b
4:      b       5f
6:      add     w21, w21, #1
        b       2b
7:      mov     w22, #0                         /* nothing new in it */
5:
        mov     w9, #0                          /* remember it for next time */
8:      cmp     w9, #8
        b.hs    10f
        ldrb    w10, [x20, w9, uxtw]
        LEA     x11, xhci_before
        strb    w10, [x11, w9, uxtw]
        add     w9, w9, #1
        b       8b
10:
        bl      xhci_topup                      /* ready for the next ones */
        cbz     w22, 9f

        cmp     w22, #HID_LAST_N
        b.hs    9f
        LEA     x9, hid_to_linux
        ldrb    w0, [x9, w22, uxtw]
        cbz     w0, 9f
        bl      SYM(kbd_translate)
        b       11f
9:      mov     w0, #-1
11:     ldr     x23, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * xhci_topup - keep several places queued for the device to write into.
 *
 * An interrupt endpoint does not push. The controller polls the device at the
 * interval the endpoint asked for, but only while it has somewhere to put an
 * answer - so a ring with nothing on it is a keyboard that has stopped.
 *
 * One buffer at a time is not enough, and the failure is silent. This is
 * polled from the editor's idle loop, which also blinks a caret and repaints;
 * anything typed between a report arriving and the next buffer being queued
 * has nowhere to go and is dropped. Typing twelve characters at it produced
 * two, which reads as a keyboard that works and is unreliable rather than one
 * that is wrong.
 *
 * So several are outstanding at once, each with its own buffer, and they
 * complete in the order they were queued - which is what makes a plain pair of
 * indices enough to say which buffer a completion belongs to.
 */
xhci_topup:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        str     x23, [sp, #48]

        bl      SYM(xhci_find)
        cbz     x0, 8f
        mov     x19, x0

        LEA     x9, xhci_prod
        ldr     w20, [x9]
        LEA     x9, xhci_cons
        ldr     w21, [x9]

1:      sub     w9, w20, w21
        cmp     w9, #REPORTS_OUT
        b.hs    2f

        LEA     x9, xhci_intput
        ldr     x22, [x9]
        LEA     x9, xhci_intcycle
        ldr     w23, [x9]

        and     w9, w20, #(REPORTS_N - 1)
        LEA     x10, xhci_reports
        add     x10, x10, w9, uxtw #3
        str     x10, [x22]
        mov     w10, #8
        str     w10, [x22, #8]
        movz    w10, #((1 << 10) | (1 << 5))    /* normal, interrupt */
        orr     w10, w10, w23
        str     w10, [x22, #12]
        add     x22, x22, #TRB_SZ
        add     w20, w20, #1

/*
 * If that filled the ring up to the link, follow it. The link's own cycle bit
 * has to be turned over as it is passed, or the controller stops at it
 * believing the rest has not been written yet.
 */
        LEA     x9, xhci_intring
        add     x10, x9, #((RING_TRBS - 1) * TRB_SZ)
        cmp     x22, x10
        b.lo    3f
        ldr     w11, [x10, #12]
        bic     w11, w11, #1
        orr     w11, w11, w23
        str     w11, [x10, #12]
        mov     x22, x9
        eor     w23, w23, #1
        LEA     x9, xhci_intcycle
        str     w23, [x9]
3:      LEA     x9, xhci_intput
        str     x22, [x9]
        b       1b

2:      LEA     x9, xhci_prod
        str     w20, [x9]

        dsb     sy
        ldr     w9, [x19, #XHCI_DBOFF]
        and     w9, w9, #0xFFFFFFFC
        add     x9, x19, w9, uxtw
        LEA     x10, SYM(xhci_intdci)
        ldr     w10, [x10]
        LEA     x11, SYM(xhci_kbdslot)
        ldr     w11, [x11]
        str     w10, [x9, w11, uxtw #2]
        dsb     sy

8:      ldr     x23, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * xhci_step - w0 = which stage is being attempted, remembered for the report.
 *
 * Enumeration is six things in a row and each fails differently: a port that
 * will not reset is a cable or a hub, a slot that is refused is a controller
 * out of them, an address that fails is a device that did not answer, and a
 * descriptor that never arrives is a transfer ring that is wrong. On a machine
 * with no debugger the difference between those is the difference between an
 * afternoon and a week, and "it did not work" says none of it.
 */
xhci_step:
        LEA     x9, SYM(xhci_stage)
        str     w0, [x9]
        ret

/*
 * xhci_control - w0 = a slot, x1 = a buffer or zero, w2 = how many bytes.
 *   The eight-byte request is in xhci_req, put there by the caller.
 *   out w0 = 0 if the device answered, -1 if it did not.
 *
 * A control transfer is three entries on the endpoint's own ring and they are
 * not three transfers: the setup stage says what is being asked, the data
 * stage says where the answer goes, and the status stage is the acknowledgement
 * that it is finished. Only the last carries Interrupt On Completion, because
 * one event for the whole exchange is what a caller wants and three would have
 * to be counted.
 *
 * <h2>Directions, which are the part that is easy to get backwards</h2>
 *
 * The setup stage names the transfer type: none, OUT or IN, from whether there
 * is data and which way the request's own direction bit points. The data stage
 * repeats it. The status stage is the *opposite* - an exchange that read from
 * the device is acknowledged by writing to it - and a transfer with no data at
 * all is acknowledged IN. Getting any of those wrong produces a device that
 * accepts the request and never completes it, which is the same silence as a
 * ring at the wrong address.
 */
        .globl  SYM(xhci_control)
SYM(xhci_control):
        stp     x29, x30, [sp, #-80]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        str     x25, [sp, #64]
        mov     w19, w0
        mov     x20, x1
        mov     w21, w2

        bl      SYM(xhci_find)
        cbz     x0, 9f
        mov     x22, x0

        LEA     x9, xhci_ep0put
        ldr     x23, [x9]
        LEA     x24, xhci_req

/* Which way this transfer goes, decided once and used three times. */
        ldrb    w25, [x24]                      /* bmRequestType */
        mov     w10, #0                         /* no data */
        cbz     w21, 1f
        tbnz    w25, #7, 2f
        mov     w10, #2                         /* to the device */
        b       1f
2:      mov     w10, #3                         /* from it */
1:
        ldr     w9, [x24]                       /* the request, as it stands */
        str     w9, [x23]
        ldr     w9, [x24, #4]
        str     w9, [x23, #4]
        mov     w9, #8
        str     w9, [x23, #8]
        movz    w9, #((2 << 10) | (1 << 6) | 1) /* setup, immediate, cycle */
        orr     w9, w9, w10, lsl #16
        str     w9, [x23, #12]
        add     x23, x23, #TRB_SZ

        cbz     w21, 3f
        str     x20, [x23]
        str     w21, [x23, #8]
        movz    w9, #((3 << 10) | 1)            /* data, cycle */
        cmp     w10, #3
        b.ne    4f
        movk    w9, #1, lsl #16                 /* and it comes from the device */
4:      str     w9, [x23, #12]
        add     x23, x23, #TRB_SZ

3:      str     xzr, [x23]
        str     wzr, [x23, #8]
        movz    w9, #((4 << 10) | (1 << 5) | 1) /* status, interrupt, cycle */
        cmp     w10, #3
        b.eq    5f
        movk    w9, #1, lsl #16                 /* acknowledged the other way */
5:      str     w9, [x23, #12]
        add     x23, x23, #TRB_SZ
        LEA     x9, xhci_ep0put
        str     x23, [x9]

/*
 * Ring the device's own doorbell. There is one per slot, and the value is
 * which endpoint has something waiting: one is the control endpoint, and the
 * numbering is the controller's rather than USB's.
 */
        dsb     sy
        ldr     w9, [x22, #XHCI_DBOFF]
        and     w9, w9, #0xFFFFFFFC
        add     x9, x22, w9, uxtw
        mov     w10, #1
        str     w10, [x9, w19, uxtw #2]
        dsb     sy

        mov     w0, #32                         /* a transfer event */
        bl      xhci_wait
        cmn     w0, #1
        b.eq    9f
/*
 * Success, or a short packet. Short is not a failure: a device that sent fewer
 * bytes than were asked for has still answered, and refusing it would refuse
 * every descriptor shorter than the buffer offered for it.
 */
        LEA     x9, xhci_last
        ldr     w9, [x9, #8]
        lsr     w9, w9, #24
        cmp     w9, #1
        b.eq    8f
        cmp     w9, #13
        b.ne    9f
8:      mov     w0, #0
        b       10f
9:      mov     w0, #-1
10:     ldr     x25, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #80
        ret

/*
 * xhci_ask - w0 = slot, w1 = descriptor type and index, x2 = where, w3 = how
 * many. A standard GET_DESCRIPTOR, which is most of what is ever asked.
 */
xhci_ask:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        str     x21, [sp, #32]
        mov     w19, w0
        mov     x20, x2
        mov     w21, w3

        LEA     x9, xhci_req
        mov     w10, #0x80                      /* IN, standard, to the device */
        strb    w10, [x9]
        mov     w10, #6                         /* GET_DESCRIPTOR */
        strb    w10, [x9, #1]
        strb    w1, [x9, #2]                    /* the index */
        lsr     w10, w1, #8
        strb    w10, [x9, #3]                   /* and the type above it */
        strb    wzr, [x9, #4]
        strb    wzr, [x9, #5]
        strb    w21, [x9, #6]
        lsr     w10, w21, #8
        strb    w10, [x9, #7]

        mov     w0, w19
        mov     x1, x20
        mov     w2, w21
        bl      SYM(xhci_control)
        ldr     x21, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

/*
 * xhci_command - w0 = the TRB type and flags, x1 = a parameter, w2 = a slot.
 *   out w0 = the completion code, or -1 if nothing came back.
 *
 * One place for every command, because the shape is always the same and the
 * part that is easy to get wrong - ring the right doorbell, wait for the right
 * event, read the code out of the right byte - is the part that does not vary.
 */
xhci_command:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        str     x23, [sp, #48]
        mov     w19, w0
        mov     x20, x1
        mov     w21, w2

        bl      SYM(xhci_find)
        cbz     x0, 9f
        mov     x22, x0

        LEA     x9, xhci_put
        ldr     x23, [x9]
        str     x20, [x23]
        str     wzr, [x23, #8]
        orr     w10, w19, #TRB_CYCLE
        orr     w10, w10, w21, lsl #24          /* which slot, where it matters */
        str     w10, [x23, #12]
        add     x23, x23, #TRB_SZ
        str     x23, [x9]

        dsb     sy
        ldr     w9, [x22, #XHCI_DBOFF]
        and     w9, w9, #0xFFFFFFFC
        add     x9, x22, w9, uxtw
        str     wzr, [x9]
        dsb     sy

        mov     w0, #TRB_CMD_DONE
        bl      xhci_wait
        cmn     w0, #1
        b.eq    9f
        LEA     x9, xhci_last
        ldr     w9, [x9, #8]
        lsr     w0, w9, #24                     /* the completion code */
        cmp     w0, #1
        b.ne    9f
        b       10f
9:      mov     w0, #-1
10:     ldr     x23, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

/*
 * xhci_ctxsize - out w0 = 32 or 64, whichever this controller uses.
 *
 * A context is one size or the other and the controller says which, in a
 * single bit. Guessing puts every field after the first one at the wrong
 * offset, which the controller reads as a device on a port that does not
 * exist, at a speed that is not a speed.
 */
xhci_ctxsize:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        bl      SYM(xhci_find)
        cbz     x0, 9f
        ldr     w0, [x0, #0x10]                 /* HCCPARAMS1 */
        tbz     w0, #2, 9f                      /* CSZ */
        mov     w0, #64
        b       8f
9:      mov     w0, #32
8:      ldp     x29, x30, [sp], #16
        ret

/*
 * xhci_attached - out w0 = how many root ports have something plugged in.
 *
 * The first thing a USB stack can prove without being one. A controller that
 * resets, reports its shape and then says a device is connected on port two is
 * a controller this kernel is genuinely talking to - and on an unfamiliar
 * machine that is the difference between a wrong base address and a driver
 * bug, which are otherwise the same silence.
 */
        .globl  SYM(xhci_attached)
SYM(xhci_attached):
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]

        bl      SYM(xhci_find)
        cbz     x0, 9f
        mov     x19, x0
        bl      SYM(xhci_caplength)
        add     x20, x19, w0, uxtw
        bl      SYM(xhci_ports)
        mov     w21, w0
        cbz     w21, 9f

        mov     w22, #0                 /* how many are occupied */
        mov     w9, #0
1:      cmp     w9, w21
        b.hs    8f
        add     x10, x20, #XHCI_PORTSC
        add     x10, x10, x9, lsl #4    /* each port's block is sixteen bytes */
        ldr     w11, [x10]
        tbz     w11, #0, 2f             /* CCS */
        add     w22, w22, #1
2:      add     w9, w9, #1
        b       1b

8:      mov     w0, w22
        b       10f
9:      mov     w0, #0
10:     ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

        RODATA
/*
 * USB says which key by a number of its own, and Linux by another. The tables
 * that turn a key into a character are the other keyboard's and are indexed
 * the Linux way, so this is the only thing that has to be converted - one
 * layout, kept in one place, reached from two kinds of hardware.
 *
 * It stops at the arrow keys. Everything past them on a boot keyboard is a
 * keypad or a function key, and this editor has no use for either.
 */
        .p2align 2
hid_to_linux:
        .byte 0, 0, 0, 0                                        /* 00-03 */
        .byte 30, 48, 46, 32, 18, 33, 34, 35, 23, 36            /* a-j    */
        .byte 37, 38, 50, 49, 24, 25, 16, 19, 31, 20            /* k-t    */
        .byte 22, 47, 17, 45, 21, 44                            /* u-z    */
        .byte 2, 3, 4, 5, 6, 7, 8, 9, 10, 11                    /* 1-0    */
        .byte 28, 1, 14, 15, 57                                 /* enter, esc,
                                                                   backspace,
                                                                   tab, space */
        .byte 12, 13, 26, 27, 43, 0, 39, 40, 41                 /* -=[]\ ;'` */
        .byte 51, 52, 53, 0                                     /* ,./ caps  */
        .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0                /* f1-f12    */
        .byte 0, 0, 0                                           /* print etc */
        .byte 0, 102, 0, 0, 107, 0                              /* home, end */
        .byte 106, 105, 108, 103                                /* the arrows */

s_dwc3:     .asciz "snps,dwc3"
s_xhci_dt:  .asciz "generic-xhci"

        BSS
/*
 * Eight-byte fields first, four-byte fields after them.
 *
 * Not tidiness. The MMU is off, so all memory is Device type and a 64-bit
 * store to a four-byte-aligned address is an alignment fault rather than a
 * slow write. Declared in the order they were thought of, a four-byte flag
 * sat between two pointers and put the second one on a 0x4 boundary, and the
 * kernel faulted the first time it recorded where the next event would appear.
 * Grouping by width means the padding cannot come back.
 */
        .p2align 3
xhci_base:   .space 8
xhci_next:   .space 8                   /* where the next event will appear */
xhci_last:   .space 16                  /* and the one that just did, whole */
xhci_intr:   .space 8                   /* interrupter zero's registers */
xhci_put:    .space 8                   /* where the next command goes */
xhci_looked: .space 4
xhci_cycle:  .space 4                   /* which cycle bit says an event is new */

/*
 * The controller reads these by physical address, so their alignment is a
 * hardware requirement rather than a preference: sixty-four bytes for a ring,
 * a segment table and the slot array alike, and a misaligned one is quietly
 * ignored rather than refused.
 */
        .p2align 6
xhci_dcbaa:  .space 512
        .p2align 6
xhci_cmd:    .space (RING_TRBS * TRB_SZ)
        .p2align 6
xhci_evt:    .space (RING_TRBS * TRB_SZ)
        .p2align 6
xhci_erst:   .space 64
        .p2align 6
xhci_input:  .space (33 * 64)           /* what we tell the controller */
        .p2align 6
xhci_devctx: .space (32 * 64)           /* what it tells us back */
        .p2align 6
xhci_ep0:    .space (RING_TRBS * TRB_SZ)
        .p2align 6
xhci_desc:   .space 32                  /* what the device says it is */
        .p2align 6
xhci_req:    .space 8                   /* the eight bytes of a request */
        .p2align 6
xhci_cfg:    .space 256                 /* the configuration, as it arrived */
        .p2align 6
xhci_intring: .space (RING_TRBS * TRB_SZ)
        .p2align 3
xhci_intput: .space 8
        .globl  SYM(xhci_intdci)
        .globl  SYM(xhci_kbdslot)
SYM(xhci_intdci):  .space 4
SYM(xhci_kbdslot): .space 4
xhci_prod:   .space 4                   /* buffers handed to the controller */
xhci_cons:   .space 4                   /* and buffers read back out */
xhci_intcycle: .space 4
        .p2align 6
xhci_reports: .space (REPORTS_N * 8)    /* what is held down, several deep */
xhci_before:  .space 8                  /* and what was, last time */
        .p2align 3
xhci_ep0put: .space 8
        .globl  SYM(xhci_vendor)
        .globl  SYM(xhci_product)
        .globl  SYM(xhci_class)
SYM(xhci_vendor):  .space 4
SYM(xhci_product): .space 4
SYM(xhci_class):   .space 4
        .globl  SYM(xhci_stage)
SYM(xhci_stage):   .space 4
