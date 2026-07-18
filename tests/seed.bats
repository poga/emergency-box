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
