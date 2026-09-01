import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

/**
 * Where an operation goes once the consortium has agreed to ship it.
 *
 * The editor can already download an operation from a running backend. This is
 * the other path: the blob is written into the source tree, so it is in the
 * release, so a machine with no network still has it. That is what makes the
 * system evolutionary rather than merely online - what enough people needed
 * often enough, and enough models agreed was right, becomes part of what the
 * editor is.
 *
 * <h2>What gets written</h2>
 *
 * Three files per operation, all under {@code ops/}:
 *
 * <ul>
 *   <li>{@code <name>.bin} - the machine code, exactly as the device runs it.
 *   <li>{@code <name>.op} - what it matches and what arguments it takes, so
 *       the blob is not an anonymous lump of bytes.
 *   <li>{@code <name>.votes} - who agreed, and what they said.
 * </ul>
 *
 * The votes are written because a decision without its reasoning is not
 * reviewable later. Somebody reading this repository in a year should be able
 * to see that six models were asked, what each objected to, and what was
 * changed - without that, "the consortium approved it" is a claim about a
 * conversation nobody kept.
 *
 * <h2>What this does not do</h2>
 *
 * It does not run git. A daemon that commits to a repository on its own is a
 * daemon that can rewrite history while nobody is looking, and the value here
 * is in the files being reviewable, not in them being committed unattended.
 * The files land in the working tree; a person - or a build - commits them.
 */
final class Distro {

    private final Path dir;

    Distro(String directory) {
        this.dir = Path.of(directory);
    }

    Path directory() { return dir; }

    /** Is this even configured? Without a tree to write into, there is nothing to do. */
    boolean available() {
        return Files.isDirectory(dir.getParent() == null ? Path.of(".") : dir.getParent());
    }

    /**
     * Write an approved operation into the tree.
     *
     * @return the files written, for the log
     */
    List<Path> commit(Scripts.Script op, Consortium.Verdict verdict, String observed)
            throws java.io.IOException {
        Files.createDirectories(dir);
        String safe = safeName(op.name());
        Path bin = dir.resolve(safe + ".bin");
        Path meta = dir.resolve(safe + ".op");
        Path votes = dir.resolve(safe + ".votes");

        Files.write(bin, op.blob().code());
        Files.writeString(meta, """
                name       %s
                matches    %s
                arguments  %s
                bytes      %d
                sha        %s
                author     %s

                source
                %s

                observed
                %s
                """.formatted(op.name(), op.pattern(),
                        String.join(", ", op.arguments()),
                        op.blob().code().length, op.blob().sha(), op.author(),
                        indent(op.js() == null ? "(template only)" : op.js()),
                        indent(observed)),
                StandardCharsets.UTF_8);

        var b = new StringBuilder();
        b.append("verdict  ").append(verdict.commit() ? "COMMIT" : "HOLD").append('\n');
        b.append("because  ").append(verdict.why()).append("\n\n");
        for (var v : verdict.votes()) {
            b.append(v.member()).append("  ");
            if (v.error() != null) {
                b.append("did not vote: ").append(v.error()).append('\n');
                continue;
            }
            b.append(v.commit() ? "COMMIT" : "HOLD").append('\n');
            b.append("    ").append(v.why()).append('\n');
            for (var c : v.changes()) b.append("    would change: ").append(c).append('\n');
        }
        Files.writeString(votes, b.toString(), StandardCharsets.UTF_8);
        return List.of(bin, meta, votes);
    }

    /**
     * An operation names itself, and the name becomes a path.
     *
     * Names come from a model, which means they are attacker-adjacent even
     * when nobody is attacking: "../../etc/thing" is a perfectly plausible
     * thing for a confused model to emit, and it must land in ops/ or nowhere.
     */
    static String safeName(String name) {
        String s = name == null ? "" : name.trim().toLowerCase(java.util.Locale.ROOT);
        s = s.replaceAll("[^a-z0-9._-]", "-").replaceAll("^[.-]+", "");
        if (s.length() > 60) s = s.substring(0, 60);
        return s.isEmpty() ? "unnamed" : s;
    }

    private static String indent(String s) {
        if (s == null || s.isBlank()) return "    (none)";
        var b = new StringBuilder();
        for (String line : s.strip().split("\n")) b.append("    ").append(line).append('\n');
        return b.toString().stripTrailing();
    }
}
