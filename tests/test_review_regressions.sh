#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/deploy_derper_ip_selfsigned.sh"
fail() { echo "not ok - $*" >&2; exit 1; }
skip() { echo "ok - $*"; }

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
  timeout() { shift; "$@"; }
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
        [[ "$(cat "$timer_runtime")" == "$original_runtime" ]] || fail "必须恢复原运行状态 $original_runtime：$(cat "$timer_calls")"
        [[ "$(cat "$timer_enabled")" == "$original_enabled" ]] || fail "必须恢复原启用状态 $original_enabled：$(cat "$timer_calls")"
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

for test_name in test_bug051_failure_before_activation_needs_no_stop test_bug050_failed_timer_update_restores_stopped_state test_bug051_incomplete_files_do_not_restart_timer test_bug047_backup_copy_failure_keeps_original_units test_bug048_sendq_is_not_main_pid test_bug049_cron_delete_failure_rolls_back_timer test_bug049_timer_delete_failure_rolls_back_cron test_bug050_timer_rollback_restores_previous_runtime_state test_bug051_restore_failure_keeps_snapshot test_bug038_verify_clients_dependency_is_not_healthy test_bug038_localapi_403_is_unhealthy test_bug039_mismatched_key_blocks_restart test_doc007_008_wording test_doc008_unsearchable_cert_dir_is_unknown test_bug034_generated_task_survives_unexecutable_source test_bug034_timer_replaces_cron_once test_metrics_failure_keeps_old_sample test_bug035_nft_rule_failure_keeps_old_rules test_bug035_iptables_append_failure_keeps_old_rules test_bug035_iptables_restore_failure_is_incomplete test_bug035_snapshot_read_failure_preserves_rules test_bug040_port_conflicts_follow_protocol test_bug040_ownership_matches_protocol_and_pid test_bug043_044_port_ownership_pid_and_netstat test_bug041_contradictory_modes_stop_before_side_effects test_numeric_args_are_canonical_after_validation test_health_check_exit_codes_keep_old_callers_safe test_legacy_symlink_migration test_cleanup_restarts_previously_running_service test_new_root_default test_real_certificate_write_failure test_interrupted_rollback test_rotation_decline_preserves_certificate test_module_query_preserves_network_settings test_explicit_user test_existing_user test_commit_versions test_certificate_resume test_rotation_requires_ack test_certificate_rollback test_recover_restart_failure_is_warning test_bug042_timer_installation_failure_retains_cron test_bug042_existing_timer_update_failure_restores_old_units test_bug045_timer_execstart_uses_proper_systemd_quoting test_bug046_all_firewall_deletions_fail_propagates_error test_bug046_mixed_backend_remove_failure_propagates_error; do
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
    exit 1
  fi
done
