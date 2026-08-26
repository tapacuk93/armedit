import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Letting the model work on an account's AWS infrastructure without ever
 * letting it near the credentials.
 *
 * The rule this is built on: an AWS key that reaches the model has been
 * published. Everything in a prompt is seen by aicoin and by whichever
 * provider it routes to, is retained on their terms, and - because aicoin
 * multiplexes many users onto one shared provider key - sits in the same
 * upstream account as other people's traffic. A key sent there is not "shared
 * carefully", it is disclosed.
 *
 * So the model never receives one. It receives a description of what it may
 * ask for, and it asks in plain text:
 *
 *     #AWS ec2 DescribeInstances {"Filters":[{"Name":"instance-state-name","Values":["running"]}]}
 *
 * The backend parses that line, judges it against {@link AwsPolicy}, signs the
 * call with the account's own credentials, executes it, strips anything
 * secret-shaped out of the answer, and feeds the result back as text. The
 * credentials stay in this process; what crosses to the provider is a question
 * and an answer, never a key.
 *
 * A plain-text protocol rather than a provider's native tool-use format,
 * because aicoin fronts several providers whose tool formats differ - and a
 * format the backend parses itself is a format the backend can refuse.
 */
final class AwsAgent {

    /** How many action lines one exchange may run before we stop. */
    private static final int MAX_STEPS = 8;

    /** Result text handed back to the model, per call. */
    private static final int MAX_RESULT_CHARS = 6000;

    private static final Pattern ACTION = Pattern.compile(
            "(?m)^#AWS\\s+([A-Za-z0-9_-]+)\\s+([A-Za-z0-9_]+)\\s*(\\{.*\\})?\\s*$");

    /**
     * Things that must never travel back up to the provider, whatever an API
     * decided to include. EC2 user-data alone routinely carries bootstrap
     * secrets, and returning it would leak by accident what we refused to send
     * on purpose.
     */
    private static final Pattern KEY_VALUE = Pattern.compile(
            "(?i)(\"?(user_?data|secret[A-Za-z]*|password|passwd|token|" +
            "private_?key|access_?key|session_?token|authorization)\"?\\s*[:=]\\s*)" +
            "(\"[^\"]*\"|[^,\\s}]+)");

    /**
     * The EC2 and other query APIs answer in XML, where a secret is an element
     * rather than a field. Missing this would have leaked by accident exactly
     * what the design refuses to send on purpose.
     */
    private static final Pattern XML_ELEMENT = Pattern.compile(
            "(?is)<([a-z0-9:_-]*(?:userdata|password|secret|token|privatekey|accesskey)[a-z0-9:_-]*)>"
            + ".*?</\\1>");

    private static final List<Pattern> REDACTIONS = List.of(
            Pattern.compile("(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----"),
            Pattern.compile("\\bAKIA[0-9A-Z]{16}\\b"),
            Pattern.compile("\\bASIA[0-9A-Z]{16}\\b"));

    private final Aws aws;
    private final Path auditDir;

    AwsAgent(Aws aws, Path auditDir) {
        this.aws = aws;
        this.auditDir = auditDir;
    }

    /** One action the model asked for, and what came of it. */
    record Step(String service, String action, String params,
                AwsPolicy.Verdict verdict, String detail) {}

    record Outcome(String transcript, List<Step> steps, List<Step> pending) {}

    /**
     * The instructions the model is given about this facility. It describes a
     * capability, not a credential - there is nothing here worth intercepting.
     */
    static String briefing(String region) {
        return """
                You can inspect this account's AWS infrastructure. You do not have and will never \
                be given AWS credentials: instead, write an action on its own line and the backend \
                will run it for you and show you the result.

                    #AWS <service> <Action> <json params>

                for example

                    #AWS ec2 DescribeInstances {}
                    #AWS s3 ListBuckets {}
                    #AWS ce GetCostAndUsage {"TimePeriod":{"Start":"2026-08-01","End":"2026-08-27"},\
                "Granularity":"MONTHLY","Metrics":["UnblendedCost"]}

                Reads run immediately. Anything that changes infrastructure is held for the user to \
                confirm, so propose it and say plainly what it would do. Identity services (IAM, \
                STS, Organizations) are refused outright and asking will not help. The default \
                region is %s.

                Ask for what you need one step at a time; you will see each result before the next.
                """.formatted(region);
    }

    /**
     * Run whatever action lines a reply contains.
     *
     * @return the transcript to append to the conversation, the steps taken,
     *         and any steps waiting on the user
     */
    Outcome run(Accounts.Account account, String modelReply) {
        var steps = new ArrayList<Step>();
        var pending = new ArrayList<Step>();
        var transcript = new StringBuilder();

        Matcher m = ACTION.matcher(modelReply);
        int taken = 0;
        while (m.find() && taken < MAX_STEPS) {
            taken++;
            String service = m.group(1);
            String action = m.group(2);
            String params = m.group(3) == null ? "{}" : m.group(3);

            var decision = AwsPolicy.judge(service, action);
            switch (decision.verdict()) {
                case DENY -> {
                    var step = new Step(service, action, params, decision.verdict(), decision.reason());
                    steps.add(step);
                    audit(account, step);
                    transcript.append("#AWS %s %s -> REFUSED: %s%n"
                            .formatted(service, action, decision.reason()));
                }
                case CONFIRM -> {
                    String id = UUID.randomUUID().toString().substring(0, 8);
                    var step = new Step(service, action, params, decision.verdict(), id);
                    steps.add(step);
                    pending.add(step);
                    audit(account, step);
                    transcript.append("#AWS %s %s -> HELD FOR CONFIRMATION (%s): %s%n"
                            .formatted(service, action, id, decision.reason()));
                }
                case ALLOW -> {
                    String detail;
                    try {
                        String raw = aws.query(account, service.toLowerCase(Locale.ROOT), action, params);
                        detail = clamp(redact(raw));
                    } catch (Exception x) {
                        detail = "error: " + x.getMessage();
                    }
                    var step = new Step(service, action, params, decision.verdict(), detail);
                    steps.add(step);
                    audit(account, step);
                    transcript.append("#AWS %s %s ->%n%s%n".formatted(service, action, detail));
                }
            }
        }
        return new Outcome(transcript.toString(), steps, pending);
    }

    /** Strip anything secret-shaped before it goes back up to the provider. */
    static String redact(String s) {
        String out = KEY_VALUE.matcher(s).replaceAll("$1\"[redacted]\"");
        out = XML_ELEMENT.matcher(out).replaceAll("<$1>[redacted]</$1>");
        for (var p : REDACTIONS) out = p.matcher(out).replaceAll("[redacted]");
        return out;
    }

    private static String clamp(String s) {
        return s.length() <= MAX_RESULT_CHARS
                ? s
                : s.substring(0, MAX_RESULT_CHARS) + "\n...[truncated]";
    }

    /**
     * Every proposal, allowed or not, on disk under the account's own folder.
     * An agent acting on infrastructure without a record of what it asked for
     * is not something anyone should run.
     */
    private void audit(Accounts.Account account, Step step) {
        try {
            var dir = auditDir.resolve(account.id());
            Files.createDirectories(dir);
            var line = "%s\t%s\t%s\t%s\t%s%n".formatted(
                    Instant.now(), step.verdict(), step.service(), step.action(),
                    step.params().replace("\n", " "));
            Files.writeString(dir.resolve("aws-audit.log"), line,
                    StandardCharsets.UTF_8, StandardOpenOption.CREATE, StandardOpenOption.APPEND);
        } catch (Exception x) {
            System.out.printf("asmedit: audit write failed for %s: %s%n", account.id(), x.getMessage());
        }
    }

    /** Parse the flat params object into form fields for the query protocol. */
    static Map<String, String> params(String json) {
        var out = new LinkedHashMap<String, String>();
        if (json == null || json.isBlank()) return out;
        out.putAll(Json.parse(json));
        return out;
    }
}
