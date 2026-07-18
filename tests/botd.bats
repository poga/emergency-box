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
