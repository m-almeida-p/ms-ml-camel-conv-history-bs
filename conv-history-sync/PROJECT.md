# conv-history-sync

Sends every chat message of the conversation history to Microsoft Foundry, once and in order, and keeps the map between
our ids and Foundry's. It reads the same topic as `conv-history-consumer`, with a group of its own, so a Foundry outage
only delays this project. Built slice by slice; this file lists what exists so far.

| File | Holds |
|---|---|
| `ConversationEventDecoder.java`, `PoisonRecordException.java`, `OffsetCommit.java` | Copies of the consumer's beans. `scripts/test-sync.sh` fails if they differ |
| `application.properties` | Settings (`app.*`), dependencies, datasource |
