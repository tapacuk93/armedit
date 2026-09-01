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
    private final Consensus consensus = new Consensus();
    private final Behaviours behaviours;
    private final Catalogue catalogue;
    private final Fetch fetcher = new Fetch();
    private final Consortium consortium;
    private final Distro distro;
    private final String publicAddr;
    /** Promotion is slow and nobody is waiting for it. */
    private final ExecutorService promoter = Executors.newVirtualThreadPerTaskExecutor();

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
        // Keys outlive the process now: a redeploy should not re-provision
        // every device that was working a moment ago.
        accounts.openStore(root.resolve("accounts.tsv"));
        this.workspace = new Workspace(root, aws, env("ARMEDIT_S3_BUCKET", ""));
        this.agent = new AwsAgent(aws, root);
        this.journal = new Journal(root);
        this.agents = new Agents(root);
        this.behaviours = new Behaviours(root);
        this.catalogue = new Catalogue(env("ARMEDIT_AICOIN", "http://127.0.0.1:8081"),
                java.util.List.of("anthropic", "openai", "google", "mistral", "cohere"));
        this.consortium = new Consortium(aicoin, catalogue);
        this.distro = new Distro(env("ARMEDIT_OPS_DIR", "../ops"));
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
        app.startRefresher();
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
            case "/api/fetch" -> routeFetch(r);
            case "/api/behaviours" -> routeBehaviours(r);
            case "/api/ops" -> routeOps(r);
            case "/api/consensus" -> routeConsensus(r);
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
    /**
     * The model, revisiting its own work on a timer.
     *
     * A script is written once, in the middle of answering something else, on
     * the evidence available at that moment. Some turn out to be wrong, some
     * cover less than they could, and some stop being asked for. None of that
     * is visible from inside a single request - it is only visible in the
     * record of what has been used since.
     *
     * So periodically the model is shown its own inventory and what each entry
     * has actually done, and invited to replace or retire. That is the loop
     * that makes this improve rather than merely accumulate.
     *
     * Nothing here runs without an account to spend, and a refresh that fails
     * is logged and forgotten: this is maintenance, and maintenance that can
     * break the thing it maintains is worse than none.
     */
    /**
     * Turn an agreement into something the server can answer with.
     *
     * Asked of the model rather than assembled here, because the useful output
     * is the general operation behind the agreement, not the sentence three
     * people happened to type. The model is allowed to decline - a coincidence
     * of identical requests is not a pattern - and declining is the common
     * case, so nothing is forced.
     *
     * Off the request thread: the person who asked is owed their answer now,
     * not after this has finished.
     */
    private void promote(Consensus.Agreed settled, Router.Tier tier) {
        promoter.submit(() -> {
            try {
                System.out.printf("armedit: %d people agree on \"%s\" - asking for the operation%n",
                        settled.people(), settled.instruction());
                String wallet = accounts.anyWallet();
                if (wallet == null || wallet.isBlank()) return;
                String reply = aicoin.ask(wallet, tier,
                        Consensus.promotionPrompt(settled) + scripts.briefing(), 4000);
                var learned = scripts.learn(reply, tier.name(), true);
                if (learned.isEmpty()) {
                    System.out.printf("armedit: nothing general in it, left as it was%n");
                    return;
                }
                for (var op : learned) {
                    System.out.printf("armedit: promoted \"%s\" -> %s%s%n",
                            op.pattern(), op.name(),
                            op.blob() != null
                                ? " (" + op.blob().code().length + " bytes of machine code)"
                                : "");
                    if (op.blob() != null) ship(wallet, op);
                }
            } catch (Exception x) {
                System.out.printf("armedit: promotion skipped: %s%n", x);
            }
        });
    }

    /**
     * Put one compiled operation to the consortium, and ship it if they agree.
     *
     * This is the only place machine code enters the source tree, and it is
     * deliberately the narrowest one: an operation gets here only after enough
     * distinct people were independently given the same answer, only after the
     * backend turned that answer into something that compiles, and only after
     * every model this wallet can reach has separately said it should exist.
     *
     * Any of those three can decline, and declining is the ordinary outcome.
     */
    private void ship(String wallet, Scripts.Script op) {
        try {
            String observed = exercise(op);
            var verdict = consortium.decide(wallet, op.name(),
                    Consortium.aboutBlob(op.name(), op.pattern(), op.arguments(),
                            op.js(), op.blob().code(), op.blob().sha(), observed));
            System.out.printf("armedit: consortium on \"%s\": %s - %s%n",
                    op.name(), verdict.commit() ? "COMMIT" : "HOLD", verdict.why());
            for (var c : verdict.changes()) System.out.printf("armedit:   %s%n", c);
            if (!verdict.commit()) return;
            var written = distro.commit(op, verdict, observed);
            System.out.printf("armedit: %s is in the tree: %s%n", op.name(),
                    written.stream().map(java.nio.file.Path::toString)
                            .collect(java.util.stream.Collectors.joining(", ")));
        } catch (Exception x) {
            System.out.printf("armedit: not shipping \"%s\": %s%n", op.name(), x);
        }
    }

    /**
     * Run the operation on its own pattern before anyone is asked about it.
     *
     * A reviewer given only source is reviewing a claim. Given what the thing
     * actually printed, it is reviewing the thing - and the difference shows
     * up most on the operations that compile cleanly and then decline
     * everything, which read fine and do nothing.
     */
    private String exercise(Scripts.Script op) {
        var b = new StringBuilder();
        for (var probe : Scripts.probes(op)) {
            String out;
            try {
                out = Js.run(op.js(), op.arguments(), probe.values());
            } catch (RuntimeException x) {
                out = "(failed: " + x + ")";
            }
            b.append("    ").append(probe.sentence()).append("  ->  ")
             .append(out == null || out.isBlank() ? "(declined)" : out.replace("\n", "\\n"))
             .append('\n');
        }
        return b.length() == 0 ? "    (nothing to try)" : b.toString().stripTrailing();
    }

    private void startRefresher() {
        long everyMinutes = Long.parseLong(env("ARMEDIT_REFRESH_MINUTES", "360"));
        if (everyMinutes <= 0) {
            System.out.println("armedit: script refreshing disabled");
            return;
        }
        var timer = Executors.newSingleThreadScheduledExecutor(r -> {
            var t = new Thread(r, "armedit-refresher");
            t.setDaemon(true);
            return t;
        });
        timer.scheduleWithFixedDelay(this::refresh, everyMinutes, everyMinutes,
                java.util.concurrent.TimeUnit.MINUTES);
        System.out.printf("armedit: the model revisits its scripts every %d minutes%n",
                everyMinutes);
    }

    private void refresh() {
        try {
            if (scripts.size() == 0) return;
            String wallet = accounts.anyWallet();
            if (wallet == null || wallet.isBlank()) return;

            var tier = Router.byName("sonnet") == null ? Router.cheapest() : Router.byName("sonnet");
            String prompt = """
                    You wrote these operations. They answer requests without waking
                    you, so they are worth being right rather than merely present.

                    Here is what exists and how much each has been used:

                    """ + scripts.inventory() + """

                    Consider: is any of them wrong, or narrower than it could be?
                    Has anything gone unused long enough to be clutter?

                    Reply with nothing at all if they are fine - that is the
                    common and correct answer. Otherwise:

                        #RETIRE <name>          to take one out
                        #SCRIPT ... #END        to write a better one

                    A replacement must be clearly better, not merely different.
                    Rewriting a working operation costs everyone who was relying
                    on the answer it already gave.
                    """ + scripts.briefing();

            String reply = aicoin.ask(wallet, tier, prompt, 4000);
            var retire = java.util.regex.Pattern
                    .compile("(?m)^#RETIRE\\s+([A-Za-z0-9_-]{1,40})\\s*$").matcher(reply);
            while (retire.find()) {
                if (scripts.forget(retire.group(1))) {
                    System.out.printf("armedit: retired script \"%s\"%n", retire.group(1));
                }
            }
            for (var taught : scripts.learn(reply, tier.name(), true)) {
                System.out.printf("armedit: refreshed \"%s\" -> %s%n",
                        taught.pattern(), taught.name());
            }
        } catch (Exception x) {
            System.out.printf("armedit: refresh skipped: %s%n", x);
        }
    }

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
        // A run finishing is news, and a laptop-hosted backend has no way to be
        // told it - so we look, on the same schedule we reap on.
        for (var account : accounts.all()) {
            try {
                if (runner.collect(account, aws)) {
                    System.out.printf("armedit: %s - a run finished, output collected%n",
                            account.id());
                }
                runner.expire(account, aws);
            } catch (Exception x) {
                // Next sweep.
            }
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

    /**
     * Which palette slot a reply asked for, or -1 for none.
     *
     * A slot, not a name. There used to be a table here mapping "blue" to 3,
     * which is a decision about what words mean sitting in the one place that
     * cannot learn - and it had to be consulted by a briefing declared above
     * it, which meant the briefing read it before it existed. Two problems
     * from one table.
     *
     * The model knows what blue is. It picks the slot, the briefing says which
     * slot is which, and this only has to read a digit. Anything an operation
     * learns about colour names it learns for itself, and a colour the palette
     * does not have is a colour nothing here has to have an opinion about.
     */
    private static final java.util.regex.Pattern COLOUR_DIRECTIVE =
            java.util.regex.Pattern.compile("(?mi)^#COLou?R\\s+([0-9])\\s*$");

    static int colourIn(String reply) {
        if (reply == null) return -1;
        var m = COLOUR_DIRECTIVE.matcher(reply);
        return m.find() ? m.group(1).charAt(0) - '0' : -1;
    }

    /**
     * When a reply is about the screen rather than about the line.
     *
     * Cmd+P replaces exactly what was typed, which is right when somebody asked
     * for something new and wrong when they asked for a change to what is
     * already there. "add a loop" is not a request for a program; it is a
     * request for *that* program with a loop in it, and replacing only the
     * instruction leaves the old version above with a second copy underneath.
     *
     * The model is the only party that can tell those apart, since the
     * difference is in what the sentence means. So it says which it meant, and
     * the default is the conservative one - a stray marker deletes work that
     * was not the model's to delete.
     */
    private static final String WHOLE_BRIEFING = """
            By default your reply takes the place of exactly that: the line they
            typed, and nothing else on the screen. That is right when they asked
            for something new.

            It is wrong when they asked you to change what is already there.
            "add a loop", "make it faster", "without the comments" are all about
            the text above - replacing only the instruction leaves the old
            version sitting there with a second copy underneath it.

            When the instruction is about the existing screen, put #WHOLE alone
            on the first line and then give the entire new contents of the
            screen. The marker is removed before anyone sees it.

            When in doubt, leave it out. A reply that lands in the wrong place
            is a nuisance; one that deletes the screen is not.

            RUNNING IT

            Almost never. Writing the code is the answer to almost every
            request, and somebody who asked for a sorting function wants a
            sorting function - not a machine in a datacentre, a wait, and its
            output. Provisioning when nobody asked spends their money and their
            time on something they did not want.

            Only when running is the request itself - "run this", "what does it
            print", "run it on linux" - and then it is the whole answer, because
            a described output is worth less than none: it looks exactly like a
            real one and is not. In that case, write:

                #RUN aws smallest  <shell command>

            on its own line. The backend brings up a machine, runs it, and the
            output comes back to you before you answer. Anything the command
            needs must be in the command, since the machine starts empty:

                #RUN aws smallest  sudo dnf install -y nodejs >/dev/null 2>&1 && node -e 'console.log(2+2)'

            The machine is terminated as soon as it has reported, so this costs
            a couple of minutes of the smallest instance there is. That is not
            free, which is the other reason not to reach for it uninvited.

            "sort it manually", "do it without the library", "rewrite it as a
            loop" are not requests to run anything. They are changes to what is
            on the screen, so they take #WHOLE and a rewritten screen.

            HOW IT LOOKS

            "colours blue", "make the text red", "green please" are asking the
            editor to change its own appearance. The palette is fixed and this
            is all of it:

                0 green   1 white   2 amber   3 blue   4 red
                5 violet  6 cyan    7 yellow  8 grey   9 pink

            Answer with the number of the one they asked for, alone, and
            nothing else - no explanation, no code:

                #COLOUR 6      <- if, and only if, they asked for cyan

            Look the number up; do not copy the one in that example. It is the
            entire content of the answer, and an answer that is the example
            rather than the request turns "green please" blue.

            A colour the palette does not have is one the editor cannot show,
            so choose the nearest slot rather than inventing a number. The line
            they typed vanishes and the colour changes, which is the whole of
            what they asked for.

            Worth scripting: the answer depends on nothing but the colour named.
            """;


    /**
     * What a text editor can hold.
     *
     * A model writing code fences is doing the right thing for a chat window
     * and the wrong thing here: this reply is pasted straight into a document,
     * where ```javascript is three backticks and a word nobody typed. So the
     * fences come off - and only the fences, since what is between them is the
     * answer.
     *
     * Deliberately not a markdown renderer. Stripping bold and headings too
     * would start guessing at which asterisks were formatting and which were
     * multiplication, and getting that wrong silently edits somebody's code.
     */
    /**
     * Directives are addressed to the server, never to the person.
     *
     * #RUN, #SCRIPT, #WHOLE and the rest are how the model asks this process to
     * do something. Every one of them is supposed to be consumed by whatever
     * handles it - and every one of them has, at some point, failed to be, and
     * arrived on somebody's screen as literal text in the middle of their
     * document.
     *
     * So this is the last thing the text passes through, and it does not care
     * why a marker survived: a directive that reached here was not acted on,
     * and showing it to the user is strictly worse than dropping it. The
     * handlers upstream stay responsible for acting; this is only responsible
     * for the invariant that a document never fills up with protocol.
     */
    private static final java.util.regex.Pattern DIRECTIVE =
            java.util.regex.Pattern.compile("(?m)^#[A-Z]{2,}\\b.*$\\n?");

    static String withoutDirectives(String reply) {
        if (reply == null) return "";
        return DIRECTIVE.matcher(reply).replaceAll("").strip();
    }

    static String plainText(String reply) {
        if (reply == null || reply.isBlank()) return "";
        var out = new StringBuilder();
        for (String line : reply.split("\n", -1)) {
            if (line.strip().startsWith("```")) continue;
            if (out.length() > 0) out.append('\n');
            out.append(line);
        }
        return out.toString().strip();
    }


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
                if (said != null) {
                    journal.edits(account, screen, java.util.List.of(new Journal.Edit(
                            System.currentTimeMillis(), "behaviour", 0, said)));
                    return Res.json(200, Json.obj("text", said, "model", "behaviour"));
                }
            } catch (Exception x) {
                return Res.json(502, Json.obj("error", "behaviour: " + x.getMessage()));
            }
        }

        // Somebody may already have paid for this one.  Only ever true when
        // nothing of theirs went into the asking - see Cache.shareable.
        boolean shareable = Cache.shareable(instruction, context, baseline, selection, subject);
        // Asking the same thing twice in quick succession is somebody saying
        // the answer was wrong. It is the only such signal there is, so it is
        // worth acting on: forget what was remembered and go and ask properly,
        // rather than handing back the same unwanted reply faster each time.
        var again = ModelStats.classify(mode, context);
        boolean unhappy = account.lastAsk(again.id, screen);

        String cacheKey = null;
        if (shareable) {
            cacheKey = Cache.key(mode, instruction, context, baseline, selection, subject);
            if (unhappy && cache.forget(cacheKey)) {
                System.out.printf("armedit: asked again - forgetting the cached answer for \"%s\"%n",
                        instruction.length() > 60 ? instruction.substring(0, 60) + "..." : instruction);
            }
            var hit = cache.get(cacheKey);
            if (hit != null) {
                // A cache hit is still somebody receiving this answer, and that
                // is exactly what consensus counts. Recording only on the slow
                // path would mean the cache quietly prevents anything from ever
                // being agreed on: the second person to ask an identical
                // question would never be seen.
                var settled = consensus.record(account.id(), subject, instruction, hit.text());
                if (settled != null) promote(settled, Router.cheapest());
                journal.edits(account, screen, java.util.List.of(new Journal.Edit(
                        System.currentTimeMillis(), "cached", 0, instruction)));
                return Res.json(200, Json.obj("text", withoutDirectives(hit.text()),
                        "model", hit.model(), "cached", true,
                        "colour", colourIn(hit.text())));
            }

            // Nobody asked this exact thing before, but a model may have
            // recognised the kind of thing it is and left an answer for it.
            // This is the fast path: no upstream call at all.
            var scripted = unhappy ? null : scripts.lookup(new Scripts.Ctx(
                    mode, instruction, context, selection, subject));
            if (scripted != null) {
                journal.edits(account, screen, java.util.List.of(new Journal.Edit(
                        System.currentTimeMillis(), "scripted", 0, instruction)));
                // A scripted or compiled answer can change the colour too - it
                // is the same directive, and an operation the model wrote is
                // exactly as entitled to ask for one as the model itself.
                return Res.json(200, Json.obj("text", withoutDirectives(scripted.text()),
                        "model", scripted.script().author(), "scripted", true,
                        "script", scripted.script().name(),
                        "colour", colourIn(scripted.text())));
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
        // The briefings above are context - what models exist, what the record
        // says, what has been scripted. This is the actual instruction, so it
        // goes last: buried in the middle, between the cloud inventory and the
        // model catalogue, it was simply not acted on.
        String base = prompt.toString()
                + "\n\n" + catalogue.briefing()
                + stats.briefing(names, category)
                + (shareable ? scripts.briefing() : "")
                + (instruction.isBlank() ? "" : WHOLE_BRIEFING);

        // A second ask about the same screen within a minute is rarely a
        // compliment to the answer that came first, so it counts against
        // whoever gave it - not against whoever is about to try again.
        if (unhappy && !account.lastModel().isBlank()) {
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

            // Did it decide this supersedes the screen rather than the line?
            boolean whole = false;
            text = plainText(text);
            String lead = text.stripLeading();
            if (lead.startsWith("#WHOLE")) {
                whole = true;
                int nl = lead.indexOf('\n');
                text = nl < 0 ? "" : lead.substring(nl + 1);
            }

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
                        + """

                        Now answer what they actually asked. Do not repeat the
                        raw output.

                        If something above failed and they never asked for it,
                        say nothing about it at all - a person who asked how to
                        sort an array does not want to read about credentials,
                        and their screen is where your reply lands, not a log.
                        Answer the request as though the attempt had not
                        happened. Only when the thing they asked for genuinely
                        depended on it is the failure worth mentioning, and then
                        in one line.
                        """;
                text = AwsAgent.redact(aicoin.ask(account.wallet(), tier, followUp, 16000));
                // The follow-up replaces everything decided above, markers and
                // all - so it gets the same treatment, or #WHOLE arrives on the
                // user's screen as four literal characters.
                text = plainText(text);
                String lead2 = text.stripLeading();
                if (lead2.startsWith("#WHOLE")) {
                    whole = true;
                    int nl = lead2.indexOf('\n');
                    text = nl < 0 ? "" : lead2.substring(nl + 1);
                }
            }

            // Did this land somebody else's answer too?  If enough different
            // people have now been told the same thing, it stops being theirs
            // and becomes an operation.
            if (shareable) {
                var settled = consensus.record(account.id(), subject, instruction, text);
                if (settled != null) promote(settled, tier);
            }

            account.otp().account((long) text.length() * 8);
            account.lastModel(tier.name());
            // A directive is an instruction to do something, not an answer.
            // Caching a reply that still contains one hands the next person the
            // literal text "#RUN aws smallest ..." and never runs anything -
            // and worse, hands it back to the person who asked, so the run they
            // requested silently stops happening from the second attempt on.
            boolean directive = text.contains("#RUN ") || text.contains("#AWS ")
                    || text.contains("#AGENT ");
            if (cacheKey != null && !directive && results.isBlank()) {
                // Nothing here was marked private and nothing had to be run, so
                // the next person to ask gets this without paying for it again.
                cache.put(cacheKey, text, tier.name());
            }
            if ("swipe".equals(mode) && !selection.isBlank()) {
                journal.edits(account, screen, java.util.List.of(new Journal.Edit(
                        System.currentTimeMillis(), "ai-swipe",
                        parseInt(cursor.isBlank() ? "0" : cursor, 0),
                        text.length() > 200 ? text.substring(0, 200) + "..." : text)));
            }
            return Res.json(200, Json.obj("text", withoutDirectives(text),
                    "model", tier.name(), "whole", whole,
                    "colour", colourIn(text)));
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
    /**
     * The operations a device may run itself.
     *
     * Without a name, the catalogue: what exists, what each takes, and the
     * hash of its code. With ?name=, the code itself, base64'd because this is
     * a JSON API and the alternative is a second transport for one field.
     *
     * A device asks for this when it can execute what comes back. iOS cannot -
     * every page must be signed there - so it never asks, and gets the same
     * answers from /api/agent instead. The operation is identical either way;
     * only who runs it differs.
     */
    private Res routeOps(Req r) {
        var account = authorise(r);
        if (account == null) return unauthorised();

        String want = r.path().contains("?") ? "" : "";
        var q = new QueryStringDecoder("/?" + (r.header().apply("X-Armedit-Op") == null
                ? "" : "name=" + r.header().apply("X-Armedit-Op")));
        var names = q.parameters().get("name");
        if (names != null && !names.isEmpty()) {
            var op = scripts.byName(names.get(0));
            if (op == null || op.blob() == null) {
                return Res.json(404, Json.obj("error", "no such operation"));
            }
            return Res.json(200, Json.obj(
                    "name", op.name(),
                    "params", String.join(",", op.parameters()),
                    "sha", op.blob().sha(),
                    "code", Base64.getEncoder().encodeToString(op.blob().code())));
        }

        var b = new StringBuilder("{\"ops\":[");
        boolean first = true;
        for (var op : scripts.nativeOps()) {
            if (!first) b.append(',');
            first = false;
            b.append(Json.obj("name", op.name(), "pattern", op.pattern(),
                    "params", String.join(",", op.parameters()),
                    "bytes", op.blob().code().length, "sha", op.blob().sha()));
        }
        b.append("]}");
        return Res.json(200, b.toString());
    }

    /** What is converging, what has converged, and what is scattered. */
    private Res routeConsensus(Req r) {
        var account = authorise(r);
        if (account == null) return unauthorised();
        var b = new StringBuilder(consensus.asJson());
        b.setLength(b.length() - 1);
        b.append(",\"pending\":[");
        boolean first = true;
        for (var line : consensus.pending()) {
            if (!first) b.append(',');
            first = false;
            b.append('"').append(Json.escape(line)).append('"');
        }
        return Res.json(200, b.append("]}").toString());
    }

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
        // Not every sentence typed on a widget's screen is a behaviour. "make
        // it draggable" is; "what format is this" is not. Returning an error
        // for the second kind was wrong twice over - it refused a reasonable
        // question, and it kept those questions out of the record that decides
        // what becomes an operation. So: say nothing, and let the caller ask
        // normally.
        if (rule == null) return null;
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

    /**
     * Fetch a page for a device that cannot fetch it itself.
     *
     * The editor tries directly first and only arrives here when that failed -
     * no TLS on the device, or no resolver on a bare-metal machine. Answering
     * with text rather than markup keeps both routes ending in the same shape,
     * so the one that gets less use cannot quietly rot.
     */
    private Res routeFetch(Req r) {
        if (!r.isPost()) return Res.json(405, Json.obj("error", "POST only"));
        var account = authorise(r);
        if (account == null) return unauthorised();
        String url = Json.parse(r.body()).get("url");
        var page = fetcher.get(url);
        if (!page.ok()) {
            // A failure is an answer too, and it goes on the screen as text -
            // the device has no other channel to explain itself through, and
            // "could not open <site>: <why>" is more use than an empty screen.
            return Res.json(200, Json.obj("text",
                    "could not open " + (url == null ? "that" : url) + ": " + page.error(),
                    "fetched", false));
        }
        System.out.printf("armedit: %s fetched %s (%d chars)%n",
                account.id(), page.url(), page.text().length());
        return Res.json(200, Json.obj("text", page.text(), "fetched", true,
                "url", page.url()));
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
