# Emergency Box Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn an Apple Silicon Mac + any bridge-mode AP into an offline emergency chat room (chatto) with captive-portal onboarding, installed as dormant launchd daemons toggled by `emergency-on`/`emergency-off`.

**Architecture:** Four off-the-shelf daemons — dnsmasq (DHCP + wildcard DNS), Caddy :80 (portal page + host-based reverse proxy), chatto :8080 (chat server, embedded DB), mailpit :1025/:8025 (local mail catcher that closes chatto's email-code registration loop) — plus a caffeinate daemon. A self-contained portal page automates registration client-side. Shell scripts + launchd orchestrate; bats-core tests exercise the real daemons.

**Tech Stack:** bash, launchd, dnsmasq, Caddy 2, chatto (brew tap `chattocorp/tap/chatto`), mailpit, bats-core, shellcheck, jq, curl, dig.

## Global Constraints

- Target: Apple Silicon macOS only; Homebrew prefix is `/opt/homebrew`.
- Install prefix: `/opt/emergency-box` with subdirs `config/ data/ landing/ run/ log/`.
- Emergency subnet `10.87.0.0/24`; the Mac is `10.87.0.1`; DHCP range `10.87.0.50–10.87.0.250`.
- Hostnames: chat at `http://chat.lan`, mail UI at `http://mail.lan`. Never use `.local`.
- Ports: Caddy `:80`, chatto `127.0.0.1:8080`, mailpit SMTP `127.0.0.1:1025`, mailpit HTTP `127.0.0.1:8025`.
- launchd labels: `org.emergencybox.{chatto,mailpit,dnsmasq,caddy,caffeinate}`; plists live in `/Library/LaunchDaemons`.
- chatto endpoints (verified v0.4.13): `GET /healthz`; `POST /auth/register` `{email}`; `POST /auth/register/verify-code` `{email, code}` → `{completionToken}`; `POST /auth/register/complete` `{token, login, password, passwordConfirmation}`; `POST /auth/login` `{login, password}`. Anonymous requests are CSRF-exempt.
- Mailpit API (behind Caddy at `/mailapi/*`): `GET /api/v1/search?query=to:"<email>"` → `{messages:[{ID,...}]}`; `GET /api/v1/message/<ID>` → `{Text,...}`.
- Tests must drive real processes (NO MOCKS), assert observable outcomes, and poll-until-deadline rather than sleep fixed durations.
- Shell code passes `shellcheck`; comments max 1 line / 80 chars, minimal.
- Run the full suite with `./test.sh` (shellcheck + bats).
- Tests that need daemons use production ports and fail fast with a clear message if a port is busy.

---

### Task 1: Shared library, chatto + mailpit configs, real registration round-trip

**Files:**
- Create: `lib/common.sh`
- Create: `config/chatto.toml.template`
- Create: `tests/helpers.bash`
- Create: `tests/chatto_registration.bats`
- Create: `test.sh`
- Create: `.gitignore`

**Interfaces:**
- Produces: `lib/common.sh` functions used by every later task:
  - `gen_secret` → prints 64-char hex
  - `render_template SRC DEST KEY=VALUE...` → replaces each `@KEY@` in SRC
  - `detect_wifi_device` → prints e.g. `en0`
  - `detect_wifi_service` → prints e.g. `Wi-Fi`
- Produces: `config/chatto.toml.template` with placeholders `@COOKIE_SECRET@ @CORE_SECRET@ @ASSETS_SECRET@ @NATS_TOKEN@ @DATA_DIR@ @SMTP_PORT@`
- Produces: `tests/helpers.bash` functions `wait_for_url URL DEADLINE_SECS`, `require_port_free PORT`, `start_chatto_stack DIR` / `stop_chatto_stack` (real mailpit + chatto, PIDs in `$EBOX_TEST_DIR`).

- [ ] **Step 1: Install dev dependencies**

Run: `brew install chattocorp/tap/chatto mailpit bats-core shellcheck jq bind`
Expected: all install (bind provides `dig`; most Macs have curl already). Verify: `chatto --version && mailpit version && bats --version`

- [ ] **Step 2: Write `.gitignore`**

```gitignore
.DS_Stor*
*.log
data/
.claude/worktrees/
```

- [ ] **Step 3: Write `lib/common.sh`**

```bash
#!/bin/bash
set -euo pipefail

gen_secret() { openssl rand -hex 32; }

# render_template SRC DEST KEY=VALUE... ; replaces @KEY@ tokens
render_template() {
  local src=$1 dest=$2 kv content
  shift 2
  content=$(<"$src")
  for kv in "$@"; do
    content=${content//@"${kv%%=*}"@/${kv#*=}}
  done
  printf '%s\n' "$content" >"$dest"
}

detect_wifi_device() {
  networksetup -listallhardwareports |
    awk '/Hardware Port: Wi-Fi/{getline; print $2; exit}'
}

detect_wifi_service() {
  local dev
  dev=$(detect_wifi_device)
  networksetup -listnetworkserviceorder |
    grep -B1 "Device: ${dev})" | head -1 | sed 's/^([0-9*]*) //'
}
```

- [ ] **Step 4: Write `config/chatto.toml.template`**

```toml
[general]
log_level = 'info'

[owners]
emails = ['operator@chat.lan']

[webserver]
url = 'http://chat.lan'
port = 8080
cookie_signing_secret = '@COOKIE_SECRET@'

[operator_api]
enabled = true
socket_path = '@DATA_DIR@/operator.sock'

[core]
secret_key = '@CORE_SECRET@'

[core.assets]
signing_secret = '@ASSETS_SECRET@'

[auth]
direct_registration = true

[smtp]
enabled = true
host = '127.0.0.1'
port = @SMTP_PORT@
tls = 'opportunistic'
from = 'registration@chat.lan'

[nats.embedded]
enabled = true
data_dir = '@DATA_DIR@/nats'
auth_token = '@NATS_TOKEN@'
```

- [ ] **Step 5: Write `tests/helpers.bash`**

```bash
#!/bin/bash

wait_for_url() { # URL DEADLINE_SECS ; polls until 2xx or deadline
  local url=$1 deadline=$((SECONDS + $2))
  while ((SECONDS < deadline)); do
    curl -fsS --max-time 2 -o /dev/null "$url" 2>/dev/null && return 0
    sleep 0.5
  done
  echo "timeout waiting for $url" >&2
  return 1
}

require_port_free() {
  if lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $1 is busy; stop that service to run this test" >&2
    return 1
  fi
}

start_chatto_stack() { # DIR ; starts real mailpit + chatto
  local dir=$1
  require_port_free 8080 && require_port_free 1025 && require_port_free 8025
  mkdir -p "$dir/data"
  mailpit --smtp 127.0.0.1:1025 --listen 127.0.0.1:8025 \
    --database "$dir/data/mailpit.db" >"$dir/mailpit.log" 2>&1 &
  echo $! >"$dir/mailpit.pid"
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  render_template "$BATS_TEST_DIRNAME/../config/chatto.toml.template" \
    "$dir/chatto.toml" \
    "COOKIE_SECRET=$(gen_secret)" "CORE_SECRET=$(gen_secret)" \
    "ASSETS_SECRET=$(gen_secret)" "NATS_TOKEN=$(gen_secret)" \
    "DATA_DIR=$dir/data" "SMTP_PORT=1025"
  (cd "$dir" && chatto run -c "$dir/chatto.toml" >"$dir/chatto.log" 2>&1 &
   echo $! >"$dir/chatto.pid")
  wait_for_url http://127.0.0.1:8080/healthz 30
  wait_for_url http://127.0.0.1:8025/api/v1/info 15
}

stop_chatto_stack() { # DIR
  local dir=$1 f
  for f in "$dir"/*.pid; do
    [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null || true
  done
}
```

- [ ] **Step 6: Write the failing test `tests/chatto_registration.bats`**

```bash
#!/usr/bin/env bats
load helpers

setup_file() {
  export EBOX_TEST_DIR
  EBOX_TEST_DIR=$(mktemp -d)
  start_chatto_stack "$EBOX_TEST_DIR"
}

teardown_file() { stop_chatto_stack "$EBOX_TEST_DIR"; }

@test "full offline registration round-trip then login" {
  email="testuser@chat.lan"
  run curl -fsS -X POST http://127.0.0.1:8080/auth/register \
    -H 'Content-Type: application/json' -d "{\"email\":\"$email\"}"
  [ "$status" -eq 0 ]

  code=""
  deadline=$((SECONDS + 20))
  while ((SECONDS < deadline)) && [ -z "$code" ]; do
    id=$(curl -fsS "http://127.0.0.1:8025/api/v1/search?query=to:%22$email%22" |
      jq -r '.messages[0].ID // empty')
    if [ -n "$id" ]; then
      code=$(curl -fsS "http://127.0.0.1:8025/api/v1/message/$id" |
        jq -r .Text | grep -oE '[0-9]{6}' | head -1)
    fi
    [ -z "$code" ] && sleep 0.5
  done
  [ -n "$code" ]

  token=$(curl -fsS -X POST http://127.0.0.1:8080/auth/register/verify-code \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$email\",\"code\":\"$code\"}" | jq -r .completionToken)
  [ -n "$token" ] && [ "$token" != "null" ]

  run curl -fsS -X POST http://127.0.0.1:8080/auth/register/complete \
    -H 'Content-Type: application/json' \
    -d "{\"token\":\"$token\",\"login\":\"testuser\",\"password\":\"emergency123\",\"passwordConfirmation\":\"emergency123\"}"
  [ "$status" -eq 0 ]

  run curl -fsS -X POST http://127.0.0.1:8080/auth/login \
    -H 'Content-Type: application/json' \
    -d '{"login":"testuser","password":"emergency123"}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.user.login == "testuser"'
}
```

- [ ] **Step 7: Write `test.sh`**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
files=$(find . -name '*.sh' -not -path './.git/*'; find bin -type f 2>/dev/null || true)
# shellcheck disable=SC2086
shellcheck $files lib/common.sh tests/helpers.bash
bats tests/
```

Run: `chmod +x test.sh && ./test.sh`
Expected: shellcheck clean; registration test PASSES (config template is already written, so the "failing" state here is any config/endpoint mistake — iterate until green).

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "Add chatto+mailpit config and real registration round-trip test"
```

---

### Task 2: dnsmasq configs + wildcard DNS behavior test

**Files:**
- Create: `config/dnsmasq-dns.conf.template`
- Create: `config/dnsmasq.conf.template`
- Test: `tests/dns.bats`

**Interfaces:**
- Consumes: `lib/common.sh` `render_template`, `detect_wifi_device`.
- Produces: `config/dnsmasq-dns.conf.template` (placeholder `@BOX_IP@`) — the DNS-only fragment, reused verbatim by hotspot mode and tests. `config/dnsmasq.conf.template` (placeholders `@CONFIG_DIR@ @WIFI_DEVICE@ @DATA_DIR@ @LOG_DIR@`) — production DHCP+DNS config that includes the fragment via `conf-file=`.

- [ ] **Step 1: Write the failing test `tests/dns.bats`**

```bash
#!/usr/bin/env bats
load helpers

setup_file() {
  export DNS_DIR
  DNS_DIR=$(mktemp -d)
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  render_template "$BATS_TEST_DIRNAME/../config/dnsmasq-dns.conf.template" \
    "$DNS_DIR/dns.conf" "BOX_IP=10.87.0.1"
  dnsmasq --conf-file="$DNS_DIR/dns.conf" --port=15353 \
    --listen-address=127.0.0.1 --no-daemon >"$DNS_DIR/dnsmasq.log" 2>&1 &
  echo $! >"$DNS_DIR/dnsmasq.pid"
  local deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    dig +short +time=1 +tries=1 -p 15353 probe.example @127.0.0.1 |
      grep -qx 10.87.0.1 && return 0
    sleep 0.3
  done
  return 1
}

teardown_file() { kill "$(cat "$DNS_DIR/dnsmasq.pid")" 2>/dev/null || true; }

@test "wildcard DNS answers any name with the box IP" {
  run dig +short -p 15353 "random$RANDOM.example.com" @127.0.0.1
  [ "$output" = "10.87.0.1" ]
  run dig +short -p 15353 chat.lan @127.0.0.1
  [ "$output" = "10.87.0.1" ]
  run dig +short -p 15353 captive.apple.com @127.0.0.1
  [ "$output" = "10.87.0.1" ]
}

@test "production dnsmasq config validates" {
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  render_template "$BATS_TEST_DIRNAME/../config/dnsmasq-dns.conf.template" \
    "$DNS_DIR/dnsmasq-dns.conf" "BOX_IP=10.87.0.1"
  render_template "$BATS_TEST_DIRNAME/../config/dnsmasq.conf.template" \
    "$DNS_DIR/dnsmasq.conf" "CONFIG_DIR=$DNS_DIR" \
    "WIFI_DEVICE=$(detect_wifi_device)" "DATA_DIR=$DNS_DIR" "LOG_DIR=$DNS_DIR"
  run dnsmasq --test --conf-file="$DNS_DIR/dnsmasq.conf"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/dns.bats`
Expected: FAIL (templates missing).

- [ ] **Step 3: Write `config/dnsmasq-dns.conf.template`**

```
no-resolv
no-hosts
address=/#/@BOX_IP@
```

- [ ] **Step 4: Write `config/dnsmasq.conf.template`**

```
conf-file=@CONFIG_DIR@/dnsmasq-dns.conf
interface=@WIFI_DEVICE@
bind-interfaces
dhcp-range=10.87.0.50,10.87.0.250,255.255.255.0,12h
dhcp-option=option:router,10.87.0.1
dhcp-option=option:dns-server,10.87.0.1
dhcp-authoritative
dhcp-leasefile=@DATA_DIR@/dnsmasq.leases
log-facility=@LOG_DIR@/dnsmasq.log
```

- [ ] **Step 5: Run tests**

Run: `./test.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "Add dnsmasq wildcard DNS + DHCP config with behavior test"
```

---

### Task 3: Caddyfile + portal page + routing tests

**Files:**
- Create: `config/Caddyfile`
- Create: `landing/index.html`
- Test: `tests/caddy_routing.bats`

**Interfaces:**
- Consumes: `start_chatto_stack`/`stop_chatto_stack` from `tests/helpers.bash`.
- Produces: `config/Caddyfile` honoring env `EBOX_HTTP_PORT` (default 80) and `EBOX_ROOT` (default `/opt/emergency-box`); routes: host `chat.lan` → :8080, host `mail.lan` → :8025, path `/auth/*` → :8080, path `/mailapi/*` (stripped) → :8025, everything else → portal `index.html`.
- Produces: `landing/index.html` — self-contained portal that automates registration via `/auth/*` + `/mailapi/*`.

- [ ] **Step 1: Write the failing test `tests/caddy_routing.bats`**

```bash
#!/usr/bin/env bats
load helpers

setup_file() {
  export EBOX_TEST_DIR CADDY_URL="http://127.0.0.1:18080"
  EBOX_TEST_DIR=$(mktemp -d)
  start_chatto_stack "$EBOX_TEST_DIR"
  EBOX_HTTP_PORT=18080 EBOX_ROOT="$BATS_TEST_DIRNAME/.." \
    caddy start --config "$BATS_TEST_DIRNAME/../config/Caddyfile" \
    --adapter caddyfile --pidfile "$EBOX_TEST_DIR/caddy.pid"
  wait_for_url "$CADDY_URL" 15
}

teardown_file() {
  kill "$(cat "$EBOX_TEST_DIR/caddy.pid")" 2>/dev/null || true
  stop_chatto_stack "$EBOX_TEST_DIR"
}

@test "host chat.lan proxies to chatto" {
  run curl -fsS -H 'Host: chat.lan' "$CADDY_URL/healthz"
  echo "$output" | jq -e '.status == "ok"'
}

@test "host mail.lan proxies to mailpit UI" {
  run curl -fsS -H 'Host: mail.lan' "$CADDY_URL/api/v1/info"
  [ "$status" -eq 0 ]
}

@test "captive probe host gets portal page, not Success" {
  run curl -fsS -H 'Host: captive.apple.com' "$CADDY_URL/hotspot-detect.html"
  [[ "$output" == *"Emergency"* ]]
  [[ "$output" != *"<BODY>Success</BODY>"* ]]
}

@test "any other host and path gets portal page" {
  run curl -fsS -H 'Host: connectivitycheck.gstatic.com' "$CADDY_URL/generate_204"
  [[ "$output" == *"Emergency"* ]]
}

@test "portal host /auth/* reaches chatto same-origin" {
  run curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H 'Host: whatever.example' -H 'Content-Type: application/json' \
    -d '{}' "$CADDY_URL/auth/register"
  [ "$output" = "400" ]
}

@test "portal host /mailapi/* reaches mailpit API same-origin" {
  run curl -fsS -H 'Host: whatever.example' "$CADDY_URL/mailapi/api/v1/info"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/caddy_routing.bats`
Expected: FAIL (Caddyfile missing).

- [ ] **Step 3: Write `config/Caddyfile`**

```
{
	admin off
	auto_https off
	persist_config off
}

http://:{$EBOX_HTTP_PORT:80} {
	log

	@chat host chat.lan
	@mail host mail.lan
	@auth path /auth/*

	route {
		reverse_proxy @chat 127.0.0.1:8080
		reverse_proxy @mail 127.0.0.1:8025
		reverse_proxy @auth 127.0.0.1:8080
		handle_path /mailapi/* {
			reverse_proxy 127.0.0.1:8025
		}
		root * {$EBOX_ROOT:/opt/emergency-box}/landing
		try_files {path} /index.html
		file_server
	}
}
```

- [ ] **Step 4: Write `landing/index.html`**

Self-contained portal (no external assets, system font stack, mobile-first).
Full content:

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Emergency Chat</title>
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
  #done, #fallback { display: none; }
  .big { font-size: 1.2rem; font-weight: 700; }
  .hint { font-size: .85rem; opacity: .75; margin-top: .5rem; }
</style>
</head>
<body>
<h1>Emergency Chat</h1>
<p class="tag">You are connected. This network has no internet — it hosts a
local chat room for everyone nearby.</p>

<div class="card" id="signup">
  <p class="big">Create your account</p>
  <label for="login">Pick a username</label>
  <input id="login" autocapitalize="none" autocorrect="off"
         placeholder="e.g. maria" maxlength="32">
  <label for="pw">Pick a password (8+ characters)</label>
  <input id="pw" type="password" minlength="8" maxlength="128">
  <button id="go">Create account</button>
  <p id="status"></p>
</div>

<div class="card" id="done">
  <p class="big">✅ Account ready</p>
  <p>Open <a href="http://chat.lan">chat.lan</a> in your browser (Safari or
  Chrome, not this popup) and sign in with your username and password.</p>
  <p class="hint">If this page is a wifi popup, tap Done/Cancel first and
  choose “Use Without Internet”, then open your browser.</p>
</div>

<div class="card">
  <p>Already have an account? Go to
  <a href="http://chat.lan"><b>chat.lan</b></a></p>
</div>

<div class="card" id="fallback">
  <p class="big">Manual registration</p>
  <p>Automatic signup failed. In your browser: open
  <a href="http://chat.lan/register">chat.lan/register</a>, use any email
  ending in <b>@chat.lan</b>, then read your 6-digit code at
  <a href="http://mail.lan">mail.lan</a>.</p>
</div>

<script>
const $ = id => document.getElementById(id);
const status = m => { $('status').textContent = m; };

async function post(path, body) {
  const r = await fetch(path, { method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body) });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error || ('HTTP ' + r.status));
  return data;
}

async function pollCode(email) {
  const q = encodeURIComponent('to:"' + email + '"');
  for (let i = 0; i < 20; i++) {
    try {
      const s = await (await fetch('/mailapi/api/v1/search?query=' + q)).json();
      const id = s.messages && s.messages[0] && s.messages[0].ID;
      if (id) {
        const m = await (await fetch('/mailapi/api/v1/message/' + id)).json();
        const hit = (m.Text || '').match(/\b(\d{6})\b/);
        if (hit) return hit[1];
      }
    } catch (e) { /* keep polling */ }
    await new Promise(r => setTimeout(r, 1500));
  }
  throw new Error('No code arrived — the username may be taken.');
}

$('go').onclick = async () => {
  const login = $('login').value.trim().toLowerCase();
  const pw = $('pw').value;
  if (!/^[a-z0-9._-]{2,32}$/.test(login)) { status('Username: 2–32 letters/numbers.'); return; }
  if (pw.length < 8) { status('Password needs 8+ characters.'); return; }
  $('go').disabled = true;
  try {
    const email = login + '@chat.lan';
    status('Requesting account…');
    await post('/auth/register', { email });
    status('Fetching your code…');
    const code = await pollCode(email);
    status('Verifying…');
    const v = await post('/auth/register/verify-code', { email, code });
    await post('/auth/register/complete', { token: v.completionToken,
      login, password: pw, passwordConfirmation: pw });
    $('signup').style.display = 'none';
    $('done').style.display = 'block';
  } catch (e) {
    status('Failed: ' + e.message);
    $('fallback').style.display = 'block';
    $('go').disabled = false;
  }
};
</script>
</body>
</html>
```

- [ ] **Step 5: Run tests**

Run: `./test.sh`
Expected: PASS (all routing tests green).

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "Add Caddy routing and self-registering portal page"
```

---

### Task 4: launchd plists, install.sh, uninstall.sh

**Files:**
- Create: `config/org.emergencybox.chatto.plist.template`
- Create: `config/org.emergencybox.mailpit.plist.template`
- Create: `config/org.emergencybox.dnsmasq.plist`
- Create: `config/org.emergencybox.caddy.plist`
- Create: `config/org.emergencybox.caffeinate.plist`
- Create: `install.sh`
- Create: `uninstall.sh`
- Test: `tests/install.bats`

**Interfaces:**
- Consumes: `lib/common.sh`, all config templates.
- Produces: `install.sh [--prefix DIR] [--no-system]`. `--no-system` skips root-only steps (plists, firewall, operator account) so tests can run it unprivileged. Renders all configs into `$PREFIX/config`, copies `landing/`, creates `data/ run/ log/`. Produces `$PREFIX/config/operator-credentials.txt` (system installs only).

- [ ] **Step 1: Write the failing test `tests/install.bats`**

```bash
#!/usr/bin/env bats
load helpers

setup_file() {
  export PREFIX
  PREFIX=$(mktemp -d)
  run "$BATS_TEST_DIRNAME/../install.sh" --prefix "$PREFIX" --no-system
  [ "$status" -eq 0 ]
}

@test "renders chatto.toml with distinct generated secrets" {
  grep -qE "cookie_signing_secret = '[0-9a-f]{64}'" "$PREFIX/config/chatto.toml"
  s=$(grep -oE "[0-9a-f]{64}" "$PREFIX/config/chatto.toml" | sort -u | wc -l)
  [ "$s" -ge 4 ]
}

@test "chatto.toml is not world readable" {
  perms=$(stat -f '%Lp' "$PREFIX/config/chatto.toml")
  [ "$perms" = "600" ]
}

@test "rendered dnsmasq config passes dnsmasq --test" {
  run dnsmasq --test --conf-file="$PREFIX/config/dnsmasq.conf"
  [ "$status" -eq 0 ]
}

@test "rendered dnsmasq config binds the real wifi device" {
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  grep -qx "interface=$(detect_wifi_device)" "$PREFIX/config/dnsmasq.conf"
}

@test "caddyfile and portal installed and valid" {
  [ -f "$PREFIX/landing/index.html" ]
  run caddy validate --config "$PREFIX/config/Caddyfile" --adapter caddyfile
  [ "$status" -eq 0 ]
}

@test "install is idempotent and keeps existing secrets" {
  before=$(grep cookie_signing_secret "$PREFIX/config/chatto.toml")
  run "$BATS_TEST_DIRNAME/../install.sh" --prefix "$PREFIX" --no-system
  [ "$status" -eq 0 ]
  after=$(grep cookie_signing_secret "$PREFIX/config/chatto.toml")
  [ "$before" = "$after" ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/install.bats`
Expected: FAIL (install.sh missing).

- [ ] **Step 3: Write plists**

`config/org.emergencybox.chatto.plist.template` (mailpit template is identical
in shape; both run as the installing user via `@EBOX_USER@`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>org.emergencybox.chatto</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/chatto</string>
    <string>run</string>
    <string>-c</string>
    <string>/opt/emergency-box/config/chatto.toml</string>
  </array>
  <key>UserName</key><string>@EBOX_USER@</string>
  <key>WorkingDirectory</key><string>/opt/emergency-box/data</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/opt/emergency-box/log/chatto.log</string>
  <key>StandardErrorPath</key><string>/opt/emergency-box/log/chatto.log</string>
</dict>
</plist>
```

`config/org.emergencybox.mailpit.plist.template`: same structure with label
`org.emergencybox.mailpit` and ProgramArguments:
`/opt/homebrew/bin/mailpit --smtp 127.0.0.1:1025 --listen 127.0.0.1:8025
--database /opt/emergency-box/data/mailpit.db`, logs to `mailpit.log`.

`config/org.emergencybox.dnsmasq.plist` (root, no UserName key): label
`org.emergencybox.dnsmasq`, ProgramArguments:
`/opt/homebrew/sbin/dnsmasq --keep-in-foreground
--conf-file=/opt/emergency-box/config/dnsmasq.conf`, logs to `dnsmasq-daemon.log`.

`config/org.emergencybox.caddy.plist` (root): label `org.emergencybox.caddy`,
ProgramArguments: `/opt/homebrew/bin/caddy run --config
/opt/emergency-box/config/Caddyfile --adapter caddyfile`, logs to `caddy.log`.

`config/org.emergencybox.caffeinate.plist` (root): label
`org.emergencybox.caffeinate`, ProgramArguments: `/usr/bin/caffeinate -si`,
no log keys needed.

All five: `RunAtLoad` true, `KeepAlive` true (caffeinate too — it must
restart if killed).

- [ ] **Step 4: Write `install.sh`**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source lib/common.sh

PREFIX=/opt/emergency-box
SYSTEM=1
while [ $# -gt 0 ]; do
  case $1 in
    --prefix) PREFIX=$2; shift 2 ;;
    --no-system) SYSTEM=0; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

[ "$(uname -sm)" = "Darwin arm64" ] || { echo "Apple Silicon macOS only" >&2; exit 1; }
command -v brew >/dev/null || { echo "Homebrew required: https://brew.sh" >&2; exit 1; }

if [ "$SYSTEM" = 1 ] && [ "$(id -u)" -ne 0 ]; then
  echo "System install needs root; re-run: sudo $0" >&2
  exit 1
fi
EBOX_USER=${SUDO_USER:-$(id -un)}

echo "==> Installing packages (needs internet, one time only)"
pkgs=(dnsmasq caddy mailpit jq chattocorp/tap/chatto bats-core shellcheck bind)
if [ "$(id -u)" -eq 0 ]; then
  sudo -u "$EBOX_USER" brew install "${pkgs[@]}"
else
  brew install "${pkgs[@]}"
fi

echo "==> Laying out $PREFIX"
mkdir -p "$PREFIX"/{bin,lib,config,data,landing,run,log}

wifi_device=$(detect_wifi_device)
[ -n "$wifi_device" ] || { echo "no Wi-Fi device found" >&2; exit 1; }

if [ ! -f "$PREFIX/config/chatto.toml" ]; then
  render_template config/chatto.toml.template "$PREFIX/config/chatto.toml" \
    "COOKIE_SECRET=$(gen_secret)" "CORE_SECRET=$(gen_secret)" \
    "ASSETS_SECRET=$(gen_secret)" "NATS_TOKEN=$(gen_secret)" \
    "DATA_DIR=$PREFIX/data" "SMTP_PORT=1025"
  chmod 600 "$PREFIX/config/chatto.toml"
fi
render_template config/dnsmasq-dns.conf.template \
  "$PREFIX/config/dnsmasq-dns.conf" "BOX_IP=10.87.0.1"
render_template config/dnsmasq.conf.template "$PREFIX/config/dnsmasq.conf" \
  "CONFIG_DIR=$PREFIX/config" "WIFI_DEVICE=$wifi_device" \
  "DATA_DIR=$PREFIX/data" "LOG_DIR=$PREFIX/log"
cp config/Caddyfile "$PREFIX/config/Caddyfile"
cp landing/index.html "$PREFIX/landing/index.html"
cp lib/common.sh "$PREFIX/lib/common.sh"
cp bin/emergency-* "$PREFIX/bin/" 2>/dev/null || true

if [ "$SYSTEM" = 1 ]; then
  echo "==> Installing launchd daemons (dormant until emergency-on)"
  for t in config/org.emergencybox.*.plist.template; do
    out="/Library/LaunchDaemons/$(basename "${t%.template}")"
    render_template "$t" "$out" "EBOX_USER=$EBOX_USER"
  done
  cp config/org.emergencybox.{dnsmasq,caddy,caffeinate}.plist /Library/LaunchDaemons/
  chown root:wheel /Library/LaunchDaemons/org.emergencybox.*.plist
  chmod 644 /Library/LaunchDaemons/org.emergencybox.*.plist
  chown -R "$EBOX_USER" "$PREFIX/data" "$PREFIX/log"

  echo "==> Pre-authorizing binaries with the application firewall"
  fw=/usr/libexec/ApplicationFirewall/socketfilterfw
  for b in /opt/homebrew/bin/caddy /opt/homebrew/sbin/dnsmasq \
           /opt/homebrew/bin/chatto /opt/homebrew/bin/mailpit; do
    "$fw" --add "$b" >/dev/null || true
    "$fw" --unblockapp "$b" >/dev/null || true
  done

  if [ ! -f "$PREFIX/config/operator-credentials.txt" ]; then
    echo "==> Creating operator (admin) account"
    launchctl bootstrap system /Library/LaunchDaemons/org.emergencybox.chatto.plist
    deadline=$((SECONDS + 60))
    until curl -fsS --max-time 2 http://127.0.0.1:8080/healthz >/dev/null 2>&1; do
      ((SECONDS < deadline)) || { echo "chatto did not start" >&2; exit 1; }
      sleep 1
    done
    op_pw=$(openssl rand -base64 12)
    printf '%s' "$op_pw" | chatto operator \
      -c "$PREFIX/config/chatto.toml" user create \
      --login operator --password-stdin --verified-email operator@chat.lan
    printf 'login: operator\npassword: %s\n' "$op_pw" \
      >"$PREFIX/config/operator-credentials.txt"
    chmod 600 "$PREFIX/config/operator-credentials.txt"
    launchctl bootout system/org.emergencybox.chatto
  fi
  echo "Install complete. Activate with: sudo bin/emergency-on"
else
  echo "Install complete (no-system mode)."
fi
```

Note: `bin/emergency-*` doesn't exist until Task 5 — the `|| true` keeps
install working now; Task 5 removes nothing.

- [ ] **Step 5: Write `uninstall.sh`**

```bash
#!/bin/bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
for l in chatto mailpit dnsmasq caddy caffeinate; do
  launchctl bootout "system/org.emergencybox.$l" 2>/dev/null || true
  rm -f "/Library/LaunchDaemons/org.emergencybox.$l.plist"
done
echo "Daemons removed. Chat history lives in /opt/emergency-box/data."
read -rp "Delete /opt/emergency-box entirely? [y/N] " a
if [ "$a" = "y" ]; then rm -rf /opt/emergency-box; fi
echo "Done. Brew packages left installed (dnsmasq caddy mailpit chatto)."
```

- [ ] **Step 6: Run tests**

Run: `chmod +x install.sh uninstall.sh && ./test.sh`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "Add launchd daemons, install and uninstall scripts"
```

---

### Task 5: emergency-on / emergency-off / emergency-status

**Files:**
- Create: `bin/emergency-on`
- Create: `bin/emergency-off`
- Create: `bin/emergency-status`
- Test: `tests/scripts.bats`

**Interfaces:**
- Consumes: `lib/common.sh` (`detect_wifi_service`), installed plists and configs from Task 4.
- Produces: state marker `/opt/emergency-box/run/active`; `emergency-on [--hotspot] [--no-sleep]`; all three support `--help`.

- [ ] **Step 1: Write the failing test `tests/scripts.bats`**

Full activation takes over the network, so automated tests cover the safe
surface: help/arg contracts and wifi detection against the real system.
The full cycle is exercised by the README smoke checklist (Task 7).

```bash
#!/usr/bin/env bats

@test "emergency scripts show usage with --help" {
  for s in emergency-on emergency-off emergency-status; do
    run "$BATS_TEST_DIRNAME/../bin/$s" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
  done
}

@test "emergency-on rejects unknown flags" {
  run "$BATS_TEST_DIRNAME/../bin/emergency-on" --bogus
  [ "$status" -eq 2 ]
}

@test "wifi detection finds a real device and service" {
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  dev=$(detect_wifi_device)
  [[ "$dev" =~ ^en[0-9]+$ ]]
  svc=$(detect_wifi_service)
  [ -n "$svc" ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/scripts.bats`
Expected: FAIL (scripts missing).

- [ ] **Step 3: Write `bin/emergency-on`**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/common.sh 2>/dev/null || source /opt/emergency-box/lib/common.sh

PREFIX=/opt/emergency-box
HOTSPOT=0 NOSLEEP=0
usage() {
  cat <<'EOF'
Usage: sudo emergency-on [--hotspot] [--no-sleep]
Activates the emergency chat box: static IP + DHCP/DNS/portal/chat daemons.
  --hotspot   EXPERIMENTAL: the Mac broadcasts the wifi itself
  --no-sleep  also disable lid-closed sleep (pmset disablesleep 1)
EOF
}
while [ $# -gt 0 ]; do
  case $1 in
    --hotspot) HOTSPOT=1; shift ;;
    --no-sleep) NOSLEEP=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[ "$(id -u)" -eq 0 ] || { echo "needs root: sudo $0" >&2; exit 1; }

svc=$(detect_wifi_service)
echo "==> Static IP 10.87.0.1 on '$svc'"
networksetup -setmanual "$svc" 10.87.0.1 255.255.255.0 10.87.0.1
networksetup -setdnsservers "$svc" 10.87.0.1

echo "==> Starting daemons"
daemons=(chatto mailpit caddy caffeinate dnsmasq)
if [ "$HOTSPOT" = 1 ]; then
  bin/emergency-hotspot up   # Task 6; provides its own DNS arrangement
  daemons=(chatto mailpit caddy caffeinate)
fi
for l in "${daemons[@]}"; do
  launchctl bootstrap system "/Library/LaunchDaemons/org.emergencybox.$l.plist" \
    2>/dev/null || launchctl kickstart "system/org.emergencybox.$l"
done
[ "$NOSLEEP" = 1 ] && pmset -a disablesleep 1
date > "$PREFIX/run/active"

echo "==> Self-test"
fail() { echo "SELF-TEST FAILED: $1 (see $PREFIX/log/)" >&2; exit 1; }
deadline=$((SECONDS + 45))
until curl -fsS --max-time 2 http://127.0.0.1:8080/healthz >/dev/null 2>&1; do
  ((SECONDS < deadline)) || fail "chatto not healthy on :8080"
  sleep 1
done
curl -fsS --max-time 5 --resolve chat.lan:80:127.0.0.1 \
  http://chat.lan/healthz | grep -q ok || fail "caddy proxy for chat.lan"
curl -fsS --max-time 5 -H 'Host: captive.apple.com' http://127.0.0.1/ |
  grep -qi emergency || fail "portal page on :80"
curl -fsS --max-time 5 --resolve mail.lan:80:127.0.0.1 \
  http://mail.lan/api/v1/info >/dev/null || fail "mailpit via mail.lan"
if [ "$HOTSPOT" = 0 ]; then
  dig +short +time=2 +tries=2 "probe$RANDOM.example" @10.87.0.1 |
    grep -qx 10.87.0.1 || fail "wildcard DNS on 10.87.0.1"
fi

ssid=$(networksetup -getairportnetwork "$(detect_wifi_device)" |
  sed 's/^[^:]*: //' || true)
cat <<EOF

  EMERGENCY BOX ACTIVE
  Wifi network : ${ssid:-<join your bridge-mode AP>}
  Chat         : http://chat.lan   (phones: just join the wifi)
  Mail codes   : http://mail.lan
  Deactivate   : sudo emergency-off
EOF
```

- [ ] **Step 4: Write `bin/emergency-off`**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/common.sh 2>/dev/null || source /opt/emergency-box/lib/common.sh
case ${1:-} in
  --help|-h) echo "Usage: sudo emergency-off"; exit 0 ;;
  '') ;;
  *) echo "Usage: sudo emergency-off" >&2; exit 2 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo "needs root: sudo $0" >&2; exit 1; }

for l in dnsmasq caddy chatto mailpit caffeinate; do
  launchctl bootout "system/org.emergencybox.$l" 2>/dev/null || true
done
bin/emergency-hotspot down 2>/dev/null || true
svc=$(detect_wifi_service)
networksetup -setdhcp "$svc"
networksetup -setdnsservers "$svc" Empty
pmset -a disablesleep 0
rm -f /opt/emergency-box/run/active
echo "Emergency mode off; '$svc' restored to DHCP."
```

- [ ] **Step 5: Write `bin/emergency-status`**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/common.sh 2>/dev/null || source /opt/emergency-box/lib/common.sh
case ${1:-} in
  --help|-h) echo "Usage: emergency-status"; exit 0 ;;
esac
PREFIX=/opt/emergency-box
ok() { printf '  [ok] %s\n' "$1"; }
bad() { printf '  [!!] %s\n' "$1"; FAILED=1; }
FAILED=0

[ -f "$PREFIX/run/active" ] &&
  echo "State: ACTIVE since $(cat "$PREFIX/run/active")" ||
  echo "State: inactive"
for l in chatto mailpit dnsmasq caddy caffeinate; do
  launchctl print "system/org.emergencybox.$l" >/dev/null 2>&1 &&
    ok "daemon $l loaded" || bad "daemon $l not loaded"
done
ip=$(ipconfig getifaddr "$(detect_wifi_device)" 2>/dev/null || true)
[ "$ip" = "10.87.0.1" ] && ok "wifi IP is 10.87.0.1" || bad "wifi IP is ${ip:-none}"
curl -fsS --max-time 3 http://127.0.0.1:8080/healthz >/dev/null 2>&1 &&
  ok "chatto healthy" || bad "chatto not responding"
curl -fsS --max-time 3 -H 'Host: captive.apple.com' http://127.0.0.1/ 2>/dev/null |
  grep -qi emergency && ok "portal serving" || bad "portal not serving"
dig +short +time=2 +tries=1 probe.example @10.87.0.1 2>/dev/null |
  grep -qx 10.87.0.1 && ok "wildcard DNS answering" || bad "wildcard DNS silent"
leases=$(grep -c . "$PREFIX/data/dnsmasq.leases" 2>/dev/null || echo 0)
echo "  DHCP leases: $leases device(s)"
exit "$FAILED"
```

- [ ] **Step 6: Run tests**

Run: `chmod +x bin/emergency-* && ./test.sh`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "Add emergency-on/off/status activation scripts"
```

---

### Task 6: Hotspot fallback (EXPERIMENTAL)

**Files:**
- Create: `bin/emergency-hotspot`
- Modify: `config/dnsmasq.conf.template` (no change expected; verify only)
- Test: covered by `tests/scripts.bats` --help contract + manual protocol below

**Interfaces:**
- Consumes: `lib/common.sh`, dnsmasq DNS fragment template.
- Produces: `emergency-hotspot up|down|--help`. `up` enables macOS Internet Sharing over Wi-Fi (Mac becomes AP at `192.168.2.1`, macOS bootpd serves DHCP) and starts a DNS-only dnsmasq answering `192.168.2.1` wildcard. `emergency-on --hotspot` and `emergency-off` call these (wired in Task 5).

**Approach (verify live, in order):** macOS InternetSharing is controlled by
`/Library/Preferences/SystemConfiguration/com.apple.nat.plist` +
`launchctl kickstart -k system/com.apple.InternetSharing`. Its DHCP (bootpd)
advertises `192.168.2.1` as DNS, but the built-in forwarder is useless
offline. Candidate A: pf `rdr` redirecting `:53` on the bridge interface to a
local DNS-only dnsmasq on `127.0.0.1:53535`. Candidate B: patch
`/etc/bootpd.plist` DNS options. Implement A; keep B as a documented note.

- [ ] **Step 1: Write `bin/emergency-hotspot`**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/common.sh 2>/dev/null || source /opt/emergency-box/lib/common.sh
PREFIX=/opt/emergency-box
NAT=/Library/Preferences/SystemConfiguration/com.apple.nat

usage() {
  cat <<'EOF'
Usage: sudo emergency-hotspot up|down
EXPERIMENTAL: makes this Mac broadcast the emergency wifi itself
(Internet Sharing). Configure the network name once in
System Settings > General > Sharing > Internet Sharing (from: Ethernet /
any unused port, to: Wi-Fi) before first use.
EOF
}

up() {
  render_template config/dnsmasq-dns.conf.template \
    "$PREFIX/config/dnsmasq-hotspot.conf" "BOX_IP=192.168.2.1"
  /opt/homebrew/sbin/dnsmasq \
    --conf-file="$PREFIX/config/dnsmasq-hotspot.conf" \
    --port=53535 --listen-address=127.0.0.1 \
    --pid-file="$PREFIX/run/dnsmasq-hotspot.pid"
  defaults write "$NAT" NAT -dict-add Enabled -int 1
  launchctl kickstart -k system/com.apple.InternetSharing
  echo "rdr pass on bridge100 inet proto { tcp udp } from any to any port 53 -> 127.0.0.1 port 53535" |
    pfctl -a emergencybox -f - 2>/dev/null
  pfctl -e 2>/dev/null || true
  echo "Hotspot up: phones join the shared network; portal at any URL."
}

down() {
  pfctl -a emergencybox -F all 2>/dev/null || true
  defaults write "$NAT" NAT -dict-add Enabled -int 0
  launchctl kickstart -k system/com.apple.InternetSharing 2>/dev/null || true
  [ -f "$PREFIX/run/dnsmasq-hotspot.pid" ] &&
    kill "$(cat "$PREFIX/run/dnsmasq-hotspot.pid")" 2>/dev/null || true
  rm -f "$PREFIX/run/dnsmasq-hotspot.pid"
}

case ${1:-} in
  up) [ "$(id -u)" -eq 0 ] || { echo "needs root" >&2; exit 1; }; up ;;
  down) [ "$(id -u)" -eq 0 ] || { echo "needs root" >&2; exit 1; }; down ;;
  --help|-h) usage ;;
  *) usage >&2; exit 2 ;;
esac
```

- [ ] **Step 2: Extend `tests/scripts.bats` help-contract loop**

Add `emergency-hotspot` to the `--help` test's script list.

- [ ] **Step 3: Run tests**

Run: `./test.sh`
Expected: PASS.

- [ ] **Step 4: Record the live verification protocol**

This cannot run in this session (enabling hotspot cuts the Mac's own
network). Add to the README smoke checklist (Task 7): configure Internet
Sharing once in System Settings, run `sudo bin/emergency-on --hotspot`,
join from a phone, confirm portal pops and `chat.lan` loads. If pf
redirection fails on the current macOS, mark `--hotspot` unsupported in
README troubleshooting and file the bootpd.plist fallback as future work.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Add experimental Mac-as-hotspot fallback"
```

---

### Task 7: README (the 1-doc) + printable sign

**Files:**
- Create: `README.md`
- Create: `docs/sign.md`

**Interfaces:**
- Consumes: everything above; commands must match the real scripts verbatim.

- [ ] **Step 1: Write `README.md`** with exactly these sections:

1. **What this is** — offline emergency chat on an Apple Silicon Mac +
   any router in bridge mode; phones just join the wifi.
2. **One-command setup** (needs internet once):
   `git clone <repo> && cd emergency-box && sudo ./install.sh`
   plus the LLM-agent variant: "point your agent at this repo and say:
   *follow README.md to install, then run the test suite*".
3. **When emergency strikes** — power the AP, `sudo bin/emergency-on`,
   read the printed status; `--no-sleep` for lid-closed; hotspot variant.
4. **How people join** — join wifi → captive popup portal → pick
   name/password → sign in at `chat.lan`. Codes readable at `mail.lan`.
   Operator credentials in `/opt/emergency-box/config/operator-credentials.txt`.
5. **Router bridge-mode recipe** — generic steps (disable DHCP/NAT or set
   AP/bridge mode, note the SSID); verify: with the Mac off, phones joining
   get no IP (169.254.x) — that's correct.
6. **Smoke checklist** (the full cycle, run once after install):
   AP on → `emergency-on` → self-test passes → iPhone joins → popup →
   create account → Android joins → notification → create account →
   exchange a message both ways in a room → reboot the Mac → wait →
   `emergency-status` all-ok and chat still has history → phones still
   chat → `emergency-off` → normal wifi works, `dig google.com` resolves
   normally.
7. **Troubleshooting** — self-test failure meanings (port 53/80 squatters,
   VPN DNS proxies), `emergency-status`, log locations, Android "no
   internet" prompt, iOS popup instructions, hotspot experimental status.
8. **Uninstall** — `sudo ./uninstall.sh`.
9. **Design notes** — link to `docs/superpowers/specs/`.

- [ ] **Step 2: Write `docs/sign.md`** — a print-ready page: big SSID
placeholder, "1. Join wifi ___  2. A welcome screen appears — follow it
3. Chat at http://chat.lan". Note the optional QR one-liner:
`qrencode -o sign-qr.png 'WIFI:T:WPA;S:<ssid>;P:<password>;;'`.

- [ ] **Step 3: Verify doc accuracy**

Run every command quoted in README against `--help`/`ls` to confirm paths
and flags exist exactly as written. Expected: no drift.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "Add README runbook and printable sign"
```

---

### Task 8: Full verification pass

**Files:**
- Modify: whatever the pass uncovers.

- [ ] **Step 1: Full suite** — `./test.sh` → all green.
- [ ] **Step 2: Real system install** — `sudo ./install.sh` on this Mac
  (safe: daemons stay dormant; operator account created via a brief
  chatto bootstrap on localhost). Verify `/Library/LaunchDaemons` plists,
  `operator-credentials.txt`, and that `launchctl print` shows nothing
  running afterwards.
- [ ] **Step 3: Browser-drive the portal** — start the Task 3 test stack
  (chatto + mailpit + caddy on :18080), open `http://127.0.0.1:18080` in
  Chrome, create an account through the portal UI for real, then log in to
  chatto at `http://127.0.0.1:8080` with it. This proves the portal JS
  end-to-end without touching the network.
- [ ] **Step 4: Idempotence** — run `sudo ./install.sh` again; expect
  "keeps existing secrets" behavior and no errors. Run
  `sudo ./uninstall.sh` answering `N`; then `sudo ./install.sh` to restore.
- [ ] **Step 5: Leave the phone/AP smoke checklist to the user** — print
  its location and stop; do not attempt `emergency-on` while this Mac is
  associated to a normal network.
- [ ] **Step 6: Commit fixes**

```bash
git add -A && git commit -m "Verification pass fixes"
```
