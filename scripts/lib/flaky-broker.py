#!/usr/bin/env python3
"""A token broker that gives a bad token first, for testing how the sync reacts to a REAL 401 from Foundry.

GET /token forwards to the real broker (http://foundry-token:8099/token) and returns its answer, except that the first
FLAKY_COUNT answers (default 1) carry the token "junk.invalid.token" instead of the real one. GET /stats says how many
tokens were served. Standard library only; started by scripts/test-sync.sh, never by hand.
"""
import json
import os
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REAL = os.environ.get("REAL_BROKER", "http://foundry-token:8099/token")
FLAKY_COUNT = int(os.environ.get("FLAKY_COUNT", "1"))
served = {"n": 0}
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/stats":
            return self._send(200, dict(served))
        if self.path != "/token":
            return self._send(404, {"error": "not found"})
        try:
            with urllib.request.urlopen(REAL, timeout=15) as resp:
                answer = json.load(resp)
        except OSError as err:
            return self._send(502, {"error": type(err).__name__})
        with lock:
            served["n"] += 1
            if served["n"] <= FLAKY_COUNT:
                answer["accessToken"] = "junk.invalid.token"
        self._send(200, answer)

    def log_message(self, fmt, *args):
        print(f"{self.command} {self.path} -> {args[1] if len(args) > 1 else '?'}", flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8099), Handler).serve_forever()
