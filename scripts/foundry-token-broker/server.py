#!/usr/bin/env python3
"""Token broker for the Camel Karavan projects that call Microsoft Foundry.

A container started by Karavan cannot receive a secret without it landing in Git, so the secret stays here and the
projects ask for a token over the shared Docker network:

    GET /token   -> {"accessToken": "...", "expiresOn": "<UTC ISO>", "expiresIn": <seconds>, "endpoint": "<project endpoint>"}
    GET /health  -> {"status": "ok", "configured": true|false}

The token is a Microsoft Entra ID access token for Foundry (client credentials of the service principal in .env). The
endpoint is FOUNDRY_PROJECT_ENDPOINT from .env: it names the Azure resource, so it is served here instead of written in
a project file that goes to Git. It is cached until a minute before it expires, so many callers cost one request to Entra ID. Standard library only.
The token and the secret are never logged.
"""
import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TENANT = os.environ.get("FOUNDRY_TENANT_ID", "")
CLIENT = os.environ.get("FOUNDRY_CLIENT_ID", "")
SECRET = os.environ.get("FOUNDRY_CLIENT_SECRET", "")
ENDPOINT = os.environ.get("FOUNDRY_PROJECT_ENDPOINT", "").rstrip("/")
SCOPE = os.environ.get("FOUNDRY_TOKEN_SCOPE", "https://ai.azure.com/.default")
PORT = int(os.environ.get("PORT", "8099"))
MARGIN_SECONDS = 60

_lock = threading.Lock()
_cache = {"token": None, "expires_at": 0.0}


def configured():
    return bool(TENANT and CLIENT and SECRET)


def request_token():
    """One client-credentials request to Entra ID. Returns (token, seconds until it expires)."""
    body = urllib.parse.urlencode({
        "client_id": CLIENT, "client_secret": SECRET, "scope": SCOPE, "grant_type": "client_credentials",
    }).encode()
    url = f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/token"
    with urllib.request.urlopen(urllib.request.Request(url, data=body), timeout=15) as resp:
        data = json.load(resp)
    return data["access_token"], int(data["expires_in"])


def current_token():
    """The cached token, renewed when less than MARGIN_SECONDS of life remain."""
    with _lock:
        now = time.time()
        if _cache["token"] is None or now >= _cache["expires_at"] - MARGIN_SECONDS:
            token, expires_in = request_token()
            _cache.update(token=token, expires_at=now + expires_in)
        return _cache["token"], _cache["expires_at"]


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/health":
            return self._send(200, {"status": "ok", "configured": configured()})
        if path != "/token":
            return self._send(404, {"error": "not found"})
        if not configured():
            return self._send(503, {"error": "FOUNDRY_TENANT_ID, FOUNDRY_CLIENT_ID and FOUNDRY_CLIENT_SECRET are not set"})
        try:
            token, expires_at = current_token()
        except urllib.error.HTTPError as err:  # Entra ID refused: report its error code, never its body or our secret
            try:
                code = json.load(err).get("error", "unknown")
            except ValueError:
                code = "unknown"
            return self._send(502, {"error": "token request refused", "entraStatus": err.code, "entraError": code})
        except (urllib.error.URLError, OSError, KeyError, ValueError) as err:
            return self._send(502, {"error": "token request failed", "kind": type(err).__name__})
        expires_on = datetime.fromtimestamp(expires_at, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        self._send(200, {"accessToken": token, "expiresOn": expires_on, "expiresIn": int(expires_at - time.time()), "endpoint": ENDPOINT})

    def log_message(self, fmt, *args):  # one line per request: method and path only
        print(f"{self.command} {urllib.parse.urlparse(self.path).path} -> {args[1] if len(args) > 1 else '?'}", flush=True)


if __name__ == "__main__":
    print(f"foundry-token broker on :{PORT}, configured={configured()}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
