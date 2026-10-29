#!/usr/bin/env bash
# 审查回归：历次审查反例的先红后绿回归与 B 阶段 b1/b2/b3 工作包行为。
# 非 root 可运行（root/工具缺失场景输出 skip，不当通过）；可传测试函数名单独运行。
# 退出码 0=全部通过，1=有失败（累计列出）。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/deploy_derper_ip_selfsigned.sh"
fail() { echo "not ok - $*" >&2; exit 1; }
skip() { echo "skip - $*"; }

use_running_tailscaled() {
  local body="$1"
  printf '#!/bin/sh\n%s\n' "$body" >"$case_tmp/running-tailscaled"
  chmod 755 "$case_tmp/running-tailscaled"
  tailscaled_running_exe() { printf '%s\n' "$case_tmp/running-tailscaled"; }
}

write_recovery_manifest() {
  local dir="$1" intent="$2"
  {
    printf 'binary_sha256=%s\n' "$(file_sha256 "$dir/binary")"
    printf 'unit_sha256=%s\n' "$(recovery_file_digest "$dir/unit")"
    printf 'config_sha256=%s\n' "$(recovery_file_digest "$dir/config")"
    printf 'state_sha256=%s\n' "$(recovery_state_digest "$dir/state")"
    printf 'run_intent=%s\n' "$intent"
  } >"$dir/manifest"
}

test_explicit_user() {
  USER=root; unset SUDO_USER
  id() { echo 0; }
  read_derper_unit_content() { :; }
  NON_INTERACTIVE=1
  parse_args --use-current-user
  resolve_run_user
  [[ "$RUN_USER" == root ]] || fail '显式当前用户被覆盖'
}
test_existing_user() {
  read_derper_unit_content() { printf '[Service]\nUser=derper\n'; }
  resolve_run_user
  [[ "$RUN_USER" == derper ]] || fail '未继承已部署用户'
  parse_args --user custom
  resolve_run_user
  [[ "$RUN_USER" == custom ]] || fail '显式用户被继承值覆盖'
}
test_commit_versions() {
  BIN_PATH=/bin/bash
  DERPER_VERSION=abcdef1234567890abcdef1234567890abcdef12
  get_installed_derper_version() { echo '1.2.3-0.20260920000000-abcdef123456'; }
  derper_binary_needs_install && fail '完整 commit 未匹配 12 位伪版本'
  DERPER_VERSION=ABCDEF1234567890ABCDEF1234567890ABCDEF12
  derper_binary_needs_install && fail '大写 commit 未匹配 12 位伪版本'
  get_installed_derper_version() { echo 1.102.4; }
  resolve_derper_module_version() { echo v1.102.4; }
  derper_binary_needs_install && fail '发布标签未匹配 commit'
  resolve_derper_module_version() { echo v1.102.5; }
  derper_binary_needs_install || fail '不同版本必须重装'
}
test_certificate_resume() {
  INSTALL_DIR="$case_tmp/install"; IP_ADDR=203.0.113.10
  mkdir -p "$INSTALL_DIR/certs"
  printf cert > "$INSTALL_DIR/certs/$IP_ADDR.crt"
  printf key > "$INSTALL_DIR/certs/$IP_ADDR.key"
  printf stale > "$INSTALL_DIR/certs/fullchain.pem"
  CERT_PRESENT=1; CERT_SAN_MATCH=1; CERT_EXPIRY_OK=1; CERT_NAMING_OK=1
  harden_cert_dir() { touch "$case_tmp/hardened"; }
  generate_selfsigned_cert() { fail '有效证书不应重签'; }
  ensure_compatible_certs
  [[ -L "$INSTALL_DIR/certs/fullchain.pem" && -L "$INSTALL_DIR/certs/privkey.pem" ]] || fail '未恢复兼容链接'
  [[ -f "$case_tmp/hardened" ]] || fail '未恢复权限'
}
test_rotation_requires_ack() {
  INSTALL_DIR="$case_tmp/install"; IP_ADDR=203.0.113.10
  mkdir -p "$INSTALL_DIR/certs"
  printf old > "$INSTALL_DIR/certs/$IP_ADDR.crt"
  NON_INTERACTIVE=1
  openssl() { printf newder; }
  if confirm_cert_rotation "$case_tmp/new.crt"; then fail '非交互续签未经专门确认'; fi
  parse_args --accept-cert-rotation
  confirm_cert_rotation "$case_tmp/new.crt" || fail '显式确认未生效'
}
test_certificate_rollback() {
  INSTALL_DIR="$case_tmp/install"; IP_ADDR=203.0.113.10
  mkdir -p "$INSTALL_DIR/certs"
  printf oldcert > "$INSTALL_DIR/certs/$IP_ADDR.crt"
  printf oldkey > "$INSTALL_DIR/certs/$IP_ADDR.key"
  printf oldunit > "$SERVICE_PATH"
  # CI 环境存在真实 systemctl（非 root 时 daemon-reload 被拒），必须 stub 隔离
  systemctl() { [[ "$1" == daemon-reload ]]; }
  begin_cert_update
  printf newunit > "$SERVICE_PATH"
  printf newcert > "$INSTALL_DIR/certs/$IP_ADDR.crt"
  printf newkey > "$INSTALL_DIR/certs/$IP_ADDR.key"
  rollback_cert_update
  [[ "$(cat "$SERVICE_PATH")" == oldunit ]] || fail "unit 未随证书恢复"
  [[ "$(cat "$INSTALL_DIR/certs/$IP_ADDR.crt")" == oldcert ]] || fail '证书未回滚'
  [[ "$(cat "$INSTALL_DIR/certs/$IP_ADDR.key")" == oldkey ]] || fail '密钥未回滚'
}
test_new_root_default() {
  USER=root; unset SUDO_USER
  RUN_USER=root; NON_INTERACTIVE=1
  id() { echo 0; }
  read_derper_unit_content() { :; }
  resolve_run_user
  [[ "$RUN_USER" == derper ]] || fail '首次 root 非交互部署仍应默认专用用户'
}
test_real_certificate_write_failure() {
  INSTALL_DIR="$case_tmp/install"; IP_ADDR=203.0.113.10; CERT_DAYS=365
  harden_cert_dir() { :; }
  generate_derper_config() { :; }
  # 回滚路径同样会触发 daemon-reload，保持与 CI 一致的 stub
  systemctl() { [[ "$1" == daemon-reload ]]; }
  generate_selfsigned_cert >/dev/null
  commit_cert_update
  local old_cert old_key
  old_cert=$(sha256_hex < "$INSTALL_DIR/certs/$IP_ADDR.crt")
  old_key=$(sha256_hex < "$INSTALL_DIR/certs/$IP_ADDR.key")
  ACCEPT_CERT_ROTATION=1
  mv() {
    if [[ "$*" == *'.derper-cert.'* ]]; then return 1; fi
    command mv "$@"
  }
  if generate_selfsigned_cert >/dev/null 2>&1; then fail '证书写入失败必须返回失败'; fi
  [[ "$(sha256_hex < "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$old_cert" ]] || fail '写入失败改变旧证书'
  [[ "$(sha256_hex < "$INSTALL_DIR/certs/$IP_ADDR.key")" == "$old_key" ]] || fail '写入失败改变旧私钥'
  [[ -L "$INSTALL_DIR/certs/fullchain.pem" ]] || fail '回滚丢失链接'
}
test_recover_restart_failure_is_warning() {
  INSTALL_DIR="$case_tmp/install"; mkdir -p "$INSTALL_DIR/certs"
  printf old > "$INSTALL_DIR/certs/cert"
  printf oldunit > "$SERVICE_PATH"
  systemctl() { [[ "$1" == is-active || "$1" == daemon-reload ]]; }
  begin_cert_update
  systemctl() {
    case "$1" in
      daemon-reload) return 0 ;;
      restart) return 1 ;;
      *) return 1 ;;
    esac
  }
  verify_restored_service() { return 1; }
  recover_cert_update || fail 'restart failure after cert restore should warn, not abort'
}
test_interrupted_rollback() {
  INSTALL_DIR="$case_tmp/install"; mkdir -p "$INSTALL_DIR/certs"
  printf old > "$INSTALL_DIR/certs/cert"
  begin_cert_update
  mv "$INSTALL_DIR/certs" "${SERVICE_PATH}.certs-rollback/failed"
  rollback_cert_update
  [[ "$(cat "$INSTALL_DIR/certs/cert")" == old ]] || fail '恢复中断后无法继续'
}
test_rotation_decline_preserves_certificate() {
  INSTALL_DIR="$case_tmp/install"; IP_ADDR=203.0.113.10; CERT_DAYS=365
  harden_cert_dir() { :; }; generate_derper_config() { :; }
  generate_selfsigned_cert >/dev/null
  commit_cert_update
  local before
  before=$(sha256_hex < "$INSTALL_DIR/certs/$IP_ADDR.crt")
  NON_INTERACTIVE=1
  if generate_selfsigned_cert >/dev/null 2>&1; then fail '未确认轮换却成功'; fi
  [[ "$(sha256_hex < "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$before" ]] || fail '未确认却覆盖了旧证书'
  [[ ! -d "${SERVICE_PATH}.certs-rollback" ]] || fail '拒绝轮换不应启动事务'
}
test_module_query_preserves_network_settings() {
  GOPROXY_ARG=https://example.invalid; GOSUMDB_ARG=sum.example.invalid
  go() { :; }
  timeout() { [[ "${1:-}" != --kill-after=* ]] || shift; shift; "$@"; }
  env() {
    printf '%s\n' "$@" > "$case_tmp/env"
    echo v1.102.4
  }
  [[ "$(resolve_derper_module_version abcdef123456)" == v1.102.4 ]] || fail '无法解析规范版本'
  grep -qF 'GOPROXY=https://example.invalid' "$case_tmp/env" || fail '查询忽略显式代理'
  grep -qF 'GOSUMDB=sum.example.invalid' "$case_tmp/env" || fail '查询忽略校验数据库'
}
test_cleanup_restarts_previously_running_service() {
  INSTALL_DIR="$case_tmp/install"; mkdir -p "$INSTALL_DIR/certs"
  printf old > "$INSTALL_DIR/certs/cert"
  printf oldunit > "$SERVICE_PATH"
  systemctl() { [[ "$1" == is-active || "$1" == daemon-reload ]]; }
  begin_cert_update
  systemctl() {
    case "$1" in
      restart) touch "$case_tmp/restarted"; return 0 ;;
      daemon-reload) return 0 ;;
      *) return 1 ;;
    esac
  }
  read_derper_unit_content() { echo "ExecStart=derper -hostname 203.0.113.99 -a :30443 -stun-port 40000"; }
  # 此用例隔离旧编排分支；C阶段的完整发布门禁由专用套件和真实VM验证。
  publish_verification_gate() { return 0; }
  service_verified_running() {
    [[ "$IP_ADDR" == 203.0.113.99 && "$DERP_PORT" == 30443 && "$STUN_PORT" == 40000 ]] || return 1
    touch "$case_tmp/verified"
  }
  cleanup_deployment 1
  [[ -f "$case_tmp/restarted" ]] || fail '原先运行的服务恢复证书后未重启'
  [[ -f "$case_tmp/verified" ]] || fail '恢复未使用旧端点验证'
}
test_bug040_port_conflicts_follow_protocol() {
  DERP_PORT=30399
  STUN_PORT=3478
  CURRENT_DERPER_OWNS_PORTS=0
  local out rc

  rc=0
  out=$(check_port_conflicts_from_listening $'udp UNCONN 0 0 *:30399 *:* users:(("unbound",pid=9,fd=3))\n' 2>&1) || rc=$?
  [[ "$rc" -eq 0 ]] || fail "UDP 占用 30399 不能当成 DERP TCP 冲突，rc=${rc} out=${out}"
  [[ "$out" != *"TCP 端口 ${DERP_PORT}"* ]] || fail "不应把 UDP 监听报成 TCP 冲突：${out}"

  rc=0
  out=$(check_port_conflicts_from_listening $'tcp LISTEN 0 4096 *:3478 *:* users:(("nginx",pid=8,fd=3))\n' 2>&1) || rc=$?
  [[ "$rc" -eq 0 ]] || fail "TCP 占用 3478 不能当成 STUN UDP 冲突，rc=${rc} out=${out}"
  [[ "$out" != *"UDP 端口 ${STUN_PORT}"* ]] || fail "不应把 TCP 监听报成 UDP 冲突：${out}"

  rc=0
  out=$(check_port_conflicts_from_listening $'udp UNCONN 0 0 *:30399 *:* users:(("unbound",pid=9,fd=3))\ntcp LISTEN 0 4096 *:3478 *:* users:(("nginx",pid=8,fd=3))\n' 2>&1) || rc=$?
  [[ "$rc" -eq 0 ]] || fail "异协议相同端口号必须允许，rc=${rc} out=${out}"

  rc=0
  out=$(check_port_conflicts_from_listening $'tcp LISTEN 0 4096 *:30399 *:* users:(("nginx",pid=1,fd=3))\nudp UNCONN 0 0 *:30399 *:* users:(("derper",pid=2,fd=4))\n' 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "同端口 UDP 上的 derper 不能抵消外来 TCP 占用"
  [[ "$out" == *"TCP 端口 ${DERP_PORT}"* ]] || fail "TCP 冲突必须点名 TCP：${out}"

  rc=0
  out=$(check_port_conflicts_from_listening $'udp UNCONN 0 0 *:3478 *:* users:(("unbound",pid=9,fd=3))\n' 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "同协议外来 STUN 仍必须拒绝"
  [[ "$out" == *"UDP 端口 ${STUN_PORT}"* ]] || fail "UDP 冲突必须点名 UDP：${out}"

  rc=0
  out=$(check_port_conflicts_from_listening $'tcp6       0      0 :::30399                :::*                    LISTEN      8/nginx\nudp6       0      0 :::3478                 :::*                                9/unbound\n' 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "netstat tcp6/udp6 外来监听仍必须拒绝"
  [[ "$out" == *"TCP 端口 ${DERP_PORT}"* && "$out" == *"UDP 端口 ${STUN_PORT}"* ]] || fail "tcp6 与 udp6 都要按协议报告：${out}"

  rc=0
  out=$(check_port_conflicts_from_listening $'udp6       0      0 :::30399                :::*                                9/unbound\n' 2>&1) || rc=$?
  [[ "$rc" -eq 0 ]] || fail "udp6 占用 DERP 端口号不是 TCP 冲突，out=${out}"

  DERP_PORT=030399
  STUN_PORT=03478
  rc=0
  out=$(check_port_conflicts_from_listening $'tcp LISTEN 0 4096 *:30399 *:* users:(("nginx",pid=1,fd=3))\n' 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "前导零端口必须与规范端口 30399 的 TCP 监听冲突，out=${out}"
}

test_bug040_ownership_matches_protocol_and_pid() {
  DERP_PORT=30399
  STUN_PORT=3478
  CURRENT_DERPER_OWNS_PORTS=0
  PORT_TLS_OK=1
  PORT_STUN_OK=1
  systemctl() {
    case "$1" in
      is-active) return 0 ;;
      show) printf '2\n' ;;
      *) return 1 ;;
    esac
  }
  command() {
    if [[ "$1" == -v && "$2" == systemctl ]]; then return 0; fi
    if [[ "$1" == -v && "$2" == ss ]]; then return 0; fi
    if [[ "$1" == -v && "$2" == netstat ]]; then return 1; fi
    builtin command "$@"
  }
  ss() {
    printf '%s\n' \
      'tcp LISTEN 0 4096 *:30399 *:* users:(("nginx",pid=1,fd=3))' \
      'udp UNCONN 0 0 *:30399 *:* users:(("derper",pid=2,fd=4))' \
      'udp UNCONN 0 0 *:3478 *:* users:(("derper",pid=2,fd=5))'
  }
  if current_derper_owns_ports; then
    fail "derper 的 UDP 监听不能证明它拥有同号 TCP 端口"
  fi
}

test_bug041_contradictory_modes_stop_before_side_effects() {
  local called="$case_tmp/side-effects"
  local label rc
  for label in uninstall repair force check dry-run; do
    : >"$called"
    rc=0
    (
      check_os_environment() { echo os >>"$called"; return 0; }
      uninstall_derper() { echo uninstall >>"$called"; }
      write_systemd_service() { echo write-unit >>"$called"; }
      install_derper() { echo install >>"$called"; }
      generate_selfsigned_cert() { echo cert >>"$called"; }
      health_check_report() { echo health >>"$called"; }
      require_root() { echo root >>"$called"; }
      case "$label" in
        uninstall) main --health-check --uninstall --ip 8.8.8.8 ;;
        repair) main --health-check --repair --ip 8.8.8.8 ;;
        force) main --health-check --force --ip 8.8.8.8 ;;
        check) main --health-check --check --ip 8.8.8.8 ;;
        dry-run) main --health-check --dry-run --ip 8.8.8.8 ;;
      esac
    ) >/dev/null 2>&1 || rc=$?
    [[ "$rc" -ne 0 ]] || fail "矛盾主模式必须失败：${label}"
    [[ ! -s "$called" ]] || fail "拒绝前发生了副作用（${label}）：$(cat "$called")"
  done

  (
    parse_args --health-check --ip 8.8.8.8
    validate_arg_combos
  ) || fail "单独 --health-check 必须仍然合法"
  (
    parse_args --repair --ip 8.8.8.8
    validate_arg_combos
  ) || fail "单独 --repair 必须仍然合法"
  (
    parse_args --uninstall
    validate_arg_combos
  ) || fail "单独 --uninstall 必须仍然合法"
  (
    parse_args --force --install-healthcheck-cron --ip 8.8.8.8
    validate_arg_combos
  ) || fail "部署类主模式仍可附带安装健康检查 cron"
}

test_numeric_args_are_canonical_after_validation() {
  IP_ADDR=8.8.8.8
  RUN_USER="$(id -un)"
  DERP_PORT=0443
  STUN_PORT=03478
  CERT_DAYS=0365
  REGION_ID=0900
  TLS_CONNLIMIT=0032
  validate_settings >/dev/null || fail "前导零的合法数字必须通过校验"
  [[ "$DERP_PORT" == 443 ]] || fail "DERP 端口应规范为 443，实际 ${DERP_PORT}"
  [[ "$STUN_PORT" == 3478 ]] || fail "STUN 端口应规范为 3478，实际 ${STUN_PORT}"
  [[ "$CERT_DAYS" == 365 ]] || fail "证书天数应规范为 365，实际 ${CERT_DAYS}"
  [[ "$REGION_ID" == 900 ]] || fail "RegionID 应规范为 900，实际 ${REGION_ID}"
  [[ "$TLS_CONNLIMIT" == 32 ]] || fail "连接上限应规范为 32，实际 ${TLS_CONNLIMIT}"
  local output
  output=$(print_acl_snippet_cert "$IP_ADDR" "$DERP_PORT" deadbeef)
  [[ "$output" == *'"DERPPort": 443'* ]] || fail "derpMap 必须使用规范 DERP 端口"
  [[ "$output" == *'"STUNPort": 3478'* ]] || fail "derpMap 必须使用规范 STUN 端口"
  [[ "$output" == *'"RegionID": 900'* ]] || fail "derpMap 必须使用规范 RegionID"
  [[ "$output" != *0443* && "$output" != *03478* && "$output" != *0900* ]] || fail "derpMap 不能保留前导零：${output}"
}

test_health_check_exit_codes_keep_old_callers_safe() {
  local rc=0
  (
    check_os_environment() { return 0; }
    check_tailscale_status() { :; }
    check_derper_status() { :; }
    check_cert_status() { :; }
    check_live_cert_status() { :; }
    health_check_report() { :; }
    validate_settings() { return 0; }
    DERPER_RUNNING=1 PORT_TLS_OK=1 PORT_STUN_OK=1 PURE_IP_OK=1 DESIRED_CONFIG_OK=1
    CERT_PRESENT=1 CERT_NAMING_OK=1 CERT_SAN_MATCH=1 CERT_EXPIRY_OK=1
    LIVE_CERT_CHECKED=0
    main --health-check --ip 8.8.8.8
  ) >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]] || fail "已确认健康必须退出 0，实际 ${rc}"

  rc=0
  (
    check_os_environment() { return 0; }
    check_tailscale_status() { :; }
    check_derper_status() { :; }
    check_cert_status() { :; }
    check_live_cert_status() { :; }
    health_check_report() { :; }
    validate_settings() { return 0; }
    DERPER_RUNNING=1 PORT_TLS_OK=1 PORT_STUN_OK=1 PURE_IP_OK=1 DESIRED_CONFIG_OK=1
    CERT_PRESENT=0 CERT_NAMING_OK=1 CERT_SAN_MATCH=1 CERT_EXPIRY_OK=1
    LIVE_CERT_CHECKED=0
    main --health-check --ip 8.8.8.8
  ) >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]] || fail "已确认故障必须退出 1（旧 if ! 调用把非 0 当失败），实际 ${rc}"

  [[ "$(health_check_exit_code 0 1)" == 2 ]] || fail "未知必须退出 2，且不能报健康"
  [[ "$(health_check_exit_code 0 1)" != 0 ]] || fail "未知不能返回 0"
}

test_bug038_verify_clients_dependency_is_not_healthy() {
  DERPER_RUNNING=1 PORT_TLS_OK=1 PORT_STUN_OK=1 PURE_IP_OK=1 DESIRED_CONFIG_OK=1
  CERT_PRESENT=1 CERT_NAMING_OK=1 CERT_SAN_MATCH=1 CERT_EXPIRY_OK=1
  CERT_KEY_MATCH=1 CERT_CHECK_UNKNOWN=0 LIVE_CERT_CHECKED=0
  DERPER_VERIFY_CLIENTS_EFFECTIVE=1
  TS_RUNNING=0 TS_AUTH_UNKNOWN=0 METRICS_WRITE_FAILED=0
  health_is_ok && fail "verify-clients 开启且 tailscaled 停止时不能报健康"
  [[ "$(health_check_exit_code 0)" == 1 ]] || fail "tailscaled 停止是已确认故障，应退出 1"
  local metrics="$case_tmp/stopped.prom"
  write_prometheus_metrics "$metrics" 100 0 || fail "metrics write should succeed"
  grep -qF "derper_healthy 0" "$metrics" || fail "依赖失败不能输出 derper_healthy 1"

  TS_RUNNING=1 TS_AUTH_UNKNOWN=1
  health_is_ok && fail "无法确认 LocalAPI 时不能报健康"
  [[ "$(health_check_exit_code 0)" == 2 ]] || fail "无权限确认必须退出 2，而不是当成坏证书"
  write_prometheus_metrics "$metrics" 100 0 || fail "unknown metrics write should succeed"
  grep -qF "derper_check_unknown 1" "$metrics" || fail "未知状态必须出现在指标里"
}

test_bug039_mismatched_key_blocks_restart() {
  local work="$case_tmp/certs"
  mkdir -p "$work"
  INSTALL_DIR="$case_tmp/install"
  IP_ADDR=203.0.113.10
  mkdir -p "${INSTALL_DIR}/certs"
  SERVICE_PATH="$case_tmp/derper.service"
  openssl req -x509 -newkey rsa:2048 -keyout "$work/a.key" -out "$work/a.crt" -nodes -subj /CN=a -days 1 >/dev/null 2>&1
  openssl req -x509 -newkey rsa:2048 -keyout "$work/b.key" -out "$work/b.crt" -nodes -subj /CN=b -days 1 >/dev/null 2>&1
  cp "$work/a.crt" "${INSTALL_DIR}/certs/${IP_ADDR}.crt"
  cp "$work/b.key" "${INSTALL_DIR}/certs/${IP_ADDR}.key"
  check_cert_status
  [[ "$CERT_KEY_MATCH" -eq 0 ]] || fail "RSA 错配私钥必须被识别"
  [[ "$CERT_SAN_MATCH" -eq 0 || "$CERT_PRESENT" -eq 1 ]] || fail "错配不能被当成文件不存在"
  systemctl() { echo restarted >"$case_tmp/restarted"; return 0; }
  if ensure_compatible_certs >/dev/null 2>&1; then
    fail "错配证书不能走已兼容路径"
  fi
  [[ ! -f "$case_tmp/restarted" ]] || fail "错配时不能重启服务"

  openssl ecparam -name prime256v1 -genkey -noout -out "$work/e1.key" >/dev/null 2>&1
  openssl req -new -x509 -key "$work/e1.key" -out "$work/e1.crt" -subj /CN=e -days 1 >/dev/null 2>&1
  openssl ecparam -name prime256v1 -genkey -noout -out "$work/e2.key" >/dev/null 2>&1
  cp "$work/e1.crt" "${INSTALL_DIR}/certs/${IP_ADDR}.crt"
  cp "$work/e2.key" "${INSTALL_DIR}/certs/${IP_ADDR}.key"
  check_cert_status
  [[ "$CERT_KEY_MATCH" -eq 0 ]] || fail "EC 错配私钥必须被识别"

  if [[ "$(id -u)" -eq 0 ]]; then
    skip "unreadable-key assertion skipped (running as root; chmod 000 remains readable)"
    return 0
  fi
  chmod 000 "${INSTALL_DIR}/certs/${IP_ADDR}.key"
  check_cert_status
  [[ "$CERT_CHECK_UNKNOWN" -eq 1 ]] || fail "无权限读取私钥必须记为未知"
  [[ "$CERT_KEY_MATCH" -ne 0 ]] || fail "无权限不能记成已确认的私钥错配"
  chmod 600 "${INSTALL_DIR}/certs/${IP_ADDR}.key" || true
}

assert_interface_scoped_listener_classification() {
  local backend="$1" expected
  DERP_PORT=30399
  command() {
    if [[ "$1" == -v && "$2" == ss ]]; then [[ "$backend" == ss ]]; return $?; fi
    if [[ "$1" == -v && "$2" == netstat ]]; then [[ "$backend" == netstat ]]; return $?; fi
    builtin command "$@"
  }
  ss() {
    printf '%s\n' 'State Recv-Q Send-Q Local Address:Port Peer Address:Port'
    awk '{print "LISTEN 0 4096 " $0 " 0.0.0.0:*"}' "$case_tmp/listeners"
  }
  netstat() {
    printf '%s\n' 'Active Internet connections (only servers)' 'Proto Recv-Q Send-Q Local Address Foreign Address State'
    awk '{proto=($0 ~ /^\[|^::/) ? "tcp6" : "tcp"; print proto " 0 0 " $0 " :::* LISTEN"}' "$case_tmp/listeners"
  }
  cat >"$case_tmp/listeners" <<'ENDPOINTS'
127.0.0.1:9090
127.0.0.53:53
127.0.0.53%lo:53
127.8.9.10%lo:4000
[::1]:631
[::1%lo]:53
[::1]%lo:5353
::1:9001
::1%lo:9002
ENDPOINTS
  check_extra_attack_surface 2>"$case_tmp/warnings"
  [[ -z "$EXTRA_LISTENERS" && ! -s "$case_tmp/warnings" ]] || fail "$backend 不得对回环监听告警：${EXTRA_LISTENERS}"

  cat >"$case_tmp/external" <<'ENDPOINTS'
0.0.0.0:22
0.0.0.0:8080
[::]:22
100.90.1.2%tailscale0:443
[fe80::1%eth0]:5353
[2001:db8::1%eth0]:8080
::1:2:9090
ENDPOINTS
  cat "$case_tmp/external" >>"$case_tmp/listeners"
  printf '%s\n' '0.0.0.0:30399' '[::]:30399' >>"$case_tmp/listeners"
  expected=$(sort -u "$case_tmp/external")
  check_extra_attack_surface 2>"$case_tmp/warnings"
  [[ "$EXTRA_LISTENERS" == "$expected" ]] || fail "$backend 必须保留非回环地址且只排除本服务端口：${EXTRA_LISTENERS}"
  grep -q '非回环' "$case_tmp/warnings" || fail "$backend 必须保留非回环监听告警"
}

test_bug109_ss_interface_scoped_loopback() {
  assert_interface_scoped_listener_classification ss
}

test_bug109_netstat_interface_scoped_loopback() {
  assert_interface_scoped_listener_classification netstat
}

test_reference_hardening_matches_generated_unit() {
  local unit doc fragment directive key expected
  SECURITY_LEVEL=standard
  unit=$(render_derper_service_unit '/usr/local/bin/derper -c /var/lib/derper/derper.json' derper derper '' "$(get_security_hardening_options)" /var/lib/derper)
  for doc in "$ROOT_DIR/docs/REFERENCE_CN.md" "$ROOT_DIR/docs/REFERENCE_EN.md"; do
    fragment=$(awk '
      /^### systemd/ {section=1; next}
      section && /^### / {exit}
      section && /^```ini/ {in_ini=1; next}
      section && /^```/ {in_ini=0; next}
      in_ini && /^[A-Za-z][A-Za-z0-9]*=/ {print}
    ' "$doc")
    [[ -n "$fragment" ]] || fail "$doc 缺少加固示例"
    while IFS= read -r directive; do
      printf '%s\n' "$unit" | grep -Fxq -- "$directive" || fail "$doc 中的指令与实际unit不符：$directive"
    done <<<"$fragment"
    for key in StateDirectory StateDirectoryMode ReadWritePaths RestrictAddressFamilies; do
      expected=$(printf '%s\n' "$unit" | grep "^${key}=")
      printf '%s\n' "$fragment" | grep -Fxq -- "$expected" || fail "$doc 必须包含实际unit的 $key"
    done
  done
}

test_doc007_008_wording() {
  local advice listeners
  advice=$(print_server_node_acl_advice)
  [[ "$advice" == *"advertise-tags=tag:derper-server"* ]] || fail "应给出 advertise-tags，而不是 set --tags"
  [[ "$advice" != *"sudo tailscale set --tags"* ]] || fail "不能再建议执行 tailscale set --tags"
  [[ "$advice" == *"tagOwners"* && "$advice" == *"src"* ]] || fail "仍要说明 tagOwners 和不要把 tag 写成 src"
  [[ "$advice" == *"看到合法客户端"* ]] || fail "必须说明 verify-clients 的可见性"
  DERP_PORT=30399
  ss() {
    printf '%s\n' 'State Recv-Q Send-Q Local Address:Port Peer Address:Port' \
      'LISTEN 0 128 127.0.0.53:53 0.0.0.0:*' \
      'LISTEN 0 128 0.0.0.0:22 0.0.0.0:*'
  }
  check_extra_attack_surface >/dev/null
  [[ "$EXTRA_LISTENERS" != *"127.0.0.53"* ]] || fail "127.0.0.53 是回环地址，不能报成非回环"
  [[ "$EXTRA_LISTENERS" == *"0.0.0.0:22"* ]] || fail "公网 SSH 仍应被标出"
}

test_bug034_generated_task_survives_unexecutable_source() {
  local src_dir="$case_tmp/src" stable="$case_tmp/stable dir"
  mkdir -p "$src_dir"
  cp "$SCRIPT" "$src_dir/deploy.sh"
  chmod 644 "$src_dir/deploy.sh"
  SCRIPT_SELF="$src_dir/deploy.sh"
  HEALTHCHECK_PROGRAM_DIR="$stable"
  HEALTHCHECK_CRON_PATH="$case_tmp/cron"
  IP_ADDR=8.8.8.8
  DERP_PORT=30399
  STUN_PORT=3478
  command() {
    if [[ "$1" == -v && "$2" == systemctl ]]; then return 1; fi
    builtin command "$@"
  }
  install_healthcheck_cron || fail "应能从 0644 源脚本安装任务"
  install_healthcheck_cron || fail "重复安装应成功"
  [[ "$(grep -c '^\*/5' "$HEALTHCHECK_CRON_PATH")" -eq 1 ]] || fail "重复安装不能写出两套调度"
  grep -q 'bash ' "$HEALTHCHECK_CRON_PATH" || fail "任务必须显式调用 bash"
  local prog
  prog=$(printf '%q' "$stable/deploy_derper_ip_selfsigned.sh")
  grep -qF "$prog" "$HEALTHCHECK_CRON_PATH" || fail "任务必须调用稳定副本"
  rm -rf "$src_dir"
  bash "$stable/deploy_derper_ip_selfsigned.sh" --version >/dev/null || fail "源码目录移走后稳定副本仍应可执行"
}

test_bug034_timer_replaces_cron_once() {
  local stable="$case_tmp/stable" units="$case_tmp/units"
  mkdir -p "$stable"
  cp "$SCRIPT" "$case_tmp/deploy.sh"
  SCRIPT_SELF="$case_tmp/deploy.sh"
  HEALTHCHECK_PROGRAM_DIR="$stable"
  HEALTHCHECK_CRON_PATH="$case_tmp/old-cron"
  HEALTHCHECK_UNIT_DIR="$units"
  IP_ADDR=8.8.8.8
  printf 'old cron\n' >"$HEALTHCHECK_CRON_PATH"
  command() {
    if [[ "$1" == -v && "$2" == systemctl ]]; then return 0; fi
    builtin command "$@"
  }
  systemctl() { return 0; }
  install_healthcheck_cron || fail "timer 安装失败"
  install_healthcheck_cron || fail "重复安装 timer 失败"
  [[ ! -f "$HEALTHCHECK_CRON_PATH" ]] || fail "安装 timer 后必须去掉旧 cron，避免两套调度"
  [[ -f "$units/derper-healthcheck.service" && -f "$units/derper-healthcheck.timer" ]] || fail "应生成 oneshot service 与 timer"
  grep -q 'Type=oneshot' "$units/derper-healthcheck.service" || fail "健康任务应为 oneshot"
  grep -q '/bin/bash' "$units/derper-healthcheck.service" || fail "timer 必须显式调用 bash"
  [[ "$(find "$units" -name 'derper-healthcheck.timer' | wc -l | tr -d ' ')" -eq 1 ]] || fail "重复安装不能产生第二份 timer"
}

test_metrics_failure_keeps_old_sample() {
  local metrics="$case_tmp/derper.prom"
  printf 'derper_metrics_unixtime 111\n' >"$metrics"
  DERPER_RUNNING=1 PORT_TLS_OK=1 PORT_STUN_OK=1 PURE_IP_OK=1 DESIRED_CONFIG_OK=1
  CERT_PRESENT=1 CERT_NAMING_OK=1 CERT_SAN_MATCH=1 CERT_EXPIRY_OK=1 CERT_KEY_MATCH=1
  CERT_CHECK_UNKNOWN=0 DERPER_VERIFY_CLIENTS_EFFECTIVE=0 LIVE_CERT_CHECKED=0
  mv() {
    if [[ "${1:-}" == -f && "${3:-}" == "$metrics" ]]; then
      return 1
    fi
    command mv "$@"
  }
  if write_prometheus_metrics "$metrics" 60 0 >/dev/null 2>&1; then
    fail "指标移动失败必须返回非零"
  fi
  [[ "$(cat "$metrics")" == "derper_metrics_unixtime 111" ]] || fail "写入失败必须保留旧指标"
  [[ "$(health_check_exit_code 0)" == 1 ]] || fail "指标失败必须让健康检查返回非零"
  [[ "$(cert_expiry_alarm 60)" == warn-90 ]] || fail "60 天应是 90 天预警"
  [[ "$(cert_expiry_alarm 20)" == warn-30 ]] || fail "20 天应是 30 天预警"
  [[ "$(cert_expiry_alarm 3)" == warn-7 ]] || fail "3 天应是 7 天预警"
  generate_selfsigned_cert() { fail "预警天数不能触发换证"; }
  repair_cert_layout() { return 0; }
  CERT_EXPIRY_OK=1 CERT_KEY_MATCH=1
  ensure_compatible_certs || fail "未到换证条件时不应失败"
}

test_bug035_nft_rule_failure_keeps_old_rules() {
  TLS_CONNLIMIT=32
  TLS_CONNLIMIT_EXPLICIT=1
  DERP_PORT=30399
  INSTALL_HEALTHCHECK_CRON=0
  printf 'old-8\n' >"$case_tmp/nft-live"
  command() {
    if [[ "$1" == -v && "$2" == nft ]]; then return 0; fi
    if [[ "$1" == -v && "$2" == iptables ]]; then return 1; fi
    builtin command "$@"
  }
  nft() {
    if [[ "$1" == flush && "$2" == chain ]]; then
      : >"$case_tmp/nft-live"
      return 0
    fi
    if [[ "$1" == add && "$2" == rule ]]; then
      return 1
    fi
    if [[ "$1" == -f || "$*" == *"--file"* ]]; then
      cat >/dev/null
      return 1
    fi
    return 0
  }
  local out="" rc=0
  out=$(run_post_deploy_extras 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "nft 添加规则失败时后续加固必须失败，out=${out}"
  [[ "$(cat "$case_tmp/nft-live")" == old-8 ]] || fail "nft 失败时不能先提交 flush，旧规则已丢失"
  [[ "$out" == *错误* ]] || fail "失败必须明确报错：${out}"
  [[ "$out" != *限流规则已生效* ]] || fail "失败不能宣称限流已生效：${out}"
}

test_bug035_iptables_append_failure_keeps_old_rules() {
  TLS_CONNLIMIT=32
  TLS_CONNLIMIT_EXPLICIT=1
  DERP_PORT=30399
  INSTALL_HEALTHCHECK_CRON=0
  printf 'old-8\n' >"$case_tmp/ipt-live"
  command() {
    if [[ "$1" == -v && "$2" == nft ]]; then return 1; fi
    if [[ "$1" == -v && "$2" == iptables ]]; then return 0; fi
    builtin command "$@"
  }
  iptables() {
    if [[ "$1" == -S && "$2" == DERPER-CONNLIMIT ]]; then
      printf '%s\n' "-N DERPER-CONNLIMIT" "-A DERPER-CONNLIMIT -p tcp --dport 30399 -m connlimit --connlimit-above 8 -j REJECT"
      return 0
    fi
    if [[ "$1" == -F && "$2" == DERPER-CONNLIMIT ]]; then
      : >"$case_tmp/ipt-live"
      return 0
    fi
    if [[ "$1" == -A && "$2" == DERPER-CONNLIMIT && "$*" == *"connlimit-above 32"* ]]; then
      return 1
    fi
    if [[ "$1" == -A && "$2" == DERPER-CONNLIMIT-NEW ]]; then
      return 1
    fi
    if [[ "$1" == -A && "$2" == DERPER-CONNLIMIT && "$*" == *"connlimit-above 8"* ]]; then
      printf 'old-8\n' >"$case_tmp/ipt-live"
      return 0
    fi
    return 0
  }
  local out="" rc=0
  out=$(run_post_deploy_extras 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "iptables 追加规则失败时后续加固必须失败，out=${out}"
  [[ "$(cat "$case_tmp/ipt-live")" == old-8 ]] || fail "iptables 失败时必须保留或恢复旧规则"
  [[ "$out" == *错误* ]] || fail "失败必须明确报错：${out}"
  [[ "$out" != *限流规则已生效* ]] || fail "失败不能宣称限流已生效：${out}"
}

test_bug035_iptables_restore_failure_is_incomplete() {
  TLS_CONNLIMIT=32
  TLS_CONNLIMIT_EXPLICIT=1
  DERP_PORT=30399
  command() {
    if [[ "$1" == -v && "$2" == nft ]]; then return 1; fi
    if [[ "$1" == -v && "$2" == iptables ]]; then return 0; fi
    builtin command "$@"
  }
  iptables() {
    if [[ "$1" == -S && "$2" == DERPER-CONNLIMIT ]]; then
      printf '%s\n' "-N DERPER-CONNLIMIT" "-A DERPER-CONNLIMIT -p tcp --dport 30399 -m connlimit --connlimit-above 8 -j REJECT"
      return 0
    fi
    if [[ "$1" == -A && "$2" == DERPER-CONNLIMIT-NEW ]]; then
      return 0
    fi
    if [[ "$1" == -F && "$2" == DERPER-CONNLIMIT ]]; then
      return 0
    fi
    if [[ "$1" == -A && "$2" == DERPER-CONNLIMIT ]]; then
      return 1
    fi
    return 0
  }
  local out="" rc=0
  out=$(apply_tls_connlimit 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "恢复失败必须返回非零，out=${out}"
  [[ "$out" == *不完整* ]] || fail "恢复失败必须说明保护不完整：${out}"
  [[ "$out" != *限流规则已生效* && "$out" != *成功* ]] || fail "不完整状态不能打印成功：${out}"
}

test_legacy_symlink_migration() {
  INSTALL_DIR="$case_tmp/install"; IP_ADDR=203.0.113.10
  mkdir -p "$INSTALL_DIR/certs"
  printf oldcert > "$INSTALL_DIR/certs/fullchain.pem"
  printf oldkey > "$INSTALL_DIR/certs/privkey.pem"
  ln -s fullchain.pem "$INSTALL_DIR/certs/cert.pem"
  ln -s privkey.pem "$INSTALL_DIR/certs/key.pem"
  CERT_PRESENT=1; CERT_SAN_MATCH=1; CERT_EXPIRY_OK=1; CERT_NAMING_OK=0
  harden_cert_dir() { :; }
  ensure_compatible_certs || fail '别名迁移失败'
  [[ -f "$INSTALL_DIR/certs/$IP_ADDR.crt" && ! -L "$INSTALL_DIR/certs/$IP_ADDR.crt" ]] || fail '迁移证书形成链接环'
  [[ "$(cat "$INSTALL_DIR/certs/$IP_ADDR.key")" == oldkey ]] || fail '迁移私钥内容改变'
}

test_bug035_snapshot_read_failure_preserves_rules() {
  TLS_CONNLIMIT=32 TLS_CONNLIMIT_EXPLICIT=1 DERP_PORT=30399
  local s_calls=0 live_rules="old-8"
  iptables() {
    if [[ "$1" == -S && "$2" == DERPER-CONNLIMIT ]]; then
      s_calls=$((s_calls + 1))
      if [[ "$s_calls" -eq 1 ]]; then
        printf '%s\n' '-N DERPER-CONNLIMIT' '-A DERPER-CONNLIMIT -p tcp --dport 30399 -m connlimit --connlimit-above 8 -j REJECT'
        return 0
      fi
      return 4
    fi
    if [[ "$1" == -F && "$2" == DERPER-CONNLIMIT ]]; then live_rules=""; return 0; fi
    return 0
  }
  local rc=0 out=""
  out=$(apply_tls_connlimit_iptables 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "快照读取失败必须返回非零"
  [[ "$live_rules" == "old-8" ]] || fail "快照读取失败不得清空旧规则"
  [[ "$out" != *已恢复旧规则* ]] || fail "快照读取失败不得误报已恢复"
}

test_bug038_localapi_403_is_unhealthy() {
  DERPER_RUNNING=1 PORT_TLS_OK=1 PORT_STUN_OK=1 PURE_IP_OK=1 DESIRED_CONFIG_OK=1
  CERT_PRESENT=1 CERT_NAMING_OK=1 CERT_SAN_MATCH=1 CERT_EXPIRY_OK=1 CERT_KEY_MATCH=1
  CERT_CHECK_UNKNOWN=0 LIVE_CERT_CHECKED=0 DERPER_VERIFY_CLIENTS_EFFECTIVE=1 TS_RUNNING=1
  local sockpath="$case_tmp/tailscaled.sock"
  if ! command -v python3 >/dev/null 2>&1; then
    skip "localapi 403 test skipped (no python3)"
    return 0
  fi
  python3 -c 'import socket, sys; s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(sys.argv[1])' "$sockpath" 2>/dev/null || {
    skip "localapi 403 test skipped (unix socket unavailable)"
    return 0
  }
  chmod 666 "$sockpath"
  expected_tailscaled_socket() { printf '%s\n' "$sockpath"; }
  probe_tailscaled_localapi() { printf '403\n'; }
  note_tailscaled_auth_visibility
  [[ "$TS_AUTH_UNKNOWN" -eq 0 ]] || fail "403 时 TS_AUTH_UNKNOWN 应为 0"
  [[ "$TS_LOCALAPI_OK" -eq 0 ]] || fail "403 时 TS_LOCALAPI_OK 应为 0"
  health_is_ok && fail "403 时 health_is_ok 必须失败"
  [[ "$(health_check_exit_code 0)" == 1 ]] || fail "403 时健康检查退出码必须为 1（故障）"
}

test_bug042_timer_installation_failure_retains_cron() {
  SCRIPT_SELF="$case_tmp/deploy_derper_ip_selfsigned.sh"
  printf '#!/bin/bash\n' >"$SCRIPT_SELF"
  HEALTHCHECK_PROGRAM_DIR="$case_tmp/stable"
  HEALTHCHECK_UNIT_DIR="$case_tmp/units"
  HEALTHCHECK_CRON_PATH="$case_tmp/cron"
  IP_ADDR=8.8.8.8
  METRICS_TEXTFILE="$case_tmp/metrics.prom"
  printf 'old working cron\n' >"$HEALTHCHECK_CRON_PATH"
  mkdir -p "$HEALTHCHECK_UNIT_DIR"
  command() {
    if [[ "${1:-}" == -v && "${2:-}" == systemctl ]]; then return 0; fi
    builtin command "$@"
  }
  systemctl() {
    if [[ "$1" == "enable" ]]; then return 1; fi
    return 0
  }
  local rc=0
  install_healthcheck_cron >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || fail "enable 失败必须返回非零"
  [[ -f "$HEALTHCHECK_CRON_PATH" ]] || fail "enable 失败必须保留旧 cron"
  [[ ! -f "$HEALTHCHECK_PROGRAM_DIR/status" ]] || fail "enable 失败不得记录为成功"
}

test_bug043_044_port_ownership_pid_and_netstat() {
  DERP_PORT=30399 STUN_PORT=3478 PORT_TLS_OK=1 PORT_STUN_OK=1
  CURRENT_DERPER_OWNS_PORTS=0
  systemctl() { case "$1" in is-active) return 0;; show) echo 100;; *) return 1;; esac; }
  command() {
    if [[ "$1" == -v ]]; then
      case "$2" in systemctl|ss) return 0;; netstat) return 1;; esac
    fi
    builtin command "$@"
  }
  # 1) 同名但 PID=999（MainPID=100）：必须报冲突
  local ss_wrong="tcp LISTEN 0 4096 *:30399 *:* users:((\"derper\",pid=999,fd=3))\nudp UNCONN 0 0 *:3478 *:* users:((\"derper\",pid=999,fd=4))"
  local rc=0
  check_port_conflicts_from_listening "$(printf '%b' "$ss_wrong")" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || fail "同名但错误 PID 必须报错冲突"

  # 2) netstat 格式 100/derper（MainPID=100）：必须允许
  command() {
    if [[ "$1" == -v ]]; then
      case "$2" in systemctl|netstat) return 0;; ss) return 1;; esac
    fi
    builtin command "$@"
  }
  local netstat_own="tcp 0 0 0.0.0.0:30399 0.0.0.0:* LISTEN 100/derper\nudp 0 0 0.0.0.0:3478 0.0.0.0:* 100/derper"
  rc=0
  CURRENT_DERPER_OWNS_PORTS=0
  check_port_conflicts_from_listening "$(printf '%b' "$netstat_own")" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]] || fail "netstat 格式 100/derper 且 PID 匹配必须放行"
}

test_doc008_unsearchable_cert_dir_is_unknown() {
  if [[ "$(id -u)" -eq 0 ]]; then
    skip "unsearchable cert dir skipped (running as root; chmod 000 remains searchable)"
    return 0
  fi
  INSTALL_DIR="$case_tmp/install"
  IP_ADDR=203.0.113.10
  mkdir -p "$INSTALL_DIR/certs"
  printf cert >"$INSTALL_DIR/certs/$IP_ADDR.crt"
  printf key >"$INSTALL_DIR/certs/$IP_ADDR.key"
  chmod 000 "$INSTALL_DIR/certs"
  trap 'chmod 700 "$INSTALL_DIR/certs"' EXIT
  check_cert_status
  [[ "$CERT_PRESENT" -eq 0 ]] || fail "目录无权限时 CERT_PRESENT 应为 0"
  [[ "$CERT_NAMING_OK" -eq 0 ]] || fail "目录无权限时 CERT_NAMING_OK 应为 0"
  [[ "$CERT_CHECK_UNKNOWN" -eq 1 ]] || fail "目录无权限时 CERT_CHECK_UNKNOWN 必须为 1"
  [[ "$(health_check_exit_code 0)" == 2 ]] || fail "目录无权限时 health_exit 必须为 2（未知）"
}

test_bug045_timer_execstart_uses_proper_systemd_quoting() {
  SCRIPT_SELF="$case_tmp/src/deploy_derper_ip_selfsigned.sh"
  mkdir -p "$(dirname "$SCRIPT_SELF")"
  printf '#!/bin/bash\n' >"$SCRIPT_SELF"
  HEALTHCHECK_PROGRAM_DIR="$case_tmp/stable dir"
  HEALTHCHECK_UNIT_DIR="$case_tmp/units"
  IP_ADDR=8.8.8.8
  METRICS_TEXTFILE="$case_tmp/metrics dir/derper.prom"
  mkdir -p "$HEALTHCHECK_UNIT_DIR"
  command() {
    if [[ "${1:-}" == -v && "${2:-}" == systemctl ]]; then return 0; fi
    builtin command "$@"
  }
  systemctl() { return 0; }
  install_healthcheck_cron >/dev/null 2>&1 || fail "install timer failed"
  local svc_content
  svc_content=$(cat "$HEALTHCHECK_UNIT_DIR/derper-healthcheck.service")
  [[ "$svc_content" == *'ExecStart=/bin/bash "'* ]] || fail "ExecStart 路径必须用引号包裹"
  [[ "$svc_content" != *'stable\ dir'* ]] || fail "ExecStart 不得使用反斜线转义空格"
  [[ "$svc_content" != *'metrics\ dir'* ]] || fail "ExecStart 不得使用反斜线转义指标路径"
}

test_bug046_all_firewall_deletions_fail_propagates_error() {
  TLS_CONNLIMIT=0 TLS_CONNLIMIT_EXPLICIT=1
  command() {
    if [[ "$1" == -v && ( "$2" == nft || "$2" == iptables ) ]]; then return 0; fi
    builtin command "$@"
  }
  nft() { return 1; }
  iptables() { return 1; }
  local rc=0 out=""
  out=$(apply_tls_connlimit 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "全部防火墙删除失败时 apply_tls_connlimit 必须返回非零"
  [[ "$out" == *残留* ]] || fail "应报告可能残留部分防护规则"
}

test_bug046_mixed_backend_remove_failure_propagates_error() {
  TLS_CONNLIMIT=0 TLS_CONNLIMIT_EXPLICIT=1
  command() {
    if [[ "$1" == -v && ( "$2" == nft || "$2" == iptables ) ]]; then return 0; fi
    builtin command "$@"
  }
  nft() { echo 'Operation not permitted' >&2; return 1; }
  iptables() { return 0; }
  local rc=0 out=""
  out=$(apply_tls_connlimit 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "混合后端中任一后端移除失败必须返回非零，实际 rc=$rc"
  [[ "$out" == *残留* ]] || fail "混合后端中任一后端移除失败必须输出残留警告，实际输出：$out"
}

test_bug047_backup_copy_failure_keeps_original_units() {
  SCRIPT_SELF="$case_tmp/deploy_derper_ip_selfsigned.sh"
  printf '#!/bin/bash\n# new\n' >"$SCRIPT_SELF"
  HEALTHCHECK_PROGRAM_DIR="$case_tmp/stable"
  HEALTHCHECK_UNIT_DIR="$case_tmp/units"
  HEALTHCHECK_CRON_PATH="$case_tmp/cron"
  IP_ADDR=8.8.8.8
  mkdir -p "$HEALTHCHECK_PROGRAM_DIR" "$HEALTHCHECK_UNIT_DIR"
  printf 'old-stable-program\n' >"$HEALTHCHECK_PROGRAM_DIR/deploy_derper_ip_selfsigned.sh"
  printf 'old-service\n' >"$HEALTHCHECK_UNIT_DIR/derper-healthcheck.service"
  printf 'old-timer\n' >"$HEALTHCHECK_UNIT_DIR/derper-healthcheck.timer"
  command() {
    if [[ "${1:-}" == -v && "${2:-}" == systemctl ]]; then return 0; fi
    builtin command "$@"
  }
  systemctl() { return 0; }
  cp() {
    local dest="${*: -1}"
    if [[ "$dest" == *.bak ]]; then return 1; fi
    command cp "$@"
  }
  local rc=0 out=""
  out=$(install_healthcheck_cron 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "必要备份失败必须中止更新，实际 rc=$rc out=$out"
  [[ "$(cat "$HEALTHCHECK_PROGRAM_DIR/deploy_derper_ip_selfsigned.sh")" == "old-stable-program" ]] || fail "备份失败后稳定副本必须保持原文件"
  [[ "$(cat "$HEALTHCHECK_UNIT_DIR/derper-healthcheck.service")" == "old-service" ]] || fail "备份失败后 service 必须保持原文件"
  [[ "$(cat "$HEALTHCHECK_UNIT_DIR/derper-healthcheck.timer")" == "old-timer" ]] || fail "备份失败后 timer 必须保持原文件"
  [[ "$out" == *备份* ]] || fail "必须明确报告备份失败，而不是当成原文件不存在：${out}"
}

test_bug048_sendq_is_not_main_pid() {
  DERP_PORT=30399 STUN_PORT=3478 PORT_TLS_OK=1 PORT_STUN_OK=1 CURRENT_DERPER_OWNS_PORTS=0
  systemctl() { case "$1" in is-active) return 0;; show) echo 128;; *) return 1;; esac; }
  command() {
    if [[ "$1" == -v ]]; then
      case "$2" in systemctl|ss) return 0;; netstat) return 1;; esac
    fi
    builtin command "$@"
  }
  ss() {
    printf '%s\n' \
      'tcp LISTEN 0 128 *:30399 *:* users:(("nginx",pid=999,fd=3))' \
      'udp UNCONN 0 128 *:3478 *:* users:(("unbound",pid=999,fd=4))'
  }
  local rc=0 out=""
  out=$(check_port_conflicts_from_listening "$(ss)" 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "Send-Q=128 不得被当成 MainPID=128 的端口归属，out=${out}"
  [[ "$out" == *"TCP 端口 30399"* ]] || fail "必须报告外来 TCP 占用：${out}"
  if current_derper_owns_ports; then
    fail "current_derper_owns_ports 也不得把队列长度当成 PID"
  fi
  ss() {
    printf '%s\n' \
      'tcp LISTEN 128 0 *:30399 *:* users:(("nginx",pid=999,fd=3))' \
      'udp UNCONN 128 0 *:3478 *:* users:(("unbound",pid=999,fd=4))'
  }
  CURRENT_DERPER_OWNS_PORTS=0
  rc=0
  out=$(check_port_conflicts_from_listening "$(ss)" 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "Recv-Q=128 不得被当成 MainPID=128 的端口归属，out=${out}"
}

test_bug049_cron_delete_failure_rolls_back_timer() {
  SCRIPT_SELF="$case_tmp/deploy_derper_ip_selfsigned.sh"
  printf '#!/bin/bash\n' >"$SCRIPT_SELF"
  HEALTHCHECK_PROGRAM_DIR="$case_tmp/stable"
  HEALTHCHECK_UNIT_DIR="$case_tmp/units"
  HEALTHCHECK_CRON_PATH="$case_tmp/old-cron"
  IP_ADDR=8.8.8.8
  mkdir -p "$HEALTHCHECK_UNIT_DIR"
  printf 'old cron\n' >"$HEALTHCHECK_CRON_PATH"
  command() {
    if [[ "${1:-}" == -v && "${2:-}" == systemctl ]]; then return 0; fi
    builtin command "$@"
  }
  systemctl() { return 0; }
  rm() {
    if [[ " $* " == *" $HEALTHCHECK_CRON_PATH "* || "$*" == "$HEALTHCHECK_CRON_PATH" ]]; then
      return 1
    fi
    command rm "$@"
  }
  local rc=0 out=""
  out=$(install_healthcheck_cron 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "删除旧 cron 失败必须返回非零，实际成功：${out}"
  [[ -f "$HEALTHCHECK_CRON_PATH" ]] || fail "删除失败时旧 cron 必须仍在"
  [[ ! -f "$HEALTHCHECK_UNIT_DIR/derper-healthcheck.timer" ]] || fail "删除旧 cron 失败必须撤销新 timer，避免双重调度"
  [[ ! -f "$HEALTHCHECK_PROGRAM_DIR/status" ]] || fail "双重调度风险下不得记录安装成功"
}

test_bug049_timer_delete_failure_rolls_back_cron() {
  SCRIPT_SELF="$case_tmp/deploy_derper_ip_selfsigned.sh"
  printf '#!/bin/bash\n' >"$SCRIPT_SELF"
  HEALTHCHECK_PROGRAM_DIR="$case_tmp/stable"
  HEALTHCHECK_UNIT_DIR="$case_tmp/units"
  HEALTHCHECK_CRON_PATH="$case_tmp/new-cron"
  IP_ADDR=8.8.8.8
  mkdir -p "$HEALTHCHECK_UNIT_DIR"
  printf 'old timer\n' >"$HEALTHCHECK_UNIT_DIR/derper-healthcheck.timer"
  printf 'old service\n' >"$HEALTHCHECK_UNIT_DIR/derper-healthcheck.service"
  command() {
    if [[ "${1:-}" == -v && "${2:-}" == systemctl ]]; then return 1; fi
    builtin command "$@"
  }
  unset -f systemctl 2>/dev/null || true
  rm() {
    if [[ " $* " == *" $HEALTHCHECK_UNIT_DIR/derper-healthcheck.timer "* ]]; then
      return 1
    fi
    command rm "$@"
  }
  local rc=0 out=""
  out=$(install_healthcheck_cron 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "删除旧 timer 失败必须返回非零，实际成功：${out}"
  [[ -f "$HEALTHCHECK_UNIT_DIR/derper-healthcheck.timer" ]] || fail "删除失败时旧 timer 必须仍在"
  [[ ! -f "$HEALTHCHECK_CRON_PATH" ]] || fail "删除旧 timer 失败必须撤销新 cron，避免双重调度"
}

# 使用可写临时目录与有状态的 systemctl 替身，root 下也能覆盖迁移失败。
setup_timer_migration_failure() {
  SCRIPT_SELF="$case_tmp/source.sh"
  printf '#!/bin/bash\n' >"$SCRIPT_SELF"
  HEALTHCHECK_PROGRAM_DIR="$case_tmp/stable"
  HEALTHCHECK_UNIT_DIR="$case_tmp/units"
  HEALTHCHECK_CRON_PATH="$case_tmp/new-cron"
  IP_ADDR=8.8.8.8
  mkdir -p "$HEALTHCHECK_PROGRAM_DIR" "$HEALTHCHECK_UNIT_DIR"
  printf 'old timer\n' >"$HEALTHCHECK_UNIT_DIR/derper-healthcheck.timer"
  printf 'old service\n' >"$HEALTHCHECK_UNIT_DIR/derper-healthcheck.service"
  timer_runtime="$case_tmp/runtime"
  timer_enabled="$case_tmp/enabled"
  timer_calls="$case_tmp/calls"
  : >"$timer_calls"
  command() {
    if [[ "${1:-}" == -v && "${2:-}" == systemctl ]]; then return 0; fi
    builtin command "$@"
  }
  mkdir() {
    # 只让选择 timer 的目录准备失败，模拟回退 cron；不修改真实权限。
    [[ "$*" != "-p $HEALTHCHECK_UNIT_DIR" ]] || return 1
    command mkdir "$@"
  }
  rm() {
    local arg
    for arg in "$@"; do
      [[ "$arg" != "$HEALTHCHECK_UNIT_DIR/derper-healthcheck.timer" ]] || return 1
    done
    command rm "$@"
  }
  systemctl() {
    printf '%s\n' "$*" >>"$timer_calls"
    case "$1" in
      is-active) [[ "$(cat "$timer_runtime")" == active ]]; return $?;;
      is-enabled) [[ "$(cat "$timer_enabled")" == enabled ]]; return $?;;
      disable) printf 'disabled\n' >"$timer_enabled"; printf 'inactive\n' >"$timer_runtime";;
      stop) printf 'inactive\n' >"$timer_runtime";;
      start) printf 'active\n' >"$timer_runtime";;
      enable)
        printf 'enabled\n' >"$timer_enabled"
        if [[ "${2:-}" == --now ]]; then printf 'active\n' >"$timer_runtime"; fi
        ;;
    esac
    return 0
  }
}

test_bug050_timer_rollback_restores_previous_runtime_state() {
  local original_runtime original_enabled
  for original_runtime in active inactive; do
    for original_enabled in enabled disabled; do
      (
        setup_timer_migration_failure
        printf '%s\n' "$original_runtime" >"$timer_runtime"
        printf '%s\n' "$original_enabled" >"$timer_enabled"
        local rc=0 out=""
        out=$(install_healthcheck_cron 2>&1) || rc=$?
        [[ "$rc" -ne 0 ]] || fail "删除旧 timer 失败必须返回非零：$out"
        [[ ! -e "$HEALTHCHECK_CRON_PATH" ]] || fail "失败迁移必须撤销新 cron"
        [[ "$(cat "$timer_runtime")" == "$original_runtime" ]] || fail "必须恢复原运行状态 ${original_runtime}：$(cat "$timer_calls")"
        [[ "$(cat "$timer_enabled")" == "$original_enabled" ]] || fail "必须恢复原启用状态 ${original_enabled}：$(cat "$timer_calls")"
        if [[ "$original_runtime" == inactive ]] && grep -Eq '^(start |enable --now)' "$timer_calls"; then
          fail "原本停止的 timer 不得被启动"
        fi
      ) || return 1
    done
  done
}

test_bug050_failed_timer_update_restores_stopped_state() {
  setup_timer_migration_failure
  unset -f mkdir rm
  printf 'inactive\n' >"$timer_runtime"
  printf 'disabled\n' >"$timer_enabled"
  printf 'old cron\n' >"$HEALTHCHECK_CRON_PATH"
  rm() {
    local arg
    for arg in "$@"; do
      [[ "$arg" != "$HEALTHCHECK_CRON_PATH" ]] || return 1
    done
    command rm "$@"
  }
  local rc=0 out=""
  out=$(install_healthcheck_cron 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "删除旧 cron 失败必须返回非零"
  [[ "$(cat "$timer_runtime")" == inactive && "$(cat "$timer_enabled")" == disabled ]] || fail "更新失败必须恢复原本停止的 timer：$(cat "$timer_calls")"
}

test_bug051_incomplete_files_do_not_restart_timer() {
  setup_timer_migration_failure
  printf 'active\n' >"$timer_runtime"
  printf 'enabled\n' >"$timer_enabled"
  cp() {
    [[ "${2:-}" != */svc.bak ]] || return 1
    command cp "$@"
  }
  local rc=0 out=""
  out=$(install_healthcheck_cron 2>&1) || rc=$?
  [[ "$rc" -ne 0 && "$out" == *回滚不完整* ]] || fail "恢复失败必须明确报告回滚不完整：$out"
  if grep -Eq '^(start |enable )' "$timer_calls"; then
    fail "文件恢复不完整时不得启动 timer：$(cat "$timer_calls")"
  fi
  [[ -n "$(find "$HEALTHCHECK_PROGRAM_DIR" -name svc.bak -print)" ]] || fail "恢复失败必须保留快照"
}


test_bug051_failure_before_activation_needs_no_stop() {
  setup_timer_migration_failure
  unset -f mkdir rm
  command rm -f "$HEALTHCHECK_UNIT_DIR/derper-healthcheck.timer" "$HEALTHCHECK_UNIT_DIR/derper-healthcheck.service"
  cp() {
    [[ "${2:-}" != "$SCRIPT_SELF" ]] || return 1
    command cp "$@"
  }
  systemctl() {
    printf '%s\n' "$*" >>"$timer_calls"
    [[ "$1" != disable ]]
  }
  local rc=0 out=""
  out=$(install_healthcheck_cron 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "程序复制失败必须中止安装"
  [[ "$out" != *回滚不完整* ]] || fail "未尝试启动 timer 时不应误报停止失败：$out"
  if grep -q '^disable ' "$timer_calls"; then
    fail "新 timer 尚未启用时无需停止不存在的 unit"
  fi
}

test_bug051_restore_failure_keeps_snapshot() {
  SCRIPT_SELF="$case_tmp/deploy_derper_ip_selfsigned.sh"
  printf '#!/bin/bash\n# new\n' >"$SCRIPT_SELF"
  HEALTHCHECK_PROGRAM_DIR="$case_tmp/stable"
  HEALTHCHECK_UNIT_DIR="$case_tmp/units"
  HEALTHCHECK_CRON_PATH="$case_tmp/cron"
  IP_ADDR=203.0.113.10
  mkdir -p "$HEALTHCHECK_PROGRAM_DIR" "$HEALTHCHECK_UNIT_DIR"
  printf 'old-stable-program\n' >"$HEALTHCHECK_PROGRAM_DIR/deploy_derper_ip_selfsigned.sh"
  printf 'old-service\n' >"$HEALTHCHECK_UNIT_DIR/derper-healthcheck.service"
  printf 'old-timer\n' >"$HEALTHCHECK_UNIT_DIR/derper-healthcheck.timer"
  command() {
    if [[ "${1:-}" == -v && "${2:-}" == systemctl ]]; then return 0; fi
    builtin command "$@"
  }
  systemctl() { [[ "$1" != enable ]]; }
  cp() {
    local src="" dest="" arg
    for arg in "$@"; do
      case "$arg" in
        -*) continue ;;
      esac
      src="$dest"
      dest="$arg"
    done
    if [[ "$src" == *.bak ]]; then
      return 1
    fi
    command cp "$@"
  }
  local rc=0 out=""
  out=$(install_healthcheck_cron 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "恢复失败时安装必须返回非零：${out}"
  [[ "$out" == *回滚不完整* ]] || fail "必须报告回滚不完整：${out}"
  [[ "$out" != *保持原样* ]] || fail "恢复失败不得声称已有调度保持原样：${out}"
  local snaps=()
  shopt -s nullglob
  snaps=("$HEALTHCHECK_PROGRAM_DIR"/.healthcheck-tx.*)
  [[ ${#snaps[@]} -ge 1 ]] || fail "恢复失败必须保留快照目录"
  [[ "$(head -n 1 "${snaps[0]}/dest.bak")" == "old-stable-program" ]] || fail "快照中的旧程序必须还在"
  [[ "$(head -n 1 "$HEALTHCHECK_PROGRAM_DIR/deploy_derper_ip_selfsigned.sh")" != "old-stable-program" ]] || fail "恢复复制失败时现场程序不会变回旧内容，此时只能依赖保留的快照"
}

test_bug042_existing_timer_update_failure_restores_old_units() {
  SCRIPT_SELF="$case_tmp/deploy_derper_ip_selfsigned.sh"
  printf '#!/bin/bash\n# new\n' >"$SCRIPT_SELF"
  HEALTHCHECK_PROGRAM_DIR="$case_tmp/stable"
  HEALTHCHECK_UNIT_DIR="$case_tmp/units"
  HEALTHCHECK_CRON_PATH="$case_tmp/cron"
  IP_ADDR=203.0.113.10
  mkdir -p "$HEALTHCHECK_PROGRAM_DIR" "$HEALTHCHECK_UNIT_DIR"
  printf 'old-stable-program\n' > "$HEALTHCHECK_PROGRAM_DIR/deploy_derper_ip_selfsigned.sh"
  printf 'old-service\n' > "$HEALTHCHECK_UNIT_DIR/derper-healthcheck.service"
  printf 'old-timer\n' > "$HEALTHCHECK_UNIT_DIR/derper-healthcheck.timer"
  command() {
    if [[ "${1:-}" == -v && "${2:-}" == systemctl ]]; then return 0; fi
    builtin command "$@"
  }
  systemctl() {
    [[ "$1" != enable ]]
  }
  local rc=0
  install_healthcheck_cron >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || fail "已有 timer 更新中途失败必须返回非零"
  [[ -f "$HEALTHCHECK_UNIT_DIR/derper-healthcheck.service" ]] || fail "旧 service unit 必须保留"
  [[ -f "$HEALTHCHECK_UNIT_DIR/derper-healthcheck.timer" ]] || fail "旧 timer unit 必须保留"
  [[ "$(cat "$HEALTHCHECK_UNIT_DIR/derper-healthcheck.service")" == "old-service" ]] || fail "service 必须恢复旧内容"
  [[ "$(cat "$HEALTHCHECK_UNIT_DIR/derper-healthcheck.timer")" == "old-timer" ]] || fail "timer 必须恢复旧内容"
  [[ "$(head -n 1 "$HEALTHCHECK_PROGRAM_DIR/deploy_derper_ip_selfsigned.sh")" == "old-stable-program" ]] || fail "稳定副本程序必须恢复旧版本"
}

test_b1_incomplete_marker_blocks_and_is_not_executed() {
  DEPLOY_STATE_DIR="$case_tmp/deploy-state"
  local canary="$case_tmp/pwned"
  mkdir -p "$DEPLOY_STATE_DIR"
  printf 'phase=switch\nrecovery=%s/recovery\n$(touch %s)\n' "$DEPLOY_STATE_DIR" "$canary" >"$DEPLOY_STATE_DIR/incomplete"
  local rc=0 out=""
  out=$(ordinary_change_allowed 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "未完成标记必须阻断普通覆盖：${out}"
  [[ "$out" == *recover-interrupted* ]] || fail "必须要求显式恢复，不能自动继续：${out}"
  [[ ! -e "$canary" ]] || fail "恢复记录不得被 source/eval 执行"
  RECOVER_INTERRUPTED=0 CHECK_ONLY=0 HEALTH_CHECK=0
  if ordinary_change_allowed >/dev/null 2>&1; then
    fail "危险标记不能被当成可继续的变更"
  fi
}

test_b1_lock_failure_blocks_second_change() {
  DEPLOY_STATE_DIR="$case_tmp/deploy-state"
  local calls=0
  flock() {
    calls=$((calls + 1))
    [[ "$calls" -eq 1 ]]
  }
  acquire_deploy_lock || fail "第一次变更必须取得锁"
  if acquire_deploy_lock; then
    fail "锁被占用时第二次升级/回退/迁移/轮换/卸载必须失败"
  fi
}

test_b1_second_process_cannot_take_lock() {
  if ! command -v flock >/dev/null 2>&1; then
    skip "second-process flock skipped (no flock)"
    return 0
  fi
  DEPLOY_STATE_DIR="$case_tmp/deploy-state"
  acquire_deploy_lock || fail "父进程必须先取得真实 flock"
  local rc
  rc=$(DEPLOY_STATE_DIR="$DEPLOY_STATE_DIR" bash -c '
    DERPER_TEST_MODE=1
    source "$1"
    DEPLOY_STATE_DIR="$2"
    if acquire_deploy_lock; then
      echo took
    else
      echo blocked
    fi
  ' _ "$SCRIPT" "$DEPLOY_STATE_DIR")
  [[ "$rc" == "blocked" ]] || fail "另一个进程在锁被占用时不得取得变更锁：${rc}"
}

test_b1_unverified_staging_keeps_only_backup() {
  DEPLOY_STATE_DIR="$case_tmp/deploy-state"
  mkdir -p "$DEPLOY_STATE_DIR/recovery" "$DEPLOY_STATE_DIR/recovery.staging"
  printf 'backup-good\n' >"$DEPLOY_STATE_DIR/recovery/binary"
  chmod 755 "$DEPLOY_STATE_DIR/recovery/binary"
  local sum
  sum=$(sha256_hex <"$DEPLOY_STATE_DIR/recovery/binary")
  printf 'binary_sha256=%s\nrun_intent=inactive\n' "$sum" >"$DEPLOY_STATE_DIR/recovery/manifest"
  printf 'partial\n' >"$DEPLOY_STATE_DIR/recovery.staging/binary"
  printf 'binary_sha256=deadbeef\nrun_intent=inactive\n' >"$DEPLOY_STATE_DIR/recovery.staging/manifest"
  local rc=0
  promote_recovery_staging >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || fail "未校验的暂存不得替换恢复集"
  [[ "$(cat "$DEPLOY_STATE_DIR/recovery/binary")" == "backup-good" ]] || fail "唯一有效备份必须保持原内容"
}

test_b2_bad_candidate_and_disk_failure_keep_live_binary() {
  DEPLOY_STATE_DIR="$case_tmp/deploy-state"
  BIN_PATH="$case_tmp/bin/derper"
  SERVICE_PATH="$case_tmp/derper.service"
  INSTALL_DIR="$case_tmp/install"
  VERIFY_CLIENTS_MODE=off
  mkdir -p "$(dirname "$BIN_PATH")" "$INSTALL_DIR"
  printf '#!/bin/sh\necho old\n' >"$BIN_PATH"
  chmod 755 "$BIN_PATH"
  printf 'old-unit\n' >"$SERVICE_PATH"
  local candidate="$case_tmp/candidate"
  printf '#!/bin/sh\nexit 42\n' >"$candidate"
  chmod 755 "$candidate"
  local rc=0 out=""
  out=$(publish_derper_candidate "$candidate" 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "坏候选不得发布成功：${out}"
  [[ "$out" != *安装到* ]] || fail "坏候选不得报告已安装：${out}"
  [[ "$(head -n 1 "$BIN_PATH")" == "#!/bin/sh" && "$(sed -n '2p' "$BIN_PATH")" == "echo old" ]] || fail "坏候选不得覆盖正式二进制"
  rm -rf "$DEPLOY_STATE_DIR"
  printf '#!/bin/sh\necho -a\nexit 0\n' >"$candidate"
  cp() { return 1; }
  rc=0
  out=$(publish_derper_candidate "$candidate" 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "磁盘写入失败不得返回成功：${out}"
  [[ "$(sed -n '2p' "$BIN_PATH")" == "echo old" ]] || fail "写入失败后正式二进制必须仍是旧版本"
  unset -f cp
}

test_b2_stopped_intent_is_not_started() {
  DEPLOY_STATE_DIR="$case_tmp/deploy-state"
  BIN_PATH="$case_tmp/bin/derper"
  SERVICE_PATH="$case_tmp/derper.service"
  INSTALL_DIR="$case_tmp/install"
  mkdir -p "$(dirname "$BIN_PATH")" "$INSTALL_DIR/state" "$DEPLOY_STATE_DIR/recovery"
  printf '#!/bin/sh\necho new\n' >"$BIN_PATH"
  chmod 755 "$BIN_PATH"
  printf '#!/bin/sh\necho old\n' >"$DEPLOY_STATE_DIR/recovery/binary"
  chmod 755 "$DEPLOY_STATE_DIR/recovery/binary"
  printf 'old-unit\n' >"$DEPLOY_STATE_DIR/recovery/unit"
  printf 'old-unit\n' >"$SERVICE_PATH"
  write_recovery_manifest "$DEPLOY_STATE_DIR/recovery" inactive
  printf 'phase=switch\nrecovery=%s/recovery\n' "$DEPLOY_STATE_DIR" >"$DEPLOY_STATE_DIR/incomplete"
  local calls="$case_tmp/systemctl-calls"
  : >"$calls"
  systemctl() {
    printf '%s\n' "$*" >>"$calls"
    [[ "$1" == is-active ]] && return 1
    return 0
  }
  verify_restored_service() { echo started >"$case_tmp/verified"; return 0; }
  local rc=0
  rollback_deploy_change >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]] || fail "停止中的服务应能恢复文件，rc=${rc}"
  [[ "$(sed -n '2p' "$BIN_PATH")" == "echo old" ]] || fail "回退必须恢复旧二进制"
  if grep -q '^start ' "$calls"; then
    fail "原停止服务必须保持停止：$(cat "$calls")"
  fi
  [[ ! -e "$case_tmp/verified" ]] || fail "原停止服务不得进入启动验证"
}

test_b2_daemon_drift_stays_manual() {
  DEPLOY_STATE_DIR="$case_tmp/deploy-state"
  BIN_PATH="$case_tmp/bin/derper"
  SERVICE_PATH="$case_tmp/derper.service"
  INSTALL_DIR="$case_tmp/install"
  VERIFY_CLIENTS_MODE=on
  mkdir -p "$(dirname "$BIN_PATH")" "$INSTALL_DIR"
  printf '#!/bin/sh\necho -a\necho old\n' >"$BIN_PATH"
  chmod 755 "$BIN_PATH"
  local candidate="$case_tmp/candidate"
  printf '#!/bin/sh\necho -a\necho new\n' >"$candidate"
  chmod 755 "$candidate"
  tailscaled_daemon_revision() { printf 'aaa111\n'; }
  derper_artifact_revision() { printf 'bbb222\n'; }
  local canary="$case_tmp/tailscale-mutated"
  tailscale() { echo mutated >"$canary"; }
  tailscaled() { echo mutated >"$canary"; }
  local rc=0 out=""
  out=$(publish_derper_candidate "$candidate" 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "daemon 漂移必须拒绝切换：${out}"
  [[ "$out" == *人工* ]] || fail "daemon 漂移必须转人工：${out}"
  [[ "$(sed -n '3p' "$BIN_PATH")" == "echo old" ]] || fail "拒绝切换时正式二进制必须不变"
  [[ ! -e "$canary" ]] || fail "不得顺带升级或降级 tailscaled"
}

test_b2_first_install_failure_has_no_fake_previous() {
  DEPLOY_STATE_DIR="$case_tmp/deploy-state"
  BIN_PATH="$case_tmp/bin/derper"
  SERVICE_PATH="$case_tmp/derper.service"
  INSTALL_DIR="$case_tmp/install"
  VERIFY_CLIENTS_MODE=off
  mkdir -p "$INSTALL_DIR"
  local candidate="$case_tmp/candidate"
  printf '#!/bin/sh\necho -a\n' >"$candidate"
  chmod 755 "$candidate"
  cp() { return 1; }
  local rc=0 out=""
  out=$(publish_derper_candidate "$candidate" 2>&1) || rc=$?
  unset -f cp
  [[ "$rc" -ne 0 ]] || fail "首次安装写入失败必须返回非零：${out}"
  [[ "$out" == *首次安装* ]] || fail "首次安装必须明确没有上一版本：${out}"
  [[ ! -e "$BIN_PATH" ]] || fail "首次安装失败不得留下正式二进制"
  [[ ! -e "$DEPLOY_STATE_DIR/recovery/binary" ]] || fail "首次安装失败不得伪造上一版本备份"
}

test_b2_rollback_restores_config_and_state() {
  DEPLOY_STATE_DIR="$case_tmp/deploy-state"
  BIN_PATH="$case_tmp/bin/derper"
  SERVICE_PATH="$case_tmp/derper.service"
  INSTALL_DIR="$case_tmp/install"
  NODE_STATE_DIR="$case_tmp/node-state"
  mkdir -p "$(dirname "$BIN_PATH")" "$NODE_STATE_DIR" "$DEPLOY_STATE_DIR/recovery/state"
  printf '#!/bin/sh\necho new\n' >"$BIN_PATH"
  chmod 755 "$BIN_PATH"
  printf '#!/bin/sh\necho old\n' >"$DEPLOY_STATE_DIR/recovery/binary"
  chmod 755 "$DEPLOY_STATE_DIR/recovery/binary"
  printf 'old-unit\n' >"$DEPLOY_STATE_DIR/recovery/unit"
  printf 'old-config\n' >"$DEPLOY_STATE_DIR/recovery/config"
  printf 'old-state\n' >"$DEPLOY_STATE_DIR/recovery/state/node.key"
  # 真实快照的状态集合包含目录中的节点配置，摘要必须与恢复后的集合一致。
  cp "$DEPLOY_STATE_DIR/recovery/config" "$DEPLOY_STATE_DIR/recovery/state/derper.json"
  printf 'new-unit\n' >"$SERVICE_PATH"
  printf 'new-config\n' >"$NODE_STATE_DIR/derper.json"
  printf 'new-state\n' >"$NODE_STATE_DIR/node.key"
  write_recovery_manifest "$DEPLOY_STATE_DIR/recovery" inactive
  printf 'phase=switch\nrecovery=%s/recovery\n' "$DEPLOY_STATE_DIR" >"$DEPLOY_STATE_DIR/incomplete"
  systemctl() { [[ "$1" == is-active ]] && return 1; return 0; }
  local rc=0
  rollback_deploy_change >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]] || fail "配置和状态可恢复时回退必须成功，rc=${rc}"
  [[ "$(cat "$NODE_STATE_DIR/derper.json")" == "old-config" ]] || fail "回退必须写回旧节点配置"
  [[ "$(cat "$NODE_STATE_DIR/node.key")" == "old-state" ]] || fail "回退必须写回旧节点状态"
  [[ "$(cat "$DEPLOY_STATE_DIR/recovery/config")" == "old-config" ]] || fail "回退成功后仍要保留恢复集里的配置"
}

test_b2_reverify_failure_keeps_recovery() {
  DEPLOY_STATE_DIR="$case_tmp/deploy-state"
  BIN_PATH="$case_tmp/bin/derper"
  SERVICE_PATH="$case_tmp/derper.service"
  INSTALL_DIR="$case_tmp/install"
  mkdir -p "$(dirname "$BIN_PATH")" "$DEPLOY_STATE_DIR/recovery"
  printf '#!/bin/sh\necho new\n' >"$BIN_PATH"
  chmod 755 "$BIN_PATH"
  printf '#!/bin/sh\necho old\n' >"$DEPLOY_STATE_DIR/recovery/binary"
  chmod 755 "$DEPLOY_STATE_DIR/recovery/binary"
  local sum
  sum=$(sha256_hex <"$DEPLOY_STATE_DIR/recovery/binary")
  printf 'binary_sha256=%s\nrun_intent=active\n' "$sum" >"$DEPLOY_STATE_DIR/recovery/manifest"
  printf 'phase=switch\nrecovery=%s/recovery\n' "$DEPLOY_STATE_DIR" >"$DEPLOY_STATE_DIR/incomplete"
  systemctl() { return 0; }
  verify_restored_service() { return 1; }
  local rc=0 out=""
  out=$(rollback_deploy_change 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "复验失败必须返回非零：${out}"
  [[ -f "$DEPLOY_STATE_DIR/recovery/binary" ]] || fail "复验失败必须留下恢复集"
  [[ -f "$DEPLOY_STATE_DIR/incomplete" ]] || fail "复验失败不得清掉未完成标记"
  [[ "$(sed -n '2p' "$DEPLOY_STATE_DIR/recovery/binary")" == "echo old" ]] || fail "恢复集中的旧二进制不得被覆盖"
}

test_b2_build_timeout_keeps_live_binary() {
  DEPLOY_STATE_DIR="$case_tmp/deploy-state"
  BIN_PATH="$case_tmp/bin/derper"
  _tmpdir="$case_tmp"
  VERIFY_CLIENTS_MODE=off
  DERPER_VERSION=v1.2.3
  GOPROXY_ARG=""
  GOSUMDB_ARG=""
  GOTOOLCHAIN_ARG=local
  mkdir -p "$(dirname "$BIN_PATH")"
  printf '#!/bin/sh\necho old\n' >"$BIN_PATH"
  chmod 755 "$BIN_PATH"
  precheck_go_network() { return 0; }
  ensure_go() { return 0; }
  _timeout_run() { return 1; }
  # install_derper 用 exit，必须放进子进程，否则当前测试进程会直接结束。
  local rc
  rc=$( ( install_derper >/dev/null 2>&1 ); echo $? )
  [[ "$rc" -ne 0 ]] || fail "构建超时必须失败"
  [[ "$(sed -n '2p' "$BIN_PATH")" == "echo old" ]] || fail "构建超时不得替换正式二进制"
}

test_b3_migration_failure_restores_running_service() {
  DEPLOY_STATE_DIR="$case_tmp/deploy-state"
  INSTALL_DIR="$case_tmp/install"
  NODE_STATE_DIR="$INSTALL_DIR/state"
  SERVICE_PATH="$case_tmp/derper.service"
  RUN_USER=derper
  mkdir -p "$INSTALL_DIR/certs" "$DEPLOY_STATE_DIR"
  printf 'cert-bytes\n' >"$INSTALL_DIR/certs/node.crt"
  printf 'old-identity\n' >"$INSTALL_DIR/derper.json"
  printf 'unit\n' >"$SERVICE_PATH"
  local calls="$case_tmp/svc-calls"
  : >"$calls"
  systemctl() { printf '%s\n' "$*" >>"$calls"; return 0; }
  verify_restored_service() { echo verified >>"$calls"; return 0; }
  chown() { return 0; }
  id() { echo derper; }
  cp() {
    local dest="${*: -1}"
    if [[ "$dest" == "$NODE_STATE_DIR/"* ]]; then
      return 1
    fi
    command cp "$@"
  }
  local rc=0 out=""
  out=$(migrate_node_state 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "迁移复制失败必须返回非零：${out}"
  [[ "$(cat "$INSTALL_DIR/derper.json")" == "old-identity" ]] || fail "迁移失败必须保留原节点身份"
  [[ "$(cat "$INSTALL_DIR/certs/node.crt")" == "cert-bytes" ]] || fail "迁移失败不得改变证书字节"
  grep -q '^stop derper' "$calls" || fail "迁移前必须先停止正在运行的服务：$(cat "$calls")"
  grep -q '^start derper' "$calls" || fail "迁移失败后必须按原运行意图重新启动：$(cat "$calls")"
  grep -q '^verified$' "$calls" || fail "迁移失败恢复后必须复验"
}

test_bug054_restore_does_not_follow_state_symlink() {
  NODE_STATE_DIR="$case_tmp/state"
  mkdir -p "$NODE_STATE_DIR" "$case_tmp/recovery"
  printf 'ORIGINAL-ROOT-FILE\n' >"$case_tmp/victim"
  printf 'OLD-NODE-CONFIG\n' >"$case_tmp/recovery/config"
  ln -s "$case_tmp/victim" "$NODE_STATE_DIR/derper.json"
  local rc=0
  restore_saved_payload "$case_tmp/recovery" >/dev/null 2>&1 || rc=$?
  [[ "$(cat "$case_tmp/victim")" == "ORIGINAL-ROOT-FILE" ]] || fail "恢复不得沿符号链接改写目标文件"
  [[ ! -L "$NODE_STATE_DIR/derper.json" ]] || fail "恢复后的配置不能仍是符号链接"
  [[ "$(cat "$NODE_STATE_DIR/derper.json")" == "OLD-NODE-CONFIG" ]] || fail "恢复应把旧配置装成普通文件，rc=${rc}"
}

test_bug054_restore_refuses_symlink_state_directory() {
  mkdir -p "$case_tmp/real-state" "$case_tmp/recovery"
  printf 'SECRET\n' >"$case_tmp/real-state/derper.json"
  ln -s "$case_tmp/real-state" "$case_tmp/linked-state"
  NODE_STATE_DIR="$case_tmp/linked-state"
  printf 'OLD-NODE-CONFIG\n' >"$case_tmp/recovery/config"
  if restore_saved_payload "$case_tmp/recovery" >/dev/null 2>&1; then
    fail "状态目录本身是符号链接时必须拒绝恢复"
  fi
  [[ "$(cat "$case_tmp/real-state/derper.json")" == "SECRET" ]] || fail "不得穿过状态目录符号链接删除或改写原文件"
}

test_bug055_same_origin_candidate_passes_daemon_gate() {
  VERIFY_CLIENTS_MODE=on
  local candidate="$case_tmp/candidate" canary="$case_tmp/disk-tailscaled-called"
  printf '#!/bin/sh\n# tailscale.com v1.104.1\necho -- -a\n' >"$candidate"
  chmod 755 "$candidate"
  use_running_tailscaled 'printf "1.104.1\n  tailscale commit: abcdef0123456789abcdef0123456789abcdef01\n"'
  tailscaled() { echo called >"$canary"; printf 'tailscale commit: bbbbbbbbbbbb\n'; }
  resolve_derper_module_version() { printf 'v1.104.1\n'; }
  candidate_matches_running_daemon "$candidate" || fail "模块版本与 daemon commit 解析到同一发布时必须放行"
  [[ ! -e "$canary" ]] || fail "同源门禁不得执行磁盘上的 tailscaled"
  resolve_derper_module_version() { printf 'v1.104.2\n'; }
  if candidate_matches_running_daemon "$candidate"; then
    fail "解析出版本不同的 commit 仍必须拒绝"
  fi
}

test_bug056_rollback_reloads_process_and_keeps_marker_on_stop_failure() {
  DEPLOY_STATE_DIR="$case_tmp/deploy-state"
  BIN_PATH="$case_tmp/bin/derper"
  SERVICE_PATH="$case_tmp/derper.service"
  INSTALL_DIR="$case_tmp/install"
  NODE_STATE_DIR="$case_tmp/state"
  mkdir -p "$DEPLOY_STATE_DIR/recovery" "$(dirname "$BIN_PATH")" "$NODE_STATE_DIR"
  printf 'old-executable\n' >"$DEPLOY_STATE_DIR/recovery/binary"
  printf 'new-executable\n' >"$BIN_PATH"
  printf 'old-unit\n' >"$DEPLOY_STATE_DIR/recovery/unit"
  printf 'new-unit\n' >"$SERVICE_PATH"
  write_recovery_manifest "$DEPLOY_STATE_DIR/recovery" active
  printf 'phase=switch\nrecovery=%s/recovery\n' "$DEPLOY_STATE_DIR" >"$DEPLOY_STATE_DIR/incomplete"
  local runtime=active runtime_executable=new-executable
  systemctl() {
    case "$1" in
      start) [[ "$runtime" == active ]] || { runtime=active; runtime_executable=$(cat "$BIN_PATH"); } ;;
      stop) runtime=inactive ;;
      restart) runtime=active; runtime_executable=$(cat "$BIN_PATH") ;;
      is-active) [[ "$runtime" == active ]] ;;
      *) return 0 ;;
    esac
  }
  verify_restored_service() { [[ "$runtime" == active && "$runtime_executable" == "$(cat "$BIN_PATH")" ]]; }
  local rc=0
  rollback_deploy_change >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]] || fail "旧二进制已重新加载时回退应成功，rc=${rc}"
  [[ "$(cat "$BIN_PATH")" == "old-executable" ]] || fail "磁盘必须是旧二进制"
  [[ "$runtime_executable" == "old-executable" ]] || fail "正在运行的进程必须换成旧二进制，实际 ${runtime_executable}"
  [[ ! -e "$DEPLOY_STATE_DIR/incomplete" ]] || fail "确认换回旧进程后才可以清除标记"

  printf 'phase=switch\nrecovery=%s/recovery\n' "$DEPLOY_STATE_DIR" >"$DEPLOY_STATE_DIR/incomplete"
  write_recovery_manifest "$DEPLOY_STATE_DIR/recovery" inactive
  systemctl() { [[ "$1" == stop ]] && return 1; return 0; }
  rc=0
  rollback_deploy_change >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || fail "停止失败必须返回非零"
  [[ -e "$DEPLOY_STATE_DIR/incomplete" ]] || fail "停止失败不得清除未完成标记"
}

test_bug057_migration_failure_keeps_recovery_marker() {
  DEPLOY_STATE_DIR="$case_tmp/migration-deploy"
  INSTALL_DIR="$case_tmp/migration-install"
  NODE_STATE_DIR="$case_tmp/migration-state"
  SERVICE_PATH="$case_tmp/legacy.service"
  RUN_USER=derper
  mkdir -p "$INSTALL_DIR/certs" "$DEPLOY_STATE_DIR"
  printf 'old-node-key\n' >"$INSTALL_DIR/derper.json"
  printf 'cert\n' >"$INSTALL_DIR/certs/node.crt"
  printf 'legacy-unit\n' >"$SERVICE_PATH"
  local runtime=active saw_marker=no
  chown() { return 0; }
  harden_cert_dir() { return 0; }
  id() { echo derper; }
  systemctl() {
    case "$1" in
      is-active) [[ "$runtime" == active ]] ;;
      stop)
        [[ -e "$DEPLOY_STATE_DIR/incomplete" ]] && saw_marker=yes
        runtime=inactive
        ;;
      start) runtime=active ;;
      *) return 0 ;;
    esac
  }
  file_sha256() {
    [[ "$1" == "$INSTALL_DIR/derper.json" ]] && return 1
    sha256_hex <"$1"
  }
  verify_restored_service() { return 1; }
  local rc=0
  migrate_node_state >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || fail "迁移摘要失败必须返回非零"
  [[ "$saw_marker" == yes ]] || fail "停服前必须已经写下未完成标记"
  [[ -e "$DEPLOY_STATE_DIR/incomplete" ]] || fail "未能恢复运行时必须保留未完成标记"
  [[ -d "$DEPLOY_STATE_DIR/recovery" ]] || fail "纯迁移也必须留下恢复集"
}

test_bug058_migrated_config_is_owned_by_run_user() {
  INSTALL_DIR="$case_tmp/install"
  NODE_STATE_DIR="$case_tmp/state"
  SERVICE_PATH="$case_tmp/missing.service"
  RUN_USER=derper
  mkdir -p "$INSTALL_DIR/certs"
  printf 'node-identity\n' >"$INSTALL_DIR/derper.json"
  printf 'cert-bytes\n' >"$INSTALL_DIR/certs/node.crt"
  local chown_log="$case_tmp/chown-log"
  : >"$chown_log"
  chown() { printf '%s\n' "$*" >>"$chown_log"; return 0; }
  id() { echo derper; }
  migrate_node_state >/dev/null || fail "属主可变更时迁移必须成功"
  local config
  config=$(derper_config_path)
  grep -F "$config" "$chown_log" >/dev/null || fail "迁移后的节点配置必须 chown 给运行用户：$(cat "$chown_log")"
  chown() {
    [[ "${*: -1}" == "$config" ]] && return 1
    return 0
  }
  rm -f "$config"
  if migrate_node_state >/dev/null 2>&1; then
    fail "配置无法交给运行用户时不得报告迁移成功"
  fi
}

test_b3_layout_blocks_cert_rename_and_keeps_identity() {
  INSTALL_DIR="$case_tmp/install"
  NODE_STATE_DIR=""
  RUN_USER="derper"
  mkdir -p "$INSTALL_DIR/certs"
  printf 'cert-bytes\n' >"$INSTALL_DIR/certs/node.crt"
  printf '{"PrivateKey":"node-identity-1"}\n' >"$INSTALL_DIR/derper.json"
  ln -s "$INSTALL_DIR/certs" "$case_tmp/certs-link"
  local chown_log="$case_tmp/chown-log"
  : >"$chown_log"
  chown() { printf '%s\n' "$*" >>"$chown_log"; return 0; }
  id() { echo derper; }
  if ! mode_grants_write_to 755 0 0 65534 65534; then
    :
  else
    fail "root:0755 父目录不得允许其他用户写入"
  fi
  layout_install_tree || fail "安装树布局必须成功"
  if grep -q -- '-R' "$chown_log"; then
    fail "不得把整个安装树 chown -R 给服务用户：$(cat "$chown_log")"
  fi
  local state
  state=$(derper_node_state_dir)
  [[ "$(cat "$state/derper.json")" == '{"PrivateKey":"node-identity-1"}' ]] || fail "迁移后节点身份必须保持原字节"
  [[ "$(cat "$INSTALL_DIR/certs/node.crt")" == "cert-bytes" ]] || fail "迁移不得改动证书字节"
  rm -rf "$INSTALL_DIR/certs"
  ln -s "$case_tmp/certs-link" "$INSTALL_DIR/certs"
  if layout_install_tree >/dev/null 2>&1; then
    fail "恶意证书目录符号链接必须拒绝"
  fi
}

# 审查回归：历次审查反例的先红后绿回归与 B 阶段 b1/b2/b3 工作包行为。
# 非 root 可运行（root/工具缺失场景输出 skip，不当通过）；可传测试函数名单独运行。
# 退出码 0=全部通过，1=有失败（累计列出）。

# 默认按序执行全部用例；传参可单独运行指定用例（用于定位与变异验证）。
# BUG-117：默认幂等部署在 LocalAPI 已确认故障时不得绕过发布门禁并成功收尾。
setup_bug117_main() {
  DEPLOY_STATE_DIR="$case_tmp/deploy-state"
  mkdir -p "$DEPLOY_STATE_DIR"
  flock() { return 0; }
  check_os_environment() { :; }
  require_root() { :; }
  recover_cert_update() { return 0; }
  ordinary_change_allowed() { return 0; }
  recover_interrupted_change() { return 0; }
  acquire_deploy_lock() { return 0; }
  detect_public_ip() { IP_ADDR=8.8.8.8; return 0; }
  check_tailscale_status() { TS_INSTALLED=1 TS_RUNNING=1 TS_VERSION="1.80.0" TS_VER_OK=1; }
  check_derper_status() {
    DERPER_BIN=1 DERPER_SERVICE_PRESENT=1 DERPER_RUNNING=1 PURE_IP_OK=1
    DESIRED_CONFIG_OK=1 DERPER_VERIFY_CLIENTS_EFFECTIVE=1
    PORT_TLS_OK=1 PORT_STUN_OK=1 CURRENT_DERPER_OWNS_PORTS=1
    TS_LOCALAPI_OK="$BUG117_LOCALAPI_OK" TS_AUTH_UNKNOWN="${BUG117_AUTH_UNKNOWN:-0}"
  }
  check_cert_status() { CERT_PRESENT=1 CERT_NAMING_OK=1 CERT_SAN_MATCH=1 CERT_EXPIRY_OK=1; }
  check_live_cert_status() { LIVE_CERT_CHECKED=1 CERT_LIVE_MATCH=1; }
  cert_layout_is_ok() { return 0; }
  check_extra_attack_surface() { EXTRA_LISTENERS=""; }
  check_automatic_updates() { AUTO_UPDATES_OK=1; }
  tailscale() { printf '{"Regions":{}}\n'; }
  _timeout_run() { shift; "$@"; }
  precheck_verify_clients() { return 0; }
  align_derper_version_with_tailscale() { :; }
  derper_binary_needs_install() { return 1; }
  ensure_compatible_certs() { CERTS_CHANGED=0; return 0; }
  commit_cert_update() { return 0; }
  run_post_deploy_extras() { return 0; }
  print_firewall_tips() { :; }
  runtime_checks() { :; }
  write_systemd_service() { fail '幂等部署不应重写 derper unit'; }
  # 真实门禁只被替身包装：记录调用，并在 LocalAPI 故障时按真实判断失败。
  publish_verification_gate() {
    printf 'called\n' >"$case_tmp/gate-called"
    [[ "${TS_LOCALAPI_OK:-0}" -eq 1 ]]
  }
  finalize_deployment_report() { printf 'called\n' >"$case_tmp/report-called"; return 0; }
  finish_deploy_auto_maintain() { return 0; }
}

test_bug117_default_deploy_gates_confirmed_localapi_failure() {
  BUG117_LOCALAPI_OK=0 BUG117_AUTH_UNKNOWN=0
  setup_bug117_main
  local out rc=0
  out=$(main --ip 8.8.8.8 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "LocalAPI 已确认故障时默认部署必须非零：${out}"
  [[ -f "$case_tmp/gate-called" ]] || fail '健康检查失败时仍必须调用发布门禁'
  [[ ! -f "$case_tmp/report-called" ]] || fail '门禁失败后不得执行成功收尾'
  [[ "$out" != *'已就绪'* ]] || fail '门禁失败不得输出已就绪'
}

test_bug117_default_deploy_still_succeeds_when_healthy() {
  BUG117_LOCALAPI_OK=1 BUG117_AUTH_UNKNOWN=0
  setup_bug117_main
  local out rc=0
  out=$(main --ip 8.8.8.8 2>&1) || rc=$?
  [[ "$rc" -eq 0 ]] || fail "健康的幂等部署应成功：${rc} ${out}"
  [[ -f "$case_tmp/gate-called" ]] || fail '健康路径仍应经过发布门禁'
  [[ "$out" == *'已就绪'* ]] || fail '健康路径应输出已就绪'
}

# BUG-122：LocalAPI 必须按 derper unit 的 User= 判断，而不是调用者（常为 root）。
test_bug122_localapi_checks_derper_service_user() {
  command -v python3 >/dev/null 2>&1 || { skip "无 python3，Unix socket 未测"; return 0; }
  local ts_sock="$case_tmp/ts.sock" caller
  python3 -c 'import socket, sys; s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(sys.argv[1])' "$ts_sock" 2>/dev/null || {
    skip "Unix socket 不可用"
    return 0
  }
  chmod 666 "$ts_sock"
  caller=$(id -un)
  DERPER_VERIFY_CLIENTS_EFFECTIVE=1 TS_RUNNING=1
  expected_tailscaled_socket() { printf '%s\n' "$ts_sock"; }
  probe_tailscaled_localapi() { printf '200\n'; }
  printf '[Service]\nUser=nobody\n' >"$SERVICE_PATH"

  # 调用者能访问、derper 用户确认不可访问：必须是明确故障（非未知、非健康）。
  running_as_root() { return 0; }
  probe_localapi_as_user() { return 1; }
  socket_rw_as_user() { return 1; }
  note_tailscaled_auth_visibility 2>/dev/null
  [[ "$TS_LOCALAPI_OK" -eq 0 && "$TS_AUTH_UNKNOWN" -eq 0 ]] ||
    fail "derper 用户被拒绝时必须是确认故障：OK=${TS_LOCALAPI_OK} UNKNOWN=${TS_AUTH_UNKNOWN}"

  # derper 用户可访问：健康。
  probe_localapi_as_user() { [[ "$1" == nobody ]] && printf '200\n'; }
  note_tailscaled_auth_visibility 2>/dev/null
  [[ "$TS_LOCALAPI_OK" -eq 1 && "$TS_AUTH_UNKNOWN" -eq 0 ]] ||
    fail "derper 用户可访问时应健康：OK=${TS_LOCALAPI_OK} UNKNOWN=${TS_AUTH_UNKNOWN}"

  # 非 root 调用者无法证明他人权限：未知，不能报假健康也不能报确认故障。
  running_as_root() { return 1; }
  probe_localapi_as_user() { return 1; }
  socket_rw_as_user() { return 2; }
  note_tailscaled_auth_visibility 2>/dev/null
  [[ "$TS_LOCALAPI_OK" -eq 0 && "$TS_AUTH_UNKNOWN" -eq 1 ]] ||
    fail "无法确认 derper 用户权限时应为未知：OK=${TS_LOCALAPI_OK} UNKNOWN=${TS_AUTH_UNKNOWN}"

  # unit 的 User= 就是调用者时，调用者自身判断已足够。
  printf '[Service]\nUser=%s\n' "$caller" >"$SERVICE_PATH"
  probe_localapi_as_user() { fail '服务用户与调用者相同时无需额外探测'; }
  socket_rw_as_user() { fail '服务用户与调用者相同时无需额外探测'; }
  note_tailscaled_auth_visibility 2>/dev/null
  [[ "$TS_LOCALAPI_OK" -eq 1 && "$TS_AUTH_UNKNOWN" -eq 0 ]] || fail '同一用户应健康'

  # 服务用户不存在：服务本就无法以该身份启动，确认故障。
  printf '[Service]\nUser=derper-no-such-user-xyz\n' >"$SERVICE_PATH"
  running_as_root() { return 0; }
  note_tailscaled_auth_visibility 2>/dev/null
  [[ "$TS_LOCALAPI_OK" -eq 0 && "$TS_AUTH_UNKNOWN" -eq 0 ]] || fail '服务用户不存在应为确认故障'
}

# BUG-123：必须切换为服务用户实际请求 LocalAPI；属主/权限位不能证明健康。
test_bug123_localapi_must_be_requested_as_service_user() {
  command -v python3 >/dev/null 2>&1 || { skip "无 python3，Unix socket 未测"; return 0; }
  local ts_sock="$case_tmp/ts2.sock"
  python3 -c 'import socket, sys; s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(sys.argv[1])' "$ts_sock" 2>/dev/null || {
    skip "Unix socket 不可用"
    return 0
  }
  chmod 666 "$ts_sock"
  DERPER_VERIFY_CLIENTS_EFFECTIVE=1 TS_RUNNING=1
  expected_tailscaled_socket() { printf '%s\n' "$ts_sock"; }
  probe_tailscaled_localapi() { printf '200\n'; }
  printf '[Service]\nUser=nobody\n' >"$SERVICE_PATH"
  running_as_root() { return 0; }

  # 调用者（root）2xx，但服务用户实际被 LocalAPI 拒绝：确认故障。
  # 权限位检查若仍返回“可访问”，说明未按服务用户实际请求。
  user_can_access_socket() { return 0; }
  probe_localapi_as_user() { [[ "$1" == nobody ]] && printf '403\n'; }
  note_tailscaled_auth_visibility 2>/dev/null
  [[ "$TS_LOCALAPI_OK" -eq 0 && "$TS_AUTH_UNKNOWN" -eq 0 ]] ||
    fail "服务用户被 LocalAPI 拒绝时必须确认故障：OK=${TS_LOCALAPI_OK} UNKNOWN=${TS_AUTH_UNKNOWN}"

  # 服务用户以该身份连接 socket 失败（000）：确认故障，不是健康。
  probe_localapi_as_user() { [[ "$1" == nobody ]] && printf '000\n'; }
  note_tailscaled_auth_visibility 2>/dev/null
  [[ "$TS_LOCALAPI_OK" -eq 0 && "$TS_AUTH_UNKNOWN" -eq 0 ]] ||
    fail "服务用户无法连接 socket 时必须确认故障：OK=${TS_LOCALAPI_OK} UNKNOWN=${TS_AUTH_UNKNOWN}"

  # 服务用户实际 2xx：健康。
  probe_localapi_as_user() { [[ "$1" == nobody ]] && printf '200\n'; }
  note_tailscaled_auth_visibility 2>/dev/null
  [[ "$TS_LOCALAPI_OK" -eq 1 && "$TS_AUTH_UNKNOWN" -eq 0 ]] ||
    fail "服务用户实际 2xx 时应健康：OK=${TS_LOCALAPI_OK} UNKNOWN=${TS_AUTH_UNKNOWN}"

  # 无法切换身份实际请求时，socket 可读写也不能证明 LocalAPI 接受该身份：未知。
  probe_localapi_as_user() { return 1; }
  socket_rw_as_user() { return 0; }
  note_tailscaled_auth_visibility 2>/dev/null
  [[ "$TS_LOCALAPI_OK" -eq 0 && "$TS_AUTH_UNKNOWN" -eq 1 ]] ||
    fail "无法实际请求时必须未知：OK=${TS_LOCALAPI_OK} UNKNOWN=${TS_AUTH_UNKNOWN}"

  # 无法请求，但已实际确认服务用户连 socket 都不可读写：确认故障。
  socket_rw_as_user() { return 1; }
  note_tailscaled_auth_visibility 2>/dev/null
  [[ "$TS_LOCALAPI_OK" -eq 0 && "$TS_AUTH_UNKNOWN" -eq 0 ]] ||
    fail "确认 socket 不可读写时应为确认故障：OK=${TS_LOCALAPI_OK} UNKNOWN=${TS_AUTH_UNKNOWN}"
}

# BUG-123：socket 属主正确但权限位为 000 时，不得仅凭属主判定可访问。
test_bug123_socket_owner_without_mode_is_not_access() {
  command -v python3 >/dev/null 2>&1 || { skip "无 python3，Unix socket 未测"; return 0; }
  local ts_sock="$case_tmp/ts3.sock"
  python3 -c 'import socket, sys; s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(sys.argv[1])' "$ts_sock" 2>/dev/null || {
    skip "Unix socket 不可用"
    return 0
  }
  chmod 600 "$ts_sock"
  stat() {
    case "$2" in
      %a) printf '000\n' ;;
      %U) printf 'nobody\n' ;;
      %G) printf 'nogroup\n' ;;
      *) command stat "$@" ;;
    esac
  }
  running_as_root() { return 0; }
  runuser() { return 1; }          # 实际探测：该用户不可读写
  user_can_access_socket nobody "$ts_sock" && fail '属主匹配但权限位 000 不得判为可访问'
  return 0
}


test_bug130_runtime_does_not_accept_other_region_netcheck() {
  IP_ADDR=114.67.236.43 DERP_PORT=30399 STUN_PORT=3478 REGION_ID=901
  ss() { :; }
  nc() { :; }
  tls_probe_endpoints() { echo 127.0.0.1; }
  _timeout_run() { return 0; }
  tailscale() {
    [[ $1 != debug ]] || { echo unexpected-debug-call; return 1; }
    echo 'Nearest DERP: Aliyun DERP (region 900)'
  }
  local out
  out=$(runtime_checks 2>&1)
  [[ "$out" == *'Region 901'* && "$out" == *'不等于'* ]] || fail '其他区域netcheck成功也必须明确901中继未验'
  [[ "$out" != *unexpected-debug-call* ]] || fail '默认客户端校验下不得自动运行随机身份debug derp'
}

test_bug131_manual_feedback_does_not_promise_background_warning() {
  cert_days_remaining() { echo 364; }
  local out
  out=$(print_auto_maintain_feedback manual)
  [[ "$out" != *'临期仍会提示'* ]] || fail 'manual不得无条件承诺后台提醒'
  [[ "$out" == *'执行检查时'* && "$out" == *'没有站外通知'* ]] || fail '必须明确检查触发与通知边界'
}

test_bug132_first_issue_and_existing_rotation_are_distinct() {
  CERT_PRESENT=0 CERT_CHECK_UNKNOWN=0 CERT_KEY_MATCH=1 CERT_NAMING_OK=0
  generate_selfsigned_cert() { :; }
  local out
  out=$(ensure_compatible_certs 2>&1)
  [[ "$out" == *'首次'* && "$out" != *'即将重签'* ]] || fail '首次签发不能提示旧指纹变化'
  CERT_PRESENT=1 CERT_SAN_MATCH=0
  out=$(ensure_compatible_certs 2>&1)
  [[ "$out" == *'即将重签'* ]] || fail '已有证书替换仍需提醒指纹变化'
}

test_deploy_report_has_one_guide_and_actual_target() {
  IP_ADDR=114.67.236.43 DERP_PORT=30399 STUN_PORT=3478 REGION_ID=901 REGION_CODE=jdcloud-derp REGION_NAME='JD Cloud DERP'
  live_cert_sha256_raw() { echo abc123; }
  print_server_node_acl_advice() { :; }
  warn_world_writable_socket() { :; }
  apply_auto_maintain_policy() { :; }
  evaluate_auto_maintain_readiness() { echo manual; }
  maintenance_scheduler_state() { echo absent; }
  cert_days_remaining() { echo 364; }
  cert_not_after() { echo 'Oct 28 00:00:00 2027 GMT'; }
  local out count
  out=$(finalize_deployment_report)
  count=$(printf '%s\n' "$out" | grep -c '客户端验证步骤')
  [[ $count == 1 ]] || fail "客户端说明必须仅一次，实际$count"
  [[ "$out" == *'jdcloud-derp'* && "$out" == *'verify-clients=on'* && "$out" == *'H3='* ]] || fail '摘要须包含实际目标、鉴权与验收层'
  [[ "$out" == *'保留'* && "$out" == *'grants'* && "$out" == *'Regions'* ]] || fail '必须说明策略合并边界'
  [[ "$out" == *'Oct 28 00:00:00 2027 GMT'* && "$out" == *'364'* && "$out" == *'回落'* ]] || fail '摘要须交代到期日期、剩余天数和过期现象'
  [[ "$out" == *'prepare/apply'* && "$out" == *'没有站外通知'* ]] || fail '摘要须给出续期入口和通知边界'
}

test_bug133_region_id_conflict_preflight() {
  command -v python3 >/dev/null 2>&1 || { skip '缺少python3，跳过RegionID解析回归'; return 0; }
  IP_ADDR=114.67.236.43 DERP_PORT=30399 STUN_PORT=3478 REGION_ID=901 ALLOW_REGION_ID_CONFLICT=0
  _timeout_run() { shift; "$@"; }
  local derp_map_fixture rc out
  derp_map_fixture='{"Regions":{"900":{"RegionID":900,"Nodes":[{"HostName":"47.120.74.191","DERPPort":30399,"STUNPort":3478}]}}}'
  tailscale() { printf '%s\n' "$derp_map_fixture"; }
  precheck_region_id_conflict >/dev/null || fail '未占用Region必须允许部署'

  derp_map_fixture='{"Regions":{"901":{"RegionID":901,"RegionCode":"other","Nodes":[{"HostName":"203.0.113.9","DERPPort":443,"STUNPort":3478}]}}}'
  rc=0; out=$(precheck_region_id_conflict 2>&1) || rc=$?
  [[ $rc == 1 && "$out" == *'901'* && "$out" == *'冲突'* ]] || fail "其他节点占用Region必须阻断，rc=$rc out=$out"

  derp_map_fixture='{"Regions":{"901":{"RegionID":901,"Nodes":[{"HostName":"114.67.236.43","DERPPort":30399,"STUNPort":3478}]}}}'
  precheck_region_id_conflict >/dev/null || fail '同一唯一目标必须允许幂等修复'

  derp_map_fixture='{"Regions":{"901":{"RegionID":901,"Nodes":[{"HostName":"114.67.236.43","DERPPort":30399,"STUNPort":3478},{"HostName":"203.0.113.9","DERPPort":443,"STUNPort":3478}]}}}'
  rc=0; precheck_region_id_conflict >/dev/null 2>&1 || rc=$?
  [[ $rc == 1 ]] || fail '多节点Region不能被当成同一单节点目标'
  ALLOW_REGION_ID_CONFLICT=1
  out=$(precheck_region_id_conflict 2>&1) || fail '显式放行后应保留人工合并路径'
  [[ "$out" == *'显式放行'* ]] || fail '显式冲突放行必须留下警告'

  ALLOW_REGION_ID_CONFLICT=0; derp_map_fixture='not-json'; rc=0
  out=$(precheck_region_id_conflict 2>&1) || rc=$?
  [[ $rc == 2 && "$out" == *'无法确认'* ]] || fail '解析失败必须报告未知，不能冒充无冲突'
}

test_bug133_region_conflict_opt_in_is_explicit() {
  ALLOW_REGION_ID_CONFLICT=0
  parse_args --allow-region-id-conflict
  [[ "$ALLOW_REGION_ID_CONFLICT" == 1 ]] || fail '冲突放行只能由显式CLI选项开启'
}

test_bug134_region_structure_anomalies_are_unknown() {
  command -v python3 >/dev/null 2>&1 || { skip '缺少python3，跳过Region结构回归'; return 0; }
  IP_ADDR=114.67.236.43 DERP_PORT=30399 STUN_PORT=3478 REGION_ID=901 ALLOW_REGION_ID_CONFLICT=0
  _timeout_run() { shift; "$@"; }
  local derp_map_fixture rc out
  tailscale() { printf '%s\n' "$derp_map_fixture"; }
  for derp_map_fixture in \
    '[]' \
    '{"Regions":{"901":null}}' \
    '{"Regions":{"901":{"Nodes":[null]}}}'; do
    rc=0
    out=$(precheck_region_id_conflict 2>&1) || rc=$?
    [[ $rc == 2 && "$out" == *'无法确认'* ]] ||
      fail "异常Region结构必须统一报告未知，fixture=$derp_map_fixture rc=$rc out=$out"
  done

  derp_map_fixture='{"Regions":{}}'
  precheck_region_id_conflict >/dev/null || fail 'Region字段不存在才表示未占用'
}

test_bug135_same_target_checks_explicit_ipv4() {
  command -v python3 >/dev/null 2>&1 || { skip '缺少python3，跳过显式IPv4回归'; return 0; }
  IP_ADDR=114.67.236.43 DERP_PORT=30399 STUN_PORT=3478 REGION_ID=901 ALLOW_REGION_ID_CONFLICT=0
  _timeout_run() { shift; "$@"; }
  local derp_map_fixture rc out
  tailscale() { printf '%s\n' "$derp_map_fixture"; }

  derp_map_fixture='{"Regions":{"901":{"Nodes":[{"HostName":"114.67.236.43","IPv4":"203.0.113.9","DERPPort":30399,"STUNPort":3478}]}}}'
  rc=0
  out=$(precheck_region_id_conflict 2>&1) || rc=$?
  [[ $rc == 1 && "$out" == *'冲突'* ]] ||
    fail "HostName相同但显式IPv4不同必须阻断，rc=$rc out=$out"

  derp_map_fixture='{"Regions":{"901":{"Nodes":[{"HostName":"114.67.236.43","IPv4":"114.67.236.43","DERPPort":30399,"STUNPort":3478}]}}}'
  precheck_region_id_conflict >/dev/null || fail '显式IPv4也相同的唯一目标必须允许幂等'
}

test_bug136_independent_module_query_removes_readonly_cache() {
  mkdir -p "$case_tmp/independent-go-bin"
  GO_ROOT_CAPTURE="$case_tmp/independent-go-root"
  export GO_ROOT_CAPTURE
  cat >"$case_tmp/independent-go-bin/go" <<'SH'
#!/bin/sh
module_dir="${GOMODCACHE}/tailscale.com@v1.104.4"
mkdir -p "$module_dir"
printf 'module cache\n' >"$module_dir/cache.txt"
chmod 444 "$module_dir/cache.txt"
chmod 555 "$module_dir"
printf '%s\n' "${GOMODCACHE%/gopath/pkg/mod}" >"$GO_ROOT_CAPTURE"
printf 'v1.104.4\n'
SH
  chmod +x "$case_tmp/independent-go-bin/go"
  PATH="$case_tmp/independent-go-bin:$PATH"
  _tmpdir=''
  _run_with_progress() { shift 3; "$@"; }
  local out rc=0 build_root
  out=$(resolve_derper_module_version abcdef1234567890 2>&1) || rc=$?
  build_root=$(cat "$GO_ROOT_CAPTURE")
  [[ $rc == 0 && "$out" == *'v1.104.4'* ]] ||
    fail "独立版本查询本身必须成功，rc=$rc out=$out"
  if [[ -d "$build_root" ]]; then
    chmod -R u+w "$build_root" 2>/dev/null || true
    rm -rf "$build_root"
    fail '独立版本查询必须清理Go默认创建的只读模块目录'
  fi
}

test_go_build_cache_stays_out_of_caller_home() {
  local build_root="$case_tmp/go-build-test"
  mkdir -p "$build_root/tmp" "$build_root/caller-home" "$build_root/bin"
  _tmpdir="$build_root/tmp"
  DEPLOY_STATE_DIR="$build_root/state"
  DERPER_VERSION=v1.104.4 LOCAL_BINARY='' GOPROXY_ARG='' GOSUMDB_ARG='' GOTOOLCHAIN_ARG=auto
  HOME="$build_root/caller-home"
  GO_ENV_CAPTURE="$build_root/env"
  export GO_ENV_CAPTURE
  cat >"$build_root/bin/go" <<'SH'
#!/bin/sh
{
  printf 'GOPATH=%s\n' "${GOPATH:-}"
  printf 'GOMODCACHE=%s\n' "${GOMODCACHE:-}"
  printf 'GOCACHE=%s\n' "${GOCACHE:-}"
  printf 'GOTMPDIR=%s\n' "${GOTMPDIR:-}"
  printf 'TMPDIR=%s\n' "${TMPDIR:-}"
} >"$GO_ENV_CAPTURE"
if [ -n "${GOBIN:-}" ]; then
  : >"$GOBIN/derper"
  chmod +x "$GOBIN/derper"
else
  printf 'v1.104.4\n'
fi
SH
  chmod +x "$build_root/bin/go"
  PATH="$build_root/bin:$PATH"
  precheck_go_network() { :; }
  ensure_go() { :; }
  publish_derper_candidate() { :; }
  _run_with_progress() { shift 3; "$@"; }
  install_derper >/dev/null
  local env_text
  env_text=$(cat "$GO_ENV_CAPTURE")
  [[ "$env_text" == *"GOPATH=${_tmpdir}/go-build/gopath"* ]] || fail "GOPATH必须位于本次临时目录：$env_text"
  [[ "$env_text" == *"GOMODCACHE=${_tmpdir}/go-build/gopath/pkg/mod"* ]] || fail "模块缓存不得写入调用者home：$env_text"
  [[ "$env_text" == *"GOCACHE=${_tmpdir}/go-build/cache"* ]] || fail "编译缓存不得写入调用者home：$env_text"
  [[ "$env_text" == *"GOTMPDIR=${_tmpdir}/go-work"* && "$env_text" == *"TMPDIR=${_tmpdir}"* ]] ||
    fail 'Go构建工作文件也必须使用经过空间预检的临时目录'
  resolve_derper_module_version abcdef1234567890 >/dev/null
  env_text=$(cat "$GO_ENV_CAPTURE")
  [[ "$env_text" == *"GOPATH=${_tmpdir}/go-build/gopath"* && "$env_text" == *"GOMODCACHE=${_tmpdir}/go-build/gopath/pkg/mod"* && "$env_text" == *"GOCACHE=${_tmpdir}/go-build/cache"* ]] ||
    fail "同源版本查询也必须使用临时Go缓存：$env_text"
  [[ "$env_text" == *"GOTMPDIR=${_tmpdir}/go-work"* && "$env_text" == *"TMPDIR=${_tmpdir}"* ]] ||
    fail 'Go版本查询工作文件也必须使用经过空间预检的临时目录'
}

test_bug138_scheduled_healthcheck_preserves_config_and_region() {
  mkdir -p "$case_tmp/relative config"
  cd "$case_tmp"
  CONFIG_FILE='relative config/target.conf'
  IP_ADDR=114.67.236.43 DERP_PORT=30399 STUN_PORT=3478
  REGION_ID=901 REGION_CODE=jdcloud-derp REGION_NAME='JD Cloud DERP'
  SECURITY_LEVEL=standard VERIFY_CLIENTS_MODE=on ALLOW_NON_GLOBAL_IP=0
  EXTERNAL_PROBE='' REQUIRE_H3=0 HEALTH_STATE_FILE="$case_tmp/status.json"
  render_healthcheck_commands /usr/local/lib/derper-deploy/deploy_derper_ip_selfsigned.sh "$IP_ADDR" "$case_tmp/metrics.prom"

  # macOS 的 /var 是符号链接，实现按物理路径解析；两种绝对写法都指向同一文件。
  local absolute_config="$case_tmp/relative config/target.conf"
  local physical_config
  physical_config="$(cd "$case_tmp/relative config" && pwd -P)/target.conf"
  local arg previous='' config_seen=0 region_id_seen=0 region_code_seen=0 region_name_seen=0
  eval "set -- $BASH_HEALTHCHECK_CMD"
  for arg in "$@"; do
    [[ "$previous" != --config || ( "$arg" != "$absolute_config" && "$arg" != "$physical_config" ) ]] || config_seen=1
    [[ "$previous" != --region-id || "$arg" != 901 ]] || region_id_seen=1
    [[ "$previous" != --region-code || "$arg" != jdcloud-derp ]] || region_code_seen=1
    [[ "$previous" != --region-name || "$arg" != 'JD Cloud DERP' ]] || region_name_seen=1
    previous=$arg
  done
  [[ "$config_seen$region_id_seen$region_code_seen$region_name_seen" == 1000 ]] ||
    fail "cron只能继承绝对配置路径，不能用重复Region参数覆盖配置：$BASH_HEALTHCHECK_CMD"

  local escaped_config escaped_physical
  escaped_config=$(systemd_escape_arg "$absolute_config")
  escaped_physical=$(systemd_escape_arg "$physical_config")
  [[ ( "$SYSTEMD_HEALTHCHECK_EXEC" == *" --config $escaped_config"* ||
       "$SYSTEMD_HEALTHCHECK_EXEC" == *" --config $escaped_physical"* ) &&
     "$SYSTEMD_HEALTHCHECK_EXEC" != *' --region-id '* ]] ||
    fail "systemd只能继承绝对配置路径，不能用重复Region参数覆盖配置：$SYSTEMD_HEALTHCHECK_EXEC"

  CONFIG_FILE='' REGION_ID=902 REGION_CODE=other-derp REGION_NAME='Other DERP'
  EXTERNAL_PROBE="$case_tmp/probe" REQUIRE_H3=0
  render_healthcheck_commands /usr/local/lib/derper-deploy/deploy_derper_ip_selfsigned.sh "$IP_ADDR" "$case_tmp/metrics.prom"
  [[ "$BASH_HEALTHCHECK_CMD" != *' --config '* && "$SYSTEMD_HEALTHCHECK_EXEC" != *' --config '* ]] ||
    fail '未使用配置文件时不得生成空--config'
  [[ "$BASH_HEALTHCHECK_CMD" == *' --region-id 902 --region-code other-derp --region-name Other\ DERP'* &&
     "$SYSTEMD_HEALTHCHECK_EXEC" == *' --region-id 902 --region-code other-derp --region-name "Other DERP"'* ]] ||
    fail '无配置文件且启用H3时也必须只继承同一套Region参数'
  [[ "$(printf '%s\n' "$BASH_HEALTHCHECK_CMD" | grep -o -- '--region-id' | wc -l)" -eq 1 &&
     "$(printf '%s\n' "$SYSTEMD_HEALTHCHECK_EXEC" | grep -o -- '--region-id' | wc -l)" -eq 1 ]] ||
    fail 'H3分支不得重复附加RegionID'
}

test_bug139_readonly_go_cache_is_cleaned_and_empty_tmpdir_refused() {
  _tmpdir="$case_tmp/deploy-tmp"
  mkdir -p "$_tmpdir/go-build/gopath/pkg/mod/example.com/mod@v1.0.0" "$_tmpdir/go-build/cache"
  printf 'x\n' >"$_tmpdir/go-build/gopath/pkg/mod/example.com/mod@v1.0.0/file"
  chmod 444 "$_tmpdir/go-build/gopath/pkg/mod/example.com/mod@v1.0.0/file"
  chmod 555 "$_tmpdir/go-build/gopath/pkg/mod/example.com/mod@v1.0.0"
  cleanup_deployment 0
  if [[ -e "$_tmpdir" ]]; then
    chmod -R u+w "$_tmpdir" 2>/dev/null || true
    rm -rf "$_tmpdir"
    fail "退出清理必须删除只读Go模块缓存目录，实际残留 ${_tmpdir}"
  fi

  local rc=0 out=''
  out=$( ( _tmpdir='' ; install_derper ) 2>&1 ) || rc=$?
  [[ "$rc" -ne 0 && "$out" == *"安全临时目录未初始化"* ]] ||
    fail "临时目录未初始化时必须拒绝构建而不是写入根目录，rc=$rc out=$out"
}

test_bug141_region_preflight_allows_port_change_and_unknown_for_empty_input() {
  command -v python3 >/dev/null 2>&1 || { skip '缺少python3，跳过Region改端口回归'; return 0; }
  IP_ADDR=114.67.236.43 DERP_PORT=443 STUN_PORT=3478 REGION_ID=901 ALLOW_REGION_ID_CONFLICT=0
  _timeout_run() { shift; "$@"; }
  local derp_map_fixture rc out
  tailscale() { printf '%s\n' "$derp_map_fixture"; }

  derp_map_fixture='{"Regions":{"901":{"Nodes":[{"HostName":"114.67.236.43","IPv4":"114.67.236.43","DERPPort":30399,"STUNPort":3478}]}}}'
  out=$(precheck_region_id_conflict 2>&1) || fail '同一机器仅改端口不能被当成其他节点占用'
  [[ "$out" == *'端口'* && "$out" == *'同步'* ]] || fail '改端口放行时应提示同步控制面端口'

  derp_map_fixture='{"Regions":{"901":{"Nodes":[]}}}'
  rc=0; out=$(precheck_region_id_conflict 2>&1) || rc=$?
  [[ $rc == 2 && "$out" == *'无法确认'* ]] || fail "空Nodes必须返回未知而不是确认冲突，rc=$rc out=$out"

  IP_ADDR=''
  derp_map_fixture='{"Regions":{"901":{"Nodes":[{"HostName":"203.0.113.9","DERPPort":30399,"STUNPort":3478}]}}}'
  rc=0; out=$(precheck_region_id_conflict 2>&1) || rc=$?
  [[ $rc == 2 && "$out" == *'无法确认'* ]] || fail "IP未探测到时必须返回未知，rc=$rc out=$out"
}

test_bug142_deployment_report_restores_minimum_acl_advice() {
  IP_ADDR=114.67.236.43 DERP_PORT=30399 STUN_PORT=3478 REGION_ID=901 REGION_CODE=jdcloud-derp REGION_NAME='JD Cloud DERP'
  live_cert_sha256_raw() { echo abc123; }
  warn_world_writable_socket() { :; }
  apply_auto_maintain_policy() { :; }
  evaluate_auto_maintain_readiness() { echo manual; }
  maintenance_scheduler_state() { echo absent; }
  cert_days_remaining() { echo 364; }
  cert_not_after() { echo 'Oct 28 00:00:00 2027 GMT'; }
  systemctl() { return 1; }
  local out
  out=$(finalize_deployment_report)
  [[ "$out" == *'服务器节点在 Tailnet 内的身份'* && "$out" == *'tag:derper-server'* && "$out" == *'tagOwners'* ]] ||
    fail '部署收尾必须实际打印服务器节点最小授权建议'
  grep -q 'tag:derper-server' "$ROOT_DIR/docs/MAINTENANCE_CN.md" || fail '中文维护文档必须包含最小授权建议'
  grep -q 'tag:derper-server' "$ROOT_DIR/docs/MAINTENANCE_EN.md" || fail '英文维护文档必须包含最小授权建议'
}

test_bug143_go_cache_is_persistent_and_space_checked() {
  _tmpdir="$case_tmp/var-tmp"
  DERPER_GO_BUILD_CACHE_DIR="$case_tmp/root-cache/go-build"
  DERPER_GO_MIN_FREE_KB=1
  mkdir -p "$_tmpdir"
  id() { echo 0; }
  stat() {
    if [[ "$2" == %u ]]; then echo 0; else command stat "$@"; fi
  }
  [[ "$(go_build_cache_root)" == "$DERPER_GO_BUILD_CACHE_DIR" ]] || fail 'root构建必须使用磁盘持久缓存目录'
  prepare_go_build_root || fail '空间充足时Go构建目录预检必须成功'
  [[ -d "$DERPER_GO_BUILD_CACHE_DIR/gopath/pkg/mod" && -d "$DERPER_GO_BUILD_CACHE_DIR/cache" ]] ||
    fail 'Go模块与编译缓存目录必须预先创建'
  df() {
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
    printf '/dev/fake 1024 1024 0 100%% /var/tmp\n'
  }
  if prepare_go_build_root >/dev/null 2>&1; then fail '空间不足必须在下载工具链和构建前阻断'; fi
}

test_adj037_healthcheck_uses_stable_config_only() {
  HEALTHCHECK_CRON_PATH="$case_tmp/derper-healthcheck"
  HEALTHCHECK_UNIT_DIR="$case_tmp/units"
  HEALTHCHECK_PROGRAM_DIR="$case_tmp/stable"
  IP_ADDR=114.67.236.43 DERP_PORT=30399 STUN_PORT=3478
  REGION_ID=901 REGION_CODE=jdcloud-derp REGION_NAME='JD Cloud DERP'
  SECURITY_LEVEL=standard VERIFY_CLIENTS_MODE=on ALLOW_NON_GLOBAL_IP=0
  EXTERNAL_PROBE='' REQUIRE_H3=0 METRICS_TEXTFILE="$case_tmp/metrics.prom"
  CONFIG_FILE="$case_tmp/source.conf"
  printf 'CONFIG_VERSION=1\nIP_ADDR=114.67.236.43\nREGION_ID=901\n' >"$CONFIG_FILE"
  SCRIPT_SELF="$case_tmp/deploy.sh"
  printf '#!/bin/bash\n' >"$SCRIPT_SELF"
  command() {
    if [[ "$1" == -v && "$2" == systemctl ]]; then return 1; fi
    builtin command "$@"
  }
  install_healthcheck_cron || fail '带配置的cron安装必须成功'
  local stable_config="$HEALTHCHECK_PROGRAM_DIR/target.conf" cron
  cron=$(cat "$HEALTHCHECK_CRON_PATH")
  [[ -f "$stable_config" && "$cron" == *" --config $stable_config"* ]] || fail '调度必须使用root管理的稳定配置副本'
  [[ "$cron" != *' --ip '* && "$cron" != *' --derp-port '* && "$cron" != *' --region-id '* ]] ||
    fail '使用配置时不得再用重复CLI参数覆盖配置'

  unset -f command
  systemctl() { return 0; }
  install_healthcheck_cron || fail '带配置的timer安装必须成功'
  local svc
  svc=$(cat "$HEALTHCHECK_UNIT_DIR/derper-healthcheck.service")
  [[ "$svc" == *" --config $stable_config"* && "$svc" != *' --ip '* && "$svc" != *' --region-id '* ]] ||
    fail 'systemd也只能使用稳定配置作为目标来源'
  rm -f "$CONFIG_FILE"
  [[ -f "$stable_config" ]] || fail '原配置移走后稳定配置必须仍然存在'
}

test_adj037_report_health_summary_order_and_not_installed() {
  IP_ADDR=114.67.236.43 DERP_PORT=30399 STUN_PORT=3478 REGION_ID=901 REGION_CODE=jdcloud-derp REGION_NAME='JD Cloud DERP'
  live_cert_sha256_raw() { echo abc123; }
  print_server_node_acl_advice() { :; }
  warn_world_writable_socket() { :; }
  apply_auto_maintain_policy() { :; }
  evaluate_auto_maintain_readiness() { echo manual; }
  maintenance_scheduler_state() { echo absent; }
  cert_days_remaining() { echo 364; }
  cert_not_after() { echo 'Oct 28 00:00:00 2027 GMT'; }
  systemctl() { return 1; }
  local out health_pos next_pos
  out=$(finalize_deployment_report)
  [[ "$out" == *'健康检查调度：timer=未安装'* ]] || fail '未安装timer不得显示成inactive'
  health_pos=$(printf '%s\n' "$out" | grep -n '健康检查调度' | cut -d: -f1)
  next_pos=$(printf '%s\n' "$out" | grep -n '^下一步：' | cut -d: -f1)
  [[ -n "$health_pos" && -n "$next_pos" && "$health_pos" -lt "$next_pos" ]] ||
    fail '健康检查调度必须位于下一步之前'
}

test_bug143_module_query_checks_both_filesystems_before_go() {
  local mode failed_path rc
  go() { :; }
  stat() { if [[ "$2" == %u ]]; then echo 0; else command stat "$@"; fi; }
  _run_with_progress() { touch "$case_tmp/query-ran"; echo v1.104.4; }
  DERPER_GO_BUILD_CACHE_DIR="$case_tmp/persistent-cache"
  DERPER_GO_MIN_FREE_KB=1024
  for mode in root user; do
    for failed_path in temp cache; do
      (
        id() { if [[ "$mode" == root ]]; then echo 0; else echo 1000; fi; }
        _tmpdir="$case_tmp/$mode-$failed_path"
        mkdir -p "$_tmpdir"
        df() {
          local available=4096
          if [[ ( "$failed_path" == temp && "$2" == "$_tmpdir" ) ||
                ( "$failed_path" == cache && "$2" != "$_tmpdir" ) ]]; then available=0; fi
          printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
          printf '/dev/test 4096 0 %s 0%% /var/tmp\n' "$available"
        }
        rc=0
        resolve_derper_module_version abcdef >"$case_tmp/query-out" 2>"$case_tmp/query-err" || rc=$?
        [[ "$rc" -ne 0 ]] || fail "${mode}查询在${failed_path}空间不足时必须失败"
        [[ ! -e "$case_tmp/query-ran" ]] || fail '空间检查失败前不得运行Go查询'
        grep -q '空间不足' "$case_tmp/query-err" || fail '应保留空间不足诊断'
        [[ ! -s "$case_tmp/query-out" ]] || fail '失败不得输出伪版本号'
      ) || return 1
    done
  done
}

test_bug143_module_query_rejects_untrusted_root_cache() {
  go() { :; }
  id() { echo 0; }
  _tmpdir="$case_tmp/query-tmp"
  mkdir -p "$_tmpdir" "$case_tmp/foreign-cache"
  DERPER_GO_BUILD_CACHE_DIR="$case_tmp/foreign-cache"
  stat() { if [[ "$2" == %u ]]; then echo 1000; else command stat "$@"; fi; }
  _run_with_progress() { touch "$case_tmp/query-ran"; }
  if resolve_derper_module_version abcdef >/dev/null 2>&1; then fail 'root版本查询必须拒绝他人所有的缓存'; fi
  [[ ! -e "$case_tmp/query-ran" ]] || fail '属主不可信时不得运行Go查询'
  ln -s "$case_tmp/foreign-cache" "$case_tmp/cache-link"
  DERPER_GO_BUILD_CACHE_DIR="$case_tmp/cache-link"
  if resolve_derper_module_version abcdef >/dev/null 2>&1; then fail 'root版本查询必须拒绝链接缓存'; fi
}

test_bug143_standalone_root_query_preflights_and_preserves_cache() {
  go() { :; }
  id() { echo 0; }
  stat() { if [[ "$2" == %u ]]; then echo 0; else command stat "$@"; fi; }
  _tmpdir=''
  DERPER_GO_BUILD_CACHE_DIR="$case_tmp/persistent-cache"
  mkdir -p "$DERPER_GO_BUILD_CACHE_DIR"
  printf retained >"$DERPER_GO_BUILD_CACHE_DIR/existing"
  df() {
    printf '%s\n' "$2" >>"$case_tmp/checked-paths"
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
    printf '/dev/test 4194304 0 4194304 0%% /var/tmp\n'
  }
  _run_with_progress() { printf 'v1.104.4\n'; }
  local result query_tmp
  result=$(resolve_derper_module_version abcdef) || fail '独立root查询应创建临时目录并成功'
  [[ "$result" == v1.104.4 ]] || fail '版本查询stdout须只含版本'
  [[ -s "$case_tmp/checked-paths" ]] || fail '独立查询也必须运行空间预检'
  query_tmp=$(head -n1 "$case_tmp/checked-paths")
  [[ "$query_tmp" == /var/tmp/derper-go-query.* && ! -e "$query_tmp" ]] || fail '查询私有临时目录应在退出后清理'
  [[ -f "$DERPER_GO_BUILD_CACHE_DIR/existing" ]] || fail '不得删除持久缓存'
  [[ -z "$_tmpdir" ]] || fail '独立查询不得改变调用者临时目录变量'

  : >"$case_tmp/checked-paths"
  df() {
    printf '%s\n' "$2" >>"$case_tmp/checked-paths"
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
    printf '/dev/test 4194304 4194304 0 100%% /var/tmp\n'
  }
  if resolve_derper_module_version abcdef >/dev/null 2>&1; then fail '独立查询空间不足必须失败'; fi
  query_tmp=$(head -n1 "$case_tmp/checked-paths")
  [[ "$query_tmp" == /var/tmp/derper-go-query.* && ! -e "$query_tmp" ]] || fail '预检失败也必须清理查询临时目录'
  [[ -f "$DERPER_GO_BUILD_CACHE_DIR/existing" ]] || fail '预检失败不得清理持久缓存'
}

tests=(
  test_bug143_module_query_checks_both_filesystems_before_go
  test_bug143_module_query_rejects_untrusted_root_cache
  test_bug143_standalone_root_query_preflights_and_preserves_cache
  test_adj037_report_health_summary_order_and_not_installed
  test_adj037_healthcheck_uses_stable_config_only
  test_bug143_go_cache_is_persistent_and_space_checked
  test_bug142_deployment_report_restores_minimum_acl_advice
  test_bug141_region_preflight_allows_port_change_and_unknown_for_empty_input
  test_bug139_readonly_go_cache_is_cleaned_and_empty_tmpdir_refused
  test_bug138_scheduled_healthcheck_preserves_config_and_region
  test_go_build_cache_stays_out_of_caller_home
  test_bug136_independent_module_query_removes_readonly_cache
  test_bug135_same_target_checks_explicit_ipv4
  test_bug134_region_structure_anomalies_are_unknown
  test_bug133_region_id_conflict_preflight
  test_bug133_region_conflict_opt_in_is_explicit
  test_bug130_runtime_does_not_accept_other_region_netcheck
  test_bug131_manual_feedback_does_not_promise_background_warning
  test_bug132_first_issue_and_existing_rotation_are_distinct
  test_deploy_report_has_one_guide_and_actual_target
  test_b1_incomplete_marker_blocks_and_is_not_executed
  test_b1_lock_failure_blocks_second_change
  test_b1_second_process_cannot_take_lock
  test_b1_unverified_staging_keeps_only_backup
  test_b2_bad_candidate_and_disk_failure_keep_live_binary
  test_b2_stopped_intent_is_not_started
  test_b2_daemon_drift_stays_manual
  test_b2_first_install_failure_has_no_fake_previous
  test_b2_rollback_restores_config_and_state
  test_b2_reverify_failure_keeps_recovery
  test_b2_build_timeout_keeps_live_binary
  test_b3_migration_failure_restores_running_service
  test_bug054_restore_does_not_follow_state_symlink
  test_bug054_restore_refuses_symlink_state_directory
  test_bug055_same_origin_candidate_passes_daemon_gate
  test_bug056_rollback_reloads_process_and_keeps_marker_on_stop_failure
  test_bug057_migration_failure_keeps_recovery_marker
  test_bug058_migrated_config_is_owned_by_run_user
  test_b3_layout_blocks_cert_rename_and_keeps_identity
  test_bug051_failure_before_activation_needs_no_stop
  test_bug050_failed_timer_update_restores_stopped_state
  test_bug051_incomplete_files_do_not_restart_timer
  test_bug047_backup_copy_failure_keeps_original_units
  test_bug048_sendq_is_not_main_pid
  test_bug049_cron_delete_failure_rolls_back_timer
  test_bug049_timer_delete_failure_rolls_back_cron
  test_bug050_timer_rollback_restores_previous_runtime_state
  test_bug051_restore_failure_keeps_snapshot
  test_bug038_verify_clients_dependency_is_not_healthy
  test_bug038_localapi_403_is_unhealthy
  test_bug039_mismatched_key_blocks_restart
  test_doc007_008_wording
  test_bug109_ss_interface_scoped_loopback
  test_bug109_netstat_interface_scoped_loopback
  test_reference_hardening_matches_generated_unit
  test_doc008_unsearchable_cert_dir_is_unknown
  test_bug034_generated_task_survives_unexecutable_source
  test_bug034_timer_replaces_cron_once
  test_metrics_failure_keeps_old_sample
  test_bug035_nft_rule_failure_keeps_old_rules
  test_bug035_iptables_append_failure_keeps_old_rules
  test_bug035_iptables_restore_failure_is_incomplete
  test_bug035_snapshot_read_failure_preserves_rules
  test_bug040_port_conflicts_follow_protocol
  test_bug040_ownership_matches_protocol_and_pid
  test_bug043_044_port_ownership_pid_and_netstat
  test_bug041_contradictory_modes_stop_before_side_effects
  test_numeric_args_are_canonical_after_validation
  test_health_check_exit_codes_keep_old_callers_safe
  test_legacy_symlink_migration
  test_cleanup_restarts_previously_running_service
  test_new_root_default
  test_real_certificate_write_failure
  test_interrupted_rollback
  test_rotation_decline_preserves_certificate
  test_module_query_preserves_network_settings
  test_explicit_user
  test_existing_user
  test_commit_versions
  test_certificate_resume
  test_rotation_requires_ack
  test_certificate_rollback
  test_recover_restart_failure_is_warning
  test_bug042_timer_installation_failure_retains_cron
  test_bug042_existing_timer_update_failure_restores_old_units
  test_bug045_timer_execstart_uses_proper_systemd_quoting
  test_bug046_all_firewall_deletions_fail_propagates_error
  test_bug046_mixed_backend_remove_failure_propagates_error
  test_bug117_default_deploy_gates_confirmed_localapi_failure
  test_bug117_default_deploy_still_succeeds_when_healthy
  test_bug122_localapi_checks_derper_service_user
  test_bug123_localapi_must_be_requested_as_service_user
  test_bug123_socket_owner_without_mode_is_not_access
)
if [[ "$#" -gt 0 ]]; then
  tests=("$@")
fi
failed=0
for test_name in "${tests[@]}"; do
  if (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    case_tmp=$(mktemp -d)
    SERVICE_PATH="$case_tmp/derper.service"
    trap 'rm -rf "$case_tmp"' EXIT
    "$test_name"
  ); then
    echo "ok - $test_name"
  else
    echo "not ok - $test_name" >&2
    failed=$((failed + 1))
  fi
done
if [[ "$failed" -ne 0 ]]; then
  echo "review regressions: ${failed} failed" >&2
  exit 1
fi
