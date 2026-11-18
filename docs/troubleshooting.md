# Troubleshooting

Every entry here is a problem that actually happened while setting this up.
Format: symptom → cause → fix.

Quick triage:

```bash
docker ps -a --format '{{.Names}}\t{{.Status}}'      # what is running, and is it healthy
docker logs karavan --tail 80                        # Karavan server errors (the UI hides most causes)
docker logs conv-history-consumer --tail 80          # the consumer's own log
```

When the UI shows only a vague popup, **read `docker logs karavan`**. The real
reason is almost always there.

---

## Starting Karavan

### `network yape-local declared as external, but could not be found`
**Cause:** the shared cluster is not running, so its network does not exist.
**Fix:** `../cluster/scripts/up.sh`, then `./scripts/up.sh`.

### Karavan starts but cannot reach Git
**Cause:** `GITHUB_MALMEIDAP_PAT` is empty or `.env` is missing. `up.sh` warns
about this.
**Fix:** `cp .env.example .env`, set the token (fine-grained PAT for this repo,
*Contents: read and write*), then `docker compose up -d karavan`.

### Port already in use / container name conflict
**Cause:** 9998 (UI) or 5555 (registry) is taken, or another stack uses the
fixed names `karavan`, `karavan-db`, `karavan-registry`.
**Fix:** change `KARAVAN_PORT` / `KARAVAN_REGISTRY_PORT` in `.env`. For name
clashes, stop the other stack.

---

## Running a project (DevMode)

### "Error Starting DevMode container" / `pull access denied`
Log (`docker logs karavan`):
```
Status 404: pull access denied for apache/camel-karavan-devmode,
repository does not exist or may require 'docker login'
```
**Cause:** Karavan's default DevMode image is `apache/camel-karavan-devmode`
on Docker Hub, which does not exist. The image is published on GitHub's
registry, next to the Karavan image.
**Fix:** `docker-compose.yml`, service `karavan`:
```yaml
KARAVAN_DEVMODE_IMAGE: ghcr.io/apache/camel-karavan-devmode:4.22.2
```
Keep the tag equal to the Karavan version. Recreate Karavan:
`docker compose up -d karavan`. Projects and the UI session survive because
state is in the Postgres volume.
Verify an image exists before using it: `docker manifest inspect ghcr.io/apache/camel-karavan-devmode:<tag>`.

### No **Run** button after pressing Stop
**Cause:** after a stop, the header shows only Stop and a trash icon.
**Fix:** use the **Containers** tab, which has **Run**, **Stop** and **Delete**.

### My change is saved but the running container behaves the old way
**Cause:** DevMode copies the project files into the container when it is
created. A stopped container keeps the old copy.
**Fix:** Containers tab → **Stop** → **Delete** → **Run**.

### Header shows a spinner and the container list is empty
**Cause:** the UI polls Karavan every few seconds, and button references go
stale.
**Fix:** reload the page. Check the truth with `docker ps -a`.

---

## The consumer

### Message received, then `MultipleCompilationErrorsException ... LHS of an assignment should be a variable`
**Cause:** `application.properties` has `camel.main.logLanguage=groovy`
(Karavan's template default). Every `log` message is then a Groovy script, and
`Received ... topic=${header...}` is not valid Groovy.
**Fix:** set `camel.main.logLanguage=simple`. The alternative is to write every
message as a Groovy expression, which is harder to read. Recreate the
container.

### Log line prints but values are empty: `topic= partition= offset= key=`
**Cause:** wrong header names. Camel 4 uses `CamelKafkaTopic`,
`CamelKafkaPartition`, `CamelKafkaOffset`, `CamelKafkaKey`,
`CamelKafkaTimestamp`. The old `kafka.TOPIC` forms resolve to empty text and do
not raise an error.
**Fix:** use `${header.CamelKafkaTopic}` etc. To discover names for any
component, read its `*Constants` class in the jar, or log `${headers}` once.

### Container shows `(unhealthy)` but the consumer works
Healthcheck: `curl -f http://localhost:9876/q/observe/health`.
**Cause:** Camel's management server is off by default, so nothing listens on
9876. Health was served only on port 8080 at `/observe/health`.
**Fix:** in `application.properties`:
```
camel.management.enabled=true
camel.management.port=9876
camel.management.path=/q
```
Recreate the container; it reports `(healthy)` after about 25 seconds.
Confirm: `docker exec conv-history-consumer curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9876/q/observe/health` → `200`.
The names come from Camel's `camel-main-configuration-metadata.json`. To check
a property, read that file from the `camel-main` jar.

### I fixed the problem but the message is not processed again
**Cause:** the group committed the offset even though the log step failed, so
the message counts as read.
**Fix:** rewind the group (see the [cheatsheet](cheatsheet.md#consumer-group-offsets)),
or publish a new test record.

### `Assignments can only be reset if the group ... is inactive`
**Cause:** Kafka still counts the stopped container as a member until its
session timeout (45 s) expires. `--describe --state` shows `Stable` until then.
**Fix:** stop the container and wait until the state is `Empty`, then retry.

### Consumer joined the group but no partitions get records
**Cause:** the topic holds nothing newer than the committed offsets. Earliest
and latest offsets can even be equal (retention removed old records).
**Fix:** publish a test record. Check with
`kafka-run-class kafka.tools.GetOffsetShell ... --time -2` (earliest) and
`--time -1` (latest).

### `Failed delivery ... On delivery attempt: N caught: ...` repeating
**Cause:** a record failed and the consumer is retrying it. Read the exception after `caught:`.
- `CannotGetJdbcConnectionException`, `Connection refused`, `schema id N is not available from the schema registry`:
  a **transient** failure. The consumer retries forever, with a growing wait, and moves on when the database or registry is
  back. Nothing is lost and nothing is dead-lettered. Fix the dependency.
- Anything else (`BadSqlGrammarException`, `NullPointerException`, ...): an **unexpected** error. It is tried 3 more times,
  then dead-lettered with `reason=unexpected` and the exception class in `field=`. A burst of those lines is a bug or a
  wrong setting (for example a wrong `app.db.url`, which gives `relation ... does not exist`).

### `DLQ reason=unexpected` for every record
**Cause:** a bug or a setting error that hits all records, such as a missing table or a wrong schema in `app.db.url`.
**Fix:** correct it, restart the container, then replay the records: their offsets are in the lines, and the group can be
rewound (see the [cheatsheet](cheatsheet.md#consumer-group-offsets)).

### `Failed to get driver instance for jdbcUrl=...`
**Cause:** DevMode loads the Postgres driver in its own classloader, where `java.sql.DriverManager` cannot discover it.
**Fix:** name it: `camel.beans.pgDataSource.driverClassName=org.postgresql.Driver`.

### `ClassNotFoundException: ConversationEventDecoder` at startup
**Cause:** `camel.beans.<name>=#class:...` is applied before the project's Java files are compiled, so a class from
those files cannot be found there.
**Fix:** register the class from inside its file with `@BindToRegistry("name")`, and read settings from the Camel
properties at first use, not from `camel.beans.*`.

### `ClassNotFoundException: PoisonRecordException` in an `onException`
**Cause:** an `onException` resolves the exception class by name before the Java files are compiled.
**Fix:** make the exception extend a built-in class and match that one: `PoisonRecordException extends
org.apache.camel.ValidationException`, and the route lists `org.apache.camel.ValidationException`. `ValidationException`
is a checked exception, so methods that throw it declare `throws PoisonRecordException`.

### `Node should have only have 1 key, was: 4 keys: [id,exception,handled,steps]`
**Cause:** in a `routeConfiguration`, each entry of `onException` must be wrapped as its own `- onException:` node.
**Fix:** `onException:` → `- onException:` → `id`, `exception`, `handled`, `steps` indented under it.

### `YAML DSL compact notation detected`
**Cause:** a warning only. A shorthand such as `simple: "..."` or `constant: "true"` was used.
**Fix:** write it canonically (`simple: {expression: "..."}`), which Karavan's Designer also prefers.

### The log says `Fetching project null files from Platform ... ConnectException`
**Cause:** printed by `scripts/devmode-local.sh`. The DevMode image tries to download the project from Karavan first, and
without a Karavan project id it falls back to the folder it was given.
**Fix:** none needed.

### The local runner starts with `Routes startup (total:0)`
**Cause:** the project folder was not visible in the container. A folder under the system temp directory is not shared
with the Docker VM.
**Fix:** `scripts/devmode-local.sh` copies the project to `.devmode-local/` inside the repo (git-ignored), which is
shared. If you change the script, keep the copy inside the repo.

### A test script waits forever, or says the consumer did not join the group
**Cause:** `scripts/common.sh` sets `pipefail`, and `docker logs | grep -q` then fails with a SIGPIPE status even when it
matches.
**Fix:** read the output into a variable and match it there (`grep -q ... <<< "$out"`), as `log_has` does in the test
scripts.

### `Error getting Pod Events: namespace cannot be null` in Karavan's log
**Cause:** Karavan's Kubernetes service runs a check that makes no sense when
running on Docker.
**Fix:** none needed. It is noise.

### `Registry request failed https://registry:5000/v2/: Failed to create SSL connection`
**Cause:** Karavan queries the local registry over HTTPS, but `registry:2`
serves plain HTTP.
**Impact:** only the *Images* list and *Build/Deploy*. **Run (DevMode) is
unaffected.**
**Fix:** none applied. A proper fix needs a TLS-enabled registry.

---

## Editing in the Karavan UI

### Typing into the code editor scrambles my text
**Cause:** the editor re-parses and reformats the file on every keystroke and
moves the cursor, and its autocomplete and auto-closing brackets interfere.
Long single-line text comes out cut up and repeated.
**Fix:** **paste** instead of typing. Put the whole file on the clipboard, click
in the editor, `Cmd+A`, `Cmd+V`. Short edits to a plain value (such as one
property) type fine.
Tip: Karavan rewrites long strings as folded blocks (`message: >-`). That is
equivalent YAML.

### **Upload** does not replace a file that already exists
**Cause:** Karavan's Upload dialog adds new files and silently ignores one whose name is taken.
**Fix:** delete the file in the Source tab, then upload it again. `application.properties` and `docker-compose.yaml`
cannot be deleted in the UI: change `application.properties` in its editor (paste the whole file), or push from Git and
press **Pull**.

### My edit in the Designer form did not change the file
**Cause:** a value set programmatically did not trigger the form's change
handler.
**Fix:** edit in the **Code** tab and paste, or type the value into the field by
hand.

### Karavan re-sorts lines in `application.properties`
**Cause:** it normalizes the file when you edit it.
**Fix:** none needed. Order does not matter in a properties file.

---

## Git and Karavan

### **Push** is disabled
**Cause:** it needs files selected.
**Fix:** tick the files (header checkbox selects all), then Push.

### Karavan's commits show `admin <admin@platform.platform>`
**Cause:** that is the identity Karavan uses for its own commits.
**Fix:** none. Your own commits (docs, compose, scripts) use your Git identity.

### My local clone is behind after a Karavan push
**Fix:** `git pull --ff-only`. If you have local commits that Karavan has not
seen, push them, then press **Pull** in Karavan.

### `docs/` or `scripts/` appear as projects in Karavan
**Cause:** Karavan treats each top-level folder of the repository as a project.
**Fix:** ignore them. Do not push changes into them from Karavan.

---

## Reset everything

Remove Karavan and its database. Projects are safe in Git:

```bash
./scripts/clean.sh
docker rm -f conv-history-consumer 2>/dev/null     # DevMode containers are not removed by clean.sh
./scripts/up.sh
```
