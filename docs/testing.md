# Testing

Every test of this repository, what it proves, what it needs and how to run it. The short version: `./scripts/test-all.sh` runs
everything that needs only the shared cluster and the Foundry project (about 15 minutes) and ends with one table.

Last full run, 2026-11-18, on the final code: **all 10 suites green**.

| Suite | Count | What it needs |
|---|---|---|
| `check-docs.py` | 64 pointers, 112 links, 140 labels, 16 diagrams | Nothing (Mermaid CLI for the diagrams) |
| JUnit, `test-camel.sh` | **421** tests (api 265, consumer 81, sync 75) | Docker, the cluster; the sync module also the fake Foundry |
| `test-token-broker.sh` | 16 checks | Cluster, the real Foundry identity |
| `test-fake-foundry.sh` | 81 checks | Cluster, the real Foundry |
| `test-consumer.sh` | 37 checks | Cluster (Kafka, Postgres, Schema Registry) |
| `test-sync.sh` | 124 checks | Cluster, the fake Foundry (`FOUNDRY_MODE=real` runs some on the real one) |
| `test-api.sh` | 273 checks | Cluster, the fake Foundry |
| `test-cleanup-orphans.sh` | 23 checks | The real Foundry |
| `oracle-api.sh` | 54 checks | The Karavan-run API |
| `check-foundry-sync.sh` | 10 conversations, 42 items | The real Foundry, the Karavan-run projects |
| `test-e2e.sh` | 13 checks | VPN, the producer agent, the three projects. **Not part of `test-all.sh`** |

## One command

```bash
./scripts/test-all.sh                 # everything above except test-e2e.sh
./scripts/test-all.sh --offline       # no call to the real Foundry
./scripts/test-all.sh --e2e           # also the real producer flow
./scripts/test-all.sh --only camel,sync --stop
```

The full output of each suite is kept in `.test-logs/<suite>.log` (git-ignored). The table at the end shows the last summary line of
each. A suite that fails prints its first failing lines; read the log for the rest.

## What is safe to run

Every suite works on **its own rows and topics**: fixtures are keyed with a prefix (`t-`, `ts-`, `ta-`, `tco-`, `jt-`) and removed
at the end, each throwaway topic and consumer group is deleted, and every Foundry conversation a test creates is deleted. The real
history in `camel_history` (42 messages, 10 conversations at the last count) and the real consumer groups are never touched.

**One script is destructive: `scripts/parity-check.sh`** empties the three `camel_history` tables. It now refuses to run while they
hold rows unless you pass `--wipe-camel-history`. `test-consumer.sh` used to do the same (a `TRUNCATE`) and was fixed in the same way: it
deletes only its `t-%` rows. If you add a script, scope every `DELETE` to your own prefix and never `TRUNCATE`.

## JUnit (`tests/camel`)

Three Maven modules, one per project, in a Maven container on the cluster network (`maven:3.9-eclipse-temurin-21`, cache in the
Docker volume `camel-tests-m2`, so only the first run downloads). They compile **the projects' own Java files** (`sourceDirectory`
points at `conv-history-*/`), so a test breaks when the code does, and the YAML routes are loaded from the project folders.
Nothing is a copy.

```bash
./scripts/test-camel.sh                         # the three modules, then the totals
./scripts/test-camel.sh api                     # one module (api, consumer or sync)
./scripts/test-camel.sh api ApiRoutesTest       # one class (a comma list works)
```

| Module / class | Tests | What it proves |
|---|---|---|
| api / `ApiRequestTest` | 122 | Every parameter rule of the contract at its edges (sizes 0/1/100/101, malformed cursors, repeated parameters, ids with `/`, spaces, unicode, 128/129 characters), and that every request header that is not Camel's is removed |
| api / `ProblemResponderTest` | 13 | Which failure becomes 400, 404, 500 or 503; the body never repeats what the client sent |
| api / `ConversationListTest` | 11 | Order, `Link` headers, microsecond cursors, times truncated (not rounded), plain numbers |
| api / `FoundryReaderTest` | 53 | Against a real local HTTP server: every status (401, 403, 404, 408, 429, 5xx are "try again"; the other 4xx are a bug), token cache and renewal, a broker that fails or is slow, timeouts |
| api / `MessagePageTest` | 19 | Which database errors are "try again" (connection) and which are a bug |
| api / `ApiRoutesTest` | 47 | **The API as a client sees it**: the real YAML routes and beans in a Camel Main with a real HTTP server, the cluster's Postgres and a fake Foundry that pages like the real one. Walks 230 conversations and 25 messages through `Link` in both directions; ties; 404/405; hard text; 40 concurrent requests; Foundry down, slow or answering garbage; no echo of request headers; `CamelSqlQuery` from a client has no effect |
| consumer / `DecoderTest` | 66 | The decoder at the edge of every field, against the real Schema Registry (read only); tombstones; the consumer's and the sync's copies of the shared classes must stay **identical** (a test compares them) |
| consumer / `StoreRouteTest` | 15 | Routes 2 and 3 with their real error rules on the cluster's Postgres: stored, duplicate, conflict, a NUL (refused for good), a million characters, 16 threads on one event, 30 on one conversation |
| sync / `FoundryClientTest` | 56 | Against the **fake Foundry**: the reconcile matrix (lost answer, several held items, identical texts, unknown item, changed role, late event, gone, more than 100 items, a skipped earlier message), rebuild and its half-built retry, `deleteOldConversation`, statuses, token |
| sync / `SyncStoreTest` | 19 | The same database-error classification as `MessagePageTest`, for the sync |

`tests/camel/common/FakeHttp.java` is a small real HTTP server shared by the api and sync modules.

**Two things the JUnit tests do not cover:** route 1 of the consumer and of the sync (the Kafka subscription and the offset commit;
`test-consumer.sh` and `test-sync.sh` do), and a Postgres that goes down (`test-api.sh` does).

## System suites

| Script | Sections | Notes |
|---|---|---|
| `test-consumer.sh` | tables, dead-letter log, offsets, an outage and its recovery, an unexpected error | Starts the consumer with `devmode-local.sh` on a throwaway topic. 19 records dead-lettered, each with its exact reason, including two the store refuses (a NUL in a text and in a jsonb) |
| `test-sync.sh` | `base receive first order wait reconcile rebuild edge errors broker crash real401` | Run some: `./scripts/test-sync.sh reconcile edge`. `crash` kills the process with SIGKILL in the window where Foundry has the item and the sync has not recorded it. `edge`: 130 messages, the whole sync repeated, interleaved conversations, ten awkward texts compared by SHA-256, a skipped message. `real401` runs only against the real Foundry |
| `test-api.sh` | `skeleton validation list messages failures dependencies checker` | Runs the API with the DevMode image against the fake; every response is recorded and checked against `docs/contract/` |
| `test-fake-foundry.sh` | real versus fake, then the faults | Part 1 runs one block of calls on the real Foundry and on the fake and compares line by line: a difference means the fake drifted |
| `test-token-broker.sh` | health, token, cache, secrets | Restarts the broker first, so the token it checks is a fresh one |
| `test-cleanup-orphans.sh` | listing, instance, empty map, minimum age, `--delete` | On the real Foundry, with conversations it creates |
| `oracle-api.sh` | lists and message pages | Computes the expected answer with plain SQL for every account and compares it with the Karavan-run API |
| `check-foundry-sync.sh` | per conversation | Read only: Foundry holds exactly what `camel_history` says, item by item; no orphan |
| `test-e2e.sh` | the whole chain | A real producer flow (`card` by default), timed hop by hop. Adds one conversation to the shared event store |

Helpers: `scripts/test-lib.sh` (checks, `wait_until`, the real-Foundry calls), `scripts/lib/events.py` (events as Debezium writes them),
`scripts/lib/flaky-broker.py` (a broker whose first tokens are junk, for the real 401), `scripts/fake-foundry/server.py` (the fake and
its faults), `scripts/devmode-local.sh` (runs a project in the DevMode image on a throwaway topic).

### The fake Foundry

`scripts/fake-foundry/server.py` imitates what was **measured** on the real service (server-generated ids, no item time or metadata,
at most 20 items per write, 404 after a delete...) and has faults the real one cannot be asked for, set with `POST /__fail`:
`429`, `500`, `400`, `401`, `slow`, `drop` (applies the request and closes without answering), `late` (applies it and answers after a
delay, a window to kill the caller in), each with a `count`, a `delayMs` and an optional `method`. `POST /__reset` clears it,
`GET /__state` shows it. `./scripts/fake-foundry.sh start|stop|status` runs it on the cluster network (also on `localhost:8098`).
It says `Connection: close` on every answer; without it the JDK's pooled client reuses connections the server has closed.

## Mutation experiment: do the tests notice a change?

`tests/mutation/run.sh` copies the repo to a folder under your home, changes **one condition at a time** (25 of them: the paging
cursor, the page size, status classification, the reconcile logic, the decoder's bounds, the store SQL...), runs the JUnit tests of
that module and reports `KILLED` or `SURVIVED`. A survivor is a missing test. The list is in `tests/mutation/mutate.py`.

```bash
./tests/mutation/run.sh            # all (about 20 minutes)
./tests/mutation/run.sh 3 12       # some, by number from 0
```

Last run: 25 of 25 killed, after a test was added for the one survivor (`has_more` ignored in `FoundryClient`) and an invalid mutation
was redone. A mutation whose text no longer occurs once in the code is reported `SKIPPED`: update it. The copy must be under `$HOME`:
on macOS Docker cannot see `/private/tmp`, Maven finds an empty folder and reports `NO TESTS RAN`.

## Adding a test

1. A bug: write the test that **fails first**, see it fail on the old code, then fix.
2. Logic with no I/O: a JUnit test in the module of the project. Anything with a database or HTTP: the same, using the cluster's
   Postgres (rows keyed `jt-`) and `FakeHttp`.
3. A behaviour that needs Kafka or a killed process: a section of `test-sync.sh` / `test-consumer.sh`. Use a throwaway topic and group
   and scope every row to your prefix.
4. Run `./scripts/test-all.sh`, and `python3 -I scripts/check-docs.py` if you touched a route, a label or a doc.

## Known gaps

- A real 429 or 5xx from Foundry was never provoked: the sync and API handle them against the fake, and the status classification is
  tested, but Foundry's own throttling is unobserved. See [foundry-setup.md](foundry-setup.md#limits-and-behaviour-measured).
- The Kafka eviction from a group (`max.poll.interval.ms`) that the sync's poll settings guard against was not provoked.
- The token race in the API's `FoundryReader` is fixed by construction, with no test that fails without the fix.
- `test-e2e.sh` (the real producer flow) was last run on 2026-11-18 and passed; rerun it after a change to the chain. It is not part of `test-all.sh`.
