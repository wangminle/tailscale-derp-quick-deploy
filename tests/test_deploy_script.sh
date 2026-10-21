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
  unit=$'[Service]\nUser=derper\n# 安全加固（级别：standard）\nExecStart=/usr/local/bin/derper -c /opt/derper/state/derper.json -hostname 203.0.113.10 -certmode manual -certdir /opt/derper/certs -http-port -1 -a :30399 -stun -stun-port 3478 -verify-clients\n'
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
  IP_ADDR="8.8.8.8"
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
    service_verified_running() { return 0; }
    systemctl() { return 0; }

    write_systemd_service >/dev/null
    grep -qF "ExecStart=${BIN_PATH} -c ${INSTALL_DIR}/state/derper.json -hostname" "$SERVICE_PATH" ||
      fail "non-empty config must emit -c and path as separate ExecStart arguments"
  )
  ok "non-empty derper config emits a valid -c argument"
}

test_unsupported_custom_stun_port_is_rejected() {
  if (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    SERVICE_PATH="$local_tmp/derper.service"
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
    SERVICE_PATH="$local_tmp/derper.service"
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
    service_verified_running() { return 0; }
    systemctl() { return 0; }

    write_systemd_service >/dev/null 2>&1
    grep -qF -- "-verify-clients -socket /run/tailscale/tailscaled.sock" "$SERVICE_PATH" ||
      fail "verify-clients service must pass the tailscaled socket through -socket"
    ! grep -qF "TS_LOCAL_API_SOCKET" "$SERVICE_PATH" ||
      fail "service must not rely on unsupported TS_LOCAL_API_SOCKET environment variable"
  )
  ok "verify-clients uses the supported derper socket flag"
}

test_acl_cert_snippet_uses_requested_region_endpoint_and_stun() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  REGION_ID="1234"
  REGION_CODE="custom-region"
  REGION_NAME="Custom Region"
  IP_ADDR="203.0.113.20"
  DERP_PORT="30443"
  STUN_PORT="40000"
  local output
  output=$(print_acl_snippet_cert "${IP_ADDR}" "${DERP_PORT}" "deadbeef")
  [[ "$output" == *'"RegionID": 1234'* ]] || fail "cert ACL should use requested RegionID"
  [[ "$output" == *'"HostName": "203.0.113.20"'* ]] || fail "cert ACL should use requested IP"
  [[ "$output" == *'"DERPPort": 30443'* ]] || fail "cert ACL should use requested DERP port"
  [[ "$output" == *'"STUNPort": 40000'* ]] || fail "cert ACL must include the custom STUN port"
  [[ "$output" == *'"CertName": "sha256-raw:deadbeef"'* ]] || fail "cert ACL should pin the CertName fingerprint"
  [[ "$output" != *'InsecureForTests'* ]] || fail "cert ACL must never emit InsecureForTests"
  ok "cert ACL includes DERPPort/STUNPort/CertName for the requested endpoint"
}

test_missing_fingerprint_fails_instead_of_insecure_fallback() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  IP_ADDR="203.0.113.20"
  DERP_PORT="30443"
  live_cert_sha256_raw() { return 1; }
  journal_certname_raw() { return 1; }
  cert_file_sha256_raw() { return 1; }
  local output rc=0
  output=$(finalize_deployment_report 2>&1) || rc=$?
  [[ $rc -ne 0 ]] || fail "missing certificate fingerprint must fail the deployment"
  [[ "$output" != *'"InsecureForTests": true'* && "$output" != *'"InsecureForTests":true'* ]] ||
    fail "failure path must never emit the InsecureForTests JSON field"
  [[ "$output" == *'排查'* || "$output" == *'CertName'* ]] || fail "failure path should explain how to debug TLS"
  ok "missing fingerprint fails safely without InsecureForTests fallback"
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
    SERVICE_PATH="$local_tmp/derper.service"
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

    IP_ADDR="3.4.5.6"
    openssl() {
      if [[ " $* " == *" -checkend "* ]]; then return 0; fi
      printf '%s\n' "X509v3 Subject Alternative Name:" "    IP Address:13.4.5.6"
    }
    check_cert_status
    [[ $CERT_SAN_MATCH -eq 0 ]] || fail "new IP that is a suffix of the old SAN must not match"

    IP_ADDR="13.4.5.6"
    openssl() {
      if [[ " $* " == *" -checkend "* ]]; then return 0; fi
      printf '%s\n' "X509v3 Subject Alternative Name:" "    IP Address:3.4.5.6"
    }
    check_cert_status
    [[ $CERT_SAN_MATCH -eq 0 ]] || fail "old SAN that is a suffix of the new IP must not match"
  )
  ok "certificate SAN matching treats IP dots literally"
}

test_live_certificate_mismatch_fails_health_check() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  DERPER_RUNNING=1 PORT_TLS_OK=1 PORT_STUN_OK=1 PURE_IP_OK=1 DESIRED_CONFIG_OK=1
  CERT_PRESENT=1 CERT_NAMING_OK=1 CERT_SAN_MATCH=1 CERT_EXPIRY_OK=1
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
    TS_RUNNING=1 TS_AUTH_UNKNOWN=0 TS_LOCALAPI_OK=1
    CERT_PRESENT=1 CERT_NAMING_OK=1 CERT_SAN_MATCH=1 CERT_EXPIRY_OK=1
    LIVE_CERT_CHECKED=1 CERT_LIVE_MATCH=1
    write_prometheus_metrics "$metrics" "100" "256"
    [[ "$(cat "${metrics}.tmp")" == "sentinel" ]] ||
      fail "metrics writer must not use predictable path.prom.tmp"
    grep -qF "derper_up 1" "$metrics" || fail "metrics output should be written"
    grep -qF "derper_healthy 1" "$metrics" || fail "overall health metric should reflect health_is_ok"
    grep -qF "derper_cert_live_match 1" "$metrics" || fail "live certificate consistency metric should be exported"

    # 在线证书不一致时：健康总体应为 0，且一致性指标暴露该故障
    CERT_LIVE_MATCH=0
    write_prometheus_metrics "$metrics" "100" "256"
    grep -qF "derper_healthy 0" "$metrics" || fail "cert mismatch must be visible in overall health metric"
    grep -qF "derper_cert_live_match 0" "$metrics" || fail "cert mismatch must be visible in consistency metric"
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

test_unit_matching_rejects_wrong_socket_path() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  IP_ADDR="203.0.113.10" DERP_PORT="30399" STUN_PORT="3478" INSTALL_DIR="/opt/derper"
  RUN_USER="derper" VERIFY_CLIENTS_MODE="on" SECURITY_LEVEL="standard"
  derper_supports_socket_flag() { return 0; }
  local base good bad
  base=$'[Service]\nUser=derper\n# 安全加固（级别：standard）\nExecStart=/usr/local/bin/derper -c /opt/derper/state/derper.json -hostname 203.0.113.10 -certmode manual -certdir /opt/derper/certs -http-port -1 -a :30399 -stun -stun-port 3478 -verify-clients'
  # 正确 socket 路径应被接受
  good="${base} -socket /run/tailscale/tailscaled.sock"
  unit_matches_desired_config "$good" || fail "correct -socket path should be accepted"
  # 错误 socket 路径应被判为配置漂移
  bad="${base} -socket /var/run/tailscale/tailscaled.sock"
  unit_matches_desired_config "$bad" && fail "wrong -socket path should be rejected as drift"
  ok "unit matching rejects wrong -socket path"
}

test_reconcile_detects_stale_live_cert() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  DERPER_SERVICE_PRESENT=1 DESIRED_CONFIG_OK=1 DERPER_RUNNING=1
  PORT_TLS_OK=1 PORT_STUN_OK=1
  # 在线证书与磁盘证书不一致（如外部替换磁盘证书但 derper 未重启）→ 应触发协调
  LIVE_CERT_CHECKED=1 CERT_LIVE_MATCH=0
  service_needs_reconcile 0 || fail "stale live certificate should trigger reconcile"
  # 在线证书一致时不应触发
  CERT_LIVE_MATCH=1
  service_needs_reconcile 0 && fail "matching live certificate should not trigger reconcile"
  # 未执行在线检查时也不应凭空触发
  LIVE_CERT_CHECKED=0 CERT_LIVE_MATCH=0
  service_needs_reconcile 0 && fail "absent live check must not trigger reconcile"
  ok "stale live certificate triggers service reconcile"
}

test_verify_clients_aligns_derper_version() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  VERIFY_CLIENTS_MODE="on"; DERPER_VERSION="latest"; TS_VERSION="1.80.0"
  ts_commit() { return 1; }
  align_derper_version_with_tailscale >/dev/null 2>&1
  [[ "$DERPER_VERSION" == "v1.80.0" ]] || fail "verify-clients on should align derper to tailscale version"
  # 显式指定版本时不覆盖
  DERPER_VERSION="v1.74.1"
  align_derper_version_with_tailscale >/dev/null 2>&1
  [[ "$DERPER_VERSION" == "v1.74.1" ]] || fail "explicit --derper-version must be respected"
  # 关闭 verify-clients 时不覆盖
  VERIFY_CLIENTS_MODE="off"; DERPER_VERSION="latest"
  align_derper_version_with_tailscale >/dev/null 2>&1
  [[ "$DERPER_VERSION" == "latest" ]] || fail "verify-clients off should keep latest"
  # 检测不到 tailscale 版本时保留 latest
  VERIFY_CLIENTS_MODE="on"; DERPER_VERSION="latest"; TS_VERSION=""
  align_derper_version_with_tailscale >/dev/null 2>&1
  [[ "$DERPER_VERSION" == "latest" ]] || fail "unknown tailscale version should keep latest"
  # 能拿到 Git commit 时，优先对齐到同一 revision（真正同源）
  VERIFY_CLIENTS_MODE="on"; DERPER_VERSION="latest"; TS_VERSION="1.80.0"
  ts_commit() { echo "6b69a2e1234567890abcdef"; }
  align_derper_version_with_tailscale >/dev/null 2>&1
  [[ "$DERPER_VERSION" == "6b69a2e1234567890abcdef" ]] || fail "verify-clients on should prefer the tailscaled git commit"
  ok "verify-clients aligns derper version with tailscale"
}

# 回归：ts_commit 必须解析真实 tailscale version 输出（字段名是 "tailscale commit:"，
# 曾被误写成 "tail commit:" 导致 commit 对齐永远不触发；此前测试只 stub 了 ts_commit 本身，
# 掩盖了该问题）。此处 stub tailscale 命令本身，走完整解析路径。
test_ts_commit_parses_real_tailscale_output() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    tailscale() {
      printf '%s\n' \
        "1.98.5" \
        "  tailscale commit: 6b69a2e1234567890abcdef" \
        "  long version: 1.98.5-t6b69a2e1234567890abcdef-gc1619fb10" \
        "  other commit: c1619fb10d5db0f7cb1d109d5b67d053f7751508" \
        "  go version: go1.26.3 (tailscale/go e877d97384)"
    }
    [[ "$(ts_commit)" == "6b69a2e1234567890abcdef" ]] ||
      fail "ts_commit must parse the 'tailscale commit:' field from real output"
    # 不含该字段时必须返回空（走版本标签回退），而不是误抓其他行
    tailscale() { printf '%s\n' "1.98.5" "  track: stable"; }
    [[ -z "$(ts_commit)" ]] || fail "ts_commit must stay empty when the commit field is absent"
  )
  ok "ts_commit parses real tailscale version output"
}

test_manual_cert_uses_upstream_filenames() {
  local cert_mode
  for cert_mode in addext config; do
    (
      DERPER_TEST_MODE=1 source "$SCRIPT"
      chown() { :; }
      command -v openssl >/dev/null 2>&1 || { echo "ok - certificate naming skipped (no openssl)"; return 0; }
      local_tmp=$(mktemp -d)
      trap 'rm -rf "$local_tmp"' EXIT
      SERVICE_PATH="$local_tmp/derper.service"
      INSTALL_DIR="$local_tmp"
      IP_ADDR="203.0.113.10"
      CERT_DAYS="30"
      openssl() {
        if [[ "$cert_mode" == config && " $* " == *' -addext '* ]]; then
          return 1
        fi
        command openssl "$@"
      }
      generate_derper_config() { :; }
      generate_selfsigned_cert >/dev/null
      [[ -f "${INSTALL_DIR}/certs/203.0.113.10.crt" ]] || fail "missing upstream <ip>.crt"
      [[ -f "${INSTALL_DIR}/certs/203.0.113.10.key" ]] || fail "missing upstream <ip>.key"
      [[ -L "${INSTALL_DIR}/certs/fullchain.pem" ]] || fail "fullchain.pem should be a compatibility symlink"
      check_cert_status
      [[ $CERT_PRESENT -eq 1 && $CERT_NAMING_OK -eq 1 && $CERT_SAN_MATCH -eq 1 ]] ||
        fail "generated upstream-named certificate should pass cert status checks"
      [[ -z "$(find "${INSTALL_DIR}/certs" -name '.derper-*' -print)" ]] ||
        fail "certificate generation should remove temporary files"
    )
    ok "self-signed cert uses derper manual filenames ($cert_mode)"
  done
}

test_cert_fallback_temp_failure_is_handled() {
  local kind output rc
  for kind in key cert cnf; do
    rc=0
    output=$(
      exec 2>&1
      DERPER_TEST_MODE=1 source "$SCRIPT"
      chown() { :; }
      local_tmp=$(mktemp -d)
      trap 'rm -rf "$local_tmp"' EXIT
      SERVICE_PATH="$local_tmp/derper.service"
      INSTALL_DIR="$local_tmp"
      IP_ADDR="203.0.113.10"
      CERT_DAYS="30"
      harden_cert_dir() { :; }
      openssl() { touch "${local_tmp}/fallback"; return 1; }
      mktemp() {
        if [[ -f "${local_tmp}/fallback" && "$1" == *".derper-${kind}."* ]]; then
          return 1
        fi
        command mktemp "$@"
      }
      result=0
      generate_selfsigned_cert || result=$?
      [[ -z "$(find "${INSTALL_DIR}/certs" -name '.derper-*' -print)" ]] ||
        fail "failed certificate generation should remove temporary files"
      exit "$result"
    ) || rc=$?
    [[ "$rc" -eq 1 && "$output" == *'创建临时文件'* ]] ||
      fail "fallback $kind temp failure should return the intended diagnostic: $output"
    [[ "$output" != *'unbound variable'* ]] || fail "cleanup must not access unset variables"
    ok "certificate fallback handles $kind temporary file failure"
  done
}

test_derper_binary_needs_reinstall_on_version_mismatch() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    BIN_PATH="${local_tmp}/derper"
    printf '#!/bin/sh\necho fake\n' >"$BIN_PATH"
    chmod +x "$BIN_PATH"

    DERPER_VERSION="latest"
    if derper_binary_needs_install; then
      fail "existing binary with latest target should not force reinstall"
    fi

    DERPER_VERSION="v1.80.0"
    get_installed_derper_version() { echo "1.74.1"; }
    if ! derper_binary_needs_install; then
      fail "mismatched pinned version should require reinstall"
    fi

    get_installed_derper_version() { echo "1.80.0"; }
    if derper_binary_needs_install; then
      fail "matching pinned version should skip reinstall"
    fi

    # 按 Git commit 对齐时，已安装伪版本包含该 commit 即视为同源
    DERPER_VERSION="abcdef1234567890abcdef12"
    get_installed_derper_version() { echo "1.80.0-0.20250814000000-abcdef123456"; }
    if derper_binary_needs_install; then
      fail "installed pseudo-version containing the target commit should be considered aligned"
    fi
    DERPER_VERSION="ABCDEF1234567890ABCDEF12"
    if derper_binary_needs_install; then
      fail "uppercase commit must match lowercase pseudo-version revision"
    fi
    get_installed_derper_version() { echo "1.80.0"; }
    if ! derper_binary_needs_install; then
      fail "plain version without the target commit should require reinstall"
    fi
  )
  ok "derper binary reinstall is driven by real version mismatch"
}

test_paranoid_degraded_unit_is_accepted() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  IP_ADDR="203.0.113.10" DERP_PORT="30399" STUN_PORT="3478" INSTALL_DIR="/opt/derper"
  RUN_USER="derper" VERIFY_CLIENTS_MODE="off" SECURITY_LEVEL="paranoid"
  derper_supports_socket_flag() { return 1; }
  local full degraded
  full=$'[Service]\nUser=derper\n# 安全加固（级别：paranoid）\nMemoryDenyWriteExecute=true\nExecStart=/usr/local/bin/derper -c /opt/derper/state/derper.json -hostname 203.0.113.10 -certmode manual -certdir /opt/derper/certs -http-port -1 -a :30399 -stun -stun-port 3478\n'
  unit_matches_desired_config "$full" || fail "full paranoid unit should match"

  degraded=$'[Service]\nUser=derper\n# 安全加固（级别：paranoid；已禁用 MemoryDenyWriteExecute）\nExecStart=/usr/local/bin/derper -c /opt/derper/state/derper.json -hostname 203.0.113.10 -certmode manual -certdir /opt/derper/certs -http-port -1 -a :30399 -stun -stun-port 3478\n'
  unit_matches_desired_config "$degraded" || fail "explicitly degraded paranoid unit should match"

  local fake_full
  fake_full=$'[Service]\nUser=derper\n# 安全加固（级别：paranoid）\nExecStart=/usr/local/bin/derper -c /opt/derper/state/derper.json -hostname 203.0.113.10 -certmode manual -certdir /opt/derper/certs -http-port -1 -a :30399 -stun -stun-port 3478\n'
  unit_matches_desired_config "$fake_full" && fail "paranoid comment without MemoryDenyWriteExecute should be drift"
  ok "paranoid degraded marker is honored by config matching"
}

test_start_limit_lives_in_unit_section() {
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
    derper_supports_stun_port() { return 0; }
    derper_supports_listen_a() { return 0; }
    setup_service_user() { return 0; }
    service_verified_running() { return 0; }
    systemctl() { return 0; }
    write_systemd_service >/dev/null
    awk '
      /^\[Unit\]/ { in_unit=1; in_service=0; next }
      /^\[Service\]/ { in_unit=0; in_service=1; next }
      /^\[/ { in_unit=0; in_service=0; next }
      /^StartLimitBurst=/ { if (!in_unit) exit 2; found=1 }
      /^StartLimitIntervalSec=/ { if (!in_unit) exit 3; found2=1 }
      END { if (!found || !found2) exit 4 }
    ' "$SERVICE_PATH" || fail "StartLimit* must live under [Unit]"
  )
  ok "systemd StartLimit settings are under [Unit]"
}

test_socket_access_skips_when_world_writable() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  local_tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$local_tmp'" RETURN
  local sock="${local_tmp}/tailscaled.sock"
  local py=""
  if command -v python3 >/dev/null 2>&1; then
    py=python3
  elif command -v python >/dev/null 2>&1; then
    py=python
  else
    ok "socket access skip test skipped (no python)"
    return 0
  fi
  if ! "$py" -c "import socket,os;p=r'''${sock}''';
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);
os.path.exists(p) and os.unlink(p);s.bind(p);os.chmod(p,0o666);s.close()" 2>/dev/null; then
    ok "socket access skip test skipped (unix socket unavailable)"
    return 0
  fi
  [[ -S "$sock" ]] || { ok "socket access skip test skipped (socket missing)"; return 0; }
  user_can_access_socket "$(id -un)" "$sock" || fail "world-writable socket should be considered accessible"
  ok "world-writable socket is treated as already accessible"
}

test_health_requires_upstream_cert_naming() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  DERPER_RUNNING=1 PORT_TLS_OK=1 PORT_STUN_OK=1 PURE_IP_OK=1 DESIRED_CONFIG_OK=1
  CERT_PRESENT=1 CERT_NAMING_OK=0 CERT_SAN_MATCH=1 CERT_EXPIRY_OK=1
  LIVE_CERT_CHECKED=0
  health_is_ok && fail "health should fail when certificate naming is incompatible"
  CERT_NAMING_OK=1
  health_is_ok || fail "health should pass once naming is compatible"
  ok "health check requires derper-compatible certificate names"
}

test_script_version_is_declared_and_consistent() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  [[ -n "${SCRIPT_VERSION:-}" ]] || fail "SCRIPT_VERSION must be declared"
  [[ "${SCRIPT_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "SCRIPT_VERSION must be semver: ${SCRIPT_VERSION}"

  local file_ver output
  file_ver=$(tr -d ' \t\r\n' <"${ROOT_DIR}/VERSION")
  [[ "$file_ver" == "$SCRIPT_VERSION" ]] ||
    fail "VERSION file (${file_ver}) must match SCRIPT_VERSION (${SCRIPT_VERSION})"

  output=$(bash "$SCRIPT" --version)
  [[ "$output" == *" ${SCRIPT_VERSION} "* ]] || fail "--version should print SCRIPT_VERSION"
  output=$(bash "$SCRIPT" -V)
  [[ "$output" == *" ${SCRIPT_VERSION} "* ]] || fail "-V should print SCRIPT_VERSION"
  ok "script version is declared and consistent with VERSION/--version"
}

test_non_global_ips_rejected_unless_explicitly_allowed() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  RUN_USER="$(id -un)"

  IP_ADDR="100.64.0.1" ALLOW_NON_GLOBAL_IP=0
  if validate_settings >/dev/null 2>&1; then
    fail "CGNAT 100.64.0.1 must be rejected in production mode"
  fi
  IP_ADDR="100.64.0.1" ALLOW_NON_GLOBAL_IP=1
  validate_settings >/dev/null 2>&1 || fail "CGNAT address should pass with --allow-non-global-ip"
  IP_ADDR="203.0.113.10" ALLOW_NON_GLOBAL_IP=0
  if validate_settings >/dev/null 2>&1; then
    fail "TEST-NET-3 documentation address must be rejected in production mode"
  fi
  IP_ADDR="192.168.1.10" ALLOW_NON_GLOBAL_IP=0
  if validate_settings >/dev/null 2>&1; then
    fail "private address must be rejected in production mode"
  fi
  IP_ADDR="224.0.0.1" ALLOW_NON_GLOBAL_IP=0
  if validate_settings >/dev/null 2>&1; then
    fail "multicast address must be rejected"
  fi
  IP_ADDR="8.8.8.8" ALLOW_NON_GLOBAL_IP=0
  validate_settings >/dev/null 2>&1 || fail "global unicast address should pass"
  ok "non-global IPv4 addresses are rejected unless --allow-non-global-ip"
}

test_region_id_safe_integer_range() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  IP_ADDR="8.8.8.8"
  RUN_USER="$(id -un)"

  REGION_ID="900"
  validate_settings >/dev/null 2>&1 || fail "RegionID 900 should be valid"
  REGION_ID="9007199254740991"
  validate_settings >/dev/null 2>&1 || fail "RegionID at Number.MAX_SAFE_INTEGER should be valid"
  REGION_ID="9007199254740993"
  if validate_settings >/dev/null 2>&1; then
    fail "RegionID beyond JavaScript safe integer range must be rejected"
  fi
  REGION_ID="0"
  if validate_settings >/dev/null 2>&1; then
    fail "RegionID 0 must be rejected"
  fi
  ok "RegionID is bounded to the JavaScript safe integer range"
}

test_argument_combinations_are_validated() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  PURGE=1 UNINSTALL=0 METRICS_TEXTFILE="" FORCE=0 REPAIR=0 DRY_RUN=0
  validate_arg_combos && fail "--purge without --uninstall must be rejected"
  PURGE=0 UNINSTALL=1
  validate_arg_combos || fail "--uninstall alone should be valid"

  PURGE=0 UNINSTALL=0 METRICS_TEXTFILE="/tmp/x.prom" HEALTH_CHECK=0 INSTALL_HEALTHCHECK_CRON=0
  validate_arg_combos && fail "--metrics-textfile without --health-check must be rejected"
  INSTALL_HEALTHCHECK_CRON=1
  validate_arg_combos || fail "--metrics-textfile with --install-healthcheck-cron should be valid"
  METRICS_TEXTFILE="" HEALTH_CHECK=0 INSTALL_HEALTHCHECK_CRON=0

  FORCE=1 REPAIR=1
  validate_arg_combos && fail "--force with --repair must be rejected"
  FORCE=0 REPAIR=0

  UNINSTALL=1 FORCE=1
  validate_arg_combos && fail "--uninstall with --force must be rejected"
  FORCE=0 UNINSTALL=0

  DRY_RUN=1 REPAIR=1
  validate_arg_combos && fail "--check with --repair must be rejected"
  DRY_RUN=0 REPAIR=0

  validate_arg_combos || fail "no conflicting options should pass"
  ok "conflicting/ignored argument combinations are rejected"
}

test_cert_generation_refuses_symlinked_paths() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    SERVICE_PATH="$local_tmp/derper.service"
    INSTALL_DIR="$local_tmp"
    IP_ADDR="203.0.113.10"
    CERT_DAYS="30"
    RUN_USER="$(id -un)"
    mkdir -p "${INSTALL_DIR}/certs"
    # derper 用户把 <IP>.key 预埋成指向其他文件的符号链接
    printf 'precious-data\n' >"${local_tmp}/victim"
    ln -s "${local_tmp}/victim" "${INSTALL_DIR}/certs/203.0.113.10.key"
    generate_derper_config() { :; }
    if generate_selfsigned_cert >/dev/null 2>&1; then
      fail "cert generation must refuse a symlinked key path"
    fi
    [[ "$(cat "${local_tmp}/victim")" == "precious-data" ]] ||
      fail "symlink target must not be overwritten"
    ok "cert generation refuses symlinked cert/key paths"
  )
}

test_acl_failure_never_emits_insecure_flag() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  local output
  output=$(print_acl_snippet_cert "203.0.113.10" "30399" "abcd1234")
  [[ "$output" != *'InsecureForTests'* ]] || fail "cert-based ACL must not contain InsecureForTests"
  ok "cert-based ACL never emits InsecureForTests"
}

test_extra_listener_detection_flags_attack_surface() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  DERP_PORT="30399"
  ss() {
    cat <<'EOT'
State   Recv-Q  Send-Q   Local Address:Port   Peer Address:Port
LISTEN  0       128            0.0.0.0:30399         0.0.0.0:*
LISTEN  0       128            0.0.0.0:22            0.0.0.0:*
LISTEN  0       128            0.0.0.0:8080          0.0.0.0:*
LISTEN  0       128          127.0.0.1:9090          0.0.0.0:*
LISTEN  0       128               [::1]:631          0.0.0.0:*
EOT
  }
  check_extra_attack_surface >/dev/null 2>&1
  [[ -n "$EXTRA_LISTENERS" ]] || fail "extra non-loopback listeners should be flagged"
  [[ "$EXTRA_LISTENERS" != *"30399"* ]] || fail "own DERP port must not be flagged"
  [[ "$EXTRA_LISTENERS" == *"0.0.0.0:22"* ]] || fail "wildcard SSH listener should be flagged"
  [[ "$EXTRA_LISTENERS" == *"0.0.0.0:8080"* ]] || fail "wildcard HTTP listener should be flagged"
  [[ "$EXTRA_LISTENERS" != *"127.0.0.1"* && "$EXTRA_LISTENERS" != *"::1"* ]] ||
    fail "loopback listeners should not be flagged"
  ok "attack-surface check flags only non-loopback extra listeners"
}

test_automatic_updates_detection_runs() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  check_automatic_updates >/dev/null 2>&1
  [[ "$AUTO_UPDATES_OK" == "0" || "$AUTO_UPDATES_OK" == "1" ]] ||
    fail "auto-updates check must set AUTO_UPDATES_OK to 0 or 1"
  ok "automatic-updates detection runs without errors"
}

test_server_node_acl_advice_includes_tag() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  local output
  output=$(print_server_node_acl_advice)
  [[ "$output" == *"tag:derper-server"* ]] || fail "server-node advice should suggest tagging the server"
  [[ "$output" == *"tagOwners"* ]] || fail "advice should show tagOwners declaration"
  [[ "$output" == *"src"* ]] || fail "advice should warn against granting src access to the server tag"
  ok "server-node ACL restriction advice is emitted"
}

test_go_toolchain_rejects_pre_1_21() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  [[ "$(parse_go_version 'go version go1.18.1 linux/amd64')" == "1.18.1" ]] ||
    fail "parse_go_version must extract 1.18.1 from go version output"
  [[ "$(parse_go_version 'go version go1.22.6 linux/amd64')" == "1.22.6" ]] ||
    fail "parse_go_version must extract 1.22.6 from go version output"

  go() { echo "go version go1.18.1 linux/amd64"; }
  if go_toolchain_meets_min; then
    fail "apt Go 1.18 must be rejected (GOTOOLCHAIN=auto requires >= 1.21)"
  fi
  go() { echo "go version go1.22.6 linux/amd64"; }
  go_toolchain_meets_min || fail "Go 1.22.6 must satisfy the minimum toolchain"
  ok "Go toolchain below 1.21 is rejected"
}

test_get_installed_derper_version_ignores_go_toolchain() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    BIN_PATH="${local_tmp}/derper"
    printf 'not a real binary\ngo1.22.6\nruntime go1.22.6\n' >"$BIN_PATH"
    chmod +x "$BIN_PATH"
    go() { return 1; }

    local ver
    ver=$(get_installed_derper_version || true)
    [[ -z "$ver" ]] || fail "Go toolchain strings must not be reported as derper version, got: ${ver}"

    printf 'tailscale.com v1.80.0\n' >>"$BIN_PATH"
    ver=$(get_installed_derper_version || true)
    [[ "$ver" == "1.80.0" ]] || fail "tailscale.com module version should still be detected, got: ${ver}"
  )
  ok "installed derper version parser ignores Go toolchain strings"
}

test_port_conflict_allows_derper_tls_without_stun() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  DERP_PORT="30399"
  STUN_PORT="3478"
  CURRENT_DERPER_OWNS_PORTS=0
  check_port_conflicts_from_listening $'tcp LISTEN 0 4096 *:30399 *:* users:(("derper",pid=1234,fd=3))\n' ||
    fail "old derper listening only on TLS must not block --force/--repair"
  ok "missing STUN listener is not treated as a self-port conflict"
}

test_port_conflict_rejects_foreign_stun() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  DERP_PORT="30399"
  STUN_PORT="3478"
  CURRENT_DERPER_OWNS_PORTS=0
  if check_port_conflicts_from_listening $'tcp LISTEN 0 4096 *:30399 *:* users:(("derper",pid=1234,fd=3))\nudp UNCONN 0 0 *:3478 *:* users:(("unbound",pid=9,fd=3))\n'; then
    fail "STUN occupied by a non-derper process must remain a conflict"
  fi
  ok "foreign STUN occupancy is still a conflict"
}

test_ensure_compatible_certs_migrates_legacy_names() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    SERVICE_PATH="$local_tmp/derper.service"
    INSTALL_DIR="$local_tmp"
    IP_ADDR="203.0.113.10"
    mkdir -p "${INSTALL_DIR}/certs"
    printf 'legacy-cert\n' >"${INSTALL_DIR}/certs/fullchain.pem"
    printf 'legacy-key\n' >"${INSTALL_DIR}/certs/privkey.pem"
    CERT_PRESENT=1 CERT_SAN_MATCH=1 CERT_EXPIRY_OK=1 CERT_NAMING_OK=0
    generate_selfsigned_cert() { fail "naming-only drift must migrate, not re-sign"; }
    harden_cert_dir() { return 0; }
    refuse_symlink() { return 0; }

    ensure_compatible_certs || fail "legacy cert migration should succeed"
    [[ -f "${INSTALL_DIR}/certs/203.0.113.10.crt" ]] || fail "migrated cert must use upstream filename"
    [[ -f "${INSTALL_DIR}/certs/203.0.113.10.key" ]] || fail "migrated key must use upstream filename"
    [[ "${CERT_NAMING_OK}" -eq 1 ]] || fail "CERT_NAMING_OK should be set after migration"
    [[ "${CERTS_CHANGED:-0}" -eq 1 ]] || fail "migration should mark certs as changed"
  )
  ok "--repair reuses legacy certificate name migration"
}

test_ssh_session_via_tailscale_detects_cgnat() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  SSH_CONNECTION="100.64.1.2 54321 100.64.1.3 22"
  ssh_session_via_tailscale || fail "CGNAT 100.x SSH peer must be treated as Tailscale"
  SSH_CONNECTION="fd7a:115c:a1e0::1 54321 fd7a:115c:a1e0::2 22"
  ssh_session_via_tailscale || fail "Tailscale IPv6 SSH peer must be detected"
  SSH_CONNECTION="203.0.113.10 54321 198.51.100.1 22"
  if ssh_session_via_tailscale; then
    fail "public SSH peer must not be treated as Tailscale"
  fi
  unset SSH_CONNECTION
  if ssh_session_via_tailscale; then
    fail "missing SSH_CONNECTION must not be treated as Tailscale"
  fi
  ok "Tailscale SSH sessions are detected from SSH_CONNECTION"
}

test_restart_tailscaled_socket_skips_over_tailscale_ssh() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  SSH_CONNECTION="100.64.1.2 54321 100.64.1.3 22"
  NON_INTERACTIVE=1
  local restarted=0
  systemctl() {
    if [[ " $* " == *" restart "* ]]; then
      restarted=1
    fi
    return 0
  }
  if restart_tailscaled_socket_unit; then
    fail "non-interactive Tailscale SSH must skip tailscaled.socket restart"
  fi
  [[ "$restarted" -eq 0 ]] || fail "tailscaled.socket must not be restarted over Tailscale SSH"
  ok "tailscaled.socket restart is skipped over Tailscale SSH"
}

test_release_tmpdir_clears_deploy_temp() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  _tmpdir=$(mktemp -d)
  local kept="$_tmpdir"
  printf 'x\n' >"${_tmpdir}/keep-me"
  [[ -d "$kept" ]] || fail "precondition: tmpdir must exist"
  release_tmpdir
  [[ -z "${_tmpdir:-}" ]] || fail "release_tmpdir must clear _tmpdir"
  [[ ! -d "$kept" ]] || fail "release_tmpdir must delete the temp directory before exec"
  ok "wizard exec path can drop the deploy temp directory"
}

test_infer_ip_from_existing_unit() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  IP_ADDR=""
  read_derper_unit_content() {
    printf '%s\n' 'ExecStart=/usr/local/bin/derper -hostname 203.0.113.88 -a :30399'
  }
  infer_ip_from_existing_deployment || fail "unit hostname should supply IP for health checks"
  [[ "$IP_ADDR" == "203.0.113.88" ]] || fail "inferred IP mismatch: ${IP_ADDR}"
  ok "health check can infer IP from the deployed unit"
}

test_health_check_skips_external_ip_probe_when_ip_set() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  IP_ADDR="203.0.113.10"
  detect_public_ip() { fail "health-check must not probe the internet when IP is already known"; }
  check_tailscale_status() { :; }
  check_derper_status() { :; }
  check_cert_status() { :; }
  check_live_cert_status() { :; }
  cert_days_remaining() { echo "100"; }
  check_extra_attack_surface() { EXTRA_LISTENERS=""; }
  check_automatic_updates() { :; }
  DERPER_RUNNING=1 PORT_TLS_OK=1 PORT_STUN_OK=1 PURE_IP_OK=1 DESIRED_CONFIG_OK=1
  CERT_LIVE_MATCH=1 CERT_NAMING_OK=1
  health_check_report >/dev/null
  ok "health-check does not re-probe public IP when already set"
}

test_goproxy_probe_targets_skip_direct() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  GOPROXY_ARG="https://goproxy.cn,direct"
  local out
  out=$(goproxy_probe_targets)
  [[ "$out" == "https://goproxy.cn" ]] || fail "expected goproxy.cn only, got: $out"
  GOPROXY_ARG=""
  unset GOPROXY
  out=$(goproxy_probe_targets)
  [[ "$out" == "https://proxy.golang.org" ]] || fail "default proxy should be proxy.golang.org, got: $out"
  ok "goproxy probe targets skip direct and default to proxy.golang.org"
}

test_precheck_go_network_fails_fast_with_hint() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  GOPROXY_ARG="https://example.invalid"
  curl() { return 7; }
  local err
  err=$(precheck_go_network 2>&1) && fail "unreachable proxy must fail"
  echo "$err" | grep -q -- '--goproxy' || fail "failure must hint --goproxy, got: $err"
  ok "module proxy precheck fails fast and hints --goproxy"
}

test_precheck_go_network_succeeds_when_reachable() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  GOPROXY_ARG="https://goproxy.cn,direct"
  curl() { return 0; }
  precheck_go_network || fail "reachable proxy must pass"
  ok "module proxy precheck passes when curl succeeds"
}

test_get_installed_derper_version_without_strings() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    BIN_PATH="${local_tmp}/derper"
    printf 'not a real binary\ngo1.22.6\ntailscale.com v1.80.0\n' >"$BIN_PATH"
    chmod +x "$BIN_PATH"
    go() { return 1; }
    strings() { return 127; }
    local ver
    ver=$(get_installed_derper_version || true)
    [[ "$ver" == "1.80.0" ]] || fail "grep fallback must find module version without strings, got: ${ver}"
  )
  ok "installed derper version parser works without strings"
}

test_relax_socket_perms_restored_on_cleanup() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  local_tmp=$(mktemp -d)
  trap "rm -rf '$local_tmp'" RETURN
  local sock="${local_tmp}/tailscaled.sock"
  local py=""
  if command -v python3 >/dev/null 2>&1; then
    py=python3
  elif command -v python >/dev/null 2>&1; then
    py=python
  else
    ok "socket restore test skipped (no python)"
    return 0
  fi
  if ! "$py" -c "import socket,os;p=r'''${sock}''';
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);
os.path.exists(p) and os.unlink(p);s.bind(p);os.chmod(p,0o660);s.close()" 2>/dev/null; then
    ok "socket restore test skipped (unix socket unavailable)"
    return 0
  fi
  [[ -S "$sock" ]] || { ok "socket restore test skipped (socket missing)"; return 0; }
  RELAX_SOCKET_PERMS=1
  relax_socket_world_writable "$sock" || fail "relax should succeed"
  local now
  now=$(stat -c '%a' "$sock" 2>/dev/null || stat -f '%OLp' "$sock")
  [[ "$now" == "666" ]] || fail "socket should be 666 after relax, got $now"
  restore_relaxed_socket_perms || fail "restore should succeed"
  now=$(stat -c '%a' "$sock" 2>/dev/null || stat -f '%OLp' "$sock")
  [[ "$now" == "660" ]] || fail "socket should restore to 660, got $now"
  ok "relaxed socket mode is restored"
}

test_cleanup_restores_relaxed_socket() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  local_tmp=$(mktemp -d)
  trap "rm -rf '$local_tmp'" RETURN
  local sock="${local_tmp}/tailscaled.sock"
  if ! command -v python3 >/dev/null 2>&1; then
    ok "cleanup socket restore skipped (no python)"
    return 0
  fi
  python3 -c "import socket,os;p=r'''${sock}''';
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);
os.path.exists(p) and os.unlink(p);s.bind(p);os.chmod(p,0o640);s.close()" 2>/dev/null || {
    ok "cleanup socket restore skipped (unix socket unavailable)"
    return 0
  }
  RELAX_SOCKET_PERMS=1
  relax_socket_world_writable "$sock"
  cleanup_deployment 0
  local now
  now=$(stat -c '%a' "$sock" 2>/dev/null || stat -f '%OLp' "$sock")
  [[ "$now" == "640" ]] || fail "cleanup must restore original socket mode, got $now"
  ok "cleanup restores relaxed socket permissions"
}

test_world_writable_socket_is_warned() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  local_tmp=$(mktemp -d)
  trap "rm -rf '$local_tmp'" RETURN
  local sock="${local_tmp}/tailscaled.sock"
  if ! command -v python3 >/dev/null 2>&1; then
    ok "socket warning skipped (no python)"
    return 0
  fi
  python3 -c "import socket,os;p=r'''${sock}''';
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);
os.path.exists(p) and os.unlink(p);s.bind(p);os.chmod(p,0o666);s.close()" 2>/dev/null || {
    ok "socket warning skipped (unix socket unavailable)"
    return 0
  }
  local out
  out=$(warn_world_writable_socket "$sock" 2>&1)
  echo "$out" | grep -q '0666' || fail "health warning must mention 0666, got: $out"
  echo "$out" | grep -q '这是应急状态' && fail "0666 must not be described as an emergency state, got: $out"
  ok "world-writable tailscaled socket is warned"
}

test_tls_connlimit_zero_is_noop() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  TLS_CONNLIMIT=0
  nft() { fail "nft must not run when connlimit is 0"; }
  iptables() { fail "iptables must not run when connlimit is 0"; }
  apply_tls_connlimit || fail "zero connlimit should succeed as no-op"
  ok "tls connlimit 0 does not touch firewall"
}

test_tls_connlimit_iptables_rule() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    TLS_CONNLIMIT=32
    DERP_PORT=30399
    local cmds=""
    command() {
      if [[ "$1" == -v && "$2" == nft ]]; then return 1; fi
      if [[ "$1" == -v && "$2" == iptables ]]; then return 0; fi
      builtin command "$@"
    }
    iptables() {
      cmds+="$*"$'\n'
      return 0
    }
    apply_tls_connlimit || fail "iptables connlimit should apply"
    echo "$cmds" | grep -q 'connlimit-above 32' || fail "missing connlimit-above, commands: $cmds"
    echo "$cmds" | grep -q -- '--dport 30399' || fail "missing dport, commands: $cmds"
  )
  ok "tls connlimit installs iptables connlimit rule"
}

test_tls_connlimit_removed_on_uninstall() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local cmds=""
    command() {
      if [[ "$1" == -v && "$2" == nft ]]; then return 1; fi
      if [[ "$1" == -v && "$2" == iptables ]]; then return 0; fi
      builtin command "$@"
    }
    iptables() {
      cmds+="$*"$'\n'
      return 0
    }
    remove_tls_connlimit || fail "remove should succeed"
    echo "$cmds" | grep -q 'DERPER-CONNLIMIT' || fail "remove must target DERPER-CONNLIMIT, got: $cmds"
  )
  ok "tls connlimit chain is removed"
}

test_install_healthcheck_cron_writes_job() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    HEALTHCHECK_CRON_PATH="${local_tmp}/derper-healthcheck"
    IP_ADDR="203.0.113.10"
    METRICS_TEXTFILE="${local_tmp}/derper.prom"
    SCRIPT_SELF="${local_tmp}/deploy_derper_ip_selfsigned.sh"
    printf '#!/bin/bash\n' >"$SCRIPT_SELF"
    # 1) cron 后备分支（无 systemctl）
    command() {
      if [[ "$1" == -v && "$2" == systemctl ]]; then return 1; fi
      builtin command "$@"
    }
    install_healthcheck_cron || fail "cron install should succeed"
    [[ -f "$HEALTHCHECK_CRON_PATH" ]] || fail "cron file missing"
    grep -q -- '--health-check' "$HEALTHCHECK_CRON_PATH" || fail "cron must call --health-check"
    grep -q -- '--ip 203.0.113.10' "$HEALTHCHECK_CRON_PATH" || fail "cron must pin --ip"
    grep -q -- '--derp-port' "$HEALTHCHECK_CRON_PATH" || fail "cron must pin --derp-port"
    grep -q -- '--stun-port' "$HEALTHCHECK_CRON_PATH" || fail "cron must pin --stun-port"
    grep -q -- '--metrics-textfile' "$HEALTHCHECK_CRON_PATH" || fail "cron must write metrics textfile"

    # 2) systemd timer 分支（有 systemctl + 可写 HEALTHCHECK_UNIT_DIR）
    unset -f command
    systemctl() { return 0; }
    HEALTHCHECK_UNIT_DIR="${local_tmp}/units"
    install_healthcheck_cron || fail "timer install should succeed"
    [[ -f "${HEALTHCHECK_UNIT_DIR}/derper-healthcheck.service" ]] || fail "timer service unit missing"
    [[ -f "${HEALTHCHECK_UNIT_DIR}/derper-healthcheck.timer" ]] || fail "timer unit missing"
    [[ ! -e "$HEALTHCHECK_CRON_PATH" ]] || fail "timer install must remove legacy cron file"
    grep -q -- '--health-check' "${HEALTHCHECK_UNIT_DIR}/derper-healthcheck.service" || fail "timer service must call --health-check"
    grep -q -- '--ip 203.0.113.10' "${HEALTHCHECK_UNIT_DIR}/derper-healthcheck.service" || fail "timer service must pin --ip"
  )
  ok "healthcheck cron and systemd timer files are installed"
}

test_uninstall_removes_healthcheck_cron() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    HEALTHCHECK_CRON_PATH="${local_tmp}/derper-healthcheck"
    printf 'job\n' >"$HEALTHCHECK_CRON_PATH"
    SERVICE_PATH="${local_tmp}/derper.service"
    INSTALL_DIR="${local_tmp}/install"
    BIN_PATH="${local_tmp}/derper"
    UNINSTALL=1
    mkdir -p "${SERVICE_PATH}.certs-rollback/certs"
    printf leftover-key >"${SERVICE_PATH}.certs-rollback/certs/old.key"
    command() {
      if [[ "$1" == -v && ( "$2" == systemctl || "$2" == nft || "$2" == iptables ) ]]; then return 1; fi
      builtin command "$@"
    }
    nft() { return 0; }
    iptables() { return 0; }
    require_root() { :; }
    uninstall_derper >/dev/null 2>&1
    [[ ! -e "$HEALTHCHECK_CRON_PATH" ]] || fail "cron file should be removed on uninstall"
    [[ ! -e "${SERVICE_PATH}.certs-rollback" ]] || fail "certs-rollback backup should be removed on uninstall"
  )
  ok "uninstall removes healthcheck cron"
}

test_healthcheck_cron_conflicts_with_uninstall() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    INSTALL_HEALTHCHECK_CRON=1 UNINSTALL=1 PURGE=0 FORCE=0 REPAIR=0 DRY_RUN=0 HEALTH_CHECK=0 METRICS_TEXTFILE=""
    validate_arg_combos && fail "--install-healthcheck-cron with --uninstall must be rejected"
    UNINSTALL=0
    parse_args --install-healthcheck-cron
    [[ "$INSTALL_HEALTHCHECK_CRON" -eq 1 ]] || fail "parse_args should set INSTALL_HEALTHCHECK_CRON"
    validate_arg_combos || fail "install-healthcheck-cron alone should be valid"
    true
  )
  ok "healthcheck cron argument combinations are validated"
}

test_tls_connlimit_parse_and_reject() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  parse_args --tls-connlimit 16
  [[ "$TLS_CONNLIMIT" == "16" ]] || fail "parse_args should set TLS_CONNLIMIT, got $TLS_CONNLIMIT"
  [[ "${TLS_CONNLIMIT_EXPLICIT:-0}" -eq 1 ]] || fail "explicit --tls-connlimit must set TLS_CONNLIMIT_EXPLICIT"
  TLS_CONNLIMIT="nope"
  IP_ADDR="8.8.8.8"
  RUN_USER="$(id -un)"
  if validate_settings >/dev/null 2>&1; then
    fail "non-numeric tls-connlimit must be rejected"
  fi
  ok "tls-connlimit is parsed and validated"
}

test_module_query_survives_missing_timeout() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    command() {
      if [[ "$1" == -v && "$2" == timeout ]]; then return 1; fi
      builtin command "$@"
    }
    go() { :; }
    env() { echo v1.102.4; }
    local out
    out=$(resolve_derper_module_version abcdef123456) || fail "missing timeout must not crash module query"
    [[ "$out" == v1.102.4 ]] || fail "expected v1.102.4, got $out"
  )
  ok "module query works when timeout is absent"
}

test_install_derper_survives_missing_timeout() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    BIN_PATH="${local_tmp}/derper"
    _tmpdir="$local_tmp"
    DEPLOY_STATE_DIR="${local_tmp}/deploy-state"
    VERIFY_CLIENTS_MODE=off
    DERPER_VERSION=v1.80.0
    GOPROXY_ARG=""
    GOSUMDB_ARG=""
    command() {
      if [[ "$1" == -v && "$2" == timeout ]]; then return 1; fi
      builtin command "$@"
    }
    precheck_go_network() { return 0; }
    ensure_go() { return 0; }
    go() {
      mkdir -p "$GOBIN"
      printf '#!/bin/sh\necho -a\n' >"$GOBIN/derper"
      chmod +x "$GOBIN/derper"
    }
    env() { go; }
    install_derper >/dev/null || fail "install_derper must succeed without timeout"
    [[ -x "$BIN_PATH" ]] || fail "derper binary missing after install without timeout"
  )
  ok "install_derper works when timeout is absent"
}

test_healthcheck_cron_conflicts_with_health_check() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    parse_args --install-healthcheck-cron --health-check --ip 203.0.113.10
    if validate_arg_combos; then fail "--install-healthcheck-cron with --health-check must be rejected"; fi
  )
  ok "healthcheck cron cannot combine with --health-check"
}

test_tls_connlimit_conflicts_with_readonly_modes() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    INSTALL_HEALTHCHECK_CRON=0 HEALTH_CHECK=0 DRY_RUN=0 CHECK_ONLY=0 TLS_CONNLIMIT_EXPLICIT=0
    parse_args --tls-connlimit 32 --health-check --ip 203.0.113.10
    [[ "${INSTALL_HEALTHCHECK_CRON:-0}" -eq 0 ]] || fail "tls conflict test must not inherit INSTALL_HEALTHCHECK_CRON"
    local err="" rc=0
    err=$(validate_arg_combos 2>&1) || rc=$?
    [[ "$rc" -ne 0 ]] || fail "--tls-connlimit with --health-check must be rejected"
    echo "$err" | grep -q 'tls-connlimit' || fail "rejection must cite tls-connlimit, got: $err"
    HEALTH_CHECK=0 DRY_RUN=0 CHECK_ONLY=0 INSTALL_HEALTHCHECK_CRON=0
    parse_args --tls-connlimit 32 --check --ip 203.0.113.10
    rc=0
    err=$(validate_arg_combos 2>&1) || rc=$?
    [[ "$rc" -ne 0 ]] || fail "--tls-connlimit with --check must be rejected"
    echo "$err" | grep -q 'tls-connlimit' || fail "check rejection must cite tls-connlimit, got: $err"
    HEALTH_CHECK=0 DRY_RUN=0 CHECK_ONLY=0 INSTALL_HEALTHCHECK_CRON=0
    parse_args --tls-connlimit 32 --ip 203.0.113.10
    validate_arg_combos || fail "--tls-connlimit alone should be valid"
  )
  ok "tls-connlimit is rejected with check/health-check"
}

test_tls_connlimit_explicit_zero_removes_rules() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    parse_args --tls-connlimit 0
    local cmds=""
    command() {
      if [[ "$1" == -v && "$2" == nft ]]; then return 1; fi
      if [[ "$1" == -v && "$2" == iptables ]]; then return 0; fi
      builtin command "$@"
    }
    iptables() {
      cmds+="$*"$'\n'
      return 0
    }
    apply_tls_connlimit || fail "explicit --tls-connlimit 0 should succeed"
    echo "$cmds" | grep -q 'DERPER-CONNLIMIT' || fail "explicit 0 must remove existing rules, commands: $cmds"
  )
  ok "explicit --tls-connlimit 0 removes installed rules"
}

test_install_healthcheck_cron_quotes_paths() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    HEALTHCHECK_CRON_PATH="${local_tmp}/derper-healthcheck"
    HEALTHCHECK_PROGRAM_DIR="${local_tmp}/program dir"
    IP_ADDR="203.0.113.10"
    mkdir -p "${local_tmp}/metrics dir"
    METRICS_TEXTFILE="${local_tmp}/metrics dir/derper.prom"
    SCRIPT_SELF="${local_tmp}/deploy derper.sh"
    printf '#!/bin/bash\n' >"$SCRIPT_SELF"
    command() {
      if [[ "$1" == -v && "$2" == systemctl ]]; then return 1; fi
      builtin command "$@"
    }
    install_healthcheck_cron || fail "cron install should succeed with spaces in paths"
    local expected_prog expected_metrics
    expected_prog=$(printf '%q' "${HEALTHCHECK_PROGRAM_DIR}/deploy_derper_ip_selfsigned.sh")
    expected_metrics=$(printf '%q' "$METRICS_TEXTFILE")
    grep -q 'bash ' "$HEALTHCHECK_CRON_PATH" || fail "cron must invoke bash explicitly, cron=$(cat "$HEALTHCHECK_CRON_PATH")"
    grep -qF -- "$expected_prog" "$HEALTHCHECK_CRON_PATH" || fail "stable program path with spaces must be quoted, cron=$(cat "$HEALTHCHECK_CRON_PATH")"
    grep -qF -- "$expected_metrics" "$HEALTHCHECK_CRON_PATH" || fail "metrics path with spaces must be quoted, cron=$(cat "$HEALTHCHECK_CRON_PATH")"
  )
  ok "healthcheck cron quotes paths that contain spaces"
}

test_precheck_go_network_allows_direct_fallback() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    GOPROXY_ARG="https://example.invalid,direct"
    curl() { return 7; }
    local out
    out=$(precheck_go_network 2>&1) || fail "GOPROXY with ,direct must not abort when proxies are down, got: $out"
    echo "$out" | grep -qi 'direct' || fail "should mention direct fallback, got: $out"
  )
  ok "module proxy precheck falls back to GOPROXY direct"
}

test_overflow_numeric_args_are_rejected() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  IP_ADDR="8.8.8.8"
  RUN_USER="$(id -un)"
  DERP_PORT="18446744073709552059"
  STUN_PORT="3478"
  CERT_DAYS="365"
  REGION_ID="900"
  TLS_CONNLIMIT="0"
  if validate_settings >/dev/null 2>&1; then fail "overflow --derp-port wrapping to 443 must be rejected"; fi
  DERP_PORT="30399"
  STUN_PORT="18446744073709551616"
  if validate_settings >/dev/null 2>&1; then fail "overflow --stun-port wrapping to 0 must be rejected"; fi
  STUN_PORT="3478"
  CERT_DAYS="18446744073709551981"
  if validate_settings >/dev/null 2>&1; then fail "overflow --cert-days wrapping to 365 must be rejected"; fi
  CERT_DAYS="365"
  REGION_ID="18446744073709552516"
  if validate_settings >/dev/null 2>&1; then fail "overflow --region-id wrapping to 900 must be rejected"; fi
  REGION_ID="900"
  TLS_CONNLIMIT="18446744073709551617"
  if validate_settings >/dev/null 2>&1; then fail "overflow --tls-connlimit must be rejected"; fi
  ok "64-bit arithmetic overflow values are rejected"
}

test_healthcheck_cron_preserves_custom_deploy_flags() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    HEALTHCHECK_CRON_PATH="${local_tmp}/derper-healthcheck"
    IP_ADDR="203.0.113.10"
    DERP_PORT="443"
    STUN_PORT="40000"
    VERIFY_CLIENTS_MODE="off"
    SECURITY_LEVEL="paranoid"
    METRICS_TEXTFILE="${local_tmp}/derper.prom"
    SCRIPT_SELF="${local_tmp}/deploy_derper_ip_selfsigned.sh"
    printf '#!/bin/bash\n' >"$SCRIPT_SELF"
    command() {
      if [[ "$1" == -v && "$2" == systemctl ]]; then return 1; fi
      builtin command "$@"
    }
    install_healthcheck_cron || fail "cron install should succeed"
    grep -q -- '--derp-port 443' "$HEALTHCHECK_CRON_PATH" || fail "cron must pin custom DERP port"
    grep -q -- '--stun-port 40000' "$HEALTHCHECK_CRON_PATH" || fail "cron must pin custom STUN port"
    grep -q -- '--no-verify-clients' "$HEALTHCHECK_CRON_PATH" || fail "cron must pin --no-verify-clients"
    grep -q -- '--security-level paranoid' "$HEALTHCHECK_CRON_PATH" || fail "cron must pin security level"

    # systemd timer 分支同样保留自定义部署参数
    unset -f command
    systemctl() { return 0; }
    HEALTHCHECK_UNIT_DIR="${local_tmp}/units"
    install_healthcheck_cron || fail "timer install should succeed"
    grep -q -- '--derp-port 443' "${HEALTHCHECK_UNIT_DIR}/derper-healthcheck.service" || fail "timer service must pin custom DERP port"
    grep -q -- '--stun-port 40000' "${HEALTHCHECK_UNIT_DIR}/derper-healthcheck.service" || fail "timer service must pin custom STUN port"
    grep -q -- '--no-verify-clients' "${HEALTHCHECK_UNIT_DIR}/derper-healthcheck.service" || fail "timer service must pin --no-verify-clients"
    grep -q -- '--security-level paranoid' "${HEALTHCHECK_UNIT_DIR}/derper-healthcheck.service" || fail "timer service must pin security level"
  )
  ok "healthcheck cron and timer preserve custom ports and security flags"
}

test_healthcheck_infers_settings_from_unit() {
  DERPER_TEST_MODE=1 source "$SCRIPT"
  DERP_PORT="30399"
  STUN_PORT="3478"
  VERIFY_CLIENTS_MODE="on"
  SECURITY_LEVEL="standard"
  DERP_PORT_EXPLICIT=0
  STUN_PORT_EXPLICIT=0
  VERIFY_CLIENTS_EXPLICIT=0
  SECURITY_LEVEL_EXPLICIT=0
  local unit
  unit="ExecStart=/usr/local/bin/derper -a :443 -stun-port 40000 -hostname 8.8.8.8"$'\n'"# 安全加固（级别：basic）"
  infer_healthcheck_settings_from_unit "$unit"
  [[ "$DERP_PORT" == "443" ]] || fail "must infer DERP port 443, got $DERP_PORT"
  [[ "$STUN_PORT" == "40000" ]] || fail "must infer STUN port 40000, got $STUN_PORT"
  [[ "$VERIFY_CLIENTS_MODE" == "off" ]] || fail "unit without -verify-clients must infer off, got $VERIFY_CLIENTS_MODE"
  [[ "$SECURITY_LEVEL" == "basic" ]] || fail "must infer security level basic, got $SECURITY_LEVEL"
  DERP_PORT_EXPLICIT=1 DERP_PORT="30399"
  infer_healthcheck_settings_from_unit "$unit"
  [[ "$DERP_PORT" == "30399" ]] || fail "explicit --derp-port must not be overwritten"
  ok "health-check infers custom ports, verify-clients, and security level from unit"
}

test_tls_connlimit_nft_uses_script_owned_table() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    TLS_CONNLIMIT=32
    DERP_PORT=30399
    local cmds=""
    command() {
      if [[ "$1" == -v && "$2" == nft ]]; then return 0; fi
      if [[ "$1" == -v && "$2" == iptables ]]; then return 1; fi
      builtin command "$@"
    }
    nft() { cmds+="$*"$'\n'; return 0; }
    apply_tls_connlimit || fail "nft connlimit should apply"
    echo "$cmds" | grep -q 'derper_tls_connlimit' || fail "must use script-owned table, commands: $cmds"
    if echo "$cmds" | grep -qE 'flush chain inet derper[[:space:]]'; then
      fail "must not flush generic inet derper chain, commands: $cmds"
    fi
    cmds=""
    remove_tls_connlimit || fail "nft remove should succeed"
    echo "$cmds" | grep -q 'delete table inet derper_tls_connlimit' || fail "remove must delete script-owned table, commands: $cmds"
    if echo "$cmds" | grep -qE 'delete table inet derper$'; then
      fail "must not delete generic inet derper table, commands: $cmds"
    fi
  )
  ok "nft connlimit uses a script-owned table"
}

test_readme_documents_missing_flags_and_runnable_examples() {
  grep -q -- '--cert-days' "$ROOT_DIR/README.md" || fail "README must document --cert-days"
  grep -q -- '--derper-version' "$ROOT_DIR/README.md" || fail "README must document --derper-version"
  if bash "$SCRIPT" --help | grep -q -- '--ip 203.0.113.10'; then
    fail "help examples must not use TEST-NET-3 as a deploy IP"
  fi
  if awk '/Complete Example: Zero to Production/,/^#### Output Example/' "$ROOT_DIR/README.md" | grep -q -- '--ip 203.0.113.10'; then
    fail "EN formal deploy example must not use TEST-NET-3 as --ip"
  fi
  if awk '/完整示例：从零到可用/,/^#### 输出示例/' "$ROOT_DIR/README.md" | grep -q -- '--ip 203.0.113.10'; then
    fail "CN formal deploy example must not use TEST-NET-3 as --ip"
  fi
  grep -q -- '--install-healthcheck-cron' "$ROOT_DIR/README.md" || fail "scenario table should use --install-healthcheck-cron"
  if awk '/Typical Application Scenarios/,/^### ⚠️/' "$ROOT_DIR/README.md" | grep -q -- '`--dedicated-user --health-check`'; then
    fail "EN scenario table must not treat --health-check as a deploy combo"
  fi
  if awk '/典型应用场景对比/,/^### ⚠️/' "$ROOT_DIR/README.md" | grep -q -- '`--dedicated-user --health-check`'; then
    fail "CN scenario table must not treat --health-check as a deploy combo"
  fi
  [[ -f "$ROOT_DIR/CHANGELOG_CN.md" ]] || fail "Chinese changelog must exist at repository root"
  [[ -f "$ROOT_DIR/CHANGELOG_EN.md" ]] || fail "English changelog must exist at repository root"
  if grep -q 'docs/BUGFIX_REVIEW_20260920.md' "$ROOT_DIR/README.md" \
       "$ROOT_DIR/CHANGELOG_CN.md" "$ROOT_DIR/CHANGELOG_EN.md"; then
    fail "docs must not link to missing docs/BUGFIX_REVIEW_20260920.md"
  fi
  grep -q '1–365000' "$ROOT_DIR/docs/REFERENCE_CN.md" || fail "REFERENCE_CN must document --cert-days range"
  grep -q '1–365000' "$ROOT_DIR/docs/REFERENCE_EN.md" || fail "REFERENCE_EN must document --cert-days range"
  bash "$SCRIPT" --help | grep -q '1–365000' || fail "usage must document --cert-days range"
  ok "README documents flags and uses runnable public-IP examples"
}

test_unit_atomic_write_refuses_symlink() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    local dest="${local_tmp}/derper.service" target="${local_tmp}/target"
    printf 'old\n' >"$target"
    ln -s "$target" "$dest"
    if printf '[Service]\n' | atomic_install_file "$dest" 2>/dev/null; then
      fail "atomic_install_file must refuse symlink dest"
    fi
    [[ "$(cat "$target")" == "old" ]] || fail "symlink target must not be overwritten"
    rm -f "$dest"
    printf '[Unit]\nDescription=ok\n' | atomic_install_file "$dest" || fail "atomic write of regular file should succeed"
    [[ -f "$dest" && ! -L "$dest" ]] || fail "dest should be a regular file"
    grep -q 'Description=ok' "$dest" || fail "unit content missing"
  )
  ok "systemd unit writes are atomic and refuse symlinks"
}

test_sha256_hex_rejects_empty_input() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    if printf '' | sha256_hex >/dev/null 2>&1; then
      fail "empty input hash must not be treated as a fingerprint"
    fi
    local out
    out=$(printf 'derper\n' | sha256_hex) || fail "non-empty input should hash"
    [[ "$out" != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]] || fail "non-empty hash collided with empty"
  )
  ok "sha256_hex rejects empty-input digest"
}

test_install_healthcheck_cron_rejects_missing_script() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    HEALTHCHECK_CRON_PATH="${local_tmp}/derper-healthcheck"
    IP_ADDR="203.0.113.10"
    SCRIPT_SELF="${local_tmp}/not-here.sh"
    if install_healthcheck_cron >/dev/null 2>&1; then
      fail "cron install must refuse missing script path"
    fi
    [[ ! -e "$HEALTHCHECK_CRON_PATH" ]] || fail "cron file must not be written when script is missing"
  )
  ok "healthcheck cron refuses missing script path"
}

test_resolve_run_user_survives_unreadable_unit() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    set -euo pipefail
    trap 'fail "unreadable unit aborted under set -e (status=$?)"' ERR
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    SERVICE_PATH="${local_tmp}/derper.service"
    printf '[Service]\nUser=derper\n' >"$SERVICE_PATH"
    RUN_USER_EXPLICIT=0
    RUN_USER=root
    NON_INTERACTIVE=0
    unset SUDO_USER
    id() { echo 1; }
    # 普通语句 + ERR trap：条件上下文会关掉 errexit，删掉 || true 仍假绿。
    cat() { return 1; }
    read_derper_unit_content >/dev/null
    unset -f cat
    read_derper_unit_content() { return 1; }
    resolve_run_user
    [[ "$RUN_USER" == root ]] || fail "unreadable unit must not abort resolve_run_user"
  )
  ok "resolve_run_user survives unreadable unit content"
}

test_commit_cert_update_clears_active_transaction() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    SERVICE_PATH="${local_tmp}/derper.service"
    INSTALL_DIR="${local_tmp}/install"
    mkdir -p "${INSTALL_DIR}/certs"
    printf old >"${INSTALL_DIR}/certs/cert"
    printf unit >"$SERVICE_PATH"
    systemctl() { return 1; }
    begin_cert_update || fail "begin should succeed"
    [[ "${CERT_TRANSACTION_ACTIVE}" -eq 1 ]] || fail "transaction should be active"
    [[ -d "${SERVICE_PATH}.certs-rollback" ]] || fail "backup dir missing"
    commit_cert_update || fail "commit should succeed"
    [[ "${CERT_TRANSACTION_ACTIVE}" -eq 0 ]] || fail "commit must clear CERT_TRANSACTION_ACTIVE"
    [[ ! -e "${SERVICE_PATH}.certs-rollback" ]] || fail "commit must remove backup"
    cleanup_deployment 1
    [[ "$(cat "${INSTALL_DIR}/certs/cert")" == old ]] || fail "inactive transaction must not rollback certs"
  )
  ok "commit_cert_update clears the rollback transaction"
}

test_run_post_deploy_extras_keeps_verified_deploy() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    apply_tls_connlimit() { return 1; }
    INSTALL_HEALTHCHECK_CRON=0
    local out="" rc=0
    out=$(run_post_deploy_extras 2>&1) || rc=$?
    [[ "$rc" -ne 0 ]] || fail "extras failure should return 1"
    echo "$out" | grep -q '不会回滚' || fail "must say it will not rollback, got: $out"
  )
  ok "post-deploy extras failure does not imply cert rollback"
}

test_service_verified_skips_missing_probe_tools() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    DERP_PORT=30399
    STUN_PORT=3478
    IP_ADDR=203.0.113.10
    command() {
      if [[ "$1" == -v && ( "$2" == ss || "$2" == netstat || "$2" == openssl ) ]]; then return 1; fi
      if [[ "$1" == -v && "$2" == systemctl ]]; then return 0; fi
      builtin command "$@"
    }
    systemctl() {
      case "$1" in
        is-active) return 0 ;;
        show) echo 1 ;;
        *) return 1 ;;
      esac
    }
    kill() { return 0; }
    service_verified_running || fail "active service must verify when ss/openssl are missing"
  )
  ok "service verification skips missing ss/openssl instead of failing"
}

test_timeout_run_fallback_does_not_block_command_substitution() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    command() {
      if [[ "$1" == -v && "$2" == timeout ]]; then return 1; fi
      builtin command "$@"
    }
    local start end elapsed out
    if command -v python3 >/dev/null 2>&1; then
      start=$(python3 -c 'import time; print(int(time.time()*1000))')
    else
      start=$(($(date +%s) * 1000))
    fi
    out=$(_timeout_run 4 echo ok) || fail "fast command should succeed without timeout(1)"
    [[ "$out" == ok ]] || fail "command substitution should capture output, got: ${out}"
    if command -v python3 >/dev/null 2>&1; then
      end=$(python3 -c 'import time; print(int(time.time()*1000))')
    else
      end=$(($(date +%s) * 1000))
    fi
    elapsed=$((end - start))
    [[ "$elapsed" -lt 2000 ]] || fail "fast command in \$() must not wait full timeout, elapsed=${elapsed}ms"
  )
  ok "_timeout_run fallback does not block command substitution for the full timeout"
}

test_main_commits_certs_before_post_deploy_extras() {
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /run_post_deploy_extras[[:space:]]*\(/ { next }
    /run_post_deploy_extras/ {
      if (prev !~ /commit_cert_update/) {
        print "run_post_deploy_extras without preceding commit_cert_update at line " NR > "/dev/stderr"
        bad = 1
      }
    }
    { prev = $0 }
    END { exit bad + 0 }
  ' "$SCRIPT" || fail "every run_post_deploy_extras call must immediately follow commit_cert_update"
  ok "main commits certs before post-deploy extras"
}

test_wizard_read_choice_rejects_invalid() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local out rc=0
    out=$(printf 'z\n' | wizard_read_choice "prompt: " "ab" 2>&1) || rc=$?
    [[ "$rc" -ne 0 ]] || fail "invalid then EOF should fail"
    echo "$out" | grep -q '无效选项' || fail "must report invalid option, got: $out"
  )
  ok "wizard choice prompt rejects invalid input"
}

test_sudo_user_validation_and_fallback() {
  (
    export SUDO_USER="deploy_admin-01"
    export USER="fallback_user"
    DERPER_TEST_MODE=1 source "$SCRIPT"
    [[ "$RUN_USER" == "deploy_admin-01" ]] || fail "valid SUDO_USER should be used as RUN_USER, got: $RUN_USER"
  )
  (
    export SUDO_USER="bad;user"
    export USER="safe_user"
    local warn_out
    warn_out=$(DERPER_TEST_MODE=1 source "$SCRIPT" 2>&1 >/dev/null)
    echo "$warn_out" | grep -q 'SUDO_USER 包含非法字符' || fail "invalid SUDO_USER must emit warning, got: $warn_out"
    DERPER_TEST_MODE=1 source "$SCRIPT" 2>/dev/null
    [[ "$RUN_USER" == "safe_user" ]] || fail "invalid SUDO_USER must fall back to USER, got: $RUN_USER"
  )
  ok "SUDO_USER validation accepts POSIX names and rejects injection characters"
}

test_help_and_unknown_or_missing_value_args() {
  (
    local help_out rc=0
    help_out=$(bash "$SCRIPT" --help 2>&1) || rc=$?
    [[ "$rc" -eq 0 ]] || fail "--help should exit 0"
    echo "$help_out" | grep -q '用法：' || fail "--help should print usage"
    help_out=$(bash "$SCRIPT" -h 2>&1) || rc=$?
    [[ "$rc" -eq 0 ]] || fail "-h should exit 0"

    rc=0
    help_out=$(bash "$SCRIPT" --unknown-flag-xyz 2>&1) || rc=$?
    [[ "$rc" -ne 0 ]] || fail "unknown flag should exit non-zero"
    echo "$help_out" | grep -q '未知参数' || fail "unknown flag should report 未知参数"

    DERPER_TEST_MODE=1 source "$SCRIPT"
    local opt
    for opt in --ip --derp-port --stun-port --cert-days --goproxy --gosumdb --gotoolchain \
               --region-id --region-code --region-name --user --security-level \
               --tls-connlimit --derper-version --metrics-textfile; do
      rc=0
      ( parse_args "$opt" >/dev/null 2>&1 ) || rc=$?
      [[ "$rc" -ne 0 ]] || fail "$opt without value must fail"
      rc=0
      ( parse_args "$opt" --force >/dev/null 2>&1 ) || rc=$?
      [[ "$rc" -ne 0 ]] || fail "$opt followed by another flag must fail"
    done

    parse_args --ip 8.8.8.8 --derp-port 8443 --stun-port 3479 --cert-days 90 --auto-ufw \
      --goproxy https://goproxy.cn,direct --gosumdb sum.golang.google.cn --gotoolchain local \
      --no-verify-clients --force-verify-clients --region-id 901 --region-code hk-derp \
      --region-name "HK DERP" --accept-cert-rotation --dedicated-user --allow-non-global-ip \
      --security-level paranoid --relax-socket-perms --yes --derper-version v1.80.0 \
      --uninstall --purge-all
    [[ "$IP_ADDR" == "8.8.8.8" && "$DERP_PORT" == "8443" && "$DERP_PORT_EXPLICIT" -eq 1 ]] || fail "derp-port parse failed"
    [[ "$STUN_PORT" == "3479" && "$STUN_PORT_EXPLICIT" -eq 1 && "$CERT_DAYS" == "90" ]] || fail "stun/cert-days parse failed"
    [[ "$AUTO_UFW" -eq 1 && "$GOPROXY_ARG" == "https://goproxy.cn,direct" ]] || fail "ufw/goproxy parse failed"
    [[ "$GOSUMDB_ARG" == "sum.golang.google.cn" && "$GOTOOLCHAIN_ARG" == "local" ]] || fail "gosumdb/gotoolchain parse failed"
    [[ "$VERIFY_CLIENTS_MODE" == "on" && "$VERIFY_CLIENTS_EXPLICIT" -eq 1 ]] || fail "verify-clients parse failed"
    [[ "$REGION_ID" == "901" && "$REGION_CODE" == "hk-derp" && "$REGION_NAME" == "HK DERP" ]] || fail "region parse failed"
    [[ "$ACCEPT_CERT_ROTATION" -eq 1 && "$CREATE_DEDICATED_USER" -eq 1 && "$RUN_USER" == "derper" ]] || fail "dedicated-user parse failed"
    [[ "$ALLOW_NON_GLOBAL_IP" -eq 1 && "$SECURITY_LEVEL" == "paranoid" && "$RELAX_SOCKET_PERMS" -eq 1 ]] || fail "security flags parse failed"
    [[ "$NON_INTERACTIVE" -eq 1 && "$DERPER_VERSION" == "v1.80.0" ]] || fail "non-interactive/derper-version parse failed"
    [[ "$UNINSTALL" -eq 1 && "$PURGE_ALL" -eq 1 && "$PURGE" -eq 1 ]] || fail "--purge-all must set both PURGE_ALL and PURGE"

    UNINSTALL=0 PURGE=0 PURGE_ALL=1
    if validate_arg_combos 2>/dev/null; then fail "--purge-all without --uninstall must fail"; fi
    PURGE_ALL=0 INSTALL_HEALTHCHECK_CRON=1 DRY_RUN=1
    if validate_arg_combos 2>/dev/null; then fail "--install-healthcheck-cron with --dry-run must fail"; fi
  )
  ok "help, unknown flags, missing option values, and full option parsing work as expected"
}

test_require_root_and_check_os_environment() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    id() { echo 1000; }
    local out rc=0
    out=$(require_root 2>&1) || rc=$?
    [[ "$rc" -ne 0 && "$out" == *"需要 root 权限"* ]] || fail "non-root must be rejected by require_root"
    id() { echo 0; }
    require_root || fail "root should pass require_root"

    # 若宿主机无 /proc/version（如 macOS），通过 uname 与环境变量即可覆盖所有分支
    if [[ ! -f /proc/version ]]; then
      uname() { echo "Darwin"; }
      rc=0
      out=$(check_os_environment 2>&1) || rc=$?
      [[ "$rc" -ne 0 && "$out" == *"不支持的操作系统：macOS"* ]] || fail "macOS must be blocked"

      uname() { echo "Linux"; }
      WSL_DISTRO_NAME="Ubuntu"
      uname() { echo "Unknown"; }
      rc=0
      out=$(check_os_environment 2>&1) || rc=$?
      [[ "$rc" -ne 0 && "$out" == *"不支持的运行环境：WSL"* ]] || fail "WSL must be blocked"
      unset WSL_DISTRO_NAME

      uname() { echo "FreeBSD"; }
      rc=0
      out=$(check_os_environment 2>&1) || rc=$?
      [[ "$rc" -ne 0 && "$out" == *"不支持的操作系统"* ]] || fail "unknown OS must be blocked"

      uname() { echo "Linux"; }
      command() {
        if [[ "$1" == -v && "$2" == systemctl ]]; then return 1; fi
        builtin command "$@"
      }
      out=$(check_os_environment 2>&1) || fail "Linux without systemctl should pass with warning"
      [[ "$out" == *"未检测到 systemd"* && "$out" == *"环境检测通过：Linux 系统"* ]] ||
        fail "Linux check should warn about missing systemd and succeed"
    fi
  )
  ok "require_root and check_os_environment enforce root and Linux requirements"
}

test_precheck_verify_clients_all_branches() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    VERIFY_CLIENTS_MODE="off"
    local out rc=0
    out=$(precheck_verify_clients 2>&1) || fail "verify-clients off should return 0"
    [[ "$out" == *"--no-verify-clients"* ]] || fail "verify-clients off should warn"

    VERIFY_CLIENTS_MODE="on"
    pgrep() { return 1; }
    # 分支：tailscaled 未运行 + 有 systemctl -> exit 2
    command() {
      if [[ "$1" == -v && "$2" == systemctl ]]; then return 0; fi
      builtin command "$@"
    }
    systemctl() { return 1; }
    if [[ ! -S /run/tailscale/tailscaled.sock && ! -S /var/run/tailscale/tailscaled.sock ]]; then
      rc=0
      out=$(precheck_verify_clients 2>&1) || rc=$?
      [[ "$rc" -eq 2 && "$out" == *"systemctl enable --now tailscaled"* ]] ||
        fail "inactive tailscaled with systemctl must exit 2, rc=$rc"

      # 分支：tailscaled 未运行 + 无 systemctl -> exit 2
      command() {
        if [[ "$1" == -v && "$2" == systemctl ]]; then return 1; fi
        builtin command "$@"
      }
      rc=0
      out=$(precheck_verify_clients 2>&1) || rc=$?
      [[ "$rc" -eq 2 && "$out" == *"OpenRC/Alpine"* ]] ||
        fail "inactive tailscaled without systemctl must exit 2 with OpenRC hint, rc=$rc"
    fi

    # 分支：tailscaled 运行中，但未登录（tailscale ip -4 为空）-> exit 2
    pgrep() { return 0; }
    command() {
      if [[ "$1" == -v && "$2" == tailscale ]]; then return 0; fi
      builtin command "$@"
    }
    tailscale() { echo ""; }
    rc=0
    out=$(precheck_verify_clients 2>&1) || rc=$?
    [[ "$rc" -eq 2 && "$out" == *"未检测到已登录的 Tailnet IP"* ]] ||
      fail "unauthenticated tailscaled must exit 2, rc=$rc"

    # 分支：tailscaled 运行中且已登录 -> return 0
    tailscale() { echo "100.64.0.42"; }
    out=$(precheck_verify_clients 2>&1) || fail "logged-in tailscaled should pass"
    [[ "$out" == *"100.64.0.42"* ]] || fail "logged-in message should include Tailnet IP"

    # 分支：tailscaled 运行中但无 tailscale CLI -> return 0
    command() {
      if [[ "$1" == -v && "$2" == tailscale ]]; then return 1; fi
      builtin command "$@"
    }
    out=$(precheck_verify_clients 2>&1) || fail "missing tailscale CLI with active daemon should pass"
    [[ "$out" == *"未找到 tailscale CLI"* ]] || fail "should mention missing tailscale CLI"
  )
  ok "precheck_verify_clients covers off, inactive, logged-out, logged-in, and no-CLI branches"
}

test_ipv4_address_class_and_validate_settings_edge_cases() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    [[ "$(ipv4_address_class "0.0.0.1")" == *"保留（0.0.0.0/8）"* ]] || fail "0/8 class failed"
    [[ "$(ipv4_address_class "10.1.2.3")" == *"私有（10.0.0.0/8）"* ]] || fail "10/8 class failed"
    [[ "$(ipv4_address_class "100.64.0.1")" == *"CGNAT"* ]] || fail "100.64/10 class failed"
    [[ "$(ipv4_address_class "127.0.0.1")" == *"回环"* ]] || fail "127/8 class failed"
    [[ "$(ipv4_address_class "169.254.1.1")" == *"链路本地"* ]] || fail "169.254/16 class failed"
    [[ "$(ipv4_address_class "172.16.0.1")" == *"私有（172.16.0.0/12）"* ]] || fail "172.16/12 class failed"
    [[ "$(ipv4_address_class "192.0.0.1")" == *"192.0.0.0/24"* ]] || fail "192.0.0/24 class failed"
    [[ "$(ipv4_address_class "192.0.2.1")" == *"TEST-NET-1"* ]] || fail "192.0.2/24 class failed"
    [[ "$(ipv4_address_class "192.88.99.1")" == *"6to4"* ]] || fail "192.88.99/24 class failed"
    [[ "$(ipv4_address_class "192.168.1.1")" == *"192.168.0.0/16"* ]] || fail "192.168/16 class failed"
    [[ "$(ipv4_address_class "198.18.0.1")" == *"198.18.0.0/15"* ]] || fail "198.18/15 class failed"
    [[ "$(ipv4_address_class "198.51.100.1")" == *"TEST-NET-2"* ]] || fail "198.51.100/24 class failed"
    [[ "$(ipv4_address_class "203.0.113.1")" == *"TEST-NET-3"* ]] || fail "203.0.113/24 class failed"
    [[ "$(ipv4_address_class "224.0.0.1")" == *"组播"* ]] || fail "224/4 class failed"
    [[ "$(ipv4_address_class "240.0.0.1")" == *"240.0.0.0/4"* ]] || fail "240/4 class failed"
    [[ "$(ipv4_address_class "255.255.255.255")" == *"240.0.0.0/4"* || "$(ipv4_address_class "255.255.255.255")" == *"广播"* ]] || fail "255.255.255.255 must be non-global"
    [[ "$(ipv4_address_class "999.1.1.1")" == "invalid" ]] || fail "octet > 255 must be invalid"
    [[ "$(ipv4_address_class "1.2.3")" == "invalid" ]] || fail "short IP must be invalid"
    [[ "$(ipv4_address_class "8.8.8.8")" == "global" ]] || fail "8.8.8.8 must be global"

    RUN_USER="$(id -un)"
    IP_ADDR="08.08.08.08"
    validate_settings >/dev/null 2>&1 || fail "leading-zero octets 08.08.08.08 must parse as decimal"

    IP_ADDR="8.8.8.8"
    REGION_CODE='bad"code'
    validate_settings >/dev/null 2>&1 && fail "region-code with quote must be rejected"
    REGION_CODE="my-derp"

    REGION_NAME='Bad;Name'
    validate_settings >/dev/null 2>&1 && fail "region-name with semicolon must be rejected"
    REGION_NAME="My IP DERP"

    REGION_ID="100"
    local warn_out
    warn_out=$(validate_settings 2>&1) || fail "region-id 100 should pass with warning"
    [[ "$warn_out" == *"900-999"* ]] || fail "region-id outside 900-999 should emit warning"
    REGION_ID="900"

    SECURITY_LEVEL="ultra"
    validate_settings >/dev/null 2>&1 && fail "invalid security-level must be rejected"
    SECURITY_LEVEL="standard"

    DERP_PORT="0"
    validate_settings >/dev/null 2>&1 && fail "port 0 must be rejected"
    DERP_PORT="65536"
    validate_settings >/dev/null 2>&1 && fail "port 65536 must be rejected"
    DERP_PORT="30399"

    CERT_DAYS="0"
    if validate_settings >/dev/null 2>&1; then fail "cert-days 0 must be rejected"; fi
    CERT_DAYS="365001"
    if validate_settings >/dev/null 2>&1; then fail "cert-days > 365000 must be rejected"; fi
  )
  ok "ipv4_address_class and validate_settings cover all address classes and parameter boundaries"
}

test_detect_public_ip_fallback_chain() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    IP_ADDR=""
    # 第 1 源成功（1.1.1.1/cdn-cgi/trace）
    curl() {
      if [[ "$*" == *"1.1.1.1/cdn-cgi/trace"* ]]; then
        printf 'fl=1\nip=1.2.3.4\n'
        return 0
      fi
      return 1
    }
    dig() { return 1; }
    detect_public_ip >/dev/null
    [[ "$IP_ADDR" == "1.2.3.4" ]] || fail "should detect IP from first source, got: $IP_ADDR"

    # 前面源失败，回退到 api.ipify.org
    IP_ADDR=""
    curl() {
      if [[ "$*" == *"api.ipify.org"* ]]; then
        printf '5.6.7.8\n'
        return 0
      fi
      return 1
    }
    detect_public_ip >/dev/null
    [[ "$IP_ADDR" == "5.6.7.8" ]] || fail "should fall back to ipify, got: $IP_ADDR"

    # 全部探测源失败
    IP_ADDR=""
    curl() { return 1; }
    dig() { return 1; }
    if detect_public_ip >/dev/null 2>&1; then
      fail "detect_public_ip must return 1 when all sources fail"
    fi
  )
  ok "detect_public_ip falls back across probe endpoints and fails when none respond"
}

test_ver_ge_pure_bash_fallback_and_tailscale_status() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    # 屏蔽 sort -V，专门走纯 Bash 版本比较回退分支
    sort() {
      if [[ "${1:-}" == "-V" ]]; then return 1; fi
      command sort "$@"
    }
    ver_ge "1.10.0" "1.9.9" || fail "pure bash ver_ge: 1.10.0 >= 1.9.9 must be true"
    ver_ge "1.66.3" "1.66.3" || fail "pure bash ver_ge: 1.66.3 >= 1.66.3 must be true"
    ver_ge "2.0" "1.99.9" || fail "pure bash ver_ge: 2.0 >= 1.99.9 must be true"
    if ver_ge "1.66.2" "1.66.3"; then
      fail "pure bash ver_ge: 1.66.2 >= 1.66.3 must be false"
    fi

    # 测试 check_tailscale_status（含旧版本升级提示）
    sleep() { :; }
    command() {
      if [[ "$1" == -v && "$2" == tailscale ]]; then return 0; fi
      if [[ "$1" == -v && "$2" == systemctl ]]; then return 0; fi
      builtin command "$@"
    }
    systemctl() { return 0; }
    tailscale() { printf '1.50.0\n  tailscale commit: abcdef1\n'; }
    local out
    check_tailscale_status 2>/dev/null
    [[ "$TS_INSTALLED" -eq 1 && "$TS_RUNNING" -eq 1 && "$TS_VER_OK" -eq 0 ]] ||
      fail "old tailscale should set TS_INSTALLED=1 TS_RUNNING=1 TS_VER_OK=0"
    out=$(check_tailscale_status 2>&1)
    [[ "$out" == *"检测到 Tailscale 版本较旧"* ]] || fail "old tailscale should emit upgrade hint"

    tailscale() { printf '1.80.0\n'; }
    check_tailscale_status 2>/dev/null
    [[ "$TS_VER_OK" -eq 1 && "$TS_VERSION" == "1.80.0" ]] || fail "new tailscale should satisfy version check"
  )
  ok "ver_ge pure-bash fallback and check_tailscale_status work accurately"
}

test_check_pure_ip_ports_ownership_and_cert_days() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local u_new u_old u_bad
    u_new="ExecStart=/usr/local/bin/derper -hostname 8.8.8.8 -certmode manual -certdir /opt/derper/certs -http-port -1 -a :30399 -stun"
    check_pure_ip_from_unit "$u_new"
    [[ "$PURE_IP_OK" -eq 1 ]] || fail "valid -a unit should set PURE_IP_OK=1"

    u_old="ExecStart=/usr/local/bin/derper -hostname 8.8.8.8 -certmode manual -certdir /opt/derper/certs -http-port -1 -https-port 30399 -stun"
    check_pure_ip_from_unit "$u_old"
    [[ "$PURE_IP_OK" -eq 1 ]] || fail "valid -https-port unit should set PURE_IP_OK=1"

    u_bad="ExecStart=/usr/local/bin/derper -hostname example.com -certmode letsencrypt -a :30399 -stun"
    check_pure_ip_from_unit "$u_bad"
    [[ "$PURE_IP_OK" -eq 0 ]] || fail "domain unit must set PURE_IP_OK=0"

    # check_ports_status: ss 分支与 netstat 回退分支
    DERP_PORT="30399" STUN_PORT="3478"
    command() {
      if [[ "$1" == -v && "$2" == ss ]]; then return 1; fi
      if [[ "$1" == -v && "$2" == netstat ]]; then return 0; fi
      builtin command "$@"
    }
    netstat() {
      if [[ "$1" == "-ltnp" ]]; then echo "tcp 0 0 0.0.0.0:30399 0.0.0.0:* LISTEN 999/derper"; fi
      if [[ "$1" == "-lunp" ]]; then echo "udp 0 0 0.0.0.0:3478 0.0.0.0:* 999/derper"; fi
    }
    check_ports_status
    [[ "$PORT_TLS_OK" -eq 1 && "$PORT_STUN_OK" -eq 1 ]] || fail "netstat fallback should detect TLS and STUN listeners"

    # current_derper_owns_ports: MainPID 核对
    CURRENT_DERPER_OWNS_PORTS=0
    command() {
      if [[ "$1" == -v && ( "$2" == systemctl || "$2" == ss ) ]]; then return 0; fi
      builtin command "$@"
    }
    systemctl() {
      if [[ "$1" == "is-active" ]]; then return 0; fi
      if [[ "$1" == "show" ]]; then echo "4321"; return 0; fi
      return 1
    }
    ss() {
      printf 'tcp LISTEN 0 128 *:30399 *:* users:(("derper",pid=4321,fd=3))\nudp UNCONN 0 0 *:3478 *:* users:(("derper",pid=4321,fd=4))\n'
    }
    current_derper_owns_ports || fail "matching MainPID should own ports"
    [[ "$CURRENT_DERPER_OWNS_PORTS" -eq 1 ]] || fail "CURRENT_DERPER_OWNS_PORTS should be 1"

    CURRENT_DERPER_OWNS_PORTS=0
    ss() {
      printf 'tcp LISTEN 0 128 *:30399 *:* users:(("nginx",pid=1111,fd=3))\nudp UNCONN 0 0 *:3478 *:* users:(("unbound",pid=2222,fd=4))\n'
    }
    current_derper_owns_ports && fail "foreign process must not be treated as derper owning ports"

    # cert_days_remaining 实测
    if builtin command -v openssl >/dev/null 2>&1; then
      local_tmp=$(mktemp -d)
      trap 'rm -rf "$local_tmp"' EXIT
      INSTALL_DIR="$local_tmp"
      IP_ADDR="203.0.113.10"
      mkdir -p "${INSTALL_DIR}/certs"
      openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
        -keyout "${INSTALL_DIR}/certs/203.0.113.10.key" \
        -out "${INSTALL_DIR}/certs/203.0.113.10.crt" \
        -days 30 -subj "/CN=203.0.113.10" >/dev/null 2>&1
      local days
      days=$(cert_days_remaining)
      [[ -n "$days" && "$days" -ge 28 && "$days" -le 30 ]] ||
        fail "30-day certificate should report ~29-30 days remaining, got: ${days:-empty}"
    fi
  )
  ok "check_pure_ip_from_unit, check_ports_status, current_derper_owns_ports, and cert_days_remaining work"
}

test_install_deps_and_ensure_go_sha256_verification() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    _tmpdir="$local_tmp"

    # 1) 所有依赖存在时跳过包管理器
    command() {
      if [[ "$1" == -v ]]; then return 0; fi
      builtin command "$@"
    }
    apt() { fail "apt must not run when all deps are present"; }
    install_deps >/dev/null

    # 2) 缺少 nc 与 ss 时通过 apt 按需安装 netcat-openbsd 与 iproute2
    local installed_pkgs=""
    command() {
      if [[ "$1" == -v ]]; then
        case "$2" in
          nc|ss) return 1 ;;
          apt|curl|openssl|git|tar) return 0 ;;
          *) return 1 ;;
        esac
      fi
      builtin command "$@"
    }
    apt() {
      if [[ "$1" == "install" ]]; then
        installed_pkgs="$*"
      fi
      return 0
    }
    install_deps >/dev/null 2>&1
    [[ "$installed_pkgs" == *"netcat-openbsd"* && "$installed_pkgs" == *"iproute2"* ]] ||
      fail "install_deps on apt should install netcat-openbsd and iproute2, got: $installed_pkgs"

    # 3) ensure_go: 不支持的架构报错退出
    go_toolchain_meets_min() { return 1; }
    command() {
      if [[ "$1" == -v && "$2" == go ]]; then return 0; fi
      if [[ "$1" == -v && "$2" == curl ]]; then return 0; fi
      if [[ "$1" == -v && "$2" == sha256sum ]]; then return 0; fi
      builtin command "$@"
    }
    go() { echo "go version go1.18.1 linux/amd64"; }
    uname() { echo "riscv64"; }
    local out rc=0
    out=$(ensure_go 2>&1) || rc=$?
    [[ "$rc" -ne 0 && "$out" == *"未支持的架构"* ]] || fail "unsupported arch must fail ensure_go"

    # 4) ensure_go: SHA256 校验不匹配时必须拒绝并删除损坏包
    uname() { echo "x86_64"; }
    precheck_go_download() { return 0; }
    curl() {
      # 将伪造内容写入 -o 指定的 tarball
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == "-o" ]]; then
          printf 'corrupted-tarball\n' >"$2"
          return 0
        fi
        shift
      done
      return 0
    }
    sha256sum() { echo "0000000000000000000000000000000000000000000000000000000000000000  $1"; }
    rc=0
    out=$(ensure_go 2>&1) || rc=$?
    [[ "$rc" -ne 0 && "$out" == *"SHA256 校验失败"* ]] ||
      fail "mismatched Go tarball SHA256 must abort ensure_go, got rc=$rc out=$out"
    [[ ! -e "${_tmpdir}/go${GO_VERSION}.linux-amd64.tar.gz" ]] ||
      fail "corrupted tarball must be removed after SHA256 failure"
  )
  ok "install_deps and ensure_go SHA256/architecture checks work properly"
}

test_derper_flag_detection_with_exit_code_2() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    BIN_PATH="${local_tmp}/derper"

    # 新版 derper -h：输出含 -a、-stun-port、-socket，并以 exit 2 退出
    cat >"$BIN_PATH" <<'EOF'
#!/usr/bin/env bash
cat >&2 <<'HELP'
Usage of derper:
  -a string
        server address (default ":443")
  -stun-port int
        The UDP port on which to serve STUN. (default 3478)
  -socket string
        path to tailscaled unix socket
HELP
exit 2
EOF
    chmod +x "$BIN_PATH"
    derper_supports_listen_a || fail "should detect -a even when derper -h exits 2"
    derper_supports_stun_port || fail "should detect -stun-port"
    derper_supports_socket_flag || fail "should detect -socket"
    derper_supports_https_port && fail "should not detect -https-port when absent"

    # 旧版 derper -h：仅含 -https-port，无 -a/-stun-port/-socket
    cat >"$BIN_PATH" <<'EOF'
#!/usr/bin/env bash
cat >&2 <<'HELP'
Usage of derper:
  -https-port int
        The port on which to serve HTTPS. (default 443)
HELP
exit 2
EOF
    chmod +x "$BIN_PATH"
    derper_supports_https_port || fail "should detect legacy -https-port"
    if derper_supports_listen_a; then fail "legacy derper should not report -a"; fi
    if derper_supports_stun_port; then fail "legacy derper should not report -stun-port"; fi
    if derper_supports_socket_flag; then fail "legacy derper should not report -socket"; fi
  )
  ok "derper flag detection functions handle exit code 2 under pipefail"
}

test_harden_cert_dir_layout_check_and_finalize_report_fallbacks() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    INSTALL_DIR="${local_tmp}/install"
    SERVICE_PATH="${local_tmp}/derper.service"
    IP_ADDR="203.0.113.10"
    DERP_PORT="30399"
    mkdir -p "$INSTALL_DIR"

    # 1) certs 目录本身为符号链接时，harden_cert_dir 必须拒绝
    mkdir -p "${local_tmp}/real_certs"
    ln -s "${local_tmp}/real_certs" "${INSTALL_DIR}/certs"
    if harden_cert_dir >/dev/null 2>&1; then
      fail "harden_cert_dir must refuse symlinked certs directory"
    fi
    rm -f "${INSTALL_DIR}/certs"

    # 2) journal_certname_raw 解析 journalctl 输出
    command() {
      if [[ "$1" == -v && "$2" == journalctl ]]; then return 0; fi
      builtin command "$@"
    }
    journalctl() {
      printf 'derper[100]: listening on :30399\nderper[100]: cert fingerprint sha256-raw:11223344aabbccdd\n'
    }
    [[ "$(journal_certname_raw)" == "11223344aabbccdd" ]] ||
      fail "journal_certname_raw should extract hex fingerprint from journalctl"

    # 3) finalize_deployment_report 三级回退：live -> journal -> disk
    live_cert_sha256_raw() { echo "livefp1234"; }
    local rep
    rep=$(finalize_deployment_report) || fail "finalize should succeed with live fingerprint"
    [[ "$rep" == *'"CertName": "sha256-raw:livefp1234"'* ]] || fail "should use live fingerprint first"

    live_cert_sha256_raw() { return 1; }
    journal_certname_raw() { echo "journalfp5678"; }
    rep=$(finalize_deployment_report) || fail "finalize should fall back to journal fingerprint"
    [[ "$rep" == *'"CertName": "sha256-raw:journalfp5678"'* ]] || fail "should use journal fingerprint second"

    journal_certname_raw() { return 1; }
    cert_file_sha256_raw() { echo "diskfp9999"; }
    rep=$(finalize_deployment_report) || fail "finalize should fall back to disk cert fingerprint"
    [[ "$rep" == *'"CertName": "sha256-raw:diskfp9999"'* ]] || fail "should use disk fingerprint third"
  )
  ok "harden_cert_dir symlink check, journal_certname_raw, and finalize_deployment_report fallback chain work"
}

test_socket_access_owner_group_and_setup_service_user() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    local sock="${local_tmp}/tailscaled.sock"
    if command -v python3 >/dev/null 2>&1; then
      python3 -c "import socket,os;p=r'''${sock}''';
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);
os.path.exists(p) and os.unlink(p);s.bind(p);os.chmod(p,0o600);s.close()" 2>/dev/null || true
    fi
    if [[ -S "$sock" ]]; then
      # 1) 属主匹配时返回 0
      stat() {
        case "$2" in
          "%a") echo "600" ;;
          "%U") echo "derper" ;;
          "%G") echo "root" ;;
        esac
      }
      user_can_access_socket "derper" "$sock" || fail "socket owner should have access"

      # 2) 属组匹配且组权限 rw（660）且用户在组内时返回 0
      stat() {
        case "$2" in
          "%a") echo "660" ;;
          "%U") echo "root" ;;
          "%G") echo "tailscale" ;;
        esac
      }
      id() {
        if [[ "$1" == "-nG" ]]; then echo "derper tailscale"; return 0; fi
        builtin command id "$@"
      }
      user_can_access_socket "derper" "$sock" || fail "user in socket group with 0660 should have access"

      # 3) 属主/属组均不匹配且 0600，且 runuser/sudo 失败 -> 返回 1
      stat() {
        case "$2" in
          "%a") echo "600" ;;
          "%U") echo "root" ;;
          "%G") echo "root" ;;
        esac
      }
      command() {
        if [[ "$1" == -v && ( "$2" == runuser || "$2" == sudo ) ]]; then return 1; fi
        builtin command "$@"
      }
      user_can_access_socket "derper" "$sock" && fail "0600 root socket must not be accessible to derper"
      unset -f stat id command
    fi

    # 4) setup_service_user：新用户创建（首选失败回退 useradd --system）
    INSTALL_DIR="${local_tmp}/install"
    mkdir -p "${INSTALL_DIR}/certs"
    RUN_USER="derper_new"
    local user_created=0 useradd_calls=0
    id() {
      if [[ "${1:-}" == "derper_new" || "${2:-}" == "derper_new" || "${3:-}" == "derper_new" ]]; then
        [[ "$user_created" -eq 1 ]] && { echo "derper_new"; return 0; } || return 1
      fi
      builtin command id "$@"
    }
    getent() { return 1; }
    groupadd() { return 0; }
    useradd() {
      useradd_calls=$((useradd_calls + 1))
      if [[ "$useradd_calls" -eq 1 ]]; then
        return 1  # 模拟第一次 useradd -r -M 失败，触发 --system 回退
      fi
      user_created=1
      return 0
    }
    chown() { return 0; }
    harden_cert_dir() { return 0; }
    setup_service_user >/dev/null
    [[ "$user_created" -eq 1 && "$useradd_calls" -eq 2 ]] ||
      fail "setup_service_user should create user via fallback useradd --system"

    # 5) setup_service_user：useradd 全部失败时退出 1
    user_created=0
    useradd() { return 1; }
    if ( setup_service_user >/dev/null 2>&1 ); then
      fail "setup_service_user must exit non-zero when useradd completely fails"
    fi
  )
  ok "user_can_access_socket and setup_service_user cover owner/group/fallback/failure paths"
}

test_write_systemd_service_branches_paranoid_fallback_and_rollback() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    INSTALL_DIR="${local_tmp}/install"
    SERVICE_PATH="${local_tmp}/derper.service"
    BIN_PATH="/usr/local/bin/derper"
    IP_ADDR="203.0.113.10"
    DERP_PORT="30399"
    STUN_PORT="3478"
    RUN_USER="$(id -un)"
    VERIFY_CLIENTS_MODE="off"
    SECURITY_LEVEL="basic"
    mkdir -p "$INSTALL_DIR"
    setup_service_user() { return 0; }

    # 1) 旧版 derper：无 -a、有 -https-port 时生成 -https-port
    derper_supports_stun_port() { return 1; }
    derper_supports_listen_a() { return 1; }
    derper_supports_https_port() { return 0; }
    service_verified_running() { return 0; }
    systemctl() { return 0; }
    write_systemd_service >/dev/null
    grep -qF -- "-https-port 30399" "$SERVICE_PATH" || fail "legacy derper should use -https-port 30399"

    # 2) 无 systemctl 环境：阻断并打印手动前台运行命令
    command() {
      if [[ "$1" == -v && "$2" == systemctl ]]; then return 1; fi
      builtin command "$@"
    }
    local out rc=0
    out=$(write_systemd_service 2>&1) || rc=$?
    [[ "$rc" -ne 0 && "$out" == *"未检测到 systemd"* && "$out" == *"手动前台运行 derper"* ]] ||
      fail "missing systemctl must block write_systemd_service and print manual command"
    unset -f command

    # 3) paranoid 首次启动验证失败 -> 自动降级禁用 MemoryDenyWriteExecute 并重试成功
    SECURITY_LEVEL="paranoid"
    derper_supports_listen_a() { return 0; }
    derper_supports_stun_port() { return 0; }
    local verify_attempt=0
    service_verified_running() {
      verify_attempt=$((verify_attempt + 1))
      [[ "$verify_attempt" -ge 2 ]]
    }
    write_systemd_service >/dev/null 2>&1
    grep -qF "# 安全加固（级别：paranoid；已禁用 MemoryDenyWriteExecute）" "$SERVICE_PATH" ||
      fail "paranoid fallback must mark unit with degraded comment"
    ! grep -qE '^MemoryDenyWriteExecute=' "$SERVICE_PATH" ||
      fail "paranoid fallback must remove MemoryDenyWriteExecute directive"

    # 4) 启动失败回滚：恢复旧备份 unit 并重启验证旧服务
    SECURITY_LEVEL="standard"
    printf '[Service]\nExecStart=/usr/local/bin/derper -hostname 203.0.113.10 -a :30399 -stun-port 3478\n' >"$SERVICE_PATH"
    service_verified_running() { return 1; }
    local restored_verified=0
    verify_restored_service() { restored_verified=1; return 0; }
    systemctl() { return 0; }
    rc=0
    out=$(write_systemd_service 2>&1) || rc=$?
    [[ "$rc" -ne 0 ]] || fail "failed service start must exit non-zero"
    grep -qF "ExecStart=/usr/local/bin/derper -hostname 203.0.113.10 -a :30399 -stun-port 3478" "$SERVICE_PATH" ||
      fail "failed service start must restore the backed-up unit file"
  )
  ok "write_systemd_service covers -https-port, no-systemd, paranoid degradation, and unit rollback"
}

test_legacy_nft_rule_cleanup_firewall_tips_and_runtime_checks() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    DERP_PORT="30399"
    STUN_PORT="3478"
    IP_ADDR="8.8.8.8"

    # 1) remove_legacy_nft_derper_connlimit_rules 仅按 handle 删除 derper-tls-connlimit 规则
    local nft_deleted=""
    nft() {
      if [[ "$1" == "-a" && "$2" == "list" ]]; then
        cat <<'EOF'
table inet derper {
  chain input {
    tcp dport 22 accept # handle 10
    tcp dport 30399 ct state new comment "derper-tls-connlimit" drop # handle 42
  }
}
EOF
        return 0
      fi
      if [[ "$1" == "delete" && "$2" == "rule" ]]; then
        nft_deleted+="$*"$'\n'
        return 0
      fi
      return 0
    }
    remove_legacy_nft_derper_connlimit_rules
    [[ "$nft_deleted" == *"delete rule inet derper input handle 42"* ]] ||
      fail "must delete legacy nft rule handle 42, got: $nft_deleted"
    [[ "$nft_deleted" != *"handle 10"* ]] ||
      fail "must not delete unrelated handle 10"

    # 2) print_firewall_tips：AUTO_UFW=1 自动执行 ufw allow
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    AUTO_UFW=1
    command() {
      if [[ "$1" == -v && ( "$2" == ufw || "$2" == firewall-cmd ) ]]; then return 0; fi
      builtin command "$@"
    }
    ufw() { printf '%s\n' "$*" >>"${local_tmp}/ufw.log"; return 0; }
    check_extra_attack_surface() { return 0; }
    check_automatic_updates() { return 0; }
    local fw_out ufw_cmds
    fw_out=$(print_firewall_tips 2>&1)
    ufw_cmds=$(cat "${local_tmp}/ufw.log" 2>/dev/null || true)
    [[ "$ufw_cmds" == *"allow 30399/tcp"* && "$ufw_cmds" == *"allow 3478/udp"* ]] ||
      fail "AUTO_UFW=1 should run ufw allow for DERP and STUN ports, got: $ufw_cmds"
    [[ "$fw_out" == *"firewall-cmd --permanent --add-port=30399/tcp"* ]] ||
      fail "firewall-cmd hint should be printed when firewall-cmd is present"

    # 3) runtime_checks：覆盖 ss、openssl 握手、nc 探测与 tailscale debug derp
    command() {
      if [[ "$1" == -v && ( "$2" == ss || "$2" == openssl || "$2" == nc || "$2" == tailscale ) ]]; then return 0; fi
      builtin command "$@"
    }
    ss() { echo "LISTEN 0 128 *:30399 *:*"; }
    _timeout_run() { shift; "$@"; }
    openssl() { return 0; }
    nc() { return 0; }
    tailscale() {
      if [[ "$1" == "debug" && "$2" == "derp" ]]; then
        echo "DERP debug probe ok"
        return 0
      fi
      return 1
    }
    local rt_out
    rt_out=$(runtime_checks 2>&1)
    [[ "$rt_out" == *"TLS 握手成功"* && "$rt_out" == *"DERP debug probe ok"* ]] ||
      fail "runtime_checks should report TLS success and tailscale debug derp output"
  )
  ok "legacy nft handle cleanup, print_firewall_tips, and runtime_checks work"
}

test_health_check_report_expiry_tiers_and_uninstall_purge_modes() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    IP_ADDR="8.8.8.8"
    METRICS_TEXTFILE="${local_tmp}/derper.prom"
    infer_ip_from_existing_deployment() { :; }
    infer_healthcheck_settings_from_unit() { :; }
    validate_settings() { return 0; }
    check_tailscale_status() { :; }
    check_derper_status() {
      DERPER_RUNNING=1 PORT_TLS_OK=1 PORT_STUN_OK=1 PURE_IP_OK=1 DESIRED_CONFIG_OK=1
      DERPER_VERIFY_CLIENTS_EFFECTIVE=1
    }
    check_cert_status() {
      CERT_PRESENT=1 CERT_NAMING_OK=1 CERT_SAN_MATCH=1 CERT_EXPIRY_OK=1
    }
    check_live_cert_status() { LIVE_CERT_CHECKED=1 CERT_LIVE_MATCH=1; }
    check_extra_attack_surface() { EXTRA_LISTENERS=""; }
    check_automatic_updates() { :; }

    # 1) 证书有效期 >= 90 天（正常 ok 档）及 30~89 天（90 天预警档）
    cert_days_remaining() { echo "120"; }
    local h_out
    h_out=$(health_check_report 2>&1)
    [[ "$h_out" == *"✅ 证书：有效期剩余 120 天"* && -f "$METRICS_TEXTFILE" ]] ||
      fail "health_check_report should report >=90 days as ok and write metrics file"

    cert_days_remaining() { echo "45"; }
    h_out=$(health_check_report 2>&1)
    [[ "$h_out" == *"有效期剩余 45 天（90 天预警"* ]] ||
      fail "health_check_report should report 90-day warning tier for 45 days"

    # 2) 证书有效期 7~29 天（30 天预警）与 0~6 天（7 天预警）
    cert_days_remaining() { echo "10"; }
    h_out=$(health_check_report 2>&1)
    [[ "$h_out" == *"有效期剩余 10 天（30 天预警"* ]] || fail "health_check_report should warn when <30 days left"

    cert_days_remaining() { echo "3"; }
    h_out=$(health_check_report 2>&1)
    [[ "$h_out" == *"有效期剩余 3 天（7 天预警"* ]] || fail "health_check_report should warn when <7 days left"

    # 3) 证书已过期（< 0 天）
    cert_days_remaining() { echo "-5"; }
    h_out=$(health_check_report 2>&1)
    [[ "$h_out" == *"已过期"* ]] || fail "health_check_report should flag expired cert"

    # 4) uninstall_derper: --purge 与 --purge-all
    require_root() { :; }
    remove_healthcheck_cron() { :; }
    remove_tls_connlimit() { :; }
    systemctl() { return 0; }
    SERVICE_PATH="${local_tmp}/derper.service"
    INSTALL_DIR="${local_tmp}/install"
    BIN_PATH="${local_tmp}/derper"
    HEALTHCHECK_PROGRAM_DIR="${local_tmp}/health-program"
    mkdir -p "$INSTALL_DIR"
    printf '[Service]\nUser=derper_custom\n' >"$SERVICE_PATH"
    printf '#!/bin/sh\n' >"$BIN_PATH"
    chmod +x "$BIN_PATH"

    UNINSTALL=1 PURGE=1 PURGE_ALL=0
    uninstall_derper >/dev/null 2>&1
    [[ ! -d "$INSTALL_DIR" && -x "$BIN_PATH" ]] ||
      fail "--uninstall --purge must remove INSTALL_DIR but keep BIN_PATH"

    mkdir -p "$INSTALL_DIR"
    printf '[Service]\nUser=derper_custom\n' >"$SERVICE_PATH"
    UNINSTALL=1 PURGE=1 PURGE_ALL=1
    local u_out
    u_out=$(uninstall_derper 2>&1)
    [[ ! -d "$INSTALL_DIR" && ! -e "$BIN_PATH" ]] ||
      fail "--uninstall --purge-all must remove both INSTALL_DIR and BIN_PATH"
    [[ "$u_out" == *"userdel derper_custom"* ]] ||
      fail "--purge-all should suggest userdel for detected non-root service user"
  )
  ok "health_check_report expiry tiers and uninstall --purge/--purge-all work"
}

test_deployment_wizard_full_flow_and_validation() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    cd "$local_tmp"

    # 1) --non-interactive 与 wizard 冲突必须退出 1
    NON_INTERACTIVE=1
    local out rc=0
    out=$(deployment_wizard 2>&1) || rc=$?
    [[ "$rc" -ne 0 && "$out" == *"与 --non-interactive/--yes 冲突"* ]] ||
      fail "wizard must reject NON_INTERACTIVE=1"
    NON_INTERACTIVE=0

    # 2) 完整交互生成命令并保存 derper_deploy_cmd.sh（选 c 生产 / b 专用账户 / a 443 / b 不验证 / a 大陆代理 / n 不立即执行）
    id() { echo 0; }
    out=$(printf 'c\nb\na\nb\na\nn\n' | deployment_wizard 2>&1) || fail "wizard command generation should succeed"
    [[ -x "${local_tmp}/derper_deploy_cmd.sh" ]] || fail "wizard must create executable derper_deploy_cmd.sh"
    local cmd_file
    cmd_file=$(cat "${local_tmp}/derper_deploy_cmd.sh")
    [[ "$cmd_file" == *"--dedicated-user"* && "$cmd_file" == *"--derp-port 443"* ]] ||
      fail "wizard command missing user/port flags: $cmd_file"
    [[ "$cmd_file" == *"--no-verify-clients"* && "$cmd_file" == *"--security-level paranoid"* ]] ||
      fail "wizard command missing verify/security flags: $cmd_file"
    [[ "$cmd_file" == *"--goproxy"* && "$cmd_file" == *"goproxy.cn"* ]] ||
      fail "wizard command missing goproxy flag: $cmd_file"

    # 3) 选择立即执行（y）但输入非法 IP（如 999.1.1.1）时报错退出 1
    rc=0
    out=$(printf 'a\na\nb\na\nb\ny\n999.1.1.1\n' | deployment_wizard 2>&1) || rc=$?
    [[ "$rc" -ne 0 && "$out" == *"超出范围"* ]] ||
      fail "wizard must reject out-of-range IP octets, rc=$rc"

    # 4) 选择立即执行（y）、输入合法 IP、但在最终确认输入 no 时安全取消
    out=$(printf 'a\na\nb\na\nb\ny\n8.8.8.8\nno\n' | deployment_wizard 2>&1) ||
      fail "wizard final confirmation 'no' should cancel cleanly"
    [[ "$out" == *"已取消执行"* ]] || fail "wizard should report cancellation when final confirm is no"
  )
  ok "deployment_wizard covers non-interactive conflict, command generation, IP validation, and cancel"
}

test_main_modes_end_to_end_orchestration() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local_tmp=$(mktemp -d)
    trap 'rm -rf "$local_tmp"' EXIT
    DEPLOY_STATE_DIR="$local_tmp/deploy-state"
    flock() { return 0; }
    check_os_environment() { :; }
    require_root() { :; }
    recover_cert_update() { return 0; }
    check_tailscale_status() { TS_INSTALLED=1 TS_RUNNING=1 TS_VERSION="1.80.0" TS_VER_OK=1; }
    check_derper_status() {
      DERPER_BIN=1 DERPER_SERVICE_PRESENT=1 DERPER_RUNNING=1 PURE_IP_OK=1
      DESIRED_CONFIG_OK=1 DERPER_VERIFY_CLIENTS_EFFECTIVE=1
      PORT_TLS_OK=1 PORT_STUN_OK=1
      TS_LOCALAPI_OK=1 TS_AUTH_UNKNOWN=0
    }
    check_cert_status() {
      CERT_PRESENT=1 CERT_NAMING_OK=1 CERT_SAN_MATCH=1 CERT_EXPIRY_OK=1
    }
    check_live_cert_status() { LIVE_CERT_CHECKED=1 CERT_LIVE_MATCH=1; }
    cert_layout_is_ok() { return 0; }
    check_extra_attack_surface() { EXTRA_LISTENERS=""; }
    check_automatic_updates() { AUTO_UPDATES_OK=1; }

    # 1) main --check：合法参数返回 0；非法参数仍输出总结但返回 1
    local out rc=0
    out=$(main --check --ip 8.8.8.8 2>&1) || rc=$?
    [[ "$rc" -eq 0 && "$out" == *"[检查] 参数与环境状态总结："* && "$out" == *"<已就绪：可直接跳过>"* ]] ||
      fail "main --check with healthy state should return 0 and suggest skip"

    rc=0
    out=$(main --check --ip 8.8.8.8 --derp-port 70000 2>&1) || rc=$?
    [[ "$rc" -ne 0 && "$out" == *"[检查结束]"* ]] ||
      fail "main --check with invalid port must print summary and return non-zero"

    # 2) main --health-check：健康退出 0，不健康退出 1
    cert_days_remaining() { echo "120"; }
    out=$(main --health-check --ip 8.8.8.8 2>&1) || fail "healthy main --health-check must exit 0"
    check_live_cert_status() { LIVE_CERT_CHECKED=1 CERT_LIVE_MATCH=0; }
    rc=0
    out=$(main --health-check --ip 8.8.8.8 2>&1) || rc=$?
    [[ "$rc" -ne 0 ]] || fail "unhealthy main --health-check must exit non-zero"
    check_live_cert_status() { LIVE_CERT_CHECKED=1 CERT_LIVE_MATCH=1; }

    # 3) main 默认幂等模式：一切就绪时直接跳过安装退出 0
    precheck_verify_clients() { return 0; }
    align_derper_version_with_tailscale() { :; }
    derper_binary_needs_install() { return 1; }
    ensure_compatible_certs() { CERTS_CHANGED=0; return 0; }
    commit_cert_update() { return 0; }
    run_post_deploy_extras() { return 0; }
    write_systemd_service() { fail "idempotent ready state must not rewrite systemd service"; }
    out=$(main --ip 8.8.8.8 2>&1) || fail "idempotent main should exit 0 when already healthy"
    [[ "$out" == *"已就绪：检测到 derper 正在以纯 IP 模式运行，跳过安装"* ]] ||
      fail "idempotent main should print ready message"

    # 4) main --repair：执行修复与收尾报告
    local steps=""
    install_deps() { steps+="deps,"; }
    install_derper() { steps+="derper,"; }
    ensure_compatible_certs() { steps+="certs,"; return 0; }
    check_port_conflicts() { steps+="ports,"; }
    write_systemd_service() { steps+="unit,"; }
    print_firewall_tips() { steps+="fw,"; }
    runtime_checks() { steps+="rt,"; }
    commit_cert_update() { steps+="commit,"; return 0; }
    run_post_deploy_extras() { steps+="extras,"; return 0; }
    finalize_deployment_report() { steps+="report"; return 0; }
    (
      main --repair --ip 8.8.8.8 >/dev/null 2>&1
      [[ "$steps" == "deps,certs,ports,unit,fw,rt,commit,extras,report" ]] || exit 1
    ) || fail "main --repair must execute expected pipeline steps in order"

    # 5) main --force：全量重装编排
    steps=""
    generate_selfsigned_cert() { steps+="gencert,"; }
    (
      main --force --ip 8.8.8.8 >/dev/null 2>&1
      [[ "$steps" == "deps,derper,gencert,ports,unit,fw,rt,commit,extras,report" ]] || exit 1
    ) || fail "main --force must execute full reinstall pipeline steps in order"
  )
  ok "main end-to-end orchestration covers --check, --health-check, idempotent, --repair, and --force"
}

test_helper_primitives_cert_resolve_atomic_copy_and_auth_visibility() {
  (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    local tmp py_pid=""
    tmp=$(mktemp -d)
    trap 'if [[ -n "$py_pid" ]]; then kill "$py_pid" 2>/dev/null || true; wait "$py_pid" 2>/dev/null || true; fi; rm -rf "$tmp"' EXIT
    INSTALL_DIR="$tmp/derper"
    mkdir -p "$INSTALL_DIR/certs"
    IP_ADDR="8.8.8.8"

    # 1) derper_manual_cert_basename 过滤非安全字符（与上游 unsafeHostnameCharacters 对齐）
    [[ "$(derper_manual_cert_basename "8.8.8.8:8443/evil")" == "8.8.8.88443evil" ]] ||
      fail "derper_manual_cert_basename must strip unsafe hostname characters"

    # 2) resolve_disk_cert_pem / resolve_disk_key_pem 优先级：上游命名 -> cert.pem/key.pem -> fullchain.pem/privkey.pem
    if resolve_disk_cert_pem >/dev/null 2>&1; then
      fail "resolve_disk_cert_pem must fail when no cert exists"
    fi
    echo "fullchain" >"$INSTALL_DIR/certs/fullchain.pem"
    echo "privkey" >"$INSTALL_DIR/certs/privkey.pem"
    [[ "$(resolve_disk_cert_pem)" == "$INSTALL_DIR/certs/fullchain.pem" ]] ||
      fail "resolve_disk_cert_pem should fall back to fullchain.pem"
    [[ "$(resolve_disk_key_pem)" == "$INSTALL_DIR/certs/privkey.pem" ]] ||
      fail "resolve_disk_key_pem should fall back to privkey.pem"

    echo "cert" >"$INSTALL_DIR/certs/cert.pem"
    echo "key" >"$INSTALL_DIR/certs/key.pem"
    [[ "$(resolve_disk_cert_pem)" == "$INSTALL_DIR/certs/cert.pem" ]] ||
      fail "resolve_disk_cert_pem should prefer cert.pem over fullchain.pem"
    [[ "$(resolve_disk_key_pem)" == "$INSTALL_DIR/certs/key.pem" ]] ||
      fail "resolve_disk_key_pem should prefer key.pem over privkey.pem"

    echo "upstream-crt" >"$INSTALL_DIR/certs/8.8.8.8.crt"
    echo "upstream-key" >"$INSTALL_DIR/certs/8.8.8.8.key"
    [[ "$(resolve_disk_cert_pem)" == "$INSTALL_DIR/certs/8.8.8.8.crt" ]] ||
      fail "resolve_disk_cert_pem should prefer upstream <IP>.crt"
    [[ "$(resolve_disk_key_pem)" == "$INSTALL_DIR/certs/8.8.8.8.key" ]] ||
      fail "resolve_disk_key_pem should prefer upstream <IP>.key"

    # 3) atomic_copy_file：正常复制、源文件不存在失败、目标为符号链接拒绝
    echo "unit-backup" >"$tmp/src.unit"
    atomic_copy_file "$tmp/src.unit" "$tmp/dest.unit" || fail "atomic_copy_file should succeed on regular files"
    [[ "$(cat "$tmp/dest.unit")" == "unit-backup" ]] || fail "atomic_copy_file content mismatch"
    if atomic_copy_file "$tmp/nonexistent.unit" "$tmp/dest.unit" 2>/dev/null; then
      fail "atomic_copy_file must fail when source file does not exist"
    fi
    ln -s "$tmp/src.unit" "$tmp/symlink.unit"
    if atomic_copy_file "$tmp/src.unit" "$tmp/symlink.unit" 2>/dev/null; then
      fail "atomic_copy_file must refuse symlink destination"
    fi

    # 4) note_tailscaled_auth_visibility：区分未开启 verify-clients、tailscaled 未运行、socket 不可读写（unknown）与正常可读（ok）
    DERPER_VERIFY_CLIENTS_EFFECTIVE=0
    TS_RUNNING=1
    note_tailscaled_auth_visibility
    [[ "$TS_AUTH_UNKNOWN" -eq 0 && "$TS_LOCALAPI_OK" -eq 0 ]] ||
      fail "note_tailscaled_auth_visibility should be noop when verify-clients is off"

    DERPER_VERIFY_CLIENTS_EFFECTIVE=1
    TS_RUNNING=0
    note_tailscaled_auth_visibility
    [[ "$TS_AUTH_UNKNOWN" -eq 0 && "$TS_LOCALAPI_OK" -eq 0 ]] ||
      fail "note_tailscaled_auth_visibility should leave unknown=0 when tailscaled is stopped"

    TS_RUNNING=1
    expected_tailscaled_socket() { echo "$tmp/missing.sock"; }
    note_tailscaled_auth_visibility
    [[ "$TS_AUTH_UNKNOWN" -eq 1 && "$TS_LOCALAPI_OK" -eq 0 ]] ||
      fail "note_tailscaled_auth_visibility must mark TS_AUTH_UNKNOWN=1 when socket is missing/unaccessible"

    local probe_sock="$tmp/probe.sock" live_sock="$tmp/live.sock" ready_file="$tmp/live.ready"
    rm -f "$probe_sock" "$live_sock" "$ready_file"
    if command -v python3 >/dev/null 2>&1 \
      && python3 -c 'import socket,sys,os
p=sys.argv[1]
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
os.path.exists(p) and os.unlink(p)
s.bind(p)
s.close()
os.unlink(p)
' "$probe_sock" 2>/dev/null; then
      python3 - "$live_sock" "$ready_file" <<'PY' &
import os, socket, sys, time
# 故意晚于旧的 sleep 0.1，覆盖服务启动慢时的就绪等待。
time.sleep(0.2)
p, ready = sys.argv[1], sys.argv[2]
if os.path.exists(p):
    os.unlink(p)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(p)
s.listen(1)
s.settimeout(5)
with open(ready, "w", encoding="ascii") as handle:
    handle.write("listening\n")
try:
    conn, _ = s.accept()
except socket.timeout:
    s.close()
    sys.exit(0)
conn.settimeout(5)
try:
    conn.recv(1024)
    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}")
finally:
    conn.close()
    s.close()
PY
      py_pid=$!
      local ready=0 waited=0
      while [[ "$waited" -lt 30 ]]; do
        if [[ -s "$ready_file" && -S "$live_sock" ]]; then
          ready=1
          break
        fi
        if ! kill -0 "$py_pid" 2>/dev/null; then
          break
        fi
        sleep 0.1
        waited=$((waited + 1))
      done
      if [[ "$ready" -eq 1 ]]; then
        chmod 666 "$live_sock"
        expected_tailscaled_socket() { echo "$live_sock"; }
        note_tailscaled_auth_visibility
        waited=0
        while kill -0 "$py_pid" 2>/dev/null; do
          sleep 0.1
          waited=$((waited + 1))
          if [[ "$waited" -ge 30 ]]; then
            kill "$py_pid" 2>/dev/null || true
            break
          fi
        done
        wait "$py_pid" 2>/dev/null || true
        py_pid=""
        [[ "$TS_AUTH_UNKNOWN" -eq 0 && "$TS_LOCALAPI_OK" -eq 1 ]] ||
          fail "note_tailscaled_auth_visibility must mark TS_LOCALAPI_OK=1 when LocalAPI responds 200"
      else
        kill "$py_pid" 2>/dev/null || true
        wait "$py_pid" 2>/dev/null || true
        py_pid=""
        fail "LocalAPI test server did not become ready within 3 seconds"
      fi
    else
      echo "# SKIP LocalAPI 200 probe (python3 or Unix socket bind unavailable)"
    fi

    # 5) tls_probe_endpoints：包含 127.0.0.1、localhost 与 IP_ADDR
    local eps
    eps=$(tls_probe_endpoints | tr '\n' ',')
    [[ "$eps" == "127.0.0.1,localhost,8.8.8.8," ]] ||
      fail "tls_probe_endpoints unexpected output: $eps"
  )
  ok "helper primitives (cert resolve, atomic_copy_file, auth visibility, tls_probe_endpoints) work as expected"
}

run_case() {
  ( "$1" )
}

run_case test_no_crlf_and_syntax
run_case test_source_does_not_run_main
run_case test_source_survives_unset_user
run_case test_unit_matching_detects_config_drift
run_case test_unit_matching_rejects_wrong_socket_path
run_case test_validate_settings_rejects_invalid_user
run_case test_port_conflict_ignores_current_derper_service
run_case test_service_reconcile_detects_runtime_failures_and_cert_regen
run_case test_reconcile_detects_stale_live_cert
run_case test_nonempty_config_uses_separate_c_argument
run_case test_unsupported_custom_stun_port_is_rejected
run_case test_empty_derper_config_is_migrated_for_auto_key_generation
run_case test_verify_clients_passes_socket_flag
run_case test_verify_clients_aligns_derper_version
run_case test_ts_commit_parses_real_tailscale_output
run_case test_manual_cert_uses_upstream_filenames
run_case test_cert_fallback_temp_failure_is_handled
run_case test_derper_binary_needs_reinstall_on_version_mismatch
run_case test_paranoid_degraded_unit_is_accepted
run_case test_start_limit_lives_in_unit_section
run_case test_socket_access_skips_when_world_writable
run_case test_health_requires_upstream_cert_naming
run_case test_script_version_is_declared_and_consistent
run_case test_acl_cert_snippet_uses_requested_region_endpoint_and_stun
run_case test_missing_fingerprint_fails_instead_of_insecure_fallback
run_case test_non_global_ips_rejected_unless_explicitly_allowed
run_case test_region_id_safe_integer_range
run_case test_argument_combinations_are_validated
run_case test_cert_generation_refuses_symlinked_paths
run_case test_acl_failure_never_emits_insecure_flag
run_case test_extra_listener_detection_flags_attack_surface
run_case test_automatic_updates_detection_runs
run_case test_server_node_acl_advice_includes_tag
run_case test_go_toolchain_rejects_pre_1_21
run_case test_get_installed_derper_version_ignores_go_toolchain
run_case test_port_conflict_allows_derper_tls_without_stun
run_case test_port_conflict_rejects_foreign_stun
run_case test_ensure_compatible_certs_migrates_legacy_names
run_case test_ssh_session_via_tailscale_detects_cgnat
run_case test_restart_tailscaled_socket_skips_over_tailscale_ssh
run_case test_release_tmpdir_clears_deploy_temp
run_case test_infer_ip_from_existing_unit
run_case test_health_check_skips_external_ip_probe_when_ip_set
run_case test_wizard_handles_eof_cleanly
run_case test_cert_san_matches_literal_ip_only
run_case test_live_certificate_mismatch_fails_health_check
run_case test_metrics_writer_avoids_predictable_tmp_path
run_case test_goproxy_probe_targets_skip_direct
run_case test_precheck_go_network_fails_fast_with_hint
run_case test_precheck_go_network_succeeds_when_reachable
run_case test_get_installed_derper_version_without_strings
run_case test_relax_socket_perms_restored_on_cleanup
run_case test_cleanup_restores_relaxed_socket
run_case test_world_writable_socket_is_warned
run_case test_tls_connlimit_zero_is_noop
run_case test_tls_connlimit_iptables_rule
run_case test_tls_connlimit_removed_on_uninstall
run_case test_install_healthcheck_cron_writes_job
run_case test_uninstall_removes_healthcheck_cron
run_case test_healthcheck_cron_conflicts_with_uninstall
run_case test_tls_connlimit_parse_and_reject
run_case test_module_query_survives_missing_timeout
run_case test_install_derper_survives_missing_timeout
run_case test_healthcheck_cron_conflicts_with_health_check
run_case test_tls_connlimit_conflicts_with_readonly_modes
run_case test_tls_connlimit_explicit_zero_removes_rules
run_case test_install_healthcheck_cron_quotes_paths
run_case test_precheck_go_network_allows_direct_fallback
run_case test_overflow_numeric_args_are_rejected
run_case test_healthcheck_cron_preserves_custom_deploy_flags
run_case test_healthcheck_infers_settings_from_unit
run_case test_tls_connlimit_nft_uses_script_owned_table
run_case test_readme_documents_missing_flags_and_runnable_examples
run_case test_unit_atomic_write_refuses_symlink
run_case test_sha256_hex_rejects_empty_input
run_case test_install_healthcheck_cron_rejects_missing_script
run_case test_resolve_run_user_survives_unreadable_unit
run_case test_commit_cert_update_clears_active_transaction
run_case test_run_post_deploy_extras_keeps_verified_deploy
run_case test_service_verified_skips_missing_probe_tools
run_case test_timeout_run_fallback_does_not_block_command_substitution
run_case test_main_commits_certs_before_post_deploy_extras
run_case test_wizard_read_choice_rejects_invalid
run_case test_sudo_user_validation_and_fallback
run_case test_help_and_unknown_or_missing_value_args
run_case test_require_root_and_check_os_environment
run_case test_precheck_verify_clients_all_branches
run_case test_ipv4_address_class_and_validate_settings_edge_cases
run_case test_detect_public_ip_fallback_chain
run_case test_ver_ge_pure_bash_fallback_and_tailscale_status
run_case test_check_pure_ip_ports_ownership_and_cert_days
run_case test_install_deps_and_ensure_go_sha256_verification
run_case test_derper_flag_detection_with_exit_code_2
run_case test_harden_cert_dir_layout_check_and_finalize_report_fallbacks
run_case test_socket_access_owner_group_and_setup_service_user
run_case test_write_systemd_service_branches_paranoid_fallback_and_rollback
run_case test_legacy_nft_rule_cleanup_firewall_tips_and_runtime_checks
run_case test_health_check_report_expiry_tiers_and_uninstall_purge_modes
run_case test_deployment_wizard_full_flow_and_validation
run_case test_main_modes_end_to_end_orchestration
run_case test_helper_primitives_cert_resolve_atomic_copy_and_auth_visibility
