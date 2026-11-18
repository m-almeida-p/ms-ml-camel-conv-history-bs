import org.apache.camel.Exchange;
import org.apache.camel.ValidationException;

/**
 * Foundry refused the request for good: a 4xx that no retry can change (400, 409, 422...). The route sends the record to
 * the dead-letter log and goes on, so one refused message never blocks a partition.
 *
 * It extends Camel's ValidationException on purpose, like PoisonRecordException: the route's onException matches that
 * built-in class by name. The reason, field and detail are set on the exchange for the dead-letter log.
 */
public class FoundryRejectedException extends ValidationException {

    public FoundryRejectedException(Exchange exchange, int status, String code, String message) {
        super(exchange, "Foundry answered " + status + " " + code + ": " + message);
        exchange.setProperty("dlqReason", "foundry-rejected");
        exchange.setProperty("dlqField", "http-" + status);
        exchange.setProperty("dlqDetail", code + ": " + message);
    }
}
