import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;

/**
 * The one-time pad layer, and the bit accounting that drives it.
 *
 * Both ends count the exact number of bits that have crossed the link, and
 * that count is the only framing there is. Reservation windows sit at offsets
 * derived from the account's own seed, so at any bit position both ends
 * already agree on whether what follows is data or a pad reservation. Nothing
 * on the wire says which, and an observer without the seed cannot tell where
 * one ends and the other begins.
 *
 * The seed is SHA-256 over the server's private random value, the account's
 * creation nanosecond, its id and its password. Two accounts registered in the
 * same nanosecond with the same password still diverge, because the server
 * secret is in the hash and never leaves this process.
 *
 * On the word "pad": the bytes handed out by {@link #reserve()} are real
 * SecureRandom, spent once, and zeroed as they are consumed - that is what
 * makes this a pad rather than a stream cipher. The seed decides only *where*
 * the windows fall, never what the pad contains.
 */
final class Otp {

    /** Bits of pad handed over in one reservation: 32 KiB. */
    static final int RESERVATION_BITS = 1 << 18;

    /** Data bits between reservations: a seed-derived jitter over this base. */
    private static final long WINDOW_MIN = 1L << 16;
    private static final long WINDOW_SPAN = 1L << 17;

    private final byte[] seed;
    private final SecureRandom rng = new SecureRandom();

    private long bits;              // exact bits transferred, data and framing
    private byte[] pad = new byte[0];
    private long padBitBase;        // the bit offset pad[0] covers
    private long reservations;

    Otp(byte[] serverSecret, long createdNanos, String id, String password) {
        this.seed = digest(md -> {
            md.update(serverSecret);
            md.update(ByteBuffer.allocate(Long.BYTES).putLong(createdNanos).array());
            md.update(id.getBytes(StandardCharsets.UTF_8));
            md.update((byte) 0);
            md.update(password.getBytes(StandardCharsets.UTF_8));
        });
    }

    synchronized long bitsTransferred() { return bits; }

    synchronized long reservationsIssued() { return reservations; }

    synchronized int padRemaining() {
        int spent = (int) ((bits - padBitBase) / 8);
        return Math.max(0, pad.length - spent);
    }

    /**
     * Where the n-th reservation window opens, in bits. Unpredictable without
     * the seed, identical on both sides with it.
     */
    long windowStart(long n) {
        long acc = 0;
        for (long i = 0; i <= n; i++) acc += WINDOW_MIN + (jitter(i) % WINDOW_SPAN);
        return acc;
    }

    /** True when the bit at this offset belongs to a reservation, not to data. */
    synchronized boolean isReservation(long bitOffset) {
        long start = windowStart(reservations);
        return bitOffset >= start && bitOffset < start + RESERVATION_BITS;
    }

    /** How many more data bits may pass before the next reservation window. */
    synchronized long bitsUntilReservation() {
        return Math.max(0, windowStart(reservations) - bits);
    }

    /** Fresh pad for the next window: real randomness, handed over exactly once. */
    synchronized byte[] reserve() {
        pad = new byte[RESERVATION_BITS / 8];
        rng.nextBytes(pad);
        padBitBase = bits;
        reservations++;
        return pad.clone();
    }

    /**
     * XOR a payload against the pad at the current offset, advancing the
     * counter by exactly the bits consumed. Spent pad bytes are zeroed on the
     * way past, so nothing here can be used a second time.
     */
    synchronized byte[] apply(byte[] data) {
        int off = (int) ((bits - padBitBase) / 8);
        if (off < 0 || pad.length - off < data.length) {
            throw new IllegalStateException(
                    "pad exhausted: %d bytes left, %d needed".formatted(padRemaining(), data.length));
        }
        var out = new byte[data.length];
        for (int i = 0; i < data.length; i++) {
            out[i] = (byte) (data[i] ^ pad[off + i]);
            pad[off + i] = 0;
        }
        bits += (long) data.length * 8;
        return out;
    }

    /** Account for bits that crossed the link outside the pad, such as framing. */
    synchronized void account(long moreBits) { bits += moreBits; }

    private long jitter(long n) {
        var h = digest(md -> {
            md.update(seed);
            md.update(ByteBuffer.allocate(Long.BYTES).putLong(n).array());
        });
        return ByteBuffer.wrap(h, 0, Long.BYTES).getLong() >>> 1;
    }

    private interface Feed { void feed(MessageDigest md); }

    private static byte[] digest(Feed f) {
        try {
            var md = MessageDigest.getInstance("SHA-256");
            f.feed(md);
            return md.digest();
        } catch (Exception e) {
            throw new IllegalStateException("SHA-256 unavailable", e);
        }
    }
}
