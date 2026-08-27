import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.concurrent.TimeUnit;

/**
 * The armedit agent: a machine volunteering itself to an account.
 *
 * It runs on a laptop, a workstation, a box under a desk - anything that
 * already exists and is not worth provisioning. It registers with the
 * backend, then polls for work. Polling rather than listening is deliberate:
 * nothing here opens a port, nothing has to be reachable from the internet,
 * and a machine behind any NAT works the same as one that is not.
 *
 * What it will run is decided by the backend, which applies the same three
 * answers it applies to a cloud: run it, ask the human, or refuse. The
 * access level below is what the *installer* is willing to allow; it is a
 * ceiling, not a grant, and the refused list applies at every level.
 *
 * Run it:
 *   java agent/src/ArmeditAgent.java --key <armedit key> [--access read-only|confirmed|full]
 */
public final class ArmeditAgent {

    /** How long to wait between polls when there is nothing to do. */
    private static final int IDLE_POLL_SECONDS = 3;

    /** A single command may not run longer than this. */
    private static final int COMMAND_TIMEOUT_SECONDS = 120;

    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .build();

    private final String base;
    private final String key;
    private final String name;
    private final String access;

    private String agentId = "";
    private String token = "";

    private ArmeditAgent(String base, String key, String name, String access) {
        this.base = base;
        this.key = key;
        this.name = name;
        this.access = access;
    }

    public static void main(String[] args) throws Exception {
        String key = arg(args, "--key", System.getenv("ARMEDIT_KEY"));
        String access = arg(args, "--access", "confirmed");
        String name = arg(args, "--name", hostName());

        if (key == null || key.isBlank()) {
            System.err.println("""
                    armedit-agent: no key.

                      java agent/src/ArmeditAgent.java --key <armedit key> [--access confirmed]

                    The key is the one the registration page issued. It carries the address of
                    the backend to call, so there is nothing else to configure.""");
            System.exit(2);
        }

        // The key carries where to reach the backend, exactly as it does for
        // the editor: one property on a machine, never two.
        String secret = key;
        String addr = arg(args, "--backend", "127.0.0.1:8080");
        int at = key.indexOf('@');
        if (at >= 0) {
            secret = key.substring(0, at);
            addr = key.substring(at + 1);
        }
        String base = addr.startsWith("http") ? addr : "http://" + addr;

        var agent = new ArmeditAgent(base, secret, name, access);
        agent.register();
        agent.loop();
    }

    private void register() throws Exception {
        String body = Json.obj(
                "name", name,
                "os", System.getProperty("os.name", "?"),
                "arch", System.getProperty("os.arch", "?"),
                "access", access);
        var res = post("/api/agents/register", body, true);
        var in = Json.parse(res);
        agentId = in.getOrDefault("agent", "");
        token = in.getOrDefault("token", "");
        if (token.isBlank()) throw new IllegalStateException("registration refused: " + res);
        System.out.printf("armedit-agent: %s registered as %s, %s access%n", name, agentId, access);
    }

    /**
     * Poll, run, report, repeat. Health is implicit: every poll is a sign of
     * life, so an agent that stops polling stops being offered to the model
     * without needing a separate heartbeat.
     */
    private void loop() {
        while (true) {
            try {
                var res = post("/api/agents/poll", Json.obj("token", token), false);
                var in = Json.parse(res);
                String job = in.getOrDefault("job", "");
                String command = in.getOrDefault("command", "");
                if (job.isBlank() || command.isBlank()) {
                    TimeUnit.SECONDS.sleep(IDLE_POLL_SECONDS);
                    continue;
                }
                System.out.printf("armedit-agent: running %s%n", command);
                var result = run(command);
                post("/api/agents/result", Json.obj(
                        "token", token, "job", job,
                        "code", result.code(), "output", result.output()), false);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            } catch (Exception x) {
                // A backend that is down is a thing to wait out, not to die of.
                System.out.printf("armedit-agent: %s%n", x.getMessage());
                try {
                    TimeUnit.SECONDS.sleep(5);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return;
                }
            }
        }
    }

    record Result(int code, String output) {}

    /**
     * Run one command through a shell, capture both streams together, and
     * stop it if it will not stop itself.
     */
    private Result run(String command) {
        try {
            var pb = new ProcessBuilder("/bin/sh", "-lc", command);
            pb.redirectErrorStream(true);
            pb.directory(new java.io.File(System.getProperty("user.home", ".")));
            var p = pb.start();
            String out;
            try (var in = p.getInputStream()) {
                out = new String(in.readAllBytes(), StandardCharsets.UTF_8);
            }
            if (!p.waitFor(COMMAND_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                p.destroyForcibly();
                return new Result(124, out + "\n[timed out after %ds]".formatted(COMMAND_TIMEOUT_SECONDS));
            }
            if (out.length() > 60_000) out = out.substring(0, 60_000) + "\n...[truncated]";
            return new Result(p.exitValue(), out);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return new Result(130, "interrupted");
        } catch (IOException x) {
            return new Result(127, "could not run: " + x.getMessage());
        }
    }

    private String post(String path, String body, boolean withKey) throws Exception {
        var b = HttpRequest.newBuilder(URI.create(base + path))
                .timeout(Duration.ofSeconds(60))
                .header("Content-Type", "application/json");
        if (withKey) b.header("X-Armedit-Key", key);
        var res = http.send(b.POST(HttpRequest.BodyPublishers.ofString(body)).build(),
                HttpResponse.BodyHandlers.ofString());
        if (res.statusCode() / 100 != 2) {
            throw new IllegalStateException("%s %d: %s".formatted(path, res.statusCode(), res.body()));
        }
        return res.body();
    }

    private static String arg(String[] args, String flag, String fallback) {
        for (int i = 0; i + 1 < args.length; i++) {
            if (args[i].equals(flag)) return args[i + 1];
        }
        return fallback;
    }

    private static String hostName() {
        try {
            return java.net.InetAddress.getLocalHost().getHostName().split("\\.")[0];
        } catch (Exception x) {
            return "agent";
        }
    }
}
