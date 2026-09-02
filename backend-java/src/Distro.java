import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import java.util.concurrent.TimeUnit;

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
 * <h2>Committing, and why that changed</h2>
 *
 * This used to stop at writing files, on the argument that a daemon which
 * commits on its own can rewrite history while nobody is looking. That
 * argument was about an unsupervised daemon. It is now the development cycle
 * itself: somebody writes a feature, it compiles to machine code, several
 * models across two vendors separately agree it should exist, and the point is
 * that it is then *in the project* rather than in a directory waiting for
 * somebody to notice.
 *
 * The safety moved rather than disappeared. Only the operation's own three
 * files are staged - never `git add -A`, which would sweep up whatever
 * somebody happened to be editing at the time. Nothing is committed if those
 * paths are unchanged. And the consortium remains the gate: a push happens
 * because several models agreed, not because a compiler succeeded.
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
    List<Path> commit(Scripts.Script op, Consortium.Verdict verdict, String observed,
                      int people) throws java.io.IOException {
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
        /*
         * How much demand was behind it, kept with the votes rather than only
         * in the prompt that is thrown away. An operation approved on one
         * person's request and one approved on several people's agreement are
         * different things a year later, and the file should say which it was.
         */
        b.append("asked by ").append(people)
         .append(people == 1 ? " person" : " people").append('\n');
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

    /**
     * Commit the operation and push it, so writing a feature ends with the
     * feature being in the project.
     *
     * @return what happened, for the log and for the person who asked
     */
    String publish(java.util.List<Path> written, Scripts.Script op,
                   Consortium.Verdict verdict) {
        Path root = dir.toAbsolutePath().getParent();
        if (root == null || !java.nio.file.Files.isDirectory(root.resolve(".git"))) {
            return "not a git repository, so it stays in the working tree";
        }
        try {
            var paths = new java.util.ArrayList<String>();
            for (var w : written) paths.add(root.relativize(w.toAbsolutePath()).toString());

            // Only these files. Staging everything would commit whatever
            // somebody was in the middle of writing, which is the difference
            // between a development cycle and a hazard.
            var add = new java.util.ArrayList<String>(java.util.List.of("git", "add", "--"));
            add.addAll(paths);
            String bad = run(root, add);
            if (bad != null) return "could not stage: " + bad;

            var staged = new java.util.ArrayList<String>(
                    java.util.List.of("git", "diff", "--cached", "--quiet", "--"));
            staged.addAll(paths);
            if (run(root, staged) == null) {
                return "nothing changed - this operation was already in the project";
            }

            String message = """
                    %s: an operation the consortium agreed to ship

                    %s

                    Matches "%s", takes %s, and compiles to %d bytes of aarch64.
                    %s

                    Written by %s, agreed by %d of %d members. Their reasoning is
                    in %s alongside the code, because a decision without it is
                    not reviewable later.
                    """.formatted(op.name(),
                            op.js() == null ? "" : op.js().strip().lines().findFirst().orElse(""),
                            op.pattern(), String.join(", ", op.arguments()),
                            op.blob().code().length, verdict.why(),
                            op.author(), verdict.voters(), verdict.votes().size(),
                            paths.get(paths.size() - 1));

            var commit = new java.util.ArrayList<>(java.util.List.of(
                    "git", "commit", "-m", message, "--"));
            commit.addAll(paths);
            bad = run(root, commit);
            if (bad != null) return "could not commit: " + bad;

            String branch = capture(root, java.util.List.of(
                    "git", "rev-parse", "--abbrev-ref", "HEAD"));
            branch = branch == null ? "HEAD" : branch.strip();
            bad = run(root, java.util.List.of("git", "push", "origin", branch));
            if (bad != null) return "committed to " + branch + " but not pushed: " + bad;
            return "pushed to " + branch;
        } catch (Exception x) {
            return "not published: " + x;
        }
    }

    /** Run a command in the repository. Returns null on success, else why not. */
    private static String run(Path in, java.util.List<String> argv) throws Exception {
        var p = new ProcessBuilder(argv).directory(in.toFile())
                .redirectErrorStream(true).start();
        var out = new String(p.getInputStream().readAllBytes(),
                java.nio.charset.StandardCharsets.UTF_8);
        if (!p.waitFor(120, TimeUnit.SECONDS)) {
            p.destroyForcibly();
            return "timed out";
        }
        return p.exitValue() == 0 ? null : out.strip();
    }

    private static String capture(Path in, java.util.List<String> argv) throws Exception {
        var p = new ProcessBuilder(argv).directory(in.toFile()).start();
        var out = new String(p.getInputStream().readAllBytes(),
                java.nio.charset.StandardCharsets.UTF_8);
        p.waitFor(30, TimeUnit.SECONDS);
        return p.exitValue() == 0 ? out : null;
    }

    private static String indent(String s) {
        if (s == null || s.isBlank()) return "    (none)";
        var b = new StringBuilder();
        for (String line : s.strip().split("\n")) b.append("    ").append(line).append('\n');
        return b.toString().stripTrailing();
    }
}
