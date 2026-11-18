import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.apache.camel.BindToRegistry;
import org.apache.camel.CamelContext;
import org.apache.camel.Exchange;

/**
 * The calls this project makes to the Microsoft Foundry Conversations API.
 *
 * It is a bean, not http steps, so the token comes from the broker and not from the message, no header of the message
 * is sent to Foundry, and every outcome becomes one of the route's three families (see route-error-handling):
 *   2xx                                  the call worked
 *   404                                  the answer, for the caller to read (the conversation is gone)
 *   401, 403, 408, 429, 5xx, no answer   FoundryUnavailableException: retried in place, forever
 *   any other 4xx                        FoundryRejectedException: the dead-letter log
 *
 * Settings: app.foundry.tokenUrl (the broker), app.foundry.endpoint (empty: the broker's endpoint) and
 * app.foundry.timeoutMs. The conversation id travels in the metadata of the Foundry conversation, with the source.
 */
@BindToRegistry("foundry")
public class FoundryClient {

    private static final ObjectMapper JSON = new ObjectMapper();
    private static final String SOURCE = "ms-ml-camel-conv-history-bs";
    private static final int MAX_DETAIL = 200;

    private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();

    private volatile boolean configured;
    private String tokenUrl;
    private String endpointOverride;
    private Duration timeout;

    private String token;
    private String brokerEndpoint;
    private Instant tokenExpires = Instant.EPOCH;

    /** A Foundry answer: the status and the body. Only 2xx and 404 are ever returned. */
    public record Answer(int status, String body) {
    }

    // ---- what the routes call -------------------------------------------------------------------------------------

    /**
     * Creates the Foundry conversation of a conversation of ours, with its first message, and reads back the id of that
     * message (the create call does not return it). Sets the headers "foundryConversationId" and "foundryItemId".
     */
    public void createConversation(Exchange exchange) throws Exception {
        configure(exchange.getContext());
        String conversationId = exchange.getMessage().getHeader("conversationId", String.class);
        ObjectNode body = JSON.createObjectNode();
        body.putObject("metadata").put("conversation_id", conversationId).put("source", SOURCE);
        body.putArray("items").add(item(exchange.getMessage().getHeader("storedRole", String.class), exchange.getMessage().getHeader("storedText", String.class)));
        String foundryConversationId = JSON.readTree(call(exchange, "POST", "/openai/v1/conversations", body.toString()).body()).path("id").asText();
        if (foundryConversationId.isEmpty()) {
            throw new FoundryUnavailableException("Foundry created a conversation but returned no id");
        }
        Answer items = call(exchange, "GET", "/openai/v1/conversations/" + foundryConversationId + "/items?order=asc&limit=1", null);
        exchange.getMessage().setHeader("foundryConversationId", foundryConversationId);
        exchange.getMessage().setHeader("foundryItemId", firstItemId(items.body()));
    }

    /**
     * Adds the message to a conversation Foundry already has, unless Foundry already holds it.
     *
     * This is ONE step on purpose. Foundry has no idempotency key, so a call whose answer is lost (a crash, a timeout)
     * may still have kept the item, and sending again would duplicate it. Camel retries only the step that failed, so
     * the check for such an item and the send have to be the same step: every retry looks first.
     *
     * The items after the last mapped one are compared, in order, with the stored messages that come next ("candidates").
     * Those that match are adopted. If the message being handled is not among them, it is sent.
     *
     * Reads the headers convMapRow, lastItemRow (the id of the last mapped item, or none) and candidates (the next
     * stored messages: sequence, role, text), plus storedRole and storedText. Sets:
     *   adoptJson, adoptCount   every item to record, adopted or new, as [{"sequence":n,"itemId":"msg_..."}]
     *   adoptedCurrent          true when Foundry already held the message being handled
     *   reconcileMismatch       true when Foundry holds something we cannot account for: the conversation must be rebuilt
     *   foundryGone             true when Foundry no longer has the conversation
     */
    @SuppressWarnings("unchecked")
    public void addItem(Exchange exchange) throws Exception {
        configure(exchange.getContext());
        Map<?, ?> mapRow = exchange.getMessage().getHeader("convMapRow", Map.class);
        String lastItemId = exchange.getMessage().getHeader("lastItemRow", String.class); // one column: the value itself
        List<Map<String, Object>> candidates = exchange.getMessage().getHeader("candidates", List.class);
        int current = exchange.getMessage().getHeader("sequence", Integer.class);
        String base = "/openai/v1/conversations/" + mapRow.get("foundry_conversation_id");

        exchange.getMessage().setHeader("foundryGone", false);
        exchange.getMessage().setHeader("reconcileMismatch", false);
        exchange.getMessage().setHeader("rebuildReason", "");
        exchange.getMessage().setHeader("adoptedCurrent", false);
        exchange.getMessage().setHeader("adoptCount", 0);
        exchange.getMessage().setHeader("adoptJson", "[]");

        // Foundry only appends. A message below the last synced sequence cannot be put in its place: rebuild.
        if (current < ((Number) mapRow.get("last_synced_sequence")).intValue()) {
            exchange.getMessage().setHeader("reconcileMismatch", true);
            exchange.getMessage().setHeader("rebuildReason", "late-event");
            return;
        }

        Answer trailing = call(exchange, "GET", base + "/items?order=asc&limit=100" + (lastItemId == null ? "" : "&after=" + lastItemId), null);
        if (trailing.status() == 404) {
            exchange.getMessage().setHeader("foundryGone", true);
            exchange.getMessage().setHeader("rebuildReason", "gone");
            return;
        }
        JsonNode list = JSON.readTree(trailing.body());
        JsonNode items = list.path("data");
        ArrayNode record = JSON.createArrayNode();
        boolean adoptedCurrent = false;
        int next = 0;
        boolean mismatch = list.path("has_more").asBoolean(false);
        for (int i = 0; !mismatch && i < items.size(); i++) {
            int found = -1;
            for (int k = next; candidates != null && k < candidates.size(); k++) {
                if (sameMessage(items.get(i), String.valueOf(candidates.get(k).get("role")), String.valueOf(candidates.get(k).get("text")))) {
                    found = k;
                    break;
                }
            }
            if (found < 0) {
                mismatch = true;
                break;
            }
            int sequence = ((Number) candidates.get(found).get("sequence")).intValue();
            record.addObject().put("sequence", sequence).put("itemId", items.get(i).path("id").asText());
            adoptedCurrent |= sequence == current;
            next = found + 1;
        }
        if (mismatch) {
            exchange.getMessage().setHeader("reconcileMismatch", true);
            exchange.getMessage().setHeader("rebuildReason", "unknown-items");
            return;
        }
        if (!adoptedCurrent) {
            ObjectNode body = JSON.createObjectNode();
            body.putArray("items").add(item(exchange.getMessage().getHeader("storedRole", String.class), exchange.getMessage().getHeader("storedText", String.class)));
            Answer added = call(exchange, "POST", base + "/items", body.toString());
            if (added.status() == 404) {
                exchange.getMessage().setHeader("foundryGone", true);
                exchange.getMessage().setHeader("rebuildReason", "gone");
                return;
            }
            record.addObject().put("sequence", current).put("itemId", firstItemId(added.body()));
        }
        exchange.getMessage().setHeader("adoptJson", record.toString());
        exchange.getMessage().setHeader("adoptCount", record.size());
        exchange.getMessage().setHeader("adoptedCurrent", adoptedCurrent);
    }

    /** True when the Foundry item is the message: the same role, and the same text. */
    private static boolean sameMessage(JsonNode item, String role, String text) {
        String itemRole = item.path("role").asText();
        if (!("appUser".equals(role) ? "user" : "assistant").equals(itemRole)) {
            return false;
        }
        JsonNode content = item.path("content");
        String itemText = content.isArray() ? content.path(0).path("text").asText() : content.asText();
        return text.equals(itemText);
    }

    /**
     * Builds the Foundry conversation of ours again from the stored messages, in order, when it cannot be repaired by
     * adding: a message arrived below the last synced sequence, Foundry no longer has the conversation, or it holds an
     * item nobody can account for.
     *
     * Reads the headers convMapRow (the old conversation, or none) and allMessages (every stored message to send: sequence,
     * role, text), in sequence order. Deletes the old Foundry conversation (a 404 is fine), creates the new one with the
     * first message and adds the rest, one call each. Sets foundryConversationId, rebuildJson (every item, as
     * [{"sequence":n,"itemId":"msg_..."}]) and rebuildLast (the highest sequence).
     *
     * It is one step, so a retry starts it over. The conversation made by an attempt that failed half way is remembered
     * in the exchange property rebuildAttempt and deleted by the next attempt, so a retry leaves no orphan.
     */
    @SuppressWarnings("unchecked")
    public void rebuild(Exchange exchange) throws Exception {
        configure(exchange.getContext());
        List<Map<String, Object>> messages = exchange.getMessage().getHeader("allMessages", List.class);
        Map<?, ?> oldRow = exchange.getMessage().getHeader("convMapRow", Map.class);
        String half = exchange.getProperty("rebuildAttempt", String.class);
        if (half != null) {
            call(exchange, "DELETE", "/openai/v1/conversations/" + half, null);
            exchange.removeProperty("rebuildAttempt");
        }
        if (oldRow != null) {
            call(exchange, "DELETE", "/openai/v1/conversations/" + oldRow.get("foundry_conversation_id"), null);
        }

        String conversationId = exchange.getMessage().getHeader("conversationId", String.class);
        ObjectNode create = JSON.createObjectNode();
        create.putObject("metadata").put("conversation_id", conversationId).put("source", SOURCE);
        create.putArray("items").add(item(String.valueOf(messages.get(0).get("role")), String.valueOf(messages.get(0).get("text"))));
        String fid = JSON.readTree(call(exchange, "POST", "/openai/v1/conversations", create.toString()).body()).path("id").asText();
        if (fid.isEmpty()) {
            throw new FoundryUnavailableException("Foundry created a conversation but returned no id");
        }
        exchange.setProperty("rebuildAttempt", fid);

        ArrayNode record = JSON.createArrayNode();
        record.addObject().put("sequence", ((Number) messages.get(0).get("sequence")).intValue())
                .put("itemId", firstItemId(call(exchange, "GET", "/openai/v1/conversations/" + fid + "/items?order=asc&limit=1", null).body()));
        for (int i = 1; i < messages.size(); i++) {
            ObjectNode body = JSON.createObjectNode();
            body.putArray("items").add(item(String.valueOf(messages.get(i).get("role")), String.valueOf(messages.get(i).get("text"))));
            record.addObject().put("sequence", ((Number) messages.get(i).get("sequence")).intValue())
                    .put("itemId", firstItemId(call(exchange, "POST", "/openai/v1/conversations/" + fid + "/items", body.toString()).body()));
        }
        exchange.getMessage().setHeader("foundryConversationId", fid);
        exchange.getMessage().setHeader("rebuildJson", record.toString());
        exchange.getMessage().setHeader("rebuildLast", ((Number) messages.get(messages.size() - 1).get("sequence")).intValue());
        exchange.removeProperty("rebuildAttempt");
    }

    // ---- the message as a Foundry item -----------------------------------------------------------------------------

    /**
     * A user message is sent as a string, which Foundry stores as input_text. An assistant message is sent as a list of
     * output_text parts, the shape Foundry itself returns for the assistant. (Foundry also accepts an assistant string, and
     * stores it as input_text, so the parts are a choice, not a requirement: scripts/foundry-limits-probe.py.)
     */
    private static ObjectNode item(String role, String text) {
        ObjectNode item = JSON.createObjectNode().put("type", "message");
        if ("appUser".equals(role)) {
            item.put("role", "user").put("content", text);
        } else {
            item.put("role", "assistant");
            item.putArray("content").addObject().put("type", "output_text").put("text", text);
        }
        return item;
    }

    private static String firstItemId(String listBody) throws IOException {
        JsonNode first = JSON.readTree(listBody).path("data").path(0);
        String id = first.path("id").asText();
        if (id.isEmpty()) {
            throw new FoundryUnavailableException("Foundry returned no item id");
        }
        return id;
    }

    // ---- HTTP, token and outcome classification --------------------------------------------------------------------

    private Answer call(Exchange exchange, String method, String path, String json) throws IOException, FoundryRejectedException {
        ensureToken();
        HttpRequest.Builder request = HttpRequest.newBuilder(URI.create(baseUrl() + path)).timeout(timeout)
                .header("Authorization", "Bearer " + token).header("Accept", "application/json");
        if (json == null) {
            request.method(method, HttpRequest.BodyPublishers.noBody());
        } else {
            request.header("Content-Type", "application/json").method(method, HttpRequest.BodyPublishers.ofString(json));
        }
        HttpResponse<String> response;
        try {
            response = http.send(request.build(), HttpResponse.BodyHandlers.ofString());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new FoundryUnavailableException("interrupted while calling Foundry", e);
        } catch (IOException e) {
            throw new FoundryUnavailableException("Foundry did not answer " + method + " " + path + ": " + e.getClass().getSimpleName(), e);
        }
        int status = response.statusCode();
        if (status / 100 == 2 || status == 404) {
            return new Answer(status, response.body());
        }
        if (status == 401) {
            invalidateToken();
        }
        if (status == 401 || status == 403 || status == 408 || status == 429 || status >= 500) {
            throw new FoundryUnavailableException("Foundry answered " + status + " to " + method + " " + path);
        }
        throw rejected(exchange, status, response.body());
    }

    private static FoundryRejectedException rejected(Exchange exchange, int status, String body) {
        String code = "unknown";
        String message = "";
        try {
            JsonNode error = JSON.readTree(body).path("error");
            code = error.path("code").asText("unknown");
            message = error.path("message").asText("");
        } catch (IOException e) {
            // the body is not JSON: the status is all there is
        }
        return new FoundryRejectedException(exchange, status, code, message.length() > MAX_DETAIL ? message.substring(0, MAX_DETAIL) : message);
    }

    private synchronized void ensureToken() throws IOException {
        if (token != null && Instant.now().isBefore(tokenExpires)) {
            return;
        }
        HttpRequest request = HttpRequest.newBuilder(URI.create(tokenUrl)).timeout(timeout).GET().build();
        try {
            HttpResponse<String> response = http.send(request, HttpResponse.BodyHandlers.ofString());
            if (response.statusCode() != 200) {
                throw new FoundryUnavailableException("the token broker answered " + response.statusCode());
            }
            JsonNode answer = JSON.readTree(response.body());
            token = answer.path("accessToken").asText();
            brokerEndpoint = answer.path("endpoint").asText("");
            // renew 30 s early, but never trust a lifetime shorter than 5 s
            tokenExpires = Instant.now().plusSeconds(Math.max(5, answer.path("expiresIn").asLong(0) - 30));
            if (token.isEmpty()) {
                throw new FoundryUnavailableException("the token broker returned no token");
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new FoundryUnavailableException("interrupted while asking the token broker", e);
        } catch (IOException e) {
            if (e instanceof FoundryUnavailableException) {
                throw e;
            }
            throw new FoundryUnavailableException("the token broker did not answer: " + e.getClass().getSimpleName(), e);
        }
    }

    private synchronized void invalidateToken() {
        token = null;
        tokenExpires = Instant.EPOCH;
    }

    private String baseUrl() throws FoundryUnavailableException {
        String base = !endpointOverride.isBlank() ? endpointOverride : (brokerEndpoint == null ? "" : brokerEndpoint);
        if (base.isBlank()) {
            throw new FoundryUnavailableException("no Foundry endpoint: set app.foundry.endpoint or FOUNDRY_PROJECT_ENDPOINT for the broker");
        }
        return base.endsWith("/") ? base.substring(0, base.length() - 1) : base;
    }

    private void configure(CamelContext context) {
        if (configured) {
            return;
        }
        synchronized (this) {
            if (!configured) {
                tokenUrl = context.resolvePropertyPlaceholders("{{app.foundry.tokenUrl}}");
                endpointOverride = context.resolvePropertyPlaceholders("{{app.foundry.endpoint}}");
                timeout = Duration.ofMillis(Long.parseLong(context.resolvePropertyPlaceholders("{{app.foundry.timeoutMs}}")));
                configured = true;
            }
        }
    }
}
