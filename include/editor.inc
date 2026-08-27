/*
 * editor.inc - key codes and palette shared by the editor core and both of its
 * front ends.  The front ends differ in how a keypress arrives (an NSEvent on
 * macOS, a byte off the UART on bare metal) but agree on what it means once
 * translated into these codes.
 */
#ifndef ARMEDIT_EDITOR_INC
#define ARMEDIT_EDITOR_INC

/* Keys.  Printable characters are themselves; these fill in the rest. */
#define K_BS            0x08
#define K_TAB           0x09
#define K_ENTER         0x0A
#define K_LEFT          0x100
#define K_RIGHT         0x101
#define K_UP            0x102
#define K_DOWN          0x103
#define K_HOME          0x104
#define K_END           0x105

/* Modifiers.  Cmd on macOS; Ctrl on the serial console, which has no Cmd. */
#define MOD_CMD         0x1000
#define MOD_SHIFT       0x2000

/* What editor_key reports back to the front end. */
#define ED_NONE         0
#define ED_SUBMIT       1               /* Cmd+Enter: hand the screen over    */
#define ED_AIFY         2               /* Cmd+P: rewrite what is on screen   */
#define ED_SWIPE        3               /* a swipe: do something with this    */

/* Applet actions above this are front-end commands rather than key codes. */
#define AP_ACT_ASK      0x2000          /* what Cmd+Enter does */
#define AP_ACT_REWRITE  0x2001          /* what Cmd+P does     */

/* Screens */
#define MAX_SCREENS     8
#define SCR_BUF_SZ      8192
#define SCR_HDR         64
#define SCR_STRIDE      (SCR_HDR + 2 * SCR_BUF_SZ)
#define SCR_LEN_OFF     0
#define SCR_CUR_OFF     4
#define SCR_SCROLL_OFF  8
#define SCR_BASELEN_OFF 12              /* length of the last synced snapshot */
#define SCR_SUBJ_OFF    16              /* what this screen is about, if anything */
#define SCR_SUBJ_MAX    40
#define SCR_TEXT_OFF    SCR_HDR
/* Each screen carries a second copy of its text: what it looked like the last
   time the backend saw it.  Sending both is what lets the far side reason
   about the edit rather than the file. */
#define SCR_BASE_OFF    (SCR_HDR + SCR_BUF_SZ)

/* Palette, 0xAARRGGBB - the same numbers in a window and on bare metal. */
#define COL_BG          0xFF141618
#define COL_FG          0xFF8AE2B8
#define COL_DIM         0xFF3A4048
#define COL_BAR         0xFF1D2228
#define COL_CURSOR      0xFFE2B85A
#define COL_SEL         0xFF2E4A3E      /* the swiped span, behind the text */

/* Colours as movz/movk halves: a 32-bit constant needs two instructions, and
   spelling it out beats relying on a literal pool that only one of our two
   assemblers is guaranteed to build. */
#define COL_BG_LO       0x1618
#define COL_BG_HI       0xFF14
#define COL_FG_LO       0xE2B8
#define COL_FG_HI       0xFF8A
#define COL_DIM_LO      0x4048
#define COL_DIM_HI      0xFF3A
#define COL_BAR_LO      0x2228
#define COL_BAR_HI      0xFF1D
#define COL_CURSOR_LO   0xB85A
#define COL_CURSOR_HI   0xFFE2
#define COL_SEL_LO      0x4A3E
#define COL_SEL_HI      0xFF2E

.macro  LDCOL reg, lo, hi
        mov     \reg, #\lo
        movk    \reg, #\hi, lsl #16
.endm

/*
 * Scale and colour are runtime state, not constants: Cmd +/- resizes the font
 * and Cmd 0-9 recolours it.  These are the defaults and the limits.
 */
#define ED_SCALE        2
#define ED_SCALE_MIN    1
#define ED_SCALE_MAX    8
#define ED_CELL_W       (GLYPH_ADV * ED_SCALE)
#define ED_CELL_H       ((GLYPH_H + 2) * ED_SCALE)
#define ED_BAR_H        (ED_CELL_H + 4 * ED_SCALE)

/* ed_state layout */
#define EDS_CURRENT     0
#define EDS_COUNT       4
#define EDS_SCROLL      8
#define EDS_ROWS        12
#define EDS_COLS        16
#define EDS_SCALE       20
#define EDS_COLOUR      24
#define EDS_SEL_A       28      /* what the user swiped over: first byte  */
#define EDS_SEL_B       32      /* ... and one past the last              */
#define EDS_BUSY        36      /* waiting on the backend: no caret, a mark */
#define EDS_CARET       40      /* the blink phase, driven by the front end */
#define EDS_SZ          48

#endif
