import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Duration;
import java.time.ZoneOffset;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.Base64;
import java.util.HexFormat;
import java.util.regex.Pattern;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * EC2, signed with Signature Version 4.
 *
 * Requests are signed here rather than by an SDK, so the credentials an
 * account bound at registration are used directly and nothing else is pulled
 * into the process. What we ask for is deliberately small - one instance
 * running a minimal Linux with Docker brought up by user-data - because the
 * editor only needs somewhere to run things, and every instance is billed to
 * the account that asked for it.
 */
final class Aws {

    private static final String SERVICE = "ec2";
    private static final String ALGO = "AWS4-HMAC-SHA256";
    private static final String SIGNED_HEADERS = "host;x-amz-content-sha256;x-amz-date";
    private static final String EC2_VERSION = "2016-11-15";

    private static final DateTimeFormatter AMZ =
            DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'");
    private static final DateTimeFormatter STAMP =
            DateTimeFormatter.ofPattern("yyyyMMdd");

    private static final Pattern INSTANCE_ID =
            Pattern.compile("<instanceId>([^<]+)</instanceId>");

    /** cloud-init for the account's box: a minimal Linux with Docker running. */
    private static final String USER_DATA = """
            #!/bin/bash
            dnf install -y docker
            systemctl enable --now docker
            docker run -d --restart=always --name armedit alpine:3 sleep infinity
            """;

    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .build();

    private final String endpointOverride;   // e.g. a local EC2-compatible endpoint
    private final String ami;
    private final String instanceType;

    Aws(String endpointOverride, String ami, String instanceType) {
        this.endpointOverride = endpointOverride;
        this.ami = ami;
        this.instanceType = (instanceType == null || instanceType.isBlank())
                ? "t4g.small" : instanceType.trim();
    }

    boolean configured() { return ami != null && !ami.isBlank(); }

    /** Bring up this account's instance, or return the one it already has. */
    String provision(Accounts.Account a) throws Exception {
        if (!a.instance().isBlank()) return a.instance();
        if (!configured()) throw new IllegalStateException("ARMEDIT_AMI is not set");
        String body = "Action=RunInstances&Version=%s&MinCount=1&MaxCount=1&ImageId=%s&InstanceType=%s&UserData=%s"
                .formatted(EC2_VERSION, enc(ami), enc(instanceType),
                        enc(Base64.getEncoder().encodeToString(USER_DATA.getBytes(StandardCharsets.UTF_8))));
        String xml = call(a, body);
        var m = INSTANCE_ID.matcher(xml);
        if (!m.find()) throw new IllegalStateException("no instanceId in reply: " + trim(xml));
        a.instance(m.group(1));
        return a.instance();
    }

    /** Terminate it and forget it. Doing this twice is not an error. */
    /**
     * What the machine has printed to its serial console, or "" if nothing yet.
     *
     * This exists because the obvious way for a run to report back - the
     * machine posting its output to us - needs us to be reachable from EC2,
     * and a backend running on somebody's laptop is not. The console is the
     * one channel that flows the other way: the instance writes, we read,
     * nothing has to route inward.
     *
     * It is slower and coarser than a callback. AWS refreshes the buffer every
     * few minutes rather than instantly, and everything the kernel says is in
     * there too, which is why the run brackets its own output with markers.
     * The callback stays the better path when the backend has an address; this
     * is what makes a laptop work at all.
     */
    String consoleOutput(Accounts.Account a, String instanceId) throws Exception {
        String body = "Action=GetConsoleOutput&Version=%s&InstanceId=%s&Latest=true"
                .formatted(EC2_VERSION, enc(instanceId));
        String xml = call(a, body);
        var m = java.util.regex.Pattern.compile("<output>([^<]*)</output>").matcher(xml);
        if (!m.find()) return "";
        try {
            return new String(Base64.getMimeDecoder().decode(m.group(1)),
                    StandardCharsets.UTF_8);
        } catch (IllegalArgumentException bad) {
            return "";
        }
    }

    void deprovision(Accounts.Account a) throws Exception {
        if (a.instance().isBlank()) return;
        String body = "Action=TerminateInstances&Version=%s&InstanceId.1=%s"
                .formatted(EC2_VERSION, enc(a.instance()));
        call(a, body);
        a.instance("");
    }

    /**
     * A signed call to any supported service, on behalf of an account.
     *
     * This is the only path by which the model's proposals reach AWS, and the
     * account's credentials never leave this method's frame: they sign the
     * request here and what comes back is the only thing anyone upstream sees.
     *
     * @param service one of {@link Wire}'s services
     * @param action  the API action, e.g. DescribeInstances
     * @param paramsJson flat JSON of parameters
     */
    String query(Accounts.Account a, String service, String action, String paramsJson) throws Exception {
        var wire = Wire.of(service);
        if (wire == null) {
            throw new IllegalArgumentException(
                    "service " + service + " is not wired up here yet; supported: " + Wire.names());
        }
        var params = Json.parse(paramsJson == null ? "{}" : paramsJson);
        return switch (wire.protocol) {
            case QUERY -> {
                var form = new StringBuilder("Action=").append(enc(action))
                        .append("&Version=").append(enc(wire.version));
                params.forEach((k, v) -> form.append('&').append(enc(k)).append('=').append(enc(v)));
                yield send(a, wire, "POST", "/", form.toString(),
                        "application/x-www-form-urlencoded; charset=utf-8", null);
            }
            case JSON -> {
                var body = paramsJson == null || paramsJson.isBlank() ? "{}" : paramsJson;
                yield send(a, wire, "POST", "/", body,
                        "application/x-amz-json-1.1", wire.targetPrefix + "." + action);
            }
            case REST_XML -> send(a, wire, "GET", "/", "", "application/xml", null);
        };
    }

    /**
     * Put one object in S3 - the third tier of a screen's persistence.
     * Signed like everything else here, with the account's own credentials.
     */
    void putObject(Accounts.Account a, String bucket, String key, byte[] body) throws Exception {
        String host = "%s.s3.%s.amazonaws.com".formatted(bucket, a.region());
        String path = "/" + key;                       // key segments are already safe
        var now = ZonedDateTime.now(ZoneOffset.UTC);
        String amzDate = AMZ.format(now);
        String stamp = STAMP.format(now);
        String payloadHash = hex(sha256(body));

        String canonical = String.join("\n",
                "PUT", path, "",
                "host:" + host,
                "x-amz-content-sha256:" + payloadHash,
                "x-amz-date:" + amzDate,
                "",
                SIGNED_HEADERS,
                payloadHash);

        String scope = "%s/%s/s3/aws4_request".formatted(stamp, a.region());
        String toSign = String.join("\n", ALGO, amzDate, scope,
                hex(sha256(canonical.getBytes(StandardCharsets.UTF_8))));

        byte[] k = hmac(("AWS4" + a.awsSecret()).getBytes(StandardCharsets.UTF_8), stamp);
        k = hmac(k, a.region());
        k = hmac(k, "s3");
        k = hmac(k, "aws4_request");
        String signature = hex(hmac(k, toSign));

        var req = HttpRequest.newBuilder(URI.create("https://" + host + path))
                .timeout(Duration.ofSeconds(60))
                .header("x-amz-date", amzDate)
                .header("x-amz-content-sha256", payloadHash)
                .header("Authorization", "%s Credential=%s/%s, SignedHeaders=%s, Signature=%s"
                        .formatted(ALGO, a.awsKey(), scope, SIGNED_HEADERS, signature))
                .PUT(HttpRequest.BodyPublishers.ofByteArray(body))
                .build();

        var res = http.send(req, HttpResponse.BodyHandlers.ofString());
        if (res.statusCode() / 100 != 2) {
            throw new IllegalStateException("s3 put %d: %s".formatted(res.statusCode(), trim(res.body())));
        }
    }

    /** How a service expects to be spoken to. */
    private enum Protocol { QUERY, JSON, REST_XML }

    private record Wire(String service, String hostPattern, Protocol protocol,
                        String version, String targetPrefix) {

        private static final java.util.Map<String, Wire> ALL = java.util.Map.ofEntries(
                java.util.Map.entry("ec2", new Wire("ec2", "ec2.%s.amazonaws.com", Protocol.QUERY, "2016-11-15", "")),
                java.util.Map.entry("rds", new Wire("rds", "rds.%s.amazonaws.com", Protocol.QUERY, "2014-10-31", "")),
                java.util.Map.entry("elasticloadbalancing", new Wire("elasticloadbalancing",
                        "elasticloadbalancing.%s.amazonaws.com", Protocol.QUERY, "2015-12-01", "")),
                java.util.Map.entry("cloudformation", new Wire("cloudformation",
                        "cloudformation.%s.amazonaws.com", Protocol.QUERY, "2010-05-15", "")),
                java.util.Map.entry("cloudwatch", new Wire("monitoring",
                        "monitoring.%s.amazonaws.com", Protocol.QUERY, "2010-08-01", "")),
                java.util.Map.entry("autoscaling", new Wire("autoscaling",
                        "autoscaling.%s.amazonaws.com", Protocol.QUERY, "2011-01-01", "")),
                java.util.Map.entry("logs", new Wire("logs", "logs.%s.amazonaws.com",
                        Protocol.JSON, "", "Logs_20140328")),
                java.util.Map.entry("ecs", new Wire("ecs", "ecs.%s.amazonaws.com",
                        Protocol.JSON, "", "AmazonEC2ContainerServiceV20141113")),
                java.util.Map.entry("dynamodb", new Wire("dynamodb", "dynamodb.%s.amazonaws.com",
                        Protocol.JSON, "", "DynamoDB_20120810")),
                java.util.Map.entry("ce", new Wire("ce", "ce.us-east-1.amazonaws.com",
                        Protocol.JSON, "", "AWSInsightsIndexService")),
                java.util.Map.entry("s3", new Wire("s3", "s3.%s.amazonaws.com", Protocol.REST_XML, "", "")));

        static Wire of(String service) { return ALL.get(service); }

        static String names() { return String.join(", ", new java.util.TreeSet<>(ALL.keySet())); }

        String host(String region) {
            return hostPattern.contains("%s") ? hostPattern.formatted(region) : hostPattern;
        }
    }

    private String send(Accounts.Account a, Wire wire, String method, String path,
                        String body, String contentType, String amzTarget) throws Exception {
        String host = wire.host(a.region());
        var now = ZonedDateTime.now(ZoneOffset.UTC);
        String amzDate = AMZ.format(now);
        String stamp = STAMP.format(now);
        String payloadHash = hex(sha256(body.getBytes(StandardCharsets.UTF_8)));

        // The signed header set grows by one when a target is present, and the
        // canonical request has to agree with what actually goes on the wire.
        String signedHeaders = amzTarget == null
                ? SIGNED_HEADERS
                : "host;x-amz-content-sha256;x-amz-date;x-amz-target";
        var canonicalHeaders = new StringBuilder()
                .append("host:").append(host).append('\n')
                .append("x-amz-content-sha256:").append(payloadHash).append('\n')
                .append("x-amz-date:").append(amzDate).append('\n');
        if (amzTarget != null) canonicalHeaders.append("x-amz-target:").append(amzTarget).append('\n');

        String canonical = String.join("\n",
                method, path, "", canonicalHeaders.toString().stripTrailing(), "",
                signedHeaders, payloadHash);

        String signingRegion = wire.hostPattern.contains("%s") ? a.region() : "us-east-1";
        String scope = "%s/%s/%s/aws4_request".formatted(stamp, signingRegion, wire.service);
        String toSign = String.join("\n", ALGO, amzDate, scope,
                hex(sha256(canonical.getBytes(StandardCharsets.UTF_8))));

        byte[] k = hmac(("AWS4" + a.awsSecret()).getBytes(StandardCharsets.UTF_8), stamp);
        k = hmac(k, signingRegion);
        k = hmac(k, wire.service);
        k = hmac(k, "aws4_request");
        String signature = hex(hmac(k, toSign));

        // Signed against the real host, sent wherever the override says: that
        // is what lets a local or proxied endpoint see a signature it could
        // forward to AWS unchanged.
        String url = (endpointOverride == null || endpointOverride.isBlank())
                ? "https://" + host + path
                : endpointOverride.replaceAll("/+$", "") + path;

        var req = HttpRequest.newBuilder(URI.create(url))
                .timeout(Duration.ofSeconds(60))
                .header("Content-Type", contentType)
                .header("x-amz-date", amzDate)
                .header("x-amz-content-sha256", payloadHash)
                .header("Authorization", "%s Credential=%s/%s, SignedHeaders=%s, Signature=%s"
                        .formatted(ALGO, a.awsKey(), scope, signedHeaders, signature));
        if (amzTarget != null) req.header("X-Amz-Target", amzTarget);
        var built = method.equals("GET")
                ? req.GET().build()
                : req.POST(HttpRequest.BodyPublishers.ofString(body)).build();

        var res = http.send(built, HttpResponse.BodyHandlers.ofString());
        if (res.statusCode() / 100 != 2) {
            throw new IllegalStateException("%s %d: %s".formatted(wire.service, res.statusCode(),
                    trim(res.body())));
        }
        return res.body();
    }

    /**
     * Start a machine for one run, from credentials rather than an account.
     *
     * The session instance and a run's machine are different things and this is
     * where that stops being blurred. A session is one long-lived box per
     * account, brought up from a fixed image; a run wants its own throwaway of
     * a stated size, carrying its own script, terminated when it is done. They
     * happen to be the same API call and nothing else.
     *
     * Tagged with its name so a machine that outlives its run can still be
     * recognised, which matters when the thing that would have cleaned it up is
     * the thing that crashed.
     */
    String runInstance(Clouds.Credential cred, String image, String type,
                       String name, String userData) throws Exception {
        String body = ("Action=RunInstances&Version=%s&MinCount=1&MaxCount=1"
                + "&ImageId=%s&InstanceType=%s&UserData=%s"
                + "&InstanceInitiatedShutdownBehavior=terminate"
                + "&TagSpecification.1.ResourceType=instance"
                + "&TagSpecification.1.Tag.1.Key=Name"
                + "&TagSpecification.1.Tag.1.Value=%s")
                .formatted(EC2_VERSION, enc(image), enc(type),
                        enc(Base64.getEncoder().encodeToString(
                                userData.getBytes(StandardCharsets.UTF_8))),
                        enc(name));
        String xml = callWith(cred, body);
        var m = INSTANCE_ID.matcher(xml);
        if (!m.find()) throw new IllegalStateException("no instanceId in reply: " + trim(xml));
        return m.group(1);
    }

    /** Terminate one machine, from credentials rather than an account. */
    void terminate(Clouds.Credential cred, String instanceId) throws Exception {
        callWith(cred, "Action=TerminateInstances&Version=%s&InstanceId.1=%s"
                .formatted(EC2_VERSION, enc(instanceId)));
    }

    /** As {@link #consoleOutput} but for a run's own credentials. */
    String consoleOutput(Clouds.Credential cred, String instanceId) throws Exception {
        String xml = callWith(cred,
                "Action=GetConsoleOutput&Version=%s&InstanceId=%s&Latest=true"
                        .formatted(EC2_VERSION, enc(instanceId)));
        var m = java.util.regex.Pattern.compile("<output>([^<]*)</output>").matcher(xml);
        if (!m.find()) return "";
        try {
            return new String(Base64.getMimeDecoder().decode(m.group(1)), StandardCharsets.UTF_8);
        } catch (IllegalArgumentException bad) {
            return "";
        }
    }

    private String call(Accounts.Account a, String body) throws Exception {
        return sign(a.awsKey(), a.awsSecret(), a.region(), body);
    }

    /**
     * The same request, signed from a cloud credential.
     *
     * A run's machine is started with the credential the account bound, not
     * with the account object, because a run belongs to a cloud binding rather
     * than to a session. Same signature, same endpoint; only where the key
     * comes from differs.
     */
    private String callWith(Clouds.Credential cred, String body) throws Exception {
        var f = cred.fields();
        String region = f.getOrDefault("region", "us-east-1");
        if (region == null || region.isBlank()) region = "us-east-1";
        return sign(f.get("access_key"), f.get("secret_key"), region, body);
    }

    private String sign(String awsKey, String awsSecret, String region, String body)
            throws Exception {
        String host = endpointHost(region);
        var now = ZonedDateTime.now(ZoneOffset.UTC);
        String amzDate = AMZ.format(now);
        String stamp = STAMP.format(now);
        String payloadHash = hex(sha256(body.getBytes(StandardCharsets.UTF_8)));

        String canonical = String.join("\n",
                "POST",
                "/",
                "",
                "host:" + host,
                "x-amz-content-sha256:" + payloadHash,
                "x-amz-date:" + amzDate,
                "",
                SIGNED_HEADERS,
                payloadHash);

        String scope = "%s/%s/%s/aws4_request".formatted(stamp, region, SERVICE);
        String toSign = String.join("\n", ALGO, amzDate, scope,
                hex(sha256(canonical.getBytes(StandardCharsets.UTF_8))));

        byte[] k = hmac(("AWS4" + awsSecret).getBytes(StandardCharsets.UTF_8), stamp);
        k = hmac(k, region);
        k = hmac(k, SERVICE);
        k = hmac(k, "aws4_request");
        String signature = hex(hmac(k, toSign));

        String authorization = "%s Credential=%s/%s, SignedHeaders=%s, Signature=%s"
                .formatted(ALGO, awsKey, scope, SIGNED_HEADERS, signature);

        var req = HttpRequest.newBuilder(URI.create(endpointUrl(region)))
                .timeout(Duration.ofSeconds(60))
                .header("Content-Type", "application/x-www-form-urlencoded; charset=utf-8")
                .header("x-amz-date", amzDate)
                .header("x-amz-content-sha256", payloadHash)
                .header("Authorization", authorization)
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .build();

        var res = http.send(req, HttpResponse.BodyHandlers.ofString());
        if (res.statusCode() / 100 != 2) {
            throw new IllegalStateException("ec2 %d: %s".formatted(res.statusCode(), trim(res.body())));
        }
        return res.body();
    }

    /**
     * The Host header must match what was signed. With an override we still
     * sign the real EC2 host, so a local or proxied endpoint sees a signature
     * it could forward unchanged.
     */
    private String endpointHost(String region) {
        return "ec2.%s.amazonaws.com".formatted(region);
    }

    private String endpointUrl(String region) {
        if (endpointOverride != null && !endpointOverride.isBlank()) return endpointOverride;
        return "https://" + endpointHost(region) + "/";
    }

    private static byte[] sha256(byte[] b) throws Exception {
        return MessageDigest.getInstance("SHA-256").digest(b);
    }

    private static byte[] hmac(byte[] key, String data) throws Exception {
        var mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(key, "HmacSHA256"));
        return mac.doFinal(data.getBytes(StandardCharsets.UTF_8));
    }

    private static String hex(byte[] b) { return HexFormat.of().formatHex(b); }

    private static String enc(String s) {
        return java.net.URLEncoder.encode(s, StandardCharsets.UTF_8).replace("+", "%20");
    }

    private static String trim(String s) {
        return s.length() <= 400 ? s : s.substring(0, 400) + "...";
    }
}
