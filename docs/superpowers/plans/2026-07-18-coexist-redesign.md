# Coexist Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite emergency-box as an always-on LAN chat on the normal wifi (`http://chat.local`): delete all network-takeover machinery, add a tiny account-creation service (joind) replacing mailpit, path-split Caddy on one origin, always-on launchd lifecycle.

**Architecture:** Four always-on launchd services — chatto (:8080, registration disabled, no SMTP), joind (Python 3 stdlib, :8081, wraps `chatto operator user create`), Caddy (:80, path-split: `/join*` portal, `/joinapi` → joind, rest → chatto), and a Bonjour publisher (`dns-sd -P` for `chat.local`). The portal becomes a single-fetch signup form. The router is never touched.

**Tech Stack:** bash, launchd, Caddy 2, chatto (brew `chattocorp/tap/chatto`), Python 3 stdlib (from Xcode CLT), dns-sd/Bonjour, bats-core, shellcheck, jq, curl.

## Global Constraints

- Apple Silicon macOS only; Homebrew prefix `/opt/homebrew`; install prefix `/opt/emergency-box` (custom `--prefix` is test-only, refused with system mode).
- Ports: Caddy `:80` (env `EBOX_HTTP_PORT`, root default 80; `EBOX_ROOT` default `/opt/emergency-box`), chatto `127.0.0.1:8080`, joind `127.0.0.1:8081`.
- launchd labels: `org.emergencybox.{chatto,joind,caddy,bonjour}` in `/Library/LaunchDaemons`, all RunAtLoad+KeepAlive, **enabled and bootstrapped at install** (always-on; no dormancy machinery).
- chatto config: `webserver.url = 'http://chat.local'`, `direct_registration = false`, NO `[smtp]` block. With registration disabled, `POST /auth/register` returns 403 `{"error":"Registration is disabled"}`.
- joind contract: `POST /join` JSON `{login, password}` → 201 `{"ok":true,"login":...}` | 400 | 409 (login taken) | 429 | 502; login must match `^[a-z0-9._-]{2,32}$` (lowercased first); password 8–128 chars; rate limit token bucket burst 10, refill 1/sec, 429 when exhausted; account creation ONLY via exec-array `chatto operator user create --login X --password-stdin --json` (password via stdin, never shell strings); `GET /join` → 405. Errors are JSON `{"error": "<human words>"}`.
- Caddy routing (single origin, path-split): `/join*` → portal `index.html`; `/joinapi` → rewrite to `/join` → `127.0.0.1:8081`; everything else → `127.0.0.1:8080`.
- Portal: self-contained HTML, links are RELATIVE (`/`) so IP-based access works; form submits via `addEventListener('submit', ...)` — NEVER inline `onsubmit` (HTMLFormElement named-getter regression, see git history).
- Bonjour: `dns-sd -P` proxy publishing `chat.local`; never rename the Mac (`scutil` forbidden).
- Tests: real processes, NO MOCKS, poll-until-deadline, `require_port_free` before binding, production ports; `./test.sh` = shellcheck + bats; comments max 1 line/80 chars, minimal.
- Browser drive (headless Chrome via CDP) is definition-of-done for any `landing/index.html` change.
- Execution boundary for implementers: NEVER run `install.sh` without `--no-system`, never run `uninstall.sh`, `launchctl`, `networksetup`, or `pfctl` against the system.

---

### Task 1: joind service, chatto config change, registration tests

**Files:**
- Create: `services/joind.py`
- Modify: `config/chatto.toml.template` (auth + smtp sections)
- Modify: `tests/helpers.bash` (drop mailpit from the stack helpers)
- Delete: `tests/chatto_registration.bats`
- Test: `tests/joind.bats`

**Interfaces:**
- Consumes: `start_chatto_stack DIR` / `stop_chatto_stack DIR` from helpers (this task simplifies them to chatto-only; signatures unchanged), `wait_for_url`, `require_port_free`.
- Produces: `services/joind.py` honoring env `JOIND_CHATTO` (default `/opt/homebrew/bin/chatto`), `JOIND_CONFIG` (default `/opt/emergency-box/config/chatto.toml`), `JOIND_PORT` (default 8081). Later tasks proxy to it and install it verbatim.

- [ ] **Step 1: Update `config/chatto.toml.template`**

Change the `[auth]` section and delete the `[smtp]` section entirely:

```toml
[auth]
direct_registration = false
```

Also delete the `@SMTP_PORT@` placeholder usage everywhere (it only existed for `[smtp]`).

- [ ] **Step 2: Simplify `tests/helpers.bash`**

Remove mailpit from the stack: delete the `require_port_free 1025/8025` lines, the mailpit launch/pidfile block, and the mailpit `wait_for_url`; drop `SMTP_PORT=1025` from the render call. Resulting functions (keep the existing chmod 700, PID-wait loop, and fail-fast style intact):

```bash
start_chatto_stack() { # DIR ; starts a real chatto
  local dir=$1
  require_port_free 8080 || return 1
  mkdir -p "$dir/data"
  # chatto refuses a group/other-accessible socket dir
  chmod 700 "$dir/data"
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  render_template "$BATS_TEST_DIRNAME/../config/chatto.toml.template" \
    "$dir/chatto.toml" \
    "COOKIE_SECRET=$(gen_secret)" "CORE_SECRET=$(gen_secret)" \
    "ASSETS_SECRET=$(gen_secret)" "NATS_TOKEN=$(gen_secret)" \
    "DATA_DIR=$dir/data"
  cd "$dir"
  chatto run -c "$dir/chatto.toml" >"$dir/chatto.log" 2>&1 &
  echo $! >"$dir/chatto.pid"
  cd - >/dev/null
  wait_for_url http://127.0.0.1:8080/healthz 30
}
```

`stop_chatto_stack` keeps its existing kill + wait-for-exit loop (unchanged).

- [ ] **Step 3: Delete the obsolete registration test**

```bash
git rm tests/chatto_registration.bats
```

- [ ] **Step 4: Write the failing test `tests/joind.bats`**

```bash
#!/usr/bin/env bats
load helpers

JOIND=http://127.0.0.1:8081

setup_file() {
  export EBOX_TEST_DIR
  EBOX_TEST_DIR=$(mktemp -d)
  start_chatto_stack "$EBOX_TEST_DIR"
  require_port_free 8081
  JOIND_CHATTO=$(command -v chatto) \
    JOIND_CONFIG="$EBOX_TEST_DIR/chatto.toml" \
    python3 "$BATS_TEST_DIRNAME/../services/joind.py" \
    >"$EBOX_TEST_DIR/joind.log" 2>&1 &
  echo $! >"$EBOX_TEST_DIR/joind.pid"
  local deadline=$((SECONDS + 15))
  until [ "$(curl -s -o /dev/null -w '%{http_code}' $JOIND/join)" = "405" ]; do
    ((SECONDS < deadline)) || return 1
    sleep 0.3
  done
}

teardown_file() {
  kill "$(cat "$EBOX_TEST_DIR/joind.pid")" 2>/dev/null || true
  stop_chatto_stack "$EBOX_TEST_DIR"
}

@test "creates an account that can really log in" {
  run curl -s -o /dev/null -w '%{http_code}' -X POST "$JOIND/join" \
    -H 'Content-Type: application/json' \
    -d '{"login":"joinuser","password":"emergency123"}'
  [ "$output" = "201" ]
  run curl -fsS -X POST http://127.0.0.1:8080/auth/login \
    -H 'Content-Type: application/json' \
    -d '{"login":"joinuser","password":"emergency123"}'
  echo "$output" | jq -e '.user.login == "joinuser"'
}

@test "duplicate login returns 409" {
  curl -s -o /dev/null -X POST "$JOIND/join" -H 'Content-Type: application/json' \
    -d '{"login":"dupuser","password":"emergency123"}'
  run curl -s -o /dev/null -w '%{http_code}' -X POST "$JOIND/join" \
    -H 'Content-Type: application/json' \
    -d '{"login":"dupuser","password":"emergency123"}'
  [ "$output" = "409" ]
}

@test "short password returns 400" {
  run curl -s -o /dev/null -w '%{http_code}' -X POST "$JOIND/join" \
    -H 'Content-Type: application/json' \
    -d '{"login":"shortpw","password":"short"}'
  [ "$output" = "400" ]
}

@test "invalid login characters return 400" {
  run curl -s -o /dev/null -w '%{http_code}' -X POST "$JOIND/join" \
    -H 'Content-Type: application/json' \
    -d '{"login":"Bad Name!","password":"emergency123"}'
  [ "$output" = "400" ]
}

@test "chatto email registration path is closed" {
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    http://127.0.0.1:8080/auth/register -H 'Content-Type: application/json' \
    -d '{"email":"x@chat.lan"}'
  [ "$output" = "403" ]
}
```

Note: `Bad Name!` contains uppercase and `!` — after lowercasing it still
fails the regex on space/`!`, which is the point.

- [ ] **Step 5: Run to verify it fails**

Run: `bats tests/joind.bats`
Expected: FAIL (services/joind.py missing).

- [ ] **Step 6: Write `services/joind.py`**

```python
#!/usr/bin/env python3
"""Self-registration for people on the local wifi; loopback-only."""
import json
import os
import re
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CHATTO = os.environ.get("JOIND_CHATTO", "/opt/homebrew/bin/chatto")
CONFIG = os.environ.get("JOIND_CONFIG", "/opt/emergency-box/config/chatto.toml")
PORT = int(os.environ.get("JOIND_PORT", "8081"))
LOGIN_RE = re.compile(r"^[a-z0-9._-]{2,32}$")
BURST, REFILL = 10.0, 1.0

_bucket = {"tokens": BURST, "last": time.monotonic()}


def take_token():
    now = time.monotonic()
    _bucket["tokens"] = min(BURST, _bucket["tokens"] + (now - _bucket["last"]) * REFILL)
    _bucket["last"] = now
    if _bucket["tokens"] < 1.0:
        return False
    _bucket["tokens"] -= 1.0
    return True


class Handler(BaseHTTPRequestHandler):
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
        try:
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
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
        if r.returncode == 0:
            return self._reply(201, {"ok": True, "login": login})
        err = (r.stderr + r.stdout).decode(errors="replace").lower()
        if "taken" in err or "exists" in err or "conflict" in err:
            return self._reply(409, {"error": "that name is taken - pick another"})
        if "password" in err:
            return self._reply(400, {"error": "password rejected by the chat server"})
        return self._reply(502, {"error": "chat server had a problem - try again"})


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
```

If the duplicate test (Step 4) fails because the real CLI's error wording
matches none of `taken|exists|conflict`, run the CLI by hand once, read the
actual message, and extend the match minimally; record the observed string
in your report.

- [ ] **Step 7: Run tests**

Run: `bats tests/joind.bats` then full `./test.sh`
Expected: joind.bats 5/5 PASS. Full suite: the two mailpit-dependent tests in the OLD `tests/caddy_routing.bats` ("host mail.lan proxies to mailpit UI", "portal host /mailapi/* reaches mailpit API same-origin") now fail structurally — delete those two `@test` blocks (that file is fully rewritten in Task 2 anyway). Everything else must pass; change nothing further.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "Replace email registration with joind operator service"
```

---

### Task 2: Caddyfile path-split, one-fetch portal, routing tests, browser drive

**Files:**
- Modify: `config/Caddyfile` (full rewrite)
- Modify: `landing/index.html` (full rewrite)
- Test: `tests/caddy_routing.bats` (full rewrite)

**Interfaces:**
- Consumes: `start_chatto_stack`/`stop_chatto_stack` (chatto-only), joind launch pattern from `tests/joind.bats` (same env vars).
- Produces: routing contract used by install/status/README: `/join*` → portal, `/joinapi` → joind `/join`, everything else → chatto.

- [ ] **Step 1: Write the failing test `tests/caddy_routing.bats`** (full replacement)

```bash
#!/usr/bin/env bats
load helpers

CADDY_URL="http://127.0.0.1:18080"

setup_file() {
  export EBOX_TEST_DIR
  EBOX_TEST_DIR=$(mktemp -d)
  start_chatto_stack "$EBOX_TEST_DIR"
  require_port_free 8081
  JOIND_CHATTO=$(command -v chatto) \
    JOIND_CONFIG="$EBOX_TEST_DIR/chatto.toml" \
    python3 "$BATS_TEST_DIRNAME/../services/joind.py" \
    >"$EBOX_TEST_DIR/joind.log" 2>&1 &
  echo $! >"$EBOX_TEST_DIR/joind.pid"
  require_port_free 18080
  EBOX_HTTP_PORT=18080 EBOX_ROOT="$BATS_TEST_DIRNAME/.." \
    caddy start --config "$BATS_TEST_DIRNAME/../config/Caddyfile" \
    --adapter caddyfile --pidfile "$EBOX_TEST_DIR/caddy.pid"
  wait_for_url "$CADDY_URL/healthz" 15
}

teardown_file() {
  kill "$(cat "$EBOX_TEST_DIR/caddy.pid")" 2>/dev/null || true
  kill "$(cat "$EBOX_TEST_DIR/joind.pid")" 2>/dev/null || true
  stop_chatto_stack "$EBOX_TEST_DIR"
}

@test "default route reaches chatto" {
  run curl -fsS "$CADDY_URL/healthz"
  echo "$output" | jq -e '.status == "ok"'
}

@test "/join serves the portal page" {
  run curl -fsS "$CADDY_URL/join"
  [[ "$output" == *"Emergency"* ]]
}

@test "/join/anything still serves the portal page" {
  run curl -fsS "$CADDY_URL/join/whatever"
  [[ "$output" == *"Emergency"* ]]
}

@test "/joinapi reaches joind" {
  run curl -s -o /dev/null -w '%{http_code}' -X POST "$CADDY_URL/joinapi" \
    -H 'Content-Type: application/json' -d '{}'
  [ "$output" = "400" ]
}

@test "chatto UI is the front page" {
  run curl -s -o /dev/null -w '%{http_code}' "$CADDY_URL/"
  [ "$output" = "200" ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/caddy_routing.bats`
Expected: FAIL (old Caddyfile routes by host, `/join` unknown).

- [ ] **Step 3: Rewrite `config/Caddyfile`**

```
{
	admin off
	auto_https off
	persist_config off
}

http://:{$EBOX_HTTP_PORT:80} {
	log

	route {
		handle /join* {
			root * {$EBOX_ROOT:/opt/emergency-box}/landing
			rewrite * /index.html
			file_server
		}
		handle /joinapi {
			rewrite * /join
			reverse_proxy 127.0.0.1:8081
		}
		reverse_proxy 127.0.0.1:8080
	}
}
```

- [ ] **Step 4: Rewrite `landing/index.html`**

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Join Emergency Chat</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; margin: 0; }
  body { font-family: -apple-system, system-ui, sans-serif; line-height: 1.5;
         max-width: 26rem; margin: 0 auto; padding: 1.5rem 1rem; }
  h1 { font-size: 1.6rem; margin-bottom: .25rem; }
  .tag { color: #b45309; font-weight: 600; margin-bottom: 1.25rem; }
  .card { border: 1px solid #8884; border-radius: 12px; padding: 1rem;
          margin-bottom: 1rem; }
  label { display: block; font-size: .9rem; font-weight: 600; margin: .6rem 0 .2rem; }
  input { width: 100%; font-size: 1.1rem; padding: .55rem .7rem;
          border: 1px solid #8886; border-radius: 8px; background: transparent;
          color: inherit; }
  button { width: 100%; font-size: 1.1rem; font-weight: 700; padding: .7rem;
           margin-top: 1rem; border: 0; border-radius: 8px;
           background: #b91c1c; color: #fff; }
  button:disabled { opacity: .5; }
  a { color: #b91c1c; }
  #status { margin-top: .8rem; font-size: .95rem; min-height: 1.4rem; }
  #done { display: none; }
  .big { font-size: 1.2rem; font-weight: 700; }
</style>
</head>
<body>
<h1>Emergency Chat</h1>
<p class="tag">A chat room for everyone on this wifi. It keeps working even
when the internet is down.</p>

<form class="card" id="signup">
  <p class="big">Create your account</p>
  <label for="login">Pick a username</label>
  <input id="login" autocapitalize="none" autocorrect="off"
         placeholder="e.g. maria" maxlength="32">
  <label for="pw">Pick a password (8+ characters)</label>
  <input id="pw" type="password" minlength="8" maxlength="128">
  <button id="go" type="submit">Create account</button>
  <p id="status"></p>
</form>

<div class="card" id="done">
  <p class="big">✅ Account ready</p>
  <p><a href="/">Open the chat</a> and sign in with your username and
  password.</p>
</div>

<div class="card">
  <p>Already have an account? <a href="/">Open the chat</a></p>
</div>

<script>
const $ = id => document.getElementById(id);
const status = m => { $('status').textContent = m; };

async function go() {
  const login = $('login').value.trim().toLowerCase();
  const pw = $('pw').value;
  if (!/^[a-z0-9._-]{2,32}$/.test(login)) { status('Username: 2-32 letters/numbers.'); return; }
  if (pw.length < 8) { status('Password needs 8+ characters.'); return; }
  $('go').disabled = true;
  status('Creating your account…');
  try {
    const r = await fetch('/joinapi', { method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ login, password: pw }) });
    const data = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(data.error || ('HTTP ' + r.status));
    $('signup').style.display = 'none';
    $('done').style.display = 'block';
  } catch (e) {
    status('Failed: ' + e.message);
    $('go').disabled = false;
  }
}

// inline onsubmit would let the form's named controls shadow go()
document.getElementById('signup').addEventListener('submit', e => {
  e.preventDefault();
  go();
});
</script>
</body>
</html>
```

- [ ] **Step 5: Run tests**

Run: `bats tests/caddy_routing.bats` then `./test.sh`
Expected: 5/5 PASS; suite failures only in files reworked by Tasks 3–4.

- [ ] **Step 6: Browser drive (definition-of-done for the portal)**

Start the same stack as the bats setup (chatto + joind + caddy :18080),
then drive real headless Chrome via CDP
(`"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless`;
send Input.dispatchMouseEvent / Input.dispatchKeyEvent — for Enter use
`type:"keyDown"` with `text:"\r"`, NOT rawKeyDown, which hangs this build):
1. Open `http://127.0.0.1:18080/join`; fill username `clickuser2` +
   password; submit via real mouse click; assert the success card appears.
2. Reload; fill `enteruser2`; submit via Enter in the password field;
   assert success card.
3. Verify both accounts: `curl -fsS -X POST http://127.0.0.1:8080/auth/login
   -H 'Content-Type: application/json'
   -d '{"login":"clickuser2","password":"<pw>"}'` → `.user.login` matches;
   same for `enteruser2`.
Tear the stack down afterwards. Record the evidence in your report.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "Path-split Caddy routing and one-fetch portal"
```

---

### Task 3: Bonjour publisher and bin/status

**Files:**
- Create: `services/bonjour.sh`
- Create: `bin/status`
- Delete: `bin/emergency-status`
- Modify: `tests/scripts.bats` (full rewrite)

**Interfaces:**
- Consumes: `lib/common.sh` `detect_wifi_device`.
- Produces: `services/bonjour.sh` (exec's `dns-sd -P` publishing `chat.local`), `bin/status` (all checks, exit 1 on any failure). Task 4 installs both.

- [ ] **Step 1: Write the failing test `tests/scripts.bats`** (full replacement)

```bash
#!/usr/bin/env bats

@test "status shows usage with --help" {
  run "$BATS_TEST_DIRNAME/../bin/status" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "status rejects unknown flags" {
  run "$BATS_TEST_DIRNAME/../bin/status" --bogus
  [ "$status" -eq 2 ]
}

@test "wifi detection finds a real device" {
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  dev=$(detect_wifi_device)
  [[ "$dev" =~ ^en[0-9]+$ ]]
}

@test "bonjour publisher script is valid and sources cleanly" {
  run bash -n "$BATS_TEST_DIRNAME/../services/bonjour.sh"
  [ "$status" -eq 0 ]
}

@test "bonjour publisher makes chat.local resolve (best effort)" {
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  ip=$(ipconfig getifaddr "$(detect_wifi_device)" 2>/dev/null || true)
  if [ -z "$ip" ]; then
    skip "no wifi IP on this machine; cannot exercise dns-sd"
  fi
  "$BATS_TEST_DIRNAME/../services/bonjour.sh" &
  pid=$!
  resolved=1
  deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    dscacheutil -q host -a name chat.local 2>/dev/null |
      grep -q ip_address && { resolved=0; break; }
    sleep 0.5
  done
  kill "$pid" 2>/dev/null || true
  [ "$resolved" -eq 0 ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/scripts.bats`
Expected: FAIL (bin/status, services/bonjour.sh missing).

- [ ] **Step 3: Write `services/bonjour.sh`**

```bash
#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

dev=$(detect_wifi_device)
ip=$(ipconfig getifaddr "$dev" 2>/dev/null || true)
if [ -z "$ip" ]; then
  echo "no IP on $dev yet; launchd will retry" >&2
  sleep 5
  exit 1
fi
exec /usr/bin/dns-sd -P "Emergency Chat" _http._tcp local 80 chat.local "$ip"
```

The dirname-based source works from both the repo checkout and
`/opt/emergency-box/services/` (both roots have `lib/common.sh`). The
sleep-5-exit-1 loop lets launchd KeepAlive retry until wifi has an IP
without hitting the 10s respawn throttle.

- [ ] **Step 4: Delete old script, write `bin/status`**

```bash
git rm bin/emergency-status
```

```bash
#!/bin/bash
# shellcheck disable=SC2015
set -euo pipefail
case ${1:-} in
  --help|-h) echo "Usage: status"; exit 0 ;;
  '') ;;
  *) echo "Usage: status" >&2; exit 2 ;;
esac
ok() { printf '  [ok] %s\n' "$1"; }
bad() { printf '  [!!] %s\n' "$1"; FAILED=1; }
FAILED=0

for l in chatto joind caddy bonjour; do
  launchctl print "system/org.emergencybox.$l" >/dev/null 2>&1 &&
    ok "daemon $l loaded" || bad "daemon $l not loaded"
done
curl -fsS --max-time 3 http://127.0.0.1:8080/healthz >/dev/null 2>&1 &&
  ok "chatto healthy" || bad "chatto not responding"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
  http://127.0.0.1:8081/join 2>/dev/null || true)
[ "$code" = "405" ] && ok "joind healthy" || bad "joind not responding"
curl -fsS --max-time 3 http://127.0.0.1:80/healthz >/dev/null 2>&1 &&
  ok "caddy serving chatto on :80" || bad "caddy not serving on :80"
curl -fsS --max-time 3 http://127.0.0.1:80/join 2>/dev/null |
  grep -qi emergency && ok "portal at /join" || bad "portal not serving"
dscacheutil -q host -a name chat.local 2>/dev/null | grep -q ip_address &&
  ok "chat.local resolving" || bad "chat.local not resolving (bonjour)"
exit "$FAILED"
```

- [ ] **Step 5: Run tests**

Run: `chmod +x bin/status services/bonjour.sh && bats tests/scripts.bats && ./test.sh`
Expected: scripts.bats 4/4 PASS.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "Add bonjour publisher and status script"
```

---

### Task 4: Always-on install/uninstall, plists, deletions sweep

**Files:**
- Create: `config/org.emergencybox.joind.plist.template`
- Create: `config/org.emergencybox.bonjour.plist.template`
- Delete: `config/org.emergencybox.dnsmasq.plist`, `config/org.emergencybox.mailpit.plist.template`, `config/org.emergencybox.caffeinate.plist`, `config/dnsmasq.conf.template`, `config/dnsmasq-dns.conf.template`, `tests/dns.bats`, `bin/emergency-on`, `bin/emergency-off`, `bin/emergency-hotspot`
- Modify: `install.sh` (full rewrite), `uninstall.sh` (full rewrite), `tests/install.bats` (full rewrite)
- Keep unchanged: `config/org.emergencybox.chatto.plist.template`, `config/org.emergencybox.caddy.plist`

**Interfaces:**
- Consumes: everything from Tasks 1–3 at their stated paths.
- Produces: `install.sh [--prefix DIR --no-system]`; four installed plists; operator credentials file.

- [ ] **Step 1: Write the failing test `tests/install.bats`** (full replacement)

```bash
#!/usr/bin/env bats
load helpers

setup_file() {
  export PREFIX HOMEBREW_NO_AUTO_UPDATE=1
  PREFIX=$(mktemp -d)
  run "$BATS_TEST_DIRNAME/../install.sh" --prefix "$PREFIX" --no-system
  [ "$status" -eq 0 ]
}

@test "renders chatto.toml with distinct secrets, registration disabled, no smtp" {
  grep -qE "cookie_signing_secret = '[0-9a-f]{64}'" "$PREFIX/config/chatto.toml"
  s=$(grep -oE "[0-9a-f]{64}" "$PREFIX/config/chatto.toml" | sort -u | wc -l)
  [ "$s" -ge 4 ]
  grep -q 'direct_registration = false' "$PREFIX/config/chatto.toml"
  ! grep -q '\[smtp\]' "$PREFIX/config/chatto.toml"
}

@test "chatto.toml is not world readable" {
  perms=$(stat -f '%Lp' "$PREFIX/config/chatto.toml")
  [ "$perms" = "600" ]
}

@test "services and portal installed" {
  [ -x "$PREFIX/services/joind.py" ]
  [ -x "$PREFIX/services/bonjour.sh" ]
  [ -x "$PREFIX/bin/status" ]
  [ -f "$PREFIX/landing/index.html" ]
  [ -f "$PREFIX/lib/common.sh" ]
}

@test "caddyfile installed and valid" {
  run caddy validate --config "$PREFIX/config/Caddyfile" --adapter caddyfile
  [ "$status" -eq 0 ]
}

@test "data dir is private" {
  perms=$(stat -f '%Lp' "$PREFIX/data")
  [ "$perms" = "700" ]
}

@test "install is idempotent and keeps existing secrets" {
  before=$(grep cookie_signing_secret "$PREFIX/config/chatto.toml")
  run "$BATS_TEST_DIRNAME/../install.sh" --prefix "$PREFIX" --no-system
  [ "$status" -eq 0 ]
  after=$(grep cookie_signing_secret "$PREFIX/config/chatto.toml")
  [ "$before" = "$after" ]
}

@test "custom prefix is refused for system installs" {
  run "$BATS_TEST_DIRNAME/../install.sh" --prefix /tmp/nope
  [ "$status" -eq 2 ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/install.bats`
Expected: FAIL (old install.sh renders dnsmasq, has smtp assertions, etc.).

- [ ] **Step 3: Delete takeover files**

```bash
git rm config/org.emergencybox.dnsmasq.plist \
  config/org.emergencybox.mailpit.plist.template \
  config/org.emergencybox.caffeinate.plist \
  config/dnsmasq.conf.template config/dnsmasq-dns.conf.template \
  tests/dns.bats bin/emergency-on bin/emergency-off bin/emergency-hotspot
```

- [ ] **Step 4: Write the two new plist templates**

`config/org.emergencybox.joind.plist.template`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>org.emergencybox.joind</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>/opt/emergency-box/services/joind.py</string>
  </array>
  <key>UserName</key><string>@EBOX_USER@</string>
  <key>WorkingDirectory</key><string>/opt/emergency-box</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/opt/emergency-box/log/joind.log</string>
  <key>StandardErrorPath</key><string>/opt/emergency-box/log/joind.log</string>
</dict>
</plist>
```

`config/org.emergencybox.bonjour.plist.template`: identical shape with
label `org.emergencybox.bonjour`, ProgramArguments
`/bin/bash /opt/emergency-box/services/bonjour.sh`, logs to `bonjour.log`.

- [ ] **Step 5: Rewrite `install.sh`** (complete file)

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/common.sh

PREFIX=/opt/emergency-box
SYSTEM=1
while [ $# -gt 0 ]; do
  case $1 in
    --prefix)
      [ $# -ge 2 ] || { echo "--prefix needs a value" >&2; exit 2; }
      PREFIX=$2; shift 2 ;;
    --no-system) SYSTEM=0; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
if [ "$SYSTEM" = 1 ] && [ "$PREFIX" != /opt/emergency-box ]; then
  echo "custom --prefix is test-only; combine it with --no-system" >&2
  exit 2
fi

[ "$(uname -sm)" = "Darwin arm64" ] || { echo "Apple Silicon macOS only" >&2; exit 1; }
command -v brew >/dev/null || { echo "Homebrew required: https://brew.sh" >&2; exit 1; }

if [ "$SYSTEM" = 1 ] && [ "$(id -u)" -ne 0 ]; then
  echo "System install needs root; re-run: sudo $0" >&2
  exit 1
fi
EBOX_USER=${SUDO_USER:-$(id -un)}

echo "==> Installing packages (needs internet, one time only)"
pkgs=(caddy jq chattocorp/tap/chatto bats-core shellcheck)
if [ "$(id -u)" -eq 0 ]; then
  sudo -u "$EBOX_USER" brew install "${pkgs[@]}"
else
  brew install "${pkgs[@]}"
fi

echo "==> Laying out $PREFIX"
mkdir -p "$PREFIX"/{bin,lib,config,data,landing,services,log}
chmod 700 "$PREFIX/data"

if [ ! -f "$PREFIX/config/chatto.toml" ]; then
  render_template config/chatto.toml.template "$PREFIX/config/chatto.toml" \
    "COOKIE_SECRET=$(gen_secret)" "CORE_SECRET=$(gen_secret)" \
    "ASSETS_SECRET=$(gen_secret)" "NATS_TOKEN=$(gen_secret)" \
    "DATA_DIR=$PREFIX/data"
  chmod 600 "$PREFIX/config/chatto.toml"
fi
cp config/Caddyfile "$PREFIX/config/Caddyfile"
cp landing/index.html "$PREFIX/landing/index.html"
cp lib/common.sh "$PREFIX/lib/common.sh"
cp bin/status "$PREFIX/bin/status"
cp services/joind.py services/bonjour.sh "$PREFIX/services/"
chmod +x "$PREFIX/bin/status" "$PREFIX/services/joind.py" \
  "$PREFIX/services/bonjour.sh"

if [ "$SYSTEM" = 1 ]; then
  chown "$EBOX_USER" "$PREFIX/config/chatto.toml"
  chown -R "$EBOX_USER" "$PREFIX/data" "$PREFIX/log"

  echo "==> Installing always-on launchd services"
  for t in config/org.emergencybox.*.plist.template; do
    out="/Library/LaunchDaemons/$(basename "${t%.template}")"
    render_template "$t" "$out" "EBOX_USER=$EBOX_USER"
  done
  cp config/org.emergencybox.caddy.plist /Library/LaunchDaemons/
  chown root:wheel /Library/LaunchDaemons/org.emergencybox.*.plist
  chmod 644 /Library/LaunchDaemons/org.emergencybox.*.plist
  for l in chatto joind caddy bonjour; do
    launchctl bootout "system/org.emergencybox.$l" 2>/dev/null || true
    launchctl enable "system/org.emergencybox.$l" 2>/dev/null || true
    launchctl bootstrap system "/Library/LaunchDaemons/org.emergencybox.$l.plist"
  done

  echo "==> Pre-authorizing binaries with the application firewall"
  fw=/usr/libexec/ApplicationFirewall/socketfilterfw
  for b in /opt/homebrew/bin/caddy /opt/homebrew/bin/chatto; do
    "$fw" --add "$b" >/dev/null || true
    "$fw" --unblockapp "$b" >/dev/null || true
  done

  echo "==> Waiting for chatto"
  deadline=$((SECONDS + 60))
  until curl -fsS --max-time 2 http://127.0.0.1:8080/healthz >/dev/null 2>&1; do
    ((SECONDS < deadline)) || { echo "chatto did not start; see $PREFIX/log" >&2; exit 1; }
    sleep 1
  done
  if [ ! -f "$PREFIX/config/operator-credentials.txt" ]; then
    echo "==> Creating operator (admin) account"
    op_pw=$(openssl rand -base64 12)
    if printf '%s' "$op_pw" | chatto operator \
      -c "$PREFIX/config/chatto.toml" user create \
      --login operator --password-stdin --verified-email operator@chat.lan; then
      printf 'login: operator\npassword: %s\n' "$op_pw" \
        >"$PREFIX/config/operator-credentials.txt"
      chmod 600 "$PREFIX/config/operator-credentials.txt"
      chown "$EBOX_USER" "$PREFIX/config/operator-credentials.txt"
    else
      echo "WARNING: operator account creation failed; re-run install" >&2
    fi
  fi
  cat <<EOF

Install complete — the chat is live and survives reboots.
  Chat     : http://chat.local
  Sign up  : http://chat.local/join
  Status   : $PREFIX/bin/status
  Admin    : $PREFIX/config/operator-credentials.txt
Reserve this Mac's IP in your router's DHCP settings so the printed
QR fallback stays valid.
EOF
else
  echo "Install complete (no-system mode)."
fi
```

- [ ] **Step 6: Rewrite `uninstall.sh`** (complete file)

```bash
#!/bin/bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
for l in chatto joind caddy bonjour; do
  launchctl bootout "system/org.emergencybox.$l" 2>/dev/null || true
  rm -f "/Library/LaunchDaemons/org.emergencybox.$l.plist"
done
echo "Services removed. Chat history lives in /opt/emergency-box/data."
read -rp "Delete /opt/emergency-box entirely? [y/N] " a
if [ "$a" = "y" ]; then rm -rf /opt/emergency-box; fi
echo "Done. Brew packages left installed (caddy chatto)."
```

- [ ] **Step 7: Run tests**

Run: `chmod +x install.sh uninstall.sh && ./test.sh`
Expected: full suite green (joind, caddy_routing, install, scripts).

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "Always-on install lifecycle; delete takeover machinery"
```

---

### Task 5: README and sign rewrite

**Files:**
- Modify: `README.md` (full rewrite), `docs/sign.md` (full rewrite)

**Interfaces:**
- Consumes: every command/path from Tasks 1–4; verify each against the real scripts (`--help`, `ls`, `grep`) before quoting. Never invent flags.

- [ ] **Step 1: Rewrite `README.md`** with exactly these sections:

1. **What this is** — an always-on chat room for your wifi that keeps
   working when the internet dies; nothing to activate in an emergency.
2. **One-command setup** (needs internet once):
   `git clone <repo> && cd emergency-box && sudo ./install.sh`, plus the
   LLM-agent variant sentence. After install: chat at `http://chat.local`,
   sign-up at `http://chat.local/join`.
3. **Set a DHCP reservation** — one-time router step so the Mac's IP (and
   the printed QR fallback) stays stable; how to find the Mac's IP.
4. **How people join** — `chat.local/join` → name + password → sign in at
   `chat.local`. Old Androids that can't resolve `.local` use the QR/IP
   from the sign. Admin credentials location.
5. **When the internet dies** — nothing to do; while router + Mac have
   power the chat stays up. Plug the Mac in; run `caffeinate -s` in a
   terminal (or keep the lid open) so it can't sleep.
6. **Smoke checklist** (run once after install): phone on wifi →
   `chat.local/join` → account → send a message from a second device →
   reboot the Mac → `bin/status` all-ok without touching anything →
   unplug the router's WAN cable (simulated internet death) → chat still
   works → plug it back.
7. **Troubleshooting** — `/opt/emergency-box/bin/status` line by line;
   log locations (`/opt/emergency-box/log/{chatto,joind,caddy,bonjour}.log`);
   port 80 conflicts; `.local` on old Android.
8. **Uninstall** — `sudo ./uninstall.sh`.
9. **Design notes** — link to both specs (v1 takeover design marked
   superseded, coexist design current).

- [ ] **Step 2: Rewrite `docs/sign.md`** — print-ready card: "1. Join wifi
`____`  2. Go to **chat.local/join** and pick a name  3. Chat at
**chat.local** — works even when the internet is down." plus a fallback
line for the Mac's IP (`http://<ip>/join`) and the optional
`qrencode -o sign-qr.png 'http://<ip>/join'` one-liner.

- [ ] **Step 3: Verify doc accuracy**

Run every quoted command against `--help`/`ls`/`grep` on the real files.
Run `./test.sh` once (docs-only change; must stay green).
Expected: zero drift.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "Rewrite README and sign for coexist design"
```

---

### Task 6: Full verification pass

**Files:**
- Modify: whatever the pass uncovers.

- [ ] **Step 1:** `./test.sh` → all green; `shellcheck` clean; `plutil -lint` on every plist (templates via a rendered temp copy).
- [ ] **Step 2:** Re-run the Task 2 browser drive against the current tree (fresh usernames) — portal is definition-of-done.
- [ ] **Step 3:** Confirm no takeover remnants: `grep -ri 'dnsmasq\|mailpit\|emergency-on\|hotspot\|captive' --include='*' . | grep -v docs/superpowers | grep -v .git` returns nothing unexpected (specs/plans in docs/ may mention them historically).
- [ ] **Step 4:** Leave sudo steps for the user (real `sudo ./install.sh`, `bin/status`, phone smoke checklist); print exactly what they need to run and stop.
- [ ] **Step 5: Commit fixes**

```bash
git add -A && git commit -m "Coexist verification pass fixes"
```
