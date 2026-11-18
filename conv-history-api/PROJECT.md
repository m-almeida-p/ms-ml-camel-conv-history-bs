# conv-history-api

Serves the conversation history with the same API as `ms-ml-conv-history-bs`, reading the messages from the Microsoft
Foundry Conversations API. Built slice by slice; this file lists what exists so far.

| File | Holds |
|---|---|
| `rest-api.camel.yaml` | The REST endpoints |
| `route-health.camel.yaml` | `GET /health` |
| `ProblemHandlers.java` | 404 and 405 as `application/problem+json` |
| `application.properties` | Settings (`app.*`), dependencies, datasource |
