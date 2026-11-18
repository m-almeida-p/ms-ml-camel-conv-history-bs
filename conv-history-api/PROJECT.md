# conv-history-api

Serves the conversation history with the same API as `ms-ml-conv-history-bs` (contract: `docs/contract/`, unchanged),
reading the messages from the Microsoft Foundry Conversations API. Built slice by slice; this file lists what exists.

| File | Holds |
|---|---|
| `endpoint-health.camel.yaml` | `GET /health`: its `rest` verb and its route |
| `endpoint-conversations.camel.yaml` | `GET /v1/conversations` |
| `endpoint-messages.camel.yaml` | `GET /v1/conversations/{id}/messages` |
| `route-error-handling.camel.yaml` | The error rules: a refusal is a 4xx, a dependency down is 503, a bug is 500, all problem+json |
| `ApiRequest.java` | Reads and checks the parameters, from the raw query string |
| `ApiProblemException.java`, `ProblemResponder.java` | A problem, and the response built from it |
| `ProblemHandlers.java` | 404 and 405 of unknown paths and methods as problem+json |
| `application.properties` | Settings (`app.*`), dependencies, datasource |

Each endpoint file has its `rest` verb and its route together: Karavan's Designer opens a file as an integration
only when it holds a route, and its REST tab renders a verb only when `to` is a plain string.
