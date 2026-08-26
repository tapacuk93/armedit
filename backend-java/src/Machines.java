import java.util.EnumMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * The same three machine sizes, spelled the way each cloud spells them.
 *
 * The point is that a user can say "rerun this on Alibaba, then on Google,
 * smallest Linux" without knowing that one of them calls it `ecs.t6-c1m1.large`
 * and another calls it `e2-micro`. A size class is the unit of intent; the
 * table below is the only place the translation lives.
 *
 * Images are all a current, minimal, x86-or-ARM Linux with a package manager
 * and cloud-init, because that is what running someone's code needs and
 * nothing more.
 */
final class Machines {

    /** What the user means when they say "smallest", "small" or "bigger". */
    enum Size {
        SMALLEST("smallest", "one shared vCPU, ~1 GB - enough to run a script"),
        SMALL("small", "two vCPUs, ~4 GB - builds and test suites"),
        MEDIUM("medium", "four vCPUs, ~8 GB - heavier work");

        final String id;
        final String about;

        Size(String id, String about) {
            this.id = id;
            this.about = about;
        }

        static Size of(String s) {
            if (s == null || s.isBlank()) return SMALLEST;
            String k = s.toLowerCase(Locale.ROOT).trim();
            for (var v : values()) if (v.id.equals(k)) return v;
            return switch (k) {
                case "tiny", "nano", "micro", "cheapest" -> SMALLEST;
                case "big", "large" -> MEDIUM;
                default -> SMALLEST;
            };
        }
    }

    /** One machine, as a particular cloud names it. */
    record Spec(String type, String image, String user) {}

    private static final Map<Clouds.Provider, Map<Size, Spec>> CATALOG =
            new EnumMap<>(Clouds.Provider.class);

    static {
        CATALOG.put(Clouds.Provider.AWS, Map.of(
                Size.SMALLEST, new Spec("t4g.nano", "al2023-arm64", "ec2-user"),
                Size.SMALL, new Spec("t4g.small", "al2023-arm64", "ec2-user"),
                Size.MEDIUM, new Spec("t4g.large", "al2023-arm64", "ec2-user")));

        CATALOG.put(Clouds.Provider.HETZNER, Map.of(
                Size.SMALLEST, new Spec("cax11", "debian-12", "root"),
                Size.SMALL, new Spec("cax21", "debian-12", "root"),
                Size.MEDIUM, new Spec("cax31", "debian-12", "root")));

        CATALOG.put(Clouds.Provider.DIGITALOCEAN, Map.of(
                Size.SMALLEST, new Spec("s-1vcpu-1gb", "debian-12-x64", "root"),
                Size.SMALL, new Spec("s-2vcpu-4gb", "debian-12-x64", "root"),
                Size.MEDIUM, new Spec("s-4vcpu-8gb", "debian-12-x64", "root")));

        CATALOG.put(Clouds.Provider.ALIBABA, Map.of(
                Size.SMALLEST, new Spec("ecs.t6-c1m1.large", "debian_12_amd64", "root"),
                Size.SMALL, new Spec("ecs.t6-c1m2.large", "debian_12_amd64", "root"),
                Size.MEDIUM, new Spec("ecs.c6.xlarge", "debian_12_amd64", "root")));

        CATALOG.put(Clouds.Provider.GCP, Map.of(
                Size.SMALLEST, new Spec("e2-micro", "debian-cloud/debian-12", "debian"),
                Size.SMALL, new Spec("e2-medium", "debian-cloud/debian-12", "debian"),
                Size.MEDIUM, new Spec("e2-standard-4", "debian-cloud/debian-12", "debian")));

        CATALOG.put(Clouds.Provider.AZURE, Map.of(
                Size.SMALLEST, new Spec("Standard_B1s", "Debian:debian-12:12:latest", "azureuser"),
                Size.SMALL, new Spec("Standard_B2s", "Debian:debian-12:12:latest", "azureuser"),
                Size.MEDIUM, new Spec("Standard_D4s_v5", "Debian:debian-12:12:latest", "azureuser")));
    }

    private Machines() {}

    static Spec spec(Clouds.Provider provider, Size size) {
        var perSize = CATALOG.get(provider);
        return perSize == null ? null : perSize.get(size);
    }

    /**
     * What the model is told it can ask for. Names and sizes only - which is
     * all it needs, since it never holds the credential that would let it act
     * on any of them directly.
     */
    static String briefing(List<Clouds.Provider> bound) {
        if (bound.isEmpty()) return "";
        var b = new StringBuilder("""
                You can run the user's code on any cloud they have bound, by writing a line:

                    #RUN <provider> <size> <shell command>

                for example

                    #RUN hetzner smallest  python3 main.py
                    #RUN alibaba smallest  ./build.sh && ./run-tests.sh

                The backend brings up a machine of that size, runs the command on it through
                cloud-init, and reports back. Sizes:
                """);
        for (var s : Size.values()) {
            b.append("  - ").append(s.id).append(": ").append(s.about).append('\n');
        }
        b.append("Bound to this account: ");
        for (int i = 0; i < bound.size(); i++) {
            if (i > 0) b.append(", ");
            var p = bound.get(i);
            b.append(p.id);
            if (!p.provisions) b.append(" (credentials only, cannot run yet)");
        }
        b.append(".\nWhen the user asks to try the same thing on several clouds, write one line ")
         .append("per cloud and they will be run in order.\n");
        return b.toString();
    }
}
