import java.io.IOException;

/**
 * Foundry or the token broker cannot answer right now, or answered with a status that a later try can fix: the network
 * failed, a timeout, 401, 403, 408, 429 or 5xx. The route answers 503: nothing is retried here, the caller tries again.
 *
 * It extends IOException on purpose: the route's onException matches that built-in class by name, because a class
 * compiled from this project's Java files cannot be resolved by name there.
 */
public class FoundryUnavailableException extends IOException {

    public FoundryUnavailableException(String message) {
        super(message);
    }

    public FoundryUnavailableException(String message, Throwable cause) {
        super(message, cause);
    }
}
