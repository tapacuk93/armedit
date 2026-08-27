import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import javax.tools.FileObject;
import javax.tools.ForwardingJavaFileManager;
import javax.tools.JavaCompiler;
import javax.tools.JavaFileObject;
import javax.tools.SimpleJavaFileObject;
import javax.tools.StandardJavaFileManager;
import javax.tools.ToolProvider;

/**
 * Scripts as code, compiled once and then left to the JIT.
 *
 * A template can only substitute. It cannot branch on which language was
 * asked for, cannot compute, and cannot decide it is the wrong tool for a
 * particular request. So a script may instead be a Java method body: the
 * model writes it, this compiles it in memory, and every later request that
 * matches runs compiled bytecode. Run it enough and HotSpot compiles it to
 * machine code like any other hot method, which is the point - the fast path
 * gets faster the more it is used, without anybody tending it.
 *
 * <h2>This executes code a model wrote, and that is exactly as dangerous as
 * it sounds</h2>
 *
 * The filter below rejects sources mentioning the obvious ways out - process
 * launch, filesystem, network, reflection, class loading. <b>It is a speed
 * bump and not a sandbox.</b> A denylist over Java source cannot be complete;
 * anyone who has tried has lost. It is here to catch a model that wandered,
 * not a model that was aimed.
 *
 * The real boundary is a process boundary. This project already has one - the
 * per-account machines in {@link Runner} - and a deployment that runs
 * untrusted scripts in earnest should compile and run them there, with no
 * filesystem and no network, rather than inside the daemon that holds every
 * account's credentials. Until that is wired up, the honest description of
 * this class is: it runs model-authored code in the server process, guarded by
 * a wordlist, a timeout and an output cap.
 *
 * A deployment that would rather not can leave scripts as templates, which is
 * also what happens automatically when there is no compiler - see below.
 *
 * <h2>Native images have no compiler</h2>
 *
 * {@code javac} is a JDK service, and a GraalVM native image does not carry
 * one. So on the native build {@link #available()} is false, every compile
 * declines, and scripts fall back to plain template substitution. That is a
 * real difference between the two builds and not a bug: the fast path still
 * works, it just cannot branch. A deployment that wants scripted code must run
 * the daemon on a JVM.
 */
final class ScriptVm {

    /** How long a script gets before we assume it is not coming back. */
    private static final long TIMEOUT_MS = 2000;

    /** An answer larger than this is a runaway loop, not an answer. */
    private static final int MAX_OUTPUT = 64 * 1024;

    /**
     * Ways out of a method body that a script has no business taking. Not a
     * sandbox - see the class comment - but a model that reaches for any of
     * these has misunderstood the job badly enough to be worth stopping.
     */
    private static final String[] FORBIDDEN = {
        "import", "Runtime", "ProcessBuilder", "System.exit", "Class.forName",
        "getClass", "java.io", "java.nio", "java.net", "java.lang.reflect",
        "reflect", "Unsafe", "loadLibrary", "System.getenv", "System.getProperty",
        "Thread", "ClassLoader", "MethodHandle", "javax.", "sun.", "jdk.",
        "Files.", "Socket", "URL", "URI", "exec(", "native", "synchronized",
        "ScriptVm", "Scripts", "Accounts", "Aicoin", "Aws", "Otp",
    };

    /**
     * A script that times out this many times is dropped rather than kept.
     *
     * Two is enough to tell a runaway from a slow machine, and dropping is the
     * only real answer: a body already compiled can spin, and no wordlist can
     * tell in advance which one will. {@code Future.cancel} interrupts a sleep
     * but not a loop, so a script that spins keeps a thread until the process
     * ends. Bounding the pool means that costs a slot; not bounding it would
     * mean it costs the machine.
     */
    private static final int STRIKES = 2;

    private final ExecutorService pool = new java.util.concurrent.ThreadPoolExecutor(
            0, Math.max(2, Runtime.getRuntime().availableProcessors()),
            30, TimeUnit.SECONDS, new java.util.concurrent.SynchronousQueue<>(),
            r -> {
                var t = new Thread(r, "script");
                t.setDaemon(true);  // a wedged script must not hold up shutdown
                return t;
            },
            // Every slot busy means scripts are wedged. Decline rather than
            // queue: the model is a slower answer, not a worse one.
            new java.util.concurrent.ThreadPoolExecutor.AbortPolicy());

    /** How many times each compiled body has failed to come back. */
    private final Map<ScriptBody, AtomicLong> strikes = new java.util.concurrent.ConcurrentHashMap<>();

    private final AtomicLong compiled = new AtomicLong();
    private final AtomicLong rejected = new AtomicLong();
    private final AtomicLong ran = new AtomicLong();
    private final AtomicLong declined = new AtomicLong();
    private final AtomicLong failed = new AtomicLong();

    /** Is there a compiler in this JVM?  A native image says no. */
    static boolean available() {
        return ToolProvider.getSystemJavaCompiler() != null;
    }

    /** Why a source was refused, for the log and the record. */
    record Refusal(String reason) {}

    /**
     * Compile one model-written body into something runnable.
     *
     * @param name      what the script called itself
     * @param variables the pattern's variable names, which become locals so
     *                  the body can say {@code lang} rather than reach into a map
     * @param body      the method body, which must return a String or null
     * @return the compiled script, or null if it could not or should not be
     */
    ScriptBody compile(String name, List<String> variables, String body, StringBuilder why) {
        if (body == null || body.isBlank()) { why.append("empty"); return null; }

        JavaCompiler javac = ToolProvider.getSystemJavaCompiler();
        if (javac == null) {
            why.append("no compiler in this JVM (native image): script stays a template");
            return null;
        }
        for (var bad : FORBIDDEN) {
            if (body.contains(bad)) {
                rejected.incrementAndGet();
                why.append("mentions ").append(bad);
                return null;
            }
        }

        String cls = "Script_" + name.replaceAll("[^A-Za-z0-9_]", "_") + "_" + compiled.incrementAndGet();
        var src = new StringBuilder();
        src.append("public final class ").append(cls).append(" implements ScriptBody {\n")
           .append("  @Override public String run(java.util.Map<String,String> v) throws Exception {\n");
        // Every variable the pattern binds, plus the two the screen supplies,
        // arrive as plain locals so the body reads like ordinary code.
        var seen = new java.util.LinkedHashSet<String>(variables);
        seen.add("subject");
        seen.add("selection");
        for (var vname : seen) {
            if (!vname.matches("[a-zA-Z_][a-zA-Z0-9_]*")) continue;
            src.append("    final String ").append(vname)
               .append(" = v.getOrDefault(\"").append(vname).append("\", \"\");\n");
        }
        src.append("    ").append(body).append("\n")
           .append("  }\n}\n");

        var errors = new ByteArrayOutputStream();
        try {
            var manager = new Bytes(javac.getStandardFileManager(null, null, null));
            var unit = new Source(cls, src.toString());
            var options = List.of("-classpath", System.getProperty("java.class.path"));
            boolean ok = javac.getTask(new java.io.PrintWriter(errors), manager,
                    null, options, null, List.of(unit)).call();
            if (!ok) {
                rejected.incrementAndGet();
                why.append("did not compile: ").append(errors.toString().strip());
                return null;
            }
            var loader = new Loader(manager.classes, ScriptVm.class.getClassLoader());
            Object made = loader.loadClass(cls).getDeclaredConstructor().newInstance();
            return (ScriptBody) made;
        } catch (Throwable t) {
            rejected.incrementAndGet();
            why.append("could not be built: ").append(t);
            return null;
        }
    }

    /**
     * Run one, with a clock on it.
     *
     * Every failure - thrown, timed out, oversized - is treated the same way a
     * decline is: return null, and the caller asks the model. A script that
     * misbehaves should cost latency, never an answer.
     */
    String run(ScriptBody script, Map<String, String> vars) {
        if (script == null) return null;
        ran.incrementAndGet();
        Future<String> f;
        try {
            f = pool.submit((Callable<String>) () -> script.run(new HashMap<>(vars)));
        } catch (java.util.concurrent.RejectedExecutionException busy) {
            failed.incrementAndGet();   // every slot wedged: fall back to a model
            return null;
        }
        try {
            String out = f.get(TIMEOUT_MS, TimeUnit.MILLISECONDS);
            if (out == null) { declined.incrementAndGet(); return null; }
            if (out.length() > MAX_OUTPUT) {
                failed.incrementAndGet();
                return null;
            }
            return out;
        } catch (java.util.concurrent.TimeoutException late) {
            f.cancel(true);         // interrupts a sleep or a wait, not a spin
            failed.incrementAndGet();
            strikes.computeIfAbsent(script, k -> new AtomicLong()).incrementAndGet();
            return null;
        } catch (Exception x) {
            f.cancel(true);
            failed.incrementAndGet();
            return null;            // a throw is the script's business, not a strike
        }
    }

    /**
     * Has this one run out of chances?  Asked after every failed run, so a
     * script that hangs is taken out of service rather than tried forever.
     */
    boolean spent(ScriptBody script) {
        var s = strikes.get(script);
        return s != null && s.get() >= STRIKES;
    }

    String asJson() {
        return Json.obj("compiler", available(), "compiled", compiled.get(),
                "rejected", rejected.get(), "ran", ran.get(),
                "declined", declined.get(), "failed", failed.get());
    }

    // ------------------------------------------------------ in-memory javac

    /** The source we just built, handed to the compiler without a file. */
    private static final class Source extends SimpleJavaFileObject {
        private final String code;
        Source(String name, String code) {
            super(URI.create("string:///" + name + Kind.SOURCE.extension), Kind.SOURCE);
            this.code = code;
        }
        @Override public CharSequence getCharContent(boolean ignoreEncodingErrors) { return code; }
    }

    /** The class file it produces, kept in memory rather than written out. */
    private static final class Compiled extends SimpleJavaFileObject {
        private final ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        Compiled(String name) {
            super(URI.create("bytes:///" + name + Kind.CLASS.extension), Kind.CLASS);
        }
        @Override public java.io.OutputStream openOutputStream() { return bytes; }
        byte[] toByteArray() { return bytes.toByteArray(); }
    }

    private static final class Bytes extends ForwardingJavaFileManager<StandardJavaFileManager> {
        final Map<String, Compiled> classes = new HashMap<>();
        Bytes(StandardJavaFileManager delegate) { super(delegate); }
        @Override public JavaFileObject getJavaFileForOutput(Location location, String className,
                                                            JavaFileObject.Kind kind, FileObject sibling) {
            var out = new Compiled(className);
            classes.put(className, out);
            return out;
        }
    }

    /**
     * One loader per script, so a script cannot see or replace another's
     * classes, and so both go away together when nothing refers to them.
     */
    private static final class Loader extends ClassLoader {
        private final Map<String, Compiled> classes;
        Loader(Map<String, Compiled> classes, ClassLoader parent) {
            super(parent);
            this.classes = classes;
        }
        @Override protected Class<?> findClass(String name) throws ClassNotFoundException {
            var made = classes.get(name);
            if (made == null) throw new ClassNotFoundException(name);
            byte[] b = made.toByteArray();
            return defineClass(name, b, 0, b.length);
        }
    }
}
