# Operating the three projects

What to watch, how to restart, and how to undo a change. This is a local PoC: there is no dashboard, no alerting and no SLO. The
tables below say what each signal is and what a real alert would be built from. For the first look at a system you do not know, use
the one-minute check in [handoff.md](handoff.md#is-it-healthy-one-minute).

## What runs where

| Container | Host port | Health | Started by |
|---|---|---|---|
| `conv-history-consumer` | 8081 (all interfaces) | `docker inspect` health, `GET :9876/q/observe/health` inside the network | Karavan, **Run** |
| `conv-history-sync` | 8084 (all interfaces) | same | Karavan, **Run** |
| `conv-history-api` | 8086 (all interfaces) | `GET /health` (200 when Postgres answers; Foundry is not asked) | Karavan, **Run** |
| `foundry-token` (broker) | none | `docker inspect` health | `docker compose up -d foundry-token` |
| `karavan`, `karavan-db`, `karavan-registry` | 9998 and 5555, on `127.0.0.1` | the UI answers | `./scripts/up.sh` |
| `fake-foundry` (tests only) | 8098, on `127.0.0.1` | `./scripts/fake-foundry.sh status` | the tests |

Each project also serves Camel's management endpoints on port **9876**, not published on the host, so from another container on
`yape-local`: `/q/observe/health` and `/q/observe/health/live` (200) and `/q/observe/metrics` (200). `/q/dev`, `/q/send` and
`/q/download` answer 404 (checked), although `sendEnabled` and `downloadEnabled` are on in the properties: turn them off before the
network is shared.

## What to watch

| Signal | How to read it | Healthy | If not |
|---|---|---|---|
| Container health | `docker ps --format '{{.Names}} {{.Status}}' \| grep -E 'conv-history\|foundry-token'` | all `healthy` | `docker logs <name>`; [troubleshooting.md](troubleshooting.md) |
| Consumer lag, both groups | `docker exec yape-kafka kafka-consumer-groups --bootstrap-server kafka:29092 --describe --group <group>` | 0 (briefly more while a flow runs) | Lag that grows: the project is down, or a record is being retried (next two rows). Groups: `ms-ml-camel-conv-history-bs` (consumer), `ms-ml-camel-conv-history-sync` (sync) |
| Dead letters | `docker logs <consumer or sync> \| grep 'DLQ reason='` | none | Each line names reason, field, topic, partition, offset. Reasons and what each means: [consumer](conv-history-consumer.md#the-dead-letter-log), [sync](conv-history-sync.md#the-dead-letter-log). `unexpected` is a bug |
| Retries in place | `docker logs <name> \| grep 'Failed delivery'` | none | Foundry, the broker or the database cannot answer; the offset does not move, so lag grows. Nothing is lost or duplicated; it goes on by itself |
| The sync waiting for the consumer | `docker logs conv-history-sync \| grep -i 'projection'` (a `WARN` once a minute while it waits) | none | The consumer is down or behind. After ten minutes the record is dead-lettered as `projection-missing` |
| Rebuilds | `docker logs conv-history-sync \| grep 'Conversation rebuilt'` (`WARN`) | rare | A late event, a conversation Foundry lost, or an unexplained item. Each says why |
| API answers | `curl -s localhost:8086/health`; 503s in `docker logs conv-history-api` | 200 | A 503 on `/messages` is Foundry, the broker or the database; the log says which |
| The data agrees | `./scripts/oracle-api.sh` and `./scripts/check-foundry-sync.sh` | `OK` | `MISMATCH` lists the conversation. Both are read only and cheap: a good smoke test after any deploy |
| Metrics | `/q/observe/metrics` on 9876 (Camel's Micrometer meters, JVM and routes) | n/a | There is no scraper; this is where one would point |

A real alert would be built from: any `DLQ reason=unexpected`, lag above 0 for more than a few minutes, a container that is not
`healthy`, and the share of 503s from the API.

## Starting, stopping, restarting

Order: **consumer, then sync, then API**. The sync needs the consumer's rows; the API needs both.

| You want | Do |
|---|---|
| Stop everything | `./scripts/stop.sh` stops Karavan; stop a project from its page in Karavan, or `docker stop conv-history-<name>` |
| Start a project that is stopped | In Karavan, open the project, the **top-right Run** |
| Pick up a code change | Push, then in Karavan **Source > Pull**, then `docker rm -f conv-history-<name>`, reload the page, **Run**. A restart is not enough: Run copies the project files when it creates the container |
| Pick up a changed `application.properties` or compose file | the same: the container must be recreated |
| After a machine restart | `./scripts/up.sh` (or `start.sh`), then **Run** for each project, in order |

The sync, restarted at any moment, resumes from its committed offsets and reconciles what was in flight (an item Foundry kept and the
sync did not record is adopted, not sent again). Tested by killing it with SIGKILL ([testing.md](testing.md#system-suites)).

To replay records, rewind **only the project's own group** with it stopped: see the offsets section of
[cheatsheet.md](cheatsheet.md). Never touch the group `ms-ml-conv-history-bs` (the original service's).

## Rollback plan

**Trigger.** After a deploy, any of: a container that does not become `healthy`; `oracle-api.sh` or `check-foundry-sync.sh` reporting a
mismatch; a `DLQ reason=unexpected`; lag that does not fall; an API 5xx that was not there before.

**Steps** (about five minutes, no data step):

1. Find the commit: `git log --oneline` (each change is its own commit, with a message that says what and why).
2. `git revert <commit>` (or several, newest first), run `python3 -I scripts/check-docs.py`, `./scripts/scan-secrets.sh`, push.
3. In Karavan **Pull**, `docker rm -f` the affected project(s), **Run** them in order, one at a time, each `healthy` before the next.
4. Verify: `./scripts/oracle-api.sh`, `./scripts/check-foundry-sync.sh`, lag 0.
5. Tell the owner what was reverted and why.

**Data.** There are no migrations in this repository (the `camel_history` tables are migrated from `ml-genai-agents-bs-testing`), so a
rollback never needs a schema step. What the code wrote stays valid under older code: the item map and the conversation map keep
their shape, and Foundry's `metadata.instance` is only read by the cleanup script (a conversation without it counts as `default`).
A rebuild that was in progress leaves, at worst, one extra Foundry conversation that `foundry-cleanup-orphans.sh` removes.

**Exercised, not rehearsed as a drill.** The redeploy procedure (Pull, remove, Run, verify) was done a dozen times in the course of this
work, including after a bad compose change that stopped all three projects, which was fixed by reverting the file. A revert of a
specific commit followed by a redeploy was not rehearsed.

## Rotating the Foundry secret

The service principal's secret expires one year after creation ([foundry-setup.md](foundry-setup.md)). The broker reads it from `.env`
when it starts. To rotate: create the new secret in Azure, put it in `.env` (never anywhere else), and recreate the broker with
`docker compose up -d foundry-token`; the projects ask it for a new token when theirs expires, or at once after a `401`. This was not
exercised.

## No SLO, no error budget

Nothing here defines an availability or latency objective, so there is no error budget to gate a release on. One page of the API costs
one Foundry call, about a second at the median (measured, [foundry-setup.md](foundry-setup.md#limits-and-behaviour-measured)). If this
goes further, write the objectives first; the signals above are what to measure them with.
