import java.sql.SQLTransientException;

/**
 * The history consumer has not written the message row yet. The two projects read the same topic at the same time, so
 * the sync can be first. The route retries for a while (app.sync.projectionWaitSeconds), then dead-letters the record.
 *
 * It extends SQLTransientException on purpose: the route's onException matches that built-in class by name. SyncStore
 * wraps every other database failure, so this is the only one that reaches that rule.
 */
public class ProjectionPendingException extends SQLTransientException {

    public ProjectionPendingException(String conversationId, int sequence) {
        super("message conversation=" + conversationId + " sequence=" + sequence + " is not in conversation_messages yet");
    }
}
