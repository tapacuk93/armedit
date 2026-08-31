import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * An aarch64 encoder, so the server can hand a device code instead of text.
 *
 * The reasoning: a scripted answer still costs a round trip, and a round trip
 * is the thing that made the fast path worth building. For an operation the
 * server has seen enough times to be sure of, the honest end state is that the
 * device stops asking at all - it is handed the operation once, as machine
 * code, and runs it.
 *
 * <h2>What this can encode</h2>
 *
 * Only the instructions {@link NativeOp} needs. This is not an assembler and
 * should not grow into one: every encoding here is one somebody wrote down
 * from the manual and then verified by executing it, and that verification is
 * what makes it trustworthy. A general assembler would have encodings nothing
 * exercises, which is the same as having encodings nobody has checked.
 *
 * <h2>Position independence</h2>
 *
 * The code is loaded at whatever address the device happens to map it, so
 * nothing here may contain an absolute address. Literals are reached with ADR,
 * which is PC-relative, and the only calls out are indirect through a table
 * the device passes in. That is why a blob needs no relocation and no loader:
 * copy it into executable memory and jump to it.
 */
final class Aarch64 {

    private final ByteArrayOutputStream out = new ByteArrayOutputStream();
    private final Map<String, Integer> labels = new HashMap<>();
    private final List<Fixup> fixups = new ArrayList<>();

    /** A branch or ADR whose target was not known when it was emitted. */
    private record Fixup(int at, String label, Kind kind) {}

    private enum Kind { B26, COND19, CBZ19, ADR21 }

    /* ---------------------------------------------------------- emitting */

    private void word(int w) {
        out.write(w & 0xFF);
        out.write((w >>> 8) & 0xFF);
        out.write((w >>> 16) & 0xFF);
        out.write((w >>> 24) & 0xFF);
    }

    int here() { return out.size(); }

    void label(String name) {
        if (labels.putIfAbsent(name, out.size()) != null) {
            throw new IllegalStateException("label twice: " + name);
        }
    }

    /** Raw bytes - string literals and anything else the code points at. */
    void bytes(byte[] b) {
        out.writeBytes(b);
    }

    void align(int n) {
        while (out.size() % n != 0) out.write(0);
    }

    /* ------------------------------------------------------ instructions */

    /** stp Xt1, Xt2, [sp, #imm]!  - imm is a byte offset, a multiple of 8. */
    void stpPre(int t1, int t2, int imm) {
        word(0xA9800000 | ((imm / 8) & 0x7F) << 15 | t2 << 10 | 31 << 5 | t1);
    }

    /** ldp Xt1, Xt2, [sp], #imm */
    void ldpPost(int t1, int t2, int imm) {
        word(0xA8C00000 | ((imm / 8) & 0x7F) << 15 | t2 << 10 | 31 << 5 | t1);
    }

    /** stp Xt1, Xt2, [sp, #imm] - no writeback. */
    void stpOff(int t1, int t2, int imm) {
        word(0xA9000000 | ((imm / 8) & 0x7F) << 15 | t2 << 10 | 31 << 5 | t1);
    }

    /** ldp Xt1, Xt2, [sp, #imm] */
    void ldpOff(int t1, int t2, int imm) {
        word(0xA9400000 | ((imm / 8) & 0x7F) << 15 | t2 << 10 | 31 << 5 | t1);
    }

    /** mov Xd, Xm - an alias for orr Xd, xzr, Xm. */
    void movReg(int d, int m) {
        word(0xAA0003E0 | m << 16 | d);
    }

    /** mov Wd, Wm */
    void movRegW(int d, int m) {
        word(0x2A0003E0 | m << 16 | d);
    }

    /** mov Xd, sp / mov sp, Xn - add with a zero immediate, since sp is not r31 here. */
    void movSp(int d, int n) {
        word(0x91000000 | n << 5 | d);
    }

    /** add Xd, Xn, #imm12 */
    void addImm(int d, int n, int imm) {
        word(0x91000000 | (imm & 0xFFF) << 10 | n << 5 | d);
    }

    /** Condition codes, for b.cond. */
    static final int EQ = 0, NE = 1, GE = 10, LT = 11, GT = 12, LE = 13;

    /** add Xd, Xn, Xm */
    void addReg(int d, int n, int m) {
        word(0x8B000000 | m << 16 | n << 5 | d);
    }

    /** orr Xd, Xn, Xm */
    void orrReg(int d, int n, int m) {
        word(0xAA000000 | m << 16 | n << 5 | d);
    }

    /** sub Xd, Xn, Xm */
    void subReg(int d, int n, int m) {
        word(0xCB000000 | m << 16 | n << 5 | d);
    }

    /** mul Xd, Xn, Xm - madd with the zero register as the addend. */
    void mul(int d, int n, int m) {
        word(0x9B007C00 | m << 16 | n << 5 | d);
    }

    /** sub Xd, Xn, #imm12 */
    void subImm(int d, int n, int imm) {
        word(0xD1000000 | (imm & 0xFFF) << 10 | n << 5 | d);
    }

    /** cmp Xn, Xm - subs xzr, Xn, Xm */
    void cmpReg(int n, int m) {
        word(0xEB00001F | m << 16 | n << 5);
    }

    /** cmp Xn, #imm12 */
    void cmpImm(int n, int imm) {
        word(0xF100001F | (imm & 0xFFF) << 10 | n << 5);
    }

    /** cset Xd, cond - csinc Xd, xzr, xzr, invert(cond) */
    void cset(int d, int cond) {
        word(0x9A9F07E0 | (cond ^ 1) << 12 | d);
    }

    /** str Xt, [Xn, #imm] - imm a byte offset, a multiple of 8. */
    void str(int t, int n, int imm) {
        word(0xF9000000 | ((imm / 8) & 0xFFF) << 10 | n << 5 | t);
    }

    /** str Xt, [sp, #-16]! - the expression stack. */
    void push(int t) {
        word(0xF8000C00 | ((-16 & 0x1FF) << 12) | 31 << 5 | t);
    }

    /** ldr Xt, [sp], #16 */
    void pop(int t) {
        word(0xF8400400 | ((16 & 0x1FF) << 12) | 31 << 5 | t);
    }

    /** b.cond label */
    void bcond(int cond, String label) {
        fixups.add(new Fixup(out.size(), label, Kind.COND19));
        word(0x54000000 | cond);
    }

    /** lsl Xd, Xn, #shift - ubfm, which is how the manual spells it. */
    void lslImm(int d, int n, int shift) {
        int immr = (64 - shift) & 63, imms = 63 - shift;
        word(0xD3400000 | immr << 16 | imms << 10 | n << 5 | d);
    }

    /** asr Xd, Xn, #shift */
    void asrImm(int d, int n, int shift) {
        word(0x9340FC00 | shift << 16 | n << 5 | d);
    }

    /** and Xd, Xn, #1 - the tag bit, the only mask this needs. */
    void andOne(int d, int n) {
        word(0x92400000 | n << 5 | d);
    }

    /**
     * and Xd, Xn, #~1 - clear the tag bit.
     *
     * The mask is 63 ones rotated left by one, which the immediate encoding
     * spells as N=1, immr=63, imms=62. Logical immediates are the one part of
     * this instruction set nobody guesses correctly, so: verified by
     * disassembly like everything else here.
     */
    void bicOne(int d, int n) {
        word(0x92400000 | 63 << 16 | 62 << 10 | n << 5 | d);
    }

    /** eor Xd, Xn, #1 - flip a tagged boolean. */
    void eorOne(int d, int n) {
        word(0xD2400000 | n << 5 | d);
    }

    /** orr Xd, Xn, #1 */
    void orrOne(int d, int n) {
        word(0xB2400000 | n << 5 | d);
    }

    /** ldr Xt, [Xn, #imm] - imm a byte offset, a multiple of 8. */
    void ldr(int t, int n, int imm) {
        word(0xF9400000 | ((imm / 8) & 0xFFF) << 10 | n << 5 | t);
    }

    /** movz Wd, #imm16 */
    void movzW(int d, int imm) {
        word(0x52800000 | (imm & 0xFFFF) << 5 | d);
    }

    /** movn Wd, #imm16 - movn #0 is how you say -1. */
    void movnW(int d, int imm) {
        word(0x12800000 | (imm & 0xFFFF) << 5 | d);
    }

    /** blr Xn */
    void blr(int n) {
        word(0xD63F0000 | n << 5);
    }

    void ret() {
        word(0xD65F03C0);
    }

    /** adr Xd, label - PC-relative, which is what makes the blob relocatable. */
    void adr(int d, String label) {
        fixups.add(new Fixup(out.size(), label, Kind.ADR21));
        word(0x10000000 | d);
    }

    /** b label */
    void b(String label) {
        fixups.add(new Fixup(out.size(), label, Kind.B26));
        word(0x14000000);
    }

    /** cbz Wt, label */
    void cbzW(int t, String label) {
        fixups.add(new Fixup(out.size(), label, Kind.CBZ19));
        word(0x34000000 | t);
    }

    /** cbnz Wt, label */
    void cbnzW(int t, String label) {
        fixups.add(new Fixup(out.size(), label, Kind.CBZ19));
        word(0x35000000 | t);
    }

    /** cbz Xt, label */
    void cbz(int t, String label) {
        fixups.add(new Fixup(out.size(), label, Kind.CBZ19));
        word(0xB4000000 | t);
    }

    /* ---------------------------------------------------------- finishing */

    /**
     * Resolve every branch and ADR.  A label that was never defined is a bug in
     * the generator, not in the input, so it throws rather than emitting
     * something that would run off into whatever follows.
     */
    byte[] link() {
        byte[] code = out.toByteArray();
        for (var f : fixups) {
            Integer target = labels.get(f.label());
            if (target == null) throw new IllegalStateException("no label " + f.label());
            int word = read(code, f.at());
            int delta = target - f.at();
            switch (f.kind()) {
                case B26 -> {
                    int imm = delta / 4;
                    if (imm < -(1 << 25) || imm >= (1 << 25)) throw new IllegalStateException("branch too far");
                    word |= imm & 0x03FFFFFF;
                }
                case COND19, CBZ19 -> {
                    int imm = delta / 4;
                    if (imm < -(1 << 18) || imm >= (1 << 18)) throw new IllegalStateException("branch too far");
                    word |= (imm & 0x7FFFF) << 5;
                }
                case ADR21 -> {
                    if (delta < -(1 << 20) || delta >= (1 << 20)) throw new IllegalStateException("adr too far");
                    word |= (delta & 3) << 29 | ((delta >> 2) & 0x7FFFF) << 5;
                }
            }
            write(code, f.at(), word);
        }
        return code;
    }

    private static int read(byte[] b, int at) {
        return (b[at] & 0xFF) | (b[at + 1] & 0xFF) << 8
                | (b[at + 2] & 0xFF) << 16 | (b[at + 3] & 0xFF) << 24;
    }

    private static void write(byte[] b, int at, int w) {
        b[at] = (byte) w;
        b[at + 1] = (byte) (w >>> 8);
        b[at + 2] = (byte) (w >>> 16);
        b[at + 3] = (byte) (w >>> 24);
    }
}
