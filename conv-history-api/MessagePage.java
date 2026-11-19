import com.fasterxml.jackson.core.JsonGenerator;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import javax.sql.DataSource;
import org.apache.camel.BindToRegistry;
import org.apache.camel.Exchange;
import org.apache.camel.Message;

/**
 * Shapes the answer of GET /v1/conversations/{id}/messages.
 *
 * The text and the order come from Foundry. Foundry gives an item no time and no metadata, so everything else of a message
 * comes from conversation_messages, found through the item map: the sequence (the message _id), the role, the author, the
 * time, the event, the flow and whether the text was cut. An item the map does not know is an inconsistency, not a
 * message: it is a 500 with the log naming it.
 *
 * Reads the properties conversationId, direction, size, foundryItems and hasMore. Sets the body, Content-Type and, when
 * more exist in the direction read, the Link header.
 */
@BindToRegistry("messagePage")
public class MessagePage {

    private static final ObjectMapper JSON = new ObjectMapper().enable(JsonGenerator.Feature.WRITE_BIGDECIMAL_AS_PLAIN);
    private static final int DEFAULT_SIZE = 100;

    private record Stored(int sequence, String role, String authorId, String type, boolean truncated, String eventName, String flow, Timestamp occurredAt) {
    }

    @SuppressWarnings("unchecked")
    public void build(Exchange exchange) throws Exception {
        String conversationId = exchange.getProperty("conversationId", String.class);
        String direction = exchange.getProperty("direction", String.class);
        int size = exchange.getProperty("size", Integer.class);
        List<Map<String, String>> items = exchange.getProperty("foundryItems", List.class);
        boolean more = exchange.getProperty("hasMore", Boolean.class);

        Map<String, Stored> stored = load(exchange, conversationId, items);

        ObjectNode body = JSON.createObjectNode();
        body.putObject("conversation").put("_id", conversationId);
        ArrayNode messages = body.putArray("messages");
        Integer first = null;
        Integer last = null;
        for (Map<String, String> item : items) {
            Stored s = stored.get(item.get("id"));
            if (s == null) {
                throw new IllegalStateException("Foundry item " + item.get("id") + " of conversation " + conversationId
                        + " is not in the item map or has no stored message");
            }
            ObjectNode m = messages.addObject();
            m.put("_id", Integer.toString(s.sequence()));
            m.put("type", s.type());
            m.put("role", s.role());
            m.put("authorId", s.authorId());
            m.put("text", item.get("text"));
            m.put("received", BigDecimal.valueOf(s.occurredAt().getTime(), 3).stripTrailingZeros());
            m.putObject("source").put("type", "api");
            ObjectNode metadata = m.putObject("metadata");
            metadata.put("sequence", s.sequence());
            metadata.put("eventName", s.eventName());
            metadata.put("truncated", s.truncated());
            if (s.flow() != null) {
                metadata.put("flow", s.flow());
            }
            first = first == null ? s.sequence() : first;
            last = s.sequence();
        }

        Message message = exchange.getMessage();
        message.setHeader(Exchange.CONTENT_TYPE, "application/json");
        if (more && first != null) {
            boolean forward = "after".equals(direction);
            String target = "/v1/conversations/" + conversationId + "/messages?" + (forward ? "page[after]=" + last : "page[before]=" + first)
                    + (size != DEFAULT_SIZE ? "&page[size]=" + size : "");
            message.setHeader("Link", "<" + target + ">; rel=\"" + (forward ? "next" : "prev") + "\"");
        }
        message.setBody(JSON.writeValueAsString(body));
    }

    /** The stored message of each Foundry item of the page, by item id. */
    private static Map<String, Stored> load(Exchange exchange, String conversationId, List<Map<String, String>> items) throws SQLException {
        Map<String, Stored> found = new HashMap<>();
        if (items.isEmpty()) {
            return found;
        }
        DataSource dataSource = exchange.getContext().getRegistry().lookupByNameAndType("pgDataSource", DataSource.class);
        String[] ids = items.stream().map(i -> i.get("id")).toArray(String[]::new);
        try (Connection connection = dataSource.getConnection();
                PreparedStatement statement = connection.prepareStatement(
                        "SELECT i.foundry_item_id, m.sequence, m.role, m.author_id, m.type, m.truncated, m.event_name, m.flow, m.occurred_at "
                                + "FROM foundry_item_map i JOIN conversation_messages m ON m.conversation_id = i.conversation_id AND m.sequence = i.sequence "
                                + "WHERE i.conversation_id = ? AND i.foundry_item_id = ANY (?)")) {
            statement.setString(1, conversationId);
            statement.setArray(2, connection.createArrayOf("text", ids));
            try (ResultSet rows = statement.executeQuery()) {
                while (rows.next()) {
                    found.put(rows.getString("foundry_item_id"), new Stored(rows.getInt("sequence"), rows.getString("role"), rows.getString("author_id"),
                            rows.getString("type"), rows.getBoolean("truncated"), rows.getString("event_name"), rows.getString("flow"), rows.getTimestamp("occurred_at")));
                }
            }
        } catch (SQLException e) {
            if (connectionProblem(e)) {
                throw new java.io.UncheckedIOException(new java.io.IOException("database failure: " + e.getMessage(), e));   // 503: try again
            }
            throw e;   // a wrong statement or a missing column is a bug: 500
        }
        return found;
    }

    /** True when the database cannot be reached or has gone away (worth retrying), as opposed to a statement that is wrong. */
    static boolean connectionProblem(SQLException e) {
        if (e instanceof java.sql.SQLTransientException || e instanceof java.sql.SQLRecoverableException || e instanceof java.sql.SQLNonTransientConnectionException) {
            return true;
        }
        String state = e.getSQLState();   // 08 connection, 53 resources, 57 operator intervention (a restart)
        return state != null && (state.startsWith("08") || state.startsWith("53") || state.startsWith("57"));
    }
}
