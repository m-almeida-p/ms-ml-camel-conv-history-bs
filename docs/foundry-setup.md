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
./scripts/test-token-broker.sh              # 15 checks: a token Foundry accepts, the cache, no secret in logs or files
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
| `test-fake-foundry.sh` | The fake Foundry behaves like the real one (38 observations) | Cluster, Foundry |
| `test-sync.sh` | The sync: order, repeats, reconciliation, rebuilds, errors, a broker that is down | Cluster; `FOUNDRY_MODE=real` runs some on the real Foundry |
| `test-api.sh` | The API: validation, list, messages, failures, and every response against the contract | Cluster |
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
- A user item takes a string; an assistant item must be a list of `output_text` parts.
- At most 20 items per request. The sync sends one per call.
- **No idempotency key**: the `Idempotency-Key` header is ignored. Sending twice stores twice.
- `after` and `before` follow the order of the listing, so "the messages older than this one" is `order=desc` with `after`.
- Listing conversations cannot filter by metadata; an orphan is found by listing and filtering here.
- A deleted conversation answers 404 on every call, and so does deleting it again; a malformed id is 400; a bad token is 401.
- Retention and quotas are not documented.
