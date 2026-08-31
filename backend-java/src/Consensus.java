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
 * question five times is one data point, not five, and any other rule lets a
 * single user manufacture agreement on everyone else's behalf. That is the
 * whole defence here, and it is worth being explicit that it is the only one.
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

    /** How many distinct people must have received an answer before it counts. */
    static final int AGREE = 3;

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
        return """
                %d different people have asked this about a %s, and every one of
                them was given the same answer.

                WHAT THEY ASKED:
                %s

                WHAT THEY WERE ALL GIVEN:
                %s

                That makes it nobody's in particular, so the server should be
                able to answer it without waking you. Write the operation.

                Write the general case rather than this one sentence: if the
                answer depends on something in the request, make that a typed
                variable, so the next person asking a version of this is covered
                too. If there is genuinely nothing general here - if the
                agreement is a coincidence of several people wanting the
                identical thing - say NOTHING AT ALL, and it will keep being
                asked normally.
                """.formatted(a.people(), a.subject().isBlank() ? "screen" : a.subject(),
                              a.instruction(), a.answer());
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
