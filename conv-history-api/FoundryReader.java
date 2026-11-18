import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.apache.camel.BindToRegistry;
import org.apache.camel.CamelContext;
import org.apache.camel.Exchange;

/**
 * Reads the messages of a conversation from the Microsoft Foundry Conversations API.
 *
 * Like the sync's client it is a bean, so the token comes from the broker and not from the request, and no header of
 * the request is sent to Foundry. This project only reads. What Foundry cannot answer is a FoundryUnavailableException,
 * which the route turns into a 503: no network, a timeout, 401, 403, 408, 429, 5xx, and a 404 (Foundry no longer has
 * the conversation; the sync rebuilds it with the next message). Any other status is a bug: IllegalStateException, 500.
 *
 * Settings: app.foundry.tokenUrl (the broker), app.foundry.endpoint (empty: the broker's endpoint), app.foundry.timeoutMs.
 */
@BindToRegistry("foundryReader")
public class FoundryReader {

    private static final ObjectMapper JSON = new ObjectMapper();

    private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();

    private volatile boolean configured;
    private String tokenUrl;
    private String endpointOverride;
    private Duration timeout;

    private String token;
    private String brokerEndpoint;
    private Instant tokenExpires = Instant.EPOCH;

    /**
     * Reads one page of items. Reads the exchange properties foundryConversationId, direction (newest, before or after),
     * size and cursorItemId (the Foundry item of the cursor message, for before and after). Sets:
     *   foundryItems   the items of the page, oldest first: a list of {id, text}
     *   hasMore        true when Foundry has more in the direction read
     *
     * A page towards the past (newest, before) is read newest first, with the cursor as "after" in that order, and then
     * turned round; a page towards the present (after) is read oldest first. Foundry's after/before follow the order of the
     * listing, which is what makes "after the cursor in descending order" the messages older than it.
     */
    public void listItems(Exchange exchange) throws Exception {
        configure(exchange.getContext());
        String conversation = exchange.getProperty("foundryConversationId", String.class);
        String direction = exchange.getProperty("direction", String.class);
        int size = exchange.getProperty("size", Integer.class);
        String cursorItem = exchange.getProperty("cursorItemId", String.class);

        boolean forward = "after".equals(direction);
        String path = "/openai/v1/conversations/" + conversation + "/items?order=" + (forward ? "asc" : "desc") + "&limit=" + size
                + (cursorItem == null ? "" : "&after=" + cursorItem);
        JsonNode list = JSON.readTree(get(path));

        List<Map<String, String>> items = new ArrayList<>();
        for (JsonNode item : list.path("data")) {
            Map<String, String> one = new LinkedHashMap<>();
            one.put("id", item.path("id").asText());
            JsonNode content = item.path("content");
            one.put("text", content.isArray() ? content.path(0).path("text").asText() : content.asText());
            items.add(one);
        }
        if (!forward) {
            java.util.Collections.reverse(items);
        }
        exchange.setProperty("foundryItems", items);
        exchange.setProperty("hasMore", list.path("has_more").asBoolean(false));
    }

    // ---- HTTP, token and outcome classification --------------------------------------------------------------------

    private String get(String path) throws IOException {
        ensureToken();
        HttpRequest request = HttpRequest.newBuilder(URI.create(baseUrl() + path)).timeout(timeout)
                .header("Authorization", "Bearer " + token).header("Accept", "application/json").GET().build();
        HttpResponse<String> response;
        try {
            response = http.send(request, HttpResponse.BodyHandlers.ofString());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new FoundryUnavailableException("interrupted while calling Foundry", e);
        } catch (IOException e) {
            throw new FoundryUnavailableException("Foundry did not answer GET " + path.substring(0, path.indexOf('?')) + ": " + e.getClass().getSimpleName(), e);
        }
        int status = response.statusCode();
        if (status / 100 == 2) {
            return response.body();
        }
        if (status == 401) {
            invalidateToken();
        }
        if (status == 401 || status == 403 || status == 404 || status == 408 || status == 429 || status >= 500) {
            throw new FoundryUnavailableException("Foundry answered " + status + " to GET " + path.substring(0, path.indexOf('?'))
                    + (status == 404 ? " (it no longer has the conversation; the sync rebuilds it with the next message)" : ""));
        }
        throw new IllegalStateException("Foundry answered " + status + " to GET " + path.substring(0, path.indexOf('?')));
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
