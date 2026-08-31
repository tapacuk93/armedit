import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;
import java.util.regex.Pattern;

/**
 * Asking for a thing somebody has already made.
 *
 * "tetris game" is not a question about you. Whoever asked for it first paid
 * for it, and the answer is the same for everyone, so the second person should
 * get it back immediately and for nothing.
 *
 * What is private is marked, not guessed. Text prefixed with $$ is a
 * reference the model never reads; everything else the user has declared
 * ordinary by not marking it. So the rule is:
 *
 *     an exchange is shareable when nothing in it is marked private.
 *
 * A marker beats a heuristic here, and it is worth saying why. Guessing at
 * privacy fails in both directions: it refuses "tetris game" because it
 * contains the word "my", and it shares something sensitive that happened to
 * be phrased plainly. Neither failure is visible to the person it happens to.
 * A marker is a decision the user made and can see.
 *
 * The key covers everything that shaped the answer, not just the instruction,
 * so a hit means somebody asked the identical thing - never merely a similar
 * one. Guessing that two differently worded asks want the same answer is how
 * a cache starts handing people things they did not ask for.
 */
final class Cache {

    /** The mark that makes something private. */
    static final Pattern MARKED = Pattern.compile("\\$\\$\\w+");

    /** One answer somebody already paid for. */
    record Entry(String text, String model, long madeAt, AtomicLong hits) {}

    private final Map<String, Entry> entries = new ConcurrentHashMap<>();
    private final AtomicLong hits = new AtomicLong();
    private final AtomicLong misses = new AtomicLong();

    /**
     * Is this exchange anybody's to share?  Only if nothing in it is marked.
     *
     * A reference the model cannot read is still a fact about the person who
     * wrote it - that they have such a thing, and that it belonged here - so
     * the presence of a marker keeps the whole exchange out of the cache,
     * rather than merely keeping the content out.
     */
    static boolean shareable(String... parts) {
        boolean anything = false;
        for (var p : parts) {
            if (p == null || p.isBlank()) continue;
            anything = true;
            if (MARKED.matcher(p).find()) return false;
        }
        return anything;
    }

    /**
     * The key covers everything that shaped the answer. Case and spacing are
     * noise - "Tetris Game" and "tetris  game" are the same request - and
     * nothing else is normalised away.
     */
    static String key(String mode, String... parts) {
        try {
            var md = MessageDigest.getInstance("SHA-256");
            md.update(mode.getBytes(StandardCharsets.UTF_8));
            for (var p : parts) {
                md.update((byte) 0);
                if (p == null) continue;
                String norm = p.strip().toLowerCase(Locale.ROOT).replaceAll("\\s+", " ");
                md.update(norm.getBytes(StandardCharsets.UTF_8));
            }
            return HexFormat.of().formatHex(md.digest()).substring(0, 32);
        } catch (Exception x) {
            throw new IllegalStateException(x);
        }
    }

    Entry get(String key) {
        var e = entries.get(key);
        if (e == null) {
            misses.incrementAndGet();
            return null;
        }
        e.hits().incrementAndGet();
        hits.incrementAndGet();
        return e;
    }

    void put(String key, String text, String model) {
        if (text == null || text.isBlank()) return;
        entries.putIfAbsent(key, new Entry(text, model, System.currentTimeMillis(), new AtomicLong()));
    }

    /**
     * Take one back out.
     *
     * A cache with no way to forget is a cache that makes one wrong answer
     * permanent, and this one is shared - so a single bad reply becomes
     * everybody's bad reply, for as long as the process lives. Somebody asking
     * the identical thing again straight away is the signal that the answer
     * they got was not the one they wanted, and it is the only signal available
     * without asking them to rate anything.
     */
    boolean forget(String key) {
        return key != null && entries.remove(key) != null;
    }

    long hits() { return hits.get(); }

    long misses() { return misses.get(); }

    int size() { return entries.size(); }

    String asJson() {
        return Json.obj("entries", entries.size(), "hits", hits.get(), "misses", misses.get());
    }
}
