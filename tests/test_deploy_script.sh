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
  base=$'[Service]\nUser=derper\n# 安全加固（级别：standard）\nExecStart=/usr/local/bin/derper -c /opt/derper/derper.json -hostname 203.0.113.10 -certmode manual -certdir /opt/derper/certs -http-port -1 -a :30399 -stun -stun-port 3478 -verify-clients'
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
  full=$'[Service]\nUser=derper\n# 安全加固（级别：paranoid）\nMemoryDenyWriteExecute=true\nExecStart=/usr/local/bin/derper -c /opt/derper/derper.json -hostname 203.0.113.10 -certmode manual -certdir /opt/derper/certs -http-port -1 -a :30399 -stun -stun-port 3478\n'
  unit_matches_desired_config "$full" || fail "full paranoid unit should match"

  degraded=$'[Service]\nUser=derper\n# 安全加固（级别：paranoid；已禁用 MemoryDenyWriteExecute）\nExecStart=/usr/local/bin/derper -c /opt/derper/derper.json -hostname 203.0.113.10 -certmode manual -certdir /opt/derper/certs -http-port -1 -a :30399 -stun -stun-port 3478\n'
  unit_matches_desired_config "$degraded" || fail "explicitly degraded paranoid unit should match"

  local fake_full
  fake_full=$'[Service]\nUser=derper\n# 安全加固（级别：paranoid）\nExecStart=/usr/local/bin/derper -c /opt/derper/derper.json -hostname 203.0.113.10 -certmode manual -certdir /opt/derper/certs -http-port -1 -a :30399 -stun -stun-port 3478\n'
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
    install_healthcheck_cron || fail "cron install should succeed"
    [[ -f "$HEALTHCHECK_CRON_PATH" ]] || fail "cron file missing"
    grep -q -- '--health-check' "$HEALTHCHECK_CRON_PATH" || fail "cron must call --health-check"
    grep -q -- '--ip 203.0.113.10' "$HEALTHCHECK_CRON_PATH" || fail "cron must pin --ip"
    grep -q -- '--derp-port' "$HEALTHCHECK_CRON_PATH" || fail "cron must pin --derp-port"
    grep -q -- '--stun-port' "$HEALTHCHECK_CRON_PATH" || fail "cron must pin --stun-port"
    grep -q -- '--metrics-textfile' "$HEALTHCHECK_CRON_PATH" || fail "cron must write metrics textfile"
  )
  ok "healthcheck cron file is installed"
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
      printf '#!/bin/sh\n' >"$BIN_PATH"
      chmod +x "$BIN_PATH"
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
    IP_ADDR="203.0.113.10"
    mkdir -p "${local_tmp}/metrics dir"
    METRICS_TEXTFILE="${local_tmp}/metrics dir/derper.prom"
    SCRIPT_SELF="${local_tmp}/deploy derper.sh"
    printf '#!/bin/bash\n' >"$SCRIPT_SELF"
    install_healthcheck_cron || fail "cron install should succeed with spaces in paths"
    local expected_self expected_metrics
    expected_self=$(printf '%q' "$SCRIPT_SELF")
    expected_metrics=$(printf '%q' "$METRICS_TEXTFILE")
    grep -qF -- "$expected_self" "$HEALTHCHECK_CRON_PATH" || fail "script path with spaces must be quoted, cron=$(cat "$HEALTHCHECK_CRON_PATH")"
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
    install_healthcheck_cron || fail "cron install should succeed"
    grep -q -- '--derp-port 443' "$HEALTHCHECK_CRON_PATH" || fail "cron must pin custom DERP port"
    grep -q -- '--stun-port 40000' "$HEALTHCHECK_CRON_PATH" || fail "cron must pin custom STUN port"
    grep -q -- '--no-verify-clients' "$HEALTHCHECK_CRON_PATH" || fail "cron must pin --no-verify-clients"
    grep -q -- '--security-level paranoid' "$HEALTHCHECK_CRON_PATH" || fail "cron must pin security level"
  )
  ok "healthcheck cron preserves custom ports and security flags"
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
  if grep -q 'docs/BUGFIX_REVIEW_20260920.md' "$ROOT_DIR/README.md"; then
    fail "README must not link to missing docs/BUGFIX_REVIEW_20260920.md"
  fi
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
    RUN_USER_EXPLICIT=0
    RUN_USER=root
    NON_INTERACTIVE=0
    unset SUDO_USER
    id() { echo 1; }
    read_derper_unit_content() { return 1; }
    resolve_run_user || fail "unreadable unit must not abort resolve_run_user"
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

test_no_crlf_and_syntax
test_source_does_not_run_main
test_source_survives_unset_user
test_unit_matching_detects_config_drift
test_unit_matching_rejects_wrong_socket_path
test_validate_settings_rejects_invalid_user
test_port_conflict_ignores_current_derper_service
test_service_reconcile_detects_runtime_failures_and_cert_regen
test_reconcile_detects_stale_live_cert
test_nonempty_config_uses_separate_c_argument
test_unsupported_custom_stun_port_is_rejected
test_empty_derper_config_is_migrated_for_auto_key_generation
test_verify_clients_passes_socket_flag
test_verify_clients_aligns_derper_version
test_ts_commit_parses_real_tailscale_output
test_manual_cert_uses_upstream_filenames
test_cert_fallback_temp_failure_is_handled
test_derper_binary_needs_reinstall_on_version_mismatch
test_paranoid_degraded_unit_is_accepted
test_start_limit_lives_in_unit_section
test_socket_access_skips_when_world_writable
test_health_requires_upstream_cert_naming
test_script_version_is_declared_and_consistent
test_acl_cert_snippet_uses_requested_region_endpoint_and_stun
test_missing_fingerprint_fails_instead_of_insecure_fallback
test_non_global_ips_rejected_unless_explicitly_allowed
test_region_id_safe_integer_range
test_argument_combinations_are_validated
test_cert_generation_refuses_symlinked_paths
test_acl_failure_never_emits_insecure_flag
test_extra_listener_detection_flags_attack_surface
test_automatic_updates_detection_runs
test_server_node_acl_advice_includes_tag
test_go_toolchain_rejects_pre_1_21
test_get_installed_derper_version_ignores_go_toolchain
test_port_conflict_allows_derper_tls_without_stun
test_port_conflict_rejects_foreign_stun
test_ensure_compatible_certs_migrates_legacy_names
test_ssh_session_via_tailscale_detects_cgnat
test_restart_tailscaled_socket_skips_over_tailscale_ssh
test_release_tmpdir_clears_deploy_temp
test_infer_ip_from_existing_unit
test_health_check_skips_external_ip_probe_when_ip_set
test_wizard_handles_eof_cleanly
test_cert_san_matches_literal_ip_only
test_live_certificate_mismatch_fails_health_check
test_metrics_writer_avoids_predictable_tmp_path
test_goproxy_probe_targets_skip_direct
test_precheck_go_network_fails_fast_with_hint
test_precheck_go_network_succeeds_when_reachable
test_get_installed_derper_version_without_strings
test_relax_socket_perms_restored_on_cleanup
test_cleanup_restores_relaxed_socket
test_world_writable_socket_is_warned
test_tls_connlimit_zero_is_noop
test_tls_connlimit_iptables_rule
test_tls_connlimit_removed_on_uninstall
test_install_healthcheck_cron_writes_job
test_uninstall_removes_healthcheck_cron
test_healthcheck_cron_conflicts_with_uninstall
test_tls_connlimit_parse_and_reject
test_module_query_survives_missing_timeout
test_install_derper_survives_missing_timeout
test_healthcheck_cron_conflicts_with_health_check
test_tls_connlimit_conflicts_with_readonly_modes
test_tls_connlimit_explicit_zero_removes_rules
test_install_healthcheck_cron_quotes_paths
test_precheck_go_network_allows_direct_fallback
test_overflow_numeric_args_are_rejected
test_healthcheck_cron_preserves_custom_deploy_flags
test_healthcheck_infers_settings_from_unit
test_tls_connlimit_nft_uses_script_owned_table
test_readme_documents_missing_flags_and_runnable_examples
test_unit_atomic_write_refuses_symlink
test_sha256_hex_rejects_empty_input
test_install_healthcheck_cron_rejects_missing_script
test_resolve_run_user_survives_unreadable_unit
test_commit_cert_update_clears_active_transaction
test_run_post_deploy_extras_keeps_verified_deploy
test_service_verified_skips_missing_probe_tools
test_wizard_read_choice_rejects_invalid
