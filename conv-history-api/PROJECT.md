# conv-history-api

Serves the conversation history with the same API as `ms-ml-conv-history-bs`, reading the messages from the Microsoft
Foundry Conversations API. Built slice by slice; this file lists what exists so far.

| File | Holds |
|---|---|
| `endpoint-<name>.camel.yaml` | One endpoint each: its `rest` verb and its route, together (the Designer opens a file as an integration only if it holds a route) |
| `ProblemHandlers.java` | 404 and 405 as `application/problem+json` |
| `application.properties` | Settings (`app.*`), dependencies, datasource |
