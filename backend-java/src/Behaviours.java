import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Behaviour that users write, in words, and everyone else inherits.
 *
 * Long-press a thing, get a screen about it, type "move it when I swipe it",
 * press the replace key. That sentence becomes a rule attached to that kind of
 * thing - not to the one instance you pressed - and the next person to receive
 * an image gets it already behaving that way, because enough people said so.
 *
 * The constraint that shapes all of this: the client is assembly with no
 * interpreter in it. It cannot run a rule someone typed, and it should not be
 * able to. So a rule is not code - it is a choice among things the client
 * already knows how to do, and the model's only job is to work out which
 * choice the sentence meant. A rule that maps onto nothing in the vocabulary
 * is refused rather than approximated, because a behaviour that half-works is
 * worse than one that never appeared.
 *
 * On the weighting: this is a popularity count, not a judgement. A behaviour
 * gains weight when someone authors it and loses it when someone replaces it
 * with a different answer for the same gesture. That makes defaults follow
 * what people actually keep, which is the useful signal available - it does
 * not make them right, and one loud account can still move them.
 */
final class Behaviours {

    /** What a rule can be about. */
    enum Target {
        IMAGE("image"), KEY("key"), WORD("word"), BUTTON("button"), SCREEN("screen"), ANY("any");

        final String id;

        Target(String id) { this.id = id; }

        static Target of(String s) {
            if (s == null) return ANY;
            String k = s.toLowerCase(Locale.ROOT).trim();
            for (var v : values()) if (v.id.equals(k)) return v;
            return ANY;
        }
    }

    /** What the user does to it. */
    enum Trigger {
        TAP("tap"), DOUBLE("double"), LONG("long"), SWIPE("swipe"), DRAG("drag");

        final String id;

        Trigger(String id) { this.id = id; }

        static Trigger of(String s) {
            if (s == null) return null;
            String k = s.toLowerCase(Locale.ROOT).trim();
            for (var v : values()) if (v.id.equals(k)) return v;
            return null;
        }
    }

    /**
     * What happens then. This list is the contract with the client: every verb
     * here is something the assembly can already do, and nothing else can ever
     * be asked for.
     */
    enum Verb {
        MOVE("move", "the thing follows the finger"),
        RESIZE("resize", "the thing grows or shrinks with the gesture"),
        HIGHLIGHT("highlight", "the thing lights up while it is touched"),
        OPEN("open", "a screen about the thing opens"),
        ASK("ask", "the thing is handed to the model"),
        REWRITE("rewrite", "the model replaces the thing"),
        NOTHING("nothing", "the gesture is ignored for this kind of thing");

        final String id;
        final String about;

        Verb(String id, String about) {
            this.id = id;
            this.about = about;
        }

        static Verb of(String s) {
            if (s == null) return null;
            String k = s.toLowerCase(Locale.ROOT).trim();
            for (var v : values()) if (v.id.equals(k)) return v;
            return null;
        }
    }

    /** One authored rule, and how many people are behind it. */
    static final class Rule {
        final Target target;
        final Trigger trigger;
        final Verb verb;
        volatile int weight;
        volatile String saidAs;     // the sentence someone actually typed

        Rule(Target target, Trigger trigger, Verb verb, String saidAs) {
            this.target = target;
            this.trigger = trigger;
            this.verb = verb;
            this.saidAs = saidAs;
            this.weight = 1;
        }

        String key() { return target.id + ":" + trigger.id; }
    }

    /** Every rule anyone has authored, by target:trigger:verb. */
    private final Map<String, Rule> rules = new ConcurrentHashMap<>();
    private final Path root;

    Behaviours(Path root) {
        this.root = root;
        seed();
    }

    /**
     * The behaviours that ship before anyone has said anything. They are
     * ordinary rules with a weight of one, so the first person to disagree
     * outvotes them - there is nothing privileged about being built in.
     */
    private void seed() {
        author(null, Target.WORD, Trigger.LONG, Verb.OPEN, "long press a word to open a screen about it");
        author(null, Target.WORD, Trigger.SWIPE, Verb.ASK, "swipe words to ask about them");
        author(null, Target.KEY, Trigger.TAP, Verb.NOTHING, "tapping a key types it");
        author(null, Target.IMAGE, Trigger.TAP, Verb.NOTHING, "tapping an image does nothing yet");
    }

    /**
     * What the model is told when it has to turn a sentence into a rule.
     * The vocabulary is spelled out because the answer has to be one of these
     * - anything else cannot be executed by a client that has no interpreter.
     */
    String translationPrompt(String sentence, String subject) {
        var b = new StringBuilder();
        b.append("""
                A user long-pressed something in the editor and wrote a sentence saying how it \
                should behave. Turn that sentence into exactly one rule, chosen from the \
                vocabulary below, and reply with one line and nothing else:

                    BEHAVIOUR <target> <trigger> <verb>

                targets: """);
        for (var t : Target.values()) b.append(t.id).append(' ');
        b.append("\ntriggers: ");
        for (var t : Trigger.values()) b.append(t.id).append(' ');
        b.append("\nverbs:\n");
        for (var v : Verb.values()) b.append("  ").append(v.id).append(" - ").append(v.about).append('\n');
        b.append("""

                The client is assembly with no interpreter: it can only do the verbs above, so if \
                the sentence asks for something outside them, reply exactly:

                    BEHAVIOUR none

                rather than picking the nearest thing. A rule that half-works is worse than one \
                that never appeared.

                """);
        if (subject != null && !subject.isBlank()) {
            b.append("They pressed on: ").append(subject).append('\n');
        }
        b.append("What they wrote: ").append(sentence).append('\n');
        return b.toString();
    }

    /** Read the model's one line back. Returns null when it declined. */
    Rule parse(String reply, String saidAs) {
        if (reply == null) return null;
        for (var line : reply.split("\n")) {
            var t = line.trim();
            if (!t.toUpperCase(Locale.ROOT).startsWith("BEHAVIOUR")) continue;
            var parts = t.split("\\s+");
            if (parts.length < 4) return null;
            var target = Target.of(parts[1]);
            var trigger = Trigger.of(parts[2]);
            var verb = Verb.of(parts[3]);
            if (trigger == null || verb == null) return null;
            return new Rule(target, trigger, verb, saidAs);
        }
        return null;
    }

    /**
     * Record an authored rule.
     *
     * Authoring it adds weight; it also takes weight from whatever else was
     * answering the same gesture, because choosing one answer is implicitly
     * declining the others.
     */
    Rule author(String accountId, Target target, Trigger trigger, Verb verb, String saidAs) {
        String key = target.id + ":" + trigger.id + ":" + verb.id;
        var rule = rules.computeIfAbsent(key, k -> new Rule(target, trigger, verb, saidAs));
        rule.weight++;
        rule.saidAs = saidAs;

        for (var other : rules.values()) {
            if (other != rule && other.target == target && other.trigger == trigger && other.weight > 0) {
                other.weight--;
            }
        }
        if (accountId != null) {
            record(accountId, "%s %s -> %s   (\"%s\")".formatted(
                    target.id, trigger.id, verb.id, saidAs));
        }
        return rule;
    }

    /** The winning rule for each gesture: what a client is handed as default. */
    List<Rule> defaults() {
        var best = new java.util.LinkedHashMap<String, Rule>();
        for (var r : rules.values()) {
            if (r.verb == Verb.NOTHING) continue;
            var cur = best.get(r.key());
            if (cur == null || r.weight > cur.weight) best.put(r.key(), r);
        }
        return new ArrayList<>(best.values());
    }

    /**
     * The defaults in the form the client reads: one rule per line, three
     * words and a number. A parser for this is twenty instructions, which is
     * what a client with no JSON library needs it to be.
     */
    String asText() {
        var b = new StringBuilder();
        for (var r : defaults()) {
            b.append(r.target.id).append(' ')
             .append(r.trigger.id).append(' ')
             .append(r.verb.id).append(' ')
             .append(r.weight).append('\n');
        }
        return b.toString();
    }

    String asJson() {
        var b = new StringBuilder("[");
        boolean first = true;
        for (var r : defaults()) {
            if (!first) b.append(',');
            first = false;
            b.append(Json.obj("target", r.target.id, "trigger", r.trigger.id,
                    "verb", r.verb.id, "weight", r.weight, "said_as", r.saidAs));
        }
        return b.append(']').toString();
    }

    private void record(String accountId, String line) {
        try {
            var dir = root.resolve(accountId);
            Files.createDirectories(dir);
            Files.writeString(dir.resolve("behaviours.log"),
                    "%s  %s%n".formatted(Instant.now(), line),
                    StandardCharsets.UTF_8, StandardOpenOption.CREATE, StandardOpenOption.APPEND);
        } catch (Exception x) {
            System.out.printf("armedit: could not record behaviour: %s%n", x.getMessage());
        }
    }
}
