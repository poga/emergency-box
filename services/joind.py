#!/usr/bin/env python3
"""Self-registration for people on the local wifi; loopback-only."""
import json
import os
import re
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CHATTO = os.environ.get("JOIND_CHATTO", "/opt/homebrew/bin/chatto")
CONFIG = os.environ.get("JOIND_CONFIG", "/opt/emergency-box/config/chatto.toml")
PORT = int(os.environ.get("JOIND_PORT", "8081"))
LOGIN_RE = re.compile(r"^[a-z0-9._-]{2,32}$")
BURST, REFILL = 10.0, 1.0
MAX_BODY = 4096

_bucket = {"tokens": BURST, "last": time.monotonic()}
_bucket_lock = threading.Lock()


def take_token():
    with _bucket_lock:
        now = time.monotonic()
        _bucket["tokens"] = min(BURST, _bucket["tokens"] + (now - _bucket["last"]) * REFILL)
        _bucket["last"] = now
        if _bucket["tokens"] < 1.0:
            return False
        _bucket["tokens"] -= 1.0
        return True


class Handler(BaseHTTPRequestHandler):
    timeout = 10  # stalling client shouldn't hold a thread forever

    def _reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._reply(405, {"error": "POST only"})

    def do_POST(self):
        if self.path != "/join":
            return self._reply(404, {"error": "not found"})
        if not take_token():
            return self._reply(429, {"error": "too many attempts; wait a moment"})
        raw_len = self.headers.get("Content-Length")
        try:
            length = int(raw_len) if raw_len is not None else 0
        except ValueError:
            return self._reply(400, {"error": "invalid request"})
        if length <= 0:
            return self._reply(400, {"error": "invalid request"})
        if length > MAX_BODY:
            return self._reply(413, {"error": "request too large"})
        try:
            body = json.loads(self.rfile.read(length))
        except ValueError:
            return self._reply(400, {"error": "invalid request"})
        if not isinstance(body, dict):
            return self._reply(400, {"error": "invalid request"})
        login = str(body.get("login", "")).strip().lower()
        password = str(body.get("password", ""))
        if not LOGIN_RE.match(login):
            return self._reply(
                400, {"error": "name must be 2-32 characters: letters, numbers, . _ -"})
        if not 8 <= len(password) <= 128:
            return self._reply(400, {"error": "password must be 8-128 characters"})
        try:
            r = subprocess.run(
                [CHATTO, "operator", "-c", CONFIG, "user", "create",
                 "--login", login, "--password-stdin", "--json"],
                input=password.encode(), capture_output=True, timeout=15)
        except subprocess.TimeoutExpired:
            return self._reply(502, {"error": "chat server is not responding - try again"})
        except (FileNotFoundError, OSError):
            return self._reply(502, {"error": "chat server had a problem - try again"})
        if r.returncode == 0:
            return self._reply(201, {"ok": True, "login": login})
        err = (r.stderr + r.stdout).decode(errors="replace").lower()
        if "taken" in err or "exists" in err or "conflict" in err:
            return self._reply(409, {"error": "that name is taken - pick another"})
        if "password" in err:
            return self._reply(400, {"error": "password rejected by the chat server"})
        return self._reply(502, {"error": "chat server had a problem - try again"})


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
