import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;
import org.apache.camel.BindToRegistry;
import org.apache.camel.Exchange;
import org.apache.camel.Message;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Builds the response of a failed request as application/problem+json, like the reference service:
 *   ApiProblemException        the status, type, title and detail it carries
 *   a dependency that cannot answer (Foundry, the token broker, the database)   503, about:blank
 *   anything else              500, about:blank
 * The detail of a 5xx never says what failed; the log does. No detail repeats a value the client sent.
 */
@BindToRegistry("problem")
public class ProblemResponder {

    private static final Logger LOG = LoggerFactory.getLogger("problem");
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final String SERVER_DETAIL = "Something went wrong. Try again.";

    /** Names of the exceptions that mean "the database cannot be reached", from Spring and the JDBC driver. */
    private static final String[] DATABASE_DOWN = {
        "org.springframework.jdbc.CannotGetJdbcConnectionException",
        "org.springframework.dao.DataAccessResourceFailureException",
        "org.springframework.dao.TransientDataAccessException",
        "java.sql.SQLTransientConnectionException",
        "java.sql.SQLNonTransientConnectionException"
    };

    /**
     * True when the failure, or anything it was caused by, is a dependency that cannot answer: an IOException (Foundry and
     * the token broker raise one) or a database connection failure. The route's onException rule lists the same families.
     */
    static boolean dependencyDown(Throwable failure) {
        for (Throwable t = failure; t != null; t = t.getCause()) {
            if (t instanceof IOException || t instanceof UncheckedIOException || isDatabaseDown(t)) {
                return true;
            }
        }
        return false;
    }

    /** True when the exception is one of the DATABASE_DOWN classes or a subclass of one (matched by name: Spring may not be on the classpath). */
    private static boolean isDatabaseDown(Throwable t) {
        for (Class<?> c = t.getClass(); c != null; c = c.getSuperclass()) {
            if (Arrays.asList(DATABASE_DOWN).contains(c.getName())) {
                return true;
            }
        }
        return false;
    }

    public void respond(Exchange exchange) throws Exception {
        Exception cause = exchange.getProperty(Exchange.EXCEPTION_CAUGHT, Exception.class);
        int status;
        String type;
        String title;
        String detail;
        if (cause instanceof ApiProblemException problem) {
            status = problem.getStatus();
            type = problem.getType();
            title = problem.getTitle();
            detail = problem.getDetail();
        } else if (dependencyDown(cause)) {
            status = 503;
            type = "about:blank";
            title = "Service Unavailable";
            detail = SERVER_DETAIL;
            LOG.warn("answering 503: {}: {}", cause.getClass().getSimpleName(), cause.getMessage());
        } else {
            status = 500;
            type = "about:blank";
            title = "Internal Server Error";
            detail = SERVER_DETAIL;
            LOG.error("answering 500", cause);
        }
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("type", type);
        body.put("title", title);
        body.put("status", status);
        body.put("detail", detail);

        Message message = exchange.getMessage();
        message.removeHeaders("*", "Camel*");   // the request's headers would go back on the response, and a bad one fails it
        message.setHeader(Exchange.HTTP_RESPONSE_CODE, status);
        message.setHeader(Exchange.CONTENT_TYPE, "application/problem+json");
        message.setBody(JSON.writeValueAsString(body));
    }
}
