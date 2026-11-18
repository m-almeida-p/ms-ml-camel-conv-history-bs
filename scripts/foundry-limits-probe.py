#!/usr/bin/env python3
"""Measures what the real Microsoft Foundry Conversations API does at its edges: throttling, limits, and what it returns.

    python3 -I scripts/foundry-limits-probe.py [--quick]      (or --cleanup-only: only delete what an earlier run left)

The documentation says nothing about rate limits, retention or the size of an item (see docs/foundry-setup.md), so this
measures them against the real project of .env. Everything it creates is fake, carries metadata.source = "limits-probe",
and is deleted when it ends (also on failure). It is polite: bursts ramp up and STOP at the first 429 or 5xx, which are
reported with their headers. The token comes from the service principal in .env and is never printed.
Standard library only. --quick skips the 1000-item conversation and the largest texts.
"""
import json
import statistics
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
QUICK = "--quick" in sys.argv
SOURCE = "limits-probe"
created = []          # conversation ids to delete at the end
all_status = {}       # every status seen, across the whole run


def env(name):
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        if line.startswith(name + "="):
            return line.split("=", 1)[1]
    sys.exit(f"{name} is not set in .env")


ENDPOINT = env("FOUNDRY_PROJECT_ENDPOINT").rstrip("/")


def get_token():
    body = urllib.parse.urlencode({"client_id": env("FOUNDRY_CLIENT_ID"), "client_secret": env("FOUNDRY_CLIENT_SECRET"),
                                   "scope": "https://ai.azure.com/.default", "grant_type": "client_credentials"}).encode()
    with urllib.request.urlopen(urllib.request.Request(f"https://login.microsoftonline.com/{env('FOUNDRY_TENANT_ID')}/oauth2/v2.0/token", data=body), timeout=20) as r:
        return json.load(r)["access_token"]


TOKEN = get_token()


def call(method, path, body=None, timeout=60):
    """Returns (status, parsed body or text, headers, seconds). Never raises on an HTTP status."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(ENDPOINT + path, data=data, method=method,
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            status, raw, headers = r.status, r.read(), dict(r.headers)
    except urllib.error.HTTPError as e:
        status, raw, headers = e.code, e.read(), dict(e.headers)
    except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as e:
        return 0, f"{type(e).__name__}: {e}", {}, time.time() - start
    all_status[status] = all_status.get(status, 0) + 1
    try:
        parsed = json.loads(raw) if raw else None
    except ValueError:
        parsed = raw.decode("utf-8", "replace")[:200]
    return status, parsed, headers, time.time() - start


def new_conversation(items=None, metadata=None):
    s, b, _, _ = call("POST", "/openai/v1/conversations", {"metadata": metadata or {"source": SOURCE}, **({"items": items} if items else {})})
    if s == 200:
        created.append(b["id"])
    return s, b


def pct(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * p))] if values else 0


def burst(label, fn, total, workers):
    start = time.time()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        results = list(pool.map(lambda _: fn(), range(total)))
    wall = time.time() - start
    codes, lat, bad = {}, [], None
    for status, headers, secs in results:
        codes[status] = codes.get(status, 0) + 1
        lat.append(secs)
        if status in (429, 500, 502, 503, 504) and bad is None:
            bad = (status, headers)
    print(f"  {label:<34} {total:>4} req, {workers:>2} at once: {total / wall:5.1f} req/s, p50 {pct(lat, .5) * 1000:5.0f} ms, p95 {pct(lat, .95) * 1000:5.0f} ms, max {max(lat) * 1000:5.0f} ms   {dict(sorted(codes.items()))}")
    return codes, bad


def report_throttle(bad):
    status, headers = bad
    interesting = {k: v for k, v in headers.items() if any(w in k.lower() for w in ("retry", "ratelimit", "limit", "remaining", "reset", "request-id", "region"))}
    print(f"    first {status}: headers {interesting}")


def main():
    print(f"endpoint: {ENDPOINT.split('//')[1].split('.')[0]}...  (resource name hidden)\n")

    print("== 1. latency of single calls (20 each, one at a time)")
    reads = [call("GET", "/openai/v1/conversations?limit=1")[3] for _ in range(20)]
    writes = []
    for _ in range(10):
        s, b = new_conversation()
        t0 = time.time(); call("DELETE", f"/openai/v1/conversations/{b['id']}"); writes.append(time.time() - t0); created.remove(b["id"])
    print(f"  list 1 conversation: p50 {pct(reads, .5) * 1000:.0f} ms, p95 {pct(reads, .95) * 1000:.0f} ms;  delete: p50 {pct(writes, .5) * 1000:.0f} ms")

    print("\n== 2. a burst of reads, ramping up; stops at the first 429 or 5xx")
    stop = False
    for workers, total in ((5, 50), (10, 100), (20, 200), (40, 300), (80, 600), (120, 600)):
        codes, bad = burst("GET list conversations", lambda: (lambda r: (r[0], r[2], r[3]))(call("GET", "/openai/v1/conversations?limit=1")), total, workers)
        if bad:
            report_throttle(bad)
            stop = True
            break
    print("  throttled or failed on reads:", "YES (see above)" if stop else "no, up to 120 at once")

    print("\n== 3. a burst of writes (create, then delete); stops at the first 429 or 5xx")
    stop = False
    ids = []
    for workers, total in ((5, 20), (10, 40), (20, 80), (40, 120)):
        def make():
            s, b = new_conversation()
            return (s, {}, 0.0) if s != 200 else (200, {}, 0.0)
        before = len(created)
        codes, bad = burst("POST create conversation", lambda: (lambda r: (r[0], r[2], r[3]))(call("POST", "/openai/v1/conversations", {"metadata": {"source": SOURCE}})), total, workers)
        if bad:
            report_throttle(bad)
            stop = True
            break
    # the ones made by the raw call above are not tracked: find them all by their source and delete them (below)
    print("  throttled or failed on writes:", "YES" if stop else "no, up to 40 at once")

    print("\n== 4. a conversation that grows: 20 items per call")
    s, b = new_conversation()
    cid = b["id"]
    target = 200 if QUICK else 1000
    added, failure, started = 0, None, time.time()
    while added < target:
        s, body, headers, secs = call("POST", f"/openai/v1/conversations/{cid}/items",
                                      {"items": [{"type": "message", "role": "user", "content": f"item {added + i}"} for i in range(20)]})
        if s != 200:
            failure = (s, body, headers)
            break
        added += 20
    print(f"  added {added} items in {time.time() - started:.1f} s" + (f"; STOPPED by {failure[0]}: {str(failure[1])[:160]}" if failure else f"; no limit hit up to {target}"))
    seen, after, pages = [], None, 0
    while True:
        s, body, _, _ = call("GET", f"/openai/v1/conversations/{cid}/items?order=asc&limit=100" + (f"&after={after}" if after else ""))
        if s != 200:
            print(f"  listing failed with {s}")
            break
        pages += 1
        seen += [i["id"] for i in body["data"]]
        if not body["has_more"]:
            break
        after = body["last_id"]
    print(f"  listing it with limit=100: {pages} pages, {len(seen)} items, {len(set(seen))} distinct; the last page said has_more=false: {len(seen) == added}")

    print("\n== 5. the size of one item's text")
    for size in (100_000, 500_000) if QUICK else (100_000, 500_000, 1_000_000, 2_000_000, 4_000_000):
        s, body, _, secs = call("POST", f"/openai/v1/conversations/{cid}/items", {"items": [{"type": "message", "role": "user", "content": "x" * size}]}, timeout=120)
        stored = len(body["data"][0]["content"][0]["text"]) if s == 200 else None
        print(f"  {size:>9} characters: HTTP {s}  {secs:.1f} s" + (f", stored {stored}" if s == 200 else f"  {str(body)[:140]}"))
        if s != 200:
            break

    print("\n== 6. the limits of a conversation's metadata (the docs say 16 pairs, 64-character keys, 512-character values)")
    for label, meta in (("16 pairs", {f"k{i}": "v" for i in range(16)}), ("17 pairs", {f"k{i}": "v" for i in range(17)}),
                        ("key of 64", {"k" * 64: "v"}), ("key of 65", {"k" * 65: "v"}),
                        ("value of 512", {"k": "v" * 512}), ("value of 513", {"k": "v" * 513})):
        s, b = new_conversation(metadata={"source": SOURCE, **meta} if len(meta) < 16 else meta)
        print(f"  {label:<14} HTTP {s}" + ("" if s == 200 else f"  {str(b.get('error', {}).get('message', b))[:100]}"))

    print("\n== 7. does Foundry give text back byte for byte? (create, then read)")
    cases = {
        "plain": "hola, quiero yapear", "emoji": "pago listo 👍🎉", "family emoji (ZWJ)": "👨‍👩‍👧‍👦",
        "composed é": "caf\u00e9", "decomposed é": "cafe\u0301", "hebrew (RTL)": "שלום עולם", "arabic": "مرحبا",
        "cjk": "你好，世界", "tab and newlines": "a\tb\nc\r\nd", "line separator U+2028": "a\u2028b\u2029c",
        "leading/trailing spaces": "  padded  ", "only spaces": "   ", "control chars": "a\u0001\u0007\u001fb", "NUL": "a\u0000b",
        "zero-width": "a\u200bb\u200dc\ufeffd", "backslashes": "C:\\temp\\new \\n \\u0041", "json-looking": '{"a": [1, 2], "b": null}',
        "sql-looking": "'; DROP TABLE conversation_messages; --", "html-looking": "<script>alert(1)</script> &amp;",
        "10k single word": "w" * 10_000, "percent and plus": "100% + 50%",
    }
    s, b = new_conversation()
    uid = b["id"]
    mismatches = []
    for name, text in cases.items():
        s, body, _, _ = call("POST", f"/openai/v1/conversations/{uid}/items", {"items": [{"type": "message", "role": "user", "content": text}]})
        if s != 200:
            mismatches.append((name, f"HTTP {s}: {str(body.get('error', body))[:80]}"))
            continue
        back = body["data"][0]["content"][0]["text"]
        if back != text:
            note = "same after NFC" if unicodedata.normalize("NFC", back) == unicodedata.normalize("NFC", text) else "different"
            mismatches.append((name, f"returned {back[:40]!r} for {text[:40]!r} ({note})"))
    print(f"  {len(cases)} awkward strings sent, {len(cases) - len(mismatches)} returned identical")
    for name, why in mismatches:
        print(f"    DIFFERENT  {name}: {why}")

    print("\n== 8. odd items: what does Foundry accept?")
    for label, item in (("empty text", {"type": "message", "role": "user", "content": ""}),
                        ("role system", {"type": "message", "role": "system", "content": "s"}),
                        ("role developer", {"type": "message", "role": "developer", "content": "d"}),
                        ("role nobody", {"type": "message", "role": "nobody", "content": "n"}),
                        ("no role", {"type": "message", "content": "n"}),
                        ("null content", {"type": "message", "role": "user", "content": None}),
                        ("assistant as a plain string", {"type": "message", "role": "assistant", "content": "plain"}),
                        ("unknown type", {"type": "banana", "role": "user", "content": "x"})):
        s, body, _, _ = call("POST", f"/openai/v1/conversations/{uid}/items", {"items": [item]})
        print(f"  {label:<28} HTTP {s}" + ("" if s == 200 else f"  {str(body.get('error', {}).get('message', body))[:90]}"))
    s, body, _, _ = call("POST", f"/openai/v1/conversations/{uid}/items", {"items": []})
    print(f"  {'an empty list of items':<28} HTTP {s}" + ("" if s == 200 else f"  {str(body.get('error', {}).get('message', body))[:90]}"))

    print("\n== 9. how old is what is here? (retention shows only over days; this shows the oldest conversation now)")
    s, body, _, _ = call("GET", "/openai/v1/conversations?limit=100&order=asc")
    oldest = [c for c in body["data"] if (c.get("metadata") or {}).get("source") != SOURCE] if s == 200 else []
    if oldest:
        age_h = (time.time() - min(c["created_at"] for c in oldest)) / 3600
        print(f"  the oldest conversation that is not a probe's is {age_h:.1f} hours old and still there. Nothing expired.")

    print("\n== every status seen in this run:", dict(sorted(all_status.items())))


def cleanup():
    """Deletes every conversation this run made, including those made by the raw burst calls: by metadata.source.

    Lists from the start each round instead of paging with `after` while deleting, which would skip entries, and repeats
    until a round finds none. The conversations of the real history carry another source and are never touched."""
    deleted = 0
    for _ in range(40):
        s, body, _, _ = call("GET", "/openai/v1/conversations?limit=100&order=desc")
        mine = [c["id"] for c in (body["data"] if s == 200 else []) if (c.get("metadata") or {}).get("source") == SOURCE]
        if not mine:
            break
        with ThreadPoolExecutor(max_workers=10) as pool:
            deleted += sum(1 for st in pool.map(lambda i: call("DELETE", f"/openai/v1/conversations/{i}")[0], mine) if st in (200, 404))
    for cid in list(created):                     # the 16-pairs conversation has no source: it is tracked by id
        if call("DELETE", f"/openai/v1/conversations/{cid}")[0] in (200, 404):
            deleted += 1
    s, body, _, _ = call("GET", "/openai/v1/conversations?limit=100")
    left = [c for c in (body["data"] if s == 200 else []) if (c.get("metadata") or {}).get("source") == SOURCE]
    print(f"\ncleanup: deleted {deleted} probe conversation(s); {len(left)} left")


if __name__ == "__main__":
    if "--cleanup-only" in sys.argv:
        cleanup()
    else:
        try:
            main()
        finally:
            cleanup()
