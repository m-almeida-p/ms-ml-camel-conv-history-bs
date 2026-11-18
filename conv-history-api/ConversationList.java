import com.fasterxml.jackson.core.JsonGenerator;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import org.apache.camel.BindToRegistry;
import org.apache.camel.Exchange;
import org.apache.camel.Message;

/**
 * Shapes the answer of GET /v1/conversations from the rows the query found.
 *
 * The query reads size + 1 rows, so a page that has one more than size knows more exist. A page read towards the past
 * ("newest" and "before") comes most recent first; one read towards the present ("after") comes oldest first and is
 * turned round, so every page is most recent first. The cursor of a conversation is where it stood when it was read:
 * the instant of its last message in Unix microseconds, a "~", and its id, so it stays right when the conversation
 * later receives a message and moves to the top.
 *
 * Reads the body (the rows) and the properties account, direction and size.
 * Sets the body, Content-Type and, when more exist in the direction read, the Link header.
 */
@BindToRegistry("conversationList")
public class ConversationList {

    private static final ObjectMapper JSON = new ObjectMapper().enable(JsonGenerator.Feature.WRITE_BIGDECIMAL_AS_PLAIN);
    private static final int DEFAULT_SIZE = 100;

    @SuppressWarnings("unchecked")
    public void build(Exchange exchange) throws Exception {
        List<Map<String, Object>> rows = exchange.getMessage().getBody(List.class);
        String account = exchange.getProperty("account", String.class);
        String direction = exchange.getProperty("direction", String.class);
        int size = exchange.getProperty("size", Integer.class);

        boolean more = rows.size() > size;
        List<Map<String, Object>> page = new ArrayList<>(more ? rows.subList(0, size) : rows);
        if ("after".equals(direction)) {
            Collections.reverse(page);
        }

        ObjectNode body = JSON.createObjectNode();
        ArrayNode list = body.putArray("conversations");
        for (Map<String, Object> row : page) {
            Timestamp last = (Timestamp) row.get("last_occurred_at");
            ObjectNode item = list.addObject();
            item.put("_id", (String) row.get("conversation_id"));
            item.put("cursor", cursor(last, (String) row.get("conversation_id")));
            item.put("messageCount", ((Number) row.get("message_count")).intValue());
            item.put("firstReceived", unixSeconds((Timestamp) row.get("first_occurred_at")));
            item.put("lastReceived", unixSeconds(last));
        }

        Message message = exchange.getMessage();
        message.setHeader(Exchange.CONTENT_TYPE, "application/json");
        if (more && !page.isEmpty()) {
            boolean forward = "after".equals(direction);
            Map<String, Object> edge = forward ? page.get(0) : page.get(page.size() - 1);   // the most recent, or the oldest
            String param = forward ? "page[after]" : "page[before]";
            String target = "/v1/conversations?idYapeAccount=" + account + "&" + param + "="
                    + cursor((Timestamp) edge.get("last_occurred_at"), (String) edge.get("conversation_id"))
                    + (size != DEFAULT_SIZE ? "&page[size]=" + size : "");
            message.setHeader("Link", "<" + target + ">; rel=\"" + (forward ? "next" : "prev") + "\"");
        }
        message.setBody(JSON.writeValueAsString(body));
    }

    /** The cursor: the instant in Unix microseconds, a "~", the conversation id. */
    static String cursor(Timestamp last, String conversationId) {
        Instant instant = last.toInstant();
        return (instant.getEpochSecond() * 1_000_000L + instant.getNano() / 1000) + "~" + conversationId;
    }

    /** Unix seconds with milliseconds as decimals, written as a plain number: 1792505543.5, not 1.7925055435E9. */
    static BigDecimal unixSeconds(Timestamp t) {
        return BigDecimal.valueOf(t.getTime(), 3).stripTrailingZeros();
    }
}
