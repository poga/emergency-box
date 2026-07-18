# Chatto Emergency Channels & Info Bots — Design

Date: 2026-07-19
Status: approved

## Goal

A fresh emergency-box install should come up with a useful Chinese-language
channel structure instead of chatto's bare `#announcements`/`#general`, and
with bots that pull outside information (weather, news, official alerts) into
dedicated channels. Audience: a household plus neighbors; channel names and
bot posts are in Chinese. When the internet dies the bots simply stop posting
— the channels' message history is the last-known-information cache.

All information sources are keyless (no API signups): Open-Meteo for weather,
NCDR CAP feeds for official alerts, public RSS for news. No CWA key path.

## Channel structure

Three sidebar groups, eight channels. All channels are `universal` so every
member sees them on signup. Each room gets a short Chinese description
explaining its purpose.

| Group | Channels | Purpose |
|---|---|---|
| 大廳 | #公告, #閒聊 | announcements (moderator-only posting), daily chat |
| 緊急互助 | #求助, #物資, #民防 | help requests; supplies coordination; civil defense — air-raid, shelter, war-related info |
| 資訊 | #天氣, #新聞, #警報 | bot-posted weather, news digests, official alerts |

#民防 is a human channel; war-related automated content arrives via the
alerts bot (NCDR CAP carries civil-defense alerts) and the news feeds.

#公告 posting is restricted to moderators via room permissions. Fallback: if
chatto v0.4.13's API cannot express a room-level posting restriction, ship
with open posting and state that in the room description.

## Seeding (`services/seed.py`)

Stdlib-Python script, run near the end of `install.sh` after chatto is
healthy and the operator account exists. Idempotent — safe on every re-run:

1. Log in as `boxadmin` via `POST /auth/login` (credentials from
   `config/operator-credentials.txt`), keep the session cookie.
2. Via ConnectRPC (`/api/connect/chatto.api.v1.*`):
   - Rename the default group `Lobby` → `大廳`, and the default rooms
     `#announcements` → `#公告`, `#general` → `#閒聊` (rename, not
     delete — preserves default wiring).
   - Create groups `緊急互助` and `資訊` if missing
     (`AdminRoomLayoutService`).
   - Create the six remaining rooms if missing (`RoomService/CreateRoom`
     with `universal: true`, Chinese description, correct `group_id`).
   - Apply the #公告 moderator-only posting restriction (best effort, see
     fallback above).
3. Matching is by current 中文 name (and the two known default names), so
   re-running never duplicates rooms or groups.

## Bots (`services/botd.py`)

One always-on stdlib-Python daemon — the repo's `joind.py` pattern — run by a
fifth launchd service `org.emergencybox.botd` (KeepAlive, logs to
`log/botd.log`). Login/ConnectRPC client code shared with `seed.py` lives in
`services/chatto_api.py`; the installer copies it alongside the services.

Three bot users, created at install time via `chatto operator user create`
with random passwords, so each channel shows a distinct sender:

| Bot | Channel | Source | Cadence | Behavior |
|---|---|---|---|---|
| 天氣機器人 | #天氣 | Open-Meteo forecast (configured lat/lon) | 07:00 and 17:00 daily | One Chinese digest: today/tomorrow temps, rain probability, notable wind. e.g. 「☀️ 台北今明預報：今 26–33°C 降雨 30%…」 |
| 新聞機器人 | #新聞 | RSS (defaults: 中央社即時, 公視新聞; exact URLs verified during implementation) | hourly | New headlines as one digest message (title + link), max 10 items/cycle, dedup by item GUID |
| 警報機器人 | #警報 | NCDR CAP alert feeds | every 5 min | Each new alert posts immediately as its own message 「🚨【地震】…」, dedup by alert ID. Optional `alert_regions` keyword filter, default empty = post all |

Mechanics:

- Auth: same flow the web UI uses — `POST /auth/login` with login/password,
  session cookie on subsequent calls.
- Room IDs resolved by name at startup via
  `RoomDirectoryService/ListRooms`; nothing hardcoded.
- Posting: `MessageService/CreateMessage` with `room_id` + `body`.
- Dedup/seen state persists in `data/botd-state.json`; restarts and reboots
  never repost old items.

Connectivity notice: when every source has been failing for 10+ minutes,
警報機器人 posts one 「⚠️ 對外網路已中斷，頻道內為最後已知資訊」; on recovery,
one 「✅ 對外網路已恢復」. The notice never repeats while the state holds
(tracked in the state file).

## Configuration (`config/bots.toml.template`)

Rendered once by `install.sh` to `/opt/emergency-box/config/bots.toml`
(chmod 600, owned by the box user, never overwritten on re-install — same
contract as `chatto.toml`). Contents:

- location: lat/lon + display name, default Taipei (25.04, 121.51, 「台北」)
- news feed URLs
- `alert_regions` keyword list (default empty)
- cadences (weather post times, news/alert poll intervals)
- the three bot logins and their generated passwords

Changing the city = edit the file, `launchctl kickstart` botd.

## Install / uninstall / status changes

`install.sh`:

- render `bots.toml` (if missing) with generated bot passwords
- create the three bot users via `chatto operator user create` (if missing)
- run `services/seed.py`
- install + bootstrap `org.emergencybox.botd.plist` (template, same
  bootout/bootstrap loop as the other four services)

`bin/status` reports botd like the other services. `uninstall.sh` removes
the new plist. README gains a short section: the 中文 channel lineup, what
the bots do, and how to change the city.

## Error handling

- Every HTTP call has a 10s timeout.
- Per-bot cycles are isolated try/except — one failing source never stalls
  the others; failures retry next cycle. launchd KeepAlive is the backstop,
  not the retry strategy.
- If chatto is unreachable or the session expires, botd waits and logs in
  again.
- Flood cap: at most 10 messages per bot per cycle, so a misbehaving feed
  can't bury a channel.

## Testing

Real behavior, no mocks — extends the existing bats suite that boots a real
chatto (`--no-system` install, `helpers.bash` pattern). External feeds are
replaced by a local fixtures HTTP server serving real captured Open-Meteo
JSON / RSS / CAP payloads; the test `bots.toml` points at it. Assertions are
observable outcomes through chatto's API, driven poll-until-deadline:

- seed run twice → exactly the 8 中文 rooms in 3 groups, no duplicates
- botd against fixtures → messages actually appear in #天氣 / #新聞 / #警報
- botd restarted → no reposted items
- fixtures server killed → offline notice appears exactly once
- shellcheck stays green across all shell entry points

## Out of scope

- CWA API key support (decided against — keyless only)
- Region filtering beyond simple keyword matching
- Live voice/video (existing README limitation stands)
- Bot interactivity (commands, replies) — bots only publish
