import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Operations the consortium was not sure about, kept instead of thrown away.
 *
 * There are three answers a review can give and the code used to have two. An
 * operation that is wrong should be dropped, an operation that is right should
 * ship, and an operation that reviewers cannot agree about is neither - it is a
 * question about whether anybody wants it, which is not a question a model can
 * answer by reading code. Dropping those was losing the only ones where more
 * information exists and is merely somewhere else.
 *
 * So a doubtful verdict lands here. The record says what the operation was and
 * why the doubt, and it carries a count of how many distinct people have since
 * asked for something its pattern matches. Reach the threshold and it ships.
 * Reach the expiry first and it is forgotten, which is the ordinary outcome and
 * is not a failure: most things nobody asks for twice were correctly doubted.
 *
 * <h2>The source is the record</h2>
 *
 * What is stored is the operation's source, not its machine code. The binary is
 * re-derived from it when the time comes, by the same compiler that would have
 * produced it the first time. That way the file is something a person can read
 * and disagree with, and there is no way for the record to hold bytes whose
 * source has been lost - which is the state this whole project exists to avoid.
 *
 * <h2>Waiting for a threshold nobody can reach</h2>
 *
 * A deployment with two registered accounts cannot produce three distinct
 * people asking for anything. Parking a decision there is not caution, it is a
 * decision to never decide, dressed as one - so the caller is expected to ask
 * {@link #reachable} first and to decide now when the answer is no. The models
 * are told the same thing, because a reviewer that knows an unsure answer means
 * "park it forever" should be told so before it gives one.
 */
final class Waiting {

    /** One doubted operation, and who has asked for it since. */
    record Record(String name, String pattern, String js, String why,
                  Set<String> who, long first, long expires) {

        boolean expired(long now) { return now >= expires; }

        /** The source, in the form the learner reads - see the class note. */
        String source() {
            return "#SCRIPT %s :: %s\n#JS\n%s\n#END\n".formatted(name, pattern, js);
        }
    }

    /** What happened to a request to hold something, or to count towards one. */
    enum Outcome { KEPT, COUNTED, READY }

    private final Path dir;
    private final int threshold;
    private final long ttl;                 // seconds
    private final Map<String, Record> held = new LinkedHashMap<>();

    Waiting(Path dir, int threshold, long ttlSeconds) {
        this.dir = dir;
        this.threshold = Math.max(2, threshold);
        this.ttl = ttlSeconds;
        load();
    }

    int threshold() { return threshold; }

    /**
     * Is there any point waiting?
     *
     * With fewer registered accounts than the threshold, no amount of patience
     * produces enough distinct people. Callers ask this before deferring, and
     * decide instead when it is false.
     */
    boolean reachable(int registeredAccounts) {
        return registeredAccounts >= threshold;
    }

    synchronized List<Record> all() { return List.copyOf(held.values()); }

    synchronized Record get(String name) { return held.get(Distro.safeName(name)); }

    /**
     * Park a doubted operation, or count the person who asked for it again.
     *
     * The first caller creates the record and is its first asker. Callers after
     * that add themselves, and the expiry moves out - a thing being asked for
     * is a thing still live, and expiring it on a fixed date from the first
     * request would drop it exactly as it was gaining support.
     */
    synchronized Outcome hold(java.util.Collection<String> accounts, Scripts.Script op,
                              String why, long now) {
        String name = Distro.safeName(op.name());
        var was = held.get(name);
        var who = new LinkedHashSet<String>();
        long first = now;
        if (was != null && !was.expired(now)) {
            who.addAll(was.who());
            first = was.first();
        }
        int before = who.size();
        for (String a : accounts) if (a != null && !a.isBlank()) who.add(a);
        boolean fresh = who.size() > before;
        var rec = new Record(name, op.pattern(), op.js() == null ? "" : op.js(),
                why == null ? "" : why.replace('\n', ' ').strip(),
                who, first, now + ttl);
        held.put(name, rec);
        write(rec);
        if (who.size() >= threshold) return Outcome.READY;
        return was == null ? Outcome.KEPT : (fresh ? Outcome.COUNTED : Outcome.KEPT);
    }

    /**
     * Somebody asked for something. Count them against anything waiting.
     *
     * Matching is the operation's own pattern against the instruction, the same
     * binding the server uses to answer with a script - so "counted towards it"
     * means exactly "this operation would have answered you", and not a
     * similarity judgement that could quietly count the wrong thing.
     *
     * Returns the records that just reached the threshold.
     */
    synchronized List<Record> asked(String account, String instruction, long now) {
        var ready = new ArrayList<Record>();
        if (account == null || instruction == null || instruction.isBlank()) return ready;
        for (var name : List.copyOf(held.keySet())) {
            var rec = held.get(name);
            if (rec.expired(now)) continue;
            List<Scripts.Token> tokens;
            try {
                tokens = Scripts.compile(rec.pattern());
            } catch (RuntimeException x) {
                continue;
            }
            if (Scripts.bind(tokens, instruction) == null) continue;
            if (!rec.who().contains(account)) {
                var who = new LinkedHashSet<>(rec.who());
                who.add(account);
                var next = new Record(rec.name(), rec.pattern(), rec.js(), rec.why(),
                        who, rec.first(), now + ttl);
                held.put(name, next);
                write(next);
                if (who.size() >= threshold) ready.add(next);
            }
        }
        return ready;
    }

    /** Forget what nobody asked for in time. Returns what went. */
    synchronized List<String> sweep(long now) {
        var gone = new ArrayList<String>();
        for (var name : List.copyOf(held.keySet())) {
            if (held.get(name).expired(now)) {
                held.remove(name);
                try {
                    Files.deleteIfExists(file(name));
                } catch (IOException ignored) {
                }
                gone.add(name);
            }
        }
        return gone;
    }

    /** Take it off the list, because it shipped or because it will not. */
    synchronized void drop(String name) {
        String safe = Distro.safeName(name);
        held.remove(safe);
        try {
            Files.deleteIfExists(file(safe));
        } catch (IOException ignored) {
        }
    }

    String asJson() {
        var b = new StringBuilder("{\"waiting\":").append(held.size())
                .append(",\"threshold\":").append(threshold).append('}');
        return b.toString();
    }

    // ------------------------------------------------------------ on disk

    private Path file(String name) { return dir.resolve(name + ".waiting"); }

    /**
     * One file per record, in the shape ops/*.op already uses.
     *
     * Readable on purpose. Somebody looking at a server should be able to see
     * what it is holding back and why without a tool, and should be able to
     * delete one with rm.
     */
    private void write(Record rec) {
        try {
            Files.createDirectories(dir);
            var b = new StringBuilder();
            b.append("name       ").append(rec.name()).append('\n');
            b.append("matches    ").append(rec.pattern()).append('\n');
            b.append("doubt      ").append(rec.why()).append('\n');
            b.append("first      ").append(rec.first()).append('\n');
            b.append("expires    ").append(rec.expires()).append('\n');
            b.append("asked by   ").append(String.join(" ", rec.who())).append('\n');
            b.append("\nsource\n");
            for (String line : rec.js().split("\n", -1)) b.append("    ").append(line).append('\n');
            var tmp = dir.resolve(rec.name() + ".waiting.tmp");
            Files.writeString(tmp, b.toString(), StandardCharsets.UTF_8);
            Files.move(tmp, file(rec.name()),
                    java.nio.file.StandardCopyOption.REPLACE_EXISTING,
                    java.nio.file.StandardCopyOption.ATOMIC_MOVE);
        } catch (IOException x) {
            System.out.printf("armedit: could not write the waiting record for %s: %s%n",
                    rec.name(), x);
        }
    }

    private void load() {
        if (!Files.isDirectory(dir)) return;
        try (var list = Files.list(dir)) {
            for (var p : list.filter(f -> f.getFileName().toString().endsWith(".waiting")).toList()) {
                var rec = read(p);
                if (rec != null) held.put(rec.name(), rec);
            }
        } catch (IOException x) {
            System.out.printf("armedit: could not read the waiting list: %s%n", x);
        }
    }

    static Record read(Path p) {
        try {
            return parse(Files.readString(p, StandardCharsets.UTF_8));
        } catch (Exception x) {
            return null;
        }
    }

    /**
     * Read one back.
     *
     * Fields first, then a blank line, then "source" and the body indented by
     * four. Anything missing makes the record null rather than a half-record:
     * a waiting entry with no pattern would match nothing and never expire, and
     * a file nobody can parse is better ignored than guessed at.
     */
    static Record parse(String text) {
        String name = null, pattern = null, why = "";
        long first = 0, expires = 0;
        var who = new LinkedHashSet<String>();
        var js = new StringBuilder();
        boolean inSource = false;
        for (String line : text.split("\n", -1)) {
            if (inSource) {
                if (js.length() > 0) js.append('\n');
                js.append(line.startsWith("    ") ? line.substring(4) : line);
                continue;
            }
            if (line.strip().equals("source")) { inSource = true; continue; }
            int at = line.indexOf(' ');
            if (at < 0) continue;
            String key = line.substring(0, at), value = line.substring(at).strip();
            switch (key) {
                case "name" -> name = value;
                case "matches" -> pattern = value;
                case "doubt" -> why = value;
                case "first" -> first = Long.parseLong(value);
                case "expires" -> expires = Long.parseLong(value);
                case "asked" -> {
                    // "asked by   a b c"
                    String rest = value.startsWith("by") ? value.substring(2).strip() : value;
                    for (String s : rest.split("\\s+")) if (!s.isBlank()) who.add(s);
                }
                default -> { }
            }
        }
        if (name == null || pattern == null || expires == 0) return null;
        String body = js.toString();
        while (body.endsWith("\n")) body = body.substring(0, body.length() - 1);
        return new Record(name, pattern, body, why, who, first, expires);
    }
}
