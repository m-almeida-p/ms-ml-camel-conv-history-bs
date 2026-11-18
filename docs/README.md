# Documentation

Guides for the Apache Camel Karavan setup in this repository and for the three integrations built with it: the Kafka consumer
`conv-history-consumer`, the Microsoft Foundry sync `conv-history-sync`, and the history API `conv-history-api`.

| Guide | Read it when |
|---|---|
| [design.md](design.md) | You want the picture first: the context, the containers, the three routes and their steps, the vocabulary, the legend and the Camel patterns used. |
| [karavan-setup.md](karavan-setup.md) | You need to start Karavan, understand how it is wired, or rebuild it from scratch. |
| [conv-history-consumer.md](conv-history-consumer.md) | You want to know what the Kafka consumer does, how to run it, test it and replay messages. |
| [design-foundry.md](design-foundry.md) | You want the picture of the Foundry side: the sync, the API and the token broker, with diagrams per level. |
| [foundry-setup.md](foundry-setup.md) | You need to create the Azure identity, start the broker, run the tests, or know what Foundry does (as measured). |
| [conv-history-sync.md](conv-history-sync.md) | You want to know how a chat message reaches Foundry once: routes, errors, reconciliation, rebuilding a conversation. |
| [conv-history-api.md](conv-history-api.md) | You want the API: endpoints, cursors, how a page is built from Foundry and Postgres, errors, and where it differs from the reference service. |
| [troubleshooting.md](troubleshooting.md) | Something failed. Each entry lists the symptom, the cause and the fix. Every entry is a problem we actually hit. |
| [cheatsheet.md](cheatsheet.md) | You need a command: Docker, Kafka CLI, consumer-group offsets, Git sync. |

## Repository layout

```
.
├── docker-compose.yml          Karavan, its Postgres and an image registry
├── .env.example                Settings to copy to .env (git-ignored; holds the GitHub token)
├── scripts/                    up / stop / start / logs / clean for the Karavan stack, the local runner
│                               (devmode-local.sh), the tests (test-*.sh), the token broker, the fake Foundry,
│                               and the checks (oracle-api.sh, check-foundry-sync.sh, contract-check.sh)
├── conv-history-consumer/      A Karavan project: the Kafka consumer that builds the conversation history
├── conv-history-sync/          A Karavan project: sends every chat message to Microsoft Foundry, once and in order
├── conv-history-api/           A Karavan project: the history API (the reference contract), reading the messages from Foundry
└── docs/                       This documentation; docs/contract/ is the reference service's OpenAPI, unchanged
```

Each top-level folder that Karavan manages is one Karavan *project*. Karavan
commits to this same Git repository, so its projects are never lost when the
local containers are removed.

## Conventions used in these guides

- Commands run from the repository root unless stated.
- No credentials appear in these docs or in the repository. The GitHub token and the Foundry service
  principal live in `.env`; the Karavan UI login is not defined here and must not be committed.
- Everything described is for **local development** against the shared local
  cluster (`../cluster`), with fake data.
