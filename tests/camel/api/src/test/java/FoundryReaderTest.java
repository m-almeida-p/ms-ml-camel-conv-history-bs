import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.util.List;
import java.util.Map;
import org.apache.camel.Exchange;
import org.apache.camel.impl.DefaultCamelContext;
import org.apache.camel.support.DefaultExchange;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/**
 * FoundryReader against a real HTTP server that plays both the token broker and Foundry: which statuses mean "try later"
 * and which mean "a bug", when a token is asked for again, and what an odd answer does.
 */
class FoundryReaderTest {

    private static final String ITEMS = "/openai/v1/conversations/conv_1/items";

    private FakeHttp http;
    private DefaultCamelContext context;
    private FoundryReader reader;

    private static String broker(String token, String endpoint, long expiresIn) {
        return "{\"accessToken\":\"" + token + "\",\"endpoint\":\"" + endpoint + "\",\"expiresIn\":" + expiresIn + "}";
    }

    @BeforeEach
    void start() throws IOException {
        http = new FakeHttp();
        http.answer("/token", FakeHttp.Answer.ok(broker("tok-1", http.url(), 3600)));
        http.answer(ITEMS, FakeHttp.Answer.ok(items(false, "msg_1", "one")));
        context = contextWith(http.url() + "/token", "", 2000);
        reader = new FoundryReader();
    }

    @AfterEach
    void stop() {
        http.close();
    }

    private static DefaultCamelContext contextWith(String tokenUrl, String endpoint, long timeoutMs) {
        DefaultCamelContext context = new DefaultCamelContext();
        context.getPropertiesComponent().setOverrideProperties(propertiesOf(tokenUrl, endpoint, timeoutMs));
        return context;
    }

    private static java.util.Properties propertiesOf(String tokenUrl, String endpoint, long timeoutMs) {
        java.util.Properties p = new java.util.Properties();
        p.setProperty("app.foundry.tokenUrl", tokenUrl);
        p.setProperty("app.foundry.endpoint", endpoint);
        p.setProperty("app.foundry.timeoutMs", Long.toString(timeoutMs));
        return p;
    }

    private static String items(boolean hasMore, String... idsAndTexts) {
        StringBuilder data = new StringBuilder();
        for (int i = 0; i < idsAndTexts.length; i += 2) {
            data.append(i == 0 ? "" : ",").append("{\"id\":\"").append(idsAndTexts[i]).append("\",\"type\":\"message\",\"content\":[{\"type\":\"input_text\",\"text\":\"")
                    .append(idsAndTexts[i + 1]).append("\"}]}");
        }
        return "{\"data\":[" + data + "],\"has_more\":" + hasMore + "}";
    }

    private Exchange read(String direction, int size, String cursorItem) throws Exception {
        Exchange exchange = new DefaultExchange(context);
        exchange.setProperty("foundryConversationId", "conv_1");
        exchange.setProperty("direction", direction);
        exchange.setProperty("size", size);
        if (cursorItem != null) {
            exchange.setProperty("cursorItemId", cursorItem);
        }
        reader.listItems(exchange);
        return exchange;
    }

    @SuppressWarnings("unchecked")
    private static List<Map<String, String>> itemsOf(Exchange exchange) {
        return exchange.getProperty("foundryItems", List.class);
    }

    private static List<String> idsOf(Exchange exchange) {
        return itemsOf(exchange).stream().map(i -> i.get("id")).toList();
    }

    // ---- what is asked ----------------------------------------------------------------------------------------------------

    @Test
    void theNewestPageIsAskedNewestFirstAndAnswersOldestFirst() throws Exception {
        http.answer(ITEMS, FakeHttp.Answer.ok(items(true, "msg_3", "three", "msg_2", "two")));

        Exchange exchange = read("newest", 2, null);

        assertEquals("order=desc&limit=2", http.requests().get(1).query());
        assertEquals(List.of("msg_2", "msg_3"), idsOf(exchange));
        assertEquals(true, exchange.getProperty("hasMore"));
    }

    @Test
    void theMessagesBeforeACursorAreAskedDescendingWithTheCursorAsAfter() throws Exception {
        read("before", 5, "msg_9");

        assertEquals("order=desc&limit=5&after=msg_9", http.requests().get(1).query());
    }

    @Test
    void theMessagesAfterACursorAreAskedAscendingAndKeepTheirOrder() throws Exception {
        http.answer(ITEMS, FakeHttp.Answer.ok(items(false, "msg_4", "four", "msg_5", "five")));

        Exchange exchange = read("after", 5, "msg_3");

        assertEquals("order=asc&limit=5&after=msg_3", http.requests().get(1).query());
        assertEquals(List.of("msg_4", "msg_5"), idsOf(exchange));
        assertEquals(false, exchange.getProperty("hasMore"));
    }

    @Test
    void theTokenGoesAsABearerAndNothingFromTheRequestIsForwarded() throws Exception {
        Exchange exchange = new DefaultExchange(context);
        exchange.setProperty("foundryConversationId", "conv_1");
        exchange.setProperty("direction", "newest");
        exchange.setProperty("size", 1);
        exchange.getMessage().setHeader("Authorization", "Bearer the-clients-own-token");

        reader.listItems(exchange);

        assertEquals("Bearer tok-1", http.requests().get(1).authorization());
    }

    // ---- what comes back --------------------------------------------------------------------------------------------------

    @Test
    void aStringContentAndAnEmptyOneAndMissingOnesAreAllReadable() throws Exception {
        http.answer(ITEMS, FakeHttp.Answer.ok("{\"data\":[{\"id\":\"a\",\"content\":\"plain text\"},{\"id\":\"b\",\"content\":[]},{\"id\":\"c\"}],\"has_more\":false}"));

        Exchange exchange = read("after", 5, null);

        assertEquals(List.of("plain text", "", ""), itemsOf(exchange).stream().map(i -> i.get("text")).toList());
    }

    @Test
    void theTextIsKeptExactlyAsFoundryGaveItWithUnicodeAndQuotes() throws Exception {
        String tricky = "Hola \\\"mundo\\\" \\n 👍 é \\\\ <b>";
        http.answer(ITEMS, FakeHttp.Answer.ok(items(false, "m", tricky)));

        assertEquals("Hola \"mundo\" \n 👍 é \\ <b>", itemsOf(read("after", 1, null)).get(0).get("text"));
    }

    @Test
    void aMissingDataFieldIsAnEmptyPageAndMissingHasMoreIsFalse() throws Exception {
        http.answer(ITEMS, FakeHttp.Answer.ok("{}"));

        Exchange exchange = read("newest", 5, null);

        assertEquals(0, itemsOf(exchange).size());
        assertEquals(false, exchange.getProperty("hasMore"));
    }

    @Test
    void aBodyThatIsNotJsonIsAnIoFailureSoTheClientGets503NotATrace() {
        http.answer(ITEMS, FakeHttp.Answer.ok("<html>bad gateway</html>"));

        IOException failure = assertThrows(IOException.class, () -> read("newest", 5, null));

        assertTrue(ProblemResponder.dependencyDown(failure));
    }

    // ---- statuses ---------------------------------------------------------------------------------------------------------

    @ParameterizedTest(name = "Foundry answers {0}")
    @ValueSource(ints = {401, 403, 404, 408, 429, 500, 502, 503, 504, 599})
    void aStatusThatALaterTryCanFixIsUnavailable(int status) {
        http.answer(ITEMS, FakeHttp.Answer.status(status));

        FoundryUnavailableException failure = assertThrows(FoundryUnavailableException.class, () -> read("newest", 5, null));

        assertTrue(failure.getMessage().contains(Integer.toString(status)), failure.getMessage());
        assertFalse(failure.getMessage().contains("conv_1?"), "the query is not in the message");
    }

    @ParameterizedTest(name = "Foundry answers {0}")
    @ValueSource(ints = {400, 402, 405, 409, 410, 413, 418, 422, 451})
    void anyOtherClientErrorIsOurBugAndIs500(int status) {
        http.answer(ITEMS, FakeHttp.Answer.status(status));

        IllegalStateException failure = assertThrows(IllegalStateException.class, () -> read("newest", 5, null));

        assertTrue(failure.getMessage().contains(Integer.toString(status)));
        assertFalse(ProblemResponder.dependencyDown(failure));
    }

    @ParameterizedTest(name = "Foundry answers {0}")
    @ValueSource(ints = {200, 201, 203, 206})
    void anyTwoHundredIsAnAnswer(int status) throws Exception {
        http.answer(ITEMS, new FakeHttp.Answer(status, items(false, "m", "t"), 0));

        assertEquals(List.of("m"), idsOf(read("newest", 5, null)));
    }

    @Test
    void aMissingConversationSaysTheSyncWillRebuildIt() {
        http.answer(ITEMS, FakeHttp.Answer.status(404));

        FoundryUnavailableException failure = assertThrows(FoundryUnavailableException.class, () -> read("newest", 5, null));

        assertTrue(failure.getMessage().contains("rebuilds"));
    }

    // ---- the token --------------------------------------------------------------------------------------------------------

    @Test
    void aTokenIsAskedForOnceAndReusedWhileItLives() throws Exception {
        for (int i = 0; i < 5; i++) {
            read("newest", 1, null);
        }

        assertEquals(1, http.calls("/token"));
        assertEquals(5, http.calls(ITEMS));
    }

    @Test
    void a401MakesTheNextCallAskForAFreshToken() throws Exception {
        read("newest", 1, null);
        http.answer(ITEMS, FakeHttp.Answer.status(401));
        assertThrows(FoundryUnavailableException.class, () -> read("newest", 1, null));
        http.answer("/token", FakeHttp.Answer.ok(broker("tok-2", http.url(), 3600)));
        http.answer(ITEMS, FakeHttp.Answer.ok(items(false, "m", "t")));

        read("newest", 1, null);

        assertEquals(2, http.calls("/token"), "the rejected token is dropped, not retried");
        assertEquals("Bearer tok-2", http.requests().get(http.requests().size() - 1).authorization());
    }

    @Test
    void a403DoesNotThrowTheTokenAwayButA401Does() throws Exception {
        read("newest", 1, null);
        http.answer(ITEMS, FakeHttp.Answer.status(403));
        assertThrows(FoundryUnavailableException.class, () -> read("newest", 1, null));
        http.answer(ITEMS, FakeHttp.Answer.ok(items(false, "m", "t")));

        read("newest", 1, null);

        assertEquals(1, http.calls("/token"));
    }

    @Test
    void aTokenWithAnExpiryUnderThirtySecondsIsStillUsedForFiveSeconds() throws Exception {
        http.answer("/token", FakeHttp.Answer.ok(broker("short", http.url(), 10)));

        read("newest", 1, null);
        read("newest", 1, null);

        assertEquals(1, http.calls("/token"), "the early-renewal margin never makes a token useless at once");
    }

    @Test
    void aBrokerThatAnswersWithoutAnExpiryStillGivesAUsableToken() throws Exception {
        http.answer("/token", FakeHttp.Answer.ok("{\"accessToken\":\"t\",\"endpoint\":\"" + http.url() + "\"}"));

        read("newest", 1, null);
        read("newest", 1, null);

        assertEquals(1, http.calls("/token"));
    }

    @ParameterizedTest(name = "the broker answers {0}")
    @ValueSource(ints = {401, 404, 500, 503})
    void aBrokerThatFailsIsUnavailableAndFoundryIsNeverCalled(int status) {
        http.answer("/token", FakeHttp.Answer.status(status));

        FoundryUnavailableException failure = assertThrows(FoundryUnavailableException.class, () -> read("newest", 1, null));

        assertTrue(failure.getMessage().contains("token broker"));
        assertEquals(0, http.calls(ITEMS));
    }

    @Test
    void aBrokerThatReturnsAnEmptyTokenIsUnavailable() {
        http.answer("/token", FakeHttp.Answer.ok(broker("", http.url(), 3600)));

        assertThrows(FoundryUnavailableException.class, () -> read("newest", 1, null));
        assertEquals(0, http.calls(ITEMS));
    }

    @Test
    void aBrokerThatReturnsGarbageIsAnIoFailure() {
        http.answer("/token", FakeHttp.Answer.ok("not json"));

        assertTrue(ProblemResponder.dependencyDown(assertThrows(IOException.class, () -> read("newest", 1, null))));
    }

    @Test
    void aBrokerThatIsNotListeningIsUnavailable() {
        context = contextWith("http://127.0.0.1:1/token", "", 2000);

        FoundryUnavailableException failure = assertThrows(FoundryUnavailableException.class, () -> read("newest", 1, null));

        assertTrue(failure.getMessage().contains("token broker"));
    }

    @Test
    void aBrokerThatNeverAnswersIsUnavailableAfterTheTimeoutNotForever() {
        http.answer("/token", new FakeHttp.Answer(200, broker("t", http.url(), 3600), 5000));
        context = contextWith(http.url() + "/token", "", 300);
        long started = System.nanoTime();

        assertThrows(FoundryUnavailableException.class, () -> read("newest", 1, null));

        assertTrue((System.nanoTime() - started) / 1_000_000 < 3000, "gave up near the 300 ms timeout");
    }

    // ---- the endpoint and the network -------------------------------------------------------------------------------------

    @Test
    void anEndpointWithATrailingSlashWorks() throws Exception {
        http.answer("/token", FakeHttp.Answer.ok(broker("t", http.url() + "/", 3600)));

        assertEquals(List.of("msg_1"), idsOf(read("newest", 1, null)));
    }

    @Test
    void theConfiguredEndpointWinsOverTheBrokersOne() throws Exception {
        http.answer("/token", FakeHttp.Answer.ok(broker("t", "http://127.0.0.1:1", 3600)));
        context = contextWith(http.url() + "/token", http.url(), 2000);

        assertEquals(List.of("msg_1"), idsOf(read("newest", 1, null)));
    }

    @Test
    void noEndpointAnywhereIsUnavailableWithAMessageSayingWhatToSet() {
        http.answer("/token", FakeHttp.Answer.ok(broker("t", "", 3600)));

        FoundryUnavailableException failure = assertThrows(FoundryUnavailableException.class, () -> read("newest", 1, null));

        assertTrue(failure.getMessage().contains("app.foundry.endpoint"));
    }

    @Test
    void foundryNotListeningIsUnavailable() {
        http.answer("/token", FakeHttp.Answer.ok(broker("t", "http://127.0.0.1:1", 3600)));

        assertInstanceOf(FoundryUnavailableException.class, assertThrows(IOException.class, () -> read("newest", 1, null)));
    }

    @Test
    void foundryThatNeverAnswersIsUnavailableAfterTheTimeout() {
        http.answer(ITEMS, new FakeHttp.Answer(200, items(false, "m", "t"), 5000));
        context = contextWith(http.url() + "/token", "", 300);
        long started = System.nanoTime();

        assertThrows(FoundryUnavailableException.class, () -> read("newest", 1, null));

        assertTrue((System.nanoTime() - started) / 1_000_000 < 3000);
    }

    @Test
    void aTimeoutDoesNotLoseTheTokenSoTheNextCallAsksFoundryAgain() throws Exception {
        http.answer(ITEMS, new FakeHttp.Answer(200, items(false, "m", "t"), 5000));
        context = contextWith(http.url() + "/token", "", 300);
        assertThrows(FoundryUnavailableException.class, () -> read("newest", 1, null));
        http.answer(ITEMS, FakeHttp.Answer.ok(items(false, "m", "t")));

        read("newest", 1, null);

        assertEquals(1, http.calls("/token"));
    }

    @Test
    void severalCallsAtOnceAskTheBrokerOnlyOnce() throws Exception {
        Thread[] threads = new Thread[8];
        for (int i = 0; i < threads.length; i++) {
            threads[i] = new Thread(() -> {
                try {
                    read("newest", 1, null);
                } catch (Exception e) {
                    throw new RuntimeException(e);
                }
            });
            threads[i].start();
        }
        for (Thread t : threads) {
            t.join();
        }

        assertEquals(1, http.calls("/token"), "the token is fetched under a lock");
    }

    @Test
    void nothingIsLeftOnTheExchangeWhenTheCallFails() {
        http.answer(ITEMS, FakeHttp.Answer.status(500));
        Exchange exchange = new DefaultExchange(context);
        exchange.setProperty("foundryConversationId", "conv_1");
        exchange.setProperty("direction", "newest");
        exchange.setProperty("size", 1);

        assertThrows(FoundryUnavailableException.class, () -> reader.listItems(exchange));

        assertNull(exchange.getProperty("foundryItems"));
    }
}
