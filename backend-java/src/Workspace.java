import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/**
 * Where a user's text lives: memory, then disk, then cloud.
 *
 * Each account gets a folder, and each screen gets a folder inside it - the
 * same shape the provisioned machine sees in its home directory, so "screen 3"
 * means one thing whether you are typing into it or running something against
 * it.
 *
 *   <root>/<account-id>/screen-3/text.md      the current text
 *   <root>/<account-id>/screen-3/text.1.md    the previous megabyte
 *   <root>/<account-id>/aws-audit.log         what the agent asked AWS for
 *
 * Writes never happen on the request thread. A screen's text is handed over
 * and the caller returns; a single writer thread does the file work and then
 * the upload. Losing the last few seconds of typing to a crash is acceptable;
 * making every keystroke wait on a disk - let alone on S3 - is not.
 */
final class Workspace {

    /** Rotate a screen's file once it passes this. */
    private static final long ROTATE_BYTES = 1L << 20;   // 1 MiB

    /** How many rotated generations to keep per screen. */
    private static final int KEEP = 8;

    private final Path root;
    private final Aws aws;
    private final String bucket;
    private final ExecutorService writer;

    Workspace(Path root, Aws aws, String bucket) {
        this.root = root;
        this.aws = aws;
        this.bucket = bucket == null ? "" : bucket.trim();
        this.writer = Executors.newSingleThreadExecutor(r -> {
            var t = new Thread(r, "armedit-workspace");
            t.setDaemon(true);
            return t;
        });
    }

    Path accountDir(Accounts.Account a) { return root.resolve(a.id()); }

    Path screenDir(Accounts.Account a, int screen) {
        return accountDir(a).resolve("screen-" + Math.max(1, screen));
    }

    /**
     * Persist a screen. Returns immediately; the write and any upload happen
     * on the writer thread.
     */
    void save(Accounts.Account a, int screen, String text) {
        writer.execute(() -> {
            try {
                var dir = screenDir(a, screen);
                Files.createDirectories(dir);
                var file = dir.resolve("text.md");
                rotateIfNeeded(file, text.length());
                Files.writeString(file, text, StandardCharsets.UTF_8);
                toCloud(a, screen, file, text);
            } catch (Exception x) {
                System.out.printf("armedit: could not persist %s screen %d: %s%n",
                        a.id(), screen, x.getMessage());
            }
        });
    }

    /**
     * Rotation happens before the write that would cross the line, so a file
     * never exceeds the limit rather than being trimmed after the fact.
     */
    private void rotateIfNeeded(Path file, int incoming) throws Exception {
        if (!Files.exists(file)) return;
        if (Files.size(file) + incoming <= ROTATE_BYTES) return;
        var dir = file.getParent();
        for (int i = KEEP - 1; i >= 1; i--) {
            var from = dir.resolve("text.%d.md".formatted(i));
            var to = dir.resolve("text.%d.md".formatted(i + 1));
            if (Files.exists(from)) Files.move(from, to, StandardCopyOption.REPLACE_EXISTING);
        }
        Files.move(file, dir.resolve("text.1.md"), StandardCopyOption.REPLACE_EXISTING);
    }

    /** The third tier. Skipped silently when no bucket is configured. */
    private void toCloud(Accounts.Account a, int screen, Path file, String text) {
        if (bucket.isEmpty()) return;
        try {
            String key = "%s/screen-%d/text.md".formatted(a.id(), screen);
            aws.putObject(a, bucket, key, text.getBytes(StandardCharsets.UTF_8));
        } catch (Exception x) {
            // Disk already has it; the cloud copy can catch up on the next save.
            System.out.printf("armedit: cloud copy of %s deferred: %s%n", key(a, screen), x.getMessage());
        }
    }

    private static String key(Accounts.Account a, int screen) {
        return "%s/screen-%d".formatted(a.id(), screen);
    }

    /** What screens this account has on disk, for the machine to mirror. */
    List<Integer> screens(Accounts.Account a) {
        var out = new ArrayList<Integer>();
        var dir = accountDir(a);
        if (!Files.isDirectory(dir)) return out;
        try (var s = Files.list(dir)) {
            s.filter(Files::isDirectory)
             .map(p -> p.getFileName().toString())
             .filter(n -> n.startsWith("screen-"))
             .forEach(n -> {
                 try { out.add(Integer.parseInt(n.substring("screen-".length()))); }
                 catch (NumberFormatException ignored) { }
             });
        } catch (Exception ignored) {
        }
        out.sort(Integer::compareTo);
        return out;
    }

    String read(Accounts.Account a, int screen) {
        try {
            var file = screenDir(a, screen).resolve("text.md");
            return Files.exists(file) ? Files.readString(file, StandardCharsets.UTF_8) : "";
        } catch (Exception x) {
            return "";
        }
    }

    /** Flush pending writes; used on shutdown so the last save is not lost. */
    void close() {
        writer.shutdown();
        try {
            if (!writer.awaitTermination(10, TimeUnit.SECONDS)) writer.shutdownNow();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    Instant now() { return Instant.now(); }
}
