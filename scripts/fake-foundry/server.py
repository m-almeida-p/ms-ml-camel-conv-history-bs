#!/usr/bin/env python3
"""A fake of the Microsoft Foundry Conversations API, for the tests of the sync and the API.

It reproduces what scripts/foundry-smoke-test.sh and scripts/foundry-phase1-probe.sh measured against the real
service, and nothing more: server-generated ids, string and output_text items, no item time or metadata, at most 20
items per request, `after`/`before` relative to the listing order, 404 after a delete, 400 for a malformed id, 401 for a
bad token. State is in memory.

Faults (control calls, not part of the real API):
    POST /__fail   {"mode": "429"|"500"|"400"|"401"|"slow"|"drop", "count": N (default 1; -1 = until reset), "delayMs": N}
        429/500/400/401  answer that error instead of serving the request
        slow             sleep delayMs, then serve it normally
        drop             APPLY the request, then close the connection without answering: the caller sees a failure
                         although Foundry did the work (the crash window the sync's reconciliation must survive)
    POST /__reset  forget every conversation and every fault
    GET  /__state  {"conversations": N, "items": {"<conv id>": N}, "fault": {...}}
"""
import json
import os
import random
import string
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8098"))
MAX_ITEMS = 20
LOCK = threading.Lock()
CONVERSATIONS = {}   # id -> {"id", "created_at", "metadata", "items": [item, ...]}
FAULT = {"mode": None, "count": 0, "delayMs": 0}
SEQ = [0]
ALNUM = string.digits + string.ascii_letters


def new_id(prefix):
    return prefix + "".join(random.choices("0123456789abcdef", k=16)) + "00" + "".join(random.choices(ALNUM, k=32))


def valid_id(value, prefix):
    return value.startswith(prefix) and len(value) >= len(prefix) + 40 and value[len(prefix):].isalnum()


def error(status, code, message, kind="error"):
    return status, {"error": {"code": code, "message": message, "type": kind, "details": []}}


def make_item(raw):
    role = raw.get("role", "user")
    content = raw.get("content", "")
    if isinstance(content, str):
        parts = [{"type": "input_text" if role == "user" else "output_text", "text": content}]
    else:
        parts = [{"type": p.get("type", "input_text"), "text": p.get("text", "")} for p in content]
    SEQ[0] += 1
    return {"id": new_id("msg_"), "type": "message", "role": role, "status": "completed", "content": parts,
            "created_at": None, "_n": SEQ[0]}


def public(item):
    return {k: v for k, v in item.items() if not k.startswith("_")}


def page(rows, query):
    """A Foundry-style list page. `after`/`before` are ids and relative to the listing order."""
    order = query.get("order", ["asc"])[0]
    limit = int(query.get("limit", ["20"])[0])
    rows = sorted(rows, key=lambda r: r["_n"], reverse=(order == "desc"))
    ids = [r["id"] for r in rows]
    if "after" in query and query["after"][0] in ids:
        rows = rows[ids.index(query["after"][0]) + 1:]
    if "before" in query and query["before"][0] in ids:
        rows = rows[:ids.index(query["before"][0])]
    more = len(rows) > limit
    rows = rows[:limit]
    return {"object": "list", "data": [public(r) for r in rows], "first_id": rows[0]["id"] if rows else None,
            "last_id": rows[-1]["id"] if rows else None, "has_more": more}


def add_items(conv, raw_items):
    if len(raw_items) > MAX_ITEMS:
        return error(400, "invalid_payload", f"Array length {len(raw_items)} exceeds maximum {MAX_ITEMS}", "invalid_request_error")
    made = [make_item(r) for r in raw_items]
    conv["items"].extend(made)
    return 200, {"object": "list", "data": [public(i) for i in made], "first_id": made[0]["id"] if made else None,
                 "last_id": made[-1]["id"] if made else None, "has_more": False}


def handle(method, path, query, body, token):
    """Returns (status, payload). Called with LOCK held."""
    if token is None or token == "not-a-token":
        return error(401, "unauthorized", "Access denied due to invalid subscription key or wrong API endpoint.")
    marker = "/openai/v1"
    if marker not in path:
        return error(404, "not_found", "Resource not found")
    parts = [p for p in path.split(marker, 1)[1].split("/") if p]
    if not parts or parts[0] != "conversations":
        return error(404, "not_found", "Resource not found")
    if len(parts) == 1:
        if method == "POST":
            items = body.get("items") or []
            if len(items) > MAX_ITEMS:
                return error(400, "invalid_payload", f"Array length {len(items)} exceeds maximum {MAX_ITEMS}", "invalid_request_error")
            conv = {"id": new_id("conv_"), "created_at": int(time.time()), "metadata": body.get("metadata") or {}, "items": []}
            add_items(conv, items)
            CONVERSATIONS[conv["id"]] = conv
            return 200, {"id": conv["id"], "object": "conversation", "created_at": conv["created_at"], "metadata": conv["metadata"]}
        if method == "GET":
            rows = [{"id": c["id"], "object": "conversation", "created_at": c["created_at"], "metadata": c["metadata"], "_n": c["created_at"] * 1000 + i}
                    for i, c in enumerate(CONVERSATIONS.values())]
            query = dict(query); query.setdefault("order", ["desc"])
            return 200, page(rows, query)
        return error(405, "method_not_allowed", "Method not allowed")
    cid = parts[1]
    if not valid_id(cid, "conv_"):
        return error(400, "invalid_parameters", "Malformed identifier.", "invalid_request_error")
    conv = CONVERSATIONS.get(cid)
    if conv is None:
        return error(404, "not_found", f"Conversation '{cid}' not found")
    if len(parts) == 2:
        if method == "GET":
            return 200, {"id": cid, "object": "conversation", "created_at": conv["created_at"], "metadata": conv["metadata"]}
        if method == "DELETE":
            del CONVERSATIONS[cid]
            return 200, {"id": cid, "object": "conversation.deleted", "deleted": True}
    if parts[2:3] == ["items"]:
        if len(parts) == 3 and method == "POST":
            return add_items(conv, body.get("items") or [])
        if len(parts) == 3 and method == "GET":
            return 200, page(conv["items"], query)
        if len(parts) == 4 and method == "GET":
            item = next((i for i in conv["items"] if i["id"] == parts[3]), None)
            return (200, public(item)) if item else error(404, "not_found", f"Item '{parts[3]}' not found")
    return error(404, "not_found", "Resource not found")


class Handler(BaseHTTPRequestHandler):
    def _respond(self, status, payload, headers=None):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _serve(self, method):
        url = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(url.query)
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        try:
            body = json.loads(raw) if raw else {}
        except ValueError:
            return self._respond(*error(400, "invalid_payload", "Body is not JSON"))
        if url.path.startswith("/__"):
            return self._control(method, url.path, body)
        auth = self.headers.get("Authorization", "")
        token = auth[7:] if auth.startswith("Bearer ") and len(auth) > 7 else None
        with LOCK:
            mode, delay = FAULT["mode"], FAULT["delayMs"]
            if mode and FAULT["count"] != 0:
                if FAULT["count"] > 0:
                    FAULT["count"] -= 1
                    if FAULT["count"] == 0:
                        FAULT["mode"] = None
            else:
                mode = None
            if mode in ("429", "500", "400", "401"):
                status = int(mode)
                codes = {429: "too_many_requests", 500: "server_error", 400: "invalid_payload", 401: "unauthorized"}
                extra = {"Retry-After": "1"} if status == 429 else {}
                return self._respond(*error(status, codes[status], f"injected {mode}"), headers=extra)
            if mode != "slow":
                status, payload = handle(method, url.path, query, body, token)
        if mode == "slow":
            time.sleep(delay / 1000.0)
            with LOCK:
                status, payload = handle(method, url.path, query, body, token)
        if mode == "drop":
            self.close_connection = True
            self.connection.close()
            return
        self._respond(status, payload)

    def _control(self, method, path, body):
        with LOCK:
            if path == "/__fail" and method == "POST":
                FAULT.update(mode=body.get("mode"), count=int(body.get("count", 1)), delayMs=int(body.get("delayMs", 0)))
            elif path == "/__reset" and method == "POST":
                CONVERSATIONS.clear()
                FAULT.update(mode=None, count=0, delayMs=0)
            elif path != "/__state":
                return self._respond(404, {"error": "unknown control call"})
            state = {"conversations": len(CONVERSATIONS), "items": {c: len(v["items"]) for c, v in CONVERSATIONS.items()}, "fault": dict(FAULT)}
        self._respond(200, state)

    do_GET = lambda self: self._serve("GET")
    do_POST = lambda self: self._serve("POST")
    do_DELETE = lambda self: self._serve("DELETE")

    def log_message(self, fmt, *args):
        print(f"{self.command} {urllib.parse.urlparse(self.path).path} -> {args[1] if len(args) > 1 else '?'}", flush=True)


if __name__ == "__main__":
    print(f"fake foundry on :{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
