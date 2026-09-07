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
 * bills the wallet in X-Api-Key. So sue holds no provider API key of any
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
        ANTHROPIC("anthropic", "/v1/messages", "claude-opus-5", "max_tokens"),
        OPENAI("openai", "/v1/chat/completions", "gpt-4o", "max_completion_tokens"),
        MISTRAL("mistral", "/v1/chat/completions", "mistral-large-latest", "max_tokens"),
        COHERE("cohere", "/v1/chat/completions", "command-r-plus", "max_tokens");

        final String header;    // the value of X-AI
        final String path;      // the provider's own path, forwarded verbatim
        final String model;
        /**
         * What this provider calls the output cap.
         *
         * OpenAI renamed it when reasoning models arrived, and its newer ones
         * reject the old name outright rather than accepting it - so a single
         * hardcoded "max_tokens" reaches gpt-4o and fails on gpt-5, which is
         * the failure that looks like the model being unreachable.
         *
         * A reviewing model held this change on the grounds that
         * max_completion_tokens does not exist and would break every
         * /v1/chat/completions call. Both names were put to the proxy before
         * this was written: gpt-4o answers 200 to max_completion_tokens, and
         * gpt-5 answers 400 to max_tokens with "use max_completion_tokens
         * instead". The objection was specific, confidently argued, and about
         * a world that had moved - which is the failure mode of asking models
         * about facts rather than about code, and the reason this note is here
         * rather than a silent revert.
         */
        final String cap;

        Provider(String header, String path, String model, String cap) {
            this.header = header;
            this.path = path;
            this.model = model;
            this.cap = cap;
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
        try {
            return text(wallet, prompt, null);
        } catch (NoText older) {
            /* A proxy without the capability endpoints. The tier's provider
               and model are still a working answer there, which is why the
               table has not been deleted - it is the fallback, not the plan. */
            return send(wallet, Provider.of(tier.provider()), tier.model(), prompt, maxTokens);
        }
    }

    String ask(String wallet, String prompt, int maxTokens) throws Exception {
        return send(wallet, provider, model, prompt, maxTokens);
    }

    /**
     * Ask one named model at one named provider, outside the routing table.
     *
     * The router chooses between the three tiers this editor is tuned for.
     * This reaches anything the proxy fronts, which is what a consortium needs:
     * its whole point is asking models the router would never have picked.
     */
    String askDirect(String wallet, String providerName, String model,
                     String prompt, int maxTokens) throws Exception {
        try {
            /* Pinned, because a consortium's whole point is that a named model
               answered - and a pinned provider is never silently replaced. */
            return text(wallet, prompt, providerName);
        } catch (NoText older) {
            return send(wallet, Provider.of(providerName), model, prompt, maxTokens);
        }
    }

    /**
     * Ask for a paragraph, and let the proxy decide who writes it.
     *
     * The rest of this file is provider-shaped: it sends Anthropic's own body
     * to Anthropic's own path, which is right for a caller that has chosen a
     * provider and wrong for this one. Nothing here has a view on who should
     * answer - it wants an operation written, or a piece of code judged - and
     * choosing meant carrying a table of which models exist, which is a copy
     * of something the proxy knows and goes quietly out of date.
     *
     * So `/text`: one request shape, one response shape, and the provider
     * picked by what it is rated at for the subject. Every call from this
     * project is about code, which is said rather than left to be inferred -
     * the tagger would guess it from the words, and being right by accident is
     * not the same as being right.
     *
     * Escalation is off. The proxy will offer a single model the chance to say
     * the question needs the whole panel, and for this caller that decision is
     * already made elsewhere and made explicitly: Triage decides whether to
     * convene one, and the panel it convenes is a poll rather than a merge.
     * Leaving it on would mean a triage call that could silently become
     * thirteen.
     */
    String text(String wallet, String prompt, String pin) throws Exception {
        var body = new StringBuilder("{\"prompt\":\"").append(Json.escape(prompt))
                .append("\",\"subject\":\"code\",\"escalate\":false");
        if (pin != null && !pin.isBlank()) {
            body.append(",\"provider\":\"").append(Json.escape(pin)).append('"');
        }
        body.append('}');

        var req = HttpRequest.newBuilder(base.resolve("/text"))
                .timeout(Duration.ofMinutes(5))
                .header("Content-Type", "application/json")
                .header("X-Api-Key", wallet)
                .POST(HttpRequest.BodyPublishers.ofString(body.toString()))
                .build();
        var res = http.send(req, HttpResponse.BodyHandlers.ofString());
        if (res.statusCode() == 404) {
            throw new NoText("this proxy has no /text endpoint");
        }
        if (res.statusCode() / 100 != 2) {
            throw new IllegalStateException(
                    "aicoin %d: %s".formatted(res.statusCode(), trim(res.body())));
        }
        var flat = Json.parse(res.body());
        String answer = flat.get("answer");
        if (answer == null || answer.isBlank()) {
            throw new IllegalStateException("no answer in " + trim(res.body()));
        }
        return answer;
    }

    /** Thrown when the proxy predates the capability endpoints. */
    static final class NoText extends Exception {
        NoText(String why) { super(why); }
    }

    private String send(String wallet, Provider provider, String model,
                        String prompt, int maxTokens) throws Exception {
        // Every provider aicoin fronts takes model/messages in this shape, so
        // one template covers them; the proxy forwards it untouched.
        String body = """
                {"model":"%s","%s":%d,"messages":[{"role":"user","content":"%s"}]}"""
                .formatted(model, provider.cap, maxTokens, Json.escape(prompt));

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
     * Ask the wallet's own proxy for an authorisation this backend can show as
     * a code.
     *
     * The alternative is what this replaces: the owner opens their wallet,
     * generates a token, and pastes it into a form. That works, and it puts a
     * long secret through a clipboard and a text field, and what it produces
     * cannot be withdrawn from this one service without withdrawing every
     * token that wallet ever issued.
     *
     * Two things come back and they are not the same. The id is what goes in
     * the code and is what the wallet reads; the secret stays here and is what
     * the token is collected with. Putting both in the code would mean anybody
     * who photographed the screen could collect the token instead of us.
     */
    record Authorisation(String id, String secret) {}

    Authorisation authorize(String service, String note) throws Exception {
        String body = """
                {"service":"%s","note":"%s"}"""
                .formatted(Json.escape(service), Json.escape(note));
        var req = HttpRequest.newBuilder(base.resolve("/wallet/api/authorize/new"))
                .timeout(Duration.ofSeconds(20))
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .build();
        var res = http.send(req, HttpResponse.BodyHandlers.ofString());
        if (res.statusCode() / 100 != 2) {
            throw new IllegalStateException(
                    "aicoin %d: %s".formatted(res.statusCode(), trim(res.body())));
        }
        var flat = Json.parse(res.body());
        String id = flat.get("id");
        String secret = flat.get("secret");
        if (id == null || secret == null) {
            throw new IllegalStateException("no request in " + trim(res.body()));
        }
        return new Authorisation(id, secret);
    }

    /**
     * Has the owner said yes yet? Returns the token once, or null while the
     * answer is still pending.
     *
     * The secret goes in the query rather than a header because this is a
     * plain read of a resource this backend created and holds the only copy of
     * the name for.
     */
    String collect(String id, String secret) throws Exception {
        var req = HttpRequest.newBuilder(base.resolve(
                        "/wallet/api/authorize/" + id + "?secret="
                        + java.net.URLEncoder.encode(secret, java.nio.charset.StandardCharsets.UTF_8)))
                .timeout(Duration.ofSeconds(20))
                .GET()
                .build();
        var res = http.send(req, HttpResponse.BodyHandlers.ofString());
        if (res.statusCode() / 100 != 2) {
            return null;
        }
        var flat = Json.parse(res.body());
        String token = flat.get("token");
        return token == null || token.isBlank() ? null : token;
    }

    /** One panelist's answer to a poll, exactly as it gave it. */
    record Said(String provider, String model, String text) {
        String member() { return provider + "/" + model; }
    }

    /**
     * Ask every model the proxy fronts the same question, separately.
     *
     * This is aicoin's own consortium endpoint in `poll` mode: one request, one
     * turn per panelist, and every answer returned attributed and unmerged. It
     * replaces the fan-out this file used to do by hand - a thread pool over
     * askDirect, one HTTP call per model, and a bench this side had to keep in
     * step with what the proxy could actually reach.
     *
     * The panel is the proxy's business now, which is the point: it knows which
     * providers have keys and which models are current, and a list kept here
     * was a copy of that going quietly out of date. What this side still owns
     * is what the answers mean - see Consortium.
     *
     * Poll rather than the default shape on purpose. The default merges every
     * answer into one and reviews it, which is right for prose and destroys a
     * vote: a gate that has to tell "everyone refused" from "the panel was
     * split" cannot read that out of a merged paragraph.
     */
    java.util.List<Said> poll(String wallet, String prompt, int maxTokens) throws Exception {
        String body = """
                {"prompt":"%s","mode":"poll"}""".formatted(Json.escape(prompt));
        var req = HttpRequest.newBuilder(base.resolve("/consortium"))
                .timeout(Duration.ofMinutes(8))
                .header("Content-Type", "application/json")
                .header("X-Api-Key", wallet)
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .build();
        var res = http.send(req, HttpResponse.BodyHandlers.ofString());
        if (res.statusCode() == 404) {
            // The endpoint is off, or this proxy predates it. Not an error the
            // caller should turn into a verdict: it means "ask the old way".
            throw new NoPoll("this proxy has no consortium endpoint");
        }
        if (res.statusCode() / 100 != 2) {
            throw new IllegalStateException(
                    "aicoin %d: %s".formatted(res.statusCode(), trim(res.body())));
        }
        return answers(res.body());
    }

    /** Thrown when the proxy has no poll to offer, so the caller can fall back. */
    static final class NoPoll extends Exception {
        NoPoll(String why) { super(why); }
    }

    /**
     * The answers out of a poll's reply.
     *
     * Written out rather than regexed because the text is arbitrary: an answer
     * containing a brace or a quoted string breaks any pattern that treats
     * objects as balanced braces, and the answers here are code reviews, which
     * contain both. So the scan tracks whether it is inside a string, the same
     * way the escape-aware reader in Json does.
     */
    static java.util.List<Said> answers(String json) {
        var out = new java.util.ArrayList<Said>();
        int at = json.indexOf("\"answers\":[");
        if (at < 0) return out;
        at += "\"answers\":[".length();
        int depth = 0, start = -1;
        boolean inString = false, escaped = false;
        for (int i = at; i < json.length(); i++) {
            char c = json.charAt(i);
            if (inString) {
                if (escaped) escaped = false;
                else if (c == '\\') escaped = true;
                else if (c == '"') inString = false;
                continue;
            }
            if (c == '"') { inString = true; continue; }
            if (c == '{') { if (depth++ == 0) start = i; continue; }
            if (c == '}') {
                if (--depth == 0 && start >= 0) {
                    var one = Json.parse(json.substring(start, i + 1));
                    String text = one.get("text");
                    if (text != null && !text.isBlank()) {
                        out.add(new Said(one.getOrDefault("provider", "?"),
                                one.getOrDefault("model", "?"), text));
                    }
                    start = -1;
                }
                continue;
            }
            if (c == ']' && depth == 0) break;
        }
        return out;
    }

    /**
     * Pull the reply text out. Providers disagree about where it lives, so try
     * each shape rather than assume one.
     */
    static String extract(String json) {
        /*
         * Anthropic replies are a list of blocks, and with thinking on, the
         * first one is a thinking block whose text lives under a different key.
         * Reading "the text field" out of a flattened object finds the thinking
         * block's empty string and concludes the model said nothing - so find
         * the block that is actually a text block, by its type.
         */
        var m = TEXT_BLOCK.matcher(json);
        if (m.find()) {
            String t = Json.unescape(m.group(1));
            if (!t.isBlank()) return t;
        }
        // A refusal is an answer. Saying so beats "no reply text in {...}",
        // which reads like a transport fault and sends people to look at the
        // network.
        if (json.contains("\"stop_reason\":\"refusal\"")) {
            throw new IllegalStateException("the model declined to answer: " + trim(json));
        }
        if (json.contains("\"finish_reason\": \"length\"")
                || json.contains("\"stop_reason\":\"max_tokens\"")) {
            throw new IllegalStateException("the model ran out of output room before answering");
        }
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

    private static final java.util.regex.Pattern TEXT_BLOCK = java.util.regex.Pattern.compile(
            "\"type\"\\s*:\\s*\"text\"\\s*,\\s*\"text\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");

    private static String trim(String s) {
        return s.length() <= 400 ? s : s.substring(0, 400) + "...";
    }
}
