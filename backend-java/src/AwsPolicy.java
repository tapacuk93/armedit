import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * What the model is allowed to ask AWS to do on an account's behalf.
 *
 * The model never holds credentials, so this is not a lock on a key - it is a
 * lock on an *intent*. Every action the model proposes arrives here first, and
 * the answer is one of three things: run it, ask the human, or refuse.
 *
 * Default posture: reading is free, changing costs a confirmation, and a short
 * list of things is never done at all no matter who asks. That last list
 * exists because some AWS calls cannot be undone and some would hand over the
 * account itself - an agent that can edit IAM can grant itself anything, which
 * makes every other control here decorative.
 */
final class AwsPolicy {

    enum Verdict { ALLOW, CONFIRM, DENY }

    record Decision(Verdict verdict, String reason) {
        static Decision allow() { return new Decision(Verdict.ALLOW, ""); }
        static Decision confirm(String why) { return new Decision(Verdict.CONFIRM, why); }
        static Decision deny(String why) { return new Decision(Verdict.DENY, why); }
    }

    /**
     * Never, by anyone. Privilege escalation, credential exfiltration, and the
     * handful of deletions that take the account down with them.
     */
    private static final Set<String> FORBIDDEN_SERVICES = Set.of(
            "iam", "sts", "organizations", "account", "sso", "identitystore");

    private static final List<String> FORBIDDEN_ACTIONS = List.of(
            "deletebucket",
            "deletetrail", "stoplogging",           // do not blind the audit trail
            "deletedbcluster", "deletedbinstance",
            "deletekey", "scheduleKeyDeletion",
            "putbucketpolicy", "putbucketacl",      // silent exposure of data
            "createaccesskey", "updateassumerolepolicy",
            "deletestack");                         // takes whole environments

    /** Reading. Cheap, reversible, and where nearly all agent work happens. */
    private static final List<String> READ_PREFIXES = List.of(
            "describe", "list", "get", "search", "lookup", "scan", "query",
            "head", "batchget", "estimate", "simulate", "validate");

    private AwsPolicy() {}

    static Decision judge(String service, String action) {
        String s = service == null ? "" : service.toLowerCase(Locale.ROOT).trim();
        String a = action == null ? "" : action.toLowerCase(Locale.ROOT).trim();

        if (s.isEmpty() || a.isEmpty()) {
            return Decision.deny("service and action are both required");
        }
        if (FORBIDDEN_SERVICES.contains(s)) {
            return Decision.deny(
                    "%s is never reachable from here: an agent that can edit identity can grant itself everything else"
                            .formatted(s));
        }
        for (var f : FORBIDDEN_ACTIONS) {
            if (a.equals(f.toLowerCase(Locale.ROOT))) {
                return Decision.deny(f + " is not reversible enough to do on a model's say-so");
            }
        }
        for (var p : READ_PREFIXES) {
            if (a.startsWith(p)) return Decision.allow();
        }
        return Decision.confirm("%s:%s changes infrastructure".formatted(s, action));
    }

    /**
     * The session policy handed to STS when assuming the account's role. Even
     * if everything above were bypassed, AWS itself would refuse anything
     * outside this - the model's blast radius is bounded by the cloud, not
     * only by our own code.
     */
    static String sessionPolicy() {
        return """
                {"Version":"2012-10-17","Statement":[
                  {"Effect":"Allow","Action":["ec2:Describe*","s3:List*","s3:Get*","cloudwatch:Get*",\
                "cloudwatch:List*","logs:Describe*","logs:Get*","logs:FilterLogEvents","rds:Describe*",\
                "lambda:List*","lambda:Get*","ecs:Describe*","ecs:List*","cloudformation:Describe*",\
                "cloudformation:List*","ce:GetCostAndUsage"],"Resource":"*"},
                  {"Effect":"Deny","Action":["iam:*","sts:*","organizations:*","account:*"],"Resource":"*"}
                ]}""";
    }
}
