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
        private final Otp otp;
        private final Clouds clouds = new Clouds();
        private volatile String instance = "";
        private volatile long lastSeenMillis = System.currentTimeMillis();

        Account(String id, long createdNanos, String wallet, String awsKey,
                String awsSecret, String region, Otp otp) {
            this.id = id;
            this.createdNanos = createdNanos;
            this.wallet = wallet;
            this.awsKey = awsKey;
            this.awsSecret = awsSecret;
            this.region = region;
            this.otp = otp;
        }

        String id() { return id; }
        long createdNanos() { return createdNanos; }
        String wallet() { return wallet; }
        String awsKey() { return awsKey; }
        String awsSecret() { return awsSecret; }
        String region() { return region; }
        Otp otp() { return otp; }

        /** Every cloud this account has bound credentials for, AWS included. */
        Clouds clouds() { return clouds; }

        String instance() { return instance; }

        void instance(String id) { this.instance = id == null ? "" : id; }

        /** Called on every authorised request: this is what "in use" means. */
        void touch() { lastSeenMillis = System.currentTimeMillis(); }

        long idleMillis() { return System.currentTimeMillis() - lastSeenMillis; }
    }

    private final Map<String, Account> byKey = new ConcurrentHashMap<>();
    private final SecureRandom rng = new SecureRandom();
    private final AtomicLong seq = new AtomicLong();

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
     * Mint an account and its key. The key is 24 bytes of entropy in hex: far
     * past guessing, still short enough to paste into an environment variable.
     */
    Issued create(String wallet, String awsKey, String awsSecret, String region, String password) {
        var now = Instant.now();
        long nanos = now.getEpochSecond() * 1_000_000_000L + now.getNano();
        String id = "acct-%06d".formatted(seq.incrementAndGet());
        var account = new Account(id, nanos, wallet, awsKey, awsSecret, region,
                new Otp(serverSecret, nanos, id, password));
        var raw = new byte[24];
        rng.nextBytes(raw);
        String key = HexFormat.of().formatHex(raw);
        byKey.put(key, account);
        return new Issued(key, account);
    }

    record Issued(String key, Account account) {}

    Optional<Account> byKey(String key) {
        return key == null || key.isBlank() ? Optional.empty() : Optional.ofNullable(byKey.get(key));
    }

    /** Every account, for the reaper to walk. */
    java.util.Collection<Account> all() { return byKey.values(); }

    int size() { return byKey.size(); }
}
