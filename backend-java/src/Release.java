import java.nio.file.Path;
import java.util.List;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.atomic.AtomicLong;

/**
 * What changed, and whether the machine has to be restarted to get it.
 *
 * The cycle this closes is: somebody writes a feature, it compiles, the
 * consortium agrees, it is pushed. The question left over is what the machine
 * in front of them should do about it, and there are exactly two answers.
 *
 * <h2>Live</h2>
 *
 * An operation is a page of machine code. A running editor can install one and
 * call it - that is what {@code op_install} does and what {@code /api/ops}
 * serves - so a new operation takes effect on the next keystroke, on a machine
 * that has not stopped. This is the normal case and it is the reason the cycle
 * is worth having: the gap between writing a feature and using it is a round
 * trip, not a release.
 *
 * <h2>Reboot</h2>
 *
 * Boot code is different, and pretending otherwise is how a system tells
 * somebody a change is live when it is not. The kernel's exception vectors are
 * installed once, before anything else runs; the framebuffer is found once; the
 * memory map is fixed at link time. A change to any of those exists only in a
 * binary that has not been executed yet, and no amount of downloading makes the
 * running one contain it.
 *
 * So the honest answer for those is "restart when it suits you", said plainly
 * and once, rather than a silent no-op that leaves somebody wondering why the
 * thing they just wrote does nothing.
 *
 * <h2>Why a path decides it</h2>
 *
 * Not because paths are a good model of dependency - they are a crude one - but
 * because the alternative is asking a model whether its own change needs a
 * reboot, and that is a question about the build, not about the code. A build
 * system knows which files land in the boot image. It is allowed to be
 * conservative: saying "reboot" about something that would have worked live
 * costs a restart, and saying "live" about boot code costs somebody an hour
 * wondering what is broken.
 */
final class Release {

    /**
     * Everything that ends up in the image the machine boots from.
     *
     * Deliberately broad. The editor core, the font and the network stack are
     * all linked into the kernel, so a change to any of them is a change to the
     * binary that is already running.
     */
    private static final List<String> BOOT_CODE = List.of(
            "kernel/", "include/", "font/", "editor/", "gfx/",
            "net/", "app/", "crypto/", "Makefile", "tools/mkops.py");

    /** One thing that changed, and what it means for the machine. */
    record Change(long at, String what, boolean reboot, String why) {}

    private final ConcurrentLinkedQueue<Change> changes = new ConcurrentLinkedQueue<>();
    private final AtomicLong pending = new AtomicLong();

    /**
     * Does changing this file mean the running machine is out of date?
     *
     * ops/ is the exception that makes the cycle worth having: those files are
     * loaded at run time, so they are never a reason to restart.
     */
    static boolean needsReboot(String path) {
        String p = path.replace('\\', '/');
        if (p.startsWith("ops/") || p.startsWith("./ops/")) return false;
        for (var prefix : BOOT_CODE) {
            if (p.startsWith(prefix) || p.contains("/" + prefix)) return true;
        }
        return false;
    }

    /** An operation was published. Operations are always live. */
    void record(String name, List<Path> written) {
        boolean reboot = false;
        for (var w : written) if (needsReboot(w.toString())) reboot = true;
        note(name, reboot, reboot
                ? "this touched code that runs before the editor does"
                : "a new operation - the next request can use it, nothing to restart");
    }

    /** Something else changed, and whoever changed it knows what it was. */
    void note(String what, boolean reboot, String why) {
        changes.add(new Change(System.currentTimeMillis(), what, reboot, why));
        while (changes.size() > 32) changes.poll();
        if (reboot) pending.incrementAndGet();
    }

    /** Is a restart owed? */
    boolean rebootPending() { return pending.get() > 0; }

    /**
     * Told once, then forgotten.
     *
     * A device asks whether it is out of date, and having been told, is not
     * told again - a notice that repeats on every request is a notice people
     * stop reading, and this one only matters the first time.
     */
    String takeNotice() {
        if (pending.get() == 0) return "";
        long n = pending.getAndSet(0);
        var b = new StringBuilder();
        b.append(n == 1 ? "A change needs a restart to take effect:"
                        : n + " changes need a restart to take effect:");
        for (var c : changes) {
            if (c.reboot()) b.append("\n  ").append(c.what()).append(" - ").append(c.why());
        }
        return b.toString();
    }

    /** What has happened lately, newest last. */
    List<Change> recent() { return List.copyOf(changes); }
}
