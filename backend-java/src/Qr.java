/**
 * A QR code, drawn rather than fetched.
 *
 * The page needs one so that a wallet can be authorised by pointing a phone at
 * the screen instead of pasting a secret through a text field. Asking a third
 * party to render it would mean handing them the thing it says, which for an
 * authorisation request is the whole of what is secret about it - and this
 * backend has one dependency on purpose, so a library for one grid of squares
 * would be a strange place to acquire a second.
 *
 * <h2>One size, one level, and why that is enough</h2>
 *
 * Version 4 at error-correction level L: a 33x33 grid holding up to 78 bytes,
 * which is comfortably more than a URL ending in a 32-character identifier.
 * It is also the largest version that is a *single block* - above it the data
 * is split and the blocks interleaved, which is more code for a case this
 * never reaches. Fixing the size costs nothing here and removes every table
 * that would otherwise have to be right.
 *
 * <h2>What the specification decides and what this decides</h2>
 *
 * Almost all of it is the specification: the generator polynomial, the
 * placement order, the function patterns, the format bits and their BCH code.
 * The one free choice is the mask, and it is made the way the standard says to
 * make it - all eight are drawn, each is scored by the four penalty rules, and
 * the lowest wins. Picking one arbitrarily would usually work and would fail
 * on the data where it mattered, which is the failure nobody can debug from a
 * photograph of a screen.
 */
final class Qr {

    private static final int VERSION = 4;
    private static final int SIZE = 17 + VERSION * 4;       /* 33 */
    private static final int DATA_CODEWORDS = 80;
    private static final int EC_CODEWORDS = 20;
    /*
     * Four bits of mode, eight of length and four of terminator leave 624 bits
     * for the message, which is seventy-eight bytes. Counted rather than
     * rounded down: a capacity that is short by one refuses a URL that fits.
     */
    private static final int CAPACITY = (DATA_CODEWORDS * 8 - 4 - 8 - 4) / 8;

    private final boolean[][] module = new boolean[SIZE][SIZE];
    private final boolean[][] fixed = new boolean[SIZE][SIZE];

    private Qr() {
    }

    /**
     * The chosen grid, for a test that reads it back with a scanner.
     *
     * Exposed because the only assertion worth making about an encoder is that
     * something else can decode it, and the something else needs the modules
     * rather than the picture.
     */
    static boolean[][] grid(String text) {
        return build(text);
    }

    /** The code for this text as an SVG, or null if it will not fit. */
    static String svg(String text, int pixels) {
        boolean[][] best = build(text);
        return best == null ? null : draw(best, pixels);
    }

    private static boolean[][] build(String text) {
        byte[] bytes = text.getBytes(java.nio.charset.StandardCharsets.UTF_8);
        if (bytes.length > CAPACITY) {
            return null;
        }
        boolean[][] best = null;
        int bestPenalty = Integer.MAX_VALUE;
        byte[] codewords = withErrorCorrection(bytes);
        for (int mask = 0; mask < 8; mask++) {
            Qr qr = new Qr();
            qr.patterns();
            qr.place(codewords);
            qr.mask(mask);
            qr.format(mask);
            int penalty = qr.penalty();
            if (penalty < bestPenalty) {
                bestPenalty = penalty;
                best = qr.module;
            }
        }
        return best;
    }

    /* ------------------------------------------------------------ the bits */

    /**
     * The message: what mode, how long, the bytes, then padding.
     *
     * The padding alternates two fixed values rather than being zeros, which
     * is the specification's way of keeping the unused half of a code from
     * being a large blank region - the same reason the mask exists.
     */
    private static byte[] withErrorCorrection(byte[] data) {
        var bits = new StringBuilder();
        bits.append("0100");                                    /* byte mode */
        for (int i = 7; i >= 0; i--) {                          /* eight bits of length */
            bits.append((data.length >> i) & 1);
        }
        for (byte b : data) {
            for (int i = 7; i >= 0; i--) {
                bits.append((b >> i) & 1);
            }
        }
        for (int i = 0; i < 4 && bits.length() < DATA_CODEWORDS * 8; i++) {
            bits.append('0');                                   /* terminator */
        }
        while (bits.length() % 8 != 0) {
            bits.append('0');
        }
        byte[] codewords = new byte[DATA_CODEWORDS + EC_CODEWORDS];
        for (int i = 0; i < bits.length() / 8; i++) {
            codewords[i] = (byte) Integer.parseInt(bits.substring(i * 8, i * 8 + 8), 2);
        }
        boolean odd = false;
        for (int i = bits.length() / 8; i < DATA_CODEWORDS; i++) {
            codewords[i] = (byte) (odd ? 0x11 : 0xEC);
            odd = !odd;
        }

        byte[] ec = reedSolomon(java.util.Arrays.copyOf(codewords, DATA_CODEWORDS));
        System.arraycopy(ec, 0, codewords, DATA_CODEWORDS, EC_CODEWORDS);
        return codewords;
    }

    /**
     * Reed-Solomon over GF(256), the field QR uses: x^8 + x^4 + x^3 + x^2 + 1.
     *
     * Long division of the message by the generator polynomial, keeping the
     * remainder. Written out because it is twenty lines and because the
     * alternative - a table of precomputed remainders - is twenty lines that
     * cannot be checked by reading them.
     */
    private static byte[] reedSolomon(byte[] data) {
        int[] exp = new int[512];
        int[] log = new int[256];
        int x = 1;
        for (int i = 0; i < 255; i++) {
            exp[i] = x;
            log[x] = i;
            x <<= 1;
            if ((x & 0x100) != 0) {
                x ^= 0x11D;
            }
        }
        for (int i = 255; i < 512; i++) {
            exp[i] = exp[i - 255];
        }

        int[] generator = new int[]{1};
        for (int i = 0; i < EC_CODEWORDS; i++) {
            int[] next = new int[generator.length + 1];
            for (int j = 0; j < generator.length; j++) {
                next[j] ^= generator[j];
                if (generator[j] != 0) {
                    next[j + 1] ^= exp[(log[generator[j]] + i) % 255];
                }
            }
            generator = next;
        }

        int[] remainder = new int[EC_CODEWORDS];
        for (byte b : data) {
            int factor = (b & 0xFF) ^ remainder[0];
            System.arraycopy(remainder, 1, remainder, 0, EC_CODEWORDS - 1);
            remainder[EC_CODEWORDS - 1] = 0;
            if (factor != 0) {
                for (int i = 0; i < EC_CODEWORDS; i++) {
                    remainder[i] ^= exp[(log[factor] + log[generator[i + 1]]) % 255];
                }
            }
        }
        byte[] out = new byte[EC_CODEWORDS];
        for (int i = 0; i < EC_CODEWORDS; i++) {
            out[i] = (byte) remainder[i];
        }
        return out;
    }

    /* -------------------------------------------------------- the grid */

    /** The parts of the grid that are the same in every code of this size. */
    private void patterns() {
        finder(0, 0);
        finder(SIZE - 7, 0);
        finder(0, SIZE - 7);
        for (int i = 8; i < SIZE - 8; i++) {                    /* timing */
            set(i, 6, i % 2 == 0, true);
            set(6, i, i % 2 == 0, true);
        }
        /*
         * Version four's alignment centres are 6 and 26, and the one at 6,6
         * is inside a finder. So there is exactly one, at 26,26 - which is
         * SIZE-7 and not SIZE-9. Two modules out, it sits where data should
         * be, shifts every bit after it, and produces a code nothing reads.
         */
        alignment(SIZE - 7, SIZE - 7);
        set(8, SIZE - 8, true, true);                           /* always dark */
        /*
         * Where the format information goes, kept clear of the data.
         *
         * Nine modules along the top-left in each direction; eight along the
         * top right; eight up the bottom left, the last of which is the
         * always-dark module rather than format. Reserving nine in the last
         * two - which is the symmetrical-looking thing to write - takes a
         * module of data away from each and shifts everything after it.
         */
        for (int i = 0; i < 9; i++) {
            reserve(i, 8);
            reserve(8, i);
        }
        for (int i = 0; i < 8; i++) {
            reserve(SIZE - 1 - i, 8);
            reserve(8, SIZE - 1 - i);
        }
    }

    private void finder(int x0, int y0) {
        for (int dy = -1; dy <= 7; dy++) {
            for (int dx = -1; dx <= 7; dx++) {
                int x = x0 + dx;
                int y = y0 + dy;
                if (x < 0 || y < 0 || x >= SIZE || y >= SIZE) {
                    continue;
                }
                boolean dark = dx >= 0 && dx <= 6 && dy >= 0 && dy <= 6
                        && (dx == 0 || dx == 6 || dy == 0 || dy == 6
                            || (dx >= 2 && dx <= 4 && dy >= 2 && dy <= 4));
                set(x, y, dark, true);
            }
        }
    }

    private void alignment(int cx, int cy) {
        for (int dy = -2; dy <= 2; dy++) {
            for (int dx = -2; dx <= 2; dx++) {
                boolean dark = Math.abs(dx) == 2 || Math.abs(dy) == 2 || (dx == 0 && dy == 0);
                set(cx + dx, cy + dy, dark, true);
            }
        }
    }

    private void set(int x, int y, boolean dark, boolean isFixed) {
        module[y][x] = dark;
        if (isFixed) {
            fixed[y][x] = true;
        }
    }

    private void reserve(int x, int y) {
        fixed[y][x] = true;
    }

    /**
     * The data, up the right-hand side and down the next, two columns at a
     * time, skipping the vertical timing line and anything already spoken for.
     */
    private void place(byte[] codewords) {
        int bit = 0;
        boolean upward = true;
        for (int right = SIZE - 1; right >= 1; right -= 2) {
            if (right == 6) {
                right = 5;                                      /* the timing column */
            }
            for (int i = 0; i < SIZE; i++) {
                int y = upward ? SIZE - 1 - i : i;
                for (int c = 0; c < 2; c++) {
                    int xx = right - c;
                    if (fixed[y][xx]) {
                        continue;
                    }
                    boolean dark = false;
                    if (bit < codewords.length * 8) {
                        dark = ((codewords[bit / 8] >> (7 - (bit % 8))) & 1) == 1;
                    }
                    module[y][xx] = dark;
                    bit++;
                }
            }
            upward = !upward;
        }
    }

    private void mask(int pattern) {
        for (int y = 0; y < SIZE; y++) {
            for (int x = 0; x < SIZE; x++) {
                if (fixed[y][x]) {
                    continue;
                }
                boolean flip = switch (pattern) {
                    case 0 -> (x + y) % 2 == 0;
                    case 1 -> y % 2 == 0;
                    case 2 -> x % 3 == 0;
                    case 3 -> (x + y) % 3 == 0;
                    case 4 -> (y / 2 + x / 3) % 2 == 0;
                    case 5 -> (x * y) % 2 + (x * y) % 3 == 0;
                    case 6 -> ((x * y) % 2 + (x * y) % 3) % 2 == 0;
                    default -> ((x + y) % 2 + (x * y) % 3) % 2 == 0;
                };
                module[y][x] ^= flip;
            }
        }
    }

    /**
     * Which level and which mask, twice, in the two places a reader looks.
     *
     * Fifteen bits: five of meaning, ten of BCH so that a damaged corner still
     * says which mask was used - without which none of the rest can be read.
     */
    private void format(int maskPattern) {
        int bits = (0b01 << 3) | maskPattern;                   /* level L */
        int rest = bits << 10;
        for (int i = 14; i >= 10; i--) {
            if (((rest >> i) & 1) != 0) {
                rest ^= 0b10100110111 << (i - 10);
            }
        }
        int value = ((bits << 10) | rest) ^ 0b101010000010010;

/*
 * Where each bit goes, and it is not symmetrical.
 *
 * The first copy runs down the left of the top-left finder and then along the
 * top of it; the second runs along the top of the bottom-right finder and then
 * down the left of the bottom-left one. Eight modules in the horizontal half
 * and seven in the vertical, the eighth place in that column being the module
 * that is always dark.
 *
 * Written the other way round - rows for columns - this produces a code whose
 * finders, timing, alignment and data are all correct and which no scanner
 * will read, because the fifteen bits saying which mask was used are somewhere
 * else entirely.
 */
        for (int i = 0; i < 15; i++) {
            boolean dark = ((value >> i) & 1) == 1;
            if (i < 6) {
                module[i][8] = dark;
            } else if (i == 6) {
                module[7][8] = dark;
            } else if (i == 7) {
                module[8][8] = dark;
            } else if (i == 8) {
                module[8][7] = dark;
            } else {
                module[8][14 - i] = dark;
            }
            if (i < 8) {
                module[8][SIZE - 1 - i] = dark;
            } else {
                module[SIZE - 15 + i][8] = dark;
            }
        }
        module[SIZE - 8][8] = true;
    }

    /** The four rules the standard scores a mask by; lower is better. */
    private int penalty() {
        int score = 0;
        for (int y = 0; y < SIZE; y++) {
            for (int x = 0; x < SIZE; x++) {
                if (x + 1 < SIZE && y + 1 < SIZE
                        && module[y][x] == module[y][x + 1]
                        && module[y][x] == module[y + 1][x]
                        && module[y][x] == module[y + 1][x + 1]) {
                    score += 3;                                 /* a 2x2 block */
                }
            }
        }
        for (int y = 0; y < SIZE; y++) {
            score += runs(y, true);
        }
        for (int x = 0; x < SIZE; x++) {
            score += runs(x, false);
        }
        int dark = 0;
        for (int y = 0; y < SIZE; y++) {
            for (int x = 0; x < SIZE; x++) {
                if (module[y][x]) {
                    dark++;
                }
            }
        }
        int percent = dark * 100 / (SIZE * SIZE);
        score += Math.abs(percent - 50) / 5 * 10;
        return score;
    }

    /** Runs of five or more, and the finder-like sequence, along one line. */
    private int runs(int line, boolean horizontal) {
        int score = 0;
        int run = 1;
        for (int i = 1; i < SIZE; i++) {
            boolean here = horizontal ? module[line][i] : module[i][line];
            boolean before = horizontal ? module[line][i - 1] : module[i - 1][line];
            if (here == before) {
                run++;
            } else {
                if (run >= 5) {
                    score += 3 + (run - 5);
                }
                run = 1;
            }
        }
        if (run >= 5) {
            score += 3 + (run - 5);
        }
        for (int i = 0; i + 7 < SIZE; i++) {
            boolean[] w = new boolean[7];
            for (int k = 0; k < 7; k++) {
                w[k] = horizontal ? module[line][i + k] : module[i + k][line];
            }
            if (w[0] && !w[1] && w[2] && w[3] && w[4] && !w[5] && w[6]) {
                score += 40;
            }
        }
        return score;
    }

    /**
     * As SVG, because it is the only picture format this can emit without
     * writing an encoder for one - and it stays sharp at whatever size the
     * page draws it, which a grid of squares should.
     */
    private static String draw(boolean[][] grid, int pixels) {
        int quiet = 4;
        int span = SIZE + quiet * 2;
        var out = new StringBuilder();
        out.append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"").append(pixels)
           .append("\" height=\"").append(pixels)
           .append("\" viewBox=\"0 0 ").append(span).append(' ').append(span)
           .append("\" shape-rendering=\"crispEdges\">")
           .append("<rect width=\"").append(span).append("\" height=\"").append(span)
           .append("\" fill=\"#ffffff\"/><path fill=\"#000000\" d=\"");
        for (int y = 0; y < SIZE; y++) {
            for (int x = 0; x < SIZE; x++) {
                if (grid[y][x]) {
                    out.append('M').append(x + quiet).append(' ').append(y + quiet)
                       .append("h1v1h-1z");
                }
            }
        }
        return out.append("\"/></svg>").toString();
    }
}
