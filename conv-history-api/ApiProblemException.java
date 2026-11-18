import org.apache.camel.Exchange;
import org.apache.camel.ValidationException;

/**
 * A request the API refuses, or a result it cannot give, as an RFC 9457 problem: the status, the type, the title and
 * a detail that says what is wrong without repeating what the client sent. ProblemResponder turns it into the response.
 *
 * It extends Camel's ValidationException on purpose: the route's onException matches that built-in class by name,
 * because a class compiled from this project's Java files cannot be resolved by name there.
 */
public class ApiProblemException extends ValidationException {

    public static final String TYPE_BASE = "tag:yape.com.pe,2026:conversation-history:";

    private final int status;
    private final String type;
    private final String title;
    private final String detail;

    public ApiProblemException(Exchange exchange, int status, String type, String title, String detail) {
        super(exchange, status + " " + title + ": " + detail);
        this.status = status;
        this.type = type;
        this.title = title;
        this.detail = detail;
    }

    /** 400: a parameter that is missing, malformed, repeated or out of range. */
    public static ApiProblemException invalidRequest(Exchange exchange, String detail) {
        return new ApiProblemException(exchange, 400, TYPE_BASE + "invalid-request", "Invalid request", detail);
    }

    /** 400: a page[before] or page[after] that is not a cursor this API issues. */
    public static ApiProblemException invalidCursor(Exchange exchange, String detail) {
        return new ApiProblemException(exchange, 400, TYPE_BASE + "invalid-cursor", "Invalid cursor", detail);
    }

    /** 404: the conversation has no chat messages (here: none that are in Foundry). */
    public static ApiProblemException conversationNotFound(Exchange exchange) {
        return new ApiProblemException(exchange, 404, TYPE_BASE + "conversation-not-found", "Conversation not found",
                "No chat messages were found for this conversation.");
    }

    public int getStatus() {
        return status;
    }

    public String getType() {
        return type;
    }

    public String getTitle() {
        return title;
    }

    public String getDetail() {
        return detail;
    }
}
