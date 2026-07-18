# Chatto Emergency Channels & Info Bots — Design

Date: 2026-07-19
Status: approved (updated after API verification against chatto 0.4.13)

## Goal

A fresh emergency-box install should come up with a useful channel structure
instead of chatto's bare defaults, and with bots that pull outside
information (weather, news, official alerts) into dedicated channels.
Audience: a household plus neighbors in Taiwan; group names, room
descriptions, and bot posts are in Chinese. When the internet dies the bots
simply stop posting — the channels' message history is the last-known-
information cache.

All information sources are keyless (no API signups): Open-Meteo for
weather, NCDR CAP feeds for official alerts, public RSS/Atom for news.
No CWA key path.

## Verified API facts (probed against a real chatto 0.4.13)

- `POST /auth/login` with `{"login","password"}` returns
  `{"token":"cht_..."}`; all API calls then use
  `Authorization: Bearer <token>`. No cookies needed.
- ConnectRPC endpoints live at
  `/api/connect/<service>/<Method>`, JSON in/out, always POST.
- **Room names must be ASCII** (alphanumeric/hyphen/underscore only).
  Group names and room descriptions accept Chinese.
- Rooms: `chatto.api.v1.RoomService/CreateRoom`
  (`name`, `groupId`, `description`, `universal`), `UpdateRoom`
  (`roomId`, `name`, `description`), `JoinRoom` (`roomId`).
  Posting requires membership even in universal rooms — bots must
  `JoinRoom` first (idempotent).
- Groups: `chatto.admin.v1.AdminRoomLayoutService/CreateRoomGroup`
  (`name`), `UpdateRoomGroup` (`groupId`, `name`), `ListRoomGroups`.
- Messages: `chatto.api.v1.MessageService/CreateMessage`
  (`roomId`, `body`); read back via `RoomService/GetRoomEvents`
  (`roomId` → `page.events[].messagePosted.message.body`).
- Permissions: `chatto.admin.v1.AdminPermissionService/SetRolePermission`
  with `roleName`, `permission`, `decision`
  (`PERMISSION_DECISION_ALLOW|DENY|NONE`), and room scope
  `{"scope":{"kind":"PERMISSION_SCOPE_KIND_ROOM","id":"<roomId>"}}`.
  Verified: room-scoped deny of `message.post` for `everyone` blocks plain
  users in that room only; owners still post. Never write server-scope
  decisions (a server-scope `NONE` wipes the everyone baseline).
- Roles: system roles `everyone`, `moderator`, `owner` exist. The operator
  account (email in `[owners]`) gets `owner` automatically.
  `chatto operator user create` supports `--display-name` and `--role`.

## Channel structure

Three sidebar groups (Chinese names), eight channels (ASCII names, Chinese
descriptions carry the meaning). All channels `universal` so every member
sees them; seed and bots join explicitly.

| Group | Room | Description |
|---|---|---|
| 大廳 | #announcements | 公告｜版主發布重要資訊 |
| 大廳 | #chat | 閒聊｜日常聊天 |
| 緊急互助 | #help | 求助｜需要幫忙就在這裡說 |
| 緊急互助 | #supplies | 物資｜水、食物、電源、藥品互通有無 |
| 緊急互助 | #civil-defense | 民防｜防空、避難所、戰時資訊 |
| 資訊 | #weather | 天氣｜天氣機器人自動發布 |
| 資訊 | #news | 新聞｜新聞機器人自動發布 |
| 資訊 | #alerts | 警報｜地震、颱風等官方警報自動發布 |

#civil-defense is a human channel; war-related automated content arrives
via the alerts bot (NCDR CAP carries civil-defense alerts) and news feeds.

#announcements posting is moderator-only: room-scoped
`message.post` DENY for `everyone` + room-scoped ALLOW for `moderator`.
Owners (boxadmin) bypass via the owner role.

## Seeding (`services/seed.py`)

Stdlib-Python script, run near the end of `install.sh` after chatto is
healthy and the operator account exists. Idempotent — safe on every re-run:

1. Log in via `/auth/login` (boxadmin credentials from
   `config/operator-credentials.txt`), use the bearer token.
2. Rename default group `Lobby` → `大廳`; rename default rooms
   `announcements` → keep name (update description), `general` → `chat`.
   Renames match by current name; already-renamed entities are found by
   their target names, so re-runs are no-ops.
3. Create groups `緊急互助` and `資訊` if missing; create missing rooms
   with `universal: true` and the descriptions above.
4. Apply the #announcements permission pair (deny everyone / allow
   moderator, both room-scoped). Setting an already-set decision is
   idempotent.

Shared login/RPC client code lives in `services/chatto_api.py`, used by
both `seed.py` and `botd.py`; the installer copies it alongside the
services.

## Bots (`services/botd.py`)

One always-on stdlib-Python daemon — the repo's `joind.py` pattern — run by
a fifth launchd service `org.emergencybox.botd` (KeepAlive, `UserName`
box user, logs to `log/botd.log`).

Three bot users, created at install time via `chatto operator user create`
(`--display-name` 中文名) with random passwords:

| Bot | Login | Display name | Channel |
|---|---|---|---|
| weather | weatherbot | 天氣機器人 | #weather |
| news | newsbot | 新聞機器人 | #news |
| alerts | alertbot | 警報機器人 | #alerts |

At startup botd logs each bot in, resolves room IDs by name via
`RoomDirectoryService/ListRooms`, and `JoinRoom`s its channel. Main loop
ticks every 30s and runs whichever bots are due.

**天氣機器人** — Open-Meteo forecast
(`api.open-meteo.com/v1/forecast?latitude=..&longitude=..&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max&timezone=Asia%2FTaipei&forecast_days=2`),
posts at 07:00 and 17:00 local: one Chinese digest with today/tomorrow
min–max temps, rain probability, notable wind. State records the last
posted (date, slot) so restarts don't repost.

**新聞機器人** — polls feeds hourly. Defaults (both verified live):
PTS Atom `https://news.pts.org.tw/xml/newsfeed.xml` and Google News 台灣
RSS `https://news.google.com/rss?hl=zh-TW&gl=TW&ceid=TW:zh-Hant`. Parser
handles both Atom (`entry`/`id`/`title`/`link@href`) and RSS 2.0
(`item`/`guid`/`title`/`link`). New items post as one digest message
(`標題 — 連結` lines, max 10 per cycle), dedup by id/guid (seen-set capped
at 500 per feed, newest kept).

**警報機器人** — polls the NCDR aggregate CAP Atom feed
`https://alerts.ncdr.nat.gov.tw/RssAtomFeed.ashx` every 5 minutes. The
feed carries ~1000 historical entries, so: only entries with
`cap:status == Actual` count; **bootstrap rule** — on first run (empty
state) mark everything seen but post only the ≤10 most recent entries
updated within the last 24h; afterwards each new entry posts immediately
as 「🚨【title】summary」 with the CAP link. Optional `alert_regions`
keyword list (matched against title+summary), default empty = post all.

**Connectivity notice** — when every source fetch has been failing for
10+ minutes, 警報機器人 posts one 「⚠️ 對外網路已中斷，頻道內為最後已知資訊」;
on the next successful fetch, one 「✅ 對外網路已恢復」. The offline/online
flag lives in the state file so restarts don't re-announce.

Dedup/seen state persists in `data/botd-state.json`.

## Configuration (`config/bots.ini.template`)

INI, not TOML: the box runs Apple's `/usr/bin/python3` 3.9, which has
`configparser` but not `tomllib`. Rendered once by `install.sh` to
`/opt/emergency-box/config/bots.ini` (chmod 600, owned by the box user,
never overwritten on re-install — same contract as `chatto.toml`).
Contents: chatto URL; location (lat/lon + display name, default Taipei
25.04/121.51/台北); weather post times; news feed URLs and interval;
alert feed URL, interval, and `alert_regions`; the three bot logins and
their generated passwords.

Changing the city = edit the file, then
`sudo launchctl kickstart -k system/org.emergencybox.botd`.

## Install / uninstall / status changes

`install.sh`:

- render `bots.ini` (if missing) with generated bot passwords
- create the three bot users via `chatto operator user create` (if
  missing), with Chinese display names
- copy `chatto_api.py`, `seed.py`, `botd.py`; run `seed.py`
- install + bootstrap `org.emergencybox.botd.plist` (template, same
  bootout/bootstrap loop as the other four services)

`bin/status` reports botd like the other services. `uninstall.sh` removes
the new plist. README gains a short section: the channel lineup, what the
bots do, and how to change the city.

## Error handling

- Every HTTP call has a 10s timeout.
- Per-bot cycles are isolated try/except — one failing source never stalls
  the others; failures retry next cycle. launchd KeepAlive is the
  backstop, not the retry strategy.
- If chatto is unreachable or the token expires, botd re-logs-in with
  backoff.
- Flood cap: at most 10 messages per bot per cycle.

## Testing

Real behavior, no mocks — extends the existing bats suite that boots a
real chatto on port 18082 (`helpers.bash` / `start_chatto_stack`).
External feeds are replaced by a local fixtures HTTP server
(`python3 -m http.server` over `tests/fixtures/`: captured real Open-Meteo
JSON, PTS Atom, Google News RSS, NCDR CAP Atom payloads); the test
`bots.ini` points at it. `botd.py --once` runs every due bot exactly one
cycle then exits, so tests drive real flows without waiting on wall-clock
schedules. Assertions are observable outcomes through chatto's API,
polled until a deadline:

- seed run twice → 3 groups / 8 rooms with the exact descriptions, no
  duplicates; plain user cannot post in #announcements but can in #help
- botd against fixtures → bot messages actually appear in #weather /
  #news / #alerts with Chinese content
- botd restarted with intact state → no reposted items
- fixtures server killed → offline notice appears exactly once; restored
  → recovery notice appears
- shellcheck stays green across all shell entry points

## Out of scope

- CWA API key support (keyless only)
- Region filtering beyond simple keyword matching
- Live voice/video (existing README limitation stands)
- Bot interactivity (commands, replies) — bots only publish
