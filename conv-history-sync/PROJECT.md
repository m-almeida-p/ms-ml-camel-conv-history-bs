# conv-history-sync

Sends every chat message of the conversation history to Microsoft Foundry, **once and in order**, and keeps the map between our
ids and Foundry's. It reads the same topic as `conv-history-consumer` with a group of its own, so a Foundry outage only delays
this project.

Everything below is explained, with diagrams, in [`docs/design-foundry.md`](../docs/design-foundry.md).

## Five routes, read in order

| Route | Steps |
|---|---|
| **1 Receive** | 1.1 Decode, 1.2 Route, 1.3 Commit offset |
| **2 Sync** | 2.1 Read the stored message, 2.2 Look up the item map, 2.3 Repeat?, 2.4 Look up the conversation map, 2.5 New or known conversation, 2.6 Log |
| **3 Dead-letter** | 3.1 Name the reason, 3.2 Write the log, 3.3 Commit |
| **4 Append** | 4.1 Find the last mapped item, 4.2 Find the next messages, 4.3 Add or adopt, 4.4 Rebuild or record, 4.5 Record, 4.6 Note an adoption |
| **5 Rebuild** | 5.1 Log the reason, 5.2 Find the stored messages, 5.3 Build it again in Foundry, 5.4 Replace the maps, 5.5 Log |

Route 1 calls route 2 (step 1.2.2); route 2 calls route 4 (2.5.2); route 4 calls route 5 (4.4.1). A record that cannot be sent goes
to route 3. In the **Topology** tab: `errorRules` are the error rules and `#pgDataSource` is the database.

## Key

- **Numbers** are the same in the Designer, the docs and the logs: `4.3` is step 3 of route 4.
- **(Parentheses)** name the Enterprise Integration Pattern the step implements.
- **Note** says why. **Docs:** at the end of a note points to the section that explains it.

## Files

| File | Holds |
|---|---|
| `route-receive.camel.yaml` | Route 1 |
| `route-sync.camel.yaml` | Route 2, with its SQL |
| `route-append.camel.yaml` | Route 4 |
| `route-rebuild.camel.yaml` | Route 5 |
| `route-error-handling.camel.yaml` | The error rules, and route 3 |
| `FoundryClient.java` | The calls to Foundry: create, add or adopt, rebuild |
| `SyncStore.java` | Reads the stored message, waiting for the history consumer's row |
| `ConversationEventDecoder.java`, `PoisonRecordException.java`, `OffsetCommit.java` | Copies of the consumer's beans; `scripts/test-sync.sh` fails if they differ |
| `FoundryUnavailableException.java`, `FoundryRejectedException.java`, `ProjectionPendingException.java` | The three families of failure, each extending a built-in class |
| `application.properties` | Settings (`app.*`), dependencies, datasource |
