# conv-history-consumer

A Camel Kafka consumer, built in Karavan, that reads the conversation events
topic and **logs each message it receives**. It mirrors how the reference
project [`ms-ml-conv-history-bs`](../../ms-ml-conv-history-bs) consumes the same
topic, without storing anything.

Project folder: [`conv-history-consumer/`](../conv-history-consumer)

## What it does

```
Kafka topic yape.public.conversation_events ──► routeReceive ──► log line
        (broker kafka:29092)                     (Camel 4.22.2)
```

| Setting | Value | Notes |
|---|---|---|
| Topic | `yape.public.conversation_events` | Same topic as `ms-ml-conv-history-bs`. |
| Brokers | `kafka:29092` | The cluster's *internal* listener, for containers on `yape-local`. From the host it is `localhost:9092`. |
| Consumer group | `ms-ml-camel-conv-history-bs` | Different from the reference service's group (`ms-ml-conv-history-bs`), so the two never compete for partitions. |
| Offset reset | `earliest` | Applies only when the group has no committed offset. |

### The route

`conv-history-consumer/route-receive.camel.yaml`:

```yaml
- route:
    id: routeReceive
    description: Receive Route
    nodePrefixId: routeReceive
    from:
      id: fromKafkaReceive
      uri: kafka
      parameters:
        topic: yape.public.conversation_events
        brokers: kafka:29092
        groupId: ms-ml-camel-conv-history-bs
        autoOffsetReset: earliest
      steps:
        - log:
            id: logReceived
            message: "Received kafka message topic=${header.CamelKafkaTopic} partition=${header.CamelKafkaPartition} offset=${header.CamelKafkaOffset} key=${header.CamelKafkaKey} timestamp=${header.CamelKafkaTimestamp} bodyBytes=${bodyAs(String).length()} body=${bodyAs(String)}"
```

### What the log line looks like

```
Received kafka message topic=yape.public.conversation_events partition=3 offset=19 key=test-karavan-conv-0001 timestamp=1795014209847 bodyBytes=347 body={"conversation_id":"test-karavan-conv-0001","sequence":1,"event_name":"karavan.test.event", ...}
```

> **The body is logged in full.** It contains conversation text and account
> IDs. That is acceptable with fake data on a local machine. The reference
> project deliberately logs only coordinates and counts, never content. Before
> using real data or a shared environment, remove ` body=${bodyAs(String)}`
> from the message.

### Kafka header names (Camel 4)

Use these in `${header.<name>}`. The old `kafka.TOPIC` style names do not exist
in Camel 4 and resolve to empty text.

| Header | Holds |
|---|---|
| `CamelKafkaTopic` | Topic |
| `CamelKafkaPartition` | Partition |
| `CamelKafkaOffset` | Offset |
| `CamelKafkaKey` | Record key (here the `conversation_id`) |
| `CamelKafkaTimestamp` | Record timestamp, epoch milliseconds |

### Message format

The topic carries Debezium's flat `conversation_events` row as JSON, optionally
with a Schema Registry header (a zero byte plus a 4-byte schema id) in front.
The reference decoder accepts both. This route logs the raw text and does not
decode it, so a framed record shows the 5 header bytes as odd characters at the
start of `body`.

Fields: `conversation_id`, `sequence`, `event_name`, `event_version`, `payload`,
`metadata`, `correlation_id`, `id_yape_account`, `actor`, `flow`, `occurred_at`.

## `application.properties` changes from the template

Karavan's template is kept except for these, all of which were needed:

| Property | Template | Now | Why |
|---|---|---|---|
| `camel.main.logLanguage` | `groovy` | `simple` | With `groovy`, every `log` message is compiled as a Groovy script, so the normal `${...}` text fails. `simple` is Camel's default and avoids downloading `camel-groovy`. |
| `camel.management.enabled` | *(absent)* | `true` | Starts Camel's management server. |
| `camel.management.port` | *(absent)* | `9876` | The port Karavan's DevMode image health-checks. |
| `camel.management.path` | *(absent)* | `/q` | Makes health available at `/q/observe/health`, the exact URL the Docker healthcheck calls. |

Without the three `camel.management.*` lines the container reports
`unhealthy` forever, although the consumer works.

## Run it

1. Start the cluster and Karavan ([setup guide](karavan-setup.md)).
2. In Karavan open `conv-history-consumer` → **Containers** tab → **Run**. The
   first run pulls the DevMode image (about 1.5 GB), so allow a few minutes.
3. Watch it: Karavan's **Log** tab, or
   ```bash
   docker logs -f conv-history-consumer
   ```
   Healthy start looks like `Routes startup (total:1)`,
   `Started routeReceive (kafka://yape.public.conversation_events)`, then the
   group joins and gets all 12 partitions.
4. Check health: `docker ps --filter name=conv-history-consumer` should say
   `(healthy)` after about 25 seconds.

## Change it

Edits in Karavan do **not** reach a running container. To apply a change:

1. Edit and save in Karavan.
2. **Containers** tab → **Stop**, then **Delete** (removes the stopped
   container only, not the project), then **Run**. Running the old stopped
   container would reuse the old files.

## Test it

The topic may be empty. Publish a clearly fake record:

```bash
KEY="test-karavan-conv-0003"
TS=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
VAL="{\"conversation_id\":\"$KEY\",\"sequence\":1,\"event_name\":\"karavan.test.event\",\"event_version\":1,\"payload\":{\"text\":\"hello\"},\"metadata\":{\"source\":\"karavan-test\"},\"correlation_id\":\"test-corr\",\"id_yape_account\":\"test-account\",\"actor\":\"test\",\"flow\":\"karavan-test\",\"occurred_at\":\"$TS\"}"
printf '%s|%s\n' "$KEY" "$VAL" | docker exec -i yape-kafka kafka-console-producer \
  --bootstrap-server kafka:29092 --topic yape.public.conversation_events \
  --property parse.key=true --property key.separator='|'
```

The log line appears within seconds.

**Kafka cannot delete a record.** Anything you publish stays on this shared
topic. If the real `ms-ml-conv-history-bs` service starts later, it will read
your test records too. Always use obviously fake IDs.

Two records are already on the topic from setting this up:
`test-karavan-conv-0001` and `test-karavan-conv-0002`.

## Replay messages

A consumer group commits its position, so a message that was already read is
not read again, even if logging it failed. To read it again, rewind **this
group only**. The group must be inactive, so stop the container first and wait
about 45 seconds for Kafka to drop the old member (see
[cheatsheet](cheatsheet.md#consumer-group-offsets) for the commands, including
the dry run you should always do first).
