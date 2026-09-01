import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.Base64;
import java.util.Map;
import java.util.TreeMap;
import java.util.UUID;
import java.util.regex.Pattern;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * Bringing a machine up on whichever cloud was asked for.
 *
 * One interface, one implementation per cloud, because "rerun this on Alibaba,
 * then on Google, smallest Linux" should differ only in which of these gets
 * called. The differences between them are entirely in how a request is
 * authenticated - a bearer token for two of them, a signature for the other
 * two - and none of that reaches the caller.
 *
 * Credentials are read from the account and used here. As everywhere in this
 * backend, they are never handed to a model: it names a provider and a size,
 * and this code does the rest.
 */
final class Provisioners {

    /** A machine that now exists, as the cloud that made it refers to it. */
    record Machine(String id, String ip) {}

    interface Provisioner {
        Machine create(Clouds.Credential cred, Machines.Spec spec, String name, String cloudInit)
                throws Exception;

        void destroy(Clouds.Credential cred, String id) throws Exception;
    }

    private static final HttpClient HTTP = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(15))
            .build();

    private Provisioners() {}

    static Provisioner of(Clouds.Provider provider, Aws aws) {
        return switch (provider) {
            case HETZNER -> new Hetzner();
            case DIGITALOCEAN -> new DigitalOcean();
            case ALIBABA -> new Alibaba();
            case AWS -> new AwsBacked(aws);
            case GCP, AZURE -> null;    // credentials accepted, provisioning not written yet
        };
    }

    /* --------------------------------------------------------------- AWS */

    /**
     * EC2 already has a signed client in {@link Aws}; this only adapts it.
     *
     * This used to refuse, on the grounds that EC2 machines came up through the
     * session endpoint. That was true of the session's own long-lived box and
     * had nothing to do with a run, which wants its own throwaway - so asking
     * to run anything on AWS failed with an explanation of where machines come
     * from, and the model dutifully repeated that explanation to the user
     * instead of running their code.
     */
    private record AwsBacked(Aws aws) implements Provisioner {
        @Override
        public Machine create(Clouds.Credential cred, Machines.Spec spec, String name, String cloudInit)
                throws Exception {
            String image = System.getenv("ARMEDIT_AMI");
            if (image == null || image.isBlank()) {
                throw new IllegalStateException("ARMEDIT_AMI is not set, so there is no image to boot");
            }
            return new Machine(aws.runInstance(cred, image, spec.type(), name, cloudInit), "");
        }

        @Override
        public void destroy(Clouds.Credential cred, String id) throws Exception {
            aws.terminate(cred, id);
        }
    }

    /* ----------------------------------------------------------- Hetzner */

    /**
     * A bearer token and one POST. The cheapest of the bunch by a wide margin,
     * which is why the chooser reaches for it when nothing ties the work to a
     * particular cloud.
     */
    private static final class Hetzner implements Provisioner {
        private static final Pattern ID = Pattern.compile("\"id\"\\s*:\\s*(\\d+)");
        private static final Pattern IP = Pattern.compile("\"ip\"\\s*:\\s*\"([0-9.]+)\"");

        @Override
        public Machine create(Clouds.Credential cred, Machines.Spec spec, String name, String cloudInit)
                throws Exception {
            String body = """
                    {"name":"%s","server_type":"%s","image":"%s","location":"nbg1",\
                    "start_after_create":true,"user_data":"%s"}"""
                    .formatted(name, spec.type(), spec.image(), Json.escape(cloudInit));
            var res = post("https://api.hetzner.cloud/v1/servers",
                    cred.fields().get("api_token"), body);
            var id = ID.matcher(res);
            var ip = IP.matcher(res);
            if (!id.find()) throw new IllegalStateException("hetzner: no server id in " + trim(res));
            return new Machine(id.group(1), ip.find() ? ip.group(1) : "");
        }

        @Override
        public void destroy(Clouds.Credential cred, String id) throws Exception {
            delete("https://api.hetzner.cloud/v1/servers/" + id, cred.fields().get("api_token"));
        }
    }

    /* ------------------------------------------------------ DigitalOcean */

    private static final class DigitalOcean implements Provisioner {
        private static final Pattern ID = Pattern.compile("\"id\"\\s*:\\s*(\\d+)");

        @Override
        public Machine create(Clouds.Credential cred, Machines.Spec spec, String name, String cloudInit)
                throws Exception {
            String body = """
                    {"name":"%s","region":"fra1","size":"%s","image":"%s","user_data":"%s"}"""
                    .formatted(name, spec.type(), spec.image(), Json.escape(cloudInit));
            var res = post("https://api.digitalocean.com/v2/droplets",
                    cred.fields().get("api_token"), body);
            var id = ID.matcher(res);
            if (!id.find()) throw new IllegalStateException("digitalocean: no droplet id in " + trim(res));
            return new Machine(id.group(1), "");
        }

        @Override
        public void destroy(Clouds.Credential cred, String id) throws Exception {
            delete("https://api.digitalocean.com/v2/droplets/" + id, cred.fields().get("api_token"));
        }
    }

    /* ----------------------------------------------------------- Alibaba */

    /**
     * Alibaba's RPC style: every parameter goes in the query string, sorted,
     * and the signature is HMAC-SHA1 over a canonical form of it. Older and
     * fiddlier than SigV4 - the percent-encoding has to be applied twice, in
     * the right places - but it is only twenty lines once that is said out
     * loud.
     */
    private static final class Alibaba implements Provisioner {
        private static final Pattern ID = Pattern.compile("\"InstanceIdSets\"\\s*:\\s*\\{[^}]*\"InstanceIdSet\"\\s*:\\s*\\[\\s*\"([^\"]+)\"");
        private static final DateTimeFormatter TS =
                DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC);

        @Override
        public Machine create(Clouds.Credential cred, Machines.Spec spec, String name, String cloudInit)
                throws Exception {
            var params = new TreeMap<String, String>();
            params.put("Action", "RunInstances");
            params.put("RegionId", cred.fields().getOrDefault("region_id", "eu-central-1"));
            params.put("ImageId", spec.image());
            params.put("InstanceType", spec.type());
            params.put("InstanceName", name);
            params.put("Amount", "1");
            params.put("InternetMaxBandwidthOut", "1");
            params.put("UserData", Base64.getEncoder()
                    .encodeToString(cloudInit.getBytes(StandardCharsets.UTF_8)));
            String res = rpc(cred, params);
            var id = ID.matcher(res);
            if (!id.find()) throw new IllegalStateException("alibaba: no instance id in " + trim(res));
            return new Machine(id.group(1), "");
        }

        @Override
        public void destroy(Clouds.Credential cred, String id) throws Exception {
            var params = new TreeMap<String, String>();
            params.put("Action", "DeleteInstance");
            params.put("InstanceId", id);
            params.put("Force", "true");
            rpc(cred, params);
        }

        private String rpc(Clouds.Credential cred, TreeMap<String, String> params) throws Exception {
            String region = cred.fields().getOrDefault("region_id", "eu-central-1");
            params.put("Format", "JSON");
            params.put("Version", "2014-05-26");
            params.put("AccessKeyId", cred.fields().get("access_key_id"));
            params.put("SignatureMethod", "HMAC-SHA1");
            params.put("SignatureVersion", "1.0");
            params.put("SignatureNonce", UUID.randomUUID().toString());
            params.put("Timestamp", TS.format(Instant.now()));

            var canonical = new StringBuilder();
            for (var e : params.entrySet()) {
                if (canonical.length() > 0) canonical.append('&');
                canonical.append(enc(e.getKey())).append('=').append(enc(e.getValue()));
            }
            String toSign = "GET&" + enc("/") + "&" + enc(canonical.toString());
            var mac = Mac.getInstance("HmacSHA1");
            mac.init(new SecretKeySpec(
                    (cred.fields().get("access_key_secret") + "&").getBytes(StandardCharsets.UTF_8),
                    "HmacSHA1"));
            String signature = Base64.getEncoder()
                    .encodeToString(mac.doFinal(toSign.getBytes(StandardCharsets.UTF_8)));

            String url = "https://ecs.%s.aliyuncs.com/?Signature=%s&%s"
                    .formatted(region, enc(signature), canonical);
            var req = HttpRequest.newBuilder(URI.create(url))
                    .timeout(Duration.ofSeconds(60))
                    .GET()
                    .build();
            var res = HTTP.send(req, HttpResponse.BodyHandlers.ofString());
            if (res.statusCode() / 100 != 2) {
                throw new IllegalStateException("alibaba %d: %s".formatted(res.statusCode(), trim(res.body())));
            }
            return res.body();
        }

        /** Alibaba wants RFC 3986, which URLEncoder does not quite produce. */
        private static String enc(String s) {
            return URLEncoder.encode(s, StandardCharsets.UTF_8)
                    .replace("+", "%20")
                    .replace("*", "%2A")
                    .replace("%7E", "~");
        }
    }

    /* ---------------------------------------------------------- plumbing */

    private static String post(String url, String bearer, String body) throws Exception {
        var req = HttpRequest.newBuilder(URI.create(url))
                .timeout(Duration.ofSeconds(60))
                .header("Content-Type", "application/json")
                .header("Authorization", "Bearer " + bearer)
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .build();
        var res = HTTP.send(req, HttpResponse.BodyHandlers.ofString());
        if (res.statusCode() / 100 != 2) {
            throw new IllegalStateException("%d: %s".formatted(res.statusCode(), trim(res.body())));
        }
        return res.body();
    }

    private static void delete(String url, String bearer) throws Exception {
        var req = HttpRequest.newBuilder(URI.create(url))
                .timeout(Duration.ofSeconds(60))
                .header("Authorization", "Bearer " + bearer)
                .DELETE()
                .build();
        var res = HTTP.send(req, HttpResponse.BodyHandlers.ofString());
        if (res.statusCode() / 100 != 2 && res.statusCode() != 404) {
            throw new IllegalStateException("%d: %s".formatted(res.statusCode(), trim(res.body())));
        }
    }

    private static String trim(String s) {
        return s == null ? "" : (s.length() <= 300 ? s : s.substring(0, 300) + "...");
    }

    /** Only used to keep the unused-parameter warning honest in AwsBacked. */
    static Map<String, String> noFields() { return Map.of(); }
}
