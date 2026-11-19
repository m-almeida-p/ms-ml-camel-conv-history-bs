import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.sql.SQLException;
import java.sql.SQLNonTransientConnectionException;
import java.sql.SQLRecoverableException;
import java.sql.SQLTransientConnectionException;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.junit.jupiter.api.Test;

/** Which database errors are "try again" (the database cannot be reached) and which are a bug (the statement is wrong). */
class MessagePageTest {

    @ParameterizedTest(name = "SQLSTATE {0} is worth retrying")
    @ValueSource(strings = {"08000", "08001", "08006", "53300", "53200", "57P01", "57P03"})
    void aConnectionOrResourceOrRestartStateIsRetried(String state) {
        assertTrue(MessagePage.connectionProblem(new SQLException("x", state)));
    }

    @ParameterizedTest(name = "SQLSTATE {0} is a bug")
    @ValueSource(strings = {"42P01", "42703", "42601", "42501", "22021", "22P05", "23505", "23503", "40001", "XX000"})
    void aWrongStatementAMissingTableOrRefusedDataIsNotRetried(String state) {
        assertFalse(MessagePage.connectionProblem(new SQLException("x", state)));
    }

    @Test
    void theDriversConnectionExceptionsAreRetriedWhateverTheirState() {
        assertTrue(MessagePage.connectionProblem(new SQLTransientConnectionException("timeout")));
        assertTrue(MessagePage.connectionProblem(new SQLNonTransientConnectionException("closed")));
        assertTrue(MessagePage.connectionProblem(new SQLRecoverableException("gone")));
    }

    @Test
    void anErrorWithNoStateIsNotRetried() {
        assertFalse(MessagePage.connectionProblem(new SQLException("something")));
    }
}
