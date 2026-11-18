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
        body.putArray("items").add(item(exchange));
        String foundryConversationId = JSON.readTree(call(exchange, "POST", "/openai/v1/conversations", body.toString()).body()).path("id").asText();
        if (foundryConversationId.isEmpty()) {
            throw new FoundryUnavailableException("Foundry created a conversation but returned no id");
        }
        Answer items = call(exchange, "GET", "/openai/v1/conversations/" + foundryConversationId + "/items?order=asc&limit=1", null);
        exchange.getMessage().setHeader("foundryConversationId", foundryConversationId);
        exchange.getMessage().setHeader("foundryItemId", firstItemId(items.body()));
    }

    /**
     * Adds the message to the Foundry conversation in the header "convMapRow" (a row of foundry_conversation_map).
     * Sets "foundryItemId", and "foundryGone" to true when Foundry no longer has that conversation.
     */
    public void appendItem(Exchange exchange) throws Exception {
        configure(exchange.getContext());
        Map<?, ?> mapRow = exchange.getMessage().getHeader("convMapRow", Map.class);
        String foundryConversationId = String.valueOf(mapRow.get("foundry_conversation_id"));
        ObjectNode body = JSON.createObjectNode();
        body.putArray("items").add(item(exchange));
        Answer answer = call(exchange, "POST", "/openai/v1/conversations/" + foundryConversationId + "/items", body.toString());
        exchange.getMessage().setHeader("foundryGone", answer.status() == 404);
        if (answer.status() != 404) {
            exchange.getMessage().setHeader("foundryItemId", firstItemId(answer.body()));
        }
    }

    // ---- the message as a Foundry item -----------------------------------------------------------------------------

    /** A user message is a string; an assistant message must be a list of output_text parts (measured on the real API). */
    private static ObjectNode item(Exchange exchange) {
        String role = exchange.getMessage().getHeader("storedRole", String.class);
        String text = exchange.getMessage().getHeader("storedText", String.class);
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
