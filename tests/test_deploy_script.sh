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
  unit=$'[Service]\nUser=derper\n# 安全加固（级别：standard）\nExecStart=/usr/local/bin/derper -c /opt/derper/derper.json -hostname 203.0.113.10 -certmode manual -certdir /opt/derper/certs -http-port -1 -a :30399 -stun -stun-port 3478 -verify-clients\n'
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

  VERIFY_CLIENTS_MODE="on"
  derper_supports_socket_flag() { return 0; }
  if unit_matches_desired_config "$unit"; then
    fail "missing -socket should be detected when derper supports the flag"
  fi
  local unit_with_socket="${unit/-verify-clients/-verify-clients -socket /run/tailscale/tailscaled.sock}"
  unit_matches_desired_config "$unit_with_socket" ||
    fail "matching unit with supported -socket flag should be accepted"

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

test_service_reconcile_detects_runtime_failures_and_cert_regen() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  DERPER_SERVICE_PRESENT=1
  DESIRED_CONFIG_OK=1
  DERPER_RUNNING=1
  PORT_TLS_OK=1
  PORT_STUN_OK=1

  service_needs_reconcile 0 && fail "healthy service should not be reconciled"

  DERPER_RUNNING=0
  service_needs_reconcile 0 || fail "stopped service should be reconciled"
  DERPER_RUNNING=1

  PORT_STUN_OK=0
  service_needs_reconcile 0 || fail "missing STUN listener should be reconciled"
  PORT_STUN_OK=1

  service_needs_reconcile 1 || fail "changed binary or certificate should trigger service restart"
  ok "runtime failures and changed artifacts trigger service reconciliation"
}

test_nonempty_config_uses_separate_c_argument() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    INSTALL_DIR="${local_tmp}/install"
    SERVICE_PATH="${local_tmp}/derper.service"
    BIN_PATH="/usr/local/bin/derper"
    RUN_USER="$(id -un)"
    VERIFY_CLIENTS_MODE="off"
    SECURITY_LEVEL="basic"
    mkdir -p "$INSTALL_DIR"
    printf '{"PrivateKeyPath":"state.key"}\n' >"${INSTALL_DIR}/derper.json"

    derper_supports_stun_port() { return 0; }
    derper_supports_listen_a() { return 0; }
    setup_service_user() { return 0; }
    systemctl() { return 0; }

    write_systemd_service >/dev/null
    grep -qF "ExecStart=${BIN_PATH} -c ${INSTALL_DIR}/derper.json -hostname" "$SERVICE_PATH" ||
      fail "non-empty config must emit -c and path as separate ExecStart arguments"
  )
  ok "non-empty derper config emits a valid -c argument"
}

test_unsupported_custom_stun_port_is_rejected() {
  if (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    INSTALL_DIR="$local_tmp"
    STUN_PORT="40000"
    derper_supports_stun_port() { return 1; }
    write_systemd_service >/dev/null 2>&1
  ); then
    fail "custom STUN port should be rejected when derper lacks -stun-port"
  fi
  ok "unsupported custom STUN port is rejected"
}

test_empty_derper_config_is_migrated_for_auto_key_generation() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    INSTALL_DIR="$local_tmp"
    printf '{}\n' >"${INSTALL_DIR}/derper.json"
    prepare_derper_config >/dev/null
    [[ ! -e "${INSTALL_DIR}/derper.json" ]] ||
      fail "empty config should be removed so derper can generate a node private key"

    printf '{"PrivateKey":"private:example"}\n' >"${INSTALL_DIR}/derper.json"
    prepare_derper_config >/dev/null
    [[ -f "${INSTALL_DIR}/derper.json" ]] || fail "non-empty derper config should be preserved"
  )
  ok "empty derper config is migrated without overwriting valid config"
}

test_verify_clients_passes_socket_flag() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    INSTALL_DIR="${local_tmp}/install"
    SERVICE_PATH="${local_tmp}/derper.service"
    BIN_PATH="/usr/local/bin/derper"
    RUN_USER="$(id -un)"
    VERIFY_CLIENTS_MODE="on"
    SECURITY_LEVEL="basic"

    derper_supports_stun_port() { return 0; }
    derper_supports_listen_a() { return 0; }
    derper_supports_socket_flag() { return 0; }
    setup_service_user() { return 0; }
    systemctl() { return 0; }

    write_systemd_service >/dev/null 2>&1
    grep -qF -- "-verify-clients -socket /run/tailscale/tailscaled.sock" "$SERVICE_PATH" ||
      fail "verify-clients service must pass the tailscaled socket through -socket"
    ! grep -qF "TS_LOCAL_API_SOCKET" "$SERVICE_PATH" ||
      fail "service must not rely on unsupported TS_LOCAL_API_SOCKET environment variable"
  )
  ok "verify-clients uses the supported derper socket flag"
}

test_insecure_acl_uses_requested_region_and_endpoint() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  REGION_ID="1234"
  REGION_CODE="custom-region"
  REGION_NAME="Custom Region"
  IP_ADDR="203.0.113.20"
  DERP_PORT="30443"
  local output
  output=$(print_acl_snippet_insecure)
  [[ "$output" == *'"RegionID": 1234'* ]] || fail "fallback ACL should use requested RegionID"
  [[ "$output" == *'"HostName": "203.0.113.20"'* ]] || fail "fallback ACL should use requested IP"
  [[ "$output" == *'"DERPPort": 30443'* ]] || fail "fallback ACL should use requested DERP port"
  ok "fallback ACL uses requested region and endpoint"
}

test_wizard_handles_eof_cleanly() {
  local output rc=0
  output=$(DERPER_TEST_MODE=1 bash -c 'source "$1"; deployment_wizard' _ "$SCRIPT" </dev/null 2>&1) || rc=$?
  [[ $rc -ne 0 ]] || fail "wizard should stop when stdin reaches EOF"
  [[ "$output" == *"输入已结束"* ]] || fail "wizard should explain EOF cancellation"
  [[ "$output" != *"unbound variable"* ]] || fail "wizard EOF must not trigger set -u"
  ok "wizard handles EOF without unbound-variable crash"
}

test_cert_san_matches_literal_ip_only() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    INSTALL_DIR="$local_tmp"
    IP_ADDR="203.0.113.10"
    mkdir -p "${INSTALL_DIR}/certs"
    : >"${INSTALL_DIR}/certs/fullchain.pem"
    : >"${INSTALL_DIR}/certs/privkey.pem"
    openssl() {
      if [[ " $* " == *" -checkend "* ]]; then return 0; fi
      printf '%s\n' "X509v3 Subject Alternative Name:" "    IP Address:203x0x113x10"
    }
    check_cert_status
    [[ $CERT_SAN_MATCH -eq 0 ]] || fail "IP dots must be matched literally in certificate SAN"

    openssl() {
      if [[ " $* " == *" -checkend "* ]]; then return 0; fi
      printf '%s\n' "X509v3 Subject Alternative Name:" "    IP Address:203.0.113.10"
    }
    check_cert_status
    [[ $CERT_SAN_MATCH -eq 1 ]] || fail "exact certificate SAN IP should match"
  )
  ok "certificate SAN matching treats IP dots literally"
}

test_live_certificate_mismatch_fails_health_check() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  DERPER_RUNNING=1 PORT_TLS_OK=1 PORT_STUN_OK=1 PURE_IP_OK=1 DESIRED_CONFIG_OK=1
  CERT_PRESENT=1 CERT_SAN_MATCH=1 CERT_EXPIRY_OK=1
  cert_file_sha256_raw() { echo "disk"; }
  live_cert_sha256_raw() { echo "live"; }
  check_live_cert_status
  health_is_ok && fail "health check should fail when live certificate differs from disk"

  live_cert_sha256_raw() { echo "disk"; }
  check_live_cert_status
  health_is_ok || fail "health check should pass when live certificate matches disk"
  ok "health check detects stale live certificate"
}

test_metrics_writer_avoids_predictable_tmp_path() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    local metrics="${local_tmp}/derper.prom"
    printf 'sentinel\n' >"${metrics}.tmp"
    DERPER_RUNNING=1 PORT_TLS_OK=1 PORT_STUN_OK=1
    DERPER_VERIFY_CLIENTS_EFFECTIVE=1 PURE_IP_OK=1 DESIRED_CONFIG_OK=1
    write_prometheus_metrics "$metrics" "100" "256"
    [[ "$(cat "${metrics}.tmp")" == "sentinel" ]] ||
      fail "metrics writer must not use predictable path.prom.tmp"
    grep -qF "derper_up 1" "$metrics" || fail "metrics output should be written"
  )
  ok "metrics writer uses a safe temporary file"
}

# 回归：$USER 在 sudo/CI/容器等最小环境下可能未导出，set -u 下直接引用会让
# 脚本在 source（甚至正式运行）阶段就崩溃。校验 USER 缺失时仍能正常加载。
test_source_survives_unset_user() {
  local saved_user="${USER-}"
  unset USER
  DERPER_TEST_MODE=1 source "$SCRIPT"
  [[ -n "${RUN_USER}" ]] || fail "RUN_USER should fall back to id -un when USER is unset"
  ok "script sources cleanly when USER is unset (falls back to id -un)"
  # 还原，避免污染后续测试
  [[ -n "$saved_user" ]] && export USER="$saved_user" || true
}

test_no_crlf_and_syntax
test_source_does_not_run_main
test_source_survives_unset_user
test_unit_matching_detects_config_drift
test_validate_settings_rejects_invalid_user
test_port_conflict_ignores_current_derper_service
test_service_reconcile_detects_runtime_failures_and_cert_regen
test_nonempty_config_uses_separate_c_argument
test_unsupported_custom_stun_port_is_rejected
test_empty_derper_config_is_migrated_for_auto_key_generation
test_verify_clients_passes_socket_flag
test_insecure_acl_uses_requested_region_and_endpoint
test_wizard_handles_eof_cleanly
test_cert_san_matches_literal_ip_only
test_live_certificate_mismatch_fails_health_check
test_metrics_writer_avoids_predictable_tmp_path
