#include "asm.inc"
#include "editor.inc"
/*
 * uartkey.S - the serial line as a keyboard.
 *
 * A byte off the wire is not an editor key: arrows arrive as escape sequences
 * spread over several polls, and the control codes have to be unpicked. That
 * translation belongs here rather than in the editor, because the editor
 * should be handed keys whatever the machine has - a UART on one board, a
 * virtio keyboard on another, and neither of them the editor's business.
 *
 * Getting that boundary wrong is not a theoretical worry. When platform_getc
 * started returning editor keys from a real keyboard, the editor was still
 * putting them through this decoder as though they were raw bytes - so K_BS,
 * which is 0x08, came back out as Ctrl+H, which is Cmd+Delete; and K_ENTER,
 * which is 0x0A, came out as Ctrl+J, which is Cmd+Enter. Letters survived
 * because printable bytes pass through unchanged, which is exactly what made
 * it look like backspace alone was broken.
 */

/* Where we are in an escape sequence, since getc never blocks. */
#define ESC_NONE        0
#define ESC_ESC         1
#define ESC_BRACKET     2

        .section .text
        .p2align 2

/*
 * uart_key - one editor key from the serial line, or -1.
 *
 * The escape state lives in memory rather than in registers because the bytes
 * of one sequence arrive on separate calls, with the whole editor running in
 * between.
 */
        .globl  uart_key
uart_key:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        bl      uart_getc
        cmn     w0, #1
        b.eq    9f
        LEA     x9, esc_state
        ldr     w7, [x9]
        LEA     x9, esc_param
        ldr     w5, [x9]
        bl      uart_key_decode
        LEA     x9, esc_state
        str     w7, [x9]
        LEA     x9, esc_param
        str     w5, [x9]
9:      ldp     x29, x30, [sp], #32
        ret

/*
 * .Lke_translate - w0 = a byte off the wire, out w0 = an editor key or -1.
 *
 * w7 carries the escape state between calls and w5 the numeric parameter,
 * because the bytes of a sequence arrive on separate polls and there is
 * nothing to block on in between.
 *
 * The awkward part of a serial keyboard is that the control codes are already
 * spoken for. Ctrl+M *is* Return and Ctrl+H *is* Backspace - a terminal sends
 * the same byte either way, so those two Ctrl combinations cannot be told
 * apart from the plain keys and cannot carry Cmd. The two that are left over
 * take their place: Ctrl+J, which is what Ctrl+Enter sends on a real keyboard
 * anyway, and DEL against Ctrl+H for the two kinds of erase.
 */
uart_key_decode:
        cmp     w7, #ESC_NONE
        b.eq    .Lkt_plain
        cmp     w7, #ESC_ESC
        b.eq    .Lkt_esc

/* Inside a sequence: digits and ';' are the parameters, a letter ends it. */
        cmp     w0, #'0'
        b.lo    1f
        cmp     w0, #'9'
        b.hi    1f
        mov     w9, #10                 /* accumulate this parameter */
        mul     w5, w5, w9
        sub     w9, w0, #'0'
        add     w5, w5, w9
        mov     w0, #-1
        ret
1:      cmp     w0, #';'
        b.ne    2f
        mov     w5, #0                 /* the modifier is the last one */
        mov     w0, #-1
        ret

2:      mov     w7, #ESC_NONE
        mov     w6, #0                 /* what the parameter says was held */
        cmp     w5, #2
        b.lo    3f
        sub     w9, w5, #1             /* xterm: 1 + shift + 2*alt + 4*ctrl */
        tbz     w9, #0, 4f
        mov     w6, #MOD_SHIFT
4:      tbz     w9, #2, 3f
        orr     w6, w6, #MOD_CMD      /* Ctrl stands in for Cmd here too */
3:      mov     w5, #0

        cmp     w0, #'A'
        b.ne    5f
        mov     w0, #K_UP
        b       .Lkt_mod
5:      cmp     w0, #'B'
        b.ne    6f
        mov     w0, #K_DOWN
        b       .Lkt_mod
6:      cmp     w0, #'C'
        b.ne    7f
        mov     w0, #K_RIGHT
        b       .Lkt_mod
7:      cmp     w0, #'D'
        b.ne    8f
        mov     w0, #K_LEFT
        b       .Lkt_mod
8:      cmp     w0, #'H'
        b.ne    9f
        mov     w0, #K_HOME
        b       .Lkt_mod
9:      cmp     w0, #'F'
        b.ne    10f
        mov     w0, #K_END
        b       .Lkt_mod
10:     mov     w0, #-1                 /* some sequence we do not speak */
        ret
.Lkt_mod:
        orr     w0, w0, w6
        ret

.Lkt_esc:
        cmp     w0, #'['
        b.eq    1f
        cmp     w0, #'O'
        b.eq    1f
        mov     w7, #ESC_NONE          /* ESC then something else: a bare ESC */
        mov     w0, #-1
        ret
1:      mov     w7, #ESC_BRACKET
        mov     w5, #0
        mov     w0, #-1
        ret

.Lkt_plain:
        cmp     w0, #0x1B
        b.ne    1f
        mov     w7, #ESC_ESC
        mov     w0, #-1
        ret

1:      cmp     w0, #0x7F               /* DEL: erase a character */
        b.ne    2f
        mov     w0, #K_BS
        ret
2:      cmp     w0, #0x08               /* Ctrl+H: erase the screen */
        b.ne    3f
        mov     w0, #K_BS
        orr     w0, w0, #MOD_CMD
        ret
3:      cmp     w0, #'\r'               /* Return */
        b.ne    4f
        mov     w0, #K_ENTER
        ret
4:      cmp     w0, #'\n'               /* Ctrl+J: hand the screen over */
        b.ne    5f
        mov     w0, #K_ENTER
        orr     w0, w0, #MOD_CMD
        ret

5:      cmp     w0, #0x01               /* every other Ctrl+letter is Cmd+it */
        b.lo    6f
        cmp     w0, #0x1A
        b.hi    6f
        add     w0, w0, #('a' - 1)
        orr     w0, w0, #MOD_CMD
        ret
6:      cmp     w0, #' '                /* anything printable is itself */
        b.lo    7f
        cmp     w0, #0x7E
        b.hi    7f
        ret
7:      mov     w0, #-1
        ret


        .section .bss
        .p2align 2
esc_state:      .space 4
esc_param:      .space 4
