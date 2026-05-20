#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/deploy_derper_ip_selfsigned.sh"

fail() {
  echo "not ok - $1" >&2
  exit 1
}

ok() {
  echo "ok - $1"
}

test_no_crlf_and_syntax() {
  if LC_ALL=C grep -q $'\r' "$SCRIPT"; then
    fail "deploy script must use LF line endings"
  fi
  bash -n "$SCRIPT"
  ok "deploy script uses LF line endings and parses"
}

test_source_does_not_run_main() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  declare -F validate_settings >/dev/null || fail "functions should be available after source"
  ok "script can be sourced for tests without executing main"
}

test_unit_matching_detects_config_drift() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  IP_ADDR="203.0.113.10"
  DERP_PORT="30399"
  STUN_PORT="3478"
  INSTALL_DIR="/opt/derper"
  RUN_USER="derper"
  VERIFY_CLIENTS_MODE="on"
  SECURITY_LEVEL="standard"

  local unit
  unit=$'[Service]\nUser=derper\n# 安全加固（级别：standard）\nExecStart=/usr/local/bin/derper -hostname 203.0.113.10 -certmode manual -certdir /opt/derper/certs -http-port -1 -a :30399 -stun -stun-port 3478 -verify-clients\n'
  unit_matches_desired_config "$unit" || fail "matching unit should be accepted"

  DERP_PORT="443"
  if unit_matches_desired_config "$unit"; then
    fail "changed DERP port should be detected as drift"
  fi

  DERP_PORT="30399"
  VERIFY_CLIENTS_MODE="off"
  if unit_matches_desired_config "$unit"; then
    fail "changed verify-clients mode should be detected as drift"
  fi

  ok "unit config drift is detected"
}

test_validate_settings_rejects_invalid_user() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  IP_ADDR="203.0.113.10"
  RUN_USER='bad;user'
  if validate_settings >/dev/null 2>&1; then
    fail "invalid --user value should be rejected"
  fi
  ok "invalid run user is rejected"
}

test_port_conflict_ignores_current_derper_service() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  DERP_PORT="30399"
  STUN_PORT="3478"
  DERPER_RUNNING=1
  CURRENT_DERPER_OWNS_PORTS=1
  check_port_conflicts_from_listening $'tcp LISTEN 0 4096 *:30399 *:*\nudp UNCONN 0 0 *:3478 *:*'
  ok "current derper service ports are not treated as conflicts"
}

test_no_crlf_and_syntax
test_source_does_not_run_main
test_unit_matching_detects_config_drift
test_validate_settings_rejects_invalid_user
test_port_conflict_ignores_current_derper_service
