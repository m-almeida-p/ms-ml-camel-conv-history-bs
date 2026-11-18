# Setting up Microsoft Foundry for the history

What the two Foundry projects (`conv-history-sync`, `conv-history-api`) need, how the credentials reach them without going
to Git, and how to check that it all works. The design is in [design-foundry.md](design-foundry.md).

## What you need

| Need | Check |
|---|---|
| A Foundry project, and its endpoint `https://<resource>.services.ai.azure.com/api/projects/<project>` | The Foundry portal, project **Overview** |
| The Azure CLI, logged in (only to create the identity and to run the smoke tests) | `az account show` |
| A service principal with the role **Foundry User** on that project | [below](#the-service-principal) |
| The cluster up, and Karavan running | [karavan-setup.md](karavan-setup.md) |
| `curl`, `jq`, `python3` for the scripts | `jq --version` |

## Why a token broker

A container that Karavan starts receives no environment of its own, and the project files go to Git, so a secret cannot be
passed to it in either way. The secret therefore stays in the `.env` of this repo (git-ignored), and a small service in the
compose file, `foundry-token`, turns it into short-lived tokens. The projects ask the broker for a token over the Docker
network, and the broker also tells them the project endpoint, so no Azure resource name is written in a file that is committed.

```
.env (FOUNDRY_*)  ->  foundry-token  --GET /token-->  conv-history-sync, conv-history-api  --Bearer-->  Foundry
```

The broker is `scripts/foundry-token-broker/server.py` on `python:3.13-alpine`, standard library only. It is on the network
`yape-local`, publishes no port, reads only the four `FOUNDRY_*` variables, caches a token until a minute before it expires
(a token lasts an hour), and never logs the token or the secret.

## The service principal

Create it once. The role goes on the **project only**, not on the account or the subscription:

```bash
az login
PROJECT_ID="$(az resource list -g <resource-group> --resource-type Microsoft.CognitiveServices/accounts/projects \
  --query "[?name=='<account>/<project>'].id | [0]" -o tsv)"
az ad sp create-for-rbac --name sp-conv-history-foundry-poc --role "Foundry User" --scopes "${PROJECT_ID}" --years 1 -o json
```

The answer holds the secret and is shown once. Do not paste it anywhere: put its three values in `.env`, which is
git-ignored (`.env.example` lists the names):

```bash
FOUNDRY_PROJECT_ENDPOINT=https://<resource>.services.ai.azure.com/api/projects/<project>
FOUNDRY_TENANT_ID=<tenant>
FOUNDRY_CLIENT_ID=<appId>
FOUNDRY_CLIENT_SECRET=<password>
```

The secret expires in a year. To remove the identity: `az ad sp delete --id <appId>` (its role assignment goes with it).

**Role name.** *Foundry User* was called *Azure AI User*. Check the name your subscription has:
`az role definition list --query "[?contains(roleName,'Foundry User')].roleName" -o tsv`.

## Start and check

```bash
docker compose up -d foundry-token          # the broker
./scripts/test-token-broker.sh              # 16 checks: a token Foundry accepts, the cache, no secret in logs or files
./scripts/foundry-smoke-test.sh             # what the Conversations API accepts and returns (uses `az login`)
```

Then load the projects in Karavan (**Pull** on the project list, then **Run** at the top right of each project), in this order:
`conv-history-consumer`, `conv-history-sync`, `conv-history-api`. Ports on the host: sync `8084`, API `8086`.

```bash
curl -s localhost:8086/health                                             # {"status":"ok"}
./scripts/check-foundry-sync.sh                                           # Foundry against camel_history, item by item
./scripts/oracle-api.sh                                                   # the API against what the data says
```

## The tests

| Script | What it proves | Needs |
|---|---|---|
| `test-token-broker.sh` | The broker | Cluster |
| `test-fake-foundry.sh` | The fake Foundry behaves like the real one (81 checks) | Cluster, Foundry |
| `test-sync.sh` | The sync: order, repeats, reconciliation, rebuilds, errors, a broker that is down | Cluster; `FOUNDRY_MODE=real` runs some on the real Foundry |
| `test-api.sh` | The API: validation, list, messages, failures, and every response against the contract | Cluster |
| `test-camel.sh` | 372 JUnit tests of the projects' own Java and YAML: request validation, the decoder, the reconcile matrix, and the API and the consumer's store as a client or the database sees them | Cluster, fake Foundry |
| `test-all.sh` | Every suite in turn, one table at the end | Cluster, Foundry |
| `test-cleanup-orphans.sh` | The orphan cleanup, on the real project | Foundry |
| `oracle-api.sh` | The API against SQL on the data, for every account | Karavan-run API |
| `test-e2e.sh` | A real producer flow through the whole chain, timed hop by hop | VPN, agent, the three projects |

The tests that need Foundry for the unusual (a response that never arrives, a 429, a slow answer) use the **fake**,
`scripts/fake-foundry.sh`, which can be told to fail. Everything a test creates in Foundry, Postgres and Kafka it removes.

## Foundry, as measured

Verified against the real service with `scripts/foundry-smoke-test.sh` and `scripts/foundry-phase1-probe.sh`; the
documentation does not say most of this.

- Conversation and item ids are generated by Foundry (`conv_...`, `msg_...`); a caller cannot choose them.
- An item has no time and no metadata: a `created_at` is ignored and `metadata` is dropped, with a 200. So the time of a
  message and its role, author, event and flow live in `camel_history`, and Foundry holds the text and the order.
- A string `content` is stored as `input_text`, whoever wrote it. The sync sends the assistant's text as `output_text` parts, the shape
  Foundry itself returns for the assistant; a plain string would also be accepted.
- At most 20 items per request. The sync sends one per call.
- **No idempotency key**: the `Idempotency-Key` header is ignored. Sending twice stores twice.
- `after` and `before` follow the order of the listing, so "the messages older than this one" is `order=desc` with `after`.
- Listing conversations cannot filter by metadata; an orphan is found by listing and filtering here.
- A deleted conversation answers 404 on every call, and so does deleting it again; a malformed id is 400; a bad token is 401.
- Retention and quotas are not documented. See the measurements below.

## Limits and behaviour, measured

`python3 -I scripts/foundry-limits-probe.py` measures these against the real project, with fake data that it deletes (use
`--cleanup-only` if a run is interrupted). Measured on 2026-11-18, from one machine, in 2,254 requests:

| What | Measured |
|---|---|
| Throttling (429) | **None seen.** Reads up to 120 at once (95 requests/s), writes up to 40 at once (44/s). The ramp stops at the first 429 or 5xx |
| Server errors (5xx) | **None seen.** The only non-200 answers were four deliberate 400s |
| Latency | A call takes about **1 s** at the median (list: p50 1.0 s, p95 1.3 s; create: 0.7 s). The API's page latency is that of one Foundry call |
| Items per conversation | 1,000 items added (50 calls of 20) and listed in 10 pages of 100, all distinct. No limit reached |
| Text of one item | **4,000,000 characters** stored whole. No limit reached |
| Metadata | The docs say 16 pairs, 64-character keys, 512-character values. **None is enforced**: 17 pairs, a 65-character key and a 513-character value were accepted. The history uses two small pairs |
| Text fidelity | 21 awkward strings came back **identical**: emoji and a family ZWJ sequence, composed and decomposed é (kept as sent), Hebrew and Arabic, CJK, tabs and CRLF, U+2028, leading and trailing spaces, a NUL, zero-width characters, backslashes, JSON, SQL and HTML text, a 10,000-character word |
| Roles | `user`, `assistant`, `system`, `developer`. Any other, or none: 400 |
| Refused with 400 | an unknown role, no role, `content: null`, an unknown item type |
| Accepted | empty text, an empty list of items |
| Retention | Not documented. Nothing had expired in the 1.4 hours the oldest conversation had lived. **Days are not covered** |

**What these measurements cannot say.** A 429 or 5xx was never provoked, so how Foundry throttles (its `Retry-After`, its limits) is
still unobserved; the sync and the API handle those with the fake, and a real 401 was tested with a flaky broker. A limit that sits
above what the probe tried is not known: more than 4 million characters in one item, more than 1,000 items in a conversation, more
than 120 concurrent reads. Retention over days is not covered.
