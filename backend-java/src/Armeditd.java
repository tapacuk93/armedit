import io.netty.bootstrap.ServerBootstrap;
import io.netty.buffer.Unpooled;
import io.netty.channel.ChannelFutureListener;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelInitializer;
import io.netty.channel.ChannelOption;
import io.netty.channel.SimpleChannelInboundHandler;
import io.netty.channel.nio.NioEventLoopGroup;
import io.netty.channel.socket.SocketChannel;
import io.netty.channel.socket.nio.NioServerSocketChannel;
import io.netty.handler.codec.http.DefaultFullHttpResponse;
import io.netty.handler.codec.http.FullHttpRequest;
import io.netty.handler.codec.http.HttpHeaderNames;
import io.netty.handler.codec.http.HttpHeaderValues;
import io.netty.handler.codec.http.HttpObjectAggregator;
import io.netty.handler.codec.http.HttpResponseStatus;
import io.netty.handler.codec.http.HttpServerCodec;
import io.netty.handler.codec.http.HttpVersion;
import io.netty.handler.codec.http.QueryStringDecoder;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.Function;

/**
 * armeditd - the armedit backend, on Netty.
 *
 * The only process in the system that holds credentials. It serves the
 * registration page, issues the one key a device carries, spends the account's
 * aicoin on its behalf, and provisions the account's infrastructure. Devices
 * hold that key and know none of the rest: not which model answered, not which
 * provider aicoin routed to, not the credentials behind their instance.
 *
 * Netty for the same reason aicoin-proxy uses it - and with the same care
 * about what runs where: a Cmd+P can take minutes upstream, so every route
 * runs on a virtual thread and the event loop is left free. The channel write
 * comes back from that thread, which Netty allows.
 *
 * Endpoints:
 *   GET  /                 registration page
 *   GET  /api/health
 *   POST /api/register     {wallet, aws_key, aws_secret, region, password} -> {key}
 *   POST /api/agent        X-Armedit-Key; {mode, context, baseline, cursor} -> {text}
 *   POST /api/session      X-Armedit-Key -> {instance}
 *   POST /api/teardown     X-Armedit-Key -> {instance:""}
 *   POST /api/journal      X-Armedit-Key; one edit or one gesture
 *   GET/POST /api/clouds   X-Armedit-Key; bind or list cloud credentials
 *   GET  /api/otp          X-Armedit-Key -> pad accounting for this account
 *   POST /api/otp/reserve  X-Armedit-Key -> {pad, bits, window}
 */
public final class Armeditd {

    private static final int MAX_BODY = 1 << 20;

    private final Accounts accounts = new Accounts();
    private final Aicoin aicoin;
    private final Aws aws;
    private final Workspace workspace;
    private final AwsAgent agent;
    private final Journal journal;
    private final Runner runner;
    private final Agents agents;
    private final String publicAddr;

    private Armeditd() {
        this.aicoin = new Aicoin(
                env("ARMEDIT_AICOIN", "http://127.0.0.1:8081"),
                env("ARMEDIT_PROVIDER", "anthropic"),
                env("ARMEDIT_MODEL", ""));
        this.aws = new Aws(
                env("ARMEDIT_AWS_ADDR", ""),
                env("ARMEDIT_AMI", ""),
                env("ARMEDIT_INSTANCE_TYPE", ""));
        var root = java.nio.file.Path.of(env("ARMEDIT_WORKSPACE", "workspaces"));
        this.workspace = new Workspace(root, aws, env("ARMEDIT_S3_BUCKET", ""));
        this.agent = new AwsAgent(aws, root);
        this.journal = new Journal(root);
        this.agents = new Agents(root);
        this.publicAddr = env("ARMEDIT_PUBLIC_ADDR", "");
        // Machines post their output back here, so they need an address that
        // works from outside this host.
        this.runner = new Runner(aws, root,
                env("ARMEDIT_CALLBACK", publicAddr.isBlank()
                        ? "http://127.0.0.1:" + env("ARMEDIT_PORT", "8080")
                        : "https://" + publicAddr));
    }

    /* ------------------------------------------------------------ transport */

    /** One request, with nothing Netty-shaped left in it. */
    record Req(String method, String path, Function<String, String> header, String body) {
        boolean isPost() { return "POST".equalsIgnoreCase(method); }
    }

    /** One response, ready to be written by whatever is carrying it. */
    record Res(int status, String contentType, byte[] body) {
        static Res json(int status, String body) {
            return new Res(status, "application/json", body.getBytes(StandardCharsets.UTF_8));
        }

        static Res html(String body) {
            return new Res(200, "text/html; charset=utf-8", body.getBytes(StandardCharsets.UTF_8));
        }
    }

    public static void main(String[] args) throws Exception {
        int port = Integer.parseInt(env("ARMEDIT_PORT", "8080"));
        var app = new Armeditd();
        app.startReaper();

        // One thread accepting, a small pool reading and writing, and virtual
        // threads doing the work. Nothing that can block belongs on the loops.
        var boss = new NioEventLoopGroup(1);
        var workers = new NioEventLoopGroup();
        ExecutorService jobs = Executors.newVirtualThreadPerTaskExecutor();

        try {
            var b = new ServerBootstrap()
                    .group(boss, workers)
                    .channel(NioServerSocketChannel.class)
                    .option(ChannelOption.SO_BACKLOG, 128)
                    .childOption(ChannelOption.TCP_NODELAY, true)
                    .childHandler(new ChannelInitializer<SocketChannel>() {
                        @Override
                        protected void initChannel(SocketChannel ch) {
                            ch.pipeline()
                              .addLast(new HttpServerCodec())
                              .addLast(new HttpObjectAggregator(MAX_BODY))
                              .addLast(new Gate(app, jobs));
                        }
                    });

            var channel = b.bind(port).sync().channel();
            System.out.printf("armedit backend on :%d - register at / to bind a wallet and cloud access%n",
                    port);
            channel.closeFuture().sync();
        } finally {
            jobs.shutdown();
            workers.shutdownGracefully();
            boss.shutdownGracefully();
        }
    }

    /**
     * The one Netty handler: translate, hand off to a virtual thread, write
     * back whatever it returns.
     */
    private static final class Gate extends SimpleChannelInboundHandler<FullHttpRequest> {

        private final Armeditd app;
        private final ExecutorService jobs;

        Gate(Armeditd app, ExecutorService jobs) {
            this.app = app;
            this.jobs = jobs;
        }

        @Override
        protected void channelRead0(ChannelHandlerContext ctx, FullHttpRequest msg) {
            var req = new Req(
                    msg.method().name(),
                    new QueryStringDecoder(msg.uri()).path(),
                    name -> msg.headers().get(name),
                    msg.content().toString(StandardCharsets.UTF_8));

            jobs.execute(() -> {
                Res res;
                try {
                    res = app.dispatch(req);
                } catch (Exception x) {
                    // Never let a handler's failure become a hung connection.
                    System.out.printf("armedit: %s %s failed: %s%n", req.method(), req.path(), x);
                    res = Res.json(500, Json.obj("error", "internal error"));
                }
                write(ctx, res);
            });
        }

        private static void write(ChannelHandlerContext ctx, Res res) {
            var out = new DefaultFullHttpResponse(
                    HttpVersion.HTTP_1_1,
                    HttpResponseStatus.valueOf(res.status()),
                    Unpooled.wrappedBuffer(res.body()));
            out.headers().set(HttpHeaderNames.CONTENT_TYPE, res.contentType());
            out.headers().setInt(HttpHeaderNames.CONTENT_LENGTH, res.body().length);
            out.headers().set(HttpHeaderNames.CONNECTION, HttpHeaderValues.CLOSE);
            ctx.writeAndFlush(out).addListener(ChannelFutureListener.CLOSE);
        }

        @Override
        public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
            ctx.close();
        }
    }

    /** Path to handler. Flat, because the surface is small and stays that way. */
    private Res dispatch(Req r) {
        return switch (r.path()) {
            case "/", "/index.html" -> Res.html(Page.HTML);
            case "/api/health" -> Res.json(200, Json.obj("ok", true));
            case "/api/register" -> routeRegister(r);
            case "/api/agent" -> routeAgent(r);
            case "/api/session" -> routeSession(r, true);
            case "/api/teardown" -> routeSession(r, false);
            case "/api/journal" -> routeJournal(r);
            case "/api/clouds" -> routeClouds(r);
            case "/api/otp" -> routeOtp(r);
            case "/api/otp/reserve" -> routeOtpReserve(r);
            case "/api/run/result" -> routeRunResult(r);
            case "/api/agents" -> routeAgentsList(r);
            case "/api/agents/register" -> routeAgentRegister(r);
            case "/api/agents/poll" -> routeAgentPoll(r);
            case "/api/agents/result" -> routeAgentResult(r);
            default -> Res.json(404, Json.obj("error", "no such endpoint"));
        };
    }

    /* -------------------------------------------------------------- reaper */

    /**
     * Instances are billed by the hour whether or not anyone is typing, so an
     * account that has gone quiet gets its machine taken away. Every
     * authorised request counts as activity; the sweep runs on its own
     * scheduler rather than piggybacking on request traffic, because an idle
     * account by definition sends none.
     */
    private void startReaper() {
        long idleMinutes = Long.parseLong(env("ARMEDIT_IDLE_MINUTES", "30"));
        long everySeconds = Long.parseLong(env("ARMEDIT_REAP_SECONDS", "60"));
        if (idleMinutes <= 0) {
            System.out.println("armedit: idle reaping disabled");
            return;
        }
        var reaper = Executors.newSingleThreadScheduledExecutor(r -> {
            var t = new Thread(r, "armedit-reaper");
            t.setDaemon(true);
            return t;
        });
        reaper.scheduleWithFixedDelay(() -> sweep(idleMinutes), everySeconds, everySeconds,
                java.util.concurrent.TimeUnit.SECONDS);
        System.out.printf("armedit: reaping instances idle for %d minutes%n", idleMinutes);
    }

    private void sweep(long idleMinutes) {
        // Health is checked on the same schedule as the instance reaping, so
        // the model's picture of what is reachable is never older than a
        // sweep: an agent that stopped calling in is reported gone.
        for (var a : agents.stale()) {
            System.out.printf("armedit: agent %s has not called in for %ds%n",
                    a.name, a.idleMillis() / 1000);
        }
        long limit = idleMinutes * 60_000L;
        for (var account : accounts.all()) {
            if (account.instance().isBlank() || account.idleMillis() < limit) continue;
            try {
                String was = account.instance();
                aws.deprovision(account);
                System.out.printf("armedit: %s idle %d min, terminated %s%n",
                        account.id(), account.idleMillis() / 60_000L, was);
            } catch (Exception x) {
                // Leave it for the next sweep rather than forgetting an
                // instance that is still running and still costing money.
                System.out.printf("armedit: %s could not be reaped: %s%n", account.id(), x.getMessage());
            }
        }
    }

    /* ------------------------------------------------------------- routing */

    /**
     * Registration. Both accesses or nothing: an account without a wallet
     * token cannot pay for a call, and one without cloud credentials cannot be
     * given an instance.
     *
     * The key we hand back carries the address to reach us at, so a device
     * needs exactly one property and no separate endpoint setting.
     */
    private Res routeRegister(Req r) {
        if (!r.isPost()) return Res.json(405, Json.obj("error", "POST only"));
        var in = Json.parse(r.body());
        String wallet = in.getOrDefault("wallet", "").trim();
        String awsKey = in.getOrDefault("aws_key", "").trim();
        String awsSecret = in.getOrDefault("aws_secret", "").trim();
        String region = in.getOrDefault("region", "").trim();
        String password = in.getOrDefault("password", "");

        if (wallet.isEmpty() || awsKey.isEmpty() || awsSecret.isEmpty()) {
            return Res.json(400, Json.obj("error",
                    "an account needs both an aicoin wallet token and AWS access"));
        }
        if (region.isEmpty()) region = "us-east-1";
        if (password.isEmpty()) {
            return Res.json(400, Json.obj("error",
                    "a password is required: it seeds this account's pad"));
        }

        var issued = accounts.create(wallet, awsKey, awsSecret, region, password);

        // AWS is bound like any other cloud, so the chooser can compare it
        // against whatever else this account adds later.
        issued.account().clouds().bind(Clouds.Provider.AWS,
                Map.of("access_key", awsKey, "secret_key", awsSecret, "region", region));

        String key = publicAddr.isBlank() ? issued.key() : issued.key() + "@" + publicAddr;
        return Res.json(200, Json.obj("key", key));
    }

    /**
     * The editor's one call. It sends the screen and gets text back; which
     * model answered, and what had to be done to answer, is decided here.
     */
    private Res routeAgent(Req r) {
        if (!r.isPost()) return Res.json(405, Json.obj("error", "POST only"));
        var account = authorise(r);
        if (account == null) return unauthorised();

        var in = Json.parse(r.body());
        String mode = in.getOrDefault("mode", "agent");
        String context = in.getOrDefault("context", "");
        String baseline = in.getOrDefault("baseline", "");
        String cursor = in.getOrDefault("cursor", "");
        int screen = parseInt(in.getOrDefault("screen", "1"), 1);

        // Memory to disk to cloud: handed to the writer thread, not waited on.
        workspace.save(account, screen, context);

        // Everything that crosses the link counts towards this account's bit
        // ledger, whether or not the pad is carrying it.
        account.otp().account((long) (context.length() + baseline.length()) * 8);

        var prompt = new StringBuilder();
        prompt.append(switch (mode) {
            case "aify" -> """
                    You are inside armedit, a text editor. Your reply is inserted at the caret; \
                    everything else on the screen stays exactly as it is, so do not repeat it. \
                    Carry out whatever the user's latest edit asks for and reply with only the text \
                    that belongs at the caret - no preamble, no fences.""";
            default -> """
                    You are inside armedit, a text editor. The user asked about this screen. \
                    Answer plainly.""";
        });
        prompt.append("""
                 Use only ASCII letters, digits and simple punctuation - the editor renders a 5x7 \
                bitmap font and cannot draw anything else.

                """);
        if (!baseline.isBlank()) {
            prompt.append("PREVIOUS VERSION OF THIS SCREEN:\n").append(baseline).append("\n\n");
        }
        if (!cursor.isBlank()) {
            prompt.append("THE CARET IS AT BYTE OFFSET ").append(cursor).append("\n\n");
        }
        prompt.append(journal.briefing(account, screen));
        prompt.append(runner.briefing(account));
        prompt.append(agents.briefing(account)).append('\n');
        prompt.append(account.clouds().briefing()).append('\n');
        prompt.append(Machines.briefing(account.clouds().available()));
        prompt.append(AwsAgent.briefing(account.region())).append('\n');
        prompt.append("CURRENT SCREEN:\n").append(context);

        // The router picks a starting model from the state of the screen; the
        // model may hand over once it knows more than the router did.
        var tier = Router.choose(mode, context, baseline);
        String base = prompt.toString();

        try {
            String text = "";
            for (int hop = 0; hop <= Router.MAX_HANDOFFS; hop++) {
                text = aicoin.ask(account.wallet(), tier,
                        base + "\n\n" + Router.briefing(tier), 16000);

                var handoff = Router.requested(text);
                if (handoff == null || hop == Router.MAX_HANDOFFS) break;
                System.out.printf("armedit: %s handing %s -> %s (%s)%n",
                        account.id(), tier.name(), handoff.to().name(), handoff.reason());
                base = base + "\n\n" + "%s looked at this and handed it to you: %s"
                        .formatted(tier.name(), handoff.reason());
                tier = handoff.to();
            }
            text = Router.withoutHandoff(text);

            // Anything the model asked a cloud for runs here, signed with this
            // account's credentials, and only the results go back upstream.
            var outcome = agent.run(account, text);
            var runs = runner.run(account, text);
            var onAgents = agents.run(account, text);
            String results = outcome.transcript() + runs.transcript() + onAgents.transcript();
            if (!results.isBlank()) {
                String followUp = base + "\n\nYOUR REPLY:\n" + text
                        + "\n\nRESULTS:\n" + results
                        + "\nNow answer the user with what you found. Do not repeat the raw output.";
                text = AwsAgent.redact(aicoin.ask(account.wallet(), tier, followUp, 16000));
            }

            account.otp().account((long) text.length() * 8);
            return Res.json(200, Json.obj("text", text, "model", tier.name()));
        } catch (Exception x) {
            return Res.json(502, Json.obj("error", "aicoin: " + x.getMessage()));
        }
    }

    /**
     * The editor reporting what happened: every edit including removals, and
     * every gesture. Stored per screen and fed back into the next prompt.
     */
    private Res routeJournal(Req r) {
        if (!r.isPost()) return Res.json(405, Json.obj("error", "POST only"));
        var account = authorise(r);
        if (account == null) return unauthorised();

        var in = Json.parse(r.body());
        int screen = parseInt(in.getOrDefault("screen", "1"), 1);
        long now = System.currentTimeMillis();

        // One event per request keeps the client trivial; the editor batches
        // them rather than the protocol doing it.
        String op = in.get("op");
        if (op != null && !op.isBlank()) {
            journal.edits(account, screen, java.util.List.of(new Journal.Edit(
                    now, op, parseInt(in.getOrDefault("at", "0"), 0),
                    in.getOrDefault("text", ""))));
        }
        String kind = in.get("kind");
        if (kind != null && !kind.isBlank()) {
            journal.gestures(account, screen, java.util.List.of(new Journal.Gesture(
                    now, kind, parseInt(in.getOrDefault("at", "0"), 0),
                    in.getOrDefault("word", ""),
                    parseInt(in.getOrDefault("dx", "0"), 0),
                    parseInt(in.getOrDefault("dy", "0"), 0))));
        }
        return Res.json(200, Json.obj("ok", true));
    }

    /**
     * A provisioned machine reporting what its command did.
     *
     * Authenticated by the one-time token baked into its cloud-init and
     * nothing else: a machine can report one result and has no other authority
     * here. No account key ever reaches a provisioned machine.
     */
    private Res routeRunResult(Req r) {
        if (!r.isPost()) return Res.json(405, Json.obj("error", "POST only"));
        var in = Json.parse(r.body());
        String token = in.getOrDefault("token", "");
        int code = parseInt(in.getOrDefault("code", "-1"), -1);
        String output = in.getOrDefault("output", "");
        boolean known = runner.result(token, code, output);
        return known ? Res.json(200, Json.obj("ok", true))
                     : Res.json(404, Json.obj("error", "unknown run"));
    }

    /* -------------------------------------------------------------- agents */

    /**
     * A machine volunteering itself. The account's key authorises the
     * registration; after that the agent has a token of its own and the key
     * never travels again.
     */
    private Res routeAgentRegister(Req r) {
        if (!r.isPost()) return Res.json(405, Json.obj("error", "POST only"));
        var account = authorise(r);
        if (account == null) return unauthorised();
        var in = Json.parse(r.body());
        var agent = agents.register(account,
                in.getOrDefault("name", "agent"),
                in.getOrDefault("os", "?"),
                in.getOrDefault("arch", "?"),
                Agents.Access.of(in.get("access")));
        System.out.printf("armedit: %s registered agent %s (%s %s, %s)%n",
                account.id(), agent.name, agent.os, agent.arch, agent.access.id);
        return Res.json(200, Json.obj("agent", agent.id, "token", agent.token,
                "access", agent.access.id));
    }

    /** What should this machine do next? Every poll is also a sign of life. */
    private Res routeAgentPoll(Req r) {
        if (!r.isPost()) return Res.json(405, Json.obj("error", "POST only"));
        var in = Json.parse(r.body());
        var agent = agents.byToken(in.get("token")).orElse(null);
        if (agent == null) return Res.json(401, Json.obj("error", "unknown agent token"));
        var job = agents.take(agent);
        return job == null
                ? Res.json(200, Json.obj("job", "", "command", ""))
                : Res.json(200, Json.obj("job", job.id, "command", job.command));
    }

    private Res routeAgentResult(Req r) {
        if (!r.isPost()) return Res.json(405, Json.obj("error", "POST only"));
        var in = Json.parse(r.body());
        var agent = agents.byToken(in.get("token")).orElse(null);
        if (agent == null) return Res.json(401, Json.obj("error", "unknown agent token"));
        agent.seen();
        agents.complete(in.getOrDefault("job", ""),
                parseInt(in.getOrDefault("code", "-1"), -1),
                in.getOrDefault("output", ""));
        return Res.json(200, Json.obj("ok", true));
    }

    /** What this account has connected, and whether it is actually there. */
    private Res routeAgentsList(Req r) {
        var account = authorise(r);
        if (account == null) return unauthorised();
        var b = new StringBuilder("[");
        boolean first = true;
        for (var a : agents.of(account)) {
            if (!first) b.append(',');
            first = false;
            b.append(Json.obj("name", a.name, "id", a.id, "os", a.os, "arch", a.arch,
                    "access", a.access.id, "connected", a.connected(),
                    "idle_seconds", a.idleMillis() / 1000));
        }
        b.append(']');
        return new Res(200, "application/json", b.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
    }

    private Res routeSession(Req r, boolean up) {
        if (!r.isPost()) return Res.json(405, Json.obj("error", "POST only"));
        var account = authorise(r);
        if (account == null) return unauthorised();
        try {
            if (up) aws.provision(account);
            else aws.deprovision(account);
            return Res.json(200, Json.obj("instance", account.instance()));
        } catch (Exception x) {
            return Res.json(502, Json.obj("error", "ec2: " + x.getMessage()));
        }
    }

    /**
     * Bind another cloud to this account, or ask which ones are bound.
     *
     * The homepage posts here once per provider. Credentials are held in this
     * process exactly like the AWS ones, and are subject to the same rule: the
     * model learns provider *names* and prices, never a credential.
     */
    private Res routeClouds(Req r) {
        var account = authorise(r);
        if (account == null) return unauthorised();

        if (!r.isPost()) {
            var names = new StringBuilder();
            for (var p : account.clouds().available()) {
                if (names.length() > 0) names.append(',');
                names.append(p.id);
            }
            return Res.json(200, Json.obj("bound", names.toString()));
        }

        var in = Json.parse(r.body());
        var provider = Clouds.Provider.of(in.get("provider"));
        if (provider == null) return Res.json(400, Json.obj("error", "unknown provider"));

        var fields = new java.util.LinkedHashMap<String, String>();
        for (var f : provider.fields) fields.put(f, in.getOrDefault(f, ""));
        account.clouds().bind(provider, fields);
        return Res.json(200, Json.obj("provider", provider.id,
                "complete", account.clouds().has(provider)));
    }

    /* ---------------------------------------------------------------- otp */

    /**
     * What the ledger says right now. Both ends derive the same window
     * boundaries, so this is a check, not a source of truth.
     */
    private Res routeOtp(Req r) {
        var account = authorise(r);
        if (account == null) return unauthorised();
        var otp = account.otp();
        return Res.json(200, Json.obj(
                "bits", otp.bitsTransferred(),
                "reservations", otp.reservationsIssued(),
                "pad_bytes_left", otp.padRemaining(),
                "bits_until_reservation", otp.bitsUntilReservation(),
                "is_reservation", otp.isReservation(otp.bitsTransferred())));
    }

    /** Hand over the next pad segment. Real randomness, exactly once. */
    private Res routeOtpReserve(Req r) {
        if (!r.isPost()) return Res.json(405, Json.obj("error", "POST only"));
        var account = authorise(r);
        if (account == null) return unauthorised();
        var otp = account.otp();
        byte[] pad = otp.reserve();
        return Res.json(200, Json.obj(
                "pad", Base64.getEncoder().encodeToString(pad),
                "bits", otp.bitsTransferred(),
                "window", Otp.RESERVATION_BITS));
    }

    /* ------------------------------------------------------------ helpers */

    /**
     * The key may arrive with the backend address appended - that is what lets
     * a device carry one property - so match on the part before the '@'.
     */
    private Accounts.Account authorise(Req r) {
        String key = r.header().apply("X-Armedit-Key");
        if (key != null) {
            int at = key.indexOf('@');
            if (at >= 0) key = key.substring(0, at);
        }
        var account = accounts.byKey(key).orElse(null);
        if (account != null) account.touch();   /* what keeps its instance alive */
        return account;
    }

    private static Res unauthorised() {
        return Res.json(401, Json.obj("error", "unknown or missing armedit key"));
    }

    private static int parseInt(String s, int fallback) {
        try {
            return Integer.parseInt(s.trim());
        } catch (Exception x) {
            return fallback;
        }
    }

    private static String env(String name, String fallback) {
        String v = System.getenv(name);
        return (v == null || v.isBlank()) ? fallback : v.trim();
    }
}
