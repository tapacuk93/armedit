import java.util.Map;

/**
 * A script the model wrote, compiled and running as code.
 *
 * The contract is deliberately tiny. Bindings in, one string out, and the
 * right to decline:
 *
 * Returning {@code null} means "not me" - the script looked at what it was
 * given and decided it could not answer well. The server then asks the model
 * as if the script had never matched. That valve matters more than it looks:
 * without it, a script that is right about nine cases and wrong about the
 * tenth has to be either kept (and wrong sometimes) or thrown away (and slow
 * always). With it, the script can cover what it knows and hand back the rest.
 */
public interface ScriptBody {

    /**
     * @param v the pattern's variables, plus {@code subject} and
     *          {@code selection} from the screen it fired on
     * @return the answer, or null to decline and let the model handle it
     */
    String run(Map<String, String> v) throws Exception;
}
