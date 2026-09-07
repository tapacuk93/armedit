/**
 * The code, checked by scanning it.
 *
 * Every other test here can be written against what the code should be. This
 * one cannot usefully: a QR is a specification full of tables, and a test that
 * asserted the grid matched what this encoder produces would pass for as long
 * as the encoder was consistently wrong. The only assertion worth making is
 * that a scanner reads back what went in - so the grid is written out, and
 * tests/qrscan.swift decodes it with the same framework a phone's camera uses.
 *
 * What is checked here is the part that is structure rather than content: the
 * size, the three finder patterns, the quiet zone, and that text too long to
 * fit is refused rather than truncated into something that scans as the wrong
 * thing.
 */
public class QrTest {
    static int fails = 0;

    static void ok(boolean b, String what) {
        System.out.printf("  %-58s %s%n", what, b ? "ok" : "FAIL");
        if (!b) fails++;
    }

    public static void main(String[] a) throws Exception {
        String url = "https://armedit.oeaio.com/authorize/a1b2c3d4e5f60718a1b2c3d4e5f60718";
        String svg = Qr.svg(url, 232);
        ok(svg != null, "a URL with an identifier on the end fits in a code");
        ok(svg.startsWith("<svg") && svg.endsWith("</svg>"), "...which comes out as an image");
        ok(svg.contains("viewBox=\"0 0 41 41\""),
           "...33 modules across, inside a four-module quiet zone");

        // The three corners a scanner finds before it reads anything.
        boolean[][] grid = Qr.grid(url);
        ok(grid.length == 33 && grid[0].length == 33, "the grid is version four's size");
        ok(finder(grid, 0, 0), "there is a finder in the top left");
        ok(finder(grid, 26, 0), "...the top right");
        ok(finder(grid, 0, 26), "...and the bottom left");
        ok(grid[25][8], "the module that is always dark is dark");

        // Timing: the alternating line that tells a scanner the module pitch.
        boolean timing = true;
        for (int i = 8; i < 25; i++) {
            if (grid[6][i] != (i % 2 == 0)) timing = false;
        }
        ok(timing, "the timing line alternates all the way across");

        // Too long is refused. Truncating would produce a code that scans
        // perfectly and says something other than what it was given, which is
        // the worst of the three possible outcomes.
        ok(Qr.svg("x".repeat(78), 232) != null, "seventy-eight bytes still fit");
        ok(Qr.svg("x".repeat(79), 232) == null, "seventy-nine are refused, not trimmed");

        // And the grid, for the scanner to read.
        if (a.length > 0) {
            var out = new StringBuilder();
            for (boolean[] row : grid) {
                for (boolean dark : row) out.append(dark ? '1' : '0');
                out.append('\n');
            }
            java.nio.file.Files.writeString(java.nio.file.Path.of(a[0]), out.toString());
            java.nio.file.Files.writeString(java.nio.file.Path.of(a[0] + ".txt"), url);
        }
        System.exit(fails == 0 ? 0 : 1);
    }

    /** A finder is a 7x7 ring with a 3x3 core, and nothing else looks like one. */
    static boolean finder(boolean[][] g, int x0, int y0) {
        for (int y = 0; y < 7; y++) {
            for (int x = 0; x < 7; x++) {
                boolean want = x == 0 || x == 6 || y == 0 || y == 6
                        || (x >= 2 && x <= 4 && y >= 2 && y <= 4);
                if (g[y0 + y][x0 + x] != want) return false;
            }
        }
        return true;
    }
}
