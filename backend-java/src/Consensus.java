import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

/**
 * What everybody turned out to want.
 *
 * A script written mid-answer is one model's guess about which of its answers
 * were general. This is the other way round: watch what people actually ask
 * about a kind of widget, notice when different people are getting the same
 * answer, and only then turn it into an operation.
 *
 * The difference matters because the two are wrong in opposite directions. A
 * model scripting its own answer is confident too early - it has seen one
 * request. Evidence across users is late but sure: by the time several people
 * have independently been given the same thing, that thing is not about any of
 * them.
 *
 * <h2>Counting people, not requests</h2>
 *
 * Consensus is counted in distinct accounts. One person asking the same
 * question five times is one data point, not five, and any other rule would
 * let a single user manufacture agreement on everyone else's behalf.
 *
 * <h2>Why one person is now enough to try</h2>
 *
 * It was three, and three was doing two jobs: deciding that a request is
 * general, and deciding that it is worth shipping. It is good at the first and
 * it was never doing the second - the consortium was. What it also did was
 * make the very first operation on a subject impossible to reach, because
 * nobody can be the third person to ask for something that has never worked.
 * The machine this is aimed at has no network at first boot; the operations it
 * needs most are exactly the ones nobody has asked for three times.
 *
 * So the threshold is one, and the gate moved rather than went away. What
 * carries it now is the consortium, which sees the compiled code, what it did
 * when run, and - this is the part that matters - how many people the evidence
 * came from. One is thin evidence and the reviewers are told it is thin, so
 * they can hold something that several people's agreement would have carried.
 *
 * The defence that remains is worth stating exactly, because it is weaker than
 * what it replaced. Counting distinct accounts stopped one user manufacturing
 * demand. Nothing stops that now; what stops a bad operation is that several
 * models must separately agree it should exist, having read it. A user can
 * cause an operation to be *considered*. They cannot cause one to ship.
 *
 * <h2>What is compared</h2>
 *
 * Answers are compared after collapsing whitespace and case, which catches the
 * reformattings that mean nothing, and nothing else. Two answers differing in
 * substance are two answers, and neither wins until enough people have
 * received it. There is no fuzzy matching on purpose: deciding that two
 * different programs are "similar enough" to be one operation is exactly the
 * judgement that would hand somebody the wrong one.
 */
final class Consensus {

    /**
     * How many distinct people must have received an answer before it counts.
     *
     * One: enough to try, never enough to ship. See the note above on where
     * the gate went. Raising this again is a one-line change and makes the
     * system slower and safer in exactly the way it used to be.
     */
    static final int AGREE = 1;

    /** After this many, stop tracking a question nobody is converging on. */
    private static final int MAX_VARIANTS = 12;

    /** One question, and what people have been told in reply to it. */
    private static final class Question {
        final String subject;
        final String instruction;
        /** answer digest -> the accounts that received it */
        final Map<String, Set<String>> variants = new ConcurrentHashMap<>();
        /** answer digest -> the answer itself, kept once */
        final Map<String, String> answers = new ConcurrentHashMap<>();
        volatile boolean promoted;

        Question(String subject, String instruction) {
            this.subject = subject;
            this.instruction = instruction;
        }
    }

    /** A question that has converged, and the answer it converged on. */
    record Agreed(String subject, String instruction, String answer, int people) {}

    private final Map<String, Question> questions = new ConcurrentHashMap<>();
    private final AtomicLong seen = new AtomicLong();
    private final AtomicLong agreed = new AtomicLong();

    private static String norm(String s) {
        return s == null ? "" : s.strip().toLowerCase(Locale.ROOT).replaceAll("\\s+", " ");
    }

    private static String digest(String s) {
        try {
            var md = MessageDigest.getInstance("SHA-256");
            return HexFormat.of().formatHex(md.digest(norm(s).getBytes(StandardCharsets.UTF_8)))
                    .substring(0, 24);
        } catch (Exception x) {
            throw new IllegalStateException(x);
        }
    }

    /**
     * Record what one account was told, and say whether that settles it.
     *
     * @return the agreed answer the first time a question crosses the line, and
     *         null every other time - including afterwards, so a promotion
     *         happens once rather than on every subsequent ask.
     */
    Agreed record(String accountId, String subject, String instruction, String answer) {
        if (accountId == null || answer == null || answer.isBlank()) return null;
        if (instruction == null || instruction.isBlank()) return null;

        String key = norm(subject) + " " + norm(instruction);
        var q = questions.computeIfAbsent(key, k -> new Question(norm(subject), instruction.strip()));
        if (q.promoted) return null;
        seen.incrementAndGet();

        String d = digest(answer);
        if (!q.variants.containsKey(d) && q.variants.size() >= MAX_VARIANTS) {
            // Everyone is getting something different. That is a question with
            // no general answer, and collecting more variants of it only costs
            // memory.
            return null;
        }
        q.answers.putIfAbsent(d, answer);
        var people = q.variants.computeIfAbsent(d, k -> ConcurrentHashMap.newKeySet());
        people.add(accountId);

        if (people.size() < AGREE) return null;
        synchronized (q) {
            if (q.promoted) return null;
            q.promoted = true;
        }
        agreed.incrementAndGet();
        return new Agreed(q.subject, q.instruction, q.answers.get(d), people.size());
    }

    /**
     * What to ask the model once a question has settled.
     *
     * It is shown the agreement rather than asked to imagine one, and asked for
     * the general operation behind it - the point of promoting is to cover the
     * next person who asks something of the same shape, not to memorise one
     * sentence.
     */
    static String promotionPrompt(Agreed a) {
        /*
         * One person and several people are different evidence and the prompt
         * says which this is. Telling a model that several people agreed when
         * one person asked is not a rounding error - it is the whole reason it
         * would relax, and it would relax about the wrong thing.
         */
        String evidence = a.people() >= 2
                ? """
                  %d different people have asked this about a %s, and every one
                  of them was given the same answer. That makes it nobody's in
                  particular.
                  """.formatted(a.people(), a.subject().isBlank() ? "screen" : a.subject())
                : """
                  One person has asked this about a %s and been given this
                  answer. One is not evidence that it is general - it is only
                  reason to look. Decide whether there is a real operation here
                  on the merits of the request itself, not on how many asked.
                  """.formatted(a.subject().isBlank() ? "screen" : a.subject());

        return """
                %s
                WHAT WAS ASKED:
                %s

                WHAT WAS GIVEN:
                %s

                If there is a general operation here, the server should be able
                to answer it without waking you. Write it.

                Write the general case rather than this one sentence: if the
                answer depends on something in the request, make that a typed
                variable, so the next person asking a version of this is covered
                too. If there is genuinely nothing general here - a request that
                is about one person's document, or one that only makes sense
                once - say NOTHING AT ALL, and it will keep being asked
                normally. Saying nothing is the ordinary outcome and costs
                nobody anything.
                """.formatted(evidence, a.instruction(), a.answer());
    }

    String asJson() {
        int converged = 0;
        for (var q : questions.values()) if (q.promoted) converged++;
        return Json.obj("questions", questions.size(), "answers", seen.get(),
                "agreed", agreed.get(), "promoted", converged, "threshold", AGREE);
    }

    /** For the operator: what is close to settling, and what is scattered. */
    List<String> pending() {
        var out = new ArrayList<String>();
        for (var q : questions.values()) {
            if (q.promoted) continue;
            int best = 0;
            for (var p : q.variants.values()) best = Math.max(best, p.size());
            if (best > 1) {
                out.add("%s :: %s (%d of %d agreeing, %d variants)"
                        .formatted(q.subject, q.instruction, best, AGREE, q.variants.size()));
            }
        }
        return out;
    }
}
