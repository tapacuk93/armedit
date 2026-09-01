import java.util.List;

/**
 * "colours blue" goes the whole way: recognised, scripted, compiled.
 *
 * The point of this test is not that a colour name maps to a number - it is
 * that an appearance change survives every stage of the pipeline that answers
 * cannot normally be assumed to survive. A directive that works from the model
 * and then vanishes once the answer is scripted is worse than one that never
 * worked, because it fails only after somebody has come to rely on it.
 */
public class ColourTest {
    static int fails = 0;
    static void ok(boolean b, String what) {
        System.out.printf("  %-58s %s%n", what, b ? "ok" : "FAIL");
        if (!b) fails++;
    }

    public static void main(String[] a) throws Exception {
        // --- recognised, in the shapes a model actually writes.
        // A slot, not a name: the mapping from "blue" to 3 is the model's to
        // make, and there is no table here that could disagree with it.
        ok(Armeditd.colourIn("#COLOUR 3") == 3, "\"#COLOUR 3\" is palette slot 3");
        ok(Armeditd.colourIn("#COLOR 3") == 3, "the American spelling too");
        ok(Armeditd.colourIn("#colour 4") == 4, "case does not matter");
        ok(Armeditd.colourIn("#COLOUR 0") == 0, "slot zero is a slot, not an absence");
        ok(Armeditd.colourIn("#COLOUR 9") == 9, "and nine is the last one");

        // --- and not recognised when it should not be
        ok(Armeditd.colourIn("#COLOUR blue") == -1, "a name is not a slot");
        ok(Armeditd.colourIn("the sky is blue") == -1, "prose about blue is not a directive");
        ok(Armeditd.colourIn("") == -1, "nothing asks for nothing");
        ok(Armeditd.colourIn(null) == -1, "and neither does null");

        // --- the directive never reaches the document
        ok(Armeditd.withoutDirectives("#COLOUR 3").isEmpty(),
           "the directive is stripped from what the user sees");
        ok(Armeditd.withoutDirectives("keep me\n#COLOUR 3\n").equals("keep me"),
           "...leaving anything that was really text");

        // --- scripted: the model teaches it, the server answers without a model
        var scripts = new Scripts();
        String taught = """
                #COLOUR blue
                #SCRIPT set-colour :: colours {name:colour}
                #JS
                if (name == "blue") { return "#COLOUR 3"; }
                if (name == "red") { return "#COLOUR 4"; }
                if (name == "green") { return "#COLOUR 0"; }
                return "";
                #END
                """;
        ok(scripts.learn(taught, "sonnet", true).size() == 1, "the operation is learned");
        var hit = scripts.lookup(new Scripts.Ctx("aify", "colours red", "", "", ""));
        ok(hit != null, "a later \"colours red\" is answered without a model");
        ok(hit != null && Armeditd.colourIn(hit.text()) == 4,
           "...and the colour survives the scripted path");
        ok(hit != null && Armeditd.withoutDirectives(hit.text()).isEmpty(),
           "...with nothing left over to land on screen");
        ok(scripts.lookup(new Scripts.Ctx("aify", "colours chartreuse", "", "", "")) == null,
           "a colour it does not know declines, so the model still gets asked");

        // --- the screen is handed to every operation, named or not.
        // An operation that only matched two words can still rewrite the
        // document, which is the difference between answering a sentence and
        // answering a request.
        String seesScreen = """
                #SCRIPT shout :: shout it
                #JS
                return screen + "!";
                #END
                """;
        ok(scripts.learn(seesScreen, "sonnet", true).size() == 1,
           "an operation that never named the screen is still learned");
        var loud = scripts.lookup(new Scripts.Ctx("aify", "shout it", "hello", "", ""));
        ok(loud != null && loud.text().equals("hello!"),
           "...and it was handed the whole screen anyway");
        ok(scripts.byName("shout").arguments().equals(
                   List.of("screen", "subject", "selection")),
           "...at a fixed place in the argument list");
        ok(scripts.byName("set-colour").arguments().equals(
                   List.of("name", "screen", "subject", "selection")),
           "...after whatever variables it named itself");
        ok(scripts.learn("""
                #SCRIPT clash :: rename {screen}
                #JS
                return "no";
                #END
                """, "sonnet", true).isEmpty(),
           "a variable that collides with an ambient one is refused");

        // --- compiled: the same operation as machine code the device runs
        var op = scripts.byName("set-colour");
        ok(op != null && op.blob() != null, "the operation compiled to aarch64");
        // #JAVA compiles to JVM bytecode and runs here; #JS compiles to both,
        // and only #JS can be handed to a device. Worth stating, since the
        // difference is invisible until you ask for the blob.
        if (op != null && op.blob() != null) {
            System.out.printf("  %-58s %d bytes%n", "...which is this big:", op.blob().code().length);
            java.nio.file.Files.write(java.nio.file.Path.of(a[0]), op.blob().code());
        }
        var shout = scripts.byName("shout");
        ok(shout != null && shout.blob() != null, "so did the one that reads the screen");
        if (shout != null && shout.blob() != null && a.length > 1) {
            java.nio.file.Files.write(java.nio.file.Path.of(a[1]), shout.blob().code());
        }
        System.exit(fails == 0 ? 0 : 1);
    }
}
