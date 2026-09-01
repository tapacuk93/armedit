import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Locale;
import java.util.regex.Pattern;

/**
 * Fetching a page on the editor's behalf, when the editor cannot.
 *
 * The editor prefers to fetch directly - see net/browse.S - and this is the
 * other route, taken when direct does not work. Two things make it not work,
 * and both are permanent enough to matter: the editor speaks no TLS yet, so
 * every https site needs this; and a bare-metal machine has no resolver, so
 * every name needs this.
 *
 * <h2>What comes back</h2>
 *
 * Text, not HTML. The editor has a renderer (net/html.S) and uses it on the
 * direct route, so returning markup here would work - but it would mean two
 * paths that produce differently-shaped output for the same page, and the one
 * that gets less use would be the one that quietly rots. Both routes end in
 * text; this one just does the conversion where the CPU is.
 *
 * <h2>What this is not allowed to be</h2>
 *
 * A backend that fetches whatever it is told to fetch is an open proxy, and an
 * open proxy inside somebody's network is a way to reach things that network
 * thought were private. So: http and https only, no redirects to other
 * schemes, and addresses that resolve to this machine or to a private range
 * are refused. That last check is the one that matters and the one that is
 * easiest to leave out - "http://localhost:8090/api/stats" is a URL, and
 * without it this endpoint would happily read the backend's own internals and
 * hand them to whoever asked.
 */
final class Fetch {

    /** How much of a page is worth having. A screen is not a corpus. */
    private static final int MAX_BYTES = 512 * 1024;

    private static final int MAX_REDIRECTS = 4;

    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .followRedirects(HttpClient.Redirect.NEVER)   // followed by hand, so each hop is checked
            .build();

    record Page(String url, String text, String error) {
        boolean ok() { return error == null; }
    }

    Page get(String raw) {
        String where = normalise(raw);
        if (where == null) return new Page(raw, null, "that does not look like a site");
        try {
            for (int hop = 0; hop <= MAX_REDIRECTS; hop++) {
                URI uri = URI.create(where);
                String refused = forbidden(uri);
                if (refused != null) return new Page(where, null, refused);

                var req = HttpRequest.newBuilder(uri)
                        .timeout(Duration.ofSeconds(20))
                        .header("User-Agent", "armedit/0.1")
                        .header("Accept", "text/html,text/plain")
                        .GET()
                        .build();
                var res = http.send(req, HttpResponse.BodyHandlers.ofString());
                int code = res.statusCode();
                if (code / 100 == 3) {
                    var to = res.headers().firstValue("location").orElse(null);
                    if (to == null) return new Page(where, null, "redirected to nowhere");
                    where = URI.create(where).resolve(to).toString();
                    continue;
                }
                if (code / 100 != 2) {
                    return new Page(where, null, "the site answered " + code);
                }
                String body = res.body();
                if (body.length() > MAX_BYTES) body = body.substring(0, MAX_BYTES);
                return new Page(where, text(body), null);
            }
            return new Page(where, null, "too many redirects");
        } catch (Exception x) {
            return new Page(where, null, String.valueOf(x.getMessage()));
        }
    }

    /**
     * What somebody typed, as a URL.
     *
     * The same guesses net/browse.S makes, because a site opened one way and
     * the same site opened the other way must be the same site - if "google"
     * meant google.com on the device and something else here, the route the
     * request happened to take would change where it went.
     */
    static String normalise(String raw) {
        if (raw == null) return null;
        String s = raw.strip();
        if (s.isEmpty()) return null;
        if (s.toLowerCase(Locale.ROOT).startsWith("open ")) s = s.substring(5).strip();
        if (s.isEmpty()) return null;
        if (!s.matches("(?i)^https?://.*")) {
            String host = s.split("[/?#]", 2)[0];
            if (!host.contains(".")) s = s.replaceFirst("^" + Pattern.quote(host), host + ".com");
            s = "https://" + s;      // https first here; the device tries http first
        }
        try {
            URI u = URI.create(s);
            if (u.getHost() == null) return null;
            return s;
        } catch (Exception x) {
            return null;
        }
    }

    /**
     * Is this a place this backend must not go?
     *
     * @return why not, or null if it may
     */
    static String forbidden(URI uri) {
        String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase(Locale.ROOT);
        if (!scheme.equals("http") && !scheme.equals("https")) {
            return "only http and https";
        }
        String host = uri.getHost();
        if (host == null || host.isBlank()) return "no host in that";
        try {
            for (var addr : java.net.InetAddress.getAllByName(host)) {
                if (addr.isLoopbackAddress() || addr.isAnyLocalAddress()
                        || addr.isLinkLocalAddress() || addr.isSiteLocalAddress()
                        || addr.isMulticastAddress()) {
                    // Not an error message with the address in it: what
                    // resolved where is exactly what a caller probing the
                    // network would like to be told.
                    return "that address is not one this server will fetch";
                }
            }
        } catch (Exception x) {
            return "that name does not resolve";
        }
        return null;
    }

    /**
     * HTML to text, roughly the way net/html.S does it.
     *
     * Script and style go entirely, because their contents are not the page;
     * block elements become line breaks, because a paragraph that runs into
     * the next one is not readable; everything else is stripped and its
     * entities decoded. It is not a renderer and does not need to be - the
     * question this answers is "what does the page say", and a text editor is
     * a good place to find out.
     */
    static String text(String html) {
        String s = html;
        s = s.replaceAll("(?is)<script[^>]*>.*?</script>", " ");
        s = s.replaceAll("(?is)<style[^>]*>.*?</style>", " ");
        s = s.replaceAll("(?is)<!--.*?-->", " ");
        s = s.replaceAll("(?i)<br\\s*/?>", "\n");
        s = s.replaceAll("(?i)</(p|div|li|tr|h[1-6]|section|article|header|footer)>", "\n");
        s = s.replaceAll("(?i)<li[^>]*>", "\n  - ");
        s = s.replaceAll("(?s)<[^>]+>", " ");
        s = entities(s);
        s = s.replaceAll("[ \\t\\x0B\\f\\r]+", " ");
        s = s.replaceAll(" *\n *", "\n");
        // A bullet with nothing after it is not a list item, it is the shape of
        // one. Wikipedia's navigation is a few hundred of them, and they arrive
        // ahead of the article - so the first screen of every page was dashes.
        s = s.replaceAll("(?m)^-\\s*$", "");
        s = s.replaceAll("\n{3,}", "\n\n");
        return s.strip();
    }

    private static String entities(String s) {
        String out = s.replace("&nbsp;", " ")
                .replace("&amp;", "&")
                .replace("&lt;", "<")
                .replace("&gt;", ">")
                .replace("&quot;", "\"")
                .replace("&#39;", "'")
                .replace("&apos;", "'")
                .replace("&mdash;", "-")
                .replace("&ndash;", "-")
                .replace("&hellip;", "...");
        // Numeric entities, which are the ones a page generator actually emits.
        var m = Pattern.compile("&#(x?)([0-9A-Fa-f]{1,6});").matcher(out);
        var b = new StringBuilder();
        int at = 0;
        while (m.find()) {
            b.append(out, at, m.start());
            try {
                int cp = Integer.parseInt(m.group(2), m.group(1).isEmpty() ? 10 : 16);
                // The editor's font is 7-bit. Anything else would render as a
                // box at best, so it becomes a space rather than a surprise.
                b.append(cp >= 32 && cp < 127 ? (char) cp : ' ');
            } catch (Exception x) {
                b.append(m.group());
            }
            at = m.end();
        }
        b.append(out.substring(at));
        return b.toString();
    }
}
