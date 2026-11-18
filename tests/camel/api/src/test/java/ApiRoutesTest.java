import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.zaxxer.hikari.HikariDataSource;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.Statement;
import java.time.Duration;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.CompletableFuture;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.apache.camel.main.Main;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

/**
 * The API as a client sees it: the project's real YAML routes and Java beans in a Camel Main with a real HTTP server, the
 * cluster's Postgres with fixtures (every key starts with "jt-" and is removed at the end), and a fake Foundry that pages
 * the way the real one does (order, limit, after). Nothing in the project is replaced by a double.
 */
class ApiRoutesTest {

    private static final ObjectMapper JSON = new ObjectMapper();
    private static final String PROBLEM = "application/problem+json";
    private static final String TYPE = "tag:yape.com.pe,2026:conversation-history:";
    private static final String ITEMS = "/openai/v1/conversations/%s/items";

    private static FakeHttp foundry;
    private static Main main;
    private static HikariDataSource db;
    private static HttpClient client;
    private static String base;

    // ---- fixtures ---------------------------------------------------------------------------------------------------------

    @BeforeAll
    static void boot() throws Exception {
        foundry = new FakeHttp();
        foundry.answer("/token", FakeHttp.Answer.ok("{\"accessToken\":\"tok\",\"endpoint\":\"" + foundry.url() + "\",\"expiresIn\":3600}"));

        db = new HikariDataSource();
        db.setJdbcUrl(System.getenv().getOrDefault("JDBC_URL", "jdbc:postgresql://db:5432/postgres?currentSchema=camel_history"));
        db.setUsername("postgres");
        db.setMaximumPoolSize(4);
        cleanDatabase();
        loadFixtures();

        int port = 8080;   // the port Karavan's runtime uses: ProblemHandlers finds the router under its default name only on this one
        base = "http://127.0.0.1:" + port;

        ProblemHandlers handlers = new ProblemHandlers();
        main = new Main();
        main.bind("apiRequest", new ApiRequest());
        main.bind("conversationList", new ConversationList());
        main.bind("messagePage", new MessagePage());
        main.bind("problem", new ProblemResponder());
        main.bind("foundryReader", new FoundryReader());
        main.bind("pgDataSource", db);
        main.addInitialProperty("camel.rest.component", "platform-http");
        main.addInitialProperty("camel.server.enabled", "true");
        main.addInitialProperty("camel.server.host", "127.0.0.1");
        main.addInitialProperty("camel.server.port", Integer.toString(port));
        main.addInitialProperty("app.foundry.tokenUrl", foundry.url() + "/token");
        main.addInitialProperty("app.foundry.endpoint", "");
        main.addInitialProperty("app.foundry.timeoutMs", "3000");
        main.configure().withRoutesIncludePattern("file:../../../conv-history-api/*.camel.yaml");
        main.start();
        handlers.setCamelContext(main.getCamelContext());   // the context is up, so the listener runs at once with alreadyStarted = true

        client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();
        waitUntilUp();
    }

    @AfterAll
    static void shutDown() throws Exception {
        if (main != null) {
            main.stop();
        }
        cleanDatabase();
        db.close();
        foundry.close();
    }

    private static void waitUntilUp() throws Exception {
        for (int i = 0; i < 60; i++) {
            try {
                if (get("/health").statusCode() == 200) {
                    return;
                }
            } catch (Exception e) {
                // not up yet
            }
            Thread.sleep(500);
        }
        throw new IllegalStateException("the API did not come up");
    }

    private static void sql(String statement) throws Exception {
        try (Connection c = db.getConnection(); Statement s = c.createStatement()) {
            s.execute(statement);
        }
    }

    private static void cleanDatabase() throws Exception {
        sql("DELETE FROM foundry_conversation_map WHERE conversation_id LIKE 'jt-%'");   // the item map goes with it (cascade)
        sql("DELETE FROM conversation_messages WHERE conversation_id LIKE 'jt-%'");
        sql("DELETE FROM conversation_summaries WHERE conversation_id LIKE 'jt-%'");
    }

    /** One conversation of an account: a summary, and a Foundry mapping unless unmapped. */
    private static void conversation(String account, String id, String lastAt, boolean mapped) throws Exception {
        sql("INSERT INTO conversation_summaries VALUES ('" + account + "', '" + id + "', 3, timestamptz '" + lastAt + "' - interval '1 hour', timestamptz '" + lastAt + "')");
        if (mapped) {
            sql("INSERT INTO foundry_conversation_map (conversation_id, foundry_conversation_id, last_synced_sequence) VALUES ('" + id + "', 'conv_" + id + "', 3)");
        }
    }

    private static void loadFixtures() throws Exception {
        // jt-acct-main: seven mapped conversations a minute apart, and one that Foundry does not hold
        for (int i = 0; i < 7; i++) {
            conversation("jt-acct-main", "jt-c-" + i, "2026-11-01 10:0" + i + ":00.123456+00", true);
        }
        conversation("jt-acct-main", "jt-c-unmapped", "2026-11-01 12:00:00+00", false);
        conversation("jt-acct-other", "jt-c-other", "2026-11-01 12:30:00+00", true);

        // jt-acct-tie: three at the same instant (the id decides), and two a microsecond apart
        for (String id : List.of("jt-t-a", "jt-t-b", "jt-t-c")) {
            conversation("jt-acct-tie", id, "2026-11-02 09:00:00+00", true);
        }
        conversation("jt-acct-tie", "jt-u-1", "2026-11-02 08:00:00.000001+00", true);
        conversation("jt-acct-tie", "jt-u-2", "2026-11-02 08:00:00.000002+00", true);

        // jt-acct-big: more than two default pages
        sql("INSERT INTO conversation_summaries SELECT 'jt-acct-big', 'jt-b-' || lpad(n::text, 4, '0'), 2, "
                + "timestamptz '2026-10-01 00:00:00+00' + n * interval '1 minute', timestamptz '2026-10-01 00:00:00+00' + n * interval '1 minute' + interval '10 seconds' "
                + "FROM generate_series(1, 230) n");
        sql("INSERT INTO foundry_conversation_map (conversation_id, foundry_conversation_id, last_synced_sequence) "
                + "SELECT conversation_id, 'conv_' || conversation_id, 2 FROM conversation_summaries WHERE id_yape_account = 'jt-acct-big'");

        // jt-m-main: 25 messages; the text lives in the fake Foundry, the rest here
        sql("INSERT INTO foundry_conversation_map (conversation_id, foundry_conversation_id, last_synced_sequence) VALUES ('jt-m-main', 'conv_jt-m-main', 25)");
        sql("INSERT INTO conversation_messages (conversation_id, sequence, role, author_id, type, text, truncated, event_name, id_yape_account, flow, occurred_at) "
                + "SELECT 'jt-m-main', n, CASE WHEN n % 2 = 1 THEN 'appUser' ELSE 'appMaker' END, 'author-' || n, 'text', 'db copy ' || n, n = 3, 'ev-' || n, 'jt-acct-main', "
                + "CASE WHEN n = 4 THEN 'flow-x' END, timestamptz '2026-11-03 10:00:00+00' + n * interval '1 second' + n * interval '1 microsecond' FROM generate_series(1, 25) n");
        sql("INSERT INTO foundry_item_map (conversation_id, sequence, foundry_item_id) SELECT 'jt-m-main', n, 'jt-m-main_msg_' || lpad(n::text, 3, '0') FROM generate_series(1, 25) n");
        foundry.answerWith(ITEMS.formatted("conv_jt-m-main"), request -> pagedItems(request, 25, null, "jt-m-main"));

        // jt-m-gap: the sync wrote the item map but one of Foundry's items is not in it (an inconsistency)
        sql("INSERT INTO foundry_conversation_map (conversation_id, foundry_conversation_id, last_synced_sequence) VALUES ('jt-m-gap', 'conv_jt-m-gap', 2)");
        sql("INSERT INTO conversation_messages (conversation_id, sequence, role, author_id, text, event_name, occurred_at) "
                + "SELECT 'jt-m-gap', n, 'appUser', 'a', 't', 'e', now() FROM generate_series(1, 2) n");
        sql("INSERT INTO foundry_item_map (conversation_id, sequence, foundry_item_id) VALUES ('jt-m-gap', 1, 'jt-m-gap_msg_001')");
        foundry.answerWith(ITEMS.formatted("conv_jt-m-gap"), request -> pagedItems(request, 2, null, "jt-m-gap"));

        // jt-m-fail: Foundry's answer is whatever a test sets
        sql("INSERT INTO foundry_conversation_map (conversation_id, foundry_conversation_id, last_synced_sequence) VALUES ('jt-m-fail', 'conv_jt-m-fail', 1)");
        sql("INSERT INTO conversation_messages (conversation_id, sequence, role, author_id, text, event_name, occurred_at) VALUES ('jt-m-fail', 1, 'appUser', 'a', 't', 'e', now())");
        sql("INSERT INTO foundry_item_map (conversation_id, sequence, foundry_item_id) VALUES ('jt-m-fail', 1, 'jt-m-fail_msg_001')");

        // jt-m-text: text that is hard to carry
        sql("INSERT INTO foundry_conversation_map (conversation_id, foundry_conversation_id, last_synced_sequence) VALUES ('jt-m-text', 'conv_jt-m-text', 1)");
        sql("INSERT INTO conversation_messages (conversation_id, sequence, role, author_id, text, event_name, occurred_at) VALUES ('jt-m-text', 1, 'appUser', 'a', 't', 'e', now())");
        sql("INSERT INTO foundry_item_map (conversation_id, sequence, foundry_item_id) VALUES ('jt-m-text', 1, 'jt-m-text_msg_001')");
    }

    /** Foundry's items of a conversation of n messages (msg_001 ...), with its order/limit/after paging. */
    private static FakeHttp.Answer pagedItems(FakeHttp.Seen request, int n, String text, String conversation) {
        String query = request.query() == null ? "" : request.query();
        String order = param(query, "order", "desc");
        int limit = Integer.parseInt(param(query, "limit", "20"));
        String after = param(query, "after", null);
        List<String> ids = new ArrayList<>();
        for (int i = 1; i <= n; i++) {
            ids.add(String.format("%s_msg_%03d", conversation, i));
        }
        if (order.equals("desc")) {
            java.util.Collections.reverse(ids);
        }
        int start = after == null ? 0 : ids.indexOf(after) + 1;
        if (after != null && start == 0) {
            return new FakeHttp.Answer(404, "{\"error\":{\"message\":\"no such item\"}}", 0);
        }
        List<String> page = ids.subList(start, Math.min(ids.size(), start + limit));
        StringBuilder data = new StringBuilder();
        for (String id : page) {
            data.append(data.length() == 0 ? "" : ",").append("{\"id\":\"").append(id).append("\",\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"")
                    .append(text != null ? text : "foundry says " + Integer.parseInt(id.substring(id.length() - 3))).append("\"}]}");
        }
        boolean more = start + limit < ids.size();
        return FakeHttp.Answer.ok("{\"object\":\"list\",\"data\":[" + data + "],\"has_more\":" + more + "}");
    }

    private static String param(String query, String name, String fallback) {
        for (String pair : query.split("&")) {
            if (pair.startsWith(name + "=")) {
                return pair.substring(name.length() + 1);
            }
        }
        return fallback;
    }

    // ---- HTTP helpers -----------------------------------------------------------------------------------------------------

    private static HttpResponse<String> get(String pathAndQuery, String... headers) throws Exception {
        return send("GET", pathAndQuery, headers);
    }

    private static HttpResponse<String> send(String method, String pathAndQuery, String... headers) throws Exception {
        HttpRequest.Builder request = HttpRequest.newBuilder(URI.create(base + pathAndQuery)).timeout(Duration.ofSeconds(15))
                .method(method, HttpRequest.BodyPublishers.noBody());
        for (int i = 0; i < headers.length; i += 2) {
            request.header(headers[i], headers[i + 1]);
        }
        return client.send(request.build(), HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
    }

    private static JsonNode json(HttpResponse<String> response) throws Exception {
        return JSON.readTree(response.body());
    }

    private static List<String> conversationIds(JsonNode body) {
        List<String> ids = new ArrayList<>();
        body.get("conversations").forEach(c -> ids.add(c.get("_id").asText()));
        return ids;
    }

    private static List<String> messageIds(JsonNode body) {
        List<String> ids = new ArrayList<>();
        body.get("messages").forEach(m -> ids.add(m.get("_id").asText()));
        return ids;
    }

    private static final Pattern LINK = Pattern.compile("^<(.+)>; rel=\"(next|prev)\"$");

    /** The target of the Link header, as a path and query to call again, or null when the answer has none. */
    private static String next(HttpResponse<String> response) {
        String link = response.headers().firstValue("Link").orElse(null);
        if (link == null) {
            return null;
        }
        Matcher m = LINK.matcher(link);
        assertTrue(m.matches(), "a Link header the contract allows: " + link);
        return m.group(1).replace("[", "%5B").replace("]", "%5D");
    }

    private static void assertProblem(HttpResponse<String> response, int status, String type) throws Exception {
        assertEquals(status, response.statusCode(), response.body());
        assertEquals(PROBLEM, response.headers().firstValue("Content-Type").orElse(""));
        JsonNode body = json(response);
        assertEquals(status, body.get("status").asInt());
        assertEquals(type, body.get("type").asText());
        assertNotNull(body.get("title"));
        assertNotNull(body.get("detail"));
    }

    // ---- health -----------------------------------------------------------------------------------------------------------

    @Test
    void healthIs200WithAJsonStatus() throws Exception {
        HttpResponse<String> response = get("/health");

        assertEquals(200, response.statusCode());
        assertEquals("application/json", response.headers().firstValue("Content-Type").orElse(""));
        assertEquals("{\"status\":\"ok\"}", response.body());
    }

    // ---- the conversation list --------------------------------------------------------------------------------------------

    @Test
    void theNewestPageHoldsTheMappedConversationsOfTheAccountMostRecentFirst() throws Exception {
        HttpResponse<String> response = get("/v1/conversations?idYapeAccount=jt-acct-main");

        assertEquals(200, response.statusCode());
        assertEquals(List.of("jt-c-6", "jt-c-5", "jt-c-4", "jt-c-3", "jt-c-2", "jt-c-1", "jt-c-0"), conversationIds(json(response)),
                "the unmapped conversation and the other account's are not there");
        assertNull(response.headers().firstValue("Link").orElse(null), "7 conversations fit in a page of 100");
    }

    @Test
    void eachConversationCarriesItsCursorCountAndTimes() throws Exception {
        JsonNode first = json(get("/v1/conversations?idYapeAccount=jt-acct-main&page[size]=1".replace("[", "%5B").replace("]", "%5D"))).get("conversations").get(0);

        assertEquals("jt-c-6", first.get("_id").asText());
        assertEquals("1793527560123456~jt-c-6", first.get("cursor").asText(), "2026-11-01 10:06:00.123456 UTC in microseconds");
        assertEquals(3, first.get("messageCount").asInt());
        assertEquals(1793527560.123, first.get("lastReceived").asDouble(), 0.0000001);
        assertEquals(1793523960.123, first.get("firstReceived").asDouble(), 0.0000001);
    }

    @Test
    void anAccountWithNoConversationsGetsAnEmptyListNotAnError() throws Exception {
        HttpResponse<String> response = get("/v1/conversations?idYapeAccount=jt-acct-empty");

        assertEquals(200, response.statusCode());
        assertEquals("{\"conversations\":[]}", response.body());
    }

    private List<String> walk(String start, int maxPages) throws Exception {
        List<String> seen = new ArrayList<>();
        String target = start;
        for (int page = 0; target != null; page++) {
            assertTrue(page < maxPages, "the walk does not end");
            HttpResponse<String> response = get(target);
            assertEquals(200, response.statusCode(), response.body());
            seen.addAll(conversationIds(json(response)));
            target = next(response);
        }
        return seen;
    }

    @Test
    void walkingBackInPagesOfTwoVisitsEveryConversationOnceInOrder() throws Exception {
        List<String> seen = walk("/v1/conversations?idYapeAccount=jt-acct-main&page%5Bsize%5D=2", 10);

        assertEquals(List.of("jt-c-6", "jt-c-5", "jt-c-4", "jt-c-3", "jt-c-2", "jt-c-1", "jt-c-0"), seen);
    }

    @Test
    void walkingForwardFromTheOldestVisitsTheRestMostRecentFirstPerPage() throws Exception {
        String oldestCursor = "1793527200123456~jt-c-0";   // 10:00:00.123456 on 2026-11-01
        List<String> seen = walk("/v1/conversations?idYapeAccount=jt-acct-main&page%5Bafter%5D=" + oldestCursor + "&page%5Bsize%5D=2", 10);

        assertEquals(List.of("jt-c-2", "jt-c-1", "jt-c-4", "jt-c-3", "jt-c-6", "jt-c-5"), seen, "each page most recent first, pages going forward");
    }

    @Test
    void threeConversationsAtTheSameInstantAreEachVisitedOnceWhateverThePageSize() throws Exception {
        List<String> seen = walk("/v1/conversations?idYapeAccount=jt-acct-tie&page%5Bsize%5D=1", 10);

        assertEquals(List.of("jt-t-c", "jt-t-b", "jt-t-a", "jt-u-2", "jt-u-1"), seen,
                "the id breaks the tie, and a microsecond apart is not the same instant");
    }

    @Test
    void aMicrosecondOfDifferenceSurvivesTheCursor() throws Exception {
        HttpResponse<String> first = get("/v1/conversations?idYapeAccount=jt-acct-tie&page%5Bbefore%5D=1793606400000002~jt-u-2&page%5Bsize%5D=5");

        assertEquals(List.of("jt-u-1"), conversationIds(json(first)));
    }

    @Test
    void twoHundredAndThirtyConversationsTakeThreeDefaultPagesAndNoneIsLostOrRepeated() throws Exception {
        List<String> seen = walk("/v1/conversations?idYapeAccount=jt-acct-big", 5);

        assertEquals(230, seen.size());
        assertEquals(230, new HashSet<>(seen).size(), "no duplicate");
        assertEquals("jt-b-0230", seen.get(0));
        assertEquals("jt-b-0001", seen.get(229));
    }

    @Test
    void theFirstOfTheBigPagesHasHundredAndALinkWithoutASizeParameter() throws Exception {
        HttpResponse<String> response = get("/v1/conversations?idYapeAccount=jt-acct-big");

        assertEquals(100, conversationIds(json(response)).size());
        String link = response.headers().firstValue("Link").orElseThrow();
        assertTrue(link.startsWith("</v1/conversations?idYapeAccount=jt-acct-big&page[before]="), link);
        assertTrue(link.endsWith(">; rel=\"prev\""), link);
        assertFalse(link.contains("page[size]"), "the default size is not repeated");
    }

    @Test
    void aWellFormedCursorOfAConversationThatDoesNotExistIsJustAPosition() throws Exception {
        HttpResponse<String> response = get("/v1/conversations?idYapeAccount=jt-acct-main&page%5Bbefore%5D=1793527500000000~nothing-like-it&page%5Bsize%5D=100");

        assertEquals(200, response.statusCode());
        assertEquals(List.of("jt-c-4", "jt-c-3", "jt-c-2", "jt-c-1", "jt-c-0"), conversationIds(json(response)));
    }

    @Test
    void aCursorBeyondTheEndsGivesAnEmptyPageWithoutALink() throws Exception {
        HttpResponse<String> before = get("/v1/conversations?idYapeAccount=jt-acct-main&page%5Bbefore%5D=1~a");
        HttpResponse<String> after = get("/v1/conversations?idYapeAccount=jt-acct-main&page%5Bafter%5D=253402300799999999~a");

        assertEquals("{\"conversations\":[]}", before.body());
        assertEquals("{\"conversations\":[]}", after.body());
        assertNull(before.headers().firstValue("Link").orElse(null));
    }

    @Test
    void thePageSizeBoundsAreOneAndHundred() throws Exception {
        assertEquals(1, conversationIds(json(get("/v1/conversations?idYapeAccount=jt-acct-main&page%5Bsize%5D=1"))).size());
        assertEquals(7, conversationIds(json(get("/v1/conversations?idYapeAccount=jt-acct-main&page%5Bsize%5D=100"))).size());
        assertProblem(get("/v1/conversations?idYapeAccount=jt-acct-main&page%5Bsize%5D=0"), 400, TYPE + "invalid-request");
        assertProblem(get("/v1/conversations?idYapeAccount=jt-acct-main&page%5Bsize%5D=101"), 400, TYPE + "invalid-request");
    }

    @Test
    void aRefusedListRequestIsAProblemJsonWithTheRightType() throws Exception {
        assertProblem(get("/v1/conversations"), 400, TYPE + "invalid-request");
        assertProblem(get("/v1/conversations?idYapeAccount=a%20b"), 400, TYPE + "invalid-request");
        assertProblem(get("/v1/conversations?idYapeAccount=a&idYapeAccount=b"), 400, TYPE + "invalid-request");
        assertProblem(get("/v1/conversations?idYapeAccount=a&page%5Bbefore%5D=x"), 400, TYPE + "invalid-cursor");
        assertProblem(get("/v1/conversations?idYapeAccount=a&page%5Bbefore%5D=1~a&page%5Bafter%5D=1~a"), 400, TYPE + "invalid-request");
    }

    @Test
    void aRefusalNeverRepeatsWhatTheClientSent() throws Exception {
        HttpResponse<String> response = get("/v1/conversations?idYapeAccount=%3Cscript%3Ealert(1)%3C/script%3E");

        assertProblem(response, 400, TYPE + "invalid-request");
        assertFalse(response.body().contains("script"), response.body());
    }

    @Test
    void anAccountOfTheMaximumLengthIsAcceptedAndOneLongerIsNot() throws Exception {
        assertEquals(200, get("/v1/conversations?idYapeAccount=" + "a".repeat(128)).statusCode());
        assertProblem(get("/v1/conversations?idYapeAccount=" + "a".repeat(129)), 400, TYPE + "invalid-request");
    }

    @Test
    void aSqlInjectionAttemptInTheAccountIsRefusedAndTheTableStillThere() throws Exception {
        assertProblem(get("/v1/conversations?idYapeAccount=a%27%3B%20DROP%20TABLE%20camel_history.conversation_summaries%3B--"), 400, TYPE + "invalid-request");
        assertEquals(7, conversationIds(json(get("/v1/conversations?idYapeAccount=jt-acct-main"))).size());
    }

    // ---- the messages -----------------------------------------------------------------------------------------------------

    @Test
    void theNewestMessagesComeOldestFirstWithFoundrysTextAndOurMetadata() throws Exception {
        HttpResponse<String> response = get("/v1/conversations/jt-m-main/messages?page%5Bsize%5D=3");
        JsonNode body = json(response);

        assertEquals(200, response.statusCode(), response.body());
        assertEquals("jt-m-main", body.get("conversation").get("_id").asText());
        assertEquals(List.of("23", "24", "25"), messageIds(body));
        JsonNode m = body.get("messages").get(0);
        assertEquals("foundry says 23", m.get("text").asText(), "the text is Foundry's, not the database copy");
        assertEquals("appUser", m.get("role").asText());
        assertEquals("author-23", m.get("authorId").asText());
        assertEquals("text", m.get("type").asText());
        assertEquals(23, m.get("metadata").get("sequence").asInt());
        assertEquals("ev-23", m.get("metadata").get("eventName").asText());
        assertEquals(false, m.get("metadata").get("truncated").asBoolean());
        assertEquals("api", m.get("source").get("type").asText());
        assertFalse(m.get("metadata").has("flow"), "no flow, no field");
        assertEquals("</v1/conversations/jt-m-main/messages?page[before]=23&page[size]=3>; rel=\"prev\"", response.headers().firstValue("Link").orElseThrow());
    }

    @Test
    void aTruncatedMessageAndAFlowShowUpInTheMetadata() throws Exception {
        JsonNode messages = json(get("/v1/conversations/jt-m-main/messages?page%5Bafter%5D=2&page%5Bsize%5D=2")).get("messages");

        assertEquals(List.of("3", "4"), List.of(messages.get(0).get("_id").asText(), messages.get(1).get("_id").asText()));
        assertTrue(messages.get(0).get("metadata").get("truncated").asBoolean());
        assertEquals("flow-x", messages.get(1).get("metadata").get("flow").asText());
    }

    @Test
    void theReceivedTimeKeepsMillisecondsAndDropsTheMicrosecond() throws Exception {
        JsonNode m = json(get("/v1/conversations/jt-m-main/messages?page%5Bafter%5D=1&page%5Bsize%5D=1")).get("messages").get(0);

        assertEquals("2", m.get("_id").asText());
        assertEquals("1793700002", m.get("received").asText(), "10:00:02.000002 UTC on 2026-11-03: the 2 microseconds are cut, not rounded up");
    }

    @Test
    void walkingBackByTenCoversAllTwentyFiveMessagesOnce() throws Exception {
        List<String> all = new ArrayList<>();
        String target = "/v1/conversations/jt-m-main/messages?page%5Bsize%5D=10";
        List<List<String>> pages = new ArrayList<>();
        while (target != null) {
            HttpResponse<String> response = get(target);
            assertEquals(200, response.statusCode(), response.body());
            pages.add(messageIds(json(response)));
            target = next(response);
            assertTrue(pages.size() < 6);
        }

        for (int i = pages.size() - 1; i >= 0; i--) {
            all.addAll(pages.get(i));
        }
        assertEquals(3, pages.size());
        assertEquals(25, new HashSet<>(all).size());
        assertEquals("1", all.get(0));
        assertEquals("25", all.get(24));
        for (int i = 1; i < 25; i++) {
            assertEquals(Integer.toString(i + 1), all.get(i), "no gap, no repeat, in order");
        }
    }

    @Test
    void walkingForwardFromTheFirstCoversTheRestOnce() throws Exception {
        List<String> all = new ArrayList<>(List.of("1"));
        String target = "/v1/conversations/jt-m-main/messages?page%5Bafter%5D=1&page%5Bsize%5D=7";
        while (target != null) {
            HttpResponse<String> response = get(target);
            assertEquals(200, response.statusCode(), response.body());
            all.addAll(messageIds(json(response)));
            target = next(response);
            assertTrue(all.size() < 40);
        }

        assertEquals(25, all.size());
        for (int i = 0; i < 25; i++) {
            assertEquals(Integer.toString(i + 1), all.get(i));
        }
    }

    @Test
    void theFirstMessageHasNothingBeforeIt() throws Exception {
        HttpResponse<String> response = get("/v1/conversations/jt-m-main/messages?page%5Bbefore%5D=1");

        assertEquals(200, response.statusCode());
        assertEquals("{\"conversation\":{\"_id\":\"jt-m-main\"},\"messages\":[]}", response.body());
        assertNull(response.headers().firstValue("Link").orElse(null));
    }

    @Test
    void aWholeConversationFitsInOnePageWithoutALink() throws Exception {
        HttpResponse<String> response = get("/v1/conversations/jt-m-main/messages");

        assertEquals(25, messageIds(json(response)).size());
        assertNull(response.headers().firstValue("Link").orElse(null));
    }

    @Test
    void aConversationThatHasNoMessagesInFoundryIs404() throws Exception {
        assertProblem(get("/v1/conversations/jt-nothing-here/messages"), 404, TYPE + "conversation-not-found");
    }

    @Test
    void aCursorThatIsNotAMessageOfThisConversationIs400() throws Exception {
        assertProblem(get("/v1/conversations/jt-m-main/messages?page%5Bbefore%5D=999"), 400, TYPE + "invalid-cursor");
        assertProblem(get("/v1/conversations/jt-m-main/messages?page%5Bafter%5D=26"), 400, TYPE + "invalid-cursor");
        assertProblem(get("/v1/conversations/jt-m-main/messages?page%5Bafter%5D=abc"), 400, TYPE + "invalid-cursor");
    }

    @Test
    void aCursorOfAnotherConversationIsNotAcceptedHere() throws Exception {
        assertProblem(get("/v1/conversations/jt-m-gap/messages?page%5Bbefore%5D=2"), 400, TYPE + "invalid-cursor");
    }

    @Test
    void anItemFoundryHoldsButTheMapDoesNotKnowIsA500ThatNamesNothing() throws Exception {
        HttpResponse<String> response = get("/v1/conversations/jt-m-gap/messages");

        assertProblem(response, 500, "about:blank");
        assertFalse(response.body().contains("msg_"), "the detail of a 5xx never says what failed");
    }

    @Test
    void textThatIsHardToCarryComesBackExactlyAsFoundryHeldIt() throws Exception {
        String text = "Hola \\\"mundo\\\" \\n\\t 👍🏽 é é שלום 中文 \\\\ <b>&amp;</b>  ";
        foundry.answerWith(ITEMS.formatted("conv_jt-m-text"), request -> pagedItems(request, 1, text, "jt-m-text"));

        HttpResponse<String> response = get("/v1/conversations/jt-m-text/messages");

        assertEquals("Hola \"mundo\" \n\t 👍🏽 é é שלום 中文 \\ <b>&amp;</b>  ",
                json(response).get("messages").get(0).get("text").asText());
    }

    @Test
    void aTenThousandCharacterTextPassesThroughWhole() throws Exception {
        String text = "x".repeat(10_000);
        foundry.answerWith(ITEMS.formatted("conv_jt-m-text"), request -> pagedItems(request, 1, text, "jt-m-text"));

        assertEquals(text, json(get("/v1/conversations/jt-m-text/messages")).get("messages").get(0).get("text").asText());
    }

    // ---- when Foundry or the broker cannot answer -------------------------------------------------------------------------

    private void foundryAnswers(FakeHttp.Answer answer) {
        foundry.answerWith(ITEMS.formatted("conv_jt-m-fail"), request -> answer);
    }

    @Test
    void whateverMakesFoundryUnavailableIs503AndNeverTheStatusFoundryGave() throws Exception {
        for (int status : new int[] {401, 403, 404, 408, 429, 500, 502, 503, 504}) {
            foundryAnswers(FakeHttp.Answer.status(status));

            HttpResponse<String> response = get("/v1/conversations/jt-m-fail/messages");

            assertProblem(response, 503, "about:blank");
            assertEquals("Something went wrong. Try again.", json(response).get("detail").asText(), "the detail says nothing of Foundry (it gave " + status + ")");
        }
    }

    @Test
    void foundryAnsweringGarbageIs503() throws Exception {
        foundryAnswers(FakeHttp.Answer.ok("<html>bad gateway</html>"));

        assertProblem(get("/v1/conversations/jt-m-fail/messages"), 503, "about:blank");
    }

    @Test
    void foundryAnsweringSlowerThanTheTimeoutIs503NotAHang() throws Exception {
        foundryAnswers(new FakeHttp.Answer(200, "{\"data\":[],\"has_more\":false}", 6000));
        long started = System.nanoTime();

        HttpResponse<String> response = get("/v1/conversations/jt-m-fail/messages");

        assertProblem(response, 503, "about:blank");
        assertTrue((System.nanoTime() - started) / 1_000_000 < 5500, "gave up after the 3 s timeout");
    }

    @Test
    void anUnexpectedFoundryStatusIsA500BecauseItIsOurBug() throws Exception {
        foundryAnswers(FakeHttp.Answer.status(400));

        assertProblem(get("/v1/conversations/jt-m-fail/messages"), 500, "about:blank");
    }

    @Test
    void aFoundryThatRecoversIsReadAgainWithoutARestart() throws Exception {
        foundryAnswers(FakeHttp.Answer.status(503));
        assertProblem(get("/v1/conversations/jt-m-fail/messages"), 503, "about:blank");
        foundryAnswers(FakeHttp.Answer.ok("{\"data\":[{\"id\":\"jt-m-fail_msg_001\",\"content\":[{\"type\":\"input_text\",\"text\":\"back\"}]}],\"has_more\":false}"));

        assertEquals("back", json(get("/v1/conversations/jt-m-fail/messages")).get("messages").get(0).get("text").asText());
    }

    @Test
    void theListDoesNotNeedFoundryAtAll() throws Exception {
        foundryAnswers(FakeHttp.Answer.status(503));

        assertEquals(200, get("/v1/conversations?idYapeAccount=jt-acct-main").statusCode());
    }

    // ---- paths, methods and what the HTTP layer does with odd requests ----------------------------------------------------

    @Test
    void aPathTheApiDoesNotHaveIsAProblemJson404() throws Exception {
        for (String path : List.of("/", "/v1", "/V1/conversations", "/v1/conversation", "/v1/conversations/x/messages/extra", "/v1/conversations//messages", "/health/x", "/q/health")) {
            HttpResponse<String> response = get(path);

            assertProblem(response, 404, "about:blank");
        }
    }

    @Test
    void aMethodThePathDoesNotAcceptIsAProblemJson405() throws Exception {
        for (String method : List.of("POST", "PUT", "DELETE", "PATCH", "OPTIONS")) {
            for (String path : List.of("/v1/conversations?idYapeAccount=a", "/v1/conversations/x/messages", "/health")) {
                HttpResponse<String> response = send(method, path);

                assertProblem(response, 405, "about:blank");
            }
        }
    }

    @Test
    void aTrailingSlashIsToleratedWhereTheRouterToleratesIt() throws Exception {
        assertEquals(200, get("/v1/conversations/?idYapeAccount=jt-acct-main").statusCode());
        assertEquals(200, get("/health/").statusCode());
    }

    @Test
    void anEncodedSlashOrSpaceOrNonAsciiInAConversationIdIs400NotA500() throws Exception {
        for (String id : List.of("a%2Fb", "a%20b", "caf%C3%A9", "%F0%9F%91%8D", "..%2F..%2Fetc%2Fpasswd")) {
            assertProblem(get("/v1/conversations/" + id + "/messages"), 400, TYPE + "invalid-request");
        }
    }

    @Test
    void aVeryLongQueryIsAnsweredNotCrashed() throws Exception {
        HttpResponse<String> response = get("/v1/conversations?idYapeAccount=jt-acct-main&junk=" + "y".repeat(6000));

        assertEquals(200, response.statusCode());
    }

    @Test
    void manyRequestsAtOnceAllGetTheSameCorrectAnswer() throws Exception {
        List<CompletableFuture<String>> calls = new ArrayList<>();
        for (int i = 0; i < 40; i++) {
            String path = i % 2 == 0 ? "/v1/conversations?idYapeAccount=jt-acct-main" : "/v1/conversations/jt-m-main/messages?page%5Bsize%5D=2";
            calls.add(CompletableFuture.supplyAsync(() -> {
                try {
                    HttpResponse<String> r = get(path);
                    assertEquals(200, r.statusCode(), r.body());
                    return r.body();
                } catch (Exception e) {
                    throw new RuntimeException(e);
                }
            }));
        }
        Set<String> distinct = new HashSet<>();
        for (CompletableFuture<String> call : calls) {
            distinct.add(call.get().substring(0, 20));
        }

        assertEquals(2, distinct.size(), "two kinds of request, two kinds of answer");
    }

    // ---- what the API must not send back ---------------------------------------------------------------------------------

    @Test
    void theResponseDoesNotEchoTheRequestsHeadersOrItsQueryParameters() throws Exception {
        HttpResponse<String> response = get("/v1/conversations?idYapeAccount=jt-acct-main&foo=bar", "X-Custom", "hello", "X-Api-Key", "k-123");

        assertEquals(200, response.statusCode());
        List<String> names = response.headers().map().keySet().stream().map(String::toLowerCase).toList();
        for (String reflected : List.of("x-custom", "x-api-key", "idyapeaccount", "foo")) {
            assertFalse(names.contains(reflected), reflected + " came back in " + names);
        }
    }

    @Test
    void theErrorAnswerDoesNotEchoThemEither() throws Exception {
        HttpResponse<String> response = get("/v1/conversations?idYapeAccount=a%20b&foo=bar", "X-Custom", "hello");

        assertEquals(400, response.statusCode());
        List<String> names = response.headers().map().keySet().stream().map(String::toLowerCase).toList();
        assertFalse(names.contains("x-custom"), names.toString());
        assertFalse(names.contains("foo"), names.toString());
    }

    @Test
    void aControlCharacterInAnyQueryValueIsAnAnswerNotAnEmptyHttp500() throws Exception {
        for (String path : List.of("/v1/conversations?idYapeAccount=jt-acct-main&zz=a%0Ab", "/v1/conversations?idYapeAccount=a%00",
                "/v1/conversations?idYapeAccount=a%0D%0AX-Injected:1", "/health?x=a%0Ab", "/v1/conversations/jt-m-main/messages?x=a%0Ab")) {
            HttpResponse<String> response = get(path);

            assertTrue(response.statusCode() == 200 || response.statusCode() == 400, path + " answered " + response.statusCode());
            assertFalse(response.headers().firstValue("X-Injected").isPresent());
        }
    }

    @Test
    void aControlCharacterInAParameterNameIsAnAnswerToo() throws Exception {
        HttpResponse<String> response = get("/v1/conversations?idYapeAccount=jt-acct-main&x%0Ay=1");

        assertEquals(200, response.statusCode());
    }
}
