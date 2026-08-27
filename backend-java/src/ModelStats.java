import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

/**
 * What each model actually does, per kind of work.
 *
 * Being honest about what this is: there is no ground truth here for "better".
 * Nobody grades the answers. What the server can observe is behaviour, and
 * behaviour is what this records:
 *
 *   - how often a model, given this kind of work, hands it to someone else.
 *     A handoff is the model's own judgement that it was the wrong choice,
 *     and it is the strongest signal available precisely because it costs the
 *     model nothing to be right about.
 *   - how often the user comes straight back and asks again about the same
 *     screen. Not proof of a bad answer, but a re-ask within a minute is
 *     rarely a compliment.
 *   - how long it took, and how much it cost.
 *   - how often the call failed outright.
 *
 * The score below combines those into an ordering, and the ordering is used
 * to pick a starting model and to tell each model what the others are for.
 * Anything claiming more than that would be inventing a measurement.
 */
final class ModelStats {

    /** The kinds of work the router distinguishes. */
    enum Category {
        SHORT_EDIT("short-edit", "finishing a line, tidying a list"),
        CODE("code", "reading and writing code"),
        INFRA("infra", "clouds, machines, deployments"),
        PROSE("prose", "writing and rewriting text"),
        LOOKUP("lookup", "answering a question about what is on screen");

        final String id;
        final String about;

        Category(String id, String about) {
            this.id = id;
            this.about = about;
        }

        static Category of(String s) {
            if (s == null) return LOOKUP;
            String k = s.toLowerCase(Locale.ROOT).trim();
            for (var v : values()) if (v.id.equals(k)) return v;
            return LOOKUP;
        }
    }

    /** Read off the screen, the same way the router reads it. */
    static Category classify(String mode, String context) {
        String text = context == null ? "" : context;
        String lower = text.toLowerCase(Locale.ROOT);
        if (lower.contains("#aws") || lower.contains("#run") || lower.contains("deploy")
                || lower.contains("instance") || lower.contains("cluster")) return Category.INFRA;
        if (text.contains("{") || text.contains("();") || lower.contains("def ")
                || lower.contains("class ") || lower.contains("func ")
                || lower.contains("git ") || text.contains("#include")) return Category.CODE;
        if ("swipe".equals(mode)) return Category.LOOKUP;
        if (text.length() < 400) return Category.SHORT_EDIT;
        return Category.PROSE;
    }

    /** One model's record in one category. */
    static final class Record {
        final AtomicLong calls = new AtomicLong();
        final AtomicLong failures = new AtomicLong();
        final AtomicLong handedAway = new AtomicLong();
        final AtomicLong handedTo = new AtomicLong();
        final AtomicLong reasks = new AtomicLong();
        final AtomicLong totalMillis = new AtomicLong();
        final AtomicLong totalChars = new AtomicLong();

        long calls() { return calls.get(); }

        long averageMillis() {
            long n = calls.get();
            return n == 0 ? 0 : totalMillis.get() / n;
        }

        /**
         * Higher is better, and it is a ranking rather than a grade: a model
         * with no history scores neutral so it gets tried rather than being
         * frozen out by never having been used.
         */
        double score() {
            long n = calls.get();
            if (n == 0) return 0.5;
            double bad = (handedAway.get() + failures.get() * 2 + reasks.get()) / (double) n;
            double good = handedTo.get() / (double) Math.max(1, n);
            double s = 1.0 - bad + good * 0.25;
            return Math.max(0.0, Math.min(1.5, s));
        }
    }

    private final Map<String, Record> records = new ConcurrentHashMap<>();

    private static String key(String model, Category c) {
        return model + "/" + c.id;
    }

    Record of(String model, Category c) {
        return records.computeIfAbsent(key(model, c), k -> new Record());
    }

    void called(String model, Category c, long millis, int chars) {
        var r = of(model, c);
        r.calls.incrementAndGet();
        r.totalMillis.addAndGet(millis);
        r.totalChars.addAndGet(chars);
    }

    void failed(String model, Category c) { of(model, c).failures.incrementAndGet(); }

    void handedAway(String from, Category c) { of(from, c).handedAway.incrementAndGet(); }

    void handedTo(String to, Category c) { of(to, c).handedTo.incrementAndGet(); }

    void reasked(String model, Category c) { of(model, c).reasks.incrementAndGet(); }

    /** The best-scoring model for this work, among those on offer. */
    String best(Category c, List<String> candidates) {
        String bestName = null;
        double bestScore = -1;
        for (var m : candidates) {
            double s = of(m, c).score();
            if (s > bestScore) {
                bestScore = s;
                bestName = m;
            }
        }
        return bestName;
    }

    /**
     * What each model is told about the others.
     *
     * A model deciding whether to hand over should know who it would be
     * handing to and what the record says about them, otherwise a handoff is
     * a guess dressed up as a routing decision.
     */
    String briefing(List<String> models, Category current) {
        var b = new StringBuilder("What the record says, for this kind of work (");
        b.append(current.id).append(" - ").append(current.about).append("):\n");
        boolean any = false;
        for (var m : models) {
            var r = of(m, current);
            if (r.calls() == 0) {
                b.append("  - ").append(m).append(": not tried on this yet\n");
                continue;
            }
            any = true;
            b.append("  - ").append(m).append(": ")
             .append(r.calls()).append(" calls, ")
             .append(r.averageMillis()).append("ms average");
            if (r.handedAway.get() > 0) b.append(", handed it on ").append(r.handedAway.get()).append(" times");
            if (r.reasks.get() > 0) b.append(", asked again after ").append(r.reasks.get());
            if (r.failures.get() > 0) b.append(", ").append(r.failures.get()).append(" failures");
            b.append('\n');
        }
        if (!any) {
            b.append("Nothing has been measured here yet, so choose on the description rather than the record.\n");
        }
        return b.append('\n').toString();
    }

    /** Everything, for the stats endpoint. */
    String asJson() {
        var out = new StringBuilder("{");
        boolean first = true;
        for (var e : records.entrySet()) {
            if (!first) out.append(',');
            first = false;
            var r = e.getValue();
            out.append('"').append(Json.escape(e.getKey())).append("\":")
               .append(Json.obj(
                       "calls", r.calls(),
                       "failures", r.failures.get(),
                       "handed_away", r.handedAway.get(),
                       "handed_to", r.handedTo.get(),
                       "reasks", r.reasks.get(),
                       "avg_ms", r.averageMillis(),
                       "score", Math.round(r.score() * 100) / 100.0));
        }
        return out.append('}').toString();
    }

    List<String> categories() {
        var out = new ArrayList<String>();
        for (var c : Category.values()) out.add(c.id);
        return out;
    }
}
