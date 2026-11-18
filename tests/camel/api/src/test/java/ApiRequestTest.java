import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.stream.Stream;
import org.apache.camel.Exchange;
import org.apache.camel.impl.DefaultCamelContext;
import org.apache.camel.support.DefaultExchange;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;

/** Every parameter rule of the contract, with the exact problem each break gives, and what a valid request leaves behind. */
class ApiRequestTest {

    private static final String INVALID_REQUEST = "invalid-request";
    private static final String INVALID_CURSOR = "invalid-cursor";
    private static final String CONVERSATION_CURSOR = "page[before] or page[after] is not a cursor from the conversation list.";
    private static final String MESSAGE_CURSOR = "page[before] or page[after] is not the _id of a message in this conversation.";
    private static final String SIZE = "page[size] must be a whole number from 1 to 100";
    private static final String BOTH = "page[before] and page[after] cannot be used together";

    private final ApiRequest request = new ApiRequest();

    private static Exchange exchange(String query, String conversationId) {
        Exchange exchange = new DefaultExchange(new DefaultCamelContext());
        if (query != null) {
            exchange.getMessage().setHeader(Exchange.HTTP_QUERY, query);
        }
        if (conversationId != null) {
            exchange.getMessage().setHeader("conversationId", conversationId);
        }
        // what platform-http does with a query: copies each parameter into a header, brackets and all
        exchange.getMessage().setHeader("page[before]", "copied-by-the-http-layer");
        exchange.getMessage().setHeader("page[size]", "copied-by-the-http-layer");
        return exchange;
    }

    private static String repeat(char c, int n) {
        return String.valueOf(c).repeat(n);
    }

    private ApiProblemException refusedConversations(String query) {
        return assertThrows(ApiProblemException.class, () -> request.conversations(exchange(query, null)), "query: " + query);
    }

    private ApiProblemException refusedMessages(String conversationId, String query) {
        return assertThrows(ApiProblemException.class, () -> request.messages(exchange(query, conversationId)), "query: " + query);
    }

    private static void assertProblem(ApiProblemException problem, String type, String detail) {
        assertEquals(400, problem.getStatus());
        assertEquals(ApiProblemException.TYPE_BASE + type, problem.getType());
        assertEquals(detail, problem.getDetail());
    }

    // ---- the conversation list ----------------------------------------------------------------------------------------

    static Stream<Arguments> conversationQueriesThatAreFine() {
        return Stream.of(
                Arguments.of("idYapeAccount=a", "newest", 100),
                Arguments.of("idYapeAccount=a&page[size]=1", "newest", 1),
                Arguments.of("idYapeAccount=a&page[size]=100", "newest", 100),
                Arguments.of("idYapeAccount=a&page%5Bsize%5D=7", "newest", 7),
                Arguments.of("page[size]=3&idYapeAccount=a", "newest", 3),
                Arguments.of("idYapeAccount=A.b:c_d-1", "newest", 100),
                Arguments.of("idYapeAccount=" + repeat('a', 128), "newest", 100),
                Arguments.of("idYapeAccount=a&unknown=1&other", "newest", 100),
                Arguments.of("&&idYapeAccount=a&", "newest", 100),
                Arguments.of("idYapeAccount=a&page[before]=1~a", "before", 100),
                Arguments.of("idYapeAccount=a&page[before]=253402300799999999~a", "before", 100),
                Arguments.of("idYapeAccount=a&page[after]=1795028262350036~conv_v1_x", "after", 100),
                Arguments.of("idYapeAccount=a&page%5Bafter%5D=1795028262350036%7Econv_v1_x", "after", 100));
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("conversationQueriesThatAreFine")
    void aValidListRequestLeavesItsParametersAsProperties(String query, String direction, int size) throws Exception {
        Exchange exchange = exchange(query, null);

        request.conversations(exchange);

        assertEquals(direction, exchange.getProperty("direction"));
        assertEquals(size, exchange.getProperty("size"));
        assertEquals(size + 1, exchange.getProperty("limit"), "one more than the page, to know whether more exist");
    }

    @Test
    void theListRequestRemovesEveryPageHeaderBeforeAnythingCanFail() throws Exception {
        Exchange exchange = exchange("idYapeAccount=a", null);

        request.conversations(exchange);

        assertNull(exchange.getMessage().getHeader("page[before]"));
        assertNull(exchange.getMessage().getHeader("page[size]"));
    }

    @Test
    void everyHeaderThatIsNotCamelsGoesWhileCamelsOwnStay() throws Exception {
        Exchange exchange = exchange("idYapeAccount=a", null);
        exchange.getMessage().setHeader("X-Custom", "hello");
        exchange.getMessage().setHeader("idYapeAccount", "a");
        exchange.getMessage().setHeader("Authorization", "Bearer x");
        exchange.getMessage().setHeader("CamelHttpResponseCode", 200);

        request.conversations(exchange);

        assertEquals(java.util.Set.of(Exchange.HTTP_QUERY, "CamelHttpResponseCode"), exchange.getMessage().getHeaders().keySet(),
                "what the HTTP layer would send back is only what Camel itself set");
    }

    @Test
    void theConversationIdHeaderIsReadBeforeTheHeadersGo() throws Exception {
        Exchange exchange = exchange(null, "conv_1");

        request.messages(exchange);

        assertEquals("conv_1", exchange.getProperty("conversationId"));
        assertNull(exchange.getMessage().getHeader("conversationId"));
    }

    @Test
    void aRefusedListRequestHasRemovedThePageHeadersToo() {
        Exchange exchange = exchange("idYapeAccount=", null);

        assertThrows(ApiProblemException.class, () -> request.conversations(exchange));

        assertNull(exchange.getMessage().getHeader("page[before]"), "an error answer built from this exchange must not carry them");
    }

    @Test
    void theListCursorIsSplitIntoItsInstantAndItsConversationId() throws Exception {
        Exchange exchange = exchange("idYapeAccount=a&page[before]=1795028262350036~conv_v1_ab:c.d-e", null);

        request.conversations(exchange);

        assertEquals(1795028262350036L, exchange.getProperty("cursorMicros"));
        assertEquals("conv_v1_ab:c.d-e", exchange.getProperty("cursorId"));
    }

    static Stream<String> accountsThatAreRefused() {
        return Stream.of("idYapeAccount=", "idYapeAccount=a%20b", "idYapeAccount=a+b", "idYapeAccount=a%2Fb", "idYapeAccount=a%00b",
                "idYapeAccount=%E2%9C%93", "idYapeAccount=%F0%9F%91%8D", "idYapeAccount=" + repeat('a', 129), "IdYapeAccount=a",
                "idyapeaccount=a", "page[size]=5", "", "?", "idYapeAccount=a%0Ab", "idYapeAccount=a%3Bb", "idYapeAccount=a%27%3B--");
    }

    @ParameterizedTest(name = "[{0}]")
    @MethodSource("accountsThatAreRefused")
    void anAccountThatIsMissingOrMalformedIsRefused(String query) {
        assertProblem(refusedConversations(query), INVALID_REQUEST, "idYapeAccount is missing or malformed");
    }

    static Stream<Arguments> repeatedListParameters() {
        return Stream.of(
                Arguments.of("idYapeAccount=a&idYapeAccount=b", "idYapeAccount"),
                Arguments.of("idYapeAccount=a&page[size]=1&page[size]=2", "page[size]"),
                Arguments.of("idYapeAccount=a&page[before]=1~a&page[before]=2~b", "page[before]"),
                Arguments.of("idYapeAccount=a&page[after]=1~a&page[after]=2~b", "page[after]"),
                Arguments.of("idYapeAccount=a&page%5Bsize%5D=1&page[size]=2", "page[size]"),
                Arguments.of("idYapeAccount=&idYapeAccount=a", "idYapeAccount"),
                Arguments.of("idYapeAccount=a&page[size]=&page[size]=1", "page[size]"));
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("repeatedListParameters")
    void aParameterSentTwiceIsRefusedEvenWhenTheOtherCopyIsEmpty(String query, String name) {
        assertProblem(refusedConversations(query), INVALID_REQUEST, name + " is given more than once");
    }

    static Stream<String> sizesThatAreRefused() {
        return Stream.of("0", "101", "-1", "+5", "05", "abc", "", "1.5", "1e2", "５", " 5", "5 ", "2147483648",
                "99999999999999999999", "0x10", "1_0", "-0", "00", "٥", "NaN");
    }

    @ParameterizedTest(name = "page[size]=[{0}]")
    @MethodSource("sizesThatAreRefused")
    void aPageSizeThatIsNotAPlainDecimalFromOneToHundredIsRefused(String size) {
        assertProblem(refusedConversations("idYapeAccount=a&page[size]=" + size), INVALID_REQUEST, SIZE);
        assertProblem(refusedMessages("c1", "page[size]=" + size), INVALID_REQUEST, SIZE);
    }

    @Test
    void bothCursorsAreRefusedBeforeEitherIsRead() {
        assertProblem(refusedConversations("idYapeAccount=a&page[before]=garbage&page[after]=garbage"), INVALID_REQUEST, BOTH);
        assertProblem(refusedMessages("c1", "page[before]=garbage&page[after]=garbage"), INVALID_REQUEST, BOTH);
    }

    static Stream<String> listCursorsThatAreRefused() {
        return Stream.of("", "abc", "1795028262350036", "~a", "0~a", "-1~a", "01~a", "+5~a", "253402300800000000~a", "999999999999999999~a",
                "1.5~a", "1~", "1~bad%20id", "1~a~b", "１~a", "1795028262350036~" + repeat('a', 129), "1e15~a", "0x1~a", " 1~a");
    }

    @ParameterizedTest(name = "cursor=[{0}]")
    @MethodSource("listCursorsThatAreRefused")
    void aListCursorThatIsNotTheFormTheApiWritesIsRefused(String cursor) {
        assertProblem(refusedConversations("idYapeAccount=a&page[before]=" + cursor), INVALID_CURSOR, CONVERSATION_CURSOR);
        assertProblem(refusedConversations("idYapeAccount=a&page[after]=" + cursor), INVALID_CURSOR, CONVERSATION_CURSOR);
    }

    // ---- the messages --------------------------------------------------------------------------------------------------

    @ParameterizedTest(name = "query=[{0}]")
    @MethodSource("messageQueriesThatAreFine")
    void aValidMessagesRequestLeavesItsParametersAsProperties(String query, String direction, int size, Integer cursor) throws Exception {
        Exchange exchange = exchange(query, "conv_v1:a.b-c_d");

        request.messages(exchange);

        assertEquals("conv_v1:a.b-c_d", exchange.getProperty("conversationId"));
        assertEquals(direction, exchange.getProperty("direction"));
        assertEquals(size, exchange.getProperty("size"));
        assertEquals(cursor, exchange.getProperty("cursorSequence"));
    }

    static Stream<Arguments> messageQueriesThatAreFine() {
        return Stream.of(
                Arguments.of(null, "newest", 100, null),
                Arguments.of("", "newest", 100, null),
                Arguments.of("page[size]=2", "newest", 2, null),
                Arguments.of("page[before]=1", "before", 100, 1),
                Arguments.of("page[after]=999999999", "after", 100, 999999999),
                Arguments.of("page%5Bbefore%5D=42&page%5Bsize%5D=3", "before", 3, 42),
                Arguments.of("unknown=1&page[after]=7", "after", 100, 7));
    }

    static Stream<String> conversationIdsThatAreRefused() {
        return Stream.of("", "bad id", "a/b", "a%b", "café", "👍", "a\u0000b", repeat('a', 129), "a;b", "a?b", "a#b", "a*b", "a\\b");
    }

    @ParameterizedTest(name = "id=[{0}]")
    @MethodSource("conversationIdsThatAreRefused")
    void aConversationIdOutsideTheAllowedCharactersOrLengthIsRefused(String id) {
        assertProblem(refusedMessages(id, null), INVALID_REQUEST, "the conversation id is malformed");
    }

    @Test
    void aMissingConversationIdIsRefusedToo() {
        assertProblem(refusedMessages(null, null), INVALID_REQUEST, "the conversation id is malformed");
    }

    @Test
    void theLongestAllowedConversationIdIsAccepted() throws Exception {
        Exchange exchange = exchange(null, repeat('a', 128));

        request.messages(exchange);

        assertEquals(repeat('a', 128), exchange.getProperty("conversationId"));
    }

    static Stream<String> messageCursorsThatAreRefused() {
        return Stream.of("", "abc", "0", "05", "+5", "-3", "1.5", "99999999999", "1e3", "１", " 1", "1 ", "0x1", "1_000", "2147483648", "0001");
    }

    @ParameterizedTest(name = "cursor=[{0}]")
    @MethodSource("messageCursorsThatAreRefused")
    void aMessageCursorThatIsNotAPlainDecimalIdIsRefused(String cursor) {
        assertProblem(refusedMessages("c1", "page[before]=" + cursor), INVALID_CURSOR, MESSAGE_CURSOR);
        assertProblem(refusedMessages("c1", "page[after]=" + cursor), INVALID_CURSOR, MESSAGE_CURSOR);
    }

    @Test
    void theLargestNineDigitCursorIsAccepted() throws Exception {
        Exchange exchange = exchange("page[before]=999999999", "c1");

        request.messages(exchange);

        assertEquals(999999999, exchange.getProperty("cursorSequence"));
    }

    @Test
    void aVeryLongQueryStringWithAValidAccountIsStillAnswered() throws Exception {
        Exchange exchange = exchange("idYapeAccount=a&" + "x=".concat(repeat('y', 20_000)), null);

        request.conversations(exchange);

        assertEquals("a", exchange.getProperty("account"));
    }

    @Test
    void aBrokenPercentEscapeDoesNotCrashTheParser() {
        ApiProblemException problem = refusedConversations("idYapeAccount=%zz");

        assertTrue(problem.getDetail().contains("idYapeAccount"));
    }
}
