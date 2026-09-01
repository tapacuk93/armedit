import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * "Rerun this on Alibaba, then on Google, smallest Linux."
 *
 * That sentence is the feature. The model turns it into one line per cloud:
 *
 *     #RUN alibaba smallest  ./build.sh && ./run-tests.sh
 *     #RUN gcp smallest      ./build.sh && ./run-tests.sh
 *
 * and each one brings up a machine of that size on that cloud, runs the
 * command through cloud-init, and posts the output back here. The user never
 * learns that one cloud calls it `ecs.t6-c1m1.large` and another `e2-micro`,
 * and the model never holds a credential for either.
 *
 * Runs are asynchronous by nature - a machine takes a minute to exist and the
 * command takes as long as it takes - so a #RUN line returns a handle
 * immediately and the result arrives later, on the callback.
 */
final class Runner {

    /** How many machines one exchange may start. A typo should not cost much. */
    private static final int MAX_RUNS = 4;

    private static final Pattern RUN = Pattern.compile(
            "(?m)^#RUN\\s+([A-Za-z0-9_-]+)\\s+([A-Za-z]+)\\s+(.+)$");

    private final Aws aws;
    private final Path root;
    private final String callbackBase;

    /** Runs waiting on their machine to report back, by token. */
    private final Map<String, Run> pending = new ConcurrentHashMap<>();

    Runner(Aws aws, Path root, String callbackBase) {
        this.aws = aws;
        this.root = root;
        this.callbackBase = callbackBase;
    }

    /** One machine, doing one thing, somewhere. */
    record Run(String token, String accountId, Clouds.Provider provider,
               Machines.Size size, String command, String machineId, long startedMillis) {}

    record Outcome(String transcript, List<Run> started) {}

    /**
     * Act on whatever #RUN lines a reply contains.
     *
     * Failures are reported into the transcript rather than thrown: the model
     * asked for four clouds and three of them working is a useful answer.
     */
    Outcome run(Accounts.Account account, String reply) {
        var started = new ArrayList<Run>();
        var transcript = new StringBuilder();

        Matcher m = RUN.matcher(reply == null ? "" : reply);
        int taken = 0;
        while (m.find() && taken < MAX_RUNS) {
            taken++;
            String providerName = m.group(1);
            var size = Machines.Size.of(m.group(2));
            String command = m.group(3).trim();

            var provider = Clouds.Provider.of(providerName.toLowerCase(Locale.ROOT));
            if (provider == null) {
                transcript.append("#RUN %s -> no such cloud%n".formatted(providerName));
                continue;
            }
            var cred = account.clouds().get(provider);
            if (cred == null || !cred.complete()) {
                transcript.append("#RUN %s -> no credentials bound for it%n".formatted(provider.id));
                continue;
            }
            var spec = Machines.spec(provider, size);
            var impl = Provisioners.of(provider, aws);
            if (spec == null || impl == null) {
                transcript.append("#RUN %s -> credentials are bound but provisioning it is not written yet%n"
                        .formatted(provider.id));
                continue;
            }

            String token = UUID.randomUUID().toString().replace("-", "");
            String name = "armedit-" + token.substring(0, 8);
            try {
                var machine = impl.create(cred, spec, name, cloudInit(command, token));
                var run = new Run(token, account.id(), provider, size, command,
                        machine.id(), System.currentTimeMillis());
                pending.put(token, run);
                started.add(run);
                record(account, "started %s %s (%s) on %s: %s"
                        .formatted(provider.id, size.id, spec.type(), machine.id(), command));
                transcript.append("#RUN %s %s -> machine %s starting (%s), output will follow%n"
                        .formatted(provider.id, size.id, machine.id(), spec.type()));
            } catch (Exception x) {
                record(account, "failed to start on %s: %s".formatted(provider.id, x.getMessage()));
                transcript.append("#RUN %s -> could not start: %s%n".formatted(provider.id, x.getMessage()));
            }
        }
        return new Outcome(transcript.toString(), started);
    }

    /**
     * The script the machine runs on first boot: do the thing, capture
     * everything, post it back, and shut down so it stops costing money.
     *
     * The token in the callback URL is the only authority the machine has -
     * it can report one result and nothing else. No account key ever reaches
     * a provisioned machine.
     */
    private String cloudInit(String command, String token) {
        return """
                #!/bin/bash
                OUT=$( { %s ; } 2>&1 )
                CODE=$?

                # Two ways home, because only one of them works everywhere.
                #
                # The console, first: everything between these markers can be
                # read back with GetConsoleOutput, which needs nothing routable
                # on our side. A backend on somebody's laptop has no address an
                # instance could reach, and that is the common case.
                {
                  echo '%s%s'
                  echo "exit:$CODE"
                  printf '%%s\\n' "$OUT" | head -c 40000
                  echo '%s%s'
                } > /dev/console 2>&1

                # And the callback, which is faster and exact when the backend
                # does have an address. Failing is fine: the console already has
                # it.
                curl -s -m 20 -X POST '%s/api/run/result' \\
                  -H 'Content-Type: application/json' \\
                  --data-binary @<(printf '{"token":"%s","code":%%s,"output":%%s}' \\
                      "$CODE" "$(printf '%%s' "$OUT" | head -c 60000 | python3 -c \\
                      'import json,sys; print(json.dumps(sys.stdin.read()))')") || true

                # Do not rush off. A terminated instance has no console, so
                # shutting down the instant the work finished threw away the
                # only copy of the answer on any backend that could not be
                # called back - which is how the first real run ended up with a
                # correctly executed command and nothing to show for it.
                #
                # The backend terminates this machine as soon as it has read the
                # output. This is only the backstop for a backend that never
                # comes: quiet, bounded, and cheaper than a machine left running
                # because something crashed.
                sleep %d
                shutdown -h now
                """.formatted(command, BEGIN, token, END, token, callbackBase, token,
                        LINGER_SECONDS);
    }

    /** Marks this run's output in a console full of everything else. */
    static final String BEGIN = "---armedit-begin:";
    static final String END = "---armedit-end:";

    /**
     * How long a machine waits after finishing, so its console can be read.
     *
     * Long enough for the sweep to come round twice, since AWS refreshes the
     * console buffer on its own schedule and the first look is often empty.
     */
    private static final int LINGER_SECONDS = 300;

    /**
     * And how long before a run is given up on entirely.
     *
     * A machine that never reports has either failed in a way we cannot see or
     * never booted. Either way it stops being interesting long before it stops
     * being billable, so it is terminated and the run is closed with what we
     * know, which is that it did not come back.
     */
    private static final long GIVE_UP_MILLIS = 15 * 60_000L;

    /**
     * Terminate anything that has outstayed its usefulness.
     *
     * Called on the reaping sweep. The session instance's clock is extended by
     * use - every request touches it - but a run has no user to be idle on
     * behalf of: it is finished or it is stuck, and this is what handles stuck.
     */
    void expire(Accounts.Account account, Aws aws) {
        long now = System.currentTimeMillis();
        for (var e : new java.util.ArrayList<>(pending.entrySet())) {
            var run = e.getValue();
            if (!run.accountId().equals(account.id())) continue;
            if (now - run.startedMillis() < GIVE_UP_MILLIS) continue;
            pending.remove(e.getKey());
            try {
                var cred = account.clouds().get(run.provider());
                var impl = Provisioners.of(run.provider(), aws);
                if (cred != null && impl != null) impl.destroy(cred, run.machineId());
            } catch (Exception ignored) {
                // It has its own timer too.
            }
            record(account, "gave up on %s after %d minutes; machine %s terminated"
                    .formatted(run.provider().id, GIVE_UP_MILLIS / 60_000L, run.machineId()));
        }
    }

    /**
     * Pull a finished run's output out of the machine's console, if it is there.
     *
     * Called on the same sweep that reaps idle instances, so a laptop-hosted
     * backend collects results without anything having to reach it. Returns
     * true when this run is done and has been recorded.
     */
    boolean collect(Accounts.Account account, Aws aws) {
        for (var e : pending.entrySet()) {
            var run = e.getValue();
            if (!run.machineId().isBlank()) {
                try {
                    String console = aws.consoleOutput(account, run.machineId());
                    String begin = BEGIN + e.getKey(), end = END + e.getKey();
                    int a = console.indexOf(begin), b = console.indexOf(end);
                    if (a < 0 || b <= a) continue;
                    String block = console.substring(a + begin.length(), b).strip();
                    int code = 0;
                    if (block.startsWith("exit:")) {
                        int nl = block.indexOf('\n');
                        String num = (nl < 0 ? block : block.substring(0, nl)).substring(5).strip();
                        try { code = Integer.parseInt(num); } catch (NumberFormatException ignored) { }
                        block = nl < 0 ? "" : block.substring(nl + 1);
                    }
                    result(e.getKey(), code, block);
                    // Read, therefore finished. Terminating here rather than
                    // waiting for the machine's own timer is the difference
                    // between paying for the work and paying for the backstop.
                    try {
                        var cred = account.clouds().get(run.provider());
                        var impl = Provisioners.of(run.provider(), aws);
                        if (cred != null && impl != null) impl.destroy(cred, run.machineId());
                    } catch (Exception x) {
                        // It shuts itself down anyway; this only makes it sooner.
                    }
                    return true;
                } catch (Exception x) {
                    // The console is not ready, or the instance is gone. Either
                    // way there is another sweep along shortly.
                }
            }
        }
        return false;
    }

    /** A machine reporting what happened. Returns false for an unknown token. */
    boolean result(String token, int code, String output) {
        var run = pending.remove(token);
        if (run == null) return false;
        long seconds = (System.currentTimeMillis() - run.startedMillis()) / 1000;
        appendResult(run, code, output, seconds);
        return true;
    }

    /** What finished since last time, as text for the next prompt. */
    String briefing(Accounts.Account account) {
        var file = root.resolve(account.id()).resolve("runs.log");
        if (!Files.exists(file)) return "";
        try {
            var lines = Files.readAllLines(file, StandardCharsets.UTF_8);
            if (lines.isEmpty()) return "";
            int from = Math.max(0, lines.size() - 12);
            var b = new StringBuilder("RECENT RUNS:\n");
            for (var l : lines.subList(from, lines.size())) b.append("  ").append(l).append('\n');
            return b.append('\n').toString();
        } catch (Exception x) {
            return "";
        }
    }

    private void appendResult(Run run, int code, String output, long seconds) {
        String head = output == null ? "" : output.strip();
        if (head.length() > 2000) head = head.substring(0, 2000) + "...[truncated]";
        record(run.accountId(), "%s %s finished in %ds, exit %d%n%s"
                .formatted(run.provider().id, run.size().id, seconds, code, indent(head)));
    }

    private static String indent(String s) {
        return s.isBlank() ? "    (no output)" : "    " + s.replace("\n", "\n    ");
    }

    private void record(Accounts.Account account, String line) {
        record(account.id(), line);
    }

    private void record(String accountId, String line) {
        try {
            var dir = root.resolve(accountId);
            Files.createDirectories(dir);
            Files.writeString(dir.resolve("runs.log"),
                    "%s  %s%n".formatted(Instant.now(), line),
                    StandardCharsets.UTF_8, StandardOpenOption.CREATE, StandardOpenOption.APPEND);
        } catch (Exception x) {
            System.out.printf("armedit: could not record run for %s: %s%n", accountId, x.getMessage());
        }
    }
}
