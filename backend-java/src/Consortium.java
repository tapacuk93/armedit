import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.regex.Pattern;

/**
 * Several models, asked the same question separately, before machine code is
 * committed to the repository.
 *
 * <h2>Why this exists at all</h2>
 *
 * Everything else in this backend is one model's judgement. That is the right
 * trade for an answer on somebody's screen: it is theirs, it is visible, and
 * if it is wrong they retype the line. A blob committed to the repository is
 * none of those things. It ships in the distro, it runs on machines whose
 * owners never asked for it, and by the time it is wrong it is wrong everywhere
 * at once. The asymmetry is the argument: an answer costs one person a retry,
 * a bad committed operation costs every user a release.
 *
 * So the last gate before the repository is not the model that wrote the
 * operation. It is every model this wallet can reach, asked independently.
 *
 * <h2>Independently</h2>
 *
 * No member sees another's vote, and none is told what the author said in its
 * favour. A consortium that passes opinions along is one opinion with echoes -
 * it produces agreement without producing evidence, and agreement is precisely
 * the thing being measured. The prompt is identical for everyone; only the
 * model differs.
 *
 * <h2>Unanimity, and a quorum</h2>
 *
 * A commit needs every member who answered to vote for it. Majority rule is
 * right when the cost of a wrong yes and a wrong no are alike, and here they
 * are not: holding costs a release cycle, committing costs everybody. One
 * credible objection is enough, and a member that objects has to say why - a
 * vote with no reason is not counted, in either direction, because an
 * unexplained yes is as useless as an unexplained no.
 *
 * A member that fails - times out, errors, answers in a shape nothing can read
 * - does not vote and does not block. It does count against the quorum, which
 * is why the quorum exists: with one reachable model this is not a consortium,
 * it is the same single judgement wearing a committee's name, and it should
 * decline rather than pretend.
 *
 * <h2>The bench</h2>
 *
 * "Every model the wallet can reach" is a hundred and thirty-odd names, most
 * of which transcribe audio or embed text. The bench is one seat per model
 * family - the newest member of each - up to a cap, and what did not get a
 * seat is logged rather than silently dropped, so a bench of three never reads
 * as a bench of everything.
 */
final class Consortium {

    /** Below this many actual voters, the question is not put to a vote. */
    static final int QUORUM = 3;

    /** Seats. Enough for disagreement to show up, few enough to afford. */
    private static final int SEATS = 6;

    /**
     * The output cap for a member's answer.
     *
     * Generous, because reasoning models spend their budget thinking before
     * they write anything. A cap that a chat model would find roomy makes a
     * reasoning model stop at finish_reason "length" with an empty string -
     * which arrives here as a member that could not answer, when in fact it
     * was answering and ran out of room. Four thousand was still short enough
     * to lose a member on a sitting; the answers themselves are four lines, so
     * the whole of this budget is thinking, and paying for it is cheaper than
     * seating a model that cannot finish.
     */
    private static final int CAP = 8000;

    /**
     * Members that failed in a way that will not get better.
     *
     * A model can be listed by the provider and still not be callable this
     * way - "only supported in v1/responses" is a real answer to a real
     * request, and it will be the same answer next sitting. Remembering saves
     * a seat rather than a request: an unseatable member does not merely fail,
     * it occupies one of six places while doing so.
     */
    private final java.util.Set<String> unseatable =
            java.util.concurrent.ConcurrentHashMap.newKeySet();

    /**
     * Model families that cannot review anything, by name.
     *
     * Matching on names is guesswork, and it is the cheap kind: the cost of a
     * wrong exclusion is one absent voice, and the cost of a wrong inclusion is
     * a whisper model failing on every review forever. When in doubt this
     * leaves a model out.
     */
    private static final Pattern NOT_A_REVIEWER = Pattern.compile(
            "(?i).*(embed|whisper|tts|audio|realtime|moderation|transcribe|"
            + "image|dall-e|sora|search-preview|instruct|davinci|babbage).*");

    /** What one member said. */
    record Vote(String member, boolean commit, String why, List<String> changes,
                String error) {
        boolean counted() { return error == null && why != null && !why.isBlank(); }
    }

    /** What they said together. */
    record Verdict(boolean commit, String why, List<Vote> votes, List<String> changes) {

        /**
         * Did anybody want this?
         *
         * A hold that every counted member agreed on is a rejection: several
         * models read the same code and none of them wanted it. A hold that
         * some members voted against is a disagreement, which is a different
         * thing - it says the panel could not settle the question, not that it
         * settled it against. Only the second is worth keeping, and telling
         * them apart is the whole reason a verdict carries its votes.
         */
        boolean divided() {
            boolean any = false;
            for (var v : votes) {
                if (!v.counted()) continue;
                any = true;
                if (v.commit()) return true;
            }
            return !any;        // nobody could be reached: unsettled, not refused
        }

        int voters() {
            int n = 0;
            for (var v : votes) if (v.counted()) n++;
            return n;
        }
    }

    private final Aicoin aicoin;
    private final Catalogue catalogue;
    private final ExecutorService pool = Executors.newFixedThreadPool(SEATS, r -> {
        var t = new Thread(r, "armedit-consortium");
        t.setDaemon(true);
        return t;
    });

    Consortium(Aicoin aicoin, Catalogue catalogue) {
        this.aicoin = aicoin;
        this.catalogue = catalogue;
    }

    // ----------------------------------------------------------- the bench

    /**
     * Who sits. One per family, newest first, non-reviewers left out.
     *
     * Families are derived by cutting the version off the name, which is
     * approximate and admits it: the point is not a taxonomy, it is that six
     * seats should not all go to the same model at six version numbers.
     */
    List<Catalogue.Member> bench() {
        var byFamily = new LinkedHashMap<String, Catalogue.Member>();
        var all = new ArrayList<>(catalogue.members());
        // Newest-looking first, so the seat a family gets is its best one.
        all.sort(Comparator.comparing((Catalogue.Member m) -> m.model()).reversed());
        for (var m : all) {
            if (NOT_A_REVIEWER.matcher(m.model()).matches()) continue;
            if (unseatable.contains(m.toString())) continue;
            byFamily.putIfAbsent(m.provider() + "/" + family(m.model()), m);
        }

        /*
         * Seats go round the providers, not down the list.
         *
         * Sorted by name, one provider's models occupy the whole front of the
         * queue, and the first sitting this ran filled all six seats with one
         * vendor - six models sharing a training pipeline, a house style, and
         * most of their blind spots. That is a single opinion with five
         * corroborations, which is worse than one opinion because it looks
         * like agreement. Taking one from each provider in turn costs nothing
         * and is the entire reason to ask more than one model.
         */
        var queues = new LinkedHashMap<String, ArrayList<Catalogue.Member>>();
        for (var m : byFamily.values()) {
            queues.computeIfAbsent(m.provider(), k -> new ArrayList<>()).add(m);
        }
        var seated = new ArrayList<Catalogue.Member>();
        boolean took = true;
        while (took && seated.size() < SEATS) {
            took = false;
            for (var q : queues.values()) {
                if (q.isEmpty() || seated.size() >= SEATS) continue;
                seated.add(q.remove(0));
                took = true;
            }
        }
        int eligible = byFamily.size();
        if (eligible > seated.size()) {
            System.out.printf("armedit: consortium seats %d of %d eligible models, "
                    + "across %d provider(s)%n", seated.size(), eligible, queues.size());
        }
        return seated;
    }

    /** "claude-opus-4-5-20251101" and "claude-opus-5" are both "claude-opus". */
    static String family(String model) {
        String s = model.toLowerCase(Locale.ROOT);
        // Strip trailing version and date parts: anything that is only digits,
        // or digits with a leading letter like "4o" kept, is version noise.
        var parts = new ArrayList<>(List.of(s.split("-")));
        while (parts.size() > 1) {
            String last = parts.get(parts.size() - 1);
            if (last.matches("\\d+") || last.matches("\\d{6,}")
                    || last.matches("v?\\d+(\\.\\d+)*")) {
                parts.remove(parts.size() - 1);
            } else {
                break;
            }
        }
        return String.join("-", parts);
    }

    // ------------------------------------------------------------- asking

    /**
     * Put one question to the bench and count what comes back.
     *
     * @param wallet   whose coins pay for the sitting
     * @param subject  what is being decided, for the log
     * @param question the whole prompt, identical for every member
     */
    Verdict decide(String wallet, String subject, String question) {
        var seats = bench();
        if (seats.size() < QUORUM) {
            return new Verdict(false,
                    "only %d model%s reachable; a consortium of that size is one opinion"
                            .formatted(seats.size(), seats.size() == 1 ? "" : "s"),
                    List.of(), List.of());
        }

        String prompt = question + "\n" + FORMAT;
        var jobs = new ArrayList<Callable<Vote>>();
        for (var seat : seats) {
            jobs.add(() -> {
                try {
                    String said = aicoin.askDirect(wallet, seat.provider(), seat.model(),
                            prompt, CAP);
                    return read(seat.toString(), said);
                } catch (Exception x) {
                    if (permanent(x)) unseatable.add(seat.toString());
                    return new Vote(seat.toString(), false, null, List.of(), String.valueOf(x));
                }
            });
        }

        var votes = new ArrayList<Vote>();
        try {
            for (Future<Vote> f : pool.invokeAll(jobs, 4, TimeUnit.MINUTES)) {
                try {
                    votes.add(f.get());
                } catch (Exception x) {
                    votes.add(new Vote("?", false, null, List.of(), String.valueOf(x)));
                }
            }
        } catch (InterruptedException x) {
            Thread.currentThread().interrupt();
            return new Verdict(false, "the sitting was interrupted", votes, List.of());
        }

        int counted = 0, against = 0;
        var changes = new ArrayList<String>();
        var objections = new ArrayList<String>();
        for (var v : votes) {
            if (!v.counted()) continue;
            counted++;
            changes.addAll(v.changes());
            if (!v.commit()) {
                against++;
                objections.add(v.member() + ": " + v.why());
            }
        }

        if (counted < QUORUM) {
            return new Verdict(false,
                    "%d of %d members answered; below the quorum of %d"
                            .formatted(counted, seats.size(), QUORUM),
                    votes, changes);
        }
        if (against > 0) {
            var sustained = new ArrayList<String>();
            for (var v : votes) {
                if (!v.counted() || v.commit()) continue;
                if (appeal(wallet, question, v, votes)) {
                    sustained.add(v.member() + ": " + v.why());
                } else {
                    System.out.printf("armedit: objection from %s overruled by the rest%n",
                            v.member());
                }
            }
            if (!sustained.isEmpty()) {
                return new Verdict(false, String.join("; ", sustained), votes, changes);
            }
            return new Verdict(true,
                    "%d of %d members; %d objection(s) put back to the others and overruled"
                            .formatted(counted, seats.size(), against),
                    votes, changes);
        }
        return new Verdict(true, "%d of %d members, unanimous".formatted(counted, seats.size()),
                votes, changes);
    }

    /**
     * Will this member fail the same way next time?
     *
     * Only for answers that are about the model rather than about the moment.
     * A timeout or a rate limit is the moment; "this model is not available on
     * this endpoint" is the model, and no amount of retrying changes it.
     */
    private static boolean permanent(Exception x) {
        String m = String.valueOf(x.getMessage()).toLowerCase(Locale.ROOT);
        return m.contains("404") || m.contains("not supported")
                || m.contains("only supported") || m.contains("does not exist")
                || m.contains("400");
    }

    /**
     * Put one objection back to the members who did not raise it.
     *
     * Unanimity has a failure mode, and it showed up on the first real sitting:
     * the weakest model on the bench answered "this should be verified and
     * audited", which is true of all code, names nothing, and under a strict
     * rule blocks everything forever. Dropping unanimity would fix that by
     * throwing away the property worth having - that one good objection is
     * enough.
     *
     * So an objection is not overruled by counting the votes that already
     * exist. It is put back, as a question, to the members who did not make it,
     * and it stands unless most of them say it is wrong or says nothing. A
     * vague objection loses because its peers can see it is vague; a sharp one
     * survives even alone, which is the whole point of having asked.
     *
     * The question is about correctness, not only specificity, and it is worth
     * saying why it had to be changed to that. Asked only whether an objection
     * was specific, the jury sustained one that was specific and false - a
     * confident claim that an API parameter did not exist, made by a model
     * whose training predated it. Specificity is easy to see and is not the
     * property that matters; a precise wrong answer is more dangerous than a
     * vague one, because it survives exactly the filter that vagueness fails.
     *
     * Silence sustains. If nobody can be reached to overrule an objection, the
     * objection stands - the safe direction when the question is whether to
     * ship.
     */
    private boolean appeal(String wallet, String question, Vote objection, List<Vote> votes) {
        var jury = new ArrayList<String>();
        for (var v : votes) if (v.counted() && v.commit()) jury.add(v.member());
        if (jury.isEmpty()) {
            System.out.printf("armedit: objection from %s stands unopposed - "
                    + "nobody else voted to commit%n", objection.member());
            return true;
        }

        String ask = """
                You reviewed a change and approved it. Another reviewer objected. Their
                objection is quoted below; decide only whether it is a real, specific
                objection to this change.

                THE OBJECTION

                %s

                THE CHANGE THEY WERE BOTH LOOKING AT

                %s

                Answer OVERRULE if the objection is wrong about this change, or if it
                names nothing specific to it - if it is the kind of thing that could be
                said, unchanged, about any code at all. Answer SUSTAIN only if it is both
                specific and correct.

                Check the claim against the diff before ruling. An objection can be
                precise, confident and mistaken, and those are the ones worth catching:
                if it asserts something about the world rather than about the code -
                that an API does not exist, that a name is wrong, that something is not
                supported - and the change itself contains evidence otherwise, that is
                an OVERRULE.
                """.formatted(objection.why(), question);

        String format = """

                Answer in exactly this shape:

                RULING: SUSTAIN
                WHY: one sentence
                """;

        var jobs = new ArrayList<Callable<Boolean>>();
        for (var member : jury) {
            int at = member.indexOf(':');
            String provider = member.substring(0, at), model = member.substring(at + 1);
            jobs.add(() -> {
                String said = aicoin.askDirect(wallet, provider, model, ask + format, CAP);
                for (String line : said.split("\n")) {
                    String u = line.strip().toUpperCase(Locale.ROOT);
                    if (u.startsWith("RULING:")) return !u.substring(7).strip().startsWith("OVERRULE");
                }
                return true;   // unreadable: sustains, like silence
            });
        }

        int sustain = 0, heard = 0;
        try {
            for (Future<Boolean> f : pool.invokeAll(jobs, 4, TimeUnit.MINUTES)) {
                try {
                    if (f.get()) sustain++;
                    heard++;
                } catch (Exception ignored) {
                    // A juror that could not answer does not get a say either way.
                }
            }
        } catch (InterruptedException x) {
            Thread.currentThread().interrupt();
            return true;
        }
        if (heard == 0) return true;
        return sustain * 2 >= heard;
    }

    /**
     * What to tell a panel that is seeing this for the second time.
     *
     * It held once, because it could not settle whether anybody wanted the
     * thing. Since then people have. That is new information and it is the
     * information the earlier hold was short of - so it is put in front of
     * them plainly, along with what their own reason was, and they are told
     * that this is the last time: a hold now ends it rather than parking it
     * again. A gate asked the same question repeatedly until it says yes is
     * not a gate.
     */
    static String settled(int people, String earlier) {
        return ("WHAT A HOLD DOES  This was held once already and kept, because the panel\n"
                + "                  was split rather than agreed. The reason recorded then\n"
                + "                  was: %s\n"
                + "                  Since then %d distinct people have asked for something\n"
                + "                  it matches. That is the evidence the earlier hold was\n"
                + "                  short of, and it is why you are being asked again.\n"
                + "                  A hold now ends it. It will not be kept a second time.")
                .formatted(earlier == null || earlier.isBlank() ? "(not recorded)" : earlier,
                           people);
    }

    private static final String FORMAT = """

            Answer in exactly this shape and nothing else:

            VERDICT: COMMIT
            WHY: one sentence, and it must be about this code specifically
            CHANGE: something you would change, or omit this line entirely

            VERDICT is COMMIT or HOLD. Use HOLD if you found something wrong, or
            if you cannot tell - "it looks fine" without having checked is the
            answer this process exists to filter out. CHANGE may repeat.

            A WHY that would read the same about any other operation is not a
            reason and will not be counted.
            """;

    private static final Pattern NOTHING = Pattern.compile(
            "(?i)\\s*(none|n/?a|nothing|omit|-{1,3}|no changes?|\\(omit\\))\\.?\\s*");

    /** Read a member's reply. Anything unparseable is a member that did not vote. */
    static Vote read(String member, String said) {
        if (said == null) return new Vote(member, false, null, List.of(), "no reply");
        Boolean commit = null;
        String why = null;
        var changes = new ArrayList<String>();
        for (String line : said.split("\n")) {
            String t = line.strip();
            String upper = t.toUpperCase(Locale.ROOT);
            if (upper.startsWith("VERDICT:")) {
                String v = upper.substring(8).strip();
                if (v.startsWith("COMMIT")) commit = true;
                else if (v.startsWith("HOLD")) commit = false;
            } else if (upper.startsWith("WHY:")) {
                why = t.substring(4).strip();
            } else if (upper.startsWith("CHANGE:")) {
                String c = t.substring(7).strip();
                // "CHANGE: none" is a member following the letter of the format
                // rather than its intent, and it reads downstream as a change
                // somebody asked for. There is no such change.
                if (!c.isEmpty() && !NOTHING.matcher(c).matches()) {
                    changes.add(member + ": " + c);
                }
            }
        }
        if (commit == null) {
            return new Vote(member, false, null, List.of(), "no VERDICT line in the reply");
        }
        return new Vote(member, commit, why, List.copyOf(changes), null);
    }

    // ------------------------------------------------------- the questions

    /**
     * The question asked about a compiled operation.
     *
     * It carries the source, the machine code as bytes, and what the operation
     * actually printed when it was run - because "does this compile" is a
     * question the compiler already answered, and the one left is whether this
     * should be on everybody's machine.
     */
    /**
     * What the reviewers are shown.
     *
     * The demand line is not decoration. Promotion used to require three
     * distinct people before an operation could be written at all, and that
     * threshold was doing two different jobs - judging that a request is
     * general, and judging that it is worth shipping. It only ever did the
     * first, and it made the first operation on any subject unreachable:
     * nobody can be the third person to ask for something that has never
     * worked. It is one person now, and this review is where the other job
     * went. So the reviewers are told exactly how many people the evidence
     * came from, and told what thin evidence should do to their bar - because
     * a reviewer who assumes there was agreement behind a request will approve
     * things that had none.
     */
    static String aboutBlob(String name, String pattern, List<String> arguments,
                            String source, byte[] code, String sha, String observed,
                            int people, String afterwards) {
        return """
                This is a code review for an open-source text editor. The editor's build
                system writes small operations for itself, compiles them ahead of time to
                aarch64, and checks the result into its own public repository so that the
                editor still has them when it is offline. Committing one is an ordinary
                source-control change to this project, reviewed the way any other change
                would be; users receive it when they update the editor.

                You are one of several models reviewing it separately. Judge the code in
                front of you; you are not being asked to agree with anyone.

                %s

                OPERATION   %s
                MATCHES     %s
                ARGUMENTS   %s
                CODE        %d bytes of aarch64, sha %s

                SOURCE (a small JavaScript subset the backend compiles ahead of time):

                %s

                COMPILER OUTPUT - what this project's own ahead-of-time compiler emitted
                from the source above, as 32-bit little-endian aarch64 words:

                %s

                WHAT IT DID WHEN RUN, on every value its pattern accepts:

                %s

                WHAT GETS COMMITTED, if you approve: the bytes above, the source above,
                the pattern and argument list, the sha, and this review with every
                member's reasoning - three files under ops/, in the same commit. The
                source stays in the repository next to the binary, so the compilation can
                be repeated and the result compared.

                Things that would make this a HOLD: it answers requests it should decline;
                it answers them wrongly; it is so specific that it will never match twice;
                it is so general that it will match things it should not; it hardcodes
                something that belongs to one user; it would behave differently offline
                than it does here.

                %s
                """.formatted(demand(people), name, pattern, String.join(", ", arguments),
                        code.length, sha, source, words(code), observed, afterwards);
    }

    /**
     * What a HOLD now means, said out loud.
     *
     * A hold used to be the end. It is not any more: a hold the panel is split
     * on parks the operation until enough distinct people have asked for it, and
     * a hold everybody agrees on ends it. That difference is decided by the
     * votes, so a member who would rather see more evidence than refuse should
     * know that voting HOLD while others vote COMMIT is how to say so - and a
     * member who thinks the thing should never exist should know that agreeing
     * with the other holds is how to end it.
     *
     * Where the waiting list cannot fire - too few accounts for its threshold -
     * they are told that instead, because on such a deployment a split hold is
     * an operation nobody will ever see again, and a reviewer choosing it should
     * be choosing that knowingly.
     */
    static String afterwards(int registered, int threshold, boolean canWait) {
        if (!canWait) {
            return ("WHAT A HOLD DOES  It ends this. There are %d registered accounts and "
                    + "the\n                  waiting list needs %d distinct people, so nothing "
                    + "can come\n                  off it. Do not hold in order to see more "
                    + "evidence; there\n                  will not be any.").formatted(registered, threshold);
        }
        return ("WHAT A HOLD DOES  A hold every counted member agrees on ends this. A hold\n"
                + "                  some members vote against keeps it instead, and it ships\n"
                + "                  once %d distinct people have asked for something it\n"
                + "                  matches, or expires unasked. So hold if it is wrong, and\n"
                + "                  hold apart from the others if you would rather wait and\n"
                + "                  see whether anybody wants it.").formatted(threshold);
    }

    /**
     * How much wanting is behind this, said plainly.
     *
     * A reviewer told nothing assumes the normal case, and the normal case
     * used to be three people. Saying "one person asked once" costs a line and
     * changes what a careful reviewer does with a borderline operation, which
     * is the entire point of moving the gate here.
     */
    private static String demand(int people) {
        if (people >= 2) {
            return ("EVIDENCE    %d different people asked for this separately and were "
                    + "given\n            the same answer. That is real demand and it is "
                    + "not about any\n            one of them.").formatted(people);
        }
        return "EVIDENCE    One person asked for this once. That is not evidence that it\n"
             + "            is general - it is only a reason to look. Nothing else stands\n"
             + "            between this operation and the repository, so hold it unless\n"
             + "            it is worth having on its own merits: it should be something\n"
             + "            the next person to ask something of this shape would want,\n"
             + "            not something that reads as one user's request written out.";
    }

    /**
     * The machine code, written out so it can actually be looked at.
     *
     * The first sitting this ran was held up by a member pointing out that it
     * had been asked to approve 488 bytes of aarch64 it had never been shown -
     * which was correct, and exactly the kind of objection the process is for.
     * A sha proves two people are discussing the same bytes; it does not let
     * anyone read them.
     *
     * aarch64 is fixed-width, so words are the honest unit: one instruction
     * each, in the order they execute.
     */
    static String words(byte[] code) {
        var b = new StringBuilder();
        for (int i = 0; i + 3 < code.length; i += 4) {
            int w = (code[i] & 0xff) | (code[i + 1] & 0xff) << 8
                  | (code[i + 2] & 0xff) << 16 | (code[i + 3] & 0xff) << 24;
            if (i % 32 == 0) b.append(i == 0 ? "    " : "\n    ");
            b.append(String.format("%08x ", w));
        }
        if (code.length % 4 != 0) {
            b.append("\n    (and ").append(code.length % 4)
             .append(" trailing bytes, which is itself worth asking about)");
        }
        return b.toString().stripTrailing();
    }

    /**
     * The question asked about a change to the project itself.
     *
     * Same bench, same rule, different subject: this one is put before a diff
     * is pushed rather than before a blob is committed.
     */
    static String aboutDiff(String summary, String diff) {
        return """
                A change to a text editor written in aarch64 assembly, with a Java backend
                that writes and compiles editor operations. The project's rule is that the
                editor itself uses no libraries: everything is assembly written for it.

                You are one of several models being asked this separately. Review the diff
                on its own terms; you are not being asked to agree with anyone.

                WHAT IT IS MEANT TO DO:

                %s

                THE DIFF:

                %s

                Things that would make this a HOLD: it is wrong; it breaks something the
                diff does not mention; it leaves a case unhandled that the code around it
                handles; a comment claims something the code does not do.
                """.formatted(summary, diff);
    }
}
