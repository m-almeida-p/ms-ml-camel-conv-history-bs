# Karavan setup

How Apache Camel Karavan runs in this repository, and how it was set up.

Karavan is a visual designer for Camel integrations. You draw routes in a web
UI; it stores them as YAML in this Git repository and can run them in a
container on your machine ("DevMode").

## Architecture

```
                         your browser  ──►  http://localhost:9998
                                                  │
 ┌───────────────────── docker network: yape-local (created by ../cluster) ─────────────────────┐
 │                                                                                              │
 │  karavan  ───────────► karavan-db   (Postgres 18: Karavan's own state, volume karavan_postgres_data)
 │  (ghcr.io/apache/camel-karavan:4.22.2)                                                       │
 │     │  ─ Git over HTTPS ─► GitHub  (projects live in this repo; the token comes from .env)   │
 │     │  ─ /var/run/docker.sock ─► starts DevMode containers on your Docker engine             │
 │     │                                                                                        │
 │     └─ starts ─► conv-history-consumer  (ghcr.io/apache/camel-karavan-devmode:4.22.2)        │
 │                       └─ reads Kafka as kafka:29092 ──► yape-kafka (from ../cluster)         │
 │                                                                                              │
 │  registry (registry:2, host port 5555)  — target for images that Karavan builds             │
 └──────────────────────────────────────────────────────────────────────────────────────────────┘
```

Three services in `docker-compose.yml`:

| Service | Image | Purpose | Host port |
|---|---|---|---|
| `karavan` | `ghcr.io/apache/camel-karavan:4.22.2` | The designer and its API | 9998 |
| `karavan-db` | `postgres:18` | Karavan's database. Not published on the host. | none |
| `registry` | `registry:2` | Local image registry for Karavan builds | 5555 |

## Prerequisites

1. **Docker** running.
2. **The shared cluster up**, because Karavan joins its network and reaches
   Kafka through it:
   ```bash
   ../cluster/scripts/up.sh
   ```
   Without it, `docker compose up` fails with
   `network yape-local declared as external, but could not be found`.
3. **A GitHub token** so Karavan can read and write this repository: a
   fine-grained personal access token limited to this repo with
   *Contents: read and write*.

## First-time setup

```bash
cp .env.example .env      # .env is git-ignored
```

Edit `.env` and set `GITHUB_MALMEIDAP_PAT` to the token. The other values in
`.env.example` have working defaults.

```bash
./scripts/up.sh           # checks Docker, the yape-local network and the token, then starts the stack
```

First start pulls images and takes about a minute. Open
<http://localhost:9998> and log in. The login credentials are not stored in
this repository.

Karavan is ready when `docker logs karavan` shows `karavan 4.22.2 on JVM ...
started` and `Projects loaded`.

## What each setting does

All in `docker-compose.yml`, service `karavan`:

| Variable | Value | Why |
|---|---|---|
| `KARAVAN_GIT_REPOSITORY` / `_USERNAME` / `_BRANCH` | from `.env` | Where projects are stored. |
| `KARAVAN_GIT_PASSWORD` | `${GITHUB_MALMEIDAP_PAT}` | The token. It is never written in the compose file. |
| `KARAVAN_DOCKER_NETWORK` | `yape-local` | Containers Karavan starts join the cluster network, so they resolve `kafka`, `redis` and the rest by service name. |
| `KARAVAN_DEVMODE_IMAGE` | `ghcr.io/apache/camel-karavan-devmode:4.22.2` | **Required.** Karavan's built-in default (`apache/camel-karavan-devmode`) does not exist on Docker Hub, so *Run* fails. See [troubleshooting](troubleshooting.md#error-starting-devmode-container--pull-access-denied). Keep its tag equal to the Karavan version. |
| `KARAVAN_CONTAINER_IMAGE_REGISTRY` | `registry:5000` | Where builds are pushed. |
| `KARAVAN_DATASOURCE_*` | `karavan` / `karavan` | Credentials for `karavan-db`. Local only, not exposed on the host. |

The mount `/var/run/docker.sock:/var/run/docker.sock` gives Karavan control of
your Docker engine. That is how it starts containers, and it means **anyone
who can use the Karavan UI is effectively root on this machine**. Do not expose
port 9998 beyond localhost.

## How Karavan and Git work together

- Each **top-level folder** in the repository is a Karavan **project**
  (`conv-history-consumer/` here). Karavan loads projects from Git at startup
  and when you press **Pull**.
- Edits in the UI are saved to Karavan's database first and show status `NEW`
  or *changed*. They are **not in Git** until you push.
- To commit: open the project, **Source** tab, tick the files (use the
  header checkbox to select all), click **Push**, enter a message. **Push stays
  disabled until at least one file is ticked.**
- Karavan commits as `admin <admin@platform.platform>`.
- After a push, update your local clone: `git pull --ff-only`.
- Because state is in Git, `./scripts/clean.sh` is safe: it removes containers
  and the Postgres volume, and the projects come back from Git.

> Folders that are not Karavan projects (`docs/`, `scripts/`) sit in the same
> repository. If Karavan lists them as projects after a Pull, ignore them or
> delete the entry in the UI; do not push changes into them from Karavan.

## Day-to-day scripts

| Script | Effect |
|---|---|
| `./scripts/up.sh` | Create and start the stack (checks prerequisites first). |
| `./scripts/stop.sh` | Stop containers; keep them and their data. |
| `./scripts/start.sh` | Start containers created earlier. |
| `./scripts/logs.sh` / `logs.sh -f` | Save logs to `logs_<timestamp>.txt` (git-ignored) / follow them. |
| `./scripts/clean.sh` | Remove containers **and** the Postgres volume. Projects stay in Git. |

DevMode containers started by Karavan (such as `conv-history-consumer`) are
managed from the Karavan UI, not by these scripts. `clean.sh` does not remove
them.

Development aids (they do not use Karavan; see the [consumer guide](conv-history-consumer.md#change-it)):

| Script | Effect |
|---|---|
| `./scripts/devmode-local.sh <project> [NAME=value ...]` | Run a project folder of this repo in the DevMode image, on the cluster network. `stop <project>` removes it. |
| `./scripts/test-consumer.sh` | End-to-end test of `conv-history-consumer` on a throwaway topic (37 checks). |
| `./scripts/parity-check.sh` | Compare what the consumer wrote with the original consumer's tables. |

## Files Karavan generates in a project

When you create a project, Karavan adds template files. For
`conv-history-consumer`:

| File | Notes |
|---|---|
| `application.properties` | Camel settings, dependencies, the datasource. Changed from the template; see the [consumer guide](conv-history-consumer.md#applicationproperties-changes-from-the-template). |
| `route-receive.camel.yaml`, `route-store.camel.yaml`, `route-error-handling.camel.yaml` | The three routes: Receive, Store, Dead-letter (with the error rules). |
| `*.java` | Small Java helpers (decoder, store outcome, offset commit). Karavan keeps `.java` files in the project like any other file, and DevMode compiles them at startup. |
| `docker-compose.yaml` | Generated for the *Deploy* feature. It uses network `karavan` and host port 8081, which do not match this setup. DevMode does not use it; ignore it unless you use Deploy. |
| `PROJECT.md` | Empty project notes. |

The "Kafka" starter also generates `route-processing`, `route-send` and
`default-error-handler`. They were demo routes unrelated to the consumer and
were deleted.

## Rebuilding from scratch

1. `../cluster/scripts/up.sh`
2. `cp .env.example .env` and set the token.
3. `./scripts/up.sh`
4. Open <http://localhost:9998>, log in, open `conv-history-consumer`.
5. Click **Run at the top right of the page** (not the Run of the Containers tab; see
   [troubleshooting](troubleshooting.md#which-button-does-what)).
