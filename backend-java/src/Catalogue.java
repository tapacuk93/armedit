import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * What models aicoin can actually reach, asked rather than assumed.
 *
 * The proxy forwards `GET /v1/models` to whichever provider the X-AI header
 * names, and that path costs nothing upstream - it is on the free list - so
 * this can be refreshed on a timer without spending an account's coins on
 * bookkeeping.
 *
 * A hardcoded model list is wrong the day a provider ships something, and
 * worse, it is wrong silently: the router keeps choosing between three names
 * while a fourth sits there unused. Asking means the fleet the router picks
 * from is the fleet that exists.
 *
 * Refreshing needs a wallet, because even a free call is authenticated. The
 * first account to register lends its token to the sweep; nothing about that
 * account is exposed by doing so, since a model list is not per-account.
 */
final class Catalogue {

    /** How often to re-ask. Providers do not ship hourly. */
    private static final long REFRESH_MINUTES = 60;

    private static final Pattern ID = Pattern.compile("\"id\"\\s*:\\s*\"([^\"]+)\"");

    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .build();

    /** One model, and the provider it has to be asked through. */
    record Member(String provider, String model) {
        @Override public String toString() { return provider + ":" + model; }
    }

    private final String base;
    private final List<String> providers;

    /** Everything seen, most recently refreshed. */
    private volatile List<String> models = List.of();
    private volatile List<Member> members = List.of();
    private volatile String lastError = "";
    private volatile long refreshedAt;

    Catalogue(String base, List<String> providers) {
        this.base = base;
        this.providers = providers;
    }

    List<String> models() { return models; }

    /** The same list, still knowing where each one lives. */
    List<Member> members() { return members; }

    long refreshedAt() { return refreshedAt; }

    String lastError() { return lastError; }

    /**
     * Start the sweep. It runs once at startup and then on a timer, so a
     * provider that appears later is picked up without a restart.
     */
    void start(java.util.function.Supplier<String> wallet) {
        var timer = Executors.newSingleThreadScheduledExecutor(r -> {
            var t = new Thread(r, "armedit-catalogue");
            t.setDaemon(true);
            return t;
        });
        timer.scheduleWithFixedDelay(() -> refresh(wallet.get()),
                5, REFRESH_MINUTES * 60, TimeUnit.SECONDS);
    }

    void refresh(String wallet) {
        if (wallet == null || wallet.isBlank()) {
            lastError = "no wallet has registered yet, so nothing can be asked";
            return;
        }
        var found = new LinkedHashSet<String>();
        var pairs = new ArrayList<Member>();
        var errors = new StringBuilder();
        for (var p : providers) {
            try {
                var ids = ask(wallet, p);
                found.addAll(ids);
                for (var id : ids) pairs.add(new Member(p, id));
            } catch (Exception x) {
                if (errors.length() > 0) errors.append("; ");
                errors.append(p).append(": ").append(x.getMessage());
            }
        }
        if (!found.isEmpty()) {
            models = List.copyOf(found);
            members = List.copyOf(pairs);
            refreshedAt = System.currentTimeMillis();
        }
        lastError = errors.toString();
        System.out.printf("armedit: catalogue has %d models%s%n", models.size(),
                errors.length() == 0 ? "" : " (" + errors + ")");
    }

    private Set<String> ask(String wallet, String provider) throws Exception {
        var req = HttpRequest.newBuilder(URI.create(base + "/v1/models"))
                .timeout(Duration.ofSeconds(20))
                .header("X-AI", provider)
                .header("X-Api-Key", wallet)
                .header("anthropic-version", "2023-06-01")
                .GET()
                .build();
        var res = http.send(req, HttpResponse.BodyHandlers.ofString());
        if (res.statusCode() / 100 != 2) {
            throw new IllegalStateException("HTTP " + res.statusCode());
        }
        var out = new LinkedHashSet<String>();
        Matcher m = ID.matcher(res.body());
        while (m.find()) out.add(m.group(1));
        return out;
    }

    /**
     * What the model is told about its colleagues. Names the router knows
     * first, then anything else the proxy turned out to be able to reach.
     */
    String briefing() {
        var known = new ArrayList<String>();
        for (var t : Router.TIERS) known.add(t.name());
        var b = new StringBuilder("Models this backend can route to: ");
        b.append(String.join(", ", known));
        var extra = new ArrayList<String>();
        for (var m : models) {
            boolean seen = false;
            for (var t : Router.TIERS) if (t.model().equals(m)) seen = true;
            if (!seen) extra.add(m);
        }
        if (!extra.isEmpty()) {
            b.append(".\nAlso reachable through the same wallet, though not currently in the routing table: ");
            b.append(String.join(", ", extra.subList(0, Math.min(12, extra.size()))));
            if (extra.size() > 12) b.append(" and ").append(extra.size() - 12).append(" more");
        }
        return b.append(".\n").toString();
    }
}
