import java.util.List;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Which model should answer this, and what happens when it decides it should
 * not be the one answering.
 *
 * Two separate jobs, deliberately in one place:
 *
 *   1. The server picks a starting model from the state of the screen. Most
 *      presses of Cmd+P are small - a list to tidy, a line to finish - and
 *      sending those to the largest model available is just slow and
 *      expensive. Long, code-shaped or infrastructure-shaped work goes to a
 *      capable one.
 *
 *   2. A model that finds itself in the wrong seat can hand over, by writing
 *      a line and stopping:
 *
 *          #HANDOFF opus  this needs to reason about the whole repository
 *
 *      The backend then re-asks the named model, carrying the transcript so
 *      far and the reason. A handoff is a routing decision made with more
 *      information than the router had, which is the whole point of allowing
 *      it - but it costs a second call, so there is a limit on how many times
 *      it may happen in one exchange.
 *
 * aicoin fronts several providers, so "which model" spans providers too: the
 * cheapest adequate one may not be the one the account started on.
 */
final class Router {

    /** How many times one exchange may change hands before we stop. */
    static final int MAX_HANDOFFS = 2;

    private static final Pattern HANDOFF = Pattern.compile(
            "(?m)^#HANDOFF\\s+([A-Za-z0-9_.-]+)\\s*(.*)$");

    /**
     * A model the router may choose, with what it costs and what it is for.
     * Prices are per million tokens and exist only to order the options; the
     * bill itself is aicoin's business.
     */
    record Tier(String name, String provider, String model, double costPerMTok, String suitedTo) {}

    /**
     * Ordered cheapest first. A name is what a handoff line may say, so keep
     * them short and obvious.
     */
    static final List<Tier> TIERS = List.of(
            new Tier("haiku", "anthropic", "claude-haiku-4-5", 1.00,
                    "short edits, list tidying, finishing a line"),
            new Tier("sonnet", "anthropic", "claude-sonnet-5", 3.00,
                    "ordinary code and prose work"),
            new Tier("opus", "anthropic", "claude-opus-5", 5.00,
                    "long reasoning, whole-repository work, infrastructure changes"));

    private Router() {}

    static Tier byName(String name) {
        if (name == null) return null;
        String n = name.toLowerCase(Locale.ROOT).trim();
        for (var t : TIERS) {
            if (t.name.equals(n) || t.model.equalsIgnoreCase(n)) return t;
        }
        return null;
    }

    static Tier cheapest() { return TIERS.get(0); }

    static Tier strongest() { return TIERS.get(TIERS.size() - 1); }

    /**
     * Pick a starting tier from what is actually on the screen.
     *
     * The signals are crude on purpose - screen length, whether it looks like
     * code, whether it mentions infrastructure - because a router that tries to
     * be clever about intent is a second model in the path, and this one has to
     * be free.
     */
    static Tier choose(String mode, String context, String baseline) {
        String text = context == null ? "" : context;
        String lower = text.toLowerCase(Locale.ROOT);

        boolean infra = lower.contains("#aws") || lower.contains("deploy")
                || lower.contains("instance") || lower.contains("terraform")
                || lower.contains("cluster") || lower.contains("s3://");
        boolean codey = text.contains("{") || text.contains("();")
                || lower.contains("def ") || lower.contains("class ")
                || lower.contains("func ") || lower.contains("git ")
                || text.contains("#include");
        boolean long_ = text.length() > 4000;
        boolean bigEdit = baseline != null && Math.abs(text.length() - baseline.length()) > 1500;

        if (infra || long_ || bigEdit) return strongest();
        if (codey || "aify".equals(mode) && text.length() > 800) return TIERS.get(1);
        return cheapest();
    }

    /** A model asking to be replaced: the tier it wants, and why. */
    record Handoff(Tier to, String reason) {}

    /**
     * Read a handoff request out of a reply, if there is one. An unknown
     * target is treated as no request at all rather than as an error - a model
     * inventing a model name should not stop the answer getting through.
     */
    static Handoff requested(String reply) {
        if (reply == null) return null;
        Matcher m = HANDOFF.matcher(reply);
        if (!m.find()) return null;
        var tier = byName(m.group(1));
        if (tier == null) return null;
        String why = m.group(2) == null ? "" : m.group(2).trim();
        return new Handoff(tier, why);
    }

    /** Strip the handoff line before anything is shown to the user. */
    static String withoutHandoff(String reply) {
        return reply == null ? "" : HANDOFF.matcher(reply).replaceAll("").strip();
    }

    /** What the model is told about its own ability to hand over. */
    static String briefing(Tier current) {
        var b = new StringBuilder();
        b.append("You are answering as '").append(current.name())
         .append("'. If this needs a different model, write one line and stop:\n\n")
         .append("    #HANDOFF <name>  <one sentence on why>\n\navailable: ");
        for (int i = 0; i < TIERS.size(); i++) {
            var t = TIERS.get(i);
            if (i > 0) b.append("; ");
            b.append(t.name()).append(" (").append(t.suitedTo()).append(')');
        }
        b.append(".\nHand over when the work genuinely needs it, not by default: ")
         .append("it costs the user another call.\n");
        return b.toString();
    }
}
