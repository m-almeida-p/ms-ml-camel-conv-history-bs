import java.io.IOException;
import java.io.UncheckedIOException;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import javax.sql.DataSource;
import org.apache.camel.BindToRegistry;
import org.apache.camel.Exchange;

/**
 * Reads the stored chat message the sync is about to send. It is a bean, not an sql step, because the wait for the
 * history consumer is a retry of THIS step: Camel retries the processor that failed, and only a step that queries
 * again can see the row appear.
 */
@BindToRegistry("syncStore")
public class SyncStore {

    /**
     * Puts the role (appUser or appMaker) and the text of the message in the headers "storedRole" and "storedText".
     * Throws ProjectionPendingException while the row is missing.
     */
    public void loadMessage(Exchange exchange) throws Exception {
        String conversationId = exchange.getMessage().getHeader("conversationId", String.class);
        int sequence = exchange.getMessage().getHeader("sequence", Integer.class);
        DataSource dataSource = exchange.getContext().getRegistry().lookupByNameAndType("pgDataSource", DataSource.class);
        try (Connection connection = dataSource.getConnection();
                PreparedStatement statement = connection.prepareStatement(
                        "SELECT role, text FROM conversation_messages WHERE conversation_id = ? AND sequence = ?")) {
            statement.setString(1, conversationId);
            statement.setInt(2, sequence);
            try (ResultSet rows = statement.executeQuery()) {
                if (!rows.next()) {
                    throw new ProjectionPendingException(conversationId, sequence);
                }
                exchange.getMessage().setHeader("storedRole", rows.getString("role"));
                exchange.getMessage().setHeader("storedText", rows.getString("text"));
            }
        } catch (ProjectionPendingException e) {
            throw e;   // the bounded wait of the route, not a database failure
        } catch (SQLException e) {
            // A database that cannot be reached is the route's "dependency down": retried forever.
            throw new UncheckedIOException(new IOException("database failure: " + e.getMessage(), e));
        }
    }
}
