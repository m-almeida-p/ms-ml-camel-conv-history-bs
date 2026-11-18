import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.io.UncheckedIOException;
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
 *   IOException (Foundry or the token broker cannot answer)   503, about:blank
 *   anything else              500, about:blank
 * The detail of a 5xx never says what failed; the log does. No detail repeats a value the client sent.
 */
@BindToRegistry("problem")
public class ProblemResponder {

    private static final Logger LOG = LoggerFactory.getLogger("problem");
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final String SERVER_DETAIL = "Something went wrong. Try again.";

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
        } else if (cause instanceof IOException || cause instanceof UncheckedIOException) {
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
        message.removeHeaders("page*");   // a header name with [ ] makes the HTTP layer fail the response
        message.removeHeader("Link");
        message.setHeader(Exchange.HTTP_RESPONSE_CODE, status);
        message.setHeader(Exchange.CONTENT_TYPE, "application/problem+json");
        message.setBody(JSON.writeValueAsString(body));
    }
}
