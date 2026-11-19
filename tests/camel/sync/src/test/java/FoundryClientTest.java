import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.apache.camel.Exchange;
import org.apache.camel.impl.DefaultCamelContext;
import org.apache.camel.support.DefaultExchange;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/**
 * FoundryClient against the project's fake Foundry (scripts/fake-foundry, whose fidelity to the real service is checked by
 * test-fake-foundry.sh): the reconciliation after a lost response, the rebuild, and what each status means. The faults of
 * the fake (drop, 429, 500, 401) are the ones the real service can produce and cannot be asked to.
 */
class FoundryClientTest {

    private static final ObjectMapper JSON = new ObjectMapper();
    private static final String FAKE = System.getenv().getOrDefault("FAKE_FOUNDRY", "http://fake-foundry:8098");
    private static final String ENDPOINT = FAKE + "/api/projects/fake";
    /** A new client for each helper call: the fake's server closes a connection after each answer, and a reused one fails. */
    private static HttpClient http() {
        return HttpClient.newHttpClient();
    }

    private static FakeHttp broker;
    private FoundryClient client;
    private DefaultCamelContext context;

    @BeforeAll
    static void startBroker() throws IOException {
        broker = new FakeHttp();
        broker.answer("/token", FakeHttp.Answer.ok("{\"accessToken\":\"tok\",\"endpoint\":\"" + ENDPOINT + "\",\"expiresIn\":3600}"));
    }

    @AfterAll
    static void stopBroker() {
        broker.close();
    }

    @BeforeEach
    void freshFoundry() throws Exception {
        post("/__reset", "{}");
        context = contextFor(broker.url() + "/token", 3000);
        client = new FoundryClient();
    }

    private static DefaultCamelContext contextFor(String tokenUrl, long timeoutMs) {
        DefaultCamelContext context = new DefaultCamelContext();
        java.util.Properties p = new java.util.Properties();
        p.setProperty("app.foundry.tokenUrl", tokenUrl);
        p.setProperty("app.foundry.endpoint", "");
        p.setProperty("app.foundry.timeoutMs", Long.toString(timeoutMs));
        context.getPropertiesComponent().setOverrideProperties(p);
        return context;
    }

    // ---- driving the fake directly ----------------------------------------------------------------------------------------

    private static String post(String path, String body) throws Exception {
        HttpRequest.Builder request = HttpRequest.newBuilder(URI.create((path.startsWith("/__") ? FAKE : ENDPOINT) + path))
                .header("Content-Type", "application/json").header("Authorization", "Bearer direct").POST(HttpRequest.BodyPublishers.ofString(body));
        return http().send(request.build(), HttpResponse.BodyHandlers.ofString()).body();
    }

    private static String get(String path) throws Exception {
        return http().send(HttpRequest.newBuilder(URI.create(ENDPOINT + path)).header("Authorization", "Bearer direct").GET().build(), HttpResponse.BodyHandlers.ofString()).body();
    }

    private static int status(String method, String path) throws Exception {
        return http().send(HttpRequest.newBuilder(URI.create(ENDPOINT + path)).header("Authorization", "Bearer direct")
                .method(method, HttpRequest.BodyPublishers.noBody()).build(), HttpResponse.BodyHandlers.ofString()).statusCode();
    }

    private static void fail(String mode, int count, String method) throws Exception {
        post("/__fail", "{\"mode\":\"" + mode + "\",\"count\":" + count + (method == null ? "" : ",\"method\":\"" + method + "\"") + "}");
    }

    private static int conversations() throws Exception {
        return JSON.readTree(http().send(HttpRequest.newBuilder(URI.create(FAKE + "/__state")).GET().build(), HttpResponse.BodyHandlers.ofString()).body()).get("conversations").asInt();
    }

    /** Every item of a Foundry conversation, oldest first, as {id, role, type, text}. */
    private static List<Map<String, String>> itemsOf(String conversationId) throws Exception {
        List<Map<String, String>> all = new ArrayList<>();
        String after = null;
        while (true) {
            JsonNode page = JSON.readTree(get("/openai/v1/conversations/" + conversationId + "/items?order=asc&limit=20" + (after == null ? "" : "&after=" + after)));
            for (JsonNode item : page.get("data")) {
                Map<String, String> one = new LinkedHashMap<>();
                one.put("id", item.get("id").asText());
                one.put("role", item.get("role").asText());
                JsonNode content = item.get("content");
                one.put("type", content.isArray() ? content.get(0).get("type").asText() : "string");
                one.put("text", content.isArray() ? content.get(0).get("text").asText() : content.asText());
                all.add(one);
                after = one.get("id");
            }
            if (!page.get("has_more").asBoolean()) {
                return all;
            }
        }
    }

    /** A conversation of Foundry's with the given messages already in it, made directly (not through the client). */
    private static String foundryHolding(String... roleAndText) throws Exception {
        ObjectMapperHelper items = new ObjectMapperHelper();
        for (int i = 0; i < roleAndText.length; i += 2) {
            items.add(roleAndText[i], roleAndText[i + 1]);
        }
        String id = JSON.readTree(post("/openai/v1/conversations", "{\"metadata\":{\"conversation_id\":\"jt\"},\"items\":[" + items.first() + "]}")).get("id").asText();
        if (roleAndText.length > 2) {
            for (int i = 2; i < roleAndText.length; i += 2) {
                post("/openai/v1/conversations/" + id + "/items", "{\"items\":[" + ObjectMapperHelper.one(roleAndText[i], roleAndText[i + 1]) + "]}");
            }
        }
        return id;
    }

    private static final class ObjectMapperHelper {
        private final List<String> items = new ArrayList<>();

        void add(String role, String text) {
            items.add(one(role, text));
        }

        String first() {
            return items.get(0);
        }

        static String one(String role, String text) {
            try {
                return JSON.writeValueAsString(Map.of("type", "message", "role", role, "content", text));
            } catch (Exception e) {
                throw new IllegalStateException(e);
            }
        }
    }

    // ---- exchanges --------------------------------------------------------------------------------------------------------

    private Exchange exchange() {
        return new DefaultExchange(context);
    }

    private static Map<String, Object> stored(int sequence, String role, String text) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("sequence", sequence);
        m.put("role", role);
        m.put("text", text);
        return m;
    }

    /** A create-conversation exchange whose token broker and Foundry are the given local server (its /token says where Foundry is). */
    private static Exchange createFor(FakeHttp server) {
        Exchange e = new DefaultExchange(contextFor(server.url() + "/token", 2000));
        e.getMessage().setHeader("conversationId", "c");
        e.getMessage().setHeader("storedRole", "appUser");
        e.getMessage().setHeader("storedText", "x");
        return e;
    }

    private Exchange forCreate(String role, String text) {
        Exchange exchange = exchange();
        exchange.getMessage().setHeader("conversationId", "jt-conv");
        exchange.getMessage().setHeader("storedRole", role);
        exchange.getMessage().setHeader("storedText", text);
        return exchange;
    }

    /** The headers route 2 gives addItem: the conversation map row, the last mapped item, the next stored messages. */
    private Exchange forAdd(String foundryConversationId, int lastSynced, String lastItemId, int current, List<Map<String, Object>> candidates) {
        Exchange exchange = exchange();
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("foundry_conversation_id", foundryConversationId);
        row.put("last_synced_sequence", lastSynced);
        exchange.getMessage().setHeader("convMapRow", row);
        exchange.getMessage().setHeader("lastItemRow", lastItemId);
        exchange.getMessage().setHeader("candidates", candidates);
        exchange.getMessage().setHeader("sequence", current);
        Map<String, Object> now = candidates.stream().filter(c -> c.get("sequence").equals(current)).findFirst().orElseThrow();
        exchange.getMessage().setHeader("storedRole", now.get("role"));
        exchange.getMessage().setHeader("storedText", now.get("text"));
        return exchange;
    }

    private static String header(Exchange exchange, String name) {
        return exchange.getMessage().getHeader(name, String.class);
    }

    private static List<Map<String, Object>> record(Exchange exchange, String header) throws Exception {
        List<Map<String, Object>> out = new ArrayList<>();
        for (JsonNode n : JSON.readTree(header(exchange, header))) {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("sequence", n.get("sequence").asInt());
            m.put("itemId", n.get("itemId").asText());
            out.add(m);
        }
        return out;
    }

    // ---- create -----------------------------------------------------------------------------------------------------------

    @Test
    void creatingAConversationHoldsTheFirstMessageAndReadsItsItemIdBack() throws Exception {
        Exchange exchange = forCreate("appUser", "hola");

        client.createConversation(exchange);

        String id = header(exchange, "foundryConversationId");
        List<Map<String, String>> items = itemsOf(id);
        assertEquals(1, items.size());
        assertEquals(items.get(0).get("id"), header(exchange, "foundryItemId"));
        assertEquals("user|hola", items.get(0).get("role") + "|" + items.get(0).get("text"));
        assertTrue(JSON.readTree(get("/openai/v1/conversations/" + id)).get("metadata").toString().contains("jt-conv"), "the conversation id travels in the metadata");
    }

    @Test
    void aMakersMessageIsSentAsOutputTextParts() throws Exception {
        Exchange exchange = forCreate("appMaker", "buenas");

        client.createConversation(exchange);

        Map<String, String> item = itemsOf(header(exchange, "foundryConversationId")).get(0);
        assertEquals("assistant", item.get("role"));
        assertEquals("output_text", item.get("type"));
    }

    @Test
    void aUserMessageIsStoredAsInputText() throws Exception {
        Exchange exchange = forCreate("appUser", "hola");

        client.createConversation(exchange);

        assertEquals("input_text", itemsOf(header(exchange, "foundryConversationId")).get(0).get("type"));
    }

    @Test
    void awkwardTextSurvivesTheRoundTripExactly() throws Exception {
        String[] texts = {"", " ", "👨‍👩‍👧", "é é", "שלום مرحبا", "tab\tnew\nline\r\n", "  ​", "\\ \"quote\" {\"a\":1}", "x".repeat(50_000)};
        for (String text : texts) {
            Exchange exchange = forCreate("appUser", text);

            client.createConversation(exchange);

            assertEquals(text, itemsOf(header(exchange, "foundryConversationId")).get(0).get("text"));
        }
    }

    @Test
    void aCreateWhoseAnswerIsLostIsUnavailableAndLeavesAnOrphanThatTheCleanupFinds() throws Exception {
        fail("drop", 1, "POST");

        assertThrows(FoundryUnavailableException.class, () -> client.createConversation(forCreate("appUser", "hola")));

        assertEquals(1, conversations(), "Foundry did the work: this is the orphan scripts/foundry-cleanup-orphans.sh removes");
    }

    @Test
    void aFoundryThatRefusesTheMessageIsARefusalWithItsReasonForTheDeadLetterLog() throws Exception {
        fail("400", 1, "POST");
        Exchange exchange = forCreate("appUser", "hola");

        assertThrows(FoundryRejectedException.class, () -> client.createConversation(exchange));

        assertEquals("foundry-rejected", exchange.getProperty("dlqReason"));
        assertEquals("http-400", exchange.getProperty("dlqField"));
        assertTrue(String.valueOf(exchange.getProperty("dlqDetail")).contains("invalid_payload"));
    }

    // ---- statuses (the broker class stands in for Foundry here: any status is possible) ----------------------------------

    @ParameterizedTest(name = "Foundry answers {0}")
    @ValueSource(ints = {301, 302, 307, 401, 403, 408, 429, 500, 502, 503, 504})
    void aStatusThatALaterTryCanFixIsUnavailable(int status) throws Exception {
        try (FakeHttp foundry = new FakeHttp()) {
            foundry.answer("/token", FakeHttp.Answer.ok("{\"accessToken\":\"t\",\"endpoint\":\"" + foundry.url() + "\",\"expiresIn\":3600}"));
            foundry.answer("/openai/v1/conversations", FakeHttp.Answer.status(status));
            FoundryClient other = new FoundryClient();
            Exchange e = createFor(foundry);

            assertThrows(FoundryUnavailableException.class, () -> other.createConversation(e));
        }
    }

    @ParameterizedTest(name = "Foundry answers {0}")
    @ValueSource(ints = {400, 402, 405, 409, 410, 413, 418, 422})
    void anyOtherClientErrorIsRefusedForGood(int status) throws Exception {
        try (FakeHttp foundry = new FakeHttp()) {
            foundry.answer("/token", FakeHttp.Answer.ok("{\"accessToken\":\"t\",\"endpoint\":\"" + foundry.url() + "\",\"expiresIn\":3600}"));
            foundry.answer("/openai/v1/conversations", new FakeHttp.Answer(status, "{\"error\":{\"code\":\"nope\",\"message\":\"" + "m".repeat(500) + "\"}}", 0));
            FoundryClient other = new FoundryClient();
            Exchange e = createFor(foundry);

            assertThrows(FoundryRejectedException.class, () -> other.createConversation(e));

            assertEquals("http-" + status, e.getProperty("dlqField"));
            assertTrue(String.valueOf(e.getProperty("dlqDetail")).length() <= "nope: ".length() + 200, "the message of a refusal is cut to 200 characters");
        }
    }

    @Test
    void aRefusalWhoseBodyIsNotJsonStillNamesTheStatus() throws Exception {
        try (FakeHttp foundry = new FakeHttp()) {
            foundry.answer("/token", FakeHttp.Answer.ok("{\"accessToken\":\"t\",\"endpoint\":\"" + foundry.url() + "\",\"expiresIn\":3600}"));
            foundry.answer("/openai/v1/conversations", new FakeHttp.Answer(422, "<html>nope</html>", 0));
            FoundryClient other = new FoundryClient();
            Exchange e = createFor(foundry);

            assertThrows(FoundryRejectedException.class, () -> other.createConversation(e));

            assertEquals("http-422", e.getProperty("dlqField"));
            assertTrue(String.valueOf(e.getProperty("dlqDetail")).startsWith("unknown"));
        }
    }

    @Test
    void foundryNotAnsweringAtAllIsUnavailable() throws Exception {
        FoundryClient other = new FoundryClient();
        try (FakeHttp deadEnd = new FakeHttp()) {
            deadEnd.answer("/token", FakeHttp.Answer.ok("{\"accessToken\":\"t\",\"endpoint\":\"http://127.0.0.1:1\",\"expiresIn\":3600}"));
            Exchange e = createFor(deadEnd);

            assertThrows(FoundryUnavailableException.class, () -> other.createConversation(e));
        }
    }

    @Test
    void a401MakesTheNextCallAskTheBrokerForAFreshToken() throws Exception {
        int before = broker.calls("/token");
        client.createConversation(forCreate("appUser", "one"));
        fail("401", 1, null);
        assertThrows(FoundryUnavailableException.class, () -> client.createConversation(forCreate("appUser", "two")));

        client.createConversation(forCreate("appUser", "three"));

        assertEquals(before + 2, broker.calls("/token"), "one token, then a new one after the 401");
    }

    // ---- addItem: the reconciliation --------------------------------------------------------------------------------------

    @Test
    void aNewMessageIsSentAfterTheLastMappedItemAndRecorded() throws Exception {
        String conv = foundryHolding("user", "hola");
        String first = itemsOf(conv).get(0).get("id");
        Exchange exchange = forAdd(conv, 1, first, 2, List.of(stored(2, "appMaker", "buenas")));

        client.addItem(exchange);

        assertEquals("false", header(exchange, "adoptedCurrent"));
        assertEquals("false", header(exchange, "reconcileMismatch"));
        assertEquals("1", header(exchange, "adoptCount"));
        assertEquals(2, itemsOf(conv).size());
        assertEquals(itemsOf(conv).get(1).get("id"), record(exchange, "adoptJson").get(0).get("itemId"));
        assertEquals(2, record(exchange, "adoptJson").get(0).get("sequence"));
    }

    @Test
    void aMessageFoundryAlreadyHoldsBecauseTheAnswerWasLostIsAdoptedNotSentAgain() throws Exception {
        String conv = foundryHolding("user", "hola", "assistant", "buenas");   // item 2 is there: the earlier send worked, its answer was lost
        String first = itemsOf(conv).get(0).get("id");
        Exchange exchange = forAdd(conv, 1, first, 2, List.of(stored(2, "appMaker", "buenas")));

        client.addItem(exchange);

        assertEquals("true", header(exchange, "adoptedCurrent"));
        assertEquals(2, itemsOf(conv).size(), "no duplicate");
        assertEquals(itemsOf(conv).get(1).get("id"), record(exchange, "adoptJson").get(0).get("itemId"));
    }

    @Test
    void severalItemsFromEarlierLostAnswersAreAllAdoptedInOrder() throws Exception {
        String conv = foundryHolding("user", "m1", "user", "m2", "user", "m3");
        String first = itemsOf(conv).get(0).get("id");
        Exchange exchange = forAdd(conv, 1, first, 3, List.of(stored(2, "appUser", "m2"), stored(3, "appUser", "m3"), stored(4, "appUser", "m4")));

        client.addItem(exchange);

        assertEquals("true", header(exchange, "adoptedCurrent"));
        assertEquals(2, record(exchange, "adoptJson").size());
        assertEquals(List.of(2, 3), record(exchange, "adoptJson").stream().map(r -> r.get("sequence")).toList());
        assertEquals(3, itemsOf(conv).size(), "m4 was not sent: it is not the current message");
    }

    @Test
    void itemsAdoptedAndThenTheCurrentOneSentAreAllRecorded() throws Exception {
        String conv = foundryHolding("user", "m1", "user", "m2", "user", "m3");
        String first = itemsOf(conv).get(0).get("id");
        Exchange exchange = forAdd(conv, 1, first, 4, List.of(stored(2, "appUser", "m2"), stored(3, "appUser", "m3"), stored(4, "appUser", "m4")));

        client.addItem(exchange);

        assertEquals("false", header(exchange, "adoptedCurrent"));
        assertEquals(List.of(2, 3, 4), record(exchange, "adoptJson").stream().map(r -> r.get("sequence")).toList());
        assertEquals(4, itemsOf(conv).size());
        assertEquals("m4", itemsOf(conv).get(3).get("text"));
    }

    @Test
    void twoIdenticalMessagesInARowAreNotConfused() throws Exception {
        // the user said "ok" twice (sequences 2 and 3); Foundry holds one "ok"
        String conv = foundryHolding("user", "hola", "user", "ok");
        String first = itemsOf(conv).get(0).get("id");
        Exchange exchange = forAdd(conv, 1, first, 3, List.of(stored(2, "appUser", "ok"), stored(3, "appUser", "ok")));

        client.addItem(exchange);

        assertEquals("false", header(exchange, "adoptedCurrent"), "the held item is sequence 2; sequence 3 still has to be sent");
        assertEquals(List.of(2, 3), record(exchange, "adoptJson").stream().map(r -> r.get("sequence")).toList());
        assertEquals(3, itemsOf(conv).size());
    }

    @Test
    void aMessageSkippedEarlierIsSentBeforeALaterOneSoFoundryHasNoGap() throws Exception {
        // sequence 3 was dead-lettered (the consumer was down), then sequence 4 arrives: both are stored now
        String conv = foundryHolding("user", "m1", "user", "m2");
        String last = itemsOf(conv).get(1).get("id");
        Exchange exchange = forAdd(conv, 2, last, 4, List.of(stored(3, "appUser", "m3"), stored(4, "appUser", "m4")));

        client.addItem(exchange);

        assertEquals(java.util.List.of("m1", "m2", "m3", "m4"), itemsOf(conv).stream().map(i -> i.get("text")).toList());
        assertEquals(List.of(3, 4), record(exchange, "adoptJson").stream().map(r -> r.get("sequence")).toList());
        assertEquals("false", header(exchange, "reconcileMismatch"));
    }

    @Test
    void aLaterMessageAlreadyInFoundryWithAnEarlierOneMissingMeansRebuild() throws Exception {
        String conv = foundryHolding("user", "m1", "user", "m2", "user", "m4");   // damage from an older version: 3 is missing
        String second = itemsOf(conv).get(1).get("id");
        Exchange exchange = forAdd(conv, 2, second, 4, List.of(stored(3, "appUser", "m3"), stored(4, "appUser", "m4")));

        client.addItem(exchange);

        assertEquals("true", header(exchange, "reconcileMismatch"), "appending 3 now would put it after 4");
        assertEquals(3, itemsOf(conv).size(), "nothing was sent");
    }

    @Test
    void aCurrentMessageBeyondTheCandidatesWindowMeansRebuildNotAGap() throws Exception {
        String conv = foundryHolding("user", "m1");
        String first = itemsOf(conv).get(0).get("id");
        List<Map<String, Object>> window = new ArrayList<>();
        for (int s = 2; s <= 101; s++) {
            window.add(stored(s, "appUser", "m" + s));   // the query's LIMIT 100: sequences 2..101
        }
        Exchange exchange = forAdd(conv, 1, first, 101, window);
        exchange.getMessage().setHeader("sequence", 150);   // the message being handled is beyond them
        exchange.getMessage().setHeader("storedText", "m150");

        client.addItem(exchange);

        assertEquals("true", header(exchange, "reconcileMismatch"));
        assertEquals(1, itemsOf(conv).size());
    }

    @Test
    void aHundredMatchingItemsWithMoreBehindThemMeansRebuildNotAGuess() throws Exception {
        // Foundry lists 100 items at most per call. 101 follow the last mapped one and the first 100 all match the candidates (the
        // query's LIMIT 100): only has_more tells that one more exists that nobody can account for.
        String conv = foundryHolding("user", "m1");
        for (int from = 2; from <= 102; from += 20) {
            StringBuilder chunk = new StringBuilder();
            for (int s = from; s < from + 20 && s <= 102; s++) {
                chunk.append(chunk.length() == 0 ? "" : ",").append(ObjectMapperHelper.one("user", "m" + s));
            }
            post("/openai/v1/conversations/" + conv + "/items", "{\"items\":[" + chunk + "]}");   // at most 20 items per request
        }
        assertEquals(102, itemsOf(conv).size(), "the fixture is what the test says it is");
        String first = itemsOf(conv).get(0).get("id");
        List<Map<String, Object>> window = new ArrayList<>();
        for (int s = 2; s <= 101; s++) {
            window.add(stored(s, "appUser", "m" + s));
        }
        Exchange exchange = forAdd(conv, 1, first, 101, window);

        client.addItem(exchange);

        assertEquals("true", header(exchange, "reconcileMismatch"), "has_more is true: the 101st item is unexplained");
        assertEquals(102, itemsOf(conv).size(), "nothing was sent");
    }

    @Test
    void anItemFoundryHoldsThatNoStoredMessageExplainsMeansRebuild() throws Exception {
        String conv = foundryHolding("user", "hola", "user", "something nobody stored");
        String first = itemsOf(conv).get(0).get("id");
        Exchange exchange = forAdd(conv, 1, first, 2, List.of(stored(2, "appMaker", "buenas")));

        client.addItem(exchange);

        assertEquals("true", header(exchange, "reconcileMismatch"));
        assertEquals("unknown-items", header(exchange, "rebuildReason"));
        assertEquals(2, itemsOf(conv).size(), "nothing was sent");
    }

    @Test
    void theSameTextByTheOtherSideIsNotTheSameMessage() throws Exception {
        String conv = foundryHolding("user", "hola", "assistant", "same text");
        String first = itemsOf(conv).get(0).get("id");
        Exchange exchange = forAdd(conv, 1, first, 2, List.of(stored(2, "appUser", "same text")));   // stored as the user's

        client.addItem(exchange);

        assertEquals("true", header(exchange, "reconcileMismatch"));
    }

    @Test
    void aMessageBelowTheLastSyncedSequenceCannotBeInsertedSoItMeansRebuildWithoutAnyCall() throws Exception {
        String conv = foundryHolding("user", "m1", "user", "m3");
        int before = broker.calls("/token");
        Exchange exchange = forAdd(conv, 3, itemsOf(conv).get(1).get("id"), 2, List.of(stored(2, "appUser", "m2")));

        client.addItem(exchange);

        assertEquals("true", header(exchange, "reconcileMismatch"));
        assertEquals("late-event", header(exchange, "rebuildReason"));
        assertEquals(before, broker.calls("/token"), "no call to Foundry at all");
        assertEquals(2, itemsOf(conv).size());
    }

    @Test
    void aConversationFoundryNoLongerHasIsGone() throws Exception {
        String conv = foundryHolding("user", "hola");
        String first = itemsOf(conv).get(0).get("id");
        status("DELETE", "/openai/v1/conversations/" + conv);
        Exchange exchange = forAdd(conv, 1, first, 2, List.of(stored(2, "appMaker", "buenas")));

        client.addItem(exchange);

        assertEquals("true", header(exchange, "foundryGone"));
        assertEquals("gone", header(exchange, "rebuildReason"));
    }

    @Test
    void moreThanAHundredUnmappedItemsMeansRebuildNotAGuess() throws Exception {
        String conv = foundryHolding("user", "hola");
        for (int i = 0; i < 6; i++) {
            StringBuilder items = new StringBuilder();
            for (int k = 0; k < 20; k++) {
                items.append(k == 0 ? "" : ",").append(ObjectMapperHelper.one("user", "extra " + (i * 20 + k)));
            }
            post("/openai/v1/conversations/" + conv + "/items", "{\"items\":[" + items + "]}");
        }
        String first = itemsOf(conv).get(0).get("id");
        Exchange exchange = forAdd(conv, 1, first, 2, List.of(stored(2, "appUser", "extra 0")));

        client.addItem(exchange);

        assertEquals("true", header(exchange, "reconcileMismatch"), "121 items follow the last mapped one: Foundry says there are more than it showed");
    }

    @Test
    void theFirstItemsOfAConversationWithNoMappedItemYetAreReadFromTheStart() throws Exception {
        String conv = foundryHolding("user", "m1");
        Exchange exchange = forAdd(conv, 1, null, 1, List.of(stored(1, "appUser", "m1")));

        client.addItem(exchange);

        assertEquals("true", header(exchange, "adoptedCurrent"));
        assertEquals(1, itemsOf(conv).size());
    }

    @Test
    void whenFoundryBreaksTheReadIsUnavailableAndNothingIsSentOrRecorded() throws Exception {
        String conv = foundryHolding("user", "hola");
        String first = itemsOf(conv).get(0).get("id");
        for (String mode : new String[] {"429", "500", "401"}) {
            fail(mode, 1, "GET");
            Exchange exchange = forAdd(conv, 1, first, 2, List.of(stored(2, "appMaker", "buenas")));

            assertThrows(FoundryUnavailableException.class, () -> client.addItem(exchange), mode);

            assertEquals("[]", header(exchange, "adoptJson"), "nothing was recorded");
            assertEquals(1, itemsOf(conv).size());
        }
    }

    @Test
    void aSendWhoseAnswerIsLostIsAdoptedByTheNextAttemptWithoutADuplicate() throws Exception {
        String conv = foundryHolding("user", "hola");
        String first = itemsOf(conv).get(0).get("id");
        List<Map<String, Object>> candidates = List.of(stored(2, "appMaker", "buenas"));
        fail("drop", 1, "POST");
        assertThrows(FoundryUnavailableException.class, () -> client.addItem(forAdd(conv, 1, first, 2, candidates)));
        assertEquals(2, itemsOf(conv).size(), "Foundry kept it although the caller saw a failure");

        Exchange retry = forAdd(conv, 1, first, 2, candidates);
        client.addItem(retry);

        assertEquals("true", header(retry, "adoptedCurrent"));
        assertEquals(2, itemsOf(conv).size(), "the retry looked first, so there is still one copy");
    }

    @Test
    void aSendRefusedByFoundryIsARefusalNotARetry() throws Exception {
        String conv = foundryHolding("user", "hola");
        String first = itemsOf(conv).get(0).get("id");
        fail("400", 1, "POST");

        assertThrows(FoundryRejectedException.class, () -> client.addItem(forAdd(conv, 1, first, 2, List.of(stored(2, "appMaker", "buenas")))));
    }

    // ---- rebuild ----------------------------------------------------------------------------------------------------------

    private Exchange forRebuild(String oldFoundryConversation, int n) {
        Exchange exchange = exchange();
        exchange.getMessage().setHeader("conversationId", "jt-conv");
        List<Map<String, Object>> all = new ArrayList<>();
        for (int i = 1; i <= n; i++) {
            all.add(stored(i, i % 2 == 1 ? "appUser" : "appMaker", "message " + i));
        }
        exchange.getMessage().setHeader("allMessages", all);
        if (oldFoundryConversation != null) {
            exchange.getMessage().setHeader("convMapRow", Map.of("foundry_conversation_id", oldFoundryConversation, "last_synced_sequence", 1));
        }
        return exchange;
    }

    @Test
    void aRebuildSendsEveryStoredMessageInOrderAndLeavesTheOldConversationUntilItIsToldToDeleteIt() throws Exception {
        String old = foundryHolding("user", "stale");
        Exchange exchange = forRebuild(old, 25);

        client.rebuild(exchange);

        String fresh = header(exchange, "foundryConversationId");
        List<Map<String, String>> items = itemsOf(fresh);
        assertEquals(25, items.size());
        for (int i = 0; i < 25; i++) {
            assertEquals("message " + (i + 1), items.get(i).get("text"));
            assertEquals((i + 1) % 2 == 1 ? "user" : "assistant", items.get(i).get("role"));
        }
        assertEquals(25, record(exchange, "rebuildJson").size());
        assertEquals(25, exchange.getMessage().getHeader("rebuildLast", Integer.class));
        assertEquals(items.get(24).get("id"), record(exchange, "rebuildJson").get(24).get("itemId"));
        assertEquals(200, status("GET", "/openai/v1/conversations/" + old), "the old conversation is not touched while the maps still point at it");
        assertEquals(2, conversations());

        client.deleteOldConversation(exchange);   // route 5 calls it once the maps point at the new one

        assertEquals(404, status("GET", "/openai/v1/conversations/" + old));
        assertEquals(1, conversations());
        assertEquals(25, itemsOf(fresh).size(), "and the new one is intact");
    }

    @Test
    void deletingTheOldConversationIsHarmlessWhenItIsGoneWhenThereIsNoneOrItIsTheNewOne() throws Exception {
        String old = foundryHolding("user", "stale");
        status("DELETE", "/openai/v1/conversations/" + old);
        Exchange gone = forRebuild(old, 2);
        client.rebuild(gone);
        client.deleteOldConversation(gone);   // a 404: fine
        client.deleteOldConversation(gone);   // and again

        Exchange none = forRebuild(null, 1);
        client.rebuild(none);
        client.deleteOldConversation(none);   // no old row: nothing to do

        Exchange same = forRebuild(null, 1);
        client.rebuild(same);
        same.getMessage().setHeader("convMapRow", Map.of("foundry_conversation_id", header(same, "foundryConversationId"), "last_synced_sequence", 1));
        client.deleteOldConversation(same);   // never deletes what it just built

        assertEquals(3, conversations(), "the three rebuilt conversations are all there");
        assertEquals(1, itemsOf(header(same, "foundryConversationId")).size());
    }

    @Test
    void aRebuildOfAConversationFoundryAlreadyLostIsFine() throws Exception {
        String old = foundryHolding("user", "stale");
        status("DELETE", "/openai/v1/conversations/" + old);

        Exchange exchange = forRebuild(old, 3);
        client.rebuild(exchange);

        assertEquals(3, itemsOf(header(exchange, "foundryConversationId")).size());
    }

    @Test
    void aRebuildWithNoOldConversationAndOneMessageWorks() throws Exception {
        Exchange exchange = forRebuild(null, 1);

        client.rebuild(exchange);

        assertEquals(1, itemsOf(header(exchange, "foundryConversationId")).size());
        assertEquals(1, exchange.getMessage().getHeader("rebuildLast", Integer.class));
    }

    @Test
    void aHundredAndFiftyMessagesAreRebuiltOneCallEach() throws Exception {
        Exchange exchange = forRebuild(null, 150);

        client.rebuild(exchange);

        List<Map<String, String>> items = itemsOf(header(exchange, "foundryConversationId"));
        assertEquals(150, items.size());
        assertEquals("message 150", items.get(149).get("text"));
        assertEquals(150, record(exchange, "rebuildJson").size());
    }

    @Test
    void aRebuildThatFailsHalfWayLeavesNoOrphanWhenItIsRetried() throws Exception {
        Exchange exchange = forRebuild(null, 5);
        fail("500", 1, "GET");   // after the create, the read-back of the first item fails: a half-built conversation exists
        assertThrows(FoundryUnavailableException.class, () -> client.rebuild(exchange));
        assertEquals(1, conversations(), "the half-built conversation");
        assertNotEquals(null, exchange.getProperty("rebuildAttempt"));

        client.rebuild(exchange);   // the retry, on the same exchange, as Camel does

        assertEquals(1, conversations(), "the half-built one was deleted before the new one was made: no orphan");
        assertEquals(5, itemsOf(header(exchange, "foundryConversationId")).size());
        assertNull(exchange.getProperty("rebuildAttempt"));
    }

    @Test
    void aRebuildRefusedByFoundryIsARefusalAndTheOldConversationIsStillThere() throws Exception {
        String old = foundryHolding("user", "stale");
        fail("400", 1, "POST");

        assertThrows(FoundryRejectedException.class, () -> client.rebuild(forRebuild(old, 3)));

        assertEquals(200, status("GET", "/openai/v1/conversations/" + old), "a refusal no longer leaves the conversation with no copy at all");
    }

    @Test
    void aRebuildRefusedHalfWayLeavesTheOldConversationAndTheNextAttemptRemovesTheHalfBuiltOne() throws Exception {
        String old = foundryHolding("user", "stale");
        Exchange exchange = forRebuild(old, 5);
        fail("500", 1, "GET");   // after the create: the read-back of the first item fails
        assertThrows(FoundryUnavailableException.class, () -> client.rebuild(exchange));
        assertEquals(2, conversations(), "the old one and the half-built one");

        client.rebuild(exchange);
        client.deleteOldConversation(exchange);

        assertEquals(1, conversations(), "only the new one is left");
        assertEquals(5, itemsOf(header(exchange, "foundryConversationId")).size());
    }

    @Test
    void theConversationIsCreatedWithTheInstanceAndTheSourceInItsMetadata() throws Exception {
        Exchange exchange = forCreate("appUser", "hola");

        client.createConversation(exchange);

        JsonNode metadata = JSON.readTree(get("/openai/v1/conversations/" + header(exchange, "foundryConversationId"))).get("metadata");
        assertEquals("default", metadata.get("instance").asText());
        assertEquals("ms-ml-camel-conv-history-bs", metadata.get("source").asText());
        assertEquals("jt-conv", metadata.get("conversation_id").asText());
    }

    @Test
    void theClientSendsTheBrokersTokenAndNeverAnAuthorizationHeaderOfTheMessage() throws Exception {
        try (FakeHttp foundry = new FakeHttp()) {
            foundry.answer("/token", FakeHttp.Answer.ok("{\"accessToken\":\"the-brokers\",\"endpoint\":\"" + foundry.url() + "\",\"expiresIn\":3600}"));
            foundry.answer("/openai/v1/conversations", FakeHttp.Answer.ok("{\"id\":\"conv_1\"}"));
            foundry.answer("/openai/v1/conversations/conv_1/items", FakeHttp.Answer.ok("{\"data\":[{\"id\":\"msg_1\"}]}"));
            Exchange exchange = createFor(foundry);
            exchange.getMessage().setHeader("Authorization", "Bearer the-clients-own");

            new FoundryClient().createConversation(exchange);

            List<String> sent = foundry.requests().stream().filter(r -> !r.path().equals("/token")).map(FakeHttp.Seen::authorization).toList();
            assertEquals(List.of("Bearer the-brokers", "Bearer the-brokers"), sent);
        }
    }
}
