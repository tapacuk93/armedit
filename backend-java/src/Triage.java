import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * One model, asked first, so that the panel is not asked about everything.
 *
 * A consortium is several models answering separately and then arguing, and it
 * costs what that sounds like - a four-model panel over two rounds is thirteen
 * calls. Most operations that reach it are not close calls. Something plainly
 * not worth having can be ended by one model for the price of one call, and
 * that is what this is.
 *
 * <h2>What it may and may not do</h2>
 *
 * It may end things. It may not start them. A NO here drops the operation; a
 * YES only means the panel is worth convening, and the panel still decides
 * whether anything is committed. That asymmetry is deliberate and it is the
 * project's oldest rule: machine code enters this repository when several
 * models have separately agreed it should, and one model agreeing is not that.
 * Nothing is saved by letting a cheap yes ship - the expensive review is the
 * one that was worth paying for.
 *
 * <h2>Being unsure is an answer</h2>
 *
 * UNSURE is a real verdict, not a failure to give one, and it is passed on to
 * the panel rather than resolved here. A single model told to pick a side will
 * pick one, and the side it picks on a genuinely open question is noise that
 * the panel would then be reviewing as though it meant something.
 */
final class Triage {

    enum Say { YES, NO, UNSURE }

    record Word(Say say, String why) {
        boolean rejected() { return say == Say.NO; }
        boolean unsure() { return say == Say.UNSURE; }
    }

    private static final int CAP = 700;

    private static final Pattern VERDICT =
            Pattern.compile("(?im)^\\s*VERDICT\\s*:\\s*(YES|NO|UNSURE)\\b");
    private static final Pattern WHY =
            Pattern.compile("(?im)^\\s*WHY\\s*:\\s*(.+)$");

    private final Aicoin aicoin;

    Triage(Aicoin aicoin) { this.aicoin = aicoin; }

    /**
     * Ask, and treat every kind of silence as UNSURE.
     *
     * A model that errored, timed out or answered in a shape nobody can read
     * has not said no. Reading any of those as a rejection would let a network
     * problem quietly decide what this project ships, which is the failure mode
     * that is hardest to notice because it looks like nothing happening.
     */
    Word judge(String wallet, Router.Tier tier, String about) {
        try {
            return read(aicoin.ask(wallet, tier, about + "\n" + FORMAT, CAP));
        } catch (Exception x) {
            return new Word(Say.UNSURE, "the first pass did not answer: " + x);
        }
    }

    static Word read(String said) {
        if (said == null || said.isBlank()) return new Word(Say.UNSURE, "nothing came back");
        Matcher m = VERDICT.matcher(said);
        if (!m.find()) return new Word(Say.UNSURE, "no verdict in the reply");
        Say say = Say.valueOf(m.group(1).toUpperCase(Locale.ROOT));
        Matcher w = WHY.matcher(said);
        String why = w.find() ? w.group(1).strip() : "";
        /*
         * A verdict with no reason is not a verdict. The same rule the panel
         * uses, for the same reason: "yes" on its own is indistinguishable
         * from a model that did not read the question, and this one is cheap
         * enough that the honest answer to an unreadable reply is to escalate.
         */
        if (why.isBlank()) return new Word(Say.UNSURE, "a verdict with no reason");
        return new Word(say, why);
    }

    /**
     * What the first pass is asked.
     *
     * It is told the shape of the ladder it is standing on - that no means no,
     * yes means a panel, unsure means a panel - because a model that does not
     * know what its answer causes cannot weigh it. And it is told whether the
     * waiting list below the panel can ever fire, since on a deployment with
     * too few accounts an unsure answer is a decision never to decide.
     */
    static String about(String name, String pattern, String source, String observed,
                        int people, int registered, int threshold, boolean canWait) {
        return """
                An operation has been written for a text editor that compiles small
                operations for itself and keeps them in its own repository. You are the
                first pass: one model, asked before a panel of several is convened.

                Your answer decides what happens next, so weigh it knowing that:
                  NO      ends it here, and it is written no further.
                  YES     convenes the panel, which reviews the code and decides.
                  UNSURE  convenes the same panel, told that you were unsure.

                You are not being asked whether the code is correct - the panel reads
                the code. You are being asked whether this is a thing the editor should
                be able to do at all: whether it would answer the next person who asked
                something of this shape, or whether it is one person's sentence written
                out as though it were a feature.

                %s

                OPERATION   %s
                MATCHES     %s

                SOURCE:

                %s

                WHAT IT DID WHEN RUN, on every value its pattern accepts:

                %s
                """.formatted(demand(people, registered, threshold, canWait),
                        name, pattern, source, observed);
    }

    /**
     * How much wanting there is, and what the machinery can do about it.
     *
     * The last sentence is the part that matters on a small deployment. A model
     * that leaves a decision to a counter needs to know whether the counter can
     * ever reach its mark - and where it cannot, "decide" is the only useful
     * instruction, because the alternative dressed up as caution is a shelf
     * nothing ever comes off.
     */
    static String demand(int people, int registered, int threshold, boolean canWait) {
        String asked = people >= 2
                ? "%d different people asked for this separately.".formatted(people)
                : "One person asked for this once. That is not evidence that it is "
                  + "general; it is a reason to look.";
        String wait = canWait
                ? ("This deployment has %d registered accounts. If the panel is also unsure, "
                   + "this is kept until %d distinct people have asked for something it "
                   + "matches, and then goes back to the panel with that number in front of "
                   + "it.").formatted(registered, threshold)
                : ("This deployment has %d registered account%s, and the waiting list below "
                   + "the panel needs %d distinct people, so nothing can ever come off it. "
                   + "%sOn this deployment an unsure answer is a decision never to decide. "
                   + "Decide.").formatted(registered, registered == 1 ? "" : "s", threshold,
                        registered <= 1
                                ? "The person who asked for this is the entire user base, so "
                                  + "whether anybody wants it is not the open question - "
                                  + "everybody who could has already asked. "
                                : "");
        return "EVIDENCE    " + asked + " " + wait;
    }

    private static final String FORMAT = """

            Answer in exactly this shape and nothing else:

            VERDICT: YES
            WHY: one sentence, and it must be about this operation specifically

            VERDICT is YES, NO or UNSURE. A WHY that would read the same about any
            other operation is not a reason and will not be counted.
            """;
}
