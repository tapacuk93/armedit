import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.security.SecureRandom;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * The machines that have volunteered themselves to an account.
 *
 * A cloud instance is something the backend creates; an agent is something
 * that already exists and connects inward - a laptop, a workstation, a box
 * under a desk. Both end up in the same place: a name the model can address
 * work to. The difference the model is told about is what each one can do.
 *
 * Agents poll rather than listen, so nothing has to be reachable from the
 * internet and no port is opened on anyone's machine. The health sweep is
 * what makes "connected" mean something: an agent that has stopped calling in
 * stops being offered to the model, rather than silently swallowing work.
 *
 * Commands are gated exactly like the cloud ones. An agent may declare itself
 * unrestricted, and the person who installed it may mean that, but a model
 * asking to delete a home directory still has to get past {@link #judge}.
 */
final class Agents {

    /** An agent unheard from for this long is no longer connected. */
    private static final long STALE_MILLIS = 90_000;

    private static final Pattern ACTION = Pattern.compile(
            "(?m)^#AGENT\\s+([A-Za-z0-9_.-]+)\\s+(.+)$");

    /**
     * Refused on any machine, at any access level. These are the commands
     * whose whole purpose is to be irreversible, and no amount of "full
     * access" makes it sensible for a model to reach them unattended.
     */
    private static final List<Pattern> FORBIDDEN = List.of(
            Pattern.compile("(?i)\\brm\\s+(-[a-z]*\\s+)*-[a-z]*[rf]"),
            Pattern.compile("(?i)\\bmkfs\\b|\\bdiskutil\\s+(erase|reformat)"),
            Pattern.compile("(?i)\\bdd\\b[^|]*of=/dev/"),
            Pattern.compile("(?i):\\(\\)\\s*\\{.*\\|.*&.*\\}"),        // fork bomb
            Pattern.compile("(?i)\\bshutdown\\b|\\breboot\\b|\\bhalt\\b"),
            Pattern.compile("(?i)\\bcsrutil\\b|\\bspctl\\s+--master-disable"),
            Pattern.compile("(?i)\\bsudo\\s+rm\\b"),
            Pattern.compile("(?i)\\bkeychain\\b.*\\bdump\\b|\\bsecurity\\s+dump-keychain"));

    /** Read-shaped commands, safe to run without asking. */
    private static final List<Pattern> READ_ONLY = List.of(
            Pattern.compile("^\\s*(ls|pwd|cat|head|tail|wc|file|stat|du|df|which|whoami|uname|date|env)\\b"),
            Pattern.compile("^\\s*git\\s+(status|log|diff|show|branch|remote|rev-parse)\\b"),
            Pattern.compile("^\\s*(grep|rg|find|fd)\\b"),
            Pattern.compile("^\\s*(ps|top\\s+-l\\s*1|sw_vers|system_profiler)\\b"));

    /** How much an agent was installed to allow. */
    enum Access {
        READ_ONLY("read-only", "may only be asked for information"),
        CONFIRMED("confirmed", "anything beyond reading comes back for confirmation"),
        FULL("full", "runs what it is asked, short of the refused list");

        final String id;
        final String about;

        Access(String id, String about) {
            this.id = id;
            this.about = about;
        }

        static Access of(String s) {
            if (s == null) return CONFIRMED;
            String k = s.toLowerCase(Locale.ROOT).trim();
            for (var v : values()) if (v.id.equals(k)) return v;
            return CONFIRMED;
        }
    }

    /** One machine that has called in. */
    static final class Agent {
        final String id;
        final String token;
        final String accountId;
        final String name;
        final String os;
        final String arch;
        final Access access;
        private volatile long lastSeenMillis = System.currentTimeMillis();

        /** Work waiting to be collected, and what came back. */
        final ConcurrentLinkedQueue<Job> queue = new ConcurrentLinkedQueue<>();

        Agent(String id, String token, String accountId, String name,
              String os, String arch, Access access) {
            this.id = id;
            this.token = token;
            this.accountId = accountId;
            this.name = name;
            this.os = os;
            this.arch = arch;
            this.access = access;
        }

        void seen() { lastSeenMillis = System.currentTimeMillis(); }

        long idleMillis() { return System.currentTimeMillis() - lastSeenMillis; }

        boolean connected() { return idleMillis() < STALE_MILLIS; }
    }

    /** One command, and whatever it produced. */
    static final class Job {
        final String id = UUID.randomUUID().toString().substring(0, 8);
        final String command;
        volatile int code = Integer.MIN_VALUE;
        volatile String output = "";

        Job(String command) { this.command = command; }

        boolean done() { return code != Integer.MIN_VALUE; }
    }

    private final Map<String, Agent> byId = new ConcurrentHashMap<>();
    private final Map<String, Job> jobs = new ConcurrentHashMap<>();
    private final SecureRandom rng = new SecureRandom();
    private final Path root;

    Agents(Path root) { this.root = root; }

    /* ------------------------------------------------------- registration */

    Agent register(Accounts.Account account, String name, String os, String arch, Access access) {
        var raw = new byte[24];
        rng.nextBytes(raw);
        var agent = new Agent(
                UUID.randomUUID().toString().substring(0, 8),
                HexFormat.of().formatHex(raw),
                account.id(),
                name == null || name.isBlank() ? "agent" : name.trim(),
                os == null ? "?" : os, arch == null ? "?" : arch, access);
        byId.put(agent.id, agent);
        record(agent.accountId, "registered %s (%s %s, %s access)"
                .formatted(agent.name, agent.os, agent.arch, agent.access.id));
        return agent;
    }

    Optional<Agent> byToken(String token) {
        if (token == null || token.isBlank()) return Optional.empty();
        return byId.values().stream().filter(a -> a.token.equals(token)).findFirst();
    }

    Optional<Agent> named(Accounts.Account account, String name) {
        return byId.values().stream()
                .filter(a -> a.accountId.equals(account.id()))
                .filter(a -> a.name.equalsIgnoreCase(name) || a.id.equals(name))
                .findFirst();
    }

    List<Agent> of(Accounts.Account account) {
        var out = new ArrayList<Agent>();
        for (var a : byId.values()) if (a.accountId.equals(account.id())) out.add(a);
        out.sort((x, y) -> x.name.compareToIgnoreCase(y.name));
        return out;
    }

    /* --------------------------------------------------------------- work */

    /**
     * Decide what may be run. Same three answers as everywhere else in this
     * backend: run it, ask the human, or refuse outright.
     */
    AwsPolicy.Decision judge(Agent agent, String command) {
        for (var f : FORBIDDEN) {
            if (f.matcher(command).find()) {
                return AwsPolicy.Decision.deny(
                        "that command is refused on any machine at any access level");
            }
        }
        for (var r : READ_ONLY) {
            if (r.matcher(command).find()) return AwsPolicy.Decision.allow();
        }
        return switch (agent.access) {
            case FULL -> AwsPolicy.Decision.allow();
            case READ_ONLY -> AwsPolicy.Decision.deny(
                    "%s was installed read-only".formatted(agent.name));
            case CONFIRMED -> AwsPolicy.Decision.confirm(
                    "%s would change something on %s".formatted(command, agent.name));
        };
    }

    Job submit(Agent agent, String command) {
        var job = new Job(command);
        jobs.put(job.id, job);
        agent.queue.add(job);
        record(agent.accountId, "%s <- %s".formatted(agent.name, command));
        return job;
    }

    /** What the agent should do next, or null when there is nothing. */
    Job take(Agent agent) {
        agent.seen();
        return agent.queue.poll();
    }

    void complete(String jobId, int code, String output) {
        var job = jobs.get(jobId);
        if (job == null) return;
        job.code = code;
        job.output = output == null ? "" : output;
    }

    /**
     * Wait briefly for a job to finish, so a single Cmd+P can ask a machine
     * something and answer with what it said. Longer work is picked up by the
     * next exchange rather than holding this one open.
     */
    Job await(Job job, long millis) {
        long until = System.currentTimeMillis() + millis;
        while (!job.done() && System.currentTimeMillis() < until) {
            try {
                Thread.sleep(100);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
        }
        return job;
    }

    /* ------------------------------------------------------------- action */

    record Outcome(String transcript, List<String> pending) {}

    /** Run whatever #AGENT lines a reply contains. */
    Outcome run(Accounts.Account account, String reply) {
        var transcript = new StringBuilder();
        var pending = new ArrayList<String>();
        Matcher m = ACTION.matcher(reply == null ? "" : reply);
        int taken = 0;
        while (m.find() && taken < 4) {
            taken++;
            String name = m.group(1);
            String command = m.group(2).trim();
            var agent = named(account, name).orElse(null);
            if (agent == null) {
                transcript.append("#AGENT %s -> no such agent%n".formatted(name));
                continue;
            }
            if (!agent.connected()) {
                transcript.append("#AGENT %s -> not connected (last seen %ds ago)%n"
                        .formatted(agent.name, agent.idleMillis() / 1000));
                continue;
            }
            var decision = judge(agent, command);
            switch (decision.verdict()) {
                case DENY -> transcript.append("#AGENT %s -> refused: %s%n"
                        .formatted(agent.name, decision.reason()));
                case CONFIRM -> {
                    pending.add("%s: %s".formatted(agent.name, command));
                    transcript.append("#AGENT %s -> held for confirmation: %s%n"
                            .formatted(agent.name, decision.reason()));
                }
                case ALLOW -> {
                    var job = await(submit(agent, command), 20_000);
                    if (job.done()) {
                        transcript.append("#AGENT %s (exit %d) ->%n%s%n"
                                .formatted(agent.name, job.code, clamp(job.output)));
                    } else {
                        transcript.append("#AGENT %s -> still running, id %s%n"
                                .formatted(agent.name, job.id));
                    }
                }
            }
        }
        return new Outcome(transcript.toString(), pending);
    }

    /**
     * What the model is told about the machines it can reach. Health is the
     * point: an agent that has stopped calling in is listed as gone rather
     * than offered as if it were there.
     */
    String briefing(Accounts.Account account) {
        var mine = of(account);
        if (mine.isEmpty()) return "No agents are connected to this account.\n";
        var b = new StringBuilder("""
                Machines connected to this account. Run something on one by writing a line:

                    #AGENT <name> <shell command>

                """);
        for (var a : mine) {
            b.append("  - ").append(a.name).append(" (").append(a.os).append(' ').append(a.arch)
             .append(", ").append(a.access.about).append("): ")
             .append(a.connected()
                     ? "connected, last seen %ds ago".formatted(a.idleMillis() / 1000)
                     : "NOT connected, last seen %ds ago".formatted(a.idleMillis() / 1000))
             .append('\n');
        }
        b.append("Reads run immediately; anything that changes a machine comes back to the user.\n");
        return b.toString();
    }

    /** Agents that have gone quiet, for the scheduled sweep to report. */
    List<Agent> stale() {
        var out = new ArrayList<Agent>();
        for (var a : byId.values()) if (!a.connected()) out.add(a);
        return out;
    }

    private static String clamp(String s) {
        return s.length() <= 4000 ? s : s.substring(0, 4000) + "\n...[truncated]";
    }

    private void record(String accountId, String line) {
        try {
            var dir = root.resolve(accountId);
            Files.createDirectories(dir);
            Files.writeString(dir.resolve("agents.log"),
                    "%s  %s%n".formatted(Instant.now(), line),
                    StandardCharsets.UTF_8, StandardOpenOption.CREATE, StandardOpenOption.APPEND);
        } catch (Exception x) {
            System.out.printf("armedit: could not record agent event: %s%n", x.getMessage());
        }
    }
}
