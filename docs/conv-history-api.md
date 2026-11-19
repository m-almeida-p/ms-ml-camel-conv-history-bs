# conv-history-api

Serves the conversation history with the **same API as `ms-ml-conv-history-bs`**, reading the messages from the Microsoft Foundry
Conversations API. The contract is the reference service's OpenAPI, copied unchanged to
[`contract/`](contract/ms-ml-conv-history-bs-openapi.yml). Diagrams: [design-foundry.md](design-foundry.md). Setting it up:
[foundry-setup.md](foundry-setup.md).

## Endpoints

| Endpoint | File | What it answers |
|---|---|---|
| `GET /health` | `endpoint-health.camel.yaml` | 200 `{"status":"ok"}` when the database answers, 503 `{"status":"unavailable"}` when it does not |
| `GET /v1/conversations?idYapeAccount=` | `endpoint-conversations.camel.yaml` | The conversations of an account, most recent first |
| `GET /v1/conversations/{conversationId}/messages` | `endpoint-messages.camel.yaml` | The chat messages of a conversation, oldest first |

Both lists take `page[before]`, `page[after]` (at most one) and `page[size]` (1 to 100, default 100), and announce the next page in
a `Link` header with `rel="prev"` or `rel="next"`, present only when there is more.

```bash
curl -s 'localhost:8086/v1/conversations?idYapeAccount=<account>' | jq
curl -s 'localhost:8086/v1/conversations/<conversationId>/messages?page[size]=2' | jq
curl -sD - -o /dev/null -g 'localhost:8086/v1/conversations/<conversationId>/messages?page[size]=2'   # the Link header
```

Quote the URL or use `curl -g`, because of the square brackets.

## The conversation list

It reads `camel_history.conversation_summaries` joined to `foundry_conversation_map`, so **only conversations that are in Foundry
are listed**, which means the list can lag the stored messages by the moment the sync takes. Foundry cannot list by account,
which is why this comes from Postgres.

- **Order:** the time of the last message, descending, then the conversation id, descending, so two conversations with the same
  instant are always in the same order and a page boundary between them loses nothing.
- **The cursor** of a conversation is `<microseconds>~<id>`: the instant of its last message in Unix microseconds, a `~` and its id.
  It is a position, not a pointer to a row, so it stays right when the conversation receives a message and moves to the top. It is
  opaque to a client; the API accepts only the exact form it writes.
- **`page[before]=<cursor>`:** conversations less recently active than that position (older). The most recent page and the pages
  before a cursor carry `Link: <…page[before]=<cursor of the oldest on the page>>; rel="prev"` when older ones exist.
- **`page[after]=<cursor>`:** more recent ones. The page is read oldest first and turned round, so every page is most recent
  first; its `Link` is `rel="next"`, with the cursor of the most recent conversation of the page.
- `page[size]` is repeated in the `Link` only when it is not 100. A page past the end is `{"conversations":[]}` with no `Link`.
- `firstReceived` and `lastReceived` are Unix seconds with milliseconds as decimals, cut (not rounded) to the millisecond, like the
  reference service.

## The messages

The **text and the order** of a page come from Foundry; everything Foundry gives no item comes from `conversation_messages` through
`foundry_item_map`: the sequence (the message `_id`), the role, the author, the time, the event, the flow and whether the text was
cut.

| Request | Foundry call | Link |
|---|---|---|
| No cursor | `order=desc&limit=<size>`, turned round | `rel="prev"`, `page[before]=<the first message of the page>` |
| `page[before]=<sequence>` | `order=desc&limit=<size>&after=<the cursor's item>`, turned round | same |
| `page[after]=<sequence>` | `order=asc&limit=<size>&after=<the cursor's item>` | `rel="next"`, `page[after]=<the last message of the page>` |

Foundry's `after` follows the order of the listing, which is why the messages **older** than a cursor are `desc` plus `after`. Its
`has_more` says whether a `Link` is due.

- The message `_id` and the cursor are the **sequence** of the event, a plain decimal. Gaps are normal: events that are not chat
  messages take a sequence too.
- A cursor must be a message that is in Foundry. A sequence in a gap, a message of another conversation, and a message that is
  stored but not yet sent are all `invalid-cursor`.
- A message is **not served until it is in Foundry**.
- `metadata.flow` is absent outside any flow. `metadata.truncated` is true when the stored text was cut at the agent's limit.
- An item in Foundry that the item map does not know is an inconsistency: a 500, and the log names the item.

## Errors

Every error is `application/problem+json`, as in the reference service. A client tells problems apart by `type`, never by `detail`.
No detail repeats a value the client sent.

| Status | Type (`tag:yape.com.pe,2026:conversation-history:`…) | When |
|---|---|---|
| 400 | `invalid-request` | An account that is missing or malformed (letters, digits, `. _ : -`, up to 128), a malformed conversation id, both cursors, a parameter sent twice, a `page[size]` outside 1 to 100 or not a plain decimal |
| 400 | `invalid-cursor` | A cursor that is empty, not in the form the API writes, or not a message of this conversation |
| 404 | `conversation-not-found` | The conversation has no chat messages in Foundry. An unknown path is also a 404 (`about:blank`) |
| 405 | `about:blank` | A method the path does not accept |
| 500 | `about:blank` | A bug, or an inconsistency (an item nothing maps). The log has the stack |
| 503 | `about:blank` | A dependency cannot answer: Foundry (a timeout, 401, 403, 408, 429, 5xx, or a 404 for a conversation we map), the token broker, or the database |

The errors never retry: the caller waits. The detail of a 5xx never says what failed; the log does.

**The 404 and 405 of unknown paths** are Camel's own HTML and empty answers by default. `ProblemHandlers.java` puts problem+json in
their place on the router that `platform-http` uses.

**The request's headers** go back on the response unless they are removed: `platform-http` copies the message's headers to it, and
Camel turns every query parameter into a header. Two things followed. The API echoed the client's own headers (`X-Custom`,
`X-Api-Key`, ...) and its query parameters (`idYapeAccount: a`). And the HTTP layer fails the whole response, with a plain-text
500, when a header holds a line break or a NUL (`?x=a%0Ab`) or has square brackets in its name (`page[before]`), an error answer
included. `ApiRequest`, `ProblemResponder` and the first step of the health route remove every header that is not Camel's
(`Camel*`), after `ApiRequest` has read the query from the raw string. The tests that found it are in
`tests/camel/api/src/test/java/ApiRoutesTest.java` (`theResponseDoesNotEchoTheRequestsHeadersOrItsQueryParameters` and three more).

## Who can call it

**Nobody is authenticated.** Like the reference service, this is a PoC: the contract says so (`docs/contract/`, "there is no
authentication, so it must not be deployed"). It trusts what it is given:

- `GET /v1/conversations` takes the account from the `idYapeAccount` query parameter, as sent.
- `GET /v1/conversations/{id}/messages` takes **no account at all**: whoever knows a conversation id reads its messages. The ids
  (`conv_v1_<uuid>`) cannot be guessed, but they are in every list answer, in the `Link` headers and in the dead-letter log.

So a deployment needs a gateway in front that binds `idYapeAccount` to the caller, and that cannot enforce ownership on
`/messages` unless it keeps its own conversation-to-account mapping or asks the list first. If that gap matters, the fix is an
optional `idYapeAccount` on `/messages` that must match the conversation's (404 on a mismatch): a contract change, so not made here.

Karavan (`9998`) and its image registry (`5555`) are published on `127.0.0.1` only (`docker-compose.yml`). The three services are
**not**: `8086` (API), `8084` (sync) and `8081` (consumer) listen on all interfaces, so anyone on the same network reaches them.
Karavan's compose parser reads a port as `host:container` and fails on `127.0.0.1:8086:8080`, so a project's `docker-compose.yaml`
cannot bind to the loopback. Close them with the host's firewall, or put the API behind a gateway and do not expose it otherwise.

## Differences from the reference service

The contract is the same and the tests check every response against it. These are the places where this service behaves
differently, on purpose:

| | Reference service | This service | Why |
|---|---|---|---|
| Where a message comes from | Postgres | Foundry (the text), Postgres (the rest) | The point of the exercise |
| A conversation or message not yet in Foundry | Listed and served | Not listed, not served | The list and the messages must agree with what Foundry holds |
| A dependency that cannot answer | A 503 for a timeout, otherwise 500 | 503 for Foundry, the broker and the database | The OpenAPI lists only 500; a 503 is honest. `contract-check.py` allows it |
| Health | The database | The database | Same. Foundry down shows in the messages |

## Settings

| Setting | Default | Means |
|---|---|---|
| `app.db.url`, `app.db.user` | `camel_history` on `db:5432` | The datasource |
| `app.foundry.tokenUrl` | `http://foundry-token:8099/token` | The broker. Not a secret |
| `app.foundry.endpoint` | empty | Empty: the broker's endpoint. Set it to point at another Foundry |
| `app.foundry.timeoutMs` | `10000` | How long a call to Foundry or the broker may take; longer is a 503 |
| `camel.main.shutdownTimeout` | `8` | Seconds Camel waits for requests in flight when the container stops (Docker kills it after 10). Not an `app.*` setting |

## Test it

```bash
./scripts/test-api.sh                   # 273 checks; every response is recorded and checked against the OpenAPI
./scripts/test-api.sh messages          # one section
./scripts/oracle-api.sh                 # the Karavan-run API against SQL on the data, for every account (read-only)
./scripts/test-e2e.sh                   # a real producer flow through the whole chain, timed (needs the VPN and the agent)
```

`test-api.sh` starts the project with the DevMode image and calls it from inside its container, against the fake Foundry. Its
`checker` section tests the contract check itself with broken responses it must reject.
