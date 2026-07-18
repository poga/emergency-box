#!/usr/bin/env bats

@test "emergency scripts show usage with --help" {
  for s in emergency-on emergency-off emergency-status; do
    run "$BATS_TEST_DIRNAME/../bin/$s" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
  done
}

@test "emergency-on rejects unknown flags" {
  run "$BATS_TEST_DIRNAME/../bin/emergency-on" --bogus
  [ "$status" -eq 2 ]
}

@test "wifi detection finds a real device and service" {
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  dev=$(detect_wifi_device)
  [[ "$dev" =~ ^en[0-9]+$ ]]
  svc=$(detect_wifi_service)
  [ -n "$svc" ]
}
