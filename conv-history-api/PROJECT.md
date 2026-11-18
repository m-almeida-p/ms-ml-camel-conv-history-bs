# conv-history-api

Serves the conversation history with the **same API as `ms-ml-conv-history-bs`** (the contract is `docs/contract/`, unchanged),
reading the messages from the Microsoft Foundry Conversations API. The text and the order come from Foundry; the time, the
author, the event and the flow, which Foundry does not keep, come from Postgres.

Everything below is explained, with diagrams, in [`docs/design-foundry.md`](../docs/design-foundry.md) and
[`docs/conv-history-api.md`](../docs/conv-history-api.md).

## Three endpoints, each a `rest` verb and its route in one file

| Endpoint | Route | Steps |
|---|---|---|
| `GET /health` | **Health** | 1.1 Ask the database |
| `GET /v1/conversations` | **Conversations** | 1.1 Read and check the request, 1.2 Page, 1.3 Build the answer |
| `GET /v1/conversations/{id}/messages` | **Messages** | 1.1 Read and check, 1.2 Find it in Foundry, 1.3 Is it there?, 1.4 Is there a cursor?, 1.5 Read the page from Foundry, 1.6 Build the answer |

Any refusal or failure goes to the error rules `apiErrors` and is answered as `application/problem+json`: 4xx for a refusal, 503
when Foundry, the token broker or the database cannot answer, 500 for a bug.

## Key

- **Numbers** are the same in the Designer, the docs and the logs.
- **Note** says why. **Docs:** at the end of a note points to the section that explains it.

## Files

| File | Holds |
|---|---|
| `endpoint-health.camel.yaml`, `endpoint-conversations.camel.yaml`, `endpoint-messages.camel.yaml` | One endpoint each: its `rest` verb and its route, together |
| `route-error-handling.camel.yaml` | The error rules `apiErrors` |
| `ApiRequest.java` | Reads and checks the parameters from the raw query string; removes the `page[...]` headers |
| `ApiProblemException.java`, `ProblemResponder.java` | A problem, and the response built from it |
| `ProblemHandlers.java` | 404 and 405 of unknown paths and methods as problem+json |
| `ConversationList.java`, `MessagePage.java` | Build the two answers |
| `FoundryReader.java`, `FoundryUnavailableException.java` | Read a page of items from Foundry |
| `application.properties` | Settings (`app.*`), dependencies, datasource |

A `rest` verb and its route share a file because Karavan's Designer opens a file as an integration only when it holds a route; and the
verb's `to` is a plain string because its REST tab renders only that form.
