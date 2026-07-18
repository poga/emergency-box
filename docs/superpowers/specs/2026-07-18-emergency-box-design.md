# Emergency Box — Design

**Date:** 2026-07-18
**Status:** Approved pending spec review

## Goal

Turn a daily-driver Apple Silicon Mac plus any home router (in bridge/AP mode)
into an offline emergency chat room for people on the same wifi, using
[chatto](https://github.com/chattocorp/chatto). The deliverable is one repo:
a README a human or LLM agent can follow in one pass, backed by tested
scripts. After one-time install (with internet), activation never needs
internet again.

## Decisions

| Question | Decision |
|---|---|
| Deliverable | README (the "1 doc / 1 prompt") + tested scripts |
| Topology | Bridge-mode AP primary; Mac-as-hotspot fallback |
| Discovery UX | Captive-portal style: wildcard DNS + landing page |
| Feature scope | Text chat over plain HTTP (no HTTPS, no voice/video) |
| Registration | Chatto's email-code flow, satisfied locally by mailpit; portal page automates it |
| Ops model | Installed launchd services, dormant until activated |
| Activation | Manual `emergency-on` / `emergency-off` scripts, no SSID watcher |
| Host | Daily-driver Mac; normal networking untouched when inactive |

## Architecture

Four off-the-shelf pieces on the Mac, orchestrated by shell scripts:

- **dnsmasq** — DHCP server (`10.87.0.50–250`) + wildcard DNS resolving
  every hostname to the Mac.
- **Caddy** (port 80) — serves the captive portal page for any host;
  reverse-proxies host `chat.lan` to chatto and `mail.lan` to mailpit;
  exposes `/auth/*` (chatto) and `/mailapi/*` (mailpit API) on the portal
  host so portal JS works same-origin.
- **chatto** — single Go binary with built-in DB (embedded NATS), on
  `127.0.0.1:8080`. `GET /healthz` for health checks.
- **mailpit** — local mail catcher (SMTP `127.0.0.1:1025`, API/UI
  `127.0.0.1:8025`). Chatto registration is email-first (a 6-digit code is
  emailed and a mailer is required); mailpit closes that loop offline.

**Registration UX:** the portal page automates the whole dance client-side:
user picks a name + password → JS calls `POST /auth/register` with
`<name>@chat.lan`, polls the mailpit API for the code, then
`/auth/register/verify-code` and `/auth/register/complete`. On success the
portal shows "account ready — open chat.lan and sign in". Manual fallback:
register in chatto's UI and read the code at `mail.lan`. An operator/owner
account is created at install time via chatto's root-only Operator API
(`chatto operator user create`), with `[owners] emails` granting admin.

### Network design

- AP in bridge/AP-only mode broadcasts the emergency SSID; no upstream
  internet, no DHCP from the AP. The Mac joins that wifi.
- `emergency-on` sets the Wi-Fi service to static `10.87.0.1/24`
  (range chosen to avoid common home/corp collisions). dnsmasq advertises
  the Mac as gateway and DNS.
- Chat home address is `http://chat.lan`. Not `.local`: phones route
  `.local` lookups to mDNS, bypassing our DNS, unreliable on Android.

### Captive-portal flow

Phone joins wifi → OS probes a known URL (`captive.apple.com` etc.) →
wildcard DNS sends the probe to Caddy → non-"Success" response triggers the
OS sign-in popup showing our landing page: "Emergency network connected —
open your browser and go to chat.lan" with link + QR code. The captive
webview is a signpost, not the venue: chatting happens in the real browser,
avoiding sandboxed-popup quirks (lost sessions, killed websockets). Any URL
typed into any browser also lands on this page.

### Fallback: Mac as AP

`emergency-on --hotspot` makes the Mac broadcast the network itself via
Internet Sharing (no extra hardware). macOS's sharing stack runs its own
DHCP, so this variant configures dnsmasq for DNS only. Known to be finicky;
gets its own implementation-phase verification before being documented as
supported.

## Repo layout

```
emergency-box/
├── README.md              # quickstart + how it works + manual smoke checklist
├── install.sh             # one-time setup (the only step needing internet)
├── uninstall.sh           # clean removal from the host Mac
├── bin/
│   ├── emergency-on       # activate (--hotspot, --no-sleep, --yes flags)
│   ├── emergency-off      # deactivate, restore normal networking
│   └── emergency-status   # daemons, IP, DNS answer, leases, chatto health
├── lib/common.sh          # shared: secrets, template render, wifi detection
├── config/
│   ├── dnsmasq.conf.template
│   ├── dnsmasq-dns.conf   # wildcard-DNS fragment, shared with tests
│   ├── Caddyfile
│   ├── chatto.toml.template
│   └── *.plist            # daemons: chatto, dnsmasq, caddy, mailpit, caffeinate
├── landing/index.html     # self-contained portal page (registration automation)
└── tests/*.bats           # bats-core suite + shellcheck lint
```

## Lifecycle

- **install.sh** (once, online): brew install dnsmasq, caddy, mailpit, and
  chatto (`chattocorp/tap/chatto`); generate secrets and render configs;
  place plists; create the operator account; pre-authorize binaries with
  the application firewall. Everything needed later is cached locally.
- **emergency-on**: confirm SSID takeover (skippable with `--yes`) →
  static IP → `launchctl bootstrap` the five daemons → state marker →
  self-test each layer → print one-screen status (SSID to join,
  `chat.lan`). The caffeinate daemon prevents idle sleep while active;
  `--no-sleep` additionally applies `pmset disablesleep 1` for lid-closed use.
- **emergency-off**: bootout daemons, restore Wi-Fi DHCP (best-effort),
  revert pmset, clear state. Re-runs cleanly after a crashed activation.
- **Reboot survival**: plists live in `/Library/LaunchDaemons`; an activated
  box that loses power comes back in emergency mode (static IP persists).
  Deactivation fully unloads, so normal days are unaffected.
- **Sudo**: ports 53/67/80 and network changes need root; scripts sudo
  internally and say why.

## Error handling

- Activation self-test verifies each layer (ports actually bound by us,
  wildcard DNS answering, `chat.lan` routing, chatto healthy) and names the
  culprit on failure (VPN DNS proxy on :53, dev server on :80). No silent
  half-activated state.
- `emergency-on` shows the currently associated SSID and requires
  interactive confirmation before taking it over with DHCP+DNS
  (skippable with `--yes` once confirmed), and dnsmasq binds only to the
  Wi-Fi interface and only serves `10.87.0.x`, which exists only under
  the emergency static IP — bounding takeover to a network the operator
  explicitly confirmed.
- Phone quirks (Android "no internet, stay connected?", iOS popup behavior)
  are explained on the landing page where users encounter them.
- README includes a generic "any router → bridge mode" recipe and how to
  verify the AP is not serving DHCP.
- `emergency-status` is the single diagnostic entry point.

## Testing

Real processes, real protocols, no mocks.

**Automated (safe on a live Mac, no network takeover):**

- dnsmasq on loopback/alt port; real `dig`: random hostnames → `10.87.0.1`.
- Caddy via real `curl`: `Host: chat.lan` proxies to chatto; any other host
  returns the landing page; captive probe paths return non-Success.
- chatto + mailpit started for real; full registration round-trip through
  the actual endpoints (`/auth/register` → code from mailpit API →
  `verify-code` → `complete` → `/auth/login`) — proves offline
  self-registration end-to-end.
- Config validation: `dnsmasq --test`, `caddy validate`, `shellcheck`.

**Manual smoke checklist (README, full cycle):** AP on → `emergency-on` →
iPhone joins → popup appears → Android joins → sign-in notification →
both register at `chat.lan` → exchange a message → reboot the Mac
mid-emergency → box recovers → `emergency-off` → normal wifi works again.

## Resolved research (facts verified against chatto v0.4.13)

- Install: `brew install chattocorp/tap/chatto`; config via `chatto.toml`
  (`webserver.url/port`, `cookie_signing_secret`, `core.secret_key`,
  `core.assets.signing_secret`, `[smtp]`, `[nats.embedded]`, `[owners]`).
- Registration requires a mailer: `POST /auth/register` {email} →
  emailed 6-digit code → `POST /auth/register/verify-code` {email, code} →
  `{completionToken}` → `POST /auth/register/complete`
  {token, login, password, passwordConfirmation} → verified user + session.
  CSRF middleware exempts requests without an existing session cookie.
- `POST /auth/login` accepts {login, password}. Health: `GET /healthz`.
- Operator API (`[operator_api]` Unix socket) + `chatto operator user
  create --login X --password … --verified-email …` creates users directly.

## Implementation-phase research items

- Internet Sharing activation from CLI and DHCP coexistence for `--hotspot`.
- Best-effort captive-popup escape UX on iOS (CNA) and Android; portal page
  copy tuned to observed behavior on real devices.

## Out of scope

- HTTPS, voice/video calls, screen share (needs per-phone cert trust).
- Non-Apple-Silicon hosts, Linux/Windows.
- Multi-laptop federation or mesh; one Mac serves one room.
- Automatic activation (SSID watchers); activation is always explicit.
