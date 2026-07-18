#!/usr/bin/env bats

@test "status shows usage with --help" {
  run "$BATS_TEST_DIRNAME/../bin/status" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "status rejects unknown flags" {
  run "$BATS_TEST_DIRNAME/../bin/status" --bogus
  [ "$status" -eq 2 ]
}

@test "wifi detection finds a real device" {
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  dev=$(detect_wifi_device)
  [[ "$dev" =~ ^en[0-9]+$ ]]
}

@test "bonjour publisher script is valid and sources cleanly" {
  run bash -n "$BATS_TEST_DIRNAME/../services/bonjour.sh"
  [ "$status" -eq 0 ]
}

@test "bonjour publisher makes chat.local resolve (best effort)" {
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  ip=$(ipconfig getifaddr "$(detect_wifi_device)" 2>/dev/null || true)
  if [ -z "$ip" ]; then
    skip "no wifi IP on this machine; cannot exercise dns-sd"
  fi
  "$BATS_TEST_DIRNAME/../services/bonjour.sh" &
  pid=$!
  resolved=1
  deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    dscacheutil -q host -a name chat.local 2>/dev/null |
      grep -q ip_address && { resolved=0; break; }
    sleep 0.5
  done
  kill "$pid" 2>/dev/null || true
  [ "$resolved" -eq 0 ]
}
