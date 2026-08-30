import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;

/**
 * An operation compiled to machine code the device runs itself.
 *
 * {@link Scripts} removed the model from the loop; this removes the server
 * from it. An operation the server is sure of is handed over once, as aarch64,
 * and from then on the device answers without asking anybody. That is the end
 * of the line the caching started: model, then server, then nobody.
 *
 * <h2>The shape of an operation</h2>
 *
 * Deliberately tiny: guarded clauses over declared variables, each producing a
 * string built from literals and those variables.
 *
 * <pre>
 *   op hello-world (lang)
 *     when lang = "c"      -> "#include &lt;stdio.h&gt;..."
 *     when lang = "python" -> "print(...)"
 *     otherwise            -> decline
 * </pre>
 *
 * That is enough for the operations worth not asking about, and small enough
 * that every instruction it generates is one that has been executed in a test.
 * A richer language would mean emitting encodings nothing exercises, which is
 * the same as emitting encodings nobody has checked.
 *
 * <h2>The contract with the device</h2>
 *
 * <pre>
 *   w0 = op(x0 = char **values,   the declared variables, in order
 *           x1 = char *out,
 *           x2 = char *limit,     one past the last byte that may be written
 *           x3 = void **helpers)
 *
 *   helpers[0] = str_eq(x0, x1) -> w0
 *   helpers[1] = op_append(x0 = cursor, x1 = src, x2 = limit) -> x0 = new cursor
 *
 *   returns bytes written, or -1 to decline
 * </pre>
 *
 * Two things about that are load-bearing.
 *
 * The generated code cannot address memory it was not handed. There are no
 * absolute addresses in it - literals are reached with ADR and the only calls
 * out are indirect through the helper table - so the blob needs no relocation,
 * and it also has no way to name anything it was not given.
 *
 * And it cannot overflow the output, because it does not do the copying. Every
 * byte goes through op_append, which is the device's own bounded code. The
 * safety lives in the half nobody downloaded.
 *
 * <h2>What this does not fix</h2>
 *
 * The device is still executing code the server sent it. The two points above
 * bound what a <em>buggy</em> generator can do; they do not make a hostile
 * server safe, and nothing here should be read as claiming that. What makes it
 * defensible is that this is the user's own backend, reached with their own
 * key - the same one that already holds their cloud credentials. A server that
 * wanted to harm this device has had easier ways all along.
 */
final class NativeOp {

    /** Registers, named for what they hold rather than their numbers. */
    private static final int VALUES = 19, OUT = 20, LIMIT = 21, HELPERS = 22, CUR = 23;
    private static final int SCRATCH = 9;

    record Part(String literal, int variable) {
        static Part of(String s) { return new Part(s, -1); }
        static Part var(int i) { return new Part(null, i); }
        boolean isVar() { return variable >= 0; }
    }

    /** One guarded case. A null guard is the fallthrough. */
    record Clause(Integer guardVar, String guardValue, List<Part> body) {}

    record Op(String name, List<String> variables, List<Clause> clauses) {}

    /** What gets shipped: the code, and enough to know what to feed it. */
    record Blob(String name, List<String> variables, byte[] code, String sha) {}

    static Blob compile(Op op) {
        var a = new Aarch64();
        var literals = new ArrayList<String>();

        // ---- prologue
        a.stpPre(29, 30, -64);
        a.movSp(29, 31);
        a.stpOff(VALUES, OUT, 16);
        a.stpOff(LIMIT, HELPERS, 32);
        a.stpOff(CUR, 24, 48);
        a.movReg(VALUES, 0);
        a.movReg(OUT, 1);
        a.movReg(LIMIT, 2);
        a.movReg(HELPERS, 3);
        a.movReg(CUR, 1);

        // ---- clauses
        for (int i = 0; i < op.clauses().size(); i++) {
            var c = op.clauses().get(i);
            a.label("clause" + i);
            if (c.guardVar() != null) {
                int lit = literals.size();
                literals.add(c.guardValue());
                a.ldr(0, VALUES, 8 * c.guardVar());
                a.adr(1, "lit" + lit);
                a.ldr(SCRATCH, HELPERS, 0);             // str_eq
                a.blr(SCRATCH);
                a.cbzW(0, "clause" + (i + 1));          // no match: the next one
            }
            for (var part : c.body()) {
                a.movReg(0, CUR);
                if (part.isVar()) {
                    a.ldr(1, VALUES, 8 * part.variable());
                } else {
                    int lit = literals.size();
                    literals.add(part.literal());
                    a.adr(1, "lit" + lit);
                }
                a.movReg(2, LIMIT);
                a.ldr(SCRATCH, HELPERS, 8);             // op_append
                a.blr(SCRATCH);
                a.movReg(CUR, 0);
            }
            a.b("done");
        }

        // Nothing matched. Declining is a real outcome, not a failure: the
        // caller asks the server, exactly as if the operation had not been here.
        a.label("clause" + op.clauses().size());
        a.movnW(0, 0);                                  // -1
        a.b("epilogue");

        a.label("done");
        a.subReg(0, CUR, OUT);

        a.label("epilogue");
        a.ldpOff(CUR, 24, 48);
        a.ldpOff(LIMIT, HELPERS, 32);
        a.ldpOff(VALUES, OUT, 16);
        a.ldpPost(29, 30, 64);
        a.ret();

        // ---- the strings the code points at
        for (int i = 0; i < literals.size(); i++) {
            a.label("lit" + i);
            a.bytes(literals.get(i).getBytes(StandardCharsets.UTF_8));
            a.bytes(new byte[]{0});
        }
        a.align(4);

        byte[] code = a.link();
        return new Blob(op.name(), List.copyOf(op.variables()), code, sha(code));
    }

    static String sha(byte[] b) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(b));
        } catch (Exception x) {
            throw new IllegalStateException(x);
        }
    }
}
