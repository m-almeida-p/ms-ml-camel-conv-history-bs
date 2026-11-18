import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.apache.camel.Exchange;
import org.apache.camel.impl.DefaultCamelContext;
import org.apache.camel.support.DefaultExchange;
import org.junit.jupiter.api.Test;

/** The shape of the list answer: order, paging links, cursors, and how a time is written. */
class ConversationListTest {

    private static final ObjectMapper JSON = new ObjectMapper();
    private final ConversationList list = new ConversationList();

    private static Map<String, Object> row(String id, long seconds, int micros, int messages) {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("conversation_id", id);
        row.put("message_count", (long) messages);
        row.put("first_occurred_at", Timestamp.from(Instant.ofEpochSecond(seconds - 60)));
        row.put("last_occurred_at", Timestamp.from(Instant.ofEpochSecond(seconds, micros * 1000L)));
        return row;
    }

    private Exchange exchange(List<Map<String, Object>> rows, String direction, int size) {
        Exchange exchange = new DefaultExchange(new DefaultCamelContext());
        exchange.getMessage().setBody(rows);
        exchange.setProperty("account", "acct");
        exchange.setProperty("direction", direction);
        exchange.setProperty("size", size);
        return exchange;
    }

    private JsonNode build(Exchange exchange) throws Exception {
        list.build(exchange);
        return JSON.readTree(exchange.getMessage().getBody(String.class));
    }

    private static List<String> ids(JsonNode body) {
        List<String> ids = new ArrayList<>();
        body.get("conversations").forEach(c -> ids.add(c.get("_id").asText()));
        return ids;
    }

    @Test
    void noRowsIsAnEmptyListWithoutALink() throws Exception {
        Exchange exchange = exchange(List.of(), "newest", 100);

        JsonNode body = build(exchange);

        assertEquals(0, body.get("conversations").size());
        assertNull(exchange.getMessage().getHeader("Link"));
        assertEquals("application/json", exchange.getMessage().getHeader(Exchange.CONTENT_TYPE));
    }

    @Test
    void aPageExactlyFullKnowsNothingMoreExists() throws Exception {
        Exchange exchange = exchange(List.of(row("a", 1795028270, 0, 1), row("b", 1795028260, 0, 1)), "newest", 2);

        build(exchange);

        assertNull(exchange.getMessage().getHeader("Link"));
    }

    @Test
    void oneRowBeyondThePageGivesAPrevLinkOnTheOldestOfThePage() throws Exception {
        Exchange exchange = exchange(List.of(row("a", 1795028270, 0, 1), row("b", 1795028260, 5, 1), row("c", 1795028250, 0, 1)), "newest", 2);

        JsonNode body = build(exchange);

        assertEquals(List.of("a", "b"), ids(body), "the extra row is dropped");
        assertEquals("</v1/conversations?idYapeAccount=acct&page[before]=1795028260000005~b&page[size]=2>; rel=\"prev\"",
                exchange.getMessage().getHeader("Link"));
    }

    @Test
    void theLinkLeavesTheSizeOutWhenItIsTheDefault() throws Exception {
        List<Map<String, Object>> rows = new ArrayList<>();
        for (int i = 0; i < 101; i++) {
            rows.add(row("c" + i, 1795028270 - i, 0, 1));
        }
        Exchange exchange = exchange(rows, "before", 100);

        JsonNode body = build(exchange);

        assertEquals(100, body.get("conversations").size());
        assertEquals("</v1/conversations?idYapeAccount=acct&page[before]=1795028171000000~c99>; rel=\"prev\"",
                exchange.getMessage().getHeader("Link"));
    }

    @Test
    void aPageReadTowardsThePresentIsTurnedRoundAndLinksNextOnItsMostRecent() throws Exception {
        // 'after' comes oldest first from the query: b (older), c, then d (the extra)
        Exchange exchange = exchange(List.of(row("b", 1795028250, 0, 1), row("c", 1795028260, 0, 1), row("d", 1795028270, 0, 1)), "after", 2);

        JsonNode body = build(exchange);

        assertEquals(List.of("c", "b"), ids(body), "every page is most recent first");
        assertEquals("</v1/conversations?idYapeAccount=acct&page[after]=1795028260000000~c&page[size]=2>; rel=\"next\"",
                exchange.getMessage().getHeader("Link"));
    }

    @Test
    void theCursorIsTheMicrosecondOfTheLastMessageNotItsRoundedMillisecond() throws Exception {
        JsonNode body = build(exchange(List.of(row("a", 1795028262, 350036, 3)), "newest", 100));

        assertEquals("1795028262350036~a", body.get("conversations").get(0).get("cursor").asText());
    }

    @Test
    void theTimesAreSecondsWithMillisecondsTruncatedNotRounded() throws Exception {
        Exchange exchange = exchange(List.of(row("a", 1795028262, 999999, 1)), "newest", 100);
        build(exchange);
        String raw = exchange.getMessage().getBody(String.class);

        assertTrue(raw.contains("\"lastReceived\":1795028262.999"), "999.999 ms is 999, never 1000: " + raw);
        assertTrue(raw.contains("\"firstReceived\":1795028202"), raw);
    }

    @Test
    void aTimeOnAWholeTenSecondsIsAPlainNumberNotScientific() throws Exception {
        Exchange exchange = exchange(List.of(row("a", 1795028270, 0, 1), row("b", 1000000000, 500000, 1)), "newest", 100);
        build(exchange);
        String raw = exchange.getMessage().getBody(String.class);

        assertTrue(raw.contains("\"lastReceived\":1795028270,") || raw.contains("\"lastReceived\":1795028270}"), raw);
        assertTrue(raw.contains("\"lastReceived\":1000000000.5"), raw);
        assertFalse(raw.contains("E+") || raw.contains("E9"), "no scientific notation: " + raw);
    }

    @Test
    void theMessageCountIsAnIntegerWhateverTheDriverReturned() throws Exception {
        Map<String, Object> r = row("a", 1795028270, 0, 0);
        r.put("message_count", 7L);

        assertEquals(7, build(exchange(List.of(r), "newest", 100)).get("conversations").get(0).get("messageCount").asInt());
    }

    @Test
    void aTimeBeforeTheEpochStillFormats() {
        assertEquals("-1.5", ConversationList.unixSeconds(new Timestamp(-1500)).toPlainString());
    }

    @Test
    void theCursorOfAnInstantWithNoFractionEndsInSixZeros() {
        assertEquals("1795028262000000~x", ConversationList.cursor(Timestamp.from(Instant.ofEpochSecond(1795028262)), "x"));
    }
}
