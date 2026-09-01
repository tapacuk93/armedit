import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * The server as a cache the model writes to.
 *
 * {@link Cache} remembers exact questions: ask the identical thing and you get
 * the identical answer for nothing. That is a good floor and a narrow one,
 * because almost nobody types the identical thing twice. "c hello world" and
 * "python hello world" are the same activity, and a cache keyed on the bytes
 * cannot see it.
 *
 * What can see it is the model that just answered one of them. So the model is
 * given a way to say so: having answered something it recognises as a common
 * request, it writes a script, and the server answers the next one like it
 * directly. The model is not predicting the future. It is noticing, after the
 * fact, that what it just did was not personal to whoever asked.
 *
 * That is the inversion worth naming. Normally a cache sits in front of the
 * model and guesses what to keep. Here the model sits in front of the cache
 * and says what to keep. It knows which of its answers were general and which
 * were about somebody's particular repository; a hash of the input never can.
 *
 * <h2>Understanding, rather than matching</h2>
 *
 * A script that only matched words would be a macro, and macros fire when they
 * should not. Two things make this a judgement instead:
 *
 * <b>Variables are typed.</b> A pattern says {@code {lang:lang} hello world},
 * not {@code * hello world}, and {@code lang} only binds to something that is
 * actually a language. So "c hello world" matches and "my hello world" does
 * not - which matters, because the second one is somebody talking about their
 * own work and deserves a real answer. The type is what carries the meaning:
 * it is the difference between "this request has a language in it" and "this
 * request has a word in it".
 *
 * <b>Conditions are about the state, not the sentence.</b> The same words mean
 * different things on an empty screen and in the middle of a file, so a script
 * can require what it needs: a mode, an empty screen, a subject, something
 * present in what is visible. A script for a fresh hello world should not fire
 * halfway through somebody's existing program, and saying so is the only way
 * to prevent it.
 *
 * <h2>What keeps this safe</h2>
 *
 * A script may only be written for an exchange that was shareable to begin
 * with - nothing marked private went into it, by the same test the cache uses.
 * A model cannot decide that somebody's private screen was a general case.
 *
 * And a pattern must be specific. A pattern that is mostly free variables
 * would swallow unrelated requests and answer them from a template, which is
 * worse than being slow. Literal words count towards specificity, and so do
 * closed-set variables like a language, because those constrain. Open-ended
 * ones do not, because they do not.
 */
final class Scripts {

    /**
     * How a model teaches the server:
     *
     *     #SCRIPT hello-world :: {lang:lang} hello world
     *     #WHEN screen = empty
     *     ...the program, with {lang} deciding which...
     *     #END
     */
    private static final Pattern TAUGHT = Pattern.compile(
            "(?ms)^#SCRIPT\\s+([A-Za-z0-9_-]{1,40})\\s*::\\s*(.+?)\\s*$(.*?)^#END\\s*$");

    private static final Pattern CONDITION = Pattern.compile(
            "(?m)^#WHEN\\s+(\\w+)\\s*([=~])\\s*(.+?)\\s*$");

    private static final Pattern VAR = Pattern.compile("\\{(\\w+)(?::(\\w+))?\\}");

    /** A body that is code rather than a template. */
    private static final Pattern JAVA = Pattern.compile("(?ms)^#JAVA\\s*$(.*)");

    /**
     * A body written once and meant for two destinations.
     *
     * #JAVA runs only here. #JS is the one that matters: the same source is
     * evaluated on this machine to answer immediately, and compiled to aarch64
     * for a device that would rather not ask. Both come from one parser and one
     * syntax tree, because two implementations of one language is how they
     * start disagreeing.
     */
    private static final Pattern JS = Pattern.compile("(?ms)^#JS\\s*$(.*)");

    static final int MAX_BODY = 8000;
    static final int MAX_SCRIPTS = 2000;

    /** A pattern needs this much that is not free-form before it may be kept. */
    private static final int MIN_SPECIFICITY = 2;

    /**
     * The closed sets. A variable whose type is one of these constrains the
     * match, which is what lets it count towards specificity - the pattern is
     * saying something about the request, not just leaving a hole in it.
     */
    private static final Set<String> LANGS = Set.of(
            "c", "c++", "cpp", "java", "python", "rust", "go", "javascript", "js",
            "typescript", "ts", "ruby", "php", "swift", "kotlin", "scala", "haskell",
            "lua", "perl", "bash", "shell", "sh", "zsh", "sql", "html", "css",
            "assembly", "asm", "aarch64", "arm64", "x86", "fortran", "cobol",
            "clojure", "elixir", "erlang", "dart", "zig", "nim", "ocaml", "r",
            "julia", "matlab", "objective-c", "csharp", "c#", "vb", "groovy");

    /**
     * The colours the editor actually has.
     *
     * A closed set for the same reason languages are one: it is what lets
     * "colours {c:colour}" be a specific enough pattern to keep, while
     * "colours {c:word}" is not. The editor's palette is ten slots, so a
     * pattern that binds one of their names is saying something real about the
     * request rather than leaving a hole in it.
     */
    private static final Set<String> COLOURS = Set.of(
            "green", "white", "amber", "orange", "blue", "red",
            "violet", "purple", "cyan", "yellow", "grey", "gray", "pink", "magenta");

    /** What a variable will accept. */
    enum Kind {
        WORDS,      // one or more words - free, and does not make a pattern specific
        WORD,       // exactly one word
        NUM,        // an integer
        LANG,       // a language we know by name
        COLOUR      // a colour the editor has
    }

    record Var(String name, Kind kind) {}

    /** A pattern is a sequence of these: either a fixed word or a variable. */
    record Token(String literal, Var var) {
        boolean isVar() { return var != null; }
    }

    /** Something that must be true of the state, not of the sentence. */
    record Condition(String field, char op, String value) {

        /** {@code =} is the whole value, {@code ~} is "contains". */
        boolean holds(Ctx ctx) {
            String actual = switch (field) {
                case "mode" -> ctx.mode();
                case "subject" -> ctx.subject();
                case "context" -> ctx.context();
                case "selection" -> ctx.selection();
                case "screen" -> ctx.context().isBlank() ? "empty" : "nonempty";
                default -> null;
            };
            if (actual == null) return false;               // a field we do not know
            String a = normalise(actual), v = normalise(value);
            return op == '=' ? a.equals(v) : a.contains(v);
        }
    }

    /** Everything a script is allowed to know about the moment it fires in. */
    record Ctx(String mode, String instruction, String context,
               String selection, String subject) {}

    /**
     * What every operation is handed, on top of the variables it named itself.
     *
     * An operation used to see only the words it matched: "colours {name}" got
     * {@code name} and nothing else. That is enough to answer a question about
     * the sentence, and not enough to answer a question about the document -
     * and the interesting operations are all about the document. "sort these",
     * "renumber the list", "make the second one a loop" cannot be written at
     * all without the text they are talking about.
     *
     * So the screen goes to every operation, scripted and compiled alike, at a
     * fixed position after its own variables. Fixed because the compiled form
     * addresses arguments by index: once a blob is built, the order it was
     * built with is the order it will read forever, and appending is the only
     * change that leaves old blobs meaning what they meant.
     *
     * The cost is that every operation pays for the whole screen whether it
     * looks at it or not. That is a copy of a few kilobytes against an
     * operation that can only otherwise be told what it already matched.
     */
    static final List<String> AMBIENT = List.of("screen", "subject", "selection");

    /**
     * {@code code} is set when the model wrote a method body and it compiled;
     * {@code body} is the template it falls back to. A script may be either,
     * and on a native image - where there is no compiler - it is always the
     * template.
     */
    record Script(String name, String pattern, List<Token> tokens,
                  List<Condition> conditions, String body, ScriptBody code,
                  String js, NativeOp.Blob blob,
                  String author, long taughtAt, AtomicLong hits) {

        /** The variables this operation takes, in the order it wants them. */
        List<String> parameters() {
            var names = new ArrayList<String>();
            for (var t : tokens) if (t.isVar()) names.add(t.var().name());
            return names;
        }

        /** Those, then the ambient ones - the order the operation was built with. */
        List<String> arguments() {
            var names = parameters();
            names.addAll(AMBIENT);
            return names;
        }

        /** The same order, filled in: what to actually hand it. */
        List<String> argumentsFor(Map<String, String> bound, Ctx ctx) {
            var out = new ArrayList<String>();
            for (var p : parameters()) out.add(bound.getOrDefault(p, ""));
            out.add(ctx.context() == null ? "" : ctx.context());
            out.add(ctx.subject() == null ? "" : ctx.subject());
            out.add(ctx.selection() == null ? "" : ctx.selection());
            return out;
        }
    }

    record Hit(Script script, String text, Map<String, String> bound) {}

    private final Map<String, Script> scripts = new ConcurrentHashMap<>();
    private final AtomicLong served = new AtomicLong();
    private final AtomicLong refused = new AtomicLong();
    private final AtomicLong evicted = new AtomicLong();
    private final ScriptVm vm = new ScriptVm();

    /**
     * A handful of sentences this operation would match, and the arguments
     * they bind to - so it can be run before anybody is asked to judge it.
     *
     * These are not tests: nothing here knows what the right answer is. They
     * exist so that a reviewer sees what the operation does rather than what
     * its source suggests it does, and so that an operation which declines
     * everything is visibly one that declines everything.
     *
     * The closed kinds - colours, languages - are walked through, because
     * those are exactly the cases where an operation covers three of them and
     * silently drops the fourth. Open kinds get one placeholder; there is
     * nothing to enumerate.
     */
    record Probe(String sentence, List<String> values) {}

    static List<Probe> probes(Script s) {
        var out = new ArrayList<Probe>();
        var vars = new ArrayList<Var>();
        for (var t : s.tokens()) if (t.isVar()) vars.add(t.var());

        // Which variable, if any, is worth walking through exhaustively.
        int walk = -1;
        List<String> values = List.of();
        for (int i = 0; i < vars.size(); i++) {
            var k = vars.get(i).kind();
            if (k == Kind.COLOUR) { walk = i; values = List.copyOf(COLOURS); break; }
            if (k == Kind.LANG && walk < 0) { walk = i; values = List.copyOf(LANGS); }
        }
        if (walk < 0) { values = List.of(""); walk = 0; }

        /*
         * Every member of a closed kind, in a fixed order.
         *
         * This used to stop at eight, taken from an unordered set - so which
         * eight varied between runs, and the cases that did not make the cut
         * simply were not there. A reviewer reading the result saw "blue"
         * absent from a list of colours and concluded, correctly given what it
         * was shown, that the operation did not handle blue. It handled blue
         * fine; the evidence was truncated and did not say so.
         *
         * Closed kinds are small - a dozen colours, a few languages - so there
         * is no reason to sample them at all. Sorting is what makes two runs
         * comparable; a review that changes because a hash order changed is
         * not a review.
         */
        var walked = new ArrayList<>(values);
        java.util.Collections.sort(walked);
        values = List.copyOf(walked);

        for (int n = 0; n < Math.max(1, values.size()); n++) {
            var bound = new ArrayList<String>();
            for (int i = 0; i < vars.size(); i++) {
                bound.add(i == walk && !values.isEmpty() && !values.get(0).isEmpty()
                        ? values.get(n) : placeholder(vars.get(i)));
            }
            var sentence = new StringBuilder();
            int at = 0;
            for (var t : s.tokens()) {
                if (sentence.length() > 0) sentence.append(' ');
                sentence.append(t.isVar() ? bound.get(at++) : t.literal());
            }
            // The ambient arguments come last, as they do everywhere else.
            var all = new ArrayList<>(bound);
            all.add("the document, such as it is");
            all.add("");
            all.add("");
            out.add(new Probe(sentence.toString(), List.copyOf(all)));
        }

        // And one it should not match on the closed kinds, because declining is
        // half of what these operations are for.
        if (!values.isEmpty() && !values.get(0).isEmpty()) {
            var bound = new ArrayList<String>();
            for (int i = 0; i < vars.size(); i++) {
                bound.add(i == walk ? "chartreuse" : placeholder(vars.get(i)));
            }
            var sentence = new StringBuilder();
            int at = 0;
            for (var t : s.tokens()) {
                if (sentence.length() > 0) sentence.append(' ');
                sentence.append(t.isVar() ? bound.get(at++) : t.literal());
            }
            var all = new ArrayList<>(bound);
            all.add("the document, such as it is");
            all.add("");
            all.add("");
            out.add(new Probe(sentence.toString(), List.copyOf(all)));
        }
        return out;
    }

    private static String placeholder(Var v) {
        return switch (v.kind()) {
            case NUM -> "2";
            case LANG -> "c";
            case COLOUR -> "blue";
            case WORD -> "thing";
            case WORDS -> "the thing they meant";
        };
    }

    /** Case and spacing are noise; everything else is the request. */
    static String normalise(String s) {
        return s == null ? "" : s.strip().toLowerCase(Locale.ROOT).replaceAll("\\s+", " ");
    }

    // ------------------------------------------------------------- patterns

    /** Turn "{lang:lang} hello world" into tokens. */
    static List<Token> compile(String pattern) {
        var out = new ArrayList<Token>();
        for (var word : normalise(pattern).split(" ")) {
            if (word.isBlank()) continue;
            Matcher m = VAR.matcher(word);
            if (m.matches()) {
                Kind kind = switch (m.group(2) == null ? "words" : m.group(2)) {
                    case "word" -> Kind.WORD;
                    case "num", "number" -> Kind.NUM;
                    case "lang", "language" -> Kind.LANG;
                    case "colour", "color" -> Kind.COLOUR;
                    default -> Kind.WORDS;
                };
                out.add(new Token(null, new Var(m.group(1), kind)));
            } else {
                out.add(new Token(word, null));
            }
        }
        return out;
    }

    /** Would this value be accepted by a variable of that kind? */
    static boolean accepts(Kind kind, String value) {
        return switch (kind) {
            case WORDS -> !value.isBlank();
            case WORD -> !value.isBlank() && !value.contains(" ");
            case NUM -> value.matches("-?\\d+");
            case LANG -> LANGS.contains(value);
            case COLOUR -> COLOURS.contains(value);
        };
    }

    /**
     * Is this pattern saying enough to be trusted with a request?
     *
     * Literal words count, and so do variables that can only bind to a closed
     * set: "{lang:lang} hello world" is specific because a language is a real
     * constraint, while "{x} hello" is not, because {x} rules nothing out.
     */
    static boolean specific(List<Token> tokens) {
        int score = 0;
        for (var t : tokens) {
            if (t.isVar()) {
                var k = t.var().kind();
                if (k == Kind.LANG || k == Kind.NUM || k == Kind.COLOUR) score++;
            } else if (t.literal().length() >= 2) {
                score++;
            }
        }
        return score >= MIN_SPECIFICITY;
    }

    /**
     * Match a request against a pattern, returning what the variables bound
     * to, or null if it does not match.
     *
     * A WORDS variable is non-greedy and backtracks, so "{x} hello world"
     * against "write me a c hello world" binds the whole prefix rather than
     * failing at the first word that is not "hello".
     */
    static Map<String, String> bind(List<Token> tokens, String request) {
        String[] r = normalise(request).split(" ");
        var bound = new LinkedHashMap<String, String>();
        return walk(tokens, 0, r, 0, bound) ? bound : null;
    }

    private static boolean walk(List<Token> p, int pi, String[] r, int ri,
                                Map<String, String> bound) {
        if (pi == p.size()) return ri == r.length;
        var t = p.get(pi);
        if (!t.isVar()) {
            if (ri == r.length || !t.literal().equals(r[ri])) return false;
            return walk(p, pi + 1, r, ri + 1, bound);
        }
        int most = t.var().kind() == Kind.WORDS ? r.length - ri : 1;
        for (int take = 1; take <= most && ri + take <= r.length; take++) {
            String value = String.join(" ", Arrays.copyOfRange(r, ri, ri + take));
            if (!accepts(t.var().kind(), value)) continue;
            String had = bound.put(t.var().name(), value);
            if (walk(p, pi + 1, r, ri + take, bound)) return true;
            if (had == null) bound.remove(t.var().name()); else bound.put(t.var().name(), had);
        }
        return false;
    }

    /**
     * Put the bindings back into the template, along with what the script is
     * allowed to know about where it fired.
     */
    static String fill(String body, Map<String, String> bound, Ctx ctx) {
        String out = body;
        for (var e : bound.entrySet()) out = out.replace("{" + e.getKey() + "}", e.getValue());
        out = out.replace("{subject}", ctx.subject() == null ? "" : ctx.subject());
        out = out.replace("{selection}", ctx.selection() == null ? "" : ctx.selection());
        out = out.replace("{screen}", ctx.context() == null ? "" : ctx.context());
        return out;
    }

    // -------------------------------------------------------------- serving

    /**
     * Is there a script for this moment?  The first match whose conditions
     * hold wins; scripts do not compete on score, because a tie-break between
     * two canned answers is a decision nobody made.
     */
    Hit lookup(Ctx ctx) {
        if (ctx.instruction() == null || ctx.instruction().isBlank()) return null;
        for (var s : scripts.values()) {
            var bound = bind(s.tokens(), ctx.instruction());
            if (bound == null) continue;
            boolean all = true;
            for (var c : s.conditions()) if (!c.holds(ctx)) { all = false; break; }
            if (!all) continue;

            String text;
            if (s.js() != null) {
                // Answer with the operation itself, here, now. The device may
                // instead have been handed the compiled form and never asked.
                try {
                    text = Js.run(s.js(), s.arguments(), s.argumentsFor(bound, ctx));
                } catch (RuntimeException x) {
                    System.out.printf("armedit: script \"%s\" failed: %s%n", s.name(), x);
                    continue;
                }
                if (text == null || text.isBlank()) continue;
            } else if (s.code() != null) {
                // Compiled: it may still look at what it was handed and decide
                // this one is not for it, in which case we carry on as though
                // it had never matched.
                var vars = new LinkedHashMap<String, String>();
                var names = s.arguments();
                var values = s.argumentsFor(bound, ctx);
                for (int i = 0; i < names.size(); i++) vars.put(names.get(i), values.get(i));
                text = vm.run(s.code(), vars);
                if (text == null || text.isBlank()) {
                    // A script that keeps hanging is taken out of service. It
                    // declined this request either way; the eviction is about
                    // the next one.
                    if (vm.spent(s.code())) {
                        scripts.remove(normalise(s.pattern()), s);
                        evicted.incrementAndGet();
                        System.out.printf("armedit: script \"%s\" dropped - it stopped coming back%n",
                                s.name());
                    }
                    continue;
                }
            } else {
                text = fill(s.body(), bound, ctx);
            }
            s.hits().incrementAndGet();
            served.incrementAndGet();
            return new Hit(s, text, bound);
        }
        return null;
    }

    // ------------------------------------------------------------- learning

    /**
     * Take in whatever the model taught, and say what was accepted.
     * A refusal is recorded rather than thrown: a model writing a bad pattern
     * should not cost the user the answer it wrote alongside it.
     */
    List<Script> learn(String reply, String author, boolean shareable) {
        var added = new ArrayList<Script>();
        if (reply == null) return added;
        Matcher m = TAUGHT.matcher(reply);
        while (m.find()) {
            String name = m.group(1);
            String pattern = m.group(2).strip();
            String rest = m.group(3);

            var conditions = new ArrayList<Condition>();
            Matcher c = CONDITION.matcher(rest);
            while (c.find()) conditions.add(new Condition(c.group(1), c.group(2).charAt(0), c.group(3)));
            String remainder = CONDITION.matcher(rest).replaceAll("").strip();

            // A #JAVA block means the model wrote code rather than a template;
            // #JS means it wrote something that can also leave this machine.
            String body = remainder, source = null, script = null;
            Matcher jsm = JS.matcher(remainder);
            if (jsm.find()) {
                script = jsm.group(1).strip();
                body = jsm.replaceAll("").strip();
            } else {
                Matcher j = JAVA.matcher(remainder);
                if (j.find()) {
                    source = j.group(1).strip();
                    body = j.replaceAll("").strip();
                }
            }

            var tokens = compile(pattern);
            if (!shareable || tokens.isEmpty() || !specific(tokens)
                    || scripts.size() >= MAX_SCRIPTS
                    || (source == null && script == null
                        && (body.isEmpty() || body.length() > MAX_BODY))) {
                refused.incrementAndGet();
                continue;
            }

            // A script that does not compile is refused here, on the server,
            // where the error can be read - rather than shipped to a device
            // that has no way to report it.
            // Both forms are built against the argument list they will be
            // called with - own variables first, then the ambient ones - so a
            // blob compiled today still reads argument 2 as argument 2 next
            // year.
            var params = new ArrayList<String>();
            for (var t : tokens) if (t.isVar()) params.add(t.var().name());
            for (var a : AMBIENT) {
                if (!params.contains(a)) continue;
                System.out.printf("armedit: script \"%s\" refused: \"%s\" is given to every "
                        + "operation already%n", name, a);
                refused.incrementAndGet();
                params = null;
                break;
            }
            if (params == null) continue;
            params.addAll(AMBIENT);

            NativeOp.Blob blob = null;
            if (script != null) {
                try {
                    blob = Js.compile(name, script, params);
                } catch (RuntimeException x) {
                    System.out.printf("armedit: script \"%s\" rejected: %s%n", name, x.getMessage());
                    refused.incrementAndGet();
                    continue;
                }
            }

            ScriptBody code = null;
            if (source != null) {
                var why = new StringBuilder();
                code = vm.compile(name, params, source, why);
                if (code == null) {
                    // The code was refused, but a template may have come with
                    // it, and half a script is better than none.
                    System.out.printf("armedit: script \"%s\" not compiled: %s%n", name, why);
                    if (body.isEmpty()) { refused.incrementAndGet(); continue; }
                }
            }

            var s = new Script(name, pattern, tokens, List.copyOf(conditions), body, code,
                    script, blob, author, System.currentTimeMillis(), new AtomicLong());
            // The first teacher of a pattern keeps it. Letting a later model
            // overwrite one that is already answering people turns a fast path
            // into a moving target.
            if (scripts.putIfAbsent(normalise(pattern), s) == null) added.add(s);
        }
        return added;
    }

    /** The user should never see the teaching, only the answer. */
    static String without(String reply) {
        return reply == null ? "" : TAUGHT.matcher(reply).replaceAll("").strip();
    }

    /**
     * What the model is told it can do. Deliberately framed as a judgement it
     * makes after answering, not a form to fill in every time: a model that
     * scripts everything produces a server that answers everything from a
     * template, which is the failure this exists to prevent.
     */
    String briefing() {
        var b = new StringBuilder();
        b.append("""

                THE SERVER REMEMBERS WHAT YOU TELL IT TO

                You are slow and you cost money. When you have just answered
                something that was not about this person in particular - a
                common request whose answer would serve anyone who asked it -
                teach the server to answer the next one without waking you:

                    #SCRIPT <short-name> :: <pattern>
                    #WHEN <field> = <value>        (optional, repeatable)
                    <the answer, as a template>
                    #END

                Patterns are made of fixed words and typed variables. The type
                is what makes the script understand rather than merely match:

                    {name}          one or more words
                    {name:word}     exactly one word
                    {name:num}      an integer
                    {name:lang}     a programming language, by name
                    {name:colour}   a colour the editor has

                So {lang:lang} hello world matches "c hello world" and "python
                hello world", and does NOT match "my hello world" - which is
                right, because that one is about their own work and deserves a
                real answer from you.

                Conditions are about the state, not the sentence, because the
                same words mean different things in different places:

                    mode = aify | submit | swipe
                    screen = empty | nonempty
                    subject ~ <words>      what this screen is about
                    context ~ <words>      what is visible on it

                In the body, {name} puts a binding back. So are {screen} -
                everything the editor is showing - and {subject} and
                {selection}. For example:

                    #SCRIPT hello-world :: {lang:lang} hello world
                    #WHEN screen = empty
                    ...the program, with {lang} deciding which...
                    #END

                A template can only substitute. When the answer depends on
                what was bound - which is usually - write code instead, as a
                Java method body under #JAVA. Every variable arrives as a
                local String, and you return the answer:

                Three more locals arrive whether you named them or not:
                "screen" is the entire document the person is looking at,
                "subject" what it is about, "selection" what they had picked.
                An operation that rewrites what is on screen - sorting it,
                renumbering it, changing one line of it - reads "screen",
                returns the new text, and asks for #WHOLE. That is the whole
                mechanism; there is nothing else it needs.


                    #SCRIPT hello-world :: {lang:lang} hello world
                    #JAVA
                    switch (lang) {
                      case "c": return "#include <stdio.h>\\nint main(void){...}";
                      case "python": return "print('hello world')";
                      default: return null;
                    }
                    #END

                Returning null means "not me": the server then asks a model as
                if the script had not matched. Use it. A script that covers the
                cases it knows and declines the rest is worth far more than one
                that guesses, because a wrong fast answer is the one failure
                here that nobody can see happening.

                The body is compiled and then runs as ordinary compiled code,
                so it can loop, branch and build strings. It cannot open files,
                make connections, start processes or use reflection, and a
                body that mentions those is refused outright.

                Write this after your answer; it is stripped out before the
                user sees anything.

                Only do this when the request was general rather than personal,
                your answer was right, and the pattern is tight enough that
                nothing unrelated will match. Patterns that are mostly
                free variables are refused. When in doubt, do not script it: a
                slow correct answer beats a fast wrong one, and the user has no
                way to tell the server it learned something badly.
                """);
        if (!scripts.isEmpty()) {
            b.append("\nalready scripted, so do not teach these again:\n");
            int shown = 0;
            for (var s : scripts.values()) {
                if (shown++ == 40) {
                    b.append("  ... and ").append(scripts.size() - 40).append(" more\n");
                    break;
                }
                b.append("  ").append(s.pattern());
                for (var c : s.conditions()) {
                    b.append("  [").append(c.field()).append(' ').append(c.op())
                     .append(' ').append(c.value()).append(']');
                }
                b.append('\n');
            }
        }
        return b.toString();
    }

    /** Every operation that exists as machine code, for a device to fetch. */
    List<Script> nativeOps() {
        var out = new ArrayList<Script>();
        for (var s : scripts.values()) if (s.blob() != null) out.add(s);
        return out;
    }

    Script byName(String name) {
        for (var s : scripts.values()) if (s.name().equals(name)) return s;
        return null;
    }

    /** For the refresher: what the model should be shown about its own work. */
    String inventory() {
        var b = new StringBuilder();
        for (var s : scripts.values()) {
            b.append("  ").append(s.name()).append(" :: ").append(s.pattern())
             .append("  (").append(s.hits().get()).append(" uses")
             .append(s.blob() != null ? ", compiled" : "")
             .append(")\n");
        }
        return b.toString();
    }

    /** Take one back out, by name, so the refresher can replace it. */
    boolean forget(String name) {
        for (var e : scripts.entrySet()) {
            if (e.getValue().name().equals(name)) {
                scripts.remove(e.getKey());
                return true;
            }
        }
        return false;
    }

    int size() { return scripts.size(); }

    long served() { return served.get(); }

    String asJson() {
        var b = new StringBuilder("{\"count\":").append(scripts.size())
                .append(",\"served\":").append(served.get())
                .append(",\"refused\":").append(refused.get())
                .append(",\"evicted\":").append(evicted.get())
                .append(",\"scripts\":[");
        boolean first = true;
        for (var s : scripts.values()) {
            if (!first) b.append(',');
            first = false;
            b.append(Json.obj("name", s.name(), "pattern", s.pattern(),
                    "author", s.author(), "hits", s.hits().get(),
                    "conditions", s.conditions().size(),
                    "compiled", s.code() != null,
                    "native", s.blob() != null ? s.blob().code().length : 0,
                    "taught", s.taughtAt(), "bytes", s.body().length()));
        }
        b.append("],\"vm\":").append(vm.asJson());
        return b.append("}").toString();
    }
}
