# Emergency Box

## 1. What this is

An always-on chat room for your wifi that keeps working when the
internet dies. There is nothing to activate in an emergency — it runs
every day, on the network you already use, so people already know how
to reach it when it matters.

An Apple Silicon Mac runs the chat ([chatto](https://github.com/chattocorp/chatto))
on your normal home wifi. The router is never reconfigured. As long as
the router and the Mac both have power, the chat works — before,
during, and after an internet outage.

## 2. One-command setup (needs internet once)

```bash
git clone <repo> && cd emergency-box && sudo ./install.sh
```

**LLM-agent variant:** point your coding agent at this repo and say:
*follow README.md to install, then run the test suite.*

Requires an Apple Silicon Mac and [Homebrew](https://brew.sh) already
installed. `install.sh` installs caddy and chatto (plus jq, bats-core,
shellcheck for testing) via brew, lays out `/opt/emergency-box`,
installs and starts 4 always-on launchd services, pre-authorizes them
with the application firewall, and creates the chat admin ("operator")
account. Credentials are written to
`/opt/emergency-box/config/operator-credentials.txt` — save them
somewhere safe. Internet is only needed for this one step.

After install:

- **Chat:** http://chat.local
- **Sign up:** http://chat.local/join

## 3. Set a DHCP reservation

One-time router step. The Mac's IP can change over time (e.g. after a
router reboot), and the printed sign (section 4, `docs/sign.md`) has a
fallback link baked in as plain text — a DHCP reservation keeps that
fallback valid indefinitely instead of going stale.

Find the Mac's current wifi IP and MAC address:

```bash
dev=$(networksetup -listallhardwareports | awk '/Hardware Port: Wi-Fi/{getline; print $2; exit}')
ipconfig getifaddr "$dev"
networksetup -getmacaddress "$dev"
```

(Or: System Settings > Network > Wi-Fi > Details.)

Log into the router's admin page (address + default password are
usually on a sticker on the router), find the DHCP reservation /
static lease setting, and bind the Mac's MAC address to its current
IP. Save/reboot the router if it asks.

## 4. How people join

1. Phone joins the household wifi like normal.
2. Go to **http://chat.local/join**, pick a username and password, tap
   **Create account**.
3. On success, tap **Open the chat**, then sign in at
   **http://chat.local**.
4. Old Android phones/browsers that can't resolve `.local` names: use
   the QR code or `http://<mac-ip>/join` fallback printed on the sign
   (`docs/sign.md`) instead — both the join page and the chat itself
   work the same over the plain IP.
5. Chat admin login is in
   `/opt/emergency-box/config/operator-credentials.txt`.

## 5. When the internet dies

Nothing to do. While the router and this Mac have power, the chat
stays up — there is no mode to switch on.

Keep the Mac powered and awake: plug it in, and either run
`caffeinate -s` in a terminal or keep the lid open, so it can't sleep.
A sleeping Mac is a sleeping chat room.

## 6. Smoke checklist (run once after install, full cycle)

Do this end-to-end before trusting the box. Each step names what to
actually observe — don't just run the command.

1. On a phone already on the household wifi, go to
   `http://chat.local/join`. Confirm the join page loads.
2. Pick a username and password, tap **Create account**. Confirm
   "Account ready" appears.
3. Tap **Open the chat**, sign in. Confirm the chat UI loads.
4. From a second device on the same wifi (another phone, or a laptop
   browser), join and sign in the same way, then send a message.
   Confirm it appears on the first phone, and a reply sent back lands
   too — both directions.
5. Restart the Mac (simulating a power blip). Wait for it to finish
   booting — no manual step needed after that.
6. Run `/opt/emergency-box/bin/status` and keep re-running it until
   every line reads `[ok]`, or it clearly stalls — don't declare
   success on a fixed timer.
7. On both devices, confirm the earlier messages are still in the
   room, then send one more message each way to confirm chat still
   works post-reboot.
8. Unplug the WAN/internet cable from the router (leave the router and
   Mac powered) — this simulates the internet dying.
9. Send another message between the two devices. Confirm it still
   arrives: the chat never depended on the WAN link.
10. Plug the WAN cable back in.

## 7. Troubleshooting

`/opt/emergency-box/bin/status` is the single diagnostic entry point.
Line by line:

- **`daemon chatto/joind/caddy/bonjour not loaded`** — that launchd
  service isn't running; re-run `sudo ./install.sh` (safe to repeat)
  or inspect `sudo launchctl print system/org.emergencybox.<name>`.
- **`chatto not responding`** — check
  `/opt/emergency-box/log/chatto.log`.
- **`joind not responding`** — check
  `/opt/emergency-box/log/joind.log`.
- **`caddy not serving on :80`** / **`portal not serving`** — port 80
  is likely taken by something else on the Mac (another local web
  server); free it and re-run install, or check
  `/opt/emergency-box/log/caddy.log`. Caddy owns port 80 on this Mac
  permanently, by design.
- **`chat.local not resolving (bonjour)`** — check
  `/opt/emergency-box/log/bonjour.log`. This is expected on some older
  Android phones that don't support `.local` (mDNS) names in the
  browser — use the QR/IP fallback on the sign (`docs/sign.md`)
  instead; the chat and join page both work the same over plain IP.

## 8. Uninstall

```bash
sudo ./uninstall.sh
```

Stops and removes the 4 launchd services. Chat history stays in
`/opt/emergency-box/data` unless you agree to the prompt to delete
`/opt/emergency-box` entirely. Homebrew packages (caddy, chatto) are
left installed.

## 9. Design notes

Full design rationale and decisions:

- [`docs/superpowers/specs/2026-07-18-coexist-redesign-design.md`](docs/superpowers/specs/2026-07-18-coexist-redesign-design.md)
  — current: always-on, coexists with the normal wifi.
- [`docs/superpowers/specs/2026-07-18-emergency-box-design.md`](docs/superpowers/specs/2026-07-18-emergency-box-design.md)
  — superseded: the earlier network-takeover design.
