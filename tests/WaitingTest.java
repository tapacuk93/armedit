import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

/**
 * The waiting list, and the ladder that leads to it.
 *
 * A review can say three things and the code used to hear two. Wrong is
 * dropped, right ships, and "we could not settle it" is neither - it is a
 * question about whether anybody wants the thing, which is not a question a
 * model can answer by reading code. This is the machinery for the third
 * answer: keep it, count the people who ask for something it matches, ship it
 * when enough have, forget it if they do not.
 *
 * None of it needs a model, and none of it should. A rule about when to stop
 * asking cannot itself be one of the answers.
 */
public class WaitingTest {
    static int fails = 0;

    static void ok(boolean b, String what) {
        System.out.printf("  %-58s %s%n", what, b ? "ok" : "FAIL");
        if (!b) fails++;
    }

    static Scripts.Script op(Scripts scripts, String name, String pattern, String js) {
        var learned = scripts.learn("""
                #SCRIPT %s :: %s
                #JS
                %s
                #END
                """.formatted(name, pattern, js), "test", true);
        return learned.isEmpty() ? null : learned.get(0);
    }

    public static void main(String[] a) throws Exception {
        Path dir = Files.createTempDirectory("armedit-waiting");
        var scripts = new Scripts();
        var colour = op(scripts, "set-colour", "colours {name:colour}",
                "if (name == \"blue\") { return \"#COLOUR 3\"; } return \"\";");
        long now = 1_700_000_000L;

        // --- a doubted operation is kept, and counted in distinct people
        var w = new Waiting(dir, 3, 86400);
        ok(w.hold(List.of("alice"), colour, "half of us wanted it", now) == Waiting.Outcome.KEPT,
           "a doubted operation is kept, not dropped");
        ok(w.get("set-colour") != null, "...and there is a record to look at");
        ok(w.hold(List.of("alice"), colour, "again", now) == Waiting.Outcome.KEPT,
           "the same person asking again is still one person");
        ok(w.get("set-colour").who().size() == 1, "...so the count stays at one");
        ok(w.hold(List.of("bob"), colour, "again", now) == Waiting.Outcome.COUNTED,
           "a second person counts");
        ok(w.hold(List.of("carol"), colour, "again", now) == Waiting.Outcome.READY,
           "and the third reaches the threshold");

        // --- counting by what somebody asked for, not by who they told
        var w2 = new Waiting(Files.createTempDirectory("armedit-waiting2"), 3, 86400);
        w2.hold(List.of("alice"), colour, "unsettled", now);
        ok(w2.asked("bob", "colours blue", now).isEmpty(),
           "an instruction the pattern matches counts, without shipping yet");
        ok(w2.get("set-colour").who().size() == 2, "...and the record now has two");
        ok(w2.asked("bob", "colours red", now).isEmpty()
           && w2.get("set-colour").who().size() == 2,
           "the same person matching again is still not a second person");
        ok(w2.asked("dave", "something else entirely", now).isEmpty()
           && w2.get("set-colour").who().size() == 2,
           "an instruction it does not match counts towards nothing");
        var ready = w2.asked("carol", "colours green", now);
        ok(ready.size() == 1 && ready.get(0).name().equals("set-colour"),
           "the person who completes the threshold releases it");

        // --- expiry
        var w3 = new Waiting(Files.createTempDirectory("armedit-waiting3"), 3, 100);
        w3.hold(List.of("alice"), colour, "unsettled", now);
        ok(w3.sweep(now + 50).isEmpty(), "a record inside its time is left alone");
        ok(w3.sweep(now + 200).size() == 1, "...and forgotten after it");
        ok(w3.get("set-colour") == null, "...leaving nothing behind");

        // Asking keeps it alive: a thing gaining support should not expire on a
        // date set when nobody had heard of it yet.
        var w4 = new Waiting(Files.createTempDirectory("armedit-waiting4"), 3, 100);
        w4.hold(List.of("alice"), colour, "unsettled", now);
        w4.asked("bob", "colours blue", now + 90);
        ok(w4.sweep(now + 150).isEmpty(),
           "somebody asking pushes the expiry out");

        // --- what is on disk survives a restart, and is readable
        String onDisk = Files.readString(dir.resolve("set-colour.waiting"));
        ok(onDisk.contains("matches    colours {name:colour}"),
           "the record says what it matches, in plain text");
        ok(onDisk.contains("half of us wanted it") || onDisk.contains("again"),
           "...and why it is waiting");
        var reopened = new Waiting(dir, 3, 86400);
        ok(reopened.get("set-colour") != null, "a restart finds the list again");
        ok(reopened.get("set-colour").who().size() == 3, "...with everyone who asked");
        ok(reopened.get("set-colour").source().startsWith("#SCRIPT set-colour ::"),
           "...and the source it needs to compile it again");

        // --- a threshold nobody can reach
        ok(!new Waiting(dir, 3, 86400).reachable(1),
           "one account cannot make three askers");
        ok(!new Waiting(dir, 3, 86400).reachable(2), "nor can two");
        ok(new Waiting(dir, 3, 86400).reachable(3), "three can");

        // --- what the models are told about that
        String cannot = Triage.demand(1, 1, 3, false);
        ok(cannot.contains("Decide"), "a model that cannot defer is told to decide");
        ok(cannot.contains("never to decide"), "...and told what deferring would mean");
        String can = Triage.demand(1, 9, 3, true);
        ok(!can.contains("never to decide") && can.contains("can happen"),
           "a model that can defer is told that instead");

        String ends = Consortium.afterwards(1, 3, false);
        ok(ends.contains("It ends this"), "the panel is told a hold ends it, where it does");
        String keeps = Consortium.afterwards(9, 3, true);
        ok(keeps.contains("some members vote against keeps it"),
           "...and told how to say \"wait and see\" where it can");

        // --- a split hold is doubt; an agreed one is a refusal
        var yes = new Consortium.Vote("m1", true, "worth having", List.of(), null);
        var no = new Consortium.Vote("m2", false, "too narrow", List.of(), null);
        var died = new Consortium.Vote("m3", false, null, List.of(), "timed out");
        ok(new Consortium.Verdict(false, "", List.of(no, no), List.of()).divided() == false,
           "everybody holding is a refusal, and ends it");
        ok(new Consortium.Verdict(false, "", List.of(yes, no), List.of()).divided(),
           "a split is doubt, and is kept");
        ok(new Consortium.Verdict(false, "", List.of(died, died), List.of()).divided(),
           "nobody reachable is unsettled, not refused");

        // --- reading the first pass
        ok(Triage.read("VERDICT: NO\nWHY: it is one person's sentence\n").rejected(),
           "a NO with a reason ends it");
        ok(Triage.read("VERDICT: YES\nWHY: the next person would want it\n").say()
                   == Triage.Say.YES,
           "a YES with a reason convenes the panel");
        ok(Triage.read("VERDICT: YES\n").unsure(),
           "a verdict with no reason is not a verdict");
        ok(Triage.read("Looks fine to me").unsure(), "nor is prose");
        ok(Triage.read(null).unsure(), "nor is silence");
        ok(Triage.read("verdict: unsure\nwhy: could go either way\n").unsure(),
           "and lower case is the same verdict");

        // --- the people who settled a question are carried, not just counted
        var consensus = new Consensus();
        var settled = consensus.record("alice", "screen", "reboot", "#REBOOT");
        ok(settled != null, "one person is enough to settle a question");
        ok(settled.who().contains("alice"),
           "...and the record says who, so the waiting list starts with them");
        ok(settled.people() == settled.who().size(),
           "...with the count and the names agreeing");

        System.exit(fails == 0 ? 0 : 1);
    }
}
