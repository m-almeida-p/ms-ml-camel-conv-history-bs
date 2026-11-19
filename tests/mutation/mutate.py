#!/usr/bin/env python3
"""Mutation experiment: change ONE condition of the code, run the JUnit tests of that module, and report whether any test noticed.

A mutation that leaves every test green ("SURVIVED") is a test that is missing. Run it through tests/mutation/run.sh, which does it
in a COPY of the repo, so the real files are never changed.

    python3 tests/mutation/mutate.py <root of a copy of the repo> [mutation numbers...]

Each mutation is (name, file, exact text to find, replacement, JUnit module, test classes). The text must occur exactly once; when
the code changes and it no longer does, the mutation is reported as SKIPPED and should be updated. "COMPILE ERROR" means the mutation
itself was invalid; "NO TESTS RAN" means the experiment is broken (see tests/mutation/README in docs/testing.md).
Last full run (2026-11-18): 25 of 25 killed, after one test was added for the survivor (has_more) and one invalid mutation redone.
"""
import subprocess, sys, shutil, re
from pathlib import Path
ROOT = Path(sys.argv[1])
M = [
 ("ApiRequest: id length 128 -> 129", "conv-history-api/ApiRequest.java", "{1,128}$\");\n    private static final Pattern WHOLE", "{1,129}$\");\n    private static final Pattern WHOLE", "api", "ApiRequestTest"),
 ("ApiRequest: stop dropping request headers", "conv-history-api/ApiRequest.java", 'exchange.getMessage().removeHeaders("*", "Camel*");\n        return query;', 'return query;', "api", "ApiRoutesTest"),
 ("ConversationList: more = size() >= size", "conv-history-api/ConversationList.java", "boolean more = rows.size() > size;", "boolean more = rows.size() >= size;", "api", "ConversationListTest,ApiRoutesTest"),
 ("ConversationList: cursor micros truncation", "conv-history-api/ConversationList.java", "instant.getNano() / 1000)", "instant.getNano() / 1_000_000 * 1000)", "api", "ConversationListTest,ApiRoutesTest"),
 ("Conversations SQL: before uses <= ", "conv-history-api/endpoint-conversations.camel.yaml", "AND (s.last_occurred_at, s.conversation_id) <\n", "AND (s.last_occurred_at, s.conversation_id) <=\n", "api", "ApiRoutesTest"),
 ("Conversations SQL: tiebreak id ASC in newest", "conv-history-api/endpoint-conversations.camel.yaml", "ORDER BY s.last_occurred_at DESC, s.conversation_id DESC\n                        LIMIT", "ORDER BY s.last_occurred_at DESC, s.conversation_id ASC\n                        LIMIT", "api", "ApiRoutesTest"),
 ("FoundryReader: 404 no longer unavailable", "conv-history-api/FoundryReader.java", "status == 401 || status == 403 || status == 404 || status == 408", "status == 401 || status == 403 || status == 408", "api", "FoundryReaderTest,ApiRoutesTest"),
 ("FoundryReader: 429 not unavailable", "conv-history-api/FoundryReader.java", "status == 408 || status == 429 || status >= 500", "status == 408 || status >= 500", "api", "FoundryReaderTest"),
 ("FoundryReader: 401 does not drop the token", "conv-history-api/FoundryReader.java", "        if (status == 401) {\n            invalidateToken();\n        }\n", "", "api", "FoundryReaderTest"),
 ("ProblemResponder: IOException not a dependency", "conv-history-api/ProblemResponder.java", "if (t instanceof IOException || t instanceof UncheckedIOException)", "if (t instanceof UncheckedIOException)", "api", "ProblemResponderTest,ApiRoutesTest"),
 ("MessagePage: Link uses last instead of first", "conv-history-api/MessagePage.java", '"page[before]=" + first', '"page[before]=" + last', "api", "ApiRoutesTest"),
 ("FoundryClient: always send (no adoption)", "conv-history-sync/FoundryClient.java", "        if (!adoptedCurrent) {\n            ObjectNode body", "        if (true) {\n            ObjectNode body", "sync", "FoundryClientTest"),
 ("FoundryClient: role ignored when matching", "conv-history-sync/FoundryClient.java", "if (!(\"appUser\".equals(role) ? \"user\" : \"assistant\").equals(itemRole)) {", "if (false) {", "sync", "FoundryClientTest"),
 ("FoundryClient: late event uses <=", "conv-history-sync/FoundryClient.java", "if (current < ((Number) mapRow.get(\"last_synced_sequence\")).intValue())", "if (current <= ((Number) mapRow.get(\"last_synced_sequence\")).intValue())", "sync", "FoundryClientTest"),
 ("FoundryClient: has_more not a mismatch", "conv-history-sync/FoundryClient.java", 'boolean mismatch = list.path("has_more").asBoolean(false);', 'boolean mismatch = false;', "sync", "FoundryClientTest"),
 ("FoundryClient: rebuild forgets the half-built one", "conv-history-sync/FoundryClient.java", "        if (half != null) {\n            call(exchange, \"DELETE\"", "        if (false) {\n            call(exchange, \"DELETE\"", "sync", "FoundryClientTest"),
 ("FoundryClient: 429 becomes a refusal", "conv-history-sync/FoundryClient.java", "status == 408 || status == 429 || status >= 500", "status == 408 || status >= 500", "sync", "FoundryClientTest"),
 ("Decoder: sequence upper bound >= ", "conv-history-consumer/ConversationEventDecoder.java", "sequence > Integer.MAX_VALUE", "sequence >= Integer.MAX_VALUE", "consumer", "DecoderTest"),
 ("Decoder: framed check back to schemaId>=0", "conv-history-consumer/ConversationEventDecoder.java", "if (framed && !allowedSchemaIds", "if (schemaId >= 0 && !allowedSchemaIds", "consumer", "DecoderTest"),
 ("Decoder: user without account is projectable", "conv-history-consumer/ConversationEventDecoder.java", 'role.equals("appUser") && idYapeAccount.isEmpty()', 'false', "consumer", "DecoderTest,StoreRouteTest"),
 ("Decoder: truncated must be boolean dropped", "conv-history-consumer/ConversationEventDecoder.java", "!truncatedNode.isNull() && !truncatedNode.isBoolean()", "false", "consumer", "DecoderTest"),
 ("Store: summary counts on every conflict", "conv-history-consumer/route-store.camel.yaml", "FROM msg WHERE is_new AND id_yape_account IS NOT NULL", "FROM msg WHERE id_yape_account IS NOT NULL", "consumer", "StoreRouteTest"),
 ("Store: LEAST -> GREATEST for first time", "conv-history-consumer/route-store.camel.yaml", "first_occurred_at = LEAST(", "first_occurred_at = GREATEST(", "consumer", "StoreRouteTest"),
 ("StoreOutcome: conflict treated as duplicate", "conv-history-consumer/StoreOutcome.java", "} else if (same) {", "} else if (true) {", "consumer", "StoreRouteTest"),
 ("StoreRefusal: always unknown", "conv-history-consumer/StoreRefusal.java", "if (t instanceof SQLException sql && sql.getSQLState() != null) {", "if (false) {", "consumer", "StoreRouteTest"),
]
only = sys.argv[2:] 
results = []
for i, (name, path, old, new, module, tests) in enumerate(M):
    if only and str(i) not in only: continue
    f = ROOT / path; orig = f.read_text()
    if orig.count(old) != 1:
        results.append((name, "SKIPPED: pattern not unique/found (%d)" % orig.count(old))); continue
    f.write_text(orig.replace(old, new))
    try:
        p = subprocess.run(["./scripts/test-camel.sh", module, tests], cwd=ROOT, capture_output=True, text=True, timeout=900)
        out = p.stdout + p.stderr
        m = re.search(r"(\d+) tests, (\d+) failed, (\d+) errors", out)
        comp = "COMPILATION ERROR" in out
        if comp: status = "COMPILE ERROR (mutation invalid)"
        elif m and int(m.group(1)) == 0: status = "NO TESTS RAN (experiment invalid)"
        elif m: status = ("KILLED (%s failed, %s errors)" % (m.group(2), m.group(3))) if (int(m.group(2)) + int(m.group(3))) else "SURVIVED (all %s tests green)" % m.group(1)
        else: status = "UNKNOWN"
    finally:
        f.write_text(orig)
    results.append((name, status)); print(i, name, "->", status, flush=True)
print("\nSUMMARY")
for n, s in results: print(f"{s:45} {n}")
