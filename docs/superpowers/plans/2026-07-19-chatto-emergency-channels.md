# Chatto Emergency Channels & Info Bots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fresh emergency-box installs get a seeded Chinese channel structure (3 groups / 8 rooms) plus a `botd` daemon whose three bot accounts pull weather, news, and official alerts into dedicated channels.

**Architecture:** A shared stdlib-Python ConnectRPC client (`services/chatto_api.py`) is used by an idempotent seeding script (`services/seed.py`, run from `install.sh`) and an always-on daemon (`services/botd.py`, fifth launchd service). Bots are ordinary chatto users posting via `MessageService/CreateMessage`. Tests boot a real chatto on port 18082 and serve captured feed payloads from a local `python3 -m http.server` — no mocks.

**Tech Stack:** bash, Python 3.9 stdlib only (`urllib`, `json`, `configparser`, `xml.etree`), bats + shellcheck, chatto 0.4.13 ConnectRPC JSON API.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-19-chatto-emergency-channels-design.md`. Read it before starting any task.
- Apple system python is 3.9.6: no `tomllib`, no `dataclasses` extras beyond 3.9, `datetime.fromisoformat` cannot parse `Z` suffix. Use `configparser` with `interpolation=None` (feed URLs contain `%`).
- **Room names must be ASCII** (chatto rejects non-ASCII); group names and descriptions carry the Chinese.
- All chatto API calls: `POST /api/connect/<service>/<Method>`, JSON body, `Authorization: Bearer <token>` from `POST /auth/login {"login","password"}` → `{"token":"..."}`.
- Never write server-scoped permission decisions — room scope only: `{"scope":{"kind":"PERMISSION_SCOPE_KIND_ROOM","id":"<roomId>"}}`.
- Comments: max 1 line / 80 chars each. Tests assert observable outcomes (messages readable via `GetRoomEvents`), never internal bookkeeping.
- Test chatto lives at `http://127.0.0.1:18082` (`start_chatto_stack`); fixtures server at `http://127.0.0.1:18090`.
- Run `./test.sh` (shellcheck + all bats) before every commit; it must stay green.
- Commit messages end with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_018vHkVciXbw2K4GMQafQtdF`

---

### Task 1: Shared chatto client + seeding script

**Files:**
- Create: `services/chatto_api.py`
- Create: `services/seed.py`
- Modify: `tests/helpers.bash` (append helpers)
- Test: `tests/seed.bats`

**Interfaces:**
- Consumes: `tests/helpers.bash` (`start_chatto_stack DIR`, `stop_chatto_stack DIR`, `wait_for_url`), `lib/common.sh`.
- Produces (later tasks rely on these exact names):
  - `chatto_api.Chatto(base_url)` with `.login(login, password)` (sets `.token`, returns response dict), `.rpc(service, method, payload=None)` → dict, raising `chatto_api.ChattoError` (has `.code`) on API errors.
  - `services/seed.py --url URL --credentials FILE` (file format: `login: X` / `password: Y` lines), idempotent, exit 0 on success.
  - helpers.bash: `create_operator DIR`, `chatto_token LOGIN PASSWORD`, `chatto_rpc TOKEN SERVICE METHOD JSON`, `room_id_by_name TOKEN NAME`, `count_body_matches TOKEN ROOM_ID PATTERN`, `wait_for_room_message TOKEN ROOM_ID PATTERN DEADLINE_SECS`.
  - Room/group names: groups `大廳`, `緊急互助`, `資訊`; rooms `announcements`, `chat`, `help`, `supplies`, `civil-defense`, `weather`, `news`, `alerts`.

- [ ] **Step 1: Append test helpers to `tests/helpers.bash`**

Append to the end of `tests/helpers.bash`:

```bash
create_operator() { # DIR ; operator user + credentials file for the test stack
  printf 'testoppass123' | chatto operator -c "$1/chatto.toml" user create \
    --login boxadmin --password-stdin --verified-email operator@chat.lan \
    >/dev/null
  printf 'login: boxadmin\npassword: testoppass123\n' \
    >"$1/operator-credentials.txt"
}

chatto_token() { # LOGIN PASSWORD ; prints a bearer token for the test chatto
  curl -sf -X POST http://127.0.0.1:18082/auth/login \
    -H 'Content-Type: application/json' \
    -d "{\"login\":\"$1\",\"password\":\"$2\"}" | jq -r .token
}

chatto_rpc() { # TOKEN SERVICE METHOD JSON
  curl -s -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -X POST "http://127.0.0.1:18082/api/connect/$2/$3" -d "$4"
}

room_id_by_name() { # TOKEN NAME
  chatto_rpc "$1" chatto.api.v1.RoomDirectoryService ListRooms '{}' |
    jq -r --arg n "$2" '.rooms[].room | select(.name==$n) | .id'
}

count_body_matches() { # TOKEN ROOM_ID PATTERN ; messages whose body contains it
  chatto_rpc "$1" chatto.api.v1.RoomService GetRoomEvents \
    "{\"roomId\":\"$2\"}" |
    jq --arg p "$3" \
      '[.page.events[].messagePosted.message.body // empty
        | select(contains($p))] | length'
}

wait_for_room_message() { # TOKEN ROOM_ID PATTERN DEADLINE_SECS
  local deadline=$((SECONDS + $4))
  while ((SECONDS < deadline)); do
    [ "$(count_body_matches "$1" "$2" "$3")" -ge 1 ] && return 0
    sleep 0.5
  done
  echo "timeout waiting for message matching: $3" >&2
  return 1
}
```

- [ ] **Step 2: Write the failing test `tests/seed.bats`**

```bash
#!/usr/bin/env bats
load helpers

setup_file() {
  export STACK OPTOK
  STACK="$BATS_FILE_TMPDIR/stack"
  start_chatto_stack "$STACK"
  create_operator "$STACK"
  run python3 "$BATS_TEST_DIRNAME/../services/seed.py" \
    --url http://127.0.0.1:18082 \
    --credentials "$STACK/operator-credentials.txt"
  [ "$status" -eq 0 ]
  OPTOK=$(chatto_token boxadmin testoppass123)
}

teardown_file() { stop_chatto_stack "$STACK"; }

@test "seed creates 3 Chinese groups and 8 rooms" {
  layout=$(chatto_rpc "$OPTOK" chatto.admin.v1.AdminRoomLayoutService \
    ListRoomGroups '{}')
  for g in 大廳 緊急互助 資訊; do
    echo "$layout" | jq -e --arg g "$g" '.groups[] | select(.name==$g)'
  done
  [ "$(echo "$layout" | jq '[.groups[].items[]?.room // empty] | length')" \
    -eq 8 ]
  echo "$layout" | jq -e \
    '.groups[].items[]?.room // empty
     | select(.name=="chat") | .universal == true'
  echo "$layout" | jq -e \
    '.groups[].items[]?.room // empty
     | select(.name=="civil-defense")
     | .description | contains("民防")'
}

@test "seed is idempotent" {
  run python3 "$BATS_TEST_DIRNAME/../services/seed.py" \
    --url http://127.0.0.1:18082 \
    --credentials "$STACK/operator-credentials.txt"
  [ "$status" -eq 0 ]
  layout=$(chatto_rpc "$OPTOK" chatto.admin.v1.AdminRoomLayoutService \
    ListRoomGroups '{}')
  [ "$(echo "$layout" | jq '.groups | length')" -eq 3 ]
  [ "$(echo "$layout" | jq '[.groups[].items[]?.room // empty] | length')" \
    -eq 8 ]
}

@test "announcements is moderator-only but help is open" {
  printf 'plainpass123' | chatto operator -c "$STACK/chatto.toml" \
    user create --login plainuser --password-stdin >/dev/null
  tok=$(chatto_token plainuser plainpass123)
  ann=$(room_id_by_name "$OPTOK" announcements)
  helproom=$(room_id_by_name "$OPTOK" help)
  chatto_rpc "$tok" chatto.api.v1.RoomService JoinRoom \
    "{\"roomId\":\"$ann\"}" >/dev/null
  chatto_rpc "$tok" chatto.api.v1.RoomService JoinRoom \
    "{\"roomId\":\"$helproom\"}" >/dev/null
  denied=$(chatto_rpc "$tok" chatto.api.v1.MessageService CreateMessage \
    "{\"roomId\":\"$ann\",\"body\":\"hi\"}")
  echo "$denied" | jq -e '.code == "permission_denied"'
  ok=$(chatto_rpc "$tok" chatto.api.v1.MessageService CreateMessage \
    "{\"roomId\":\"$helproom\",\"body\":\"需要幫忙\"}")
  echo "$ok" | jq -e '.message.id'
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bats tests/seed.bats`
Expected: setup_file FAILS (`services/seed.py` does not exist).

- [ ] **Step 4: Create `services/chatto_api.py`**

```python
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
```

- [ ] **Step 5: Create `services/seed.py`**

```python
#!/usr/bin/env python3
"""Seeds the emergency channel structure in chatto. Idempotent."""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import chatto_api

ADMIN_LAYOUT = "chatto.admin.v1.AdminRoomLayoutService"
ADMIN_PERM = "chatto.admin.v1.AdminPermissionService"
ROOM_SVC = "chatto.api.v1.RoomService"

GROUP_RENAMES = {"Lobby": "大廳"}
ROOM_RENAMES = {"general": "chat"}
GROUPS = ["大廳", "緊急互助", "資訊"]
ROOMS = [
    ("大廳", "announcements", "公告｜版主發布重要資訊"),
    ("大廳", "chat", "閒聊｜日常聊天"),
    ("緊急互助", "help", "求助｜需要幫忙就在這裡說"),
    ("緊急互助", "supplies", "物資｜水、食物、電源、藥品互通有無"),
    ("緊急互助", "civil-defense", "民防｜防空、避難所、戰時資訊"),
    ("資訊", "weather", "天氣｜天氣機器人自動發布"),
    ("資訊", "news", "新聞｜新聞機器人自動發布"),
    ("資訊", "alerts", "警報｜地震、颱風等官方警報自動發布"),
]


def read_credentials(path):
    creds = {}
    with open(path) as f:
        for line in f:
            if ":" in line:
                k, v = line.split(":", 1)
                creds[k.strip()] = v.strip()
    return creds["login"], creds["password"]


def layout(c):
    groups = c.rpc(ADMIN_LAYOUT, "ListRoomGroups").get("groups", [])
    by_name = {g["name"]: g for g in groups}
    rooms = {}
    for g in groups:
        for item in g.get("items", []):
            room = item.get("room")
            if room:
                rooms[room["name"]] = room
    return by_name, rooms


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--credentials", required=True)
    args = ap.parse_args()
    login, password = read_credentials(args.credentials)
    c = chatto_api.Chatto(args.url)
    c.login(login, password)

    groups, rooms = layout(c)
    for old, new in GROUP_RENAMES.items():
        if old in groups and new not in groups:
            c.rpc(ADMIN_LAYOUT, "UpdateRoomGroup",
                  {"groupId": groups[old]["id"], "name": new})
    for old, new in ROOM_RENAMES.items():
        if old in rooms and new not in rooms:
            c.rpc(ROOM_SVC, "UpdateRoom",
                  {"roomId": rooms[old]["id"], "name": new})

    groups, rooms = layout(c)
    for name in GROUPS:
        if name not in groups:
            c.rpc(ADMIN_LAYOUT, "CreateRoomGroup", {"name": name})

    groups, rooms = layout(c)
    for group, name, desc in ROOMS:
        if name not in rooms:
            c.rpc(ROOM_SVC, "CreateRoom",
                  {"name": name, "groupId": groups[group]["id"],
                   "description": desc, "universal": True})
        elif (rooms[name].get("description") != desc
              or not rooms[name].get("universal")):
            c.rpc(ROOM_SVC, "UpdateRoom",
                  {"roomId": rooms[name]["id"], "description": desc,
                   "universal": True})

    groups, rooms = layout(c)
    scope = {"kind": "PERMISSION_SCOPE_KIND_ROOM",
             "id": rooms["announcements"]["id"]}
    c.rpc(ADMIN_PERM, "SetRolePermission",
          {"roleName": "everyone", "permission": "message.post",
           "scope": scope, "decision": "PERMISSION_DECISION_DENY"})
    c.rpc(ADMIN_PERM, "SetRolePermission",
          {"roleName": "moderator", "permission": "message.post",
           "scope": scope, "decision": "PERMISSION_DECISION_ALLOW"})
    print("seeded: %d groups, %d rooms" % (len(GROUPS), len(ROOMS)))


if __name__ == "__main__":
    main()
```

Then: `chmod +x services/seed.py`

- [ ] **Step 6: Run the test to verify it passes**

Run: `bats tests/seed.bats`
Expected: 3 tests PASS.

- [ ] **Step 7: Run the whole suite and commit**

Run: `./test.sh`
Expected: all existing tests + 3 new PASS, shellcheck green.

```bash
git add services/chatto_api.py services/seed.py tests/helpers.bash tests/seed.bats
git commit -m "Add chatto API client and idempotent channel seeding"
```

---

### Task 2: Fixtures, bots config template, botd core + weather bot

**Files:**
- Create: `tests/fixtures/openmeteo.json`
- Create: `tests/fixtures/pts.xml`
- Create: `tests/fixtures/gnews.xml`
- Create: `tests/fixtures/ncdr-1.xml.template`
- Create: `tests/fixtures/ncdr-2.xml.template`
- Create: `config/bots.ini.template`
- Create: `services/botd.py`
- Test: `tests/botd.bats`

**Interfaces:**
- Consumes: `chatto_api.Chatto` / `ChattoError` (Task 1), helpers from Task 1, `render_template` from `lib/common.sh`.
- Produces: `services/botd.py --config FILE [--once]`; `--once` runs one cycle of every bot then exits (interval checks bypassed, dedup still applies). Internal names later tasks extend: `fetch(url, state)`, `load_state`/`save_state`, `Poster` (`.ready()`, `.post(body)`), `run_cycle(cfg, state, posters, force)` with a `CYCLES` tuple listing `(section, function)` pairs — Tasks 3–5 append to `CYCLES` and add `news_cycle` / `alerts_cycle` / `connectivity_cycle`. State keys: `last_success` (epoch float), `offline` (bool), `weather.last_slot` (str).

- [ ] **Step 1: Create feed fixtures**

`tests/fixtures/openmeteo.json` (captured from the real API):

```json
{"latitude":25.0,"longitude":121.5,"timezone":"Asia/Taipei","daily":{"time":["2026-07-19","2026-07-20"],"temperature_2m_max":[32.7,32.9],"temperature_2m_min":[25.5,24.9],"precipitation_probability_max":[100,100],"wind_speed_10m_max":[10.8,10.6]}}
```

`tests/fixtures/pts.xml` (trimmed real PTS Atom shape):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xml:lang="zh-TW">
  <id>https://news.pts.org.tw/xml/newsfeed.xml</id>
  <title>公視新聞網</title>
  <entry>
    <id>https://news.pts.org.tw/article/818266</id>
    <title>無人機玩家不滿新增禁航區</title>
    <link href="https://news.pts.org.tw/article/818266"/>
    <updated>2026-07-19T10:00:00+08:00</updated>
  </entry>
  <entry>
    <id>https://news.pts.org.tw/article/818261</id>
    <title>堰塞湖預估溢流時間提前</title>
    <link href="https://news.pts.org.tw/article/818261"/>
    <updated>2026-07-19T09:00:00+08:00</updated>
  </entry>
</feed>
```

`tests/fixtures/gnews.xml` (trimmed real Google News RSS 2.0 shape):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>焦點新聞 - Google 新聞</title>
    <item>
      <title>測試頭條一</title>
      <link>https://example.com/n1</link>
      <guid isPermaLink="false">gnews-item-1</guid>
      <pubDate>Sat, 19 Jul 2026 02:00:00 GMT</pubDate>
    </item>
    <item>
      <title>測試頭條二</title>
      <link>https://example.com/n2</link>
      <guid isPermaLink="false">gnews-item-2</guid>
      <pubDate>Sat, 19 Jul 2026 01:00:00 GMT</pubDate>
    </item>
  </channel>
</rss>
```

`tests/fixtures/ncdr-1.xml.template` (real NCDR Atom+CAP shape; `@TS@` is
rendered to a current timestamp so the 24h bootstrap window works):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"
      xmlns:cap="urn:oasis:names:tc:emergency:cap:1.1">
  <id>https://alerts.ncdr.nat.gov.tw/RssAtomFeed.ashx</id>
  <title>NCDR示警公開資料平台</title>
  <entry>
    <id>CWA_Earthquake_TEST_0001</id>
    <title>地震</title>
    <updated>@TS@</updated>
    <link href="https://example.com/cap/eq1"/>
    <summary>臺北市 有感地震，規模5.1，深度10公里</summary>
    <cap:status>Actual</cap:status>
  </entry>
  <entry>
    <id>WRA_ReservoirWarn_TEST_0002</id>
    <title>水庫放流</title>
    <updated>@TS@</updated>
    <link href="https://example.com/cap/wra2"/>
    <summary>鯉魚潭水庫洩洪，影響範圍:苗栗縣</summary>
    <cap:status>Actual</cap:status>
  </entry>
  <entry>
    <id>CWA_Typhoon_OLD_0003</id>
    <title>颱風</title>
    <updated>2020-01-01T00:00:00+08:00</updated>
    <link href="https://example.com/cap/old3"/>
    <summary>過期的歷史警報</summary>
    <cap:status>Actual</cap:status>
  </entry>
  <entry>
    <id>CWA_Exercise_TEST_0004</id>
    <title>演習</title>
    <updated>@TS@</updated>
    <link href="https://example.com/cap/ex4"/>
    <summary>非實際警報</summary>
    <cap:status>Exercise</cap:status>
  </entry>
</feed>
```

`tests/fixtures/ncdr-2.xml.template`: identical to `ncdr-1.xml.template`
plus one extra entry before `</feed>`:

```xml
  <entry>
    <id>CWA_Typhoon_NEW_0005</id>
    <title>颱風</title>
    <updated>@TS@</updated>
    <link href="https://example.com/cap/ty5"/>
    <summary>颱風海上警報，影響範圍:臺灣北部海面</summary>
    <cap:status>Actual</cap:status>
  </entry>
```

- [ ] **Step 2: Create `config/bots.ini.template`**

```ini
[botd]
chatto_url = http://127.0.0.1:8080
state_file = @STATE_FILE@
tick = 30
offline_after = 600

[location]
name = 台北
latitude = 25.04
longitude = 121.51

[weather]
login = weatherbot
password = @WEATHER_PASSWORD@
room = weather
post_times = 07:00,17:00
url = https://api.open-meteo.com/v1/forecast?latitude={latitude}&longitude={longitude}&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max&timezone=Asia%2FTaipei&forecast_days=2

[news]
login = newsbot
password = @NEWS_PASSWORD@
room = news
interval = 3600
max_items = 10
feeds = https://news.pts.org.tw/xml/newsfeed.xml
    https://news.google.com/rss?hl=zh-TW&gl=TW&ceid=TW:zh-Hant

[alerts]
login = alertbot
password = @ALERT_PASSWORD@
room = alerts
interval = 300
regions =
feed = https://alerts.ncdr.nat.gov.tw/RssAtomFeed.ashx
```

- [ ] **Step 3: Write the failing weather test**

Create `tests/botd.bats`:

```bash
#!/usr/bin/env bats
load helpers

setup_file() {
  export STACK FIXDIR CONF STATE OPTOK
  STACK="$BATS_FILE_TMPDIR/stack"
  start_chatto_stack "$STACK"
  create_operator "$STACK"
  run python3 "$BATS_TEST_DIRNAME/../services/seed.py" \
    --url http://127.0.0.1:18082 \
    --credentials "$STACK/operator-credentials.txt"
  [ "$status" -eq 0 ]
  for b in weatherbot newsbot alertbot; do
    printf 'botpass123' | chatto operator -c "$STACK/chatto.toml" \
      user create --login "$b" --password-stdin >/dev/null
  done
  FIXDIR="$BATS_FILE_TMPDIR/fixtures"
  mkdir -p "$FIXDIR"
  cp "$BATS_TEST_DIRNAME/fixtures/openmeteo.json" \
    "$BATS_TEST_DIRNAME/fixtures/pts.xml" \
    "$BATS_TEST_DIRNAME/fixtures/gnews.xml" "$FIXDIR/"
  # shellcheck source=lib/common.sh
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  ts=$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')
  render_template "$BATS_TEST_DIRNAME/fixtures/ncdr-1.xml.template" \
    "$FIXDIR/ncdr.xml" "TS=$ts"
  require_port_free 18090
  python3 -m http.server 18090 --directory "$FIXDIR" >/dev/null 2>&1 &
  echo $! >"$STACK/httpfix.pid"
  wait_for_url http://127.0.0.1:18090/openmeteo.json 10
  STATE="$BATS_FILE_TMPDIR/botd-state.json"
  CONF="$BATS_FILE_TMPDIR/bots.ini"
  write_bots_ini "$CONF" "$STATE"
  OPTOK=$(chatto_token boxadmin testoppass123)
}

write_bots_ini() { # CONF_PATH STATE_PATH
  cat >"$1" <<EOF
[botd]
chatto_url = http://127.0.0.1:18082
state_file = $2
offline_after = 1

[location]
name = 台北
latitude = 25.04
longitude = 121.51

[weather]
login = weatherbot
password = botpass123
room = weather
post_times = 00:00
url = http://127.0.0.1:18090/openmeteo.json

[news]
login = newsbot
password = botpass123
room = news
interval = 3600
max_items = 10
feeds = http://127.0.0.1:18090/pts.xml
    http://127.0.0.1:18090/gnews.xml

[alerts]
login = alertbot
password = botpass123
room = alerts
interval = 300
regions =
feed = http://127.0.0.1:18090/ncdr.xml
EOF
}

teardown_file() {
  [ -f "$STACK/httpfix.pid" ] &&
    kill "$(cat "$STACK/httpfix.pid")" 2>/dev/null || true
  stop_chatto_stack "$STACK"
}

@test "botd --once posts a Chinese weather digest to #weather" {
  run python3 "$BATS_TEST_DIRNAME/../services/botd.py" \
    --config "$CONF" --once
  [ "$status" -eq 0 ]
  wid=$(room_id_by_name "$OPTOK" weather)
  wait_for_room_message "$OPTOK" "$wid" "天氣預報" 15
  [ "$(count_body_matches "$OPTOK" "$wid" "26–33°C")" -ge 1 ]
  [ "$(count_body_matches "$OPTOK" "$wid" "降雨機率 100%")" -ge 1 ]
}
```

The digest for the fixture must read
`今天 26–33°C，降雨機率 100%，最大風速 11 km/h` (25.5→26, 32.7→33 via
`%.0f` rounding).

- [ ] **Step 4: Run the test to verify it fails**

Run: `bats tests/botd.bats`
Expected: FAIL (`services/botd.py` does not exist).

- [ ] **Step 5: Create `services/botd.py` (core + weather)**

```python
#!/usr/bin/env python3
"""Pulls weather, news, and official alerts into chatto channels."""
import argparse
import configparser
import json
import os
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import chatto_api

FLOOD_CAP = 10


def log(msg):
    print(msg, flush=True)


def fetch(url, state):
    req = urllib.request.Request(
        url, headers={"User-Agent": "emergency-box-botd"})
    with urllib.request.urlopen(req, timeout=10) as r:
        data = r.read()
    state["last_success"] = time.time()
    return data


def load_state(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"last_success": time.time(), "offline": False}


def save_state(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, path)


class Poster:
    """One bot account bound to one room."""

    def __init__(self, url, login, password, room):
        self.url, self.login = url, login
        self.password, self.room = password, room
        self.client = None
        self.room_id = None

    def reset(self):
        self.client = None
        self.room_id = None

    def ready(self):
        if self.room_id:
            return
        c = chatto_api.Chatto(self.url)
        c.login(self.login, self.password)
        rooms = c.rpc("chatto.api.v1.RoomDirectoryService",
                      "ListRooms").get("rooms", [])
        found = None
        for r in rooms:
            if r["room"]["name"] == self.room:
                found = r["room"]
        if found is None:
            raise chatto_api.ChattoError("not_found", "room " + self.room)
        try:
            c.rpc("chatto.api.v1.RoomService", "JoinRoom",
                  {"roomId": found["id"]})
        except chatto_api.ChattoError:
            pass
        self.client, self.room_id = c, found["id"]

    def post(self, body):
        self.ready()
        self.client.rpc("chatto.api.v1.MessageService", "CreateMessage",
                        {"roomId": self.room_id, "body": body})


def weather_due(cfg, state, now):
    times = [t.strip() for t in cfg.get("weather", "post_times").split(",")]
    due = None
    for t in times:
        if now.strftime("%H:%M") >= t:
            due = "%s %s" % (now.strftime("%Y-%m-%d"), t)
    if due and state.get("weather", {}).get("last_slot") != due:
        return due
    return None


def weather_cycle(cfg, state, poster, force):
    slot = weather_due(cfg, state, datetime.now())
    if not slot:
        return
    url = cfg.get("weather", "url").format(
        latitude=cfg.get("location", "latitude"),
        longitude=cfg.get("location", "longitude"))
    d = json.loads(fetch(url, state))["daily"]
    name = cfg.get("location", "name")
    body = ("☀️ %s天氣預報\n"
            "今天 %.0f–%.0f°C，降雨機率 %d%%，最大風速 %.0f km/h\n"
            "明天 %.0f–%.0f°C，降雨機率 %d%%") % (
        name,
        d["temperature_2m_min"][0], d["temperature_2m_max"][0],
        d["precipitation_probability_max"][0], d["wind_speed_10m_max"][0],
        d["temperature_2m_min"][1], d["temperature_2m_max"][1],
        d["precipitation_probability_max"][1])
    poster.post(body)
    state.setdefault("weather", {})["last_slot"] = slot


CYCLES = (("weather", weather_cycle),)


def run_cycle(cfg, state, posters, force=False):
    for section, fn in CYCLES:
        try:
            fn(cfg, state, posters[section], force)
        except Exception as e:  # one failing bot must not stall the others
            log("%s: %s" % (section, e))
            posters[section].reset()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--once", action="store_true")
    args = ap.parse_args()
    cfg = configparser.ConfigParser(interpolation=None)
    cfg.read(args.config)
    state_file = cfg.get("botd", "state_file")
    state = load_state(state_file)
    posters = {
        s: Poster(cfg.get("botd", "chatto_url"), cfg.get(s, "login"),
                  cfg.get(s, "password"), cfg.get(s, "room"))
        for s in ("weather", "news", "alerts")
    }
    while True:
        run_cycle(cfg, state, posters, force=args.once)
        save_state(state_file, state)
        if args.once:
            return
        time.sleep(cfg.getint("botd", "tick", fallback=30))


if __name__ == "__main__":
    main()
```

Then: `chmod +x services/botd.py`

Note: `weather_cycle` deliberately ignores `force` — its dedup is the
`(date, slot)` pair, so `--once` twice in a day posts exactly once. The
test's `post_times = 00:00` makes the first run always due.

- [ ] **Step 6: Run the test to verify it passes**

Run: `bats tests/botd.bats`
Expected: 1 test PASS.

- [ ] **Step 7: Run the whole suite and commit**

Run: `./test.sh`
Expected: green.

```bash
git add tests/fixtures config/bots.ini.template services/botd.py tests/botd.bats
git commit -m "Add botd daemon core with weather bot and feed fixtures"
```

---

### Task 3: News bot

**Files:**
- Modify: `services/botd.py`
- Test: `tests/botd.bats` (append)

**Interfaces:**
- Consumes: `fetch`, `Poster`, `CYCLES`, `run_cycle` from Task 2.
- Produces: `parse_feed(data)` → list of dicts with keys `id`, `title`, `link`, `summary`, `status`, `updated` (Task 4 reuses it); `news_cycle(cfg, state, poster, force)`; state key `news = {"seen": {feed_url: [ids]}, "last_run": epoch}`.

- [ ] **Step 1: Append the failing tests to `tests/botd.bats`**

```bash
@test "botd --once posts one news digest from both feed formats" {
  nid=$(room_id_by_name "$OPTOK" news)
  wait_for_room_message "$OPTOK" "$nid" "新聞更新" 15
  [ "$(count_body_matches "$OPTOK" "$nid" "無人機玩家不滿新增禁航區")" -eq 1 ]
  [ "$(count_body_matches "$OPTOK" "$nid" "測試頭條一")" -eq 1 ]
}

@test "a second botd run reposts nothing" {
  nid=$(room_id_by_name "$OPTOK" news)
  wid=$(room_id_by_name "$OPTOK" weather)
  before_n=$(count_body_matches "$OPTOK" "$nid" "新聞更新")
  before_w=$(count_body_matches "$OPTOK" "$wid" "天氣預報")
  run python3 "$BATS_TEST_DIRNAME/../services/botd.py" \
    --config "$CONF" --once
  [ "$status" -eq 0 ]
  [ "$(count_body_matches "$OPTOK" "$nid" "新聞更新")" -eq "$before_n" ]
  [ "$(count_body_matches "$OPTOK" "$wid" "天氣預報")" -eq "$before_w" ]
}
```

The first test relies on the Task 2 `--once` run in the earlier test having
already posted news — after this task's implementation, that same run
handles all bots, so re-run the file: the first `--once` posts weather AND
news; assertions here only read.

- [ ] **Step 2: Run to verify the new tests fail**

Run: `bats tests/botd.bats`
Expected: the two new tests FAIL (no news messages exist).

- [ ] **Step 3: Implement `parse_feed` and `news_cycle` in `services/botd.py`**

Insert after `weather_cycle` (before `CYCLES`):

```python
def parse_feed(data):
    """Atom entries or RSS 2.0 items, namespace-agnostic."""
    def local(tag):
        return tag.rsplit("}", 1)[-1]

    items = []
    for el in ET.fromstring(data).iter():
        if local(el.tag) not in ("entry", "item"):
            continue
        it = {"id": "", "title": "", "link": "",
              "summary": "", "status": "", "updated": ""}
        for c in el:
            t = local(c.tag)
            text = (c.text or "").strip()
            if t in ("id", "guid"):
                it["id"] = text
            elif t == "title":
                it["title"] = text
            elif t == "link":
                it["link"] = text or c.get("href", "")
            elif t in ("summary", "description"):
                it["summary"] = text
            elif t == "status":
                it["status"] = text
            elif t in ("updated", "pubDate"):
                it["updated"] = text
        if not it["id"]:
            it["id"] = it["link"] or it["title"]
        items.append(it)
    return items


def news_cycle(cfg, state, poster, force):
    st = state.setdefault("news", {"seen": {}, "last_run": 0})
    if not force and time.time() - st["last_run"] < cfg.getint(
            "news", "interval"):
        return
    st["last_run"] = time.time()
    max_items = cfg.getint("news", "max_items")
    lines = []
    for feed in cfg.get("news", "feeds").split():
        try:
            items = parse_feed(fetch(feed, state))
        except Exception as e:  # a dead feed must not block the others
            log("news %s: %s" % (feed, e))
            continue
        seen = st["seen"].setdefault(feed, [])
        fresh = [i for i in items if i["id"] not in seen]
        for i in fresh:
            if len(lines) < max_items:
                lines.append("・%s\n  %s" % (i["title"], i["link"]))
        seen.extend(i["id"] for i in fresh)
        del seen[:-500]
    if lines:
        poster.post("📰 新聞更新\n" + "\n".join(lines))
```

Update the registry line to:

```python
CYCLES = (("weather", weather_cycle), ("news", news_cycle))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/botd.bats`
Expected: all PASS.

- [ ] **Step 5: Run the whole suite and commit**

Run: `./test.sh`
Expected: green.

```bash
git add services/botd.py tests/botd.bats
git commit -m "Add news bot: Atom/RSS digest with per-feed dedup"
```

---

### Task 4: Alerts bot with bootstrap and region filter

**Files:**
- Modify: `services/botd.py`
- Test: `tests/botd.bats` (append)

**Interfaces:**
- Consumes: `parse_feed`, `fetch`, `Poster`, `CYCLES` (Tasks 2–3); fixtures `ncdr-1.xml.template` / `ncdr-2.xml.template`; `write_bots_ini` from the test file.
- Produces: `alerts_cycle(cfg, state, poster, force)`; state key `alerts = {"seen": [ids], "bootstrapped": bool, "last_run": epoch}`.

- [ ] **Step 1: Append the failing tests to `tests/botd.bats`**

```bash
@test "alerts bootstrap posts only recent Actual alerts" {
  aid=$(room_id_by_name "$OPTOK" alerts)
  wait_for_room_message "$OPTOK" "$aid" "地震" 15
  [ "$(count_body_matches "$OPTOK" "$aid" "🚨")" -eq 2 ]
  [ "$(count_body_matches "$OPTOK" "$aid" "過期的歷史警報")" -eq 0 ]
  [ "$(count_body_matches "$OPTOK" "$aid" "非實際警報")" -eq 0 ]
}

@test "a new alert in the feed posts exactly once" {
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  ts=$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')
  render_template "$BATS_TEST_DIRNAME/fixtures/ncdr-2.xml.template" \
    "$FIXDIR/ncdr.xml" "TS=$ts"
  run python3 "$BATS_TEST_DIRNAME/../services/botd.py" \
    --config "$CONF" --once
  [ "$status" -eq 0 ]
  aid=$(room_id_by_name "$OPTOK" alerts)
  wait_for_room_message "$OPTOK" "$aid" "海上警報" 15
  [ "$(count_body_matches "$OPTOK" "$aid" "海上警報")" -eq 1 ]
  run python3 "$BATS_TEST_DIRNAME/../services/botd.py" \
    --config "$CONF" --once
  [ "$(count_body_matches "$OPTOK" "$aid" "海上警報")" -eq 1 ]
}

@test "region keywords filter alerts" {
  conf2="$BATS_FILE_TMPDIR/bots2.ini"
  state2="$BATS_FILE_TMPDIR/botd-state2.json"
  write_bots_ini "$conf2" "$state2"
  printf '\n' >>"$conf2"
  sed -i '' 's/^regions =$/regions = 金門/' "$conf2"
  aid=$(room_id_by_name "$OPTOK" alerts)
  before=$(count_body_matches "$OPTOK" "$aid" "🚨")
  run python3 "$BATS_TEST_DIRNAME/../services/botd.py" \
    --config "$conf2" --once
  [ "$status" -eq 0 ]
  [ "$(count_body_matches "$OPTOK" "$aid" "🚨")" -eq "$before" ]
}
```

(First test reads what the file's first `--once` run produced, as with
news. Bootstrap expectation: entries 1–2 are Actual+recent → posted; the
2020 entry is old, the Exercise entry is not Actual.)

- [ ] **Step 2: Run to verify the new tests fail**

Run: `bats tests/botd.bats`
Expected: the three new tests FAIL.

- [ ] **Step 3: Implement `alerts_cycle` in `services/botd.py`**

Insert after `news_cycle`:

```python
def _recent(ts):
    try:
        then = datetime.fromisoformat(ts)
        now = datetime.now(timezone.utc).astimezone()
        return now - then <= timedelta(hours=24)
    except (ValueError, TypeError):
        return False


def alerts_cycle(cfg, state, poster, force):
    st = state.setdefault(
        "alerts", {"seen": [], "bootstrapped": False, "last_run": 0})
    if not force and time.time() - st["last_run"] < cfg.getint(
            "alerts", "interval"):
        return
    st["last_run"] = time.time()
    regions = cfg.get("alerts", "regions").split()
    items = parse_feed(fetch(cfg.get("alerts", "feed"), state))
    actual = [i for i in items if i["status"].lower() == "actual"]
    wanted = [i for i in actual if not regions or
              any(r in i["title"] + i["summary"] for r in regions)]
    if st["bootstrapped"]:
        to_post = [i for i in wanted if i["id"] not in st["seen"]]
    else:
        to_post = [i for i in wanted if _recent(i["updated"])]
        st["bootstrapped"] = True
    st["seen"].extend(
        i["id"] for i in actual if i["id"] not in st["seen"])
    del st["seen"][:-2000]
    for i in list(reversed(to_post))[:FLOOD_CAP]:
        poster.post("🚨【%s】\n%s\n%s" % (i["title"], i["summary"], i["link"]))
```

Update the registry line to:

```python
CYCLES = (("weather", weather_cycle), ("news", news_cycle),
          ("alerts", alerts_cycle))
```

Note: `seen` gets every Actual id (even filtered/old ones) so nothing
re-qualifies later; the cap (2000) exceeds the real feed's ~1000 entries.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/botd.bats`
Expected: all PASS.

- [ ] **Step 5: Run the whole suite and commit**

Run: `./test.sh`
Expected: green.

```bash
git add services/botd.py tests/botd.bats
git commit -m "Add alerts bot: NCDR CAP feed with bootstrap and regions"
```

---

### Task 5: Connectivity notices

**Files:**
- Modify: `services/botd.py`
- Test: `tests/botd.bats` (append)

**Interfaces:**
- Consumes: everything above; `state["last_success"]`, `state["offline"]`; config `[botd] offline_after` (test value `1`).
- Produces: `connectivity_cycle(cfg, state, poster)` called from `run_cycle` after the bot loop, posting via the alerts poster.

- [ ] **Step 1: Append the failing tests to `tests/botd.bats`**

```bash
@test "offline notice posts exactly once while sources are dead" {
  kill "$(cat "$STACK/httpfix.pid")" 2>/dev/null || true
  sleep 2
  aid=$(room_id_by_name "$OPTOK" alerts)
  run python3 "$BATS_TEST_DIRNAME/../services/botd.py" \
    --config "$CONF" --once
  [ "$status" -eq 0 ]
  wait_for_room_message "$OPTOK" "$aid" "對外網路已中斷" 15
  run python3 "$BATS_TEST_DIRNAME/../services/botd.py" \
    --config "$CONF" --once
  [ "$(count_body_matches "$OPTOK" "$aid" "對外網路已中斷")" -eq 1 ]
}

@test "recovery notice posts when sources return" {
  python3 -m http.server 18090 --directory "$FIXDIR" >/dev/null 2>&1 &
  echo $! >"$STACK/httpfix.pid"
  wait_for_url http://127.0.0.1:18090/openmeteo.json 10
  run python3 "$BATS_TEST_DIRNAME/../services/botd.py" \
    --config "$CONF" --once
  [ "$status" -eq 0 ]
  aid=$(room_id_by_name "$OPTOK" alerts)
  wait_for_room_message "$OPTOK" "$aid" "對外網路已恢復" 15
  [ "$(count_body_matches "$OPTOK" "$aid" "對外網路已恢復")" -eq 1 ]
}
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `bats tests/botd.bats`
Expected: the two new tests FAIL (no such messages).

- [ ] **Step 3: Implement `connectivity_cycle` in `services/botd.py`**

Insert after `alerts_cycle`:

```python
def connectivity_cycle(cfg, state, poster):
    limit = cfg.getint("botd", "offline_after", fallback=600)
    down = time.time() - state.get("last_success", 0) > limit
    if down and not state.get("offline"):
        state["offline"] = True
        poster.post("⚠️ 對外網路已中斷，頻道內為最後已知資訊")
    elif not down and state.get("offline"):
        state["offline"] = False
        poster.post("✅ 對外網路已恢復")
```

Extend `run_cycle` — after the `for section, fn in CYCLES:` loop add:

```python
    try:
        connectivity_cycle(cfg, state, posters["alerts"])
    except Exception as e:  # chatto itself may be down; retry next tick
        log("connectivity: %s" % e)
        posters["alerts"].reset()
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/botd.bats`
Expected: all PASS.

- [ ] **Step 5: Run the whole suite and commit**

Run: `./test.sh`
Expected: green.

```bash
git add services/botd.py tests/botd.bats
git commit -m "Post one-time offline and recovery notices to alerts"
```

---

### Task 6: Install wiring, launchd service, status, uninstall, README

**Files:**
- Create: `config/org.emergencybox.botd.plist.template`
- Modify: `install.sh`
- Modify: `uninstall.sh:4` (service loop)
- Modify: `bin/status:13` (service loop)
- Modify: `README.md`
- Test: `tests/install.bats`

**Interfaces:**
- Consumes: `config/bots.ini.template` (Task 2), `services/chatto_api.py` / `seed.py` (Task 1), `services/botd.py` (Task 2), `render_template` from `lib/common.sh`.
- Produces: an installed system where `/opt/emergency-box/config/bots.ini` exists (chmod 600), bot users exist with Chinese display names, channels are seeded, and `org.emergencybox.botd` runs.

- [ ] **Step 1: Extend `tests/install.bats` (failing first)**

In the `"services and portal installed"` test, after the
`[ -x "$PREFIX/services/bonjour.sh" ]` line add:

```bash
  [ -x "$PREFIX/services/seed.py" ]
  [ -x "$PREFIX/services/botd.py" ]
  [ -f "$PREFIX/services/chatto_api.py" ]
```

After the `"chatto.toml is not world readable"` test add:

```bash
@test "renders bots.ini with distinct secrets, private" {
  grep -q 'name = 台北' "$PREFIX/config/bots.ini"
  n=$(grep -oE 'password = [0-9a-f]{32}' "$PREFIX/config/bots.ini" |
    sort -u | wc -l)
  [ "$n" -eq 3 ]
  perms=$(stat -f '%Lp' "$PREFIX/config/bots.ini")
  [ "$perms" = "600" ]
}
```

In the `"install is idempotent and keeps existing secrets"` test, extend
the before/after pattern:

```bash
  bots_before=$(grep 'password = ' "$PREFIX/config/bots.ini")
```
(before the re-run) and after the re-run:
```bash
  bots_after=$(grep 'password = ' "$PREFIX/config/bots.ini")
  [ "$bots_before" = "$bots_after" ]
```

Rename the plist test to `"all five launchd plists pass plutil -lint"`
(the glob already picks up the new template; five = chatto, joind, caddy,
bonjour, botd — plus the static caddy plist it already copies).

Run: `bats tests/install.bats`
Expected: new/changed tests FAIL (no bots.ini, no botd files).

- [ ] **Step 2: Create `config/org.emergencybox.botd.plist.template`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>org.emergencybox.botd</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>/opt/emergency-box/services/botd.py</string>
    <string>--config</string>
    <string>/opt/emergency-box/config/bots.ini</string>
  </array>
  <key>UserName</key><string>@EBOX_USER@</string>
  <key>WorkingDirectory</key><string>/opt/emergency-box</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/opt/emergency-box/log/botd.log</string>
  <key>StandardErrorPath</key><string>/opt/emergency-box/log/botd.log</string>
</dict>
</plist>
```

- [ ] **Step 3: Wire up `install.sh`**

(a) After the `chatto.toml` render block (`fi` at line ~50) add:

```bash
if [ ! -f "$PREFIX/config/bots.ini" ]; then
  render_template config/bots.ini.template "$PREFIX/config/bots.ini" \
    "WEATHER_PASSWORD=$(openssl rand -hex 16)" \
    "NEWS_PASSWORD=$(openssl rand -hex 16)" \
    "ALERT_PASSWORD=$(openssl rand -hex 16)" \
    "STATE_FILE=$PREFIX/data/botd-state.json"
  chmod 600 "$PREFIX/config/bots.ini"
fi
```

(b) Change the services copy/chmod lines to:

```bash
cp services/joind.py services/bonjour.sh services/chatto_api.py \
  services/seed.py services/botd.py "$PREFIX/services/"
chmod +x "$PREFIX/bin/status" "$PREFIX/services/joind.py" \
  "$PREFIX/services/bonjour.sh" "$PREFIX/services/seed.py" \
  "$PREFIX/services/botd.py"
```

(c) In the system branch, change the chown line to:

```bash
  chown "$EBOX_USER" "$PREFIX/config/chatto.toml" "$PREFIX/config/bots.ini"
```

(d) Change the launchd loop list from `for l in chatto joind caddy bonjour`
to `for l in chatto joind caddy bonjour botd`.

(e) After the entire operator-account block (after the
`op_status=...` lines is too late — put it directly after the operator
`fi`), add:

```bash
  echo "==> Creating bot accounts"
  bot_pw() {
    python3 - "$PREFIX/config/bots.ini" "$1" <<'PY'
import configparser, sys
c = configparser.ConfigParser(interpolation=None)
c.read(sys.argv[1])
print(c[sys.argv[2]]["password"])
PY
  }
  existing=$(chatto operator -c "$PREFIX/config/chatto.toml" user list \
    --json 2>/dev/null || echo '{}')
  for spec in "weather:weatherbot:天氣機器人" "news:newsbot:新聞機器人" \
    "alerts:alertbot:警報機器人"; do
    sec=${spec%%:*} rest=${spec#*:}
    login=${rest%%:*} display=${rest#*:}
    if ! printf '%s' "$existing" |
      jq -e --arg l "$login" '[.. | .login? // empty] | index($l)' \
        >/dev/null; then
      bot_pw "$sec" | chatto operator -c "$PREFIX/config/chatto.toml" \
        user create --login "$login" --password-stdin \
        --display-name "$display" ||
        echo "WARNING: could not create bot user $login" >&2
    fi
  done

  echo "==> Seeding channels"
  python3 "$PREFIX/services/seed.py" --url http://127.0.0.1:8080 \
    --credentials "$PREFIX/config/operator-credentials.txt" ||
    echo "WARNING: channel seeding failed; re-run sudo ./install.sh" >&2
```

- [ ] **Step 4: Extend `uninstall.sh` and `bin/status`**

`uninstall.sh` line 4: `for l in chatto joind caddy bonjour botd; do`
`bin/status` line 13: `for l in chatto joind caddy bonjour botd; do`

- [ ] **Step 5: Add the README section**

Insert before the "One-time router step" paragraph in `README.md`:

```markdown
## Channels & bots

Installs seed a Chinese channel lineup: 大廳 (#announcements —
moderator-only, #chat), 緊急互助 (#help, #supplies, #civil-defense), and
資訊 where bots post — #weather (Open-Meteo, 07:00/17:00), #news (公視 +
Google News hourly), #alerts (NCDR official alerts, every 5 min). All
sources are keyless. When the internet dies the bots go quiet and the
channel history is your last-known-info cache; #alerts gets a one-time
⚠️ offline notice.

Change the city: edit `[location]` in
`/opt/emergency-box/config/bots.ini`, then
`sudo launchctl kickstart -k system/org.emergencybox.botd`.
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bats tests/install.bats`
Expected: all PASS (no-system install renders bots.ini and copies
services; bot users/seeding only run in the system branch, which the test
does not exercise).

- [ ] **Step 7: Run the whole suite and commit**

Run: `./test.sh`
Expected: green (shellcheck covers the install.sh edits).

```bash
git add config/org.emergencybox.botd.plist.template install.sh uninstall.sh bin/status README.md tests/install.bats
git commit -m "Install botd service, bot accounts, and channel seeding"
```

---

### Task 7: Final verification

**Files:** none (verification only).

- [ ] **Step 1: Full suite twice (order-independence sanity)**

Run: `./test.sh && ./test.sh`
Expected: green both times (port teardown works; no leftover state).

- [ ] **Step 2: Verify spec coverage**

Re-read `docs/superpowers/specs/2026-07-19-chatto-emergency-channels-design.md`; confirm each spec section maps to shipped code/tests. Confirm no server-scoped `SetRolePermission` call exists anywhere: `grep -rn 'SetRolePermission' services/` must show room-scoped usage only (in `seed.py`).

- [ ] **Step 3: Commit anything outstanding**

```bash
git status --short
```
Expected: clean tree.
