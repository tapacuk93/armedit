import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * What happened, not just what is there.
 *
 * A screen's text says where the user ended up. The journal says how: every
 * insertion, every deletion, every tap on a word and every swipe. Two reasons
 * to keep it, and both matter more than they sound:
 *
 *   - Deletions are edits. A screen that no longer mentions something was
 *     changed by someone deciding it should not be mentioned, and that
 *     decision is invisible in the final text. Keeping removals means the
 *     history is honest rather than merely current.
 *
 *   - The model gets to see it. "The user just deleted the retry block and
 *     tapped on `timeout`" is a different question from the same screen with
 *     no history, and produces a different answer.
 *
 * Append-only, one line per event, rotated at the same megabyte as the text.
 * Written off the request thread like everything else here.
 */
final class Journal {

    private static final long ROTATE_BYTES = 1L << 20;
    private static final int KEEP = 8;

    /** How many recent events the model is shown. Enough for "just now". */
    private static final int SUMMARY_EVENTS = 40;

    private final Path root;
    private final ExecutorService writer;

    /** The tail of each screen's history, so a summary needs no disk read. */
    private final java.util.Map<String, Deque<String>> recent = new java.util.concurrent.ConcurrentHashMap<>();

    Journal(Path root) {
        this.root = root;
        this.writer = Executors.newSingleThreadExecutor(r -> {
            var t = new Thread(r, "asmedit-journal");
            t.setDaemon(true);
            return t;
        });
    }

    /** An edit, including what was removed. */
    record Edit(long at, String op, int offset, String text) {
        String line() {
            return Json.obj("t", at, "op", op, "at", offset, "text", text);
        }

        String human() {
            return switch (op) {
                case "del" -> "deleted %s at %d".formatted(quote(text), offset);
                case "ins" -> "typed %s at %d".formatted(quote(text), offset);
                default -> "%s at %d".formatted(op, offset);
            };
        }
    }

    /** A gesture: a tap that landed on a word, a swipe, a scroll. */
    record Gesture(long at, String kind, int offset, String word, int dx, int dy) {
        String line() {
            return Json.obj("t", at, "kind", kind, "at", offset, "word", word, "dx", dx, "dy", dy);
        }

        String human() {
            return switch (kind) {
                case "tap", "click" -> word == null || word.isBlank()
                        ? "%s at offset %d".formatted(kind, offset)
                        : "%s on %s".formatted(kind, quote(word));
                case "swipe" -> "swiped %s".formatted(direction(dx, dy));
                case "scroll" -> "scrolled %s".formatted(direction(dx, dy));
                default -> kind;
            };
        }

        private static String direction(int dx, int dy) {
            if (Math.abs(dx) >= Math.abs(dy)) return dx < 0 ? "left" : "right";
            return dy < 0 ? "up" : "down";
        }
    }

    void edits(Accounts.Account a, int screen, List<Edit> events) {
        if (events.isEmpty()) return;
        append(a, screen, "edits.jsonl", events.stream().map(Edit::line).toList(),
                events.stream().map(Edit::human).toList());
    }

    void gestures(Accounts.Account a, int screen, List<Gesture> events) {
        if (events.isEmpty()) return;
        append(a, screen, "gestures.jsonl", events.stream().map(Gesture::line).toList(),
                events.stream().map(Gesture::human).toList());
    }

    private void append(Accounts.Account a, int screen, String name,
                        List<String> lines, List<String> human) {
        var key = a.id() + "/" + screen;
        var tail = recent.computeIfAbsent(key, k -> new ArrayDeque<>());
        synchronized (tail) {
            human.forEach(tail::addLast);
            while (tail.size() > SUMMARY_EVENTS) tail.removeFirst();
        }
        writer.execute(() -> {
            try {
                var dir = root.resolve(a.id()).resolve("screen-" + Math.max(1, screen));
                Files.createDirectories(dir);
                var file = dir.resolve(name);
                var body = String.join("\n", lines) + "\n";
                rotateIfNeeded(file, body.length());
                Files.writeString(file, body, StandardCharsets.UTF_8,
                        StandardOpenOption.CREATE, StandardOpenOption.APPEND);
            } catch (Exception x) {
                System.out.printf("asmedit: journal write failed for %s: %s%n", key, x.getMessage());
            }
        });
    }

    private void rotateIfNeeded(Path file, int incoming) throws Exception {
        if (!Files.exists(file)) return;
        if (Files.size(file) + incoming <= ROTATE_BYTES) return;
        var dir = file.getParent();
        var base = file.getFileName().toString();
        for (int i = KEEP - 1; i >= 1; i--) {
            var from = dir.resolve("%s.%d".formatted(base, i));
            var to = dir.resolve("%s.%d".formatted(base, i + 1));
            if (Files.exists(from)) Files.move(from, to, StandardCopyOption.REPLACE_EXISTING);
        }
        Files.move(file, dir.resolve(base + ".1"), StandardCopyOption.REPLACE_EXISTING);
    }

    /**
     * The recent history, as prose for the prompt. Empty when there is nothing
     * to say - an empty section in a prompt is worse than no section.
     */
    String briefing(Accounts.Account a, int screen) {
        var tail = recent.get(a.id() + "/" + screen);
        if (tail == null) return "";
        List<String> lines;
        synchronized (tail) {
            if (tail.isEmpty()) return "";
            lines = new ArrayList<>(tail);
        }
        var b = new StringBuilder("WHAT THE USER JUST DID, oldest first:\n");
        for (var l : lines) b.append("  - ").append(l).append('\n');
        return b.append('\n').toString();
    }

    private static String quote(String s) {
        if (s == null) return "nothing";
        var one = s.replace("\n", "\\n");
        return one.length() <= 60 ? "\"%s\"".formatted(one)
                                  : "\"%s...\" (%d chars)".formatted(one.substring(0, 60), s.length());
    }

    void close() { writer.shutdown(); }
}
