import java.security.SecureRandom;
import java.time.Instant;
import java.util.HexFormat;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

/**
 * The account store.
 *
 * An account is only valid with both accesses bound: the aicoin wallet token
 * that pays for its model calls, and the AWS credentials its instance runs
 * under. Registration refuses anything less - issuing a key for half an
 * account would only fail later, further from the cause.
 *
 * The armedit key is the one credential that ever leaves this process, and the
 * only one a device holds. It is the map key here and is never logged.
 */
final class Accounts {

    /**
     * One registered user. The bound credentials never change, so they are
     * final; the instance the account is currently running does change, so it
     * is the one mutable field.
     */
    static final class Account {
        private final String id;
        private final long createdNanos;
        private final String wallet;
        private final String awsKey;
        private final String awsSecret;
        private final String region;
        /* Kept because the one-time pad is derived from it: an account cannot
           be reconstructed after a restart without the seed it was built on. */
        private final String password;
        private final Otp otp;
        private final Clouds clouds = new Clouds();
        private volatile String instance = "";
        private volatile long lastSeenMillis = System.currentTimeMillis();

        Account(String id, long createdNanos, String wallet, String awsKey,
                String awsSecret, String region, String password, Otp otp) {
            this.id = id;
            this.createdNanos = createdNanos;
            this.wallet = wallet;
            this.awsKey = awsKey;
            this.awsSecret = awsSecret;
            this.region = region;
            this.password = password;
            this.otp = otp;
        }

        String id() { return id; }
        long createdNanos() { return createdNanos; }
        String wallet() { return wallet; }
        String awsKey() { return awsKey; }
        String awsSecret() { return awsSecret; }
        String region() { return region; }
        String password() { return password; }
        Otp otp() { return otp; }

        /** Every cloud this account has bound credentials for, AWS included. */
        Clouds clouds() { return clouds; }

        String instance() { return instance; }

        void instance(String id) { this.instance = id == null ? "" : id; }

        /** Called on every authorised request: this is what "in use" means. */
        void touch() { lastSeenMillis = System.currentTimeMillis(); }

        private volatile String lastCategory = "";
        private volatile int lastScreen = -1;
        private volatile long lastAskMillis;
        private volatile String lastModel = "";

        String lastModel() { return lastModel; }

        void lastModel(String m) { lastModel = m == null ? "" : m; }

        /**
         * Remember what was just asked, so a second ask about the same screen
         * a moment later can be counted for what it probably is: the first
         * answer not landing.
         */
        boolean lastAsk(String category, int screen) {
            long now = System.currentTimeMillis();
            boolean reask = screen == lastScreen
                    && category.equals(lastCategory)
                    && now - lastAskMillis < 60_000;
            lastCategory = category;
            lastScreen = screen;
            lastAskMillis = now;
            return reask;
        }

        long idleMillis() { return System.currentTimeMillis() - lastSeenMillis; }
    }

    private final Map<String, Account> byKey = new ConcurrentHashMap<>();
    private final SecureRandom rng = new SecureRandom();
    private final AtomicLong seq = new AtomicLong();

    /**
     * Where the accounts live between runs.
     *
     * They used to live only in the map above, which meant every restart of
     * this process invalidated every device's key at once - and a device has
     * no way to notice that except by being told the backend is unreachable.
     * A phone would have to be re-provisioned because a server was redeployed,
     * which is not a trade anybody agreed to.
     */
    private java.nio.file.Path store;

    /**
     * The server's own random value. It goes into every account's OTP seed and
     * never leaves this process, so two accounts created in the same
     * nanosecond with the same password still get unrelated pad windows.
     */
    private final byte[] serverSecret = new byte[32];

    Accounts() {
        rng.nextBytes(serverSecret);
    }

    /**
     * Read back what a previous run issued.
     *
     * The server secret is restored rather than regenerated, because it seeds
     * every account's one-time pad: a fresh secret would silently move every
     * pad window and the accounting would no longer line up with what the
     * device believes.
     *
     * A file that will not parse is left alone and ignored. Starting empty
     * costs everyone a re-registration; overwriting a file we failed to
     * understand costs them their accounts.
     */
    void openStore(java.nio.file.Path path) {
        this.store = path;
        try {
            if (!java.nio.file.Files.exists(path)) return;
            for (String line : java.nio.file.Files.readAllLines(path)) {
                if (line.isBlank()) continue;
                var f = line.split("\t", -1);
                if (f.length < 8) continue;
                if ("secret".equals(f[0])) {
                    byte[] got = HexFormat.of().parseHex(f[1]);
                    if (got.length == serverSecret.length) {
                        System.arraycopy(got, 0, serverSecret, 0, got.length);
                    }
                    continue;
                }
                String key = f[0], id = f[1];
                long nanos = Long.parseLong(f[2]);
                var account = new Account(id, nanos, f[3], f[4], f[5], f[6], f[7],
                        new Otp(serverSecret, nanos, id, f[7]));
                // Credentials came back above, but the cloud binding built from
                // them did not - and without it the model is never told it can
                // run anything, which looks like the model refusing rather than
                // like a field that was not written down.
                if (!account.awsKey().isBlank() && !account.awsSecret().isBlank()) {
                    account.clouds().bind(Clouds.Provider.AWS, java.util.Map.of(
                            "access_key", account.awsKey(),
                            "secret_key", account.awsSecret(),
                            "region", account.region()));
                }
                byKey.put(key, account);
                long n = Long.parseLong(id.substring(id.lastIndexOf('-') + 1));
                if (n > seq.get()) seq.set(n);
            }
            System.out.printf("armedit: %d account(s) restored%n", byKey.size());
        } catch (Exception x) {
            System.out.printf("armedit: could not read %s (%s) - starting empty rather than "
                    + "overwriting it%n", path, x);
            this.store = null;
        }
    }

    /**
     * Written whole, every time, because there are tens of these and not
     * thousands. The password is kept because an account's pad is derived from
     * it and cannot be reconstructed without it - which is worth being plain
     * about: this file is as sensitive as the credentials in it, and lives
     * wherever the workspace does.
     */
    private synchronized void flush() {
        if (store == null) return;
        try {
            var out = new StringBuilder();
            out.append("secret\t").append(HexFormat.of().formatHex(serverSecret))
               .append("\t\t\t\t\t\t\n");
            for (var e : byKey.entrySet()) {
                var a = e.getValue();
                out.append(e.getKey()).append('\t').append(a.id()).append('\t')
                   .append(a.createdNanos()).append('\t').append(a.wallet()).append('\t')
                   .append(a.awsKey()).append('\t').append(a.awsSecret()).append('\t')
                   .append(a.region()).append('\t').append(a.password()).append('\n');
            }
            if (store.getParent() != null) java.nio.file.Files.createDirectories(store.getParent());
            var tmp = store.resolveSibling(store.getFileName() + ".new");
            java.nio.file.Files.writeString(tmp, out.toString());
            java.nio.file.Files.move(tmp, store,
                    java.nio.file.StandardCopyOption.REPLACE_EXISTING,
                    java.nio.file.StandardCopyOption.ATOMIC_MOVE);
        } catch (Exception x) {
            System.out.printf("armedit: could not save accounts: %s%n", x);
        }
    }

    /**
     * Mint an account and its key. The key is 24 bytes of entropy in hex: far
     * past guessing, still short enough to paste into an environment variable.
     */
    Issued create(String wallet, String awsKey, String awsSecret, String region, String password) {
        var now = Instant.now();
        long nanos = now.getEpochSecond() * 1_000_000_000L + now.getNano();
        String id = "acct-%06d".formatted(seq.incrementAndGet());
        var account = new Account(id, nanos, wallet, awsKey, awsSecret, region, password,
                new Otp(serverSecret, nanos, id, password));
        var raw = new byte[24];
        rng.nextBytes(raw);
        String key = HexFormat.of().formatHex(raw);
        byKey.put(key, account);
        flush();
        return new Issued(key, account);
    }

    record Issued(String key, Account account) {}

    Optional<Account> byKey(String key) {
        return key == null || key.isBlank() ? Optional.empty() : Optional.ofNullable(byKey.get(key));
    }

    /**
     * Any wallet at all, for the model catalogue's refresh. A model list is
     * not per-account, so borrowing the first one exposes nothing.
     */
    String anyWallet() {
        for (var a : byKey.values()) if (!a.wallet().isBlank()) return a.wallet();
        return "";
    }

    /** Every account, for the reaper to walk. */
    java.util.Collection<Account> all() { return byKey.values(); }

    int size() { return byKey.size(); }
}
