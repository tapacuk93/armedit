import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Map;

/**
 * The backend's route to a model, through the user's aicoin wallet.
 *
 * aicoin is a proxy in front of several providers, not a Claude-only path: the
 * request keeps the provider's own path and body shape, an X-AI header names
 * which upstream to use, and the proxy injects its own paid credential and
 * bills the wallet in X-Api-Key. So armedit holds no provider API key of any
 * kind - the per-account secret is the wallet token bound at registration.
 *
 * Claude is the default because it is what the editor is tuned for, but any
 * provider aicoin fronts can be selected per account or per request.
 */
final class Aicoin {

    /**
     * What a provider needs: which upstream to name, the path it expects, and
     * how to read a reply out of it. Adding one is a line here, not a branch
     * in the caller.
     */
    enum Provider {
        ANTHROPIC("anthropic", "/v1/messages", "claude-opus-5"),
        OPENAI("openai", "/v1/chat/completions", "gpt-4o"),
        MISTRAL("mistral", "/v1/chat/completions", "mistral-large-latest"),
        COHERE("cohere", "/v1/chat/completions", "command-r-plus");

        final String header;    // the value of X-AI
        final String path;      // the provider's own path, forwarded verbatim
        final String model;

        Provider(String header, String path, String model) {
            this.header = header;
            this.path = path;
            this.model = model;
        }

        static Provider of(String name) {
            if (name == null || name.isBlank()) return ANTHROPIC;
            for (var p : values()) if (p.header.equalsIgnoreCase(name.trim())) return p;
            return ANTHROPIC;
        }
    }

    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .build();

    private final URI base;
    private final Provider provider;
    private final String model;

    Aicoin(String baseUrl, String providerName, String modelOverride) {
        this.base = URI.create(baseUrl);
        this.provider = Provider.of(providerName);
        this.model = (modelOverride == null || modelOverride.isBlank())
                ? provider.model : modelOverride.trim();
    }

    String provider() { return provider.header; }

    String model() { return model; }

    /**
     * Ask on behalf of one account.
     *
     * @param wallet   the account's aicoin API token - what pays for this call
     * @param prompt   the whole prompt, already assembled by the caller
     * @param maxTokens output cap
     * @return the reply text
     */
    /**
     * Ask a specific tier, as chosen by the router or by a handoff. The
     * account's configured provider is only the default; routing may send this
     * exchange somewhere cheaper or stronger.
     */
    String ask(String wallet, Router.Tier tier, String prompt, int maxTokens) throws Exception {
        return send(wallet, Provider.of(tier.provider()), tier.model(), prompt, maxTokens);
    }

    String ask(String wallet, String prompt, int maxTokens) throws Exception {
        return send(wallet, provider, model, prompt, maxTokens);
    }

    private String send(String wallet, Provider provider, String model,
                        String prompt, int maxTokens) throws Exception {
        // Every provider aicoin fronts takes model/messages in this shape, so
        // one template covers them; the proxy forwards it untouched.
        String body = """
                {"model":"%s","max_tokens":%d,"messages":[{"role":"user","content":"%s"}]}"""
                .formatted(model, maxTokens, Json.escape(prompt));

        var req = HttpRequest.newBuilder(base.resolve(provider.path))
                .timeout(Duration.ofMinutes(5))
                .header("Content-Type", "application/json")
                .header("X-AI", provider.header)
                .header("X-Api-Key", wallet)
                .header("anthropic-version", "2023-06-01")
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .build();

        var res = http.send(req, HttpResponse.BodyHandlers.ofString());
        if (res.statusCode() / 100 != 2) {
            throw new IllegalStateException("aicoin %d: %s".formatted(res.statusCode(), trim(res.body())));
        }
        return extract(res.body());
    }

    /**
     * Pull the reply text out. Providers disagree about where it lives, so try
     * each shape rather than assume one.
     */
    private String extract(String json) {
        Map<String, String> flat = Json.parse(json);
        // Anthropic: content[0].text.  OpenAI-shaped: choices[0].message.content.
        for (var key : new String[]{"text", "content"}) {
            var v = flat.get(key);
            if (v != null && !v.isBlank() && !v.startsWith("[") && !v.startsWith("{")) return v;
        }
        var v = flat.get("output_text");
        if (v != null) return v;
        throw new IllegalStateException("no reply text in: " + trim(json));
    }

    private static String trim(String s) {
        return s.length() <= 400 ? s : s.substring(0, 400) + "...";
    }
}
