import java.util.List;

/**
 * The consortium's own judgement, tested without asking anybody.
 *
 * Everything here is the part that decides what a sitting *means*: who gets a
 * seat, what counts as a vote, when a commit is refused. None of it needs a
 * model, and none of it should - a rule about when to trust several opinions
 * cannot itself be one of the opinions.
 *
 * What is deliberately not tested here is whether the models are any good.
 * That is not a property this repository can assert, and a test that stubbed
 * it would be asserting the stub.
 */
public class ConsortiumTest {
    static int fails = 0;
    static void ok(boolean b, String what) {
        System.out.printf("  %-58s %s%n", what, b ? "ok" : "FAIL");
        if (!b) fails++;
    }

    public static void main(String[] a) {
        // --- reading a member's answer
        var yes = Consortium.read("m", "VERDICT: COMMIT\nWHY: it does what it says\n");
        ok(yes.commit() && yes.counted(), "a COMMIT with a reason is a vote");

        var no = Consortium.read("m", "VERDICT: HOLD\nWHY: it declines everything\n");
        ok(!no.commit() && no.counted(), "so is a HOLD with a reason");

        ok(!Consortium.read("m", "VERDICT: COMMIT\n").counted(),
           "a verdict with no reason is not counted");
        ok(!Consortium.read("m", "Looks good to me!").counted(),
           "and neither is prose with no verdict");
        ok(!Consortium.read("m", null).counted(), "nor is silence");

        var changes = Consortium.read("m",
                "VERDICT: COMMIT\nWHY: fine\nCHANGE: rename it\nCHANGE: none\nCHANGE: n/a\n");
        ok(changes.changes().size() == 1, "\"none\" is not a change somebody asked for");
        ok(changes.changes().get(0).contains("rename it"), "...but a real one survives");

        // Case and spacing vary between models; the meaning does not.
        ok(Consortium.read("m", "verdict: commit\nwhy: sure\n").commit(),
           "lower case is the same verdict");
        ok(Consortium.read("m", "  VERDICT:   HOLD  \n  WHY:  no  \n").counted(),
           "and so is a sloppily indented one");

        // --- families, so six seats are not one model six times
        ok(Consortium.family("claude-opus-4-5-20251101").equals("claude-opus"),
           "a dated model is its family");
        ok(Consortium.family("claude-opus-5").equals("claude-opus"),
           "...and so is the undated one");
        ok(Consortium.family("gpt-4o").equals("gpt-4o"),
           "\"4o\" is a name, not a version");
        ok(!Consortium.family("claude-opus-5").equals(Consortium.family("claude-sonnet-5")),
           "opus and sonnet are different families");

        // --- names become paths, and models choose names
        ok(Distro.safeName("set-colour").equals("set-colour"), "an ordinary name is left alone");
        ok(!Distro.safeName("../../etc/passwd").contains(".."),
           "a name cannot climb out of ops/");
        ok(!Distro.safeName("/etc/passwd").startsWith("/"), "nor start at the root");
        ok(Distro.safeName("").equals("unnamed"), "and an empty name still lands somewhere");
        ok(Distro.safeName("A Name With Spaces").matches("[a-z0-9._-]+"),
           "everything else is reduced to what a filename may hold");

        // --- the machine code is shown, not just hashed
        byte[] code = {0x40, 0x0B, (byte) 0x80, 0x52, (byte) 0xC0, 0x03, 0x5F, (byte) 0xD6};
        String shown = Consortium.words(code);
        ok(shown.contains("52800b40"), "the first instruction is legible");
        ok(shown.contains("d65f03c0"), "and so is the last");
        ok(Consortium.words(new byte[]{1, 2, 3}).contains("trailing"),
           "a length that is not whole instructions says so");

        // --- probes: what a reviewer is shown about a closed kind
        var scripts = new Scripts();
        scripts.learn("""
                #SCRIPT c :: colours {name:colour}
                #JS
                if (name == "blue") { return "#COLOUR 3"; }
                return "";
                #END
                """, "test", true);
        var op = scripts.byName("c");
        var probes = Scripts.probes(op);
        var sentences = probes.stream().map(Scripts.Probe::sentence).toList();
        ok(sentences.contains("colours blue"),
           "every colour is exercised, including the one it handles");
        ok(sentences.contains("colours chartreuse"),
           "...and one it must decline");
        ok(Scripts.probes(op).stream().map(Scripts.Probe::sentence).toList().equals(sentences),
           "twice in a row gives the same list, so two reviews are comparable");
        ok(probes.get(0).values().size() == op.arguments().size(),
           "a probe binds every argument the operation takes");

        // --- reading a provider's reply, which is where members go missing.
        // Every shape below is one this actually received from the proxy: each
        // arrived once as "no reply text in {...}" and cost a seat at a sitting.
        ok(Aicoin.extract("{\"content\":[{\"type\":\"text\",\"text\":\"VERDICT: COMMIT\"}]}")
                   .equals("VERDICT: COMMIT"),
           "an ordinary Anthropic reply reads out");
        ok(Aicoin.extract("{\"content\":[{\"type\":\"thinking\",\"thinking\":\"hmm\"},"
                        + "{\"type\":\"text\",\"text\":\"VERDICT: HOLD\"}]}")
                   .equals("VERDICT: HOLD"),
           "...past a thinking block that comes first");
        ok(Aicoin.extract("{\"content\":[{\"type\":\"text\",\"text\":\"a \\\"quoted\\\" word\"}]}")
                   .equals("a \"quoted\" word"),
           "...with its escapes undone");
        ok(threw(() -> Aicoin.extract(
                   "{\"content\":[],\"stop_reason\":\"refusal\"}")).contains("declined"),
           "a refusal says it was refused, not that nothing came back");
        ok(threw(() -> Aicoin.extract(
                   "{\"content\":[{\"type\":\"thinking\",\"thinking\":\"\"}],"
                 + "\"stop_reason\":\"max_tokens\"}")).contains("output room"),
           "and a model that ran out of room says that instead");

        System.exit(fails == 0 ? 0 : 1);
    }

    /** What a call threw, as text - for the cases where failing is the answer. */
    static String threw(Runnable r) {
        try {
            r.run();
            return "";
        } catch (Exception x) {
            return String.valueOf(x.getMessage());
        }
    }
}
