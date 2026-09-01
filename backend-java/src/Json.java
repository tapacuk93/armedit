import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Just enough JSON for this protocol: flat objects of strings and numbers.
 *
 * A backend with no dependencies is easier to trust than one that pulls in a
 * parser to read four fields, and the shapes on this wire are ones we define.
 */
final class Json {

    private Json() {}

    static Map<String, String> parse(String s) {
        var out = new LinkedHashMap<String, String>();
        int i = 0, n = s.length();
        while (i < n) {
            while (i < n && s.charAt(i) != '"') i++;
            if (i >= n) break;
            var key = new StringBuilder();
            i = readString(s, i + 1, key);
            while (i < n && Character.isWhitespace(s.charAt(i))) i++;
            if (i >= n || s.charAt(i) != ':') continue;
            i++;
            while (i < n && Character.isWhitespace(s.charAt(i))) i++;
            if (i >= n) break;
            var val = new StringBuilder();
            if (s.charAt(i) == '"') {
                i = readString(s, i + 1, val);
            } else {
                while (i < n && ",}]".indexOf(s.charAt(i)) < 0) val.append(s.charAt(i++));
            }
            out.put(key.toString(), val.toString().trim());
        }
        return out;
    }

    private static int readString(String s, int i, StringBuilder out) {
        int n = s.length();
        while (i < n) {
            char c = s.charAt(i++);
            if (c == '"') return i;
            if (c != '\\') {
                out.append(c);
                continue;
            }
            if (i >= n) return i;
            char e = s.charAt(i++);
            switch (e) {
                case 'n' -> out.append('\n');
                case 'r' -> out.append('\r');
                case 't' -> out.append('\t');
                case 'b' -> out.append('\b');
                case 'f' -> out.append('\f');
                case 'u' -> {
                    if (i + 4 <= n) {
                        out.append((char) Integer.parseInt(s.substring(i, i + 4), 16));
                        i += 4;
                    }
                }
                default -> out.append(e);
            }
        }
        return i;
    }

    static String escape(String s) {
        var b = new StringBuilder(s.length() + 16);
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"' -> b.append("\\\"");
                case '\\' -> b.append("\\\\");
                case '\n' -> b.append("\\n");
                case '\r' -> b.append("\\r");
                case '\t' -> b.append("\\t");
                default -> {
                    if (c < 0x20) b.append("\\u%04x".formatted((int) c));
                    else b.append(c);
                }
            }
        }
        return b.toString();
    }

    /** obj("key", "value", "n", 3) - strings get quoted, numbers do not. */
    /**
     * The inverse of {@link #escape}, for a string already lifted out of JSON.
     *
     * Only the escapes this project's replies actually contain. A model's
     * answer is prose and code, not arbitrary Unicode games, and a decoder
     * that quietly mangles what it does not know is worse than one that copies
     * it through unchanged.
     */
    static String unescape(String s) {
        if (s == null || s.indexOf('\\') < 0) return s;
        var b = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c != '\\' || i + 1 >= s.length()) { b.append(c); continue; }
            char n = s.charAt(++i);
            switch (n) {
                case 'n' -> b.append('\n');
                case 't' -> b.append('\t');
                case 'r' -> b.append('\r');
                case 'b' -> b.append('\b');
                case 'f' -> b.append('\f');
                case '"' -> b.append('"');
                case '\\' -> b.append('\\');
                case '/' -> b.append('/');
                case 'u' -> {
                    if (i + 4 < s.length()) {
                        b.append((char) Integer.parseInt(s.substring(i + 1, i + 5), 16));
                        i += 4;
                    } else {
                        b.append("\\u");
                    }
                }
                default -> b.append('\\').append(n);
            }
        }
        return b.toString();
    }

    static String obj(Object... kv) {
        var b = new StringBuilder("{");
        for (int i = 0; i + 1 < kv.length; i += 2) {
            if (i > 0) b.append(',');
            b.append('"').append(escape(kv[i].toString())).append("\":");
            Object v = kv[i + 1];
            if (v instanceof Number || v instanceof Boolean) b.append(v);
            else b.append('"').append(escape(String.valueOf(v))).append('"');
        }
        return b.append('}').toString();
    }
}
