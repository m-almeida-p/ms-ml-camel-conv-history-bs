# Design: the Foundry sync and the API

How the history reaches Microsoft Foundry and is served from it, from the big picture down to the steps. It builds on
[design.md](design.md): the **vocabulary and legend there apply here**, with the additions below. Each diagram shows **one
level of detail**, and the numbers and names are the same in every diagram, in the Karavan Designer and in the logs.
Behaviour in words: [conv-history-sync.md](conv-history-sync.md) and [conv-history-api.md](conv-history-api.md). Setting it up:
[foundry-setup.md](foundry-setup.md).

New here? Read Level 1, then "The life of a message". Debugging? Level 2 and the troubleshooting guide. Changing it? Level 3
and the reading map.

## Vocabulary (added)

| Word | Means |
|---|---|
| **chat message** | An event that is a message of the conversation: `UserMessageSent`, `AgentMessageSent` or `GuardrailResponseSent`. The other events are skipped. |
| **item** | A message as Microsoft Foundry stores it: a role and a text, in a Foundry conversation. It has no time and no metadata. |
| **map** | The two tables that tie our ids to Foundry's: `foundry_conversation_map` and `foundry_item_map`. The second is also the sync's inbox. |
| **sync** | Sending each chat message to Foundry once, in order. |
| **reconcile / adopt** | Looking in Foundry for an item that an earlier, lost call kept, and recording it instead of sending it again. |
| **rebuild** | Deleting a conversation in Foundry and creating it again from the stored messages. |
| **orphan** | A Foundry conversation of ours that no map row names. Harmless; `foundry-cleanup-orphans.sh` removes it. |
| **broker** | `foundry-token`: the service that gives the projects a Foundry token, so no secret goes in a project file. |

---

## Level 1: context

```mermaid
flowchart LR
    producer(["Agent and Debezium<br/>publish conversation events"])
    topic(["Kafka topic<br/>yape.public.conversation_events"])
    consumer["History consumer<br/>conv-history-consumer"]
    sync["Foundry sync<br/>conv-history-sync"]
    db[("Postgres, schema camel_history<br/>messages, summaries, id maps")]
    foundry(["Microsoft Foundry<br/>Conversations API"])
    api["History API<br/>conv-history-api"]
    client(["A client<br/>same API as ms-ml-conv-history-bs"])

    producer -- "1 publishes records" --> topic
    topic -- "2 delivers records" --> consumer
    topic -- "2 delivers the same records" --> sync
    consumer -- "3 writes messages and summaries" --> db
    sync -- "4 reads the stored message" --> db
    sync -- "5 sends it to Foundry" --> foundry
    sync -- "6 records the item map" --> db
    client -- "7 asks for a list or a page" --> api
    api -- "8 reads the text and its order" --> foundry
    api -- "9 reads the list, the times, the metadata" --> db
```

*In words:* the topic is the outbox of the event store; each consumer group receives every record, so the history consumer and
the sync read it independently, and a Foundry outage only delays the sync. The consumer writes the stored messages; the sync
sends each chat message to Foundry and records which Foundry item holds it. The API serves the **text and the order from
Foundry** and everything Foundry does not keep (the time, the author, the event, the flow) from Postgres. The list of
conversations of an account comes from Postgres, because Foundry cannot list by account.

---

## Level 2: containers

```mermaid
flowchart LR
    karavan["karavan<br/>designer and API, port 9998"]
    sync["conv-history-sync<br/>DevMode container, port 8084"]
    api["conv-history-api<br/>DevMode container, port 8086"]
    broker["foundry-token<br/>the broker, port 8099, not published"]
    env[/".env<br/>FOUNDRY_* variables"/]
    kafka(["yape-kafka<br/>kafka:29092"])
    pg[("yape-postgres<br/>db:5432")]
    entra(["Microsoft Entra ID<br/>issues the token"])
    foundry(["Microsoft Foundry"])

    karavan -- "1 Run: creates the container" --> sync
    karavan -- "1 Run: creates the container" --> api
    env -- "2 read once at start" --> broker
    broker -- "3 asks for a token" --> entra
    sync -- "4 asks for token and endpoint" --> broker
    api -- "4 asks for token and endpoint" --> broker
    kafka -- "5 delivers records" --> sync
    sync -- "6 writes the maps" --> pg
    api -- "7 reads" --> pg
    sync -- "8 calls, with the token" --> foundry
    api -- "8 calls, with the token" --> foundry
```

*In words:* Karavan runs the two projects as containers on the network `yape-local`. A container Karavan starts cannot
receive a secret without it landing in Git, so the secret stays in `.env`, and the broker, a compose service, trades it with
Entra ID for a token that the projects ask for over the network. The broker also tells them the Foundry endpoint.

---

## Level 2: the routes of the sync

```mermaid
flowchart LR
    topic(["Topic"])
    r11["1.1 Decode (Message Translator)"]
    r12{"1.2 Route (Content-Based Router)"}
    r2["2 Sync"]
    r4["4 Append"]
    r5["5 Rebuild"]
    r13["1.3 Commit (at-least-once)"]
    r3["3 Dead-letter"]

    topic -- "record" --> r11
    r11 -- "valid record" --> r12
    r12 -- "tombstone or not a chat message" --> r13
    r12 -- "chat message" --> r2
    r2 -- "conversation already in Foundry" --> r4
    r4 -- "needs a rebuild" --> r5
    r2 -- "synced or repeat" --> r13
    r4 -- "recorded" --> r13
    r5 -- "rebuilt" --> r13
    r11 -. "poison record" .-> r3
    r2 -. "refused or not stored in time" .-> r3
    r4 -. "refused" .-> r3
    r5 -. "refused" .-> r3
```

*In words:* route 1 decodes a record with the same decoder as the consumer. A chat message goes to route 2, which creates the
Foundry conversation (first message) or hands over to route 4 (the conversation exists). Route 4 reconciles and sends; if
Foundry cannot be repaired by adding, it calls route 5, which builds the conversation again. Then the offset is committed. A
record that can never be sent goes to route 3 (dashed). A Foundry that cannot answer is not a failure path: the step is retried
in place, forever, and the offset does not move.

| Route | File | Called by |
|---|---|---|
| **1 Receive** | `route-receive.camel.yaml` | the topic |
| **2 Sync** | `route-sync.camel.yaml` | step 1.2.2, as `direct:sync` |
| **3 Dead-letter** | `route-error-handling.camel.yaml` | the error rules, as `direct:deadLetter` |
| **4 Append** | `route-append.camel.yaml` | step 2.5.2, as `direct:append` |
| **5 Rebuild** | `route-rebuild.camel.yaml` | step 4.4.1, as `direct:rebuild` |

---

## Level 3: the steps of the sync

### Route 2: one chat message to Foundry, once

```mermaid
flowchart TB
    s21["2.1 Read the stored message<br/>waits for the history consumer's row"]
    s22["2.2 Look up the item map"]
    s23{"2.3 Repeat (Idempotent Consumer)"}
    dup["2.3.1 Log the repeat"]
    s24["2.4 Look up the conversation map"]
    s25{"2.5 New or known conversation"}
    s2511["2.5.1.1 Create it in Foundry<br/>with the first message"]
    s2512["2.5.1.2 Save both maps<br/>one statement"]
    s252["2.5.2 Append (route 4)"]
    s26["2.6 Log the message"]

    s21 --> s22 --> s23
    s23 -- "in the map" --> dup --> s26
    s23 -- "not yet" --> s24 --> s25
    s25 -- "no conversation yet" --> s2511 --> s2512 --> s26
    s25 -- "conversation exists" --> s252 --> s26
```

*In words:* the text and the role come from the stored row, so Foundry holds the very text our table holds. A message already in
the item map is a repeat and sends nothing. The first message of a conversation creates the Foundry conversation, with our
conversation id in its metadata, and saves both map rows in one statement.

### Route 4: add to a conversation Foundry already has

```mermaid
flowchart TB
    s41["4.1 Find the last mapped item"]
    s42["4.2 Find the next messages"]
    s43["4.3 Add or adopt the item<br/>one step"]
    s44{"4.4 Rebuild or record"}
    s441["4.4.1 Rebuild (route 5)"]
    s45["4.5 Record the items<br/>one statement"]
    s46["4.6 Note an adoption"]

    s41 --> s42 --> s43 --> s44
    s44 -- "a late message, a lost conversation, an unknown item" --> s441
    s44 -- "consistent" --> s45 --> s46
```

*In words:* step 4.3 lists the items after the last mapped one and compares them, in order, with the stored messages that
come next. Those that match are **adopted**: an earlier call that was applied but whose answer was lost left them in Foundry.
If the message being handled is not among them, it is sent. Looking and sending are **one step**, because Camel retries only
the step that failed. See [Reconciliation](conv-history-sync.md#reconciliation).

### Route 5: build a conversation again

```mermaid
flowchart TB
    s51["5.1 Log the reason"]
    s52["5.2 Find the stored messages"]
    s53["5.3 Build it again in Foundry<br/>create, add in order"]
    s54["5.4 Replace the maps<br/>one statement"]
    s55["5.5 Delete the old one"]
    s56["5.6 Log the rebuild"]
    s51 --> s52 --> s53 --> s54 --> s55 --> s56
```

*In words:* Foundry only appends. A message below the last synced sequence, a conversation Foundry no longer has, or an item
nobody can account for cannot be repaired by adding, so the conversation is created again in Foundry from the
stored messages, in order, and the old one is deleted once the maps point at the new one. See [Rebuilding a conversation](conv-history-sync.md#rebuilding-a-conversation).

---

## Level 2: the routes of the API

```mermaid
flowchart LR
    client(["A client"])
    health["Health<br/>GET /health"]
    list["Conversations<br/>GET /v1/conversations"]
    messages["Messages<br/>GET /v1/conversations/{id}/messages"]
    rules["apiErrors<br/>the error rules"]
    pg[("Postgres")]
    foundry(["Foundry"])

    client -- "1 asks" --> health
    client -- "1 asks" --> list
    client -- "1 asks" --> messages
    health -- "2 SELECT 1" --> pg
    list -- "2 reads" --> pg
    messages -- "2 finds the Foundry conversation" --> pg
    messages -- "3 reads the page" --> foundry
    messages -- "4 reads time and metadata" --> pg
    list -. "a refusal or a failure" .-> rules
    messages -. "a refusal or a failure" .-> rules
```

*In words:* each endpoint is a REST verb and the route behind it, together in one `endpoint-*.camel.yaml` file. The list reads
Postgres only. The messages read the page from Foundry, then the time and metadata from Postgres. Any refusal or failure goes to
the error rules, which always answer `application/problem+json`: a refusal is a 4xx, a dependency that cannot answer is a 503, a
bug is a 500.

---

## Level 3: the steps of the API

### Messages: one page of a conversation

```mermaid
flowchart TB
    s11["1.1 Read and check the request"]
    s12["1.2 Find it in Foundry"]
    s13{"1.3 Is it there?"}
    nf["1.3.1 No chat messages (404)"]
    s14{"1.4 Is there a cursor?"}
    s141["1.4.1 Find the cursor's item"]
    s142{"1.4.2 Is it a message here?"}
    bad["1.4.2.1 Invalid cursor (400)"]
    s15["1.5 Read the page from Foundry"]
    s16["1.6 Build the answer"]

    s11 --> s12 --> s13
    s13 -- "not in Foundry" --> nf
    s13 -- "in Foundry" --> s14
    s14 -- "a cursor was sent" --> s141 --> s142
    s142 -- "no" --> bad
    s142 -- "yes" --> s15
    s14 -- "none" --> s15
    s15 --> s16
```

*In words:* the cursor of a page is the `_id` of a message, which is its sequence; Foundry pages by its own item ids, so step 1.4.1
translates one into the other through the item map. The newest page and the page before a cursor read Foundry in descending order
and turn the result round; the page after a cursor reads ascending.

---

## The life of a message

```mermaid
sequenceDiagram
    participant A as Agent
    participant T as Topic
    participant C as History consumer
    participant S as Sync
    participant P as Postgres
    participant F as Foundry
    participant API as API

    A->>T: 1 an event (Debezium publishes it)
    T->>C: 2 the record
    C->>P: 3 writes the message and the summary
    T->>S: 2 the same record
    S->>P: 4 reads the stored message
    S->>F: 5 adds the item, or creates the conversation
    S->>P: 6 records the item map
    S->>T: 7 commits the offset
    API->>P: 8 maps the conversation
    API->>F: 9 reads the page, text and order
    API->>P: 10 reads the time and metadata
```

*In words:* the two consumers read the record at the same time, so the sync waits for the consumer's row before it sends (step
4), a bounded wait. The offset is committed last, so a crash replays the record and every step is safe to repeat.

---

## Reading map

| To understand | Read | Then |
|---|---|---|
| What a chat message is and which ones are sent | Route 1, step 1.2 | the decoder, shared with the consumer |
| Why the sync waits for the consumer | Route 2, step 2.1 | `SyncStore.java` |
| What "once" means with no idempotency key | Route 4, step 4.3 | [Reconciliation](conv-history-sync.md#reconciliation) |
| What a retry repeats | [Error handling](conv-history-sync.md#error-handling) | `route-error-handling.camel.yaml` |
| How a page of messages is built | API route Messages | `MessagePage.java`, `FoundryReader.java` |
| How a cursor works | [The messages](conv-history-api.md#the-messages) | [The conversation list](conv-history-api.md#the-conversation-list) |
| Where a secret lives | [foundry-setup.md](foundry-setup.md) | `scripts/foundry-token-broker/server.py` |

## Pattern map

| Pattern | Where |
|---|---|
| Publish-Subscribe Channel | The topic: the consumer and the sync each get every record |
| Event-Driven Consumer | Route 1, the topic endpoint |
| Message Translator | Step 1.1, the decoder |
| Content-Based Router | The sync's steps 1.2, 2.5 and 4.4; the API's list step 1.2 (the direction), and the messages' steps 1.3 and 1.4 |
| Idempotent Consumer | Step 2.3, with `foundry_item_map` as its inbox |
| Guaranteed Delivery | Step 1.3: the offset moves after the work (at-least-once) |
| Invalid Message Channel / Dead Letter Channel | Route 3 |
| Message Filter | Step 1.2: events that are not chat messages are skipped |
| Pagination with cursors | The list and the messages, with the Link header |
| Compensation | Route 5: build the conversation again when it cannot be repaired |

## Conventions followed

- One `endpoint-*.camel.yaml` file per endpoint, with its `rest` verb and its route together, and the REST verb's `to` a plain
  string: Karavan's Designer opens a file as an integration only when it holds a route, and its REST tab renders only that form.
- Everything else in canonical YAML: `uri: direct` with `parameters`, expressions as `expression: {simple: {expression: ...}}`.
- Project classes are beans (`@BindToRegistry`); the exceptions extend built-in Camel or JDK classes, because a compiled project
  class cannot be named in YAML.
- Settings are `app.*` in `application.properties`, overridable by environment variables; no secret and no Azure resource name
  in a project file.
- Every route and step has a number, a short label (32 characters at most: the Designer draws 32, then `...`) and, when it needs one, a note ending in `Docs:`.
