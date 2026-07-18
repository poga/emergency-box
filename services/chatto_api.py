#!/usr/bin/env python3
"""Minimal bearer-token client for chatto's ConnectRPC JSON API."""
import json
import urllib.error
import urllib.request

TIMEOUT = 10


class ChattoError(Exception):
    def __init__(self, code, message):
        super().__init__("%s: %s" % (code, message))
        self.code = code


class Chatto:
    def __init__(self, base_url, token=None):
        self.base_url = base_url.rstrip("/")
        self.token = token

    def _post(self, path, payload):
        req = urllib.request.Request(
            self.base_url + path,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        if self.token:
            req.add_header("Authorization", "Bearer " + self.token)
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            try:
                body = json.loads(e.read().decode())
            except ValueError:
                raise ChattoError(str(e.code), str(e.reason)) from e
            raise ChattoError(
                body.get("code", str(e.code)), body.get("message", "")
            ) from e

    def login(self, login, password):
        out = self._post("/auth/login", {"login": login, "password": password})
        self.token = out["token"]
        return out

    def rpc(self, service, method, payload=None):
        return self._post("/api/connect/%s/%s" % (service, method),
                          payload or {})
