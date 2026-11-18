import io.vertx.ext.web.RoutingContext;
import org.apache.camel.BindToRegistry;
import org.apache.camel.CamelContext;
import org.apache.camel.CamelContextAware;
import org.apache.camel.StartupListener;
import org.apache.camel.component.platform.http.vertx.VertxPlatformHttpRouter;

/**
 * Answers a path the API does not have, and a method a path does not accept, as RFC 9457 problem details. Camel's own
 * answer is an HTML page for the first and an empty body for the second. The handlers go on the Vert.x router that
 * platform-http uses, once Camel has started.
 */
@BindToRegistry("problemHandlers")
public class ProblemHandlers implements CamelContextAware, StartupListener {
    private CamelContext context;

    @Override
    public CamelContext getCamelContext() {
        return context;
    }

    @Override
    public void setCamelContext(CamelContext camelContext) {
        this.context = camelContext;
        try {
            camelContext.addStartupListener(this);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    @Override
    public void onCamelContextStarted(CamelContext camelContext, boolean alreadyStarted) {
        VertxPlatformHttpRouter router = VertxPlatformHttpRouter.lookup(camelContext);
        router.errorHandler(404, rc -> problem(rc, 404, "Not Found", "There is nothing at this path."));
        router.errorHandler(405, rc -> problem(rc, 405, "Method Not Allowed", "This path does not accept this method."));
    }

    private static void problem(RoutingContext rc, int status, String title, String detail) {
        rc.response()
                .setStatusCode(status)
                .putHeader("Content-Type", "application/problem+json")
                .end("{\"type\":\"about:blank\",\"title\":\"" + title + "\",\"status\":" + status + ",\"detail\":\"" + detail + "\"}");
    }
}
