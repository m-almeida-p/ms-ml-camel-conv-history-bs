import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;
import org.apache.camel.BindToRegistry;
import org.apache.camel.Exchange;

/**
 * Reads and checks the parameters of a request, as the contract says, and leaves the result in exchange properties.
 *
 * The query is read from the raw query string, not from the headers Camel makes of it: that shows a parameter sent
 * twice, and an empty one, as they were sent. The headers called page[before], page[after] and page[size] are removed
 * at once, because a header name with square brackets makes the HTTP layer fail the response, an error answer included.
 *
 * Properties set: direction (newest, before or after), size and limit (size + 1, to know whether more exist), plus
 *   conversations: account, cursorMicros, cursorId        messages: conversationId, cursorSequence
 */
@BindToRegistry("apiRequest")
public class ApiRequest {

    private static final Pattern IDENTIFIER = Pattern.compile("^[A-Za-z0-9._:-]{1,128}$");
    private static final Pattern WHOLE_NUMBER = Pattern.compile("^(0|[1-9][0-9]{0,8})$");
    private static final Pattern MICROS = Pattern.compile("^[1-9][0-9]{0,17}$");
    private static final Pattern DECIMAL_ID = Pattern.compile("^[1-9][0-9]{0,8}$");
    private static final long MAX_CURSOR_MICROS = 253402300799999999L;
    private static final int MAX_SIZE = 100;

    /** GET /v1/conversations?idYapeAccount=&page[before]=&page[after]=&page[size]= */
    public void conversations(Exchange exchange) throws ApiProblemException {
        Map<String, List<String>> query = takeQuery(exchange);
        String account = once(exchange, query, "idYapeAccount");
        String before = once(exchange, query, "page[before]");
        String after = once(exchange, query, "page[after]");
        String size = once(exchange, query, "page[size]");

        if (account == null || !IDENTIFIER.matcher(account).matches()) {
            throw ApiProblemException.invalidRequest(exchange, "idYapeAccount is missing or malformed");
        }
        int pageSize = pageSize(exchange, size);
        String cursor = oneCursor(exchange, before, after);
        exchange.setProperty("account", account);
        exchange.setProperty("size", pageSize);
        exchange.setProperty("limit", pageSize + 1);
        exchange.setProperty("direction", direction(before, after));
        if (cursor != null) {
            // the cursor this API issues: the instant in Unix microseconds, a "~", the conversation id
            String[] parts = cursor.split("~", 2);
            long micros = parts.length == 2 && MICROS.matcher(parts[0]).matches() ? parseMicros(parts[0]) : -1;
            if (parts.length != 2 || micros < 1 || micros > MAX_CURSOR_MICROS || !IDENTIFIER.matcher(parts[1]).matches()) {
                throw ApiProblemException.invalidCursor(exchange, "page[before] or page[after] is not a cursor from the conversation list.");
            }
            exchange.setProperty("cursorMicros", micros);
            exchange.setProperty("cursorId", parts[1]);
        }
    }

    /** GET /v1/conversations/{conversationId}/messages?page[before]=&page[after]=&page[size]= */
    public void messages(Exchange exchange) throws ApiProblemException {
        Map<String, List<String>> query = takeQuery(exchange);
        String before = once(exchange, query, "page[before]");
        String after = once(exchange, query, "page[after]");
        String size = once(exchange, query, "page[size]");

        String conversationId = exchange.getMessage().getHeader("conversationId", String.class);
        if (conversationId == null || !IDENTIFIER.matcher(conversationId).matches()) {
            throw ApiProblemException.invalidRequest(exchange, "the conversation id is malformed");
        }
        int pageSize = pageSize(exchange, size);
        String cursor = oneCursor(exchange, before, after);
        exchange.setProperty("conversationId", conversationId);
        exchange.setProperty("size", pageSize);
        exchange.setProperty("limit", pageSize + 1);
        exchange.setProperty("direction", direction(before, after));
        if (cursor != null) {
            if (!DECIMAL_ID.matcher(cursor).matches()) {
                throw ApiProblemException.invalidCursor(exchange, "page[before] or page[after] is not the _id of a message in this conversation.");
            }
            exchange.setProperty("cursorSequence", Integer.parseInt(cursor));
        }
    }

    // ---- helpers ----------------------------------------------------------------------------------------------------

    private static long parseMicros(String digits) {
        try {
            return Long.parseLong(digits);
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    /** The query as sent: every value of every name, decoded. Removes the page[...] headers. */
    private static Map<String, List<String>> takeQuery(Exchange exchange) {
        String raw = exchange.getMessage().getHeader(Exchange.HTTP_QUERY, String.class);
        Map<String, List<String>> query = new LinkedHashMap<>();
        if (raw != null && !raw.isEmpty()) {
            for (String pair : raw.split("&")) {
                if (pair.isEmpty()) {
                    continue;
                }
                int eq = pair.indexOf('=');
                String name = decode(eq < 0 ? pair : pair.substring(0, eq));
                String value = eq < 0 ? "" : decode(pair.substring(eq + 1));
                query.computeIfAbsent(name, k -> new ArrayList<>()).add(value);
            }
        }
        exchange.getMessage().removeHeaders("page*");
        return query;
    }

    private static String decode(String s) {
        try {
            return URLDecoder.decode(s, StandardCharsets.UTF_8);
        } catch (IllegalArgumentException e) {
            return s;
        }
    }

    /** The one value of a parameter: null when absent, "" when present and empty, an error when sent twice. */
    private static String once(Exchange exchange, Map<String, List<String>> query, String name) throws ApiProblemException {
        List<String> values = query.get(name);
        if (values == null) {
            return null;
        }
        if (values.size() > 1) {
            throw ApiProblemException.invalidRequest(exchange, name + " is given more than once");
        }
        return values.get(0);
    }

    private static int pageSize(Exchange exchange, String raw) throws ApiProblemException {
        if (raw == null) {
            return MAX_SIZE;
        }
        if (WHOLE_NUMBER.matcher(raw).matches()) {
            int size = Integer.parseInt(raw);
            if (size >= 1 && size <= MAX_SIZE) {
                return size;
            }
        }
        throw ApiProblemException.invalidRequest(exchange, "page[size] must be a whole number from 1 to " + MAX_SIZE);
    }

    /** The cursor of page[before] or page[after]; they cannot be used together. */
    private static String oneCursor(Exchange exchange, String before, String after) throws ApiProblemException {
        if (before != null && after != null) {
            throw ApiProblemException.invalidRequest(exchange, "page[before] and page[after] cannot be used together");
        }
        return before != null ? before : after;
    }

    private static String direction(String before, String after) {
        return before != null ? "before" : after != null ? "after" : "newest";
    }
}
