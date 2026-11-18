# conv-history-consumer

A Camel Kafka consumer, built in Karavan, that **builds the conversation history** from the events topic: the
same three tables, with the same rules, as the reference service
[`ms-ml-conv-history-bs`](../../ms-ml-conv-history-bs). It also enforces the Kafka schema and writes every
poison message to a dead-letter log.

Project folder: [`conv-history-consumer/`](../conv-history-consumer)

## What it does

```
Kafka  yape.public.conversation_events          (Debezium: Schema Registry header + JSON, schema id 2)
  │
  ▼  routeReceive
  1. schema id allowed?  ──no──► DLQ
  2. valid against the registry's JSON Schema for that id?  ──no──► DLQ
  3. valid against our contract (required fields, ranges, patterns)?  ──no──► DLQ
  4. project: is it a chat message? text? author?
  5. ONE SQL statement, ONE transaction ─► camel_history.conversation_inbox
                                         ─► camel_history.conversation_messages   (chat events only)
                                         ─► camel_history.conversation_summaries  (a new message with an account)
  6. commit the offset (only now)
  ✗ database down / registry down ─► retry forever, offset not committed
  ✗ anything unexpected ─► 3 retries, then DLQ as reason=unexpected
```

The tables live in the schema **`camel_history`** of the cluster's Postgres, apart from the original consumer's
`public.conversation_*` tables, so both can run and be compared. Their DDL is the migration folder
`history/camel_conversation` of `ml-genai-agents-bs-testing`
(`make migrations/up SERVICE=history FLOW=camel_conversation`).

## Project files

| File | Role |
|---|---|
| `route-receive.camel.yaml` | The consumer route: Kafka → decode → store → commit. Karavan draws it. |
| `route-poison-handling.camel.yaml` | The error rules and the dead-letter route (`direct:dlq`). |
| `ConversationEventDecoder.java` | Schema id check, registry schema validation, contract, projection. |
| `StoreOutcome.java` | Reads the store statement's result: `stored`, `duplicate`, or a conflict. |
| `OffsetCommit.java` | Commits the offset by hand (auto commit is off). |
| `PoisonRecordException.java` | The exception for a record that can never be stored. |
| `application.properties` | Camel settings, dependencies, the datasource and the `app.*` settings. |

The three helpers are Java files because decoding bytes and validating JSON is clearer in code than in YAML. Each
registers itself with `@BindToRegistry`, so the route refers to them by name (`decoder`, `storeOutcome`,
`offsetCommit`).

## Settings

In `application.properties`. Any `app.*` value can be overridden by an environment variable (`app.topic` →
`APP_TOPIC`), which is how the local runner and the tests use a throwaway topic.

| Setting | Default | Meaning |
|---|---|---|
| `app.topic` | `yape.public.conversation_events` | Topic to read. |
| `app.kafka.brokers` | `kafka:29092` | The cluster's internal listener (from the host: `localhost:9092`). |
| `app.kafka.groupId` | `ms-ml-camel-conv-history-bs` | Different from the original's group, so they never compete. |
| `app.schema.registryUrl` | `http://schema-registry:8081` | Where schemas are read. |
| `app.schema.allowedIds` | `2` | Schema ids accepted, comma separated. |
| `app.schema.requireFraming` | `true` | `false` also accepts plain JSON, as the original does. |
| `app.db.url` / `app.db.user` | `jdbc:postgresql://db:5432/postgres?currentSchema=camel_history` / `postgres` | Target. The cluster trusts local connections: no password. |

## Schema assurance

Four layers, in this order. A record that fails any of them is dead-lettered with the reason shown.

| # | Layer | Catches | Reason |
|---|---|---|---|
| 1 | Wire format: the record starts with the Schema Registry header (zero byte + 4-byte schema id), and the id is in `app.schema.allowedIds` | A record not written through the registry; a producer moving to a new schema version without anyone approving it | `no-schema-header`, `header`, `schema-id` |
| 2 | The JSON Schema the registry holds **for that id** | A wrong type, such as `sequence` sent as a string | `schema-violation` |
| 3 | Our own contract (below) | Everything the registered schema does not say: it has no `required` list, so it alone would accept a record with no `conversation_id` | `json`, `field-missing`, `field-malformed`, `field-range`, `payload`, `metadata`, `occurred-at` |
| 4 | The database itself: `CHECK` and `NOT NULL` constraints | The last line of defence | `store-rejected` |

**A new schema version gets a new id.** Its records are refused (dead-lettered) until the id is added to
`app.schema.allowedIds` on purpose. This is the guard against silent drift: the subject's compatibility is `NONE`,
so the registry itself would let anything change.

Schemas are fetched once per id and kept, because ids never change. If the registry cannot be reached, records are
**not** dead-lettered: they wait (see the outcomes table).

### The contract (layer 3)

The rules of the original's decoder, plus `actor`:

| Field | Rule |
|---|---|
| `conversation_id` | required; `^[A-Za-z0-9._:-]{1,128}$` |
| `sequence`, `event_version` | required integers, 1 to 2,147,483,647 |
| `event_name` | required; at most 128 characters |
| `occurred_at` | required; an RFC 3339 time |
| `id_yape_account` | optional; the same pattern as `conversation_id` |
| `flow` | optional; `^[a-z][a-z0-9_]{0,63}$` |
| `actor` | optional; `user`, `agent` or `system` |
| `payload`, `metadata` | required; JSON (a string holding JSON, as Debezium sends JSONB, or an object) that is an object or array |
| unknown fields | ignored, so a new column does not break the consumer |

An empty or `null` value (a tombstone) is skipped.

## Projection: what becomes a message

| Event | Role | Text | Author |
|---|---|---|---|
| `UserMessageSent` | `appUser` | `payload.text` | the account (`id_yape_account`) |
| `AgentMessageSent` | `appMaker` | `payload.text` | `ms-ml-genai-agent-bs` |
| `GuardrailResponseSent` | `appMaker` | `payload.response_text` | `ms-ml-genai-agent-bs` |

Every other event is stored in the inbox only. A chat event with no text, a non-boolean `truncated`, or (for a
user message) no account is **stored without a message** and counted as invalid, never dropped. An empty text is
valid.

## The store: one statement, one transaction

`route-receive.camel.yaml` runs a single `WITH` statement, so Postgres applies all or nothing:

1. insert the event into `conversation_inbox`, `ON CONFLICT (conversation_id, sequence) DO NOTHING`;
2. if it was new and projectable, upsert the message (`xmax = 0` tells a new row from an update);
3. if the message was new and has an account, add one to its summary and widen the first and last times;
4. return `inserted`, `projected` and `same`, where `same` says whether the inbox row at that position equals this event.

## What happens to each kind of record

| Case | What happens | Offset |
|---|---|---|
| New event | Stored; a chat event also gets its message and summary. Log: `Event stored ...` | committed |
| Already stored, identical | Nothing written (a redelivery). Log: `Event duplicate ...` | committed |
| A **different** event at a stream position already taken | Refused: DLQ `store-rejected`. Without this it would pass for a redelivery and be lost without a trace. | committed |
| Tombstone | Skipped. Log: `Tombstone skipped ...` | committed |
| Poison (any reason above) | One `ERROR` line on the `dlq` logger | committed |
| Constraint violation or data the store cannot hold (SQLSTATE class 22 or 23) | DLQ `store-rejected`, field `sqlstate-<code>` | committed |
| **Transient**: database unreachable or timing out, registry unreachable | Retried in place **forever**, the wait doubling from 1 s to 30 s, a `WARN` each time. Never dead-lettered. | not moved until it works |
| **Unexpected**: anything no rule recognizes (a bug) | Tried 3 more times, then DLQ `unexpected` with the exception class in `field=` | committed |

A poison record never blocks a partition: retrying cannot help, so it is logged and skipped. A database outage
blocks it on purpose, and nothing is lost. An outage longer than `max.poll.interval.ms` (5 minutes) makes the broker
drop the consumer from the group; the record in hand is then delivered again and counted as a duplicate.

Why unexpected errors are dead-lettered and not retried forever: retrying a bug cannot succeed, and an endless loop
would hide it behind a stuck partition. A burst of `reason=unexpected` lines is loud and easy to alert on, and
because the line keeps the body, the records can be replayed after the fix.

## The dead-letter log

One line per poison record, on its own logger, `dlq`, at `ERROR`:

```
DLQ reason=field-range field=conversation_id topic=yape.public.conversation_events partition=3 offset=19 key=\x00\x00\x00\x00\x01{"conversation_id":"bad id"} detail=not 1 to 128 of letters, digits and . _ : - body=\x00\x00\x00\x00\x02{"conversation_id": "bad id", "sequence": 1, ...}
```

| Part | Meaning |
|---|---|
| `reason` | Why it was refused (tables above). |
| `field` | The offending field, or for `store-rejected` the SQLSTATE, or for `unexpected` the exception class. |
| `topic` `partition` `offset` | Where the record is, so it can be found and replayed. |
| `key`, `body` | The record as text. The Schema Registry header's zero bytes are shown as `\x00`. Capped at 16,384 characters. |
| `detail` | A short explanation. |

> **The body is logged in full.** It holds conversation text and account IDs. That is acceptable with fake data on a
> local machine, and it makes replay possible. The reference service deliberately logs no content. Before using real
> data or a shared environment, remove `body=${exchangeProperty.rawText}` from the `logPoison` step in
> `route-poison-handling.camel.yaml`.

Read it:

```bash
docker logs conv-history-consumer 2>&1 | grep 'DLQ reason='
# count by reason
docker logs conv-history-consumer 2>&1 | grep -o 'DLQ reason=[a-z-]*' | sort | uniq -c
```

**Replay** after a fix: rewind the group to the offsets in the lines (see the [cheatsheet](cheatsheet.md#consumer-group-offsets)).
A log is not a queue: if you need records kept and re-readable independent of container logs, copy them to a Kafka
topic from `direct:dlq`.

### Kafka header names (Camel 4)

Use these in `${header.<name>}`. The old `kafka.TOPIC` style names do not exist in Camel 4 and resolve to empty text.

| Header | Holds |
|---|---|
| `CamelKafkaTopic` / `CamelKafkaPartition` / `CamelKafkaOffset` | Where the record is |
| `CamelKafkaKey` | The key (framed like the value: header + `{"conversation_id": ...}`) |
| `CamelKafkaTimestamp` | Record timestamp, epoch milliseconds |

## `application.properties` changes from the template

| Property | Template | Now | Why |
|---|---|---|---|
| `camel.main.logLanguage` | `groovy` | `simple` | With `groovy`, every `log` message is compiled as a Groovy script, so the normal `${...}` text fails. |
| `camel.management.enabled` / `.port` / `.path` | absent | `true` / `9876` / `/q` | Makes health available at `/q/observe/health`, the URL Docker's healthcheck calls. Without them the container is `unhealthy` forever. |
| `camel.jbang.dependencies` | `camel-console` | adds `camel-sql`, `camel-jackson`, the Postgres driver, HikariCP, `json-schema-validator` | Downloaded from Maven Central when the container starts. |
| `camel.beans.pgDataSource.*` | absent | a Hikari pool, `driverClassName=org.postgresql.Driver` | The driver must be named: DevMode loads dependencies in its own classloader. |

## Run it

1. Start the cluster and Karavan ([setup guide](karavan-setup.md)); apply the `camel_history` migrations.
2. In Karavan open `conv-history-consumer` → **Containers** → **Run**. The first run pulls the DevMode image
   (about 1.5 GB) and downloads the dependencies, so allow a few minutes.
3. Watch it: Karavan's **Log** tab, or `docker logs -f conv-history-consumer`. A healthy start shows
   `Routes startup (total:2)` (`routeReceive`, `routeDlq`), then the group joins and gets all 12 partitions.
4. `docker ps --filter name=conv-history-consumer` says `(healthy)` after about 25 seconds.

## Change it

Karavan stores the files in its database, and DevMode copies them into the container when it is created.

1. Change the files in Karavan, or in this repo and then **Push** and **Pull** (see [setup](karavan-setup.md#how-karavan-and-git-work-together)).
2. **Containers** → **Stop** → **Delete** → **Run**. Running the stopped container would reuse the old files.

For quick iterations without Karavan, run the same image against the files in this repo:

```bash
./scripts/devmode-local.sh conv-history-consumer APP_TOPIC=camel.test.events APP_KAFKA_GROUPID=camel-test
docker logs -f devmode-local-conv-history-consumer
./scripts/devmode-local.sh stop conv-history-consumer
```

## Test it

Two scripts, both against the local cluster, both on **throwaway topics** and groups:

| Script | What it proves | Time |
|---|---|---|
| `./scripts/test-consumer.sh` | 35 checks. Chat, non-chat, duplicate and conflicting events; summary counts; 17 poison cases, each with its exact reason; a tombstone; no lag (no poison record blocks a partition); an unreachable database is retried, not dead-lettered, and recovers; an unexpected error is dead-lettered after 3 retries. | about 1.5 min |
| `./scripts/parity-check.sh` | Replays the 96 rows of `public.conversation_events` as Debezium would, and compares the three `camel_history` tables with the original consumer's `public` tables, every column, both directions. | about 25 s |

Both truncate the `camel_history` tables. They never write to the real topic or to the `public` tables.

To publish a fake record to the real topic by hand, remember it needs the Schema Registry header, or it is
dead-lettered as `no-schema-header`, and **Kafka cannot delete records**: if the original service starts later it reads
them too. Always use obviously fake IDs. Two unframed test records from setup (`test-karavan-conv-0001`, `-0002`) are
already on the topic and show up as `no-schema-header` in the DLQ log.

## Replay messages

A consumer group commits its position, so a message that was already read is not read again, even if it was
dead-lettered. To read it again, rewind **this group only**. The group must be inactive: stop the container and wait
about 45 seconds. See the [cheatsheet](cheatsheet.md#consumer-group-offsets), including the dry run you should always
do first.

## Known limits

- **Two writers on the same event.** The duplicate check reads the inbox in the same statement. If a second consumer
  commits the same stream position between the statement's snapshot and its insert, a genuine duplicate could be
  reported as `store-rejected`. It needs two concurrent consumers; with one group member it cannot happen.
- **No rebuild command.** The original can replay its inbox into messages and summaries (`consumer rebuild`). That is
  not ported. It would be a single `INSERT ... SELECT` from `conversation_inbox`.
- **The DLQ is a log.** It lives as long as the container's logs do.
- **The registry schema is read at the first record,** not at startup. An unreachable registry shows as `WARN` retries
  on the first record, not as a failed start.
