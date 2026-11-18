# conv-history-sync

Sends every chat message of the conversation history to Microsoft Foundry, **once and in order**, and keeps the map between our ids
and Foundry's. It reads the same topic as `conv-history-consumer`, with a group of its own, so a Foundry outage only delays this
project. Diagrams: [design-foundry.md](design-foundry.md). Setting it up: [foundry-setup.md](foundry-setup.md).

## Routes

Five routes, read in order. The numbers are the same in the Designer, in the diagrams and in the logs.

| Route | Step | What it does |
|---|---|---|
| **1 Receive** | 1.1 Decode | The consumer's decoder: schema id, registry schema, contract, projection. A bad record goes to route 3. |
| | 1.2 Route | A tombstone (1.2.1) and an event that is not a chat message (1.2.3) are skipped; a chat message goes to route 2 (1.2.2). |
| | 1.3 Commit | The offset moves only now, so a crash replays the record and every step is safe to repeat. |
| **2 Sync** | 2.1 Read the stored message | `SyncStore.loadMessage`: the role and the text come from `conversation_messages`, not from the event. It waits for the history consumer's row. |
| | 2.2 Look up the item map | A row for `(conversation_id, sequence)` proves the message was sent: the inbox of this project. |
| | 2.3 Repeat | In the map: logged as a repeat, nothing is sent. |
| | 2.4 Look up the conversation map | Is there a Foundry conversation for it? |
| | 2.5 New or known | New: 2.5.1.1 create it in Foundry with the first message and our id in its metadata, 2.5.1.2 save both map rows in one statement. Known: 2.5.2 route 4. |
| | 2.6 Log the message | `Message synced conversation=… sequence=… foundryConversation=… item=…` |
| **3 Dead-letter** | 3.1 to 3.3 | Name the reason, write the log, commit. [The dead-letter log](#the-dead-letter-log). |
| **4 Append** | 4.1 to 4.6 | Look up the last mapped item and the messages that come next, **add or adopt** (one step), rebuild if Foundry is inconsistent, record the items. [Reconciliation](#reconciliation). |
| **5 Rebuild** | 5.1 to 5.5 | Build the conversation again in Foundry. [Rebuilding a conversation](#rebuilding-a-conversation). |

The Foundry calls are made by the bean `FoundryClient`, not by http steps, so the token comes from the broker and not from the
message, no header of the message is sent to Foundry, and each outcome becomes one of the three families of
[Error handling](#error-handling).

## Settings

In `application.properties`; each can be overridden by an environment variable (`app.foundry.timeoutMs` is `APP_FOUNDRY_TIMEOUTMS`).

| Setting | Default | Means |
|---|---|---|
| `app.topic` | `yape.public.conversation_events` | The topic to read |
| `app.kafka.brokers` | `kafka:29092` | Inside the Docker network |
| `app.kafka.groupId` | `ms-ml-camel-conv-history-sync` | **Its own group.** Never the consumer's or the original service's |
| `app.schema.registryUrl`, `allowedIds`, `requireFraming` | as the consumer | The decoder's settings |
| `app.db.url`, `app.db.user` | `camel_history` on `db:5432` | The datasource |
| `app.foundry.tokenUrl` | `http://foundry-token:8099/token` | The broker. Not a secret |
| `app.foundry.endpoint` | empty | Empty: the broker's endpoint, from `.env`. Set it to point at another Foundry, for example the fake |
| `app.foundry.timeoutMs` | `10000` | How long a call to Foundry or the broker may take |
| `app.sync.projectionWaitSeconds` | `60` | How long to wait for the history consumer's row |

## What happens to each kind of record

| Record | What happens | Offset |
|---|---|---|
| A tombstone | Skipped | Moves |
| An event that is not a chat message | Skipped, logged | Moves |
| A chat message of a new conversation | Foundry conversation created with it; both map rows saved | Moves |
| A chat message of a known conversation | Added to it (or adopted, or the conversation rebuilt) | Moves |
| A message already in the item map | Logged as a repeat | Moves |
| A record that breaks the schema or the contract | Dead-letter log (reason of the decoder) | Moves |
| A message whose row the consumer never stored | Waits `projectionWaitSeconds`, then dead-letter log (`projection-missing`) | Moves |
| Foundry or the broker cannot answer, 429, 5xx, 401, 403, 408, a timeout | **Retried in place, forever** | **Does not move** |
| Foundry refuses for good (400, 409, 422…) | Dead-letter log (`foundry-rejected`) | Moves |
| Anything else (a bug) | Retried 3 times, then dead-letter log (`unexpected`) | Moves |

## Error handling

Three families, written as the exceptions that `route-error-handling.camel.yaml` matches:

| Family | Exception | Rule |
|---|---|---|
| Cannot answer, try later | `java.io.IOException` (`FoundryUnavailableException`), and the database's connection failures | Retry in place, forever, the wait doubling from 1 s to 30 s. The partition is held, nothing is skipped. |
| Refused for good | `org.apache.camel.ValidationException` (`PoisonRecordException`, `FoundryRejectedException`) | No retry. Route 3, then the offset moves. |
| The consumer's row is not there yet | `java.sql.SQLTransientException` (`ProjectionPendingException`) | Retry once a second for `projectionWaitSeconds`, then route 3. |
| Anything else | `java.lang.Exception` | The Dead Letter Channel: 3 retries, then route 3. |

Two Camel behaviours decide how this is built, and both cost a failing test to find:

- **A retry repeats only the step that failed.** Not the route. A step that sends something must therefore also look for what
  an earlier try left: that is why step 4.3 reconciles and sends in one step.
- **An `onException` rule inherits the Dead Letter Channel's exponential back-off.** The bounded wait was meant to last 6 seconds
  and lasted a minute, because 1, 2, 4, 8… was inherited. The rule sets `useExponentialBackOff: "false"`.

Project exception classes cannot be named in YAML (they are compiled at start-up), so each extends a built-in class and the rule
names that class.

## The dead-letter log

A record that cannot be sent is written by route 3, as one `ERROR` line on the logger `dlq`, with the body, so it can be replayed:

```
DLQ reason=<reason> field=<field> topic=<topic> partition=<n> offset=<n> key=<key> detail=<text> body=<the record>
```

| Reason | Means |
|---|---|
| `header`, `no-schema-header`, `schema-id`, `schema-violation`, `json`, `field-missing`, `field-malformed`, `field-range`, `payload`, `metadata`, `occurred-at` | The decoder refused it; same reasons as [conv-history-consumer.md](conv-history-consumer.md) |
| `projection-missing` | The history consumer did not store this message in time (field `conversation_messages`) |
| `foundry-rejected` | Foundry refused it with a 4xx; the field is `http-<status>`, the detail the error code and message |
| `unexpected` | A bug: the field is the exception class, the detail its message |

```bash
docker logs conv-history-sync 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep 'DLQ reason='
```

## Reconciliation

Foundry has **no idempotency key** (the `Idempotency-Key` header is ignored). If an add is applied but its answer is lost (a
crash, a timeout), the item is in Foundry with no row in the item map, and sending the message again would store it twice. So
before it sends, step 4.3 does this:

1. List the items after the last mapped one (`order=asc&after=<last item>`). Normally there are none.
2. Compare them, in order, with the stored messages that come next, by role and by text. Each that matches is **adopted**: it is
   recorded in the item map with the message's sequence, and not sent.
3. If the message being handled is among them, it was already in Foundry: nothing is sent. Otherwise it is sent now.

All of it is one bean method, `FoundryClient.addItem`, and one statement that records every item. If the list shows something no
message accounts for, the conversation is rebuilt.

Known limits: the match is by role and text, in order, so two identical messages in a row are told apart only by position; and a
call that times out while Foundry is still working may land after the retry's look, which a reconcile cannot see. The default
timeout (10 s) makes that rare.

## Rebuilding a conversation

Foundry can only append. Three situations cannot be repaired by adding:

| Reason (in the log) | Situation |
|---|---|
| `late-event` | A message arrives with a sequence below the last one synced, so it cannot be put in its place |
| `gone` | Foundry answers 404: it no longer has the conversation |
| `unknown-items` | Foundry holds an item that no stored message accounts for |

Route 5 then deletes the old Foundry conversation (a 404 is fine), creates a new one with the first stored message, adds the rest in
order, and swaps the map rows in one statement (the conversation row is updated, item rows are upserted, any other is removed). It
is one step, so a retry starts over, and the conversation that a failed attempt made is deleted by the next one.

The log says why, at `WARN`: `Rebuilding conversation=… reason=…` and `Conversation rebuilt conversation=… reason=…`.

## What it does not do

- It does not send a message in batches: one item per call. Foundry accepts 20 per request; batches are for later.
- It does not find an orphan, a conversation created whose map row was lost to a crash between the two. The retry makes another. An
  orphan is harmless; `scripts/foundry-cleanup-orphans.sh` finds and deletes them.
- It cannot re-read events the topic no longer holds: retention removed the old ones. The messages of those conversations exist
  only if `camel_history` has them.

## Test it

```bash
./scripts/test-sync.sh                  # 120 checks: receive, first, order, wait, reconcile, rebuild, edge, errors, broker, crash
./scripts/test-sync.sh reconcile        # one section
FOUNDRY_MODE=real ./scripts/test-sync.sh first order rebuild    # the same on the real Foundry
./scripts/check-foundry-sync.sh         # Foundry against camel_history, item by item (read-only)
```

The test starts the project on a throwaway topic and group, against the fake Foundry, and removes everything it creates.
