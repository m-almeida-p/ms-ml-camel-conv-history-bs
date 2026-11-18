import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.sql.SQLException;
import java.sql.SQLTransientConnectionException;
import java.util.List;
import org.apache.camel.Exchange;
import org.apache.camel.impl.DefaultCamelContext;
import org.apache.camel.support.DefaultExchange;
import org.junit.jupiter.api.Test;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.jdbc.CannotGetJdbcConnectionException;

/** Which failure becomes which status, what the body says, and what it must never say. */
class ProblemResponderTest {

    private static final ObjectMapper JSON = new ObjectMapper();
    private final ProblemResponder responder = new ProblemResponder();

    private Exchange failed(Exception cause) {
        Exchange exchange = new DefaultExchange(new DefaultCamelContext());
        exchange.setProperty(Exchange.EXCEPTION_CAUGHT, cause);
        exchange.getMessage().setHeader("page[before]", "x");
        exchange.getMessage().setHeader("pageSize", "x");
        exchange.getMessage().setHeader("Link", "<https://x>; rel=\"next\"");
        return exchange;
    }

    private JsonNode answer(Exchange exchange) throws Exception {
        responder.respond(exchange);
        return JSON.readTree(exchange.getMessage().getBody(String.class));
    }

    @Test
    void anApiProblemKeepsItsOwnStatusTypeTitleAndDetail() throws Exception {
        Exchange exchange = failed(ApiProblemException.invalidCursor(new DefaultExchange(new DefaultCamelContext()), "page[before] is not a cursor"));

        JsonNode body = answer(exchange);

        assertEquals(400, exchange.getMessage().getHeader(Exchange.HTTP_RESPONSE_CODE));
        assertEquals("tag:yape.com.pe,2026:conversation-history:invalid-cursor", body.get("type").asText());
        assertEquals("Invalid cursor", body.get("title").asText());
        assertEquals(400, body.get("status").asInt());
        assertEquals("page[before] is not a cursor", body.get("detail").asText());
    }

    @Test
    void theNotFoundProblemIs404() throws Exception {
        Exchange exchange = failed(ApiProblemException.conversationNotFound(new DefaultExchange(new DefaultCamelContext())));

        JsonNode body = answer(exchange);

        assertEquals(404, exchange.getMessage().getHeader(Exchange.HTTP_RESPONSE_CODE));
        assertEquals("Conversation not found", body.get("title").asText());
    }

    @Test
    void theBodyHasExactlyFourFieldsInTheOrderOfRfc9457() throws Exception {
        JsonNode body = answer(failed(new IllegalStateException("boom")));

        List<String> names = new java.util.ArrayList<>();
        body.fieldNames().forEachRemaining(names::add);
        assertEquals(List.of("type", "title", "status", "detail"), names);
    }

    @Test
    void theContentTypeIsProblemJsonAndTheHttpLayerCannotChoke() throws Exception {
        Exchange exchange = failed(new IllegalStateException("boom"));

        answer(exchange);

        assertEquals("application/problem+json", exchange.getMessage().getHeader(Exchange.CONTENT_TYPE));
        assertNull(exchange.getMessage().getHeader("page[before]"), "a header name with brackets fails the Vert.x response");
        assertNull(exchange.getMessage().getHeader("pageSize"));
        assertNull(exchange.getMessage().getHeader("Link"), "an error answer carries no paging link");
    }

    @Test
    void aFailureOfOurOwnIs500WithoutSayingWhatFailed() throws Exception {
        Exchange exchange = failed(new IllegalStateException("the secret detail: item msg_123 is not in the map"));

        JsonNode body = answer(exchange);

        assertEquals(500, exchange.getMessage().getHeader(Exchange.HTTP_RESPONSE_CODE));
        assertEquals("about:blank", body.get("type").asText());
        assertEquals("Internal Server Error", body.get("title").asText());
        assertFalse(body.get("detail").asText().contains("msg_123"), "the detail of a 5xx never says what failed; the log does");
    }

    @Test
    void aNullPointerIs500NotACrash() throws Exception {
        assertEquals(500, answer(failed(new NullPointerException())).get("status").asInt());
    }

    @Test
    void aNonConnectionSqlErrorIs500BecauseTheQueryIsOurBugNotTheirOutage() throws Exception {
        assertEquals(500, answer(failed(new SQLException("syntax error at or near SELECT", "42601"))).get("status").asInt());
    }

    @Test
    void anIoFailureIs503() throws Exception {
        Exchange exchange = failed(new FoundryUnavailableException("Foundry answered 429"));

        JsonNode body = answer(exchange);

        assertEquals(503, exchange.getMessage().getHeader(Exchange.HTTP_RESPONSE_CODE));
        assertEquals("Service Unavailable", body.get("title").asText());
        assertFalse(body.get("detail").asText().contains("429"));
    }

    @Test
    void aPlainIoExceptionAndAnUncheckedWrapperAreBoth503() throws Exception {
        assertEquals(503, answer(failed(new IOException("connection reset"))).get("status").asInt());
        assertEquals(503, answer(failed(new UncheckedIOException(new IOException("db")))).get("status").asInt());
    }

    @Test
    void aConnectionFailureHiddenInsideOtherExceptionsIsStillFound() throws Exception {
        Exception deep = new RuntimeException("wrapper", new IllegalArgumentException("another", new IOException("down")));

        assertEquals(503, answer(failed(deep)).get("status").asInt());
    }

    @Test
    void theDatabaseBeingDownIs503InAllTheFormsSpringAndTheDriverUse() throws Exception {
        List<Exception> down = List.of(
                new CannotGetJdbcConnectionException("could not get a connection", new SQLException("refused")),
                new DataAccessResourceFailureException("the database cannot be reached"),
                new SQLTransientConnectionException("timeout"),
                new RuntimeException("camel", new CannotGetJdbcConnectionException("x")));
        for (Exception e : down) {
            assertEquals(503, answer(failed(e)).get("status").asInt(), e.getClass().getSimpleName());
        }
    }

    @Test
    void theApiProblemWinsEvenWhenItWrapsAnIoFailure() throws Exception {
        Exchange inner = new DefaultExchange(new DefaultCamelContext());
        ApiProblemException problem = ApiProblemException.invalidRequest(inner, "idYapeAccount is missing or malformed");
        problem.initCause(new IOException("irrelevant"));

        assertEquals(400, answer(failed(problem)).get("status").asInt());
    }

    @Test
    void dependencyDownIsFalseForAnOrdinaryFailureAndTrueForNullSafeInput() {
        assertFalse(ProblemResponder.dependencyDown(new IllegalStateException("x")));
        assertFalse(ProblemResponder.dependencyDown(null));
        assertTrue(ProblemResponder.dependencyDown(new IOException()));
    }
}
