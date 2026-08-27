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
    private final ModelStats stats = new ModelStats();
    private final Cache cache = new Cache();
    private final Scripts scripts = new Scripts();
    private final Behaviours behaviours;
    private final Catalogue catalogue;
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
        this.behaviours = new Behaviours(root);
        this.catalogue = new Catalogue(env("ARMEDIT_AICOIN", "http://127.0.0.1:8081"),
                java.util.List.of("anthropic", "openai", "google", "mistral", "cohere"));
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
        // Ask the proxy what it can reach rather than assuming: a hardcoded
        // model list is wrong the day a provider ships, and wrong silently.
        app.catalogue.start(app.accounts::anyWallet);

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
            case "/api/stats" -> routeStats(r);
            case "/api/behaviours" -> routeBehaviours(r);
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
        String selection = in.getOrDefault("selection", "");
        String instruction = in.getOrDefault("instruction", "");
        String subject = in.getOrDefault("subject", "");
        int screen = parseInt(in.getOrDefault("screen", "1"), 1);

        // Memory to disk to cloud: handed to the writer thread, not waited on.
        workspace.save(account, screen, context);

        // Everything that crosses the link counts towards this account's bit
        // ledger, whether or not the pad is carrying it.
        account.otp().account((long) (context.length() + baseline.length()) * 8);

        var prompt = new StringBuilder();
        // A swipe is a gesture, and the history should say the user made it:
        // "they swiped over these words" is a different record from "the text
        // changed", and only one of them survives in the file itself.
        if ("swipe".equals(mode) && !selection.isBlank()) {
            journal.gestures(account, screen, java.util.List.of(new Journal.Gesture(
                    System.currentTimeMillis(), "swipe-select",
                    parseInt(cursor.isBlank() ? "0" : cursor, 0),
                    selection.length() > 80 ? selection.substring(0, 80) + "..." : selection,
                    0, 0)));
        }

        prompt.append(switch (mode) {
            case "swipe" -> """
                    You are inside armedit, a text editor. The user swiped across some words \
                    and wants something done with them - they did not say what, and the gesture \
                    is the whole request. Work out from the words themselves, the surrounding \
                    screen and what they have been doing what would actually help: explain it, \
                    fix it, look it up, run it, rewrite it. Do that thing. If the only honest \
                    answer is that it is not clear, say so in one line rather than guessing at \
                    length.""";
            case "aify" -> """
                    You are inside armedit, a text editor. The user wrote an instruction and it \
                    is about to be REPLACED by your reply, in place, where it stands. Produce \
                    exactly what should be there instead of it and nothing else - no preamble, no \
                    explanation, no fences, no restating the instruction. If they wrote \
                    "c hello world", reply with the C program itself. If they wrote "make this \
                    shorter" over some text, reply with the shorter text. Whatever you send is \
                    what they will be looking at.""";
            default -> """
                    You are inside armedit, a text editor. The user asked about this screen. \
                    Answer plainly.""";
        });
        prompt.append("""
                 Use only ASCII letters, digits and simple punctuation - the editor renders a 5x7 \
                bitmap font and cannot draw anything else.

                Anything written as $$name is a reference to text you cannot see and will never \
                be shown. Treat it as a name for something that is there: write $$name where the \
                thing belongs and the editor puts the real content in on its side. Do not ask \
                what is in it, do not guess at it, and do not work around it by inventing a \
                value - $$name is the answer, and it resolves where you cannot reach.

                """);
        if (!baseline.isBlank()) {
            prompt.append("PREVIOUS VERSION OF THIS SCREEN:\n").append(baseline).append("\n\n");
        }
        if (!cursor.isBlank()) {
            prompt.append("THE CARET IS AT BYTE OFFSET ").append(cursor).append("\n\n");
        }
        if (!selection.isBlank()) {
            prompt.append("THE USER SWIPED OVER THIS:\n").append(selection).append("\n\n");
        }
        if (!instruction.isBlank()) {
            prompt.append("THIS IS WHAT YOUR REPLY WILL REPLACE:\n")
                  .append(instruction).append("\n\n");
        }
        prompt.append(journal.briefing(account, screen));
        prompt.append(runner.briefing(account));
        prompt.append(agents.briefing(account)).append('\n');
        prompt.append(account.clouds().briefing()).append('\n');
        prompt.append(Machines.briefing(account.clouds().available()));
        prompt.append(AwsAgent.briefing(account.region())).append('\n');
        prompt.append("CURRENT SCREEN:\n").append(context);

        // A screen bound to a widget is not asking for text: what is typed
        // there is how that kind of thing should behave.  A screen bound to a
        // word is the opposite - "make it faster" there is about the build,
        // not about words in general - so only widgets take this path.
        if ("aify".equals(mode) && isWidgetSubject(subject) && !instruction.isBlank()) {
            try {
                String said = authorBehaviour(account, subject, instruction,
                        Router.byName("sonnet") == null ? Router.cheapest() : Router.byName("sonnet"));
                journal.edits(account, screen, java.util.List.of(new Journal.Edit(
                        System.currentTimeMillis(), "behaviour", 0, said)));
                return Res.json(200, Json.obj("text", said, "model", "behaviour"));
            } catch (Exception x) {
                return Res.json(502, Json.obj("error", "behaviour: " + x.getMessage()));
            }
        }

        // Somebody may already have paid for this one.  Only ever true when
        // nothing of theirs went into the asking - see Cache.shareable.
        boolean shareable = Cache.shareable(instruction, context, baseline, selection, subject);
        String cacheKey = null;
        if (shareable) {
            cacheKey = Cache.key(mode, instruction, context, baseline, selection, subject);
            var hit = cache.get(cacheKey);
            if (hit != null) {
                journal.edits(account, screen, java.util.List.of(new Journal.Edit(
                        System.currentTimeMillis(), "cached", 0, instruction)));
                return Res.json(200, Json.obj("text", hit.text(),
                        "model", hit.model(), "cached", true));
            }

            // Nobody asked this exact thing before, but a model may have
            // recognised the kind of thing it is and left an answer for it.
            // This is the fast path: no upstream call at all.
            var scripted = scripts.lookup(new Scripts.Ctx(
                    mode, instruction, context, selection, subject));
            if (scripted != null) {
                journal.edits(account, screen, java.util.List.of(new Journal.Edit(
                        System.currentTimeMillis(), "scripted", 0, instruction)));
                return Res.json(200, Json.obj("text", scripted.text(),
                        "model", scripted.script().author(), "scripted", true,
                        "script", scripted.script().name()));
            }
        }

        // What kind of work is this, and who has done it well before?
        var category = ModelStats.classify(mode, context);
        var names = new java.util.ArrayList<String>();
        for (var t : Router.TIERS) names.add(t.name());

        var tier = Router.choose(mode, context, baseline);
        String preferred = stats.best(category, names);
        if (preferred != null && !preferred.equals(tier.name())) {
            var better = Router.byName(preferred);
            // Only let the record override upwards from the cheapest choice:
            // a model with a good record on this category earns the work, but
            // a single bad run should not strand everything on the big model.
            if (better != null && stats.of(preferred, category).calls() >= 3) tier = better;
        }

        // Each model is told what the others are for, and what the record
        // says about them, so a handoff is a decision rather than a guess.
        String base = prompt.toString()
                + "\n\n" + catalogue.briefing()
                + stats.briefing(names, category)
                + (shareable ? scripts.briefing() : "");

        // A second ask about the same screen within a minute is rarely a
        // compliment to the answer that came first, so it counts against
        // whoever gave it - not against whoever is about to try again.
        if (account.lastAsk(category.id, screen) && !account.lastModel().isBlank()) {
            stats.reasked(account.lastModel(), category);
        }

        try {
            String text = "";
            for (int hop = 0; hop <= Router.MAX_HANDOFFS; hop++) {
                long began = System.currentTimeMillis();
                try {
                    text = aicoin.ask(account.wallet(), tier,
                            base + "\n\n" + Router.briefing(tier), 16000);
                } catch (Exception inner) {
                    stats.failed(tier.name(), category);
                    throw inner;
                }
                stats.called(tier.name(), category, System.currentTimeMillis() - began, text.length());

                var handoff = Router.requested(text);
                if (handoff == null || hop == Router.MAX_HANDOFFS) break;
                stats.handedAway(tier.name(), category);
                stats.handedTo(handoff.to().name(), category);
                System.out.printf("armedit: %s handing %s -> %s (%s)%n",
                        account.id(), tier.name(), handoff.to().name(), handoff.reason());
                base = base + "\n\n" + "%s looked at this and handed it to you: %s"
                        .formatted(tier.name(), handoff.reason());
                tier = handoff.to();
            }
            text = Router.withoutHandoff(text);

            // Whatever it decided was worth remembering, remember - then take
            // the teaching back out, because the user asked for an answer and
            // not for a transcript of the model talking to the server.
            for (var taught : scripts.learn(text, tier.name(), shareable)) {
                System.out.printf("armedit: %s taught \"%s\" -> %s (%s)%n",
                        tier.name(), taught.pattern(), taught.name(),
                        taught.code() != null ? "compiled" : taught.body().length() + "-byte template");
            }
            text = Scripts.without(text);

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
            account.lastModel(tier.name());
            if (cacheKey != null) {
                // Nothing here was marked private, so the next person to ask
                // for the same thing gets this without paying for it again.
                cache.put(cacheKey, text, tier.name());
            }
            if ("swipe".equals(mode) && !selection.isBlank()) {
                journal.edits(account, screen, java.util.List.of(new Journal.Edit(
                        System.currentTimeMillis(), "ai-swipe",
                        parseInt(cursor.isBlank() ? "0" : cursor, 0),
                        text.length() > 200 ? text.substring(0, 200) + "..." : text)));
            }
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

    /**
     * The behaviours every client starts with: the winning rule for each
     * gesture, in the three-words-and-a-number form a client with no JSON
     * parser can read. `?format=json` gives the same thing with weights, for
     * anyone looking rather than executing.
     */
    private Res routeBehaviours(Req r) {
        var account = authorise(r);
        if (account == null) return unauthorised();
        if ("json".equals(r.header().apply("X-Armedit-Format"))) {
            return new Res(200, "application/json",
                    behaviours.asJson().getBytes(StandardCharsets.UTF_8));
        }
        return new Res(200, "text/plain", behaviours.asText().getBytes(StandardCharsets.UTF_8));
    }

    /**
     * A rule someone typed on a screen bound to a thing.
     *
     * This is what makes Cmd+P on such a screen different: the sentence is not
     * a request for text, it is a request for behaviour, so it goes to the
     * model to be turned into one of the verbs the client can actually do, and
     * the reply the user sees is what was understood - not prose about it.
     */
    private String authorBehaviour(Accounts.Account account, String subject,
                                   String sentence, Router.Tier tier) throws Exception {
        String reply = aicoin.ask(account.wallet(), tier,
                behaviours.translationPrompt(sentence, subject), 400);
        var rule = behaviours.parse(reply, sentence);
        if (rule == null) {
            return "NOT UNDERSTOOD AS A BEHAVIOUR:\n" + sentence
                    + "\n\nTHE EDITOR CAN ONLY MOVE, RESIZE, HIGHLIGHT, OPEN, ASK OR REWRITE.\n";
        }
        behaviours.author(account.id(), rule.target, rule.trigger, rule.verb, sentence);
        return "%s %s -> %s\nNOW THE DEFAULT FOR EVERYONE, BY WEIGHT %d.\n"
                .formatted(rule.target.id, rule.trigger.id, rule.verb.id, rule.weight);
    }

    /**
     * What the record says. Behaviour, not grades: nobody scores the answers,
     * so this counts handoffs, re-asks, failures and latency and orders by
     * them.
     */
    private Res routeStats(Req r) {
        var account = authorise(r);
        if (account == null) return unauthorised();
        var body = "{\"models\":" + stats.asJson()
                + ",\"catalogue\":" + catalogue.models().size()
                + ",\"catalogue_error\":\"" + Json.escape(catalogue.lastError()) + "\"}";
        return new Res(200, "application/json", body.getBytes(StandardCharsets.UTF_8));
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

    /** Widgets take behaviour; content takes instructions. */
    private static boolean isWidgetSubject(String subject) {
        if (subject == null || subject.isBlank()) return false;
        String s = subject.toLowerCase(java.util.Locale.ROOT);
        return s.startsWith("image") || s.startsWith("key") || s.startsWith("applet")
                || s.startsWith("button") || s.equals("keyboard")
                || s.startsWith("video") || s.startsWith("widget");
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
