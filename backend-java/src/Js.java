import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * A JavaScript subset, compiled to aarch64 ahead of time.
 *
 * The bare-metal build has no operating system to forbid anything, so it is
 * the one target that can run a real browser - and a real browser runs script.
 * It cannot JIT: there is no reason to write a tiering compiler for a kernel
 * that boots into a text editor. So the page's script is compiled once, on the
 * backend, and the machine code arrives with the page.
 *
 * <h2>The subset</h2>
 *
 * Numbers, strings, locals, {@code + - *}, comparison, {@code if/else},
 * {@code while}, {@code return}, and the arguments the host passes in. That is
 * not JavaScript and this class does not pretend it is. It is the part of
 * JavaScript that page scripts spend most of their time in, and every
 * construct here is one that has been compiled and then executed in a test.
 *
 * Absent, and each absence is a real limitation rather than an oversight:
 * objects, arrays, closures, prototypes, exceptions, {@code var} hoisting,
 * coercion rules beyond string concatenation, and floating point. Numbers are
 * 63-bit integers. A script that needs any of that is rejected at compile
 * time on the server, where a person can see the error, rather than
 * mis-executed on a device where nobody can.
 *
 * <h2>Values</h2>
 *
 * One machine word, tagged in the low bit: an integer is {@code n << 1}, a
 * string is a pointer with the bottom bit set. That representation is chosen
 * for one property - tagged integers add and subtract without untagging,
 * because {@code (a<<1) + (b<<1) == (a+b)<<1} - which keeps the common case
 * to a single instruction.
 *
 * Strings are never built by generated code. Concatenation, truthiness and
 * rendering are host calls, so every allocation and every byte of copying
 * happens in the device's own code. Generated code computes with values it
 * was handed and never computes an address.
 */
final class Js {

    /* ------------------------------------------------------------- lexing */

    private enum T { NUM, STR, IDENT, PUNCT, END }

    private record Tok(T kind, String text, long num) {}

    private static final List<String> WORDS = List.of(
            "let", "var", "const", "if", "else", "while", "return", "function");

    private static List<Tok> lex(String src) {
        var out = new ArrayList<Tok>();
        int i = 0, n = src.length();
        while (i < n) {
            char c = src.charAt(i);
            if (Character.isWhitespace(c)) { i++; continue; }
            if (c == '/' && i + 1 < n && src.charAt(i + 1) == '/') {
                while (i < n && src.charAt(i) != '\n') i++;
                continue;
            }
            if (Character.isDigit(c)) {
                int j = i;
                while (j < n && Character.isDigit(src.charAt(j))) j++;
                out.add(new Tok(T.NUM, src.substring(i, j), Long.parseLong(src.substring(i, j))));
                i = j;
                continue;
            }
            if (Character.isJavaIdentifierStart(c)) {
                int j = i;
                while (j < n && Character.isJavaIdentifierPart(src.charAt(j))) j++;
                out.add(new Tok(T.IDENT, src.substring(i, j), 0));
                i = j;
                continue;
            }
            if (c == '"' || c == '\'') {
                var b = new StringBuilder();
                int j = i + 1;
                while (j < n && src.charAt(j) != c) {
                    char d = src.charAt(j);
                    if (d == '\\' && j + 1 < n) {
                        j++;
                        d = switch (src.charAt(j)) {
                            case 'n' -> '\n';
                            case 't' -> '\t';
                            case 'r' -> '\r';
                            default -> src.charAt(j);
                        };
                    }
                    b.append(d);
                    j++;
                }
                if (j >= n) throw new Bad("unterminated string");
                out.add(new Tok(T.STR, b.toString(), 0));
                i = j + 1;
                continue;
            }
            // Two-character operators first, so "<=" does not lex as "<".
            if (i + 1 < n) {
                String two = src.substring(i, i + 2);
                if (List.of("<=", ">=", "==", "!=", "&&", "||", "++").contains(two)) {
                    if (two.equals("==") && i + 2 < n && src.charAt(i + 2) == '=') {
                        out.add(new Tok(T.PUNCT, "==", 0));   // === means the same here
                        i += 3;
                        continue;
                    }
                    out.add(new Tok(T.PUNCT, two, 0));
                    i += 2;
                    continue;
                }
            }
            out.add(new Tok(T.PUNCT, String.valueOf(c), 0));
            i++;
        }
        out.add(new Tok(T.END, "", 0));
        return out;
    }

    /** A script this compiler will not take. Thrown on the server, seen by a person. */
    static final class Bad extends RuntimeException {
        Bad(String why) { super(why); }
    }

    /* ------------------------------------------------------------ parsing */

    private sealed interface Node permits Num, Str, Var, Bin, Assign, Decl, If, While, Ret, Block {}
    private record Num(long v) implements Node {}
    private record Str(String v) implements Node {}
    private record Var(String name) implements Node {}
    private record Bin(String op, Node a, Node b) implements Node {}
    private record Assign(String name, Node value) implements Node {}
    private record Decl(String name, Node value) implements Node {}
    private record If(Node cond, Node then, Node otherwise) implements Node {}
    private record While(Node cond, Node body) implements Node {}
    private record Ret(Node value) implements Node {}
    private record Block(List<Node> body) implements Node {}

    private final List<Tok> toks;
    private int at;
    private final Map<String, Integer> locals = new LinkedHashMap<>();

    private Js(List<Tok> toks) { this.toks = toks; }

    private Tok peek() { return toks.get(at); }

    private boolean isPunct(String s) {
        return peek().kind() == T.PUNCT && peek().text().equals(s);
    }

    private boolean isWord(String s) {
        return peek().kind() == T.IDENT && peek().text().equals(s);
    }

    private void expect(String s) {
        if (!isPunct(s)) throw new Bad("expected " + s + " but found \"" + peek().text() + "\"");
        at++;
    }

    private int slot(String name) {
        return locals.computeIfAbsent(name, k -> locals.size());
    }

    private Node block() {
        var body = new ArrayList<Node>();
        expect("{");
        while (!isPunct("}")) {
            if (peek().kind() == T.END) throw new Bad("unclosed {");
            body.add(statement());
        }
        expect("}");
        return new Block(body);
    }

    private Node statement() {
        if (isWord("let") || isWord("var") || isWord("const")) {
            at++;
            String name = peek().text();
            at++;
            slot(name);
            Node v = new Num(0);
            if (isPunct("=")) { at++; v = expr(); }
            if (isPunct(";")) at++;
            return new Decl(name, v);
        }
        if (isWord("if")) {
            at++;
            expect("(");
            Node c = expr();
            expect(")");
            Node t = isPunct("{") ? block() : statement();
            Node e = null;
            if (isWord("else")) { at++; e = isPunct("{") ? block() : statement(); }
            return new If(c, t, e);
        }
        if (isWord("while")) {
            at++;
            expect("(");
            Node c = expr();
            expect(")");
            return new While(c, isPunct("{") ? block() : statement());
        }
        if (isWord("return")) {
            at++;
            Node v = isPunct(";") ? new Num(0) : expr();
            if (isPunct(";")) at++;
            return new Ret(v);
        }
        if (isPunct("{")) return block();
        Node e = expr();
        if (isPunct(";")) at++;
        return e;
    }

    /** Assignment, then comparison, then + -, then *. No other precedence exists here. */
    private Node expr() {
        if (peek().kind() == T.IDENT && toks.get(at + 1).kind() == T.PUNCT
                && toks.get(at + 1).text().equals("=")) {
            String name = peek().text();
            if (!locals.containsKey(name)) throw new Bad("assignment to undeclared " + name);
            at += 2;
            return new Assign(name, expr());
        }
        return comparison();
    }

    private Node comparison() {
        Node a = sum();
        while (peek().kind() == T.PUNCT
                && List.of("<", ">", "<=", ">=", "==", "!=").contains(peek().text())) {
            String op = peek().text();
            at++;
            a = new Bin(op, a, sum());
        }
        return a;
    }

    private Node sum() {
        Node a = product();
        while (isPunct("+") || isPunct("-")) {
            String op = peek().text();
            at++;
            a = new Bin(op, a, product());
        }
        return a;
    }

    private Node product() {
        Node a = atom();
        while (isPunct("*")) {
            at++;
            a = new Bin("*", a, atom());
        }
        return a;
    }

    private Node atom() {
        var t = peek();
        if (t.kind() == T.NUM) { at++; return new Num(t.num()); }
        if (t.kind() == T.STR) { at++; return new Str(t.text()); }
        if (t.kind() == T.IDENT) {
            if (WORDS.contains(t.text())) throw new Bad("unexpected " + t.text());
            at++;
            if (isPunct("(")) throw new Bad("calls are not supported yet: " + t.text());
            if (!locals.containsKey(t.text())) throw new Bad("unknown name " + t.text());
            return new Var(t.text());
        }
        if (isPunct("(")) { at++; Node e = expr(); expect(")"); return e; }
        throw new Bad("unexpected \"" + t.text() + "\"");
    }

    /* ----------------------------------------------------------- lowering */

    private static final int ARGS = 19, OUT = 20, LIMIT = 21, HELPERS = 22, FP = 29;
    private static final int H_CONCAT = 16, H_TRUTHY = 24, H_RENDER = 32;

    /*
     * Locals are addressed from the frame pointer, never from sp.
     *
     * That is not a style choice. Evaluating a binary operator pushes the left
     * operand while the right is computed, which moves sp - so a local read
     * from sp during the right-hand side reads the pushed value instead. The
     * symptom was "a" + b coming out as "a" + "a", which is the sort of bug
     * that looks like a string problem and is not.
     */
    private static final int LOCAL0 = 48;

    private Aarch64 a;
    private int frame;
    private int labelSeq;

    private String fresh(String p) { return p + (labelSeq++); }

    /** An expression leaves its tagged value in x0. */
    private void gen(Node n) {
        switch (n) {
            case Num v -> {
                long tagged = v.v() << 1;
                if (tagged < 0 || tagged > 0xFFFF) throw new Bad("number out of range: " + v.v());
                a.movzW(0, (int) tagged);
            }
            case Str s -> {
                String lab = fresh("str");
                strings.put(lab, s.v());
                a.adr(0, lab);
                a.orrOne(0, 0);                     // tag it as a string
            }
            case Var v -> a.ldr(0, FP, LOCAL0 + 8 * locals.get(v.name()));
            case Decl d -> {
                gen(d.value());
                a.str(0, FP, LOCAL0 + 8 * locals.get(d.name()));
            }
            case Assign s -> {
                gen(s.value());
                a.str(0, FP, LOCAL0 + 8 * locals.get(s.name()));
            }
            case Bin b -> binary(b);
            case Block b -> b.body().forEach(this::gen);
            case If f -> {
                String els = fresh("else"), end = fresh("endif");
                gen(f.cond());
                truthy();
                a.cmpImm(0, 0);
                a.bcond(Aarch64.EQ, f.otherwise() == null ? end : els);
                gen(f.then());
                if (f.otherwise() != null) {
                    a.b(end);
                    a.label(els);
                    gen(f.otherwise());
                }
                a.label(end);
            }
            case While w -> {
                String top = fresh("while"), end = fresh("endwhile");
                a.label(top);
                gen(w.cond());
                truthy();
                a.cmpImm(0, 0);
                a.bcond(Aarch64.EQ, end);
                gen(w.body());
                a.b(top);
                a.label(end);
            }
            case Ret r -> {
                gen(r.value());
                a.b("return");
            }
        }
    }

    /** x0 = tagged; leaves 0 or 1 in x0.  The host decides, so "" is falsy. */
    private void truthy() {
        a.ldr(9, HELPERS, H_TRUTHY);
        a.blr(9);
    }

    private void binary(Bin b) {
        gen(b.a());
        a.push(0);
        gen(b.b());
        a.movReg(1, 0);
        a.pop(0);

        switch (b.op()) {
            case "+" -> {
                // Both integers is the common case and needs no untagging, because
                // (a<<1) + (b<<1) is already (a+b)<<1. Anything with a string in it
                // is the host's problem, since only the host may allocate.
                String ints = fresh("addint"), done = fresh("adddone");
                a.movReg(10, 0);
                a.orrReg(10, 10, 1);
                a.andOne(10, 10);
                a.cmpImm(10, 0);
                a.bcond(Aarch64.EQ, ints);
                a.ldr(9, HELPERS, H_CONCAT);
                a.blr(9);
                a.b(done);
                a.label(ints);
                a.addReg(0, 0, 1);
                a.label(done);
            }
            case "-" -> a.subReg(0, 0, 1);
            case "*" -> {
                a.asrImm(0, 0, 1);
                a.asrImm(1, 1, 1);
                a.mul(0, 0, 1);
                a.lslImm(0, 0, 1);
            }
            case "==", "!=" -> {
                // Comparing the words would compare addresses, so two strings
                // spelled the same but built separately would differ. Only the
                // host can answer this, and only it knows how.
                String nums = fresh("cmpnum"), done = fresh("cmpdone");
                a.movReg(10, 0);
                a.orrReg(10, 10, 1);
                a.andOne(10, 10);
                a.cmpImm(10, 0);
                a.bcond(Aarch64.EQ, nums);
                a.bicOne(0, 0);
                a.bicOne(1, 1);
                a.ldr(9, HELPERS, 0);               // str_eq
                a.blr(9);
                if (b.op().equals("!=")) a.eorOne(0, 0);
                a.lslImm(0, 0, 1);
                a.b(done);
                a.label(nums);
                a.cmpReg(0, 1);
                a.cset(0, b.op().equals("==") ? Aarch64.EQ : Aarch64.NE);
                a.lslImm(0, 0, 1);
                a.label(done);
            }
            case "<", ">", "<=", ">=" -> {
                int cond = switch (b.op()) {
                    case "<" -> Aarch64.LT;
                    case ">" -> Aarch64.GT;
                    case "<=" -> Aarch64.LE;
                    default -> Aarch64.GE;
                };
                a.cmpReg(0, 1);
                a.cset(0, cond);
                a.lslImm(0, 0, 1);                  // a tagged 0 or 1
            }
            default -> throw new Bad("operator " + b.op());
        }
    }

    private final Map<String, String> strings = new LinkedHashMap<>();

    /* --------------------------------------------------------- evaluating */

    /**
     * The same script, run here instead.
     *
     * A widget's script has two destinations and must mean the same thing at
     * both: the backend answers with it immediately, and a bare-metal device is
     * handed it as machine code. Two implementations of one language is how
     * they drift apart, so this walks the very AST the compiler lowers - same
     * parser, same tree, same rejections. What differs is only what happens at
     * the leaves.
     *
     * Values here are Long or String, which is the Java shape of the same tag.
     */
    static String run(String src, List<String> argNames, List<String> argValues) {
        var js = new Js(lex(src));
        for (var a : argNames) js.slot(a);
        var body = new ArrayList<Node>();
        while (js.peek().kind() != T.END) body.add(js.statement());

        var env = new java.util.HashMap<String, Object>();
        for (int i = 0; i < argNames.size(); i++) {
            env.put(argNames.get(i), i < argValues.size() ? argValues.get(i) : "");
        }
        try {
            for (var n : body) js.eval(n, env);
        } catch (Return r) {
            return render(r.value);
        }
        return "";
    }

    /** How a return leaves an arbitrarily nested statement. */
    private static final class Return extends RuntimeException {
        final Object value;
        Return(Object v) { super(null, null, false, false); this.value = v; }
    }

    private static String render(Object v) {
        return v instanceof Long n ? String.valueOf(n) : String.valueOf(v);
    }

    /** Empty string and zero are false, matching js_truthy on the device. */
    private static boolean truthy(Object v) {
        return v instanceof Long n ? n != 0 : !((String) v).isEmpty();
    }

    private Object eval(Node n, Map<String, Object> env) {
        return switch (n) {
            case Num v -> v.v();
            case Str s -> s.v();
            case Var v -> env.getOrDefault(v.name(), 0L);
            case Decl d -> { env.put(d.name(), eval(d.value(), env)); yield 0L; }
            case Assign s -> { env.put(s.name(), eval(s.value(), env)); yield 0L; }
            case Block b -> { for (var st : b.body()) eval(st, env); yield 0L; }
            case Ret r -> throw new Return(eval(r.value(), env));
            case If f -> {
                if (truthy(eval(f.cond(), env))) eval(f.then(), env);
                else if (f.otherwise() != null) eval(f.otherwise(), env);
                yield 0L;
            }
            case While w -> {
                int guard = 0;
                while (truthy(eval(w.cond(), env))) {
                    // The device has no such limit and will simply spin; here a
                    // runaway script would hold a request thread, so it stops.
                    if (++guard > 1_000_000) throw new Bad("script did not terminate");
                    eval(w.body(), env);
                }
                yield 0L;
            }
            case Bin b -> {
                Object x = eval(b.a(), env), y = eval(b.b(), env);
                yield switch (b.op()) {
                    case "+" -> (x instanceof Long p && y instanceof Long q)
                            ? (Object) (p + q) : render(x) + render(y);
                    case "-" -> num(x) - num(y);
                    case "*" -> num(x) * num(y);
                    case "<" -> num(x) < num(y) ? 1L : 0L;
                    case ">" -> num(x) > num(y) ? 1L : 0L;
                    case "<=" -> num(x) <= num(y) ? 1L : 0L;
                    case ">=" -> num(x) >= num(y) ? 1L : 0L;
                    case "==" -> equalTo(x, y) ? 1L : 0L;
                    case "!=" -> equalTo(x, y) ? 0L : 1L;
                    default -> throw new Bad("operator " + b.op());
                };
            }
        };
    }

    private static long num(Object v) {
        return v instanceof Long n ? n : 0L;
    }

    /** Strings compare by content, exactly as str_eq does on the device. */
    private static boolean equalTo(Object x, Object y) {
        if (x instanceof Long p && y instanceof Long q) return p.longValue() == q.longValue();
        if (x instanceof String p && y instanceof String q) return p.equals(q);
        return false;
    }

    /**
     * Compile one script.
     *
     * @param src  the function body; arguments arrive as the declared names
     * @param args the names the host will supply, in order
     */
    static NativeOp.Blob compile(String name, String src, List<String> args) {
        var js = new Js(lex(src));
        for (var arg : args) js.slot(arg);

        var body = new ArrayList<Node>();
        while (js.peek().kind() != T.END) body.add(js.statement());
        var program = new Block(body);

        js.a = new Aarch64();
        var a = js.a;
        // Saved registers, then the locals, in one frame. STP's immediate is a
        // signed 7-bit multiple of 8, so the whole thing has to fit in 512
        // bytes - which is 58 locals, and a script wanting more is refused
        // here rather than generating a frame that silently does not work.
        js.frame = ((LOCAL0 + js.locals.size() * 8 + 15) / 16) * 16;
        if (js.frame > 504) throw new Bad("too many variables: " + js.locals.size());

        a.stpPre(29, 30, -js.frame);
        a.movSp(29, 31);
        a.stpOff(ARGS, OUT, 16);
        a.stpOff(LIMIT, HELPERS, 32);
        a.movReg(ARGS, 0);
        a.movReg(OUT, 1);
        a.movReg(LIMIT, 2);
        a.movReg(HELPERS, 3);

        for (int i = 0; i < args.size(); i++) {     // arguments become locals
            a.ldr(0, ARGS, 8 * i);
            a.str(0, FP, LOCAL0 + 8 * i);
        }

        js.gen(program);
        a.movzW(0, 0);                              // falling off the end returns 0

        a.label("return");
        a.movSp(31, FP);                            // whatever the expression
                                                    // stack did, undo it
        a.movReg(1, OUT);
        a.movReg(2, LIMIT);
        a.ldr(9, HELPERS, H_RENDER);
        a.blr(9);                                   // the host turns it into text
        a.ldpOff(LIMIT, HELPERS, 32);
        a.ldpOff(ARGS, OUT, 16);
        a.ldpPost(29, 30, js.frame);
        a.ret();

        for (var e : js.strings.entrySet()) {
            a.align(2);                             // adr must land on an even byte
            a.label(e.getKey());
            a.bytes(e.getValue().getBytes(StandardCharsets.UTF_8));
            a.bytes(new byte[]{0});
        }
        a.align(4);

        byte[] code = a.link();
        return new NativeOp.Blob(name, List.copyOf(args), code, NativeOp.sha(code));
    }
}
