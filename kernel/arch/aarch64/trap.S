#include "asm.inc"
/*
 * trap.S - what happens when something goes wrong.
 *
 * Until this file existed, it was nothing. A null dereference, an unaligned
 * load, a branch into the middle of a string - all of them landed on a vector
 * table that had never been installed, and the machine simply stopped. No
 * output, no register dump, not even a distinction between "faulted" and
 * "hung in a loop". Twice this cost a day: once on an unaligned 32-bit read
 * that is legal everywhere except here, and once on a stray branch.
 *
 * The distinction matters more than it sounds. A kernel that prints ESR and
 * ELR turns "it hangs" into "it took a data abort at this instruction on this
 * address", and that is the difference between bisecting a morning away and
 * reading one line.
 *
 * <h2>Why unaligned access faults at all</h2>
 *
 * The MMU is off, and with it off every access is Device-nGnRnE memory
 * regardless of what the RAM actually is. Device memory does not permit
 * unaligned access, so a perfectly ordinary `ldr w0, [x1]` where x1 is odd
 * takes an alignment fault. That is not a bug in the CPU and not a quirk of
 * QEMU; it is what the architecture says, and it is the single most common way
 * this kernel breaks, which is why the report names it explicitly rather than
 * printing a number.
 *
 * <h2>The table</h2>
 *
 * VBAR_EL1 points at sixteen entries of 128 bytes: four exception kinds
 * (synchronous, IRQ, FIQ, SError) for each of four origins. We run at EL1 with
 * SP_EL1 selected, so faults in our own code arrive in the second group. The
 * others are installed anyway - an exception from an origin we do not use is
 * exactly the surprise worth reporting rather than ignoring.
 *
 * Every handler reports and halts. There is nothing to recover to: this kernel
 * has one thread, no process to kill, and a fault means its state is already
 * not what the code believed. Continuing would only move the evidence.
 */

/* Each vector slot is 128 bytes; the table itself must be 2KB-aligned. */
.macro VECTOR label, kind
        .align  7
        msr     tpidr_el1, x0           /* x0 is about to be overwritten with
                                           the vector number, and x0 is usually
                                           the most interesting register there
                                           is - stash it somewhere no code here
                                           uses before taking it */
        mov     x0, #\kind
        b       \label
.endm

        .section .text
        .p2align 11
        .globl  trap_vectors
trap_vectors:
        /* Current EL, SP_EL0 - we never select SP_EL0, so these are surprises. */
        VECTOR  trap_common, 0
        VECTOR  trap_common, 1
        VECTOR  trap_common, 2
        VECTOR  trap_common, 3

        /* Current EL, SP_EL1 - this is where our own faults arrive. */
        VECTOR  trap_common, 4
        VECTOR  trap_common, 5
        VECTOR  trap_common, 6
        VECTOR  trap_common, 7

        /* Lower EL, aarch64 - nothing runs below us. */
        VECTOR  trap_common, 8
        VECTOR  trap_common, 9
        VECTOR  trap_common, 10
        VECTOR  trap_common, 11

        /* Lower EL, aarch32. */
        VECTOR  trap_common, 12
        VECTOR  trap_common, 13
        VECTOR  trap_common, 14
        VECTOR  trap_common, 15

/*
 * The report.
 *
 * x0 holds which vector we came through. Nothing here may assume any other
 * register is meaningful - that is the whole point - so the first thing it
 * does is put all of them somewhere it can print from, before running any code
 * that would overwrite them.
 */
trap_common:
        msr     tpidr_el0, x18          /* and the same problem again: x18 is
                                           about to become the pointer that
                                           saves everything else, so it cannot
                                           be saved through itself */
        LEA     x18, trap_regs
        str     x0, [x18, #288]         /* which vector we arrived through */
        mrs     x0, tpidr_el1           /* the real x0, from the stub */
        str     x0, [x18, #0]
        str     x1, [x18, #8]
        stp     x2, x3, [x18, #16]
        stp     x4, x5, [x18, #32]
        stp     x6, x7, [x18, #48]
        stp     x8, x9, [x18, #64]
        stp     x10, x11, [x18, #80]
        stp     x12, x13, [x18, #96]
        stp     x14, x15, [x18, #112]
        stp     x16, x17, [x18, #128]
        mrs     x0, tpidr_el0           /* the real x18, stashed on entry */
        str     x0, [x18, #144]
        stp     x19, x20, [x18, #152]
        stp     x21, x22, [x18, #168]
        stp     x23, x24, [x18, #184]
        stp     x25, x26, [x18, #200]
        stp     x27, x28, [x18, #216]
        stp     x29, x30, [x18, #232]

        mrs     x0, esr_el1
        mrs     x1, elr_el1
        mrs     x2, far_el1
        mrs     x3, spsr_el1
        stp     x0, x1, [x18, #248]
        stp     x2, x3, [x18, #264]
        mov     x0, sp
        str     x0, [x18, #280]

        /* A private stack, because the faulting one may be why we are here. */
        LEA     x0, trap_stack_top
        mov     sp, x0

        LEA     x0, m_rule
        bl      trap_say
        LEA     x0, m_fault
        bl      trap_say

        /* Which vector, and what the ESR says it was. */
        LEA     x18, trap_regs
        ldr     x0, [x18, #288]
        bl      trap_vecname
        bl      trap_say
        LEA     x18, trap_regs
        ldr     x0, [x18, #248]
        lsr     w0, w0, #26
        and     w0, w0, #0x3F           /* EC - the exception class */
        bl      trap_cause
        bl      trap_say
        LEA     x0, m_nl
        bl      trap_say

        LEA     x0, m_esr
        bl      trap_say
        LEA     x18, trap_regs
        ldr     x0, [x18, #248]
        bl      trap_hex64
        LEA     x0, m_elr
        bl      trap_say
        LEA     x18, trap_regs
        ldr     x0, [x18, #256]
        bl      trap_hex64
        LEA     x0, m_nl
        bl      trap_say

        LEA     x0, m_far
        bl      trap_say
        LEA     x18, trap_regs
        ldr     x0, [x18, #264]
        bl      trap_hex64
        LEA     x0, m_sp
        bl      trap_say
        LEA     x18, trap_regs
        ldr     x0, [x18, #280]
        bl      trap_hex64
        LEA     x0, m_nl
        bl      trap_say

        /*
         * The registers, four to a line. Printed because the interesting
         * question after "where" is almost always "with what" - the pointer
         * that was null, the length that was negative.
         */
        mov     w19, #0                 /* which register */
1:      cmp     w19, #31
        b.hs    3f
        and     w0, w19, #3
        cbnz    w0, 2f
        LEA     x0, m_nl
        bl      trap_say
2:      mov     w0, w19
        bl      trap_regname
        LEA     x18, trap_regs
        ldr     x0, [x18, w19, uxtw #3]
        bl      trap_hex64
        LEA     x0, m_sp2
        bl      trap_say
        add     w19, w19, #1
        b       1b

3:      LEA     x0, m_nl
        bl      trap_say
        LEA     x0, m_halt
        bl      trap_say
        LEA     x0, m_rule
        bl      trap_say

/*
 * Stop, loudly rather than quietly.
 *
 * wfe rather than a spin: the difference is invisible from inside, but a host
 * watching the guest sees an idle CPU instead of one core pinned at 100%, and
 * "hung" and "wedged in a loop" stop looking alike from outside too.
 */
4:      wfe
        b       4b

/*
 * Say something on every output there is.
 *
 * The serial port always works, including before the framebuffer exists and
 * after whatever went wrong went wrong. The console is tried too, because the
 * person looking at a QEMU window should not have to know there was also a
 * serial log.
 */
trap_say:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     x19, x0
        bl      uart_puts
        mov     x0, x19
        bl      console_puts
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/* trap_hex64 - x0 as sixteen hex digits, high half then low. */
trap_hex64:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     x19, x0
        lsr     x0, x19, #32
        bl      trap_hex32
        mov     w0, w19
        bl      trap_hex32
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

trap_hex32:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        mov     w19, w0
        mov     w20, #28
1:      lsr     w0, w19, w20
        and     w0, w0, #0xF
        cmp     w0, #10
        b.lo    2f
        add     w0, w0, #('a' - 10)
        b       3f
2:      add     w0, w0, #'0'
3:      bl      uart_putc
        lsr     w1, w19, w20            /* the same digit, for the screen */
        and     w1, w1, #0xF
        cmp     w1, #10
        b.lo    4f
        add     w1, w1, #('a' - 10)
        b       5f
4:      add     w1, w1, #'0'
5:      mov     w0, w1
        bl      console_putc
        subs    w20, w20, #4
        b.ge    1b
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/* trap_regname - w0 = 0..30, prints "x7 " padded so columns line up. */
trap_regname:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     w19, w0
        mov     w0, #'x'
        bl      trap_putc
        cmp     w19, #10
        b.lo    1f
        mov     w0, #10
        udiv    w1, w19, w0
        add     w0, w1, #'0'
        bl      trap_putc
        mov     w0, #10
        udiv    w1, w19, w0
        msub    w19, w1, w0, w19
        b       2f
1:      mov     w0, #' '
        bl      trap_putc
2:      add     w0, w19, #'0'
        bl      trap_putc
        mov     w0, #'='
        bl      trap_putc
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

trap_putc:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     w19, w0
        bl      uart_putc
        mov     w0, w19
        bl      console_putc
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

/*
 * trap_vecname - x0 = which of the sixteen slots, x0 = something to read.
 *
 * The group matters as much as the class: a synchronous fault is our own code
 * doing something impossible, an IRQ is a device asking for attention that
 * nothing here has been written to give, and an SError is usually the bus
 * complaining about an access that already appeared to succeed.
 */
trap_vecname:
        and     w1, w0, #3
        lsr     w2, w0, #2
        cmp     w2, #1
        b.eq    1f
        LEA     x0, v_elsewhere
        ret
1:      cmp     w1, #0
        b.ne    2f
        LEA     x0, v_sync
        ret
2:      cmp     w1, #1
        b.ne    3f
        LEA     x0, v_irq
        ret
3:      cmp     w1, #2
        b.ne    4f
        LEA     x0, v_fiq
        ret
4:      LEA     x0, v_serror
        ret

/*
 * trap_cause - w0 = the ESR exception class, x0 = something to read.
 *
 * Only the classes this kernel can actually produce are named. A number for
 * the rest is honest: inventing a description for an exception we have never
 * seen would be guessing in the one place where guessing already cost days.
 */
trap_cause:
        cmp     w0, #0x21               /* instruction abort, same EL */
        b.ne    1f
        LEA     x0, c_iabort
        ret
1:      cmp     w0, #0x25               /* data abort, same EL */
        b.ne    2f
        LEA     x0, c_dabort
        ret
2:      cmp     w0, #0x22               /* PC alignment */
        b.ne    3f
        LEA     x0, c_pcalign
        ret
3:      cmp     w0, #0x26               /* SP alignment */
        b.ne    4f
        LEA     x0, c_spalign
        ret
4:      cmp     w0, #0x00               /* unknown reason - often a bad opcode */
        b.ne    5f
        LEA     x0, c_unknown
        ret
5:      cmp     w0, #0x18               /* trapped MSR/MRS/system instruction */
        b.ne    6f
        LEA     x0, c_sysreg
        ret
6:      cmp     w0, #0x15               /* SVC from aarch64 */
        b.ne    7f
        LEA     x0, c_svc
        ret
7:      LEA     x0, c_other
        ret

        RODATA
m_rule:     .asciz "\n================================================================\n"
m_fault:    .asciz "*** KERNEL FAULT: "
m_esr:      .asciz "ESR  "
m_elr:      .asciz "   ELR  "
m_far:      .asciz "FAR  "
m_sp:       .asciz "   SP   "
m_sp2:      .asciz " "
m_nl:       .asciz "\n"
m_halt:     .asciz "\nhalted. this kernel has one thread and nothing to kill, so\nrecovering would only move the evidence.\n"

v_sync:     .asciz "synchronous, "
v_irq:      .asciz "IRQ with no handler, "
v_fiq:      .asciz "FIQ with no handler, "
v_serror:   .asciz "SError, "
v_elsewhere: .asciz "from an execution state this kernel does not use, "

c_dabort:   .asciz "data abort (a bad address, or an unaligned access - the MMU is off, so all memory is Device type and unaligned loads are illegal)"
c_iabort:   .asciz "instruction abort (branched somewhere there is no code)"
c_pcalign:  .asciz "PC alignment (branched to an odd address)"
c_spalign:  .asciz "SP alignment (the stack pointer is not 16-byte aligned)"
c_unknown:  .asciz "unknown reason (usually an illegal instruction)"
c_sysreg:   .asciz "trapped system register access"
c_svc:      .asciz "SVC - a syscall, and there is no kernel below this one to take it"
c_other:    .asciz "an exception class this kernel has never seen"

        BSS
        .p2align 3
/*
 * x0..x30 at 0..247, then ESR, ELR, FAR, SPSR, SP.
 * x18 is stored last from a copy, since it is the register doing the storing.
 */
trap_regs:  .space 320
        .p2align 4
trap_stack: .space 8192
trap_stack_top:
