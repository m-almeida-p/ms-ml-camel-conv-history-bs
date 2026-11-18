# ms-ml-camel-conv-history-bs

Apache Camel Karavan projects for the Yape conversation history:

| Project | What it does |
|---|---|
| `conv-history-consumer` | Reads `yape.public.conversation_events` and builds the history in Postgres (schema `camel_history`), with schema checks and a dead-letter log. |
| `conv-history-sync` | Sends every chat message to **Microsoft Foundry**, once and in order, and keeps the map between our ids and Foundry's. |
| `conv-history-api` | Serves the history with the **same API as `ms-ml-conv-history-bs`**, reading the messages from the Foundry Conversations API. |

```
agent -> event store -> Debezium -> Kafka -> consumer -> camel_history
                                          -> sync -> Microsoft Foundry <- API <- a client
```

## Documentation

See [docs/](docs/README.md): the design with diagrams, Karavan setup, a guide per project, the Foundry setup,
troubleshooting and a command cheatsheet.

Start with [docs/design-foundry.md](docs/design-foundry.md) for the Foundry side and
[docs/design.md](docs/design.md) for the consumer.
