#include "asm.inc"
/*
 * wdt.S - restarting a machine that has no PSCI.
 *
 * Everywhere else this kernel runs, a reboot is a function call: PSCI's
 * SYSTEM_RESET, made with hvc or smc depending on what the device tree says is
 * underneath. QEMU has it, the Virtualization framework has it, every arm64
 * server has it.
 *
 * Apple Silicon does not. There is no secure monitor offering PSCI to an
 * operating system booted by m1n1, and the hvc that works everywhere else goes
 * nowhere - or worse, somewhere unintended. The machine restarts the way the
 * hardware restarts: by telling a watchdog to stop being fed and then setting
 * the clock so it is already too late.
 *
 * <h2>Three writes, in this order</h2>
 *
 *   control   = reset enable      say what expiry should do
 *   bite time = 0                 expire at zero
 *   current   = 0                 which is now
 *
 * The order matters and it is the only reason this is not one write. Arming
 * the counter before saying what expiry means would let it expire into a
 * default, and the default is not necessarily a reset. Setting the current
 * time before the bite time leaves a window - short, but a window - in which
 * the counter is past a bite time that has not been written yet.
 *
 * The registers are the second watchdog's, at 0x10, 0x14 and 0x1c. The first
 * one, at 0x00, is the one the system uses; this is the one a driver is
 * expected to take. Reset enable is bit two.
 *
 * <h2>Why the address is not written down here</h2>
 *
 * It moves between SoCs. The tree says where it is, and the tree is the thing
 * that is right about the machine it came from - a constant here would be
 * right about one Mac and would put a store into somebody else's device on
 * every other. The node is `apple,wdt`, which every Apple device tree carries
 * as the general half of a compatible list whose specific half names the chip.
 *
 * <h2>What is proved and what is not</h2>
 *
 * The discovery is tested and the write sequence is tested - tests/wdt.py puts
 * a watchdog-shaped region in the tree, points it at ordinary memory, and
 * reads back what landed there and in what order. What no test here can prove
 * is that a real Apple watchdog answers these three writes by restarting the
 * machine, because that requires the machine. The sequence is the one Linux's
 * apple_wdt driver performs, which is the closest thing to a specification
 * that exists for a part with no public documentation.
 */

#define WDT_WD1_CUR_TIME        0x10
#define WDT_WD1_BITE_TIME       0x14
#define WDT_WD1_CTRL            0x1c
#define WDT_CTRL_RESET_EN       (1 << 2)

        CODE
        .p2align 2

/*
 * wdt_find - out x0 = the watchdog's base address, or 0.
 *
 * Separate from the reboot so that a machine can be asked whether it has one
 * without being restarted to find out, which is the sort of test that only
 * runs once.
 */
        .globl  SYM(wdt_find)
SYM(wdt_find):
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        LEA     x0, s_apple_wdt
        mov     w1, #0
        bl      SYM(dtb_reg)
        ldp     x29, x30, [sp], #16
        ret

/*
 * wdt_reboot - restart through the watchdog.
 *   out w0 = -1, and only ever -1: there is no watchdog, or there is one and
 *   it did not bite. Coming back at all is the failure.
 *
 * The wait afterwards is not politeness. The reset is queued rather than
 * immediate and takes some tens of milliseconds to arrive, and a caller that
 * treated an instant return as a refusal would fall through to something else
 * while the machine was already on its way down - reporting a failure that was
 * about to be contradicted by the hardware.
 */
        .globl  SYM(wdt_reboot)
SYM(wdt_reboot):
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]

        bl      SYM(wdt_find)
        cbz     x0, 9f
        mov     x19, x0

        bl      SYM(wdt_arm)

        mov     x0, #200                /* milliseconds; it needs about 25 */
        bl      wdt_wait_ms

9:      mov     w0, #-1
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/*
 * wdt_arm - x0 = the watchdog's base. Sets it to bite immediately.
 *
 * Apart from wdt_reboot's own search this is the whole of the mechanism, and
 * it is a separate entry point because it is the half that can be tested
 * without a watchdog: pointed at ordinary memory it leaves exactly the three
 * words it would have left in a real one, and a test can read them back.
 *
 * Nothing is written at offset zero. That is the first watchdog, which the
 * system itself uses; taking it would be reaching past the one a driver is
 * given, and the failure would not be visible until something else wanted it.
 */
        .globl  SYM(wdt_arm)
SYM(wdt_arm):
        mov     w9, #WDT_CTRL_RESET_EN
        str     w9, [x0, #WDT_WD1_CTRL]
        str     wzr, [x0, #WDT_WD1_BITE_TIME]
        str     wzr, [x0, #WDT_WD1_CUR_TIME]
        /*
         * Read it back. On Device memory the stores have already left the
         * core; the read is what proves they reached the far side of whatever
         * lies between here and the watchdog rather than sitting in it.
         */
        ldr     w9, [x0, #WDT_WD1_CTRL]
        ret

/*
 * wdt_wait_ms - x0 = milliseconds, spun out on the architectural timer.
 *
 * Counted here rather than borrowed from the platform layer so that this file
 * needs nothing but the tree and the CPU. It is called on the way out of a
 * machine, which is the worst moment to depend on anything else still working.
 *
 * A machine with no counter frequency returns at once. Waiting forever for a
 * reset that is already happening and waiting not at all for one that is not
 * have the same outcome, and only one of them can be told apart from a hang.
 */
wdt_wait_ms:
        mrs     x1, cntfrq_el0
        cbz     x1, 9f
        mov     x2, #1000
        mul     x0, x0, x1
        udiv    x0, x0, x2              /* ticks to wait */
        mrs     x2, cntvct_el0
        add     x0, x0, x2
1:      mrs     x2, cntvct_el0
        cmp     x2, x0
        b.lo    1b
9:      ret

        RODATA
s_apple_wdt: .asciz "apple,wdt"
