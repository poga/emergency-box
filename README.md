# Emergency Box

## 1. What this is

Turn an Apple Silicon Mac plus any home router (switched to bridge/AP
mode) into an offline emergency chat room. No internet, no cell service,
no extra hardware — phones just join the wifi and chat with everyone
else nearby. Everything needed is installed once, in advance, while you
still have internet; activation later needs none.

## 2. One-command setup (needs internet once)

```bash
git clone <repo> && cd emergency-box && sudo ./install.sh
```

Requires an Apple Silicon Mac and [Homebrew](https://brew.sh) already
installed. `install.sh` installs dnsmasq/caddy/mailpit/chatto (plus
jq, bats-core, shellcheck, bind) via brew, lays out
`/opt/emergency-box`, installs 5 launchd daemons disabled — enabled
only while emergency mode is active — pre-authorizes them with the
application firewall, and creates the chat admin ("operator") account.
Credentials are written to
`/opt/emergency-box/config/operator-credentials.txt` — save them
somewhere safe.

**LLM-agent variant:** point your coding agent at this repo and say:
*follow README.md to install, then run the test suite.*

## 3. When emergency strikes

1. Power on the router in bridge mode (see section 5).
2. On this Mac, join the emergency AP's wifi network from the normal
   Wi-Fi menu — dnsmasq needs the Mac already associated before it can
   bind DHCP/DNS on that network.
3. From the cloned repo directory:
   ```bash
   sudo bin/emergency-on --yes
   ```
   `emergency-on` normally prompts you to confirm the wifi network name
   before taking it over with DHCP+DNS; `--yes` skips that prompt since
   you already confirmed it in step 2. This sets a static IP, starts the
   five daemons, then runs a 5-layer self-test (chatto health, chat.lan
   routing, portal page, mail.lan, wildcard DNS). It only prints
   `EMERGENCY BOX ACTIVE` — with the wifi name, `chat.lan`, `mail.lan` —
   after every layer passes.
4. Lid-closed / running unattended: add `--no-sleep` (also disables
   sleep via `pmset`; a `caffeinate` daemon already blocks idle sleep
   while active).
5. No second router available: `sudo bin/emergency-on --hotspot --yes`
   makes the Mac broadcast the network itself (EXPERIMENTAL). It needs a
   one-time setup first: System Settings > General > Sharing > Internet
   Sharing, share from Ethernet (or any unused port) to Wi-Fi.
6. If the self-test fails, it prints which layer and tells you to run
   `sudo bin/emergency-off` to roll back before retrying — see
   Troubleshooting.

## 4. How people join

1. Phone joins the wifi network you just announced.
2. A captive-portal popup appears (iOS: a wifi sign-in sheet; Android: a
   "sign in to network" notification) showing the **Emergency Chat**
   page.
3. Pick a username and password, tap **Create account**. The page
   automates chatto's email-code registration behind the scenes.
4. On success it says "Account ready" — leave the popup (iOS: tap
   Done/Cancel, choose "Use Without Internet") and open **Safari or
   Chrome**, not the popup itself, then go to **http://chat.lan** and
   sign in.
5. If automatic signup fails, the page shows a fallback: register
   manually at `chat.lan/register` with any `@chat.lan` email, then read
   the 6-digit code at **http://mail.lan**.
6. Chat admin login is in
   `/opt/emergency-box/config/operator-credentials.txt`.

## 5. Router bridge-mode recipe

Every router differs, but the pattern is the same:

1. Log into the router's admin page (address + default password are
   usually on a sticker on the router itself).
2. Find the WAN/Internet mode setting and switch it to **Bridge
   mode** (or **Access Point mode** — wording varies by brand). This
   turns off the router's own DHCP server and NAT/routing.
3. Note the SSID (and password, if any) the router is still
   broadcasting for wifi — that's the network people join.
4. Save/reboot the router.
5. **Verify:** with the Mac powered off (before `emergency-on`), join
   that SSID from a phone. It should get no usable IP (a `169.254.x.x`
   self-assigned address, or nothing) — that confirms the router isn't
   handing out its own DHCP anymore. The Mac supplies DHCP/DNS once
   activated.

## 6. Smoke checklist (run once after install, full cycle)

Do this end-to-end before trusting the box in a real emergency. Each
step names what to actually observe — don't just run the command.

1. Power on the bridge-mode AP.
2. On this Mac, join the emergency AP's wifi network.
3. `sudo bin/emergency-on --yes` (skips the wifi take-over confirmation
   prompt — you already confirmed the AP network in step 2) — wait for
   `EMERGENCY BOX ACTIVE`. If you see `SELF-TEST FAILED` instead, stop
   and read Troubleshooting.
4. Join the printed wifi network from an iPhone. Confirm a sign-in
   popup shows the Emergency Chat page within a few seconds.
5. Create an account in the popup. Confirm it shows "Account ready".
6. Tap Done/Cancel, open Safari, go to `http://chat.lan`, sign in.
   Confirm the chat UI loads.
7. Join the same network from an Android phone. Confirm Android shows a
   "no internet, stay connected?" prompt — tap to stay connected.
8. Create an account via the notification/portal page, then sign in at
   `http://chat.lan` on Android. Confirm the chat UI loads there too.
9. In a shared room, send a message from the iPhone and confirm it
   appears on the Android phone, then send one back the other way.
   Confirm both directions land.
10. Reboot the Mac (simulating a mid-emergency power blip). Wait for it
    to finish booting.
11. Run `bin/emergency-status` and keep re-running it until every line
    reads `[ok]` (daemons, wifi IP, chatto, portal, DNS) or it clearly
    stalls — don't declare success on a fixed timer.
12. On both phones, confirm the earlier messages are still in the room,
    then send one more message each way to confirm chat still works
    post-reboot.
13. `sudo bin/emergency-off`. Confirm it prints that wifi was restored
    to DHCP.
14. Confirm the Mac's normal wifi/internet works again, e.g.
    `dig google.com` resolves real public IPs (not `10.87.0.1`).

## 7. Troubleshooting

- **Self-test failure on activation** — the message names the failing
  layer:
  - `chatto not healthy on :8080` — chatto didn't start; check
    `/opt/emergency-box/log/chatto.log`.
  - `caddy proxy for chat.lan` / `portal page on :80` — something else
    is already bound to port 80 (a local dev server, another web
    server); free the port and retry.
  - `mailpit via mail.lan` — check `/opt/emergency-box/log/mailpit.log`.
  - `wildcard DNS on 10.87.0.1` — something else is already bound to
    port 53 (a VPN client's local DNS proxy is the usual culprit), or
    this Mac isn't joined to the emergency wifi network; disconnect the
    VPN or join the network and retry.
  - After any failure: `sudo bin/emergency-off` cleans up partial state,
    then try `sudo bin/emergency-on` again.
- **`bin/emergency-status`** (no sudo needed) is the single diagnostic
  entry point: daemon state, wifi IP, chatto/portal/DNS health, and the
  DHCP lease count.
- **Logs** live in `/opt/emergency-box/log/`: `chatto.log`,
  `mailpit.log`, `caddy.log`, `dnsmasq.log` (DHCP/startup log, not
  queries), `dnsmasq-daemon.log`.
- **Android "no internet, stay connected?"** — expected; the network
  genuinely has no internet. Tap to stay connected/keep the connection.
- **iOS captive popup** — if it won't cooperate, tap Done or Cancel on
  the popup, then open Safari yourself and go to `http://chat.lan`.
- **`--hotspot` is EXPERIMENTAL** — Internet Sharing needs the one-time
  System Settings pre-configuration (section 3) before first use, and
  is generally less reliable than a real bridge-mode router. Prefer
  section 5 when any second router/AP is available.

## 8. Uninstall

```bash
sudo ./uninstall.sh
```

If emergency mode was left active (or a prior activation crashed), it
first restores normal wifi DHCP/DNS on a best-effort basis, then removes
the launchd daemons. Chat history stays in `/opt/emergency-box/data`
unless you agree to the prompt to delete `/opt/emergency-box` entirely.
Homebrew packages are left installed.

## 9. Design notes

Full design rationale and decisions:
[`docs/superpowers/specs/2026-07-18-emergency-box-design.md`](docs/superpowers/specs/2026-07-18-emergency-box-design.md).
