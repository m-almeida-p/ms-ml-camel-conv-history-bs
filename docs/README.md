# Documentation

Guides for the Apache Camel Karavan setup in this repository and for the
`conv-history-consumer` integration built with it.

| Guide | Read it when |
|---|---|
| [karavan-setup.md](karavan-setup.md) | You need to start Karavan, understand how it is wired, or rebuild it from scratch. |
| [conv-history-consumer.md](conv-history-consumer.md) | You want to know what the Kafka consumer does, how to run it, test it and replay messages. |
| [troubleshooting.md](troubleshooting.md) | Something failed. Each entry lists the symptom, the cause and the fix. Every entry is a problem we actually hit. |
| [cheatsheet.md](cheatsheet.md) | You need a command: Docker, Kafka CLI, consumer-group offsets, Git sync. |

## Repository layout

```
.
├── docker-compose.yml          Karavan, its Postgres and an image registry
├── .env.example                Settings to copy to .env (git-ignored; holds the GitHub token)
├── scripts/                    up / stop / start / logs / clean for the Karavan stack
├── conv-history-consumer/      A Karavan project: Kafka consumer (created and pushed by Karavan)
└── docs/                       This documentation
```

Each top-level folder that Karavan manages is one Karavan *project*. Karavan
commits to this same Git repository, so its projects are never lost when the
local containers are removed.

## Conventions used in these guides

- Commands run from the repository root unless stated.
- No credentials appear in these docs or in the repository. The GitHub token
  lives in `.env`; the Karavan UI login is not defined here and must not be
  committed.
- Everything described is for **local development** against the shared local
  cluster (`../cluster`), with fake data.
