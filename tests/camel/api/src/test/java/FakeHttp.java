import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Function;

/**
 * A real HTTP server on a free local port, for the tests of the classes that call another service (the token broker and
 * Foundry). Each path has an answer that a test can change; every request is kept, so a test can say what was sent.
 */
final class FakeHttp implements AutoCloseable {

    record Answer(int status, String body, long delayMs) {
        static Answer ok(String body) {
            return new Answer(200, body, 0);
        }

        static Answer status(int status) {
            return new Answer(status, "{}", 0);
        }
    }

    record Seen(String path, String query, String authorization) {
    }

    private final HttpServer server;
    private final Map<String, Answer> answers = new ConcurrentHashMap<>();
    private final Map<String, Function<Seen, Answer>> dynamic = new ConcurrentHashMap<>();
    private final Map<String, AtomicInteger> counts = new ConcurrentHashMap<>();
    private final List<Seen> seen = new CopyOnWriteArrayList<>();

    FakeHttp() throws IOException {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/", this::handle);
        server.setExecutor(Executors.newFixedThreadPool(4));
        server.start();
    }

    String url() {
        return "http://127.0.0.1:" + server.getAddress().getPort();
    }

    void answer(String path, Answer answer) {
        answers.put(path, answer);
    }

    /** An answer worked out from the request, for a fake that has to behave (page, order, cursor). */
    void answerWith(String path, Function<Seen, Answer> answer) {
        dynamic.put(path, answer);
    }

    int calls(String path) {
        AtomicInteger n = counts.get(path);
        return n == null ? 0 : n.get();
    }

    List<Seen> requests() {
        return new ArrayList<>(seen);
    }

    private void handle(HttpExchange exchange) throws IOException {
        String path = exchange.getRequestURI().getPath();
        counts.computeIfAbsent(path, k -> new AtomicInteger()).incrementAndGet();
        seen.add(new Seen(path, exchange.getRequestURI().getRawQuery(), exchange.getRequestHeaders().getFirst("Authorization")));
        Seen request = seen.get(seen.size() - 1);
        Function<Seen, Answer> compute = dynamic.get(path);
        Answer answer = compute != null ? compute.apply(request) : answers.getOrDefault(path, Answer.status(404));
        try {
            if (answer.delayMs() > 0) {
                Thread.sleep(answer.delayMs());
            }
            byte[] bytes = answer.body().getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().add("Content-Type", "application/json");
            exchange.sendResponseHeaders(answer.status(), bytes.length == 0 ? -1 : bytes.length);
            if (bytes.length > 0) {
                exchange.getResponseBody().write(bytes);
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        } catch (IOException e) {
            // the client gave up (a timeout test): nothing to do
        } finally {
            exchange.close();
        }
    }

    @Override
    public void close() {
        server.stop(0);
    }
}
