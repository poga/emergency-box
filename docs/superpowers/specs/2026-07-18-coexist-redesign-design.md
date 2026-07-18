# Emergency Box — Coexist Redesign

**Date:** 2026-07-18
**Status:** Approved pending spec review
**Supersedes:** `2026-07-18-emergency-box-design.md` (network-takeover design)

## Goal

Rewrite emergency-box as an **always-on LAN chat bolted onto the normal
wifi** — no network takeover, no mode switch. The router stays exactly as it
is; the Mac runs the chat 24/7 at `http://chat.local`. When the internet
dies, nothing needs activating: while the router and Mac have power, the
chat keeps working, and people already know it because they could use it
every day. Familiarity is the emergency feature.

## Decisions

| Question | Decision |
|---|---|
| Topology | Normal home wifi, untouched; router keeps serving DHCP |
| Takeover machinery | Deleted entirely (dnsmasq, captive portal, emergency-on/off, hotspot); git history preserves it |
| Discovery | One name: `chat.local` via Bonjour proxy (`dns-sd -P`), no Mac rename; QR-with-IP fallback for old Androids (router DHCP reservation) |
| Registration | No email, no mailpit: physical wifi presence is the trust boundary. A tiny local service (joind) creates accounts via chatto's Operator API |
| Chatto email flow | `auth.direct_registration = false`, no `[smtp]` — chatto's own register UI shows "not available", funneling users to `/join` |
| Ops model | 4 launchd services, enabled + RunAtLoad, started at install, always on |
| Emergency procedure | One printed line: nothing to activate; plug the Mac in, `caffeinate -s` or lid open |

## Architecture

Four always-on launchd services (labels `org.emergencybox.{chatto,joind,caddy,bonjour}`):

- **chatto** — unchanged binary, `127.0.0.1:8080`, `webserver.url =
  'http://chat.local'`, `direct_registration = false`, no `[smtp]`,
  operator API socket in the data dir. Runs as the installing user.
- **joind** — new: a small Python 3 (stdlib-only) HTTP service on
  `127.0.0.1:8081`, one endpoint `POST /join` with JSON `{login, password}`.
  Validates login against chatto's rules (2–32 chars, `[a-z0-9._-]`,
  lowercased) and password length (8–128), then execs
  `chatto operator user create --login <x> --password-stdin --json`
  (argument array, never a shell string; password via stdin). Maps results:
  201 created; 409 login taken; 400 invalid input; 502 operator failure
  (body: short human-readable `error`). Light rate limit: global token
  bucket, burst 10, refill 1/sec, 429 when exhausted — so a misbehaving
  client can't hammer the operator socket.
  Runs as the installing user — the operator socket is owned by the same
  user chatto runs as; no root anywhere in the request path.
- **Caddy** (`:80`) — single-origin, path-split routing: `/join*` → portal
  page (file_server), `/joinapi` → `127.0.0.1:8081/join`, everything else →
  chatto (UI, `/auth/*`, websockets). Runs as root (port 80).
- **bonjour** — `dns-sd -P` proxy registration publishing `chat.local` →
  the Mac's current IP, as a launchd service. Does not rename the Mac.
  (dns-sd registers while running; KeepAlive restarts it. IP changes are
  why the README tells users to set a router DHCP reservation.)

**Portal (`/join`)**: same self-contained page, drastically simplified JS —
one `fetch('/joinapi', {login, password})`, then a success card linking to
`http://chat.local` ("sign in with your new account"). Errors are plain
words ("that name is taken"). Enter-to-submit kept (addEventListener form
wiring — never inline handlers; see prior regression).

**Python 3 availability:** install.sh already requires Homebrew, which
requires the Xcode CLT, which provides `/usr/bin/python3`. joind uses only
the stdlib (http.server, json, subprocess, re).

## Deletions

Removed from the repo (all preserved in git history):

- dnsmasq: both config templates, plist, `tests/dns.bats`
- mailpit: plist, `[smtp]` config, `/mailapi` + `/mail` routes, the
  code-polling portal JS, mail fallback copy
- Captive portal wildcard DNS behavior and probe handling
- `bin/emergency-on`, `bin/emergency-off`, `bin/emergency-hotspot`,
  SSID-takeover gate, activation self-test, state marker, dormancy
  enable/disable dance
- caffeinate plist
- Bridge-mode AP recipe, takeover smoke checklist, `--hotspot` docs

`bin/emergency-status` is replaced by `bin/status`: services loaded, chatto
`/healthz`, joind health (`GET /join` → 405), port 80 serving chatto,
`chat.local` resolving (dscacheutil).

## Lifecycle

- **install.sh** (once, online; system mode needs sudo): brew install
  caddy + chattocorp/tap/chatto (+ dev/test tools); render configs with
  fresh secrets (chmod 600, owned by the service user); install 4 plists
  root:wheel 644, `launchctl enable` + `bootstrap` them immediately;
  wait for chatto `/healthz`; create the operator/owner account via
  `chatto operator user create` (credentials file chmod 600); firewall
  pre-authorize binaries. `--prefix` + `--no-system` kept for tests
  (custom prefix remains test-only, refused with system mode).
- **Reboot**: services return automatically — now the desired behavior.
- **uninstall.sh**: bootout + remove plists, optional `rm -rf` of the
  prefix after typed confirmation. No network restore (networking is
  never touched).
- **Known constraints** (documented in README): Caddy owns port 80 on the
  Mac permanently; a sleeping laptop is a sleeping chat room (emergency
  card: plug in + `caffeinate -s`); `.local` needs mDNS (old Androids use
  the QR/IP fallback).

## Error handling

- joind never passes user input through a shell; login regex enforced
  before exec; all failures return structured JSON errors the portal shows
  verbatim.
- Duplicate names surface as "that name is taken — pick another".
- chatto down → joind returns 502 "chat server is starting — try again";
  portal shows it and stays retryable.
- `bin/status` is the single diagnostic entry point.
- install.sh keeps the operator-bootstrap failure trap (bootout on abort)
  adapted to the always-on model (service stays up on success).

## Testing

Real processes, no mocks; `./test.sh` = shellcheck + bats.

- **joind.bats**: real chatto + real joind; `POST /joinapi`-equivalent on
  joind directly: creates account → real `POST /auth/login` succeeds;
  duplicate login → 409; short password → 400; bad login chars → 400;
  `POST /auth/register` on chatto → 403 (email path closed).
- **caddy_routing.bats** (updated): `/` serves chatto; `/join` serves the
  portal HTML; `/joinapi` reaches joind (400 on empty body); websocket
  upgrade path untouched.
- **install.bats**: unchanged idempotence/permissions coverage, minus
  deleted components; plists lint.
- **bonjour**: with the publisher running, `dscacheutil -q host -a name
  chat.local` resolves to a local IP (best-effort assertion, skipped with
  a loud message if mDNS is unavailable in the environment).
- **Browser drive of `/join` is definition-of-done** for any portal
  change: real Chrome (CDP), click and Enter paths, then API login check.

## Resolved facts (carried from v1)

- `chatto operator user create --login X --password-stdin --verified-email
  … --json` creates users via the root-equivalent operator Unix socket;
  socket path set by `[operator_api]` in chatto.toml.
- `CHATTO_AUTH_DIRECT_REGISTRATION=false` → register API returns 403
  `{"error":"Registration is disabled"}` and the UI shows "Registration is
  not available on this instance."
- `GET /healthz` → `{"status":"ok"}`; `POST /auth/login {login, password}`.

## Out of scope

- Any takeover/AP mode; HTTPS; voice/video; non-Apple-Silicon hosts.
- Day-to-day internet for the chat clients is neither provided nor blocked
  by this system — the chat is purely additive.
