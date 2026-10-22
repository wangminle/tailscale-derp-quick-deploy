#!/usr/bin/env bash
# C 阶段契约与行为回归：配置白名单与新旧 CLI、本地 ELF 导入、JSON/derpMap、
# H0～H3 分层、状态原子性与发布门禁。JSON 校验需要 python3，ELF 导入用例需要 gcc。
# root 专属用例以退出码 77 跳过并由 root 单独补跑；可传测试函数名单独运行。
# 退出码 0=全部通过，1=有失败，77=该用例需 root。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/deploy_derper_ip_selfsigned.sh"
fail() { echo "not ok - $*" >&2; exit 1; }
test_config_precedence() {
  printf 'CONFIG_VERSION=1\nIP_ADDR=47.120.74.191\nDERP_PORT=443\nREGION_NAME=中文中继\nVERIFY_CLIENTS_MODE=off\n' >"$tmp/deploy.conf"
  parse_args status --config "$tmp/deploy.conf" --derp-port 30443 --format json
  [[ "$DERP_PORT" == 30443 && "$REGION_NAME" == 中文中继 && "$VERIFY_CLIENTS_MODE" == off && "$HEALTH_CHECK" == 1 ]] || fail '配置与CLI优先级或子命令错误'
  validate_arg_combos || fail '合法status被拒绝'
}
test_config_is_data() {
  local content
  for content in 'CONFIG_VERSION=2' $'CONFIG_VERSION=1\nTYPO=yes' $'CONFIG_VERSION=1\nDERP_PORT=443\nDERP_PORT=444' "CONFIG_VERSION=1
REGION_NAME=\$(touch $tmp/pwn)" $'CONFIG_VERSION=1\nTS_AUTHKEY=secret'; do
    printf '%s\n' "$content" >"$tmp/bad.conf"
    if load_deploy_config "$tmp/bad.conf" >/dev/null 2>&1; then fail '接受错误或可执行配置'; fi
  done
  [[ ! -e "$tmp/pwn" && "$DERP_PORT" == 30399 ]] || fail '配置产生副作用/部分赋值'
}
test_command_conflicts() {
  parse_args deploy --uninstall
  if validate_arg_combos >/dev/null 2>&1; then fail 'deploy与卸载未互斥'; fi
}
test_json_escape() {
  local out
  out=$(json_quote $'中文"\\\n\t\001')
  python3 -c 'import json,sys; assert json.loads(sys.argv[1]) == "中文\"\\\n\t\x01"' "$out"
}
test_probe_contract() {
  SAMPLED_AT=$(date +%s)
  IP_ADDR=47.120.74.191
  cat >"$tmp/probe" <<'PROBE'
#!/bin/bash
printf 'schema=1\nregion_id=900\nip=47.120.74.191\nderp_port=30399\nstun_port=3478\nchecked_at=%s\nderp=ok\nstun=ok\n' "$(date +%s)"
PROBE
  chmod 755 "$tmp/probe"
  EXTERNAL_PROBE="$tmp/probe"
  # 普通回归用例只测协议；真实root路径检查另测，VM探针放/root。
  probe_path_is_trusted() { return 0; }
  run_external_probe
  [[ "$H3_STATUS" == healthy ]] || fail '有效探针未通过'
  sed 's/region_id=900/region_id=901/' "$tmp/probe" >"$tmp/probe.new" && mv "$tmp/probe.new" "$tmp/probe" && chmod 755 "$tmp/probe"
  run_external_probe
  [[ "$H3_STATUS" == unknown ]] || fail '接受错误Region'
  EXTERNAL_PROBE=''
  run_external_probe
  [[ "$H3_STATUS" == not_checked ]] || fail '无探针伪造H3'
}
test_metrics_freshness() {
  SAMPLED_AT=$(date +%s)
  METRICS_SOURCE="$tmp/old.prom"
  printf 'derper_metrics_unixtime 1\n' >"$METRICS_SOURCE"
  check_metrics_freshness
  [[ "$METRICS_FRESHNESS" == stale ]] || fail '旧指标未标过期'
  printf 'derper_metrics_unixtime %s\n' "$SAMPLED_AT" >"$METRICS_SOURCE"
  check_metrics_freshness
  [[ "$METRICS_FRESHNESS" == fresh ]] || fail '当前指标未识别'
}
setup_snapshot() {
  H0_STATUS=healthy H1_STATUS=healthy H2_STATUS=not_applicable H3_STATUS=not_checked H3_REASON=probe_not_configured
  METRICS_FRESHNESS=not_checked METRICS_AGE='' HEALTH_SNAPSHOT_READY=1
  SAMPLED_AT=$(date +%s)
  HEALTH_DAYS_LEFT=120 HEALTH_LAST_SUCCESS=0
  IP_ADDR=47.120.74.191
  HEALTH_CERT_SHA256=$(printf '%064d' 1)
  HEALTH_LIVE_SHA256=$HEALTH_CERT_SHA256
}
test_snapshot_outputs_and_gate() {
  setup_snapshot
  REGION_NAME=$'中文"\\节点'
  render_status_json >"$tmp/status.json"
  render_derpmap_json >"$tmp/map.json"
  python3 - "$tmp" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); s=json.loads((p/'status.json').read_text()); m=json.loads((p/'map.json').read_text())['Regions']['900']
assert s['result']=='healthy' and s['layers']['h3']=='not_checked'
assert s['metrics']['age_seconds'] is None and s['target']['region_name']==m['RegionName']
assert m['Nodes'][0]['CertName']=='sha256-raw:'+s['certificate']['live_sha256']
PY
  REQUIRE_H3=1
  [[ "$(snapshot_exit_code)" == 2 ]] || fail '必需H3缺失未阻断'
  H3_STATUS=failed EXTERNAL_PROBE=/explicit
  [[ "$(snapshot_exit_code)" == 1 ]] || fail '外部故障未阻断'
  H3_STATUS=healthy
  [[ "$(snapshot_exit_code)" == 0 ]] || fail '完整健康未通过'
  H1_STATUS=unknown
  [[ "$(snapshot_exit_code)" == 2 ]] || fail '未知被报绿'
}
test_state_atomicity_and_last_success() {
  setup_snapshot
  HEALTH_STATE_FILE="$tmp/status.json"
  write_health_state || fail '状态写入失败'
  H1_STATUS=failed
  load_health_last_success
  [[ "$HEALTH_LAST_SUCCESS" == "$SAMPLED_AT" ]] || fail '最近成功时间丢失'
  write_health_state || fail '故障状态未记录'
  python3 - "$HEALTH_STATE_FILE" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); assert s['result']=='failed' and s['last_success_at']>0
PY
  cp "$HEALTH_STATE_FILE" "$tmp/keep"
  rm "$HEALTH_STATE_FILE"
  ln -s "$tmp/keep" "$HEALTH_STATE_FILE"
  if write_health_state; then fail '状态写入跟随链接'; fi
  python3 - "$tmp/keep" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['result']=='failed'
PY
}
test_single_collection_json() {
  IP_ADDR=47.120.74.191 OUTPUT_FORMAT=json
  infer_ip_from_existing_deployment() { :; }
  infer_healthcheck_settings_from_unit() { :; }
  validate_settings() { return 0; }
  # H0 依赖 systemctl/openssl/ss 存在；桩化使结果与宿主工具无关（macOS 开发机也一致）。
  systemctl() { return 0; }
  openssl() { return 0; }
  ss() { return 0; }
  check_tailscale_status() { echo ts >>"$tmp/calls"; TS_RUNNING=0; }
  check_derper_status() {
    echo derp >>"$tmp/calls"
    DERPER_RUNNING=1 PORT_TLS_OK=1 PORT_STUN_OK=1 PURE_IP_OK=1 DESIRED_CONFIG_OK=1
    CURRENT_DERPER_OWNS_PORTS=1 DERPER_VERIFY_CLIENTS_EFFECTIVE=0
  }
  check_cert_status() { echo cert >>"$tmp/calls"; CERT_PRESENT=1 CERT_NAMING_OK=1 CERT_SAN_MATCH=1 CERT_EXPIRY_OK=1; }
  check_live_cert_status() { echo live >>"$tmp/calls"; LIVE_CERT_CHECKED=1 CERT_LIVE_MATCH=1; }
  cert_days_remaining() { echo 120; }
  health_check_report >"$tmp/out.json"
  [[ "$(wc -l <"$tmp/calls" | tr -d '[:space:]')" == 4 ]] || fail '重复采集'
  python3 - "$tmp/out.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); assert s['result']=='healthy' and s['layers']['h3']=='not_checked'
PY
}
test_import_elf_version_hash_and_publish() {
  command -v gcc >/dev/null || fail '本套件需要gcc构造真实ELF'
  DEPLOY_STATE_DIR="$tmp/deploy"
  BIN_PATH="$tmp/live"
  VERIFY_CLIENTS_MODE=off
  DERPER_VERSION=v1.104.1
  cat >"$tmp/fixture.c" <<'C'
#include <stdio.h>
int main(void) { puts("mod\ttailscale.com\tv1.104.1\n-a addr\n-c file\n-certdir dir\n-certmode mode\n-stun\n-stun-port port"); return 0; }
C
  gcc "$tmp/fixture.c" -o "$tmp/fixture" || fail '编译fixture失败'
  LOCAL_BINARY="$tmp/fixture"
  printf 'old\n' >"$BIN_PATH"
  # 此用例测产物与B发布连接；持久服务恢复在VM中验证。
  SERVICE_PATH="$tmp/unit" INSTALL_DIR="$tmp/install"
  mkdir -p "$INSTALL_DIR"
  current_service_run_intent() { echo inactive; }
  import_local_derper >/dev/null || fail '有效ELF未导入'
  [[ "$(file_sha256 "$BIN_PATH")" == "$(file_sha256 "$LOCAL_BINARY")" && -f "$DEPLOY_STATE_DIR/recovery/binary" && -f "$DEPLOY_STATE_DIR/incomplete" ]] || fail '导入绕过B恢复保护'
  cp "$BIN_PATH" "$tmp/expected"
  DERPER_VERSION=v1.104.2
  if import_local_derper >/dev/null 2>&1; then fail '接受错误版本'; fi
  DERPER_VERSION=v1.104.1 BINARY_SHA256=$(printf '%064d' 0)
  if import_local_derper >/dev/null 2>&1; then fail '接受错误摘要'; fi
  BINARY_SHA256=''
  cp "$LOCAL_BINARY" "$tmp/wrong-arch"
  printf '\377\377' | dd of="$tmp/wrong-arch" bs=1 seek=18 conv=notrunc status=none
  LOCAL_BINARY="$tmp/wrong-arch"
  if import_local_derper >/dev/null 2>&1; then fail '执行或导入错误架构'; fi
  cmp "$BIN_PATH" "$tmp/expected" || fail '拒绝后正式二进制变化'
}
test_probe_timeout_and_stale() {
  setup_snapshot
  probe_path_is_trusted() { return 0; }
  EXTERNAL_PROBE="$tmp/probe"
  printf '#!/bin/sh\nsleep 5\n' >"$EXTERNAL_PROBE"; chmod 755 "$EXTERNAL_PROBE"
  PROBE_TIMEOUT=1
  run_external_probe
  [[ "$H3_STATUS" == unknown && "$H3_REASON" == probe_timeout_or_error ]] || fail '超时未报未知'
  printf '#!/bin/sh\nprintf "schema=1\\nregion_id=900\\nip=47.120.74.191\\nderp_port=30399\\nstun_port=3478\\nchecked_at=1\\nderp=ok\\nstun=ok\\n"\n' >"$EXTERNAL_PROBE"
  run_external_probe
  [[ "$H3_STATUS" == unknown && "$H3_REASON" == probe_stale ]] || fail '过期探针被报绿'
}
test_rollback_does_not_restart_twice() {
  DEPLOY_STATE_DIR="$tmp/deploy"
  mkdir -p "$DEPLOY_STATE_DIR"
  printf 'phase=switch\nrecovery=%s/recovery\n' "$DEPLOY_STATE_DIR" >"$DEPLOY_STATE_DIR/incomplete"
  rollback_cert_update() { return 0; }
  rollback_deploy_change() { rm "$DEPLOY_STATE_DIR/incomplete"; echo restored >>"$tmp/calls"; }
  rollback_previous_unit() { fail 'A/B恢复后不应再次重启'; }
  rollback_failed_release "$tmp/unit.bak" 1 || fail 'A/B回退应成功'
  [[ "$(cat "$tmp/calls")" == restored ]] || fail '缺少A/B恢复'
  printf 'phase=switch\nrecovery=%s/recovery\n' "$DEPLOY_STATE_DIR" >"$DEPLOY_STATE_DIR/incomplete"
  rollback_deploy_change() { return 1; }
  if rollback_failed_release "$tmp/unit.bak" 1 >/dev/null 2>&1; then fail '恢复失败报成功'; fi
  [[ -f "$DEPLOY_STATE_DIR/incomplete" ]] || fail '恢复失败丢标记'
}
test_old_and_new_modes_equivalent() {
  local pair cmd old a b
  parse_args
  validate_arg_combos || fail '旧无主模式调用不再兼容'
  for pair in 'check:--check' 'health:--health-check' 'status:--health-check' 'repair:--repair' 'uninstall:--uninstall' 'recover:--recover-interrupted'; do
    cmd=${pair%%:*}; old=${pair#*:}
    a=$(DERPER_TEST_MODE=1 source "$SCRIPT"; parse_args "$cmd"; validate_arg_combos || exit 1; printf '%s' "$DRY_RUN:$HEALTH_CHECK:$REPAIR:$UNINSTALL:$RECOVER_INTERRUPTED")
    b=$(DERPER_TEST_MODE=1 source "$SCRIPT"; parse_args "$old"; validate_arg_combos || exit 1; printf '%s' "$DRY_RUN:$HEALTH_CHECK:$REPAIR:$UNINSTALL:$RECOVER_INTERRUPTED")
    [[ "$a" == "$b" ]] || fail '新旧入口模式不等价'
  done
}
test_config_nul_and_no_implicit_execution() {
  printf 'CONFIG_VERSION=1\000\n' >"$tmp/nul.conf"
  if load_deploy_config "$tmp/nul.conf" >/dev/null 2>&1; then fail '配置接受NUL'; fi
  printf 'CONFIG_VERSION=1\nIP_ADDR=47.120.74.191\n' >"$tmp/good.conf"
  systemctl() { fail '读配置不应调用systemctl'; }
  load_deploy_config "$tmp/good.conf" || fail '纯数据配置失败'
  [[ "$IP_ADDR" == 47.120.74.191 && ! -e "$tmp/deploy" ]] || fail '读取配置产生安装副作用'
}
test_json_remains_valid_on_metrics_write_failure() {
  test_single_collection_json
  METRICS_TEXTFILE="$tmp/metrics.prom"
  printf 'original\n' >"$METRICS_TEXTFILE"
  mv() { return 1; }
  health_check_report >"$tmp/write-failure.json" 2>"$tmp/error"
  [[ "$(health_check_exit_code)" == 1 && "$(cat "$METRICS_TEXTFILE")" == original ]] || fail '指标失败未传播或覆盖旧数据'
  python3 - "$tmp/write-failure.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); assert s['result']=='failed' and s['writes']['metrics_failed']==1 and s['needs_manual_attention']
PY
}
test_root_probe_path_trust() {
  [[ "$(id -u)" == 0 ]] || return 77
  local root_tmp
  root_tmp=$(mktemp -d /root/derper-c-trust.XXXXXXXX)
  printf '#!/bin/sh\nexit 0\n' >"$root_tmp/probe"; chmod 755 "$root_tmp/probe"
  probe_path_is_trusted "$root_tmp/probe" || { rm -rf "$root_tmp"; fail 'root受控路径未通过'; }
  chmod 777 "$root_tmp"
  if probe_path_is_trusted "$root_tmp/probe"; then rm -rf "$root_tmp"; fail '接受父目录可写探针'; fi
  rm -rf "$root_tmp"
}
test_probe_path_trust_rejects_untrusted_paths() {
  # 覆盖信任检查负例：相对路径、符号链接、不可执行、目录、不存在一律拒绝。
  # 负断言用 if/fail 形式：正确拒绝时语句状态必须为 0，不能让函数以 1 结束。
  printf '#!/bin/sh\nexit 0\n' >"$tmp/probe-ok"; chmod 755 "$tmp/probe-ok"
  if [[ "$(id -u)" != 0 ]]; then
    probe_path_is_trusted "$tmp/probe-ok" || fail '非root下可执行的普通文件探针被误拒'
  else
    # root 分支沿路径上溯校验属主：/tmp(1777) 下的探针按设计不受信任，须用 /root 等受控路径。
    if probe_path_is_trusted "$tmp/probe-ok"; then fail 'root下公共可写目录中的探针不得通过'; fi
  fi
  if probe_path_is_trusted "relative/probe"; then fail '相对路径不得通过'; fi
  ln -s "$tmp/probe-ok" "$tmp/probe-link"
  if probe_path_is_trusted "$tmp/probe-link"; then fail '符号链接不得通过'; fi
  chmod 644 "$tmp/probe-ok"
  if probe_path_is_trusted "$tmp/probe-ok"; then fail '不可执行文件不得通过'; fi
  if probe_path_is_trusted "$tmp"; then fail '目录不得通过'; fi
  if probe_path_is_trusted "$tmp/missing-probe"; then fail '不存在的路径不得通过'; fi
}
test_local_import_keeps_requested_version() {
  LOCAL_BINARY="$tmp/pinned"
  DERPER_VERSION=v1.104.2 VERIFY_CLIENTS_MODE=on
  ts_version() { fail '本地固定版本不应按CLI版本改写目标'; }
  align_derper_version_with_tailscale
  [[ "$DERPER_VERSION" == v1.104.2 ]] || fail '本地固定版本被自动改写'
}
test_json_outputs_keep_stdout_clean_when_ip_inferred() {
  # 文档示例是不带 --ip 的 status --format json；IP 从 unit 推断时提示只能走 stderr。
  check_os_environment() { :; }
  systemctl() { return 0; }
  openssl() { return 0; }
  ss() { return 0; }
  read_derper_unit_content() { echo 'ExecStart=/usr/local/bin/derper -hostname 47.120.74.191 -a :30399 -stun-port 3478 # 安全加固（级别：standard）'; }
  check_tailscale_status() { TS_RUNNING=0; }
  check_derper_status() {
    DERPER_BIN=1 DERPER_SERVICE_PRESENT=1 DERPER_RUNNING=1 PURE_IP_OK=1 DESIRED_CONFIG_OK=1
    DERPER_VERIFY_CLIENTS_EFFECTIVE=0 PORT_TLS_OK=1 PORT_STUN_OK=1 CURRENT_DERPER_OWNS_PORTS=1
  }
  check_cert_status() { CERT_PRESENT=1 CERT_NAMING_OK=1 CERT_SAN_MATCH=1 CERT_EXPIRY_OK=1; }
  check_live_cert_status() { LIVE_CERT_CHECKED=1 CERT_LIVE_MATCH=1; HEALTH_LIVE_SHA256=$(printf '%064d' 7); HEALTH_CERT_SHA256=$HEALTH_LIVE_SHA256; }
  cert_days_remaining() { echo 120; }
  (main status --format json) >"$tmp/status.json" 2>"$tmp/status.err" || fail 'status --format json 非零退出'
  (main derpmap) >"$tmp/map.json" 2>"$tmp/map.err" || fail 'derpmap 非零退出'
  grep -q '从已部署 unit 读取' "$tmp/status.err" || fail '推断提示未出现在 stderr'
  python3 - "$tmp" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
s=json.loads((p/'status.json').read_text()); assert s['result']=='healthy' and s['target']['ip']=='47.120.74.191'
m=json.loads((p/'map.json').read_text()); assert m['Regions']['900']['Nodes'][0]['IPv4']=='47.120.74.191'
PY
}
stub_main_preflight() {
  require_root() { :; }
  check_os_environment() { :; }
  acquire_deploy_lock() { return 0; }
  ordinary_change_allowed() { return 0; }
  resolve_run_user() { :; }
  recover_cert_update() { return 0; }
  detect_public_ip() { return 0; }
  validate_settings() { return 0; }
  precheck_verify_clients() { :; }
  align_derper_version_with_tailscale() { :; }
  ensure_deploy_dependencies() { return 0; }
  check_tailscale_status() { :; }
  check_derper_status() { DERPER_BIN=0; DERPER_RUNNING=0; }
  check_cert_status() { :; }
  check_live_cert_status() { :; }
}
test_import_failure_aborts_before_mutation() {
  # Bash 3.2 对函数里的 `|| return` 不会让调用方 set -e 退出。关掉 set -e 来钉住显式 exit。
  local calls="$tmp/calls" rc mode
  : >"$calls"
  stub_main_preflight
  generate_selfsigned_cert() { echo cert >>"$calls"; }
  ensure_compatible_certs() { echo certs >>"$calls"; return 0; }
  write_systemd_service() { echo unit >>"$calls"; }
  check_port_conflicts() { echo ports >>"$calls"; }
  for mode in force deploy repair; do
    : >"$calls"
    set +e
    case "$mode" in
      force) (main --force --binary "$tmp/missing-bin" --derper-version v1.2.3 --ip 47.120.74.191 --no-verify-clients --allow-non-global-ip --yes >"$tmp/out" 2>"$tmp/err") ;;
      deploy) (main deploy --binary "$tmp/missing-bin" --derper-version v1.2.3 --ip 47.120.74.191 --no-verify-clients --allow-non-global-ip --yes >"$tmp/out" 2>"$tmp/err") ;;
      repair) (main repair --binary "$tmp/missing-bin" --derper-version v1.2.3 --ip 47.120.74.191 --no-verify-clients --allow-non-global-ip --yes >"$tmp/out" 2>"$tmp/err") ;;
    esac
    rc=$?
    set -e
    [[ "$rc" -ne 0 ]] || fail "$mode 导入失败仍返回成功"
    grep -q '本地二进制必须为可读普通文件' "$tmp/err" || fail "$mode 未走到本地导入：rc=$rc $(cat "$tmp/err")"
    if [[ -s "$calls" ]]; then fail "$mode 导入失败后仍继续变更：$(cat "$calls")"; fi
  done
}
fill_degraded_snapshot() {
  local cert_present="${1:-1}"
  HEALTH_SNAPSHOT_READY=1
  SAMPLED_AT=$(date +%s)
  HEALTH_VALIDATE_FAILED=0
  METRICS_WRITE_FAILED=0
  STATE_WRITE_FAILED=0
  H0_STATUS=unknown
  H1_STATUS=unknown
  H2_STATUS=not_applicable
  H3_STATUS=not_checked
  H3_REASON=probe_not_configured
  METRICS_FRESHNESS=not_checked
  METRICS_AGE=''
  DERPER_RUNNING=1
  PURE_IP_OK=1
  DESIRED_CONFIG_OK=1
  CERT_PRESENT=$cert_present
  CERT_NAMING_OK=1
  CERT_SAN_MATCH=1
  CERT_EXPIRY_OK=1
  CERT_KEY_MATCH=1
  CERT_CHECK_UNKNOWN=0
  LIVE_CERT_CHECKED=1
  CERT_LIVE_MATCH=1
  DERPER_VERIFY_CLIENTS_EFFECTIVE=0
  EXTERNAL_PROBE=''
  REQUIRE_H3=0
}
test_degraded_observation_does_not_roll_back() {
  local calls="$tmp/calls" rc
  : >"$calls"
  port_observation_available() { return 1; }
  tls_observation_available() { return 0; }
  collect_health_status() { fill_degraded_snapshot 1; }
  publish_verification_gate >/dev/null 2>&1 || fail '缺端口工具时，证书成立的降级启动不应被门禁拒绝'
  collect_health_status() { fill_degraded_snapshot 0; }
  if publish_verification_gate >/dev/null 2>&1; then fail '证书不成立仍沿用降级结果放行'; fi
  collect_health_status() { fill_degraded_snapshot 1; REQUIRE_H3=1; }
  if publish_verification_gate >/dev/null 2>&1; then fail '缺 H3 时降级观测仍放行'; fi
  port_observation_available() { return 0; }
  collect_health_status() { fill_degraded_snapshot 1; }
  if publish_verification_gate >/dev/null 2>&1; then fail '工具齐全时的未知仍放行'; fi

  port_observation_available() { return 1; }
  SERVICE_PATH="$tmp/derper.service"
  systemctl() { return 0; }
  service_verified_running() { return 0; }
  collect_health_status() { fill_degraded_snapshot 1; }
  rollback_failed_release() { echo rollback >>"$calls"; return 0; }
  commit_deploy_change() { echo commit >>"$calls"; }
  deploy_and_verify_derper_service "$SERVICE_PATH" '[Service] ExecStart=/bin/true' >"$tmp/out" 2>"$tmp/err" || fail '降级观测不应回滚已启动的服务'
  grep -qx commit "$calls" || fail '降级观测未提交发布'
  if grep -qx rollback "$calls"; then fail '降级观测仍回滚'; fi
  : >"$calls"
  collect_health_status() { fill_degraded_snapshot 0; }
  set +e
  (deploy_and_verify_derper_service "$SERVICE_PATH" '[Service] ExecStart=/bin/true' >"$tmp/out" 2>"$tmp/err")
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || fail '证书不成立的发布仍成功'
  grep -qx rollback "$calls" || fail '证书不成立未回滚'
}
test_fresh_install_rollback_reports_complete() {
  local calls="$tmp/calls" rc=0 out
  : >"$calls"
  DEPLOY_STATE_DIR="$tmp/state"
  SERVICE_PATH="$tmp/derper.service"
  systemctl() { printf '%s\n' "$*" >>"$calls"; [[ "$1" != is-active ]]; }
  rollback_cert_update() { return 0; }
  out=$(rollback_previous_unit "" 0 2>&1) || rc=$?
  [[ "$rc" == 0 ]] || fail "全新安装回滚应完成：rc=$rc $out"
  grep -qx 'stop derper' "$calls" || fail '未停止半启动服务'
  [[ "$out" != *回退未完成* ]] || fail '完成的回滚报未完成'
  rc=0
  out=$(rollback_failed_release "" 0 2>&1) || rc=$?
  [[ "$rc" == 0 && "$out" != *回退未完成* ]] || fail "发布回滚包装应视为完成：rc=$rc $out"
  printf 'old-unit\n' >"$tmp/unit.bak"
  rollback_previous_unit "$tmp/unit.bak" 0 >/dev/null 2>&1 || fail '旧单元已写回且原服务停止，应视为回滚完成'
  [[ "$(cat "$SERVICE_PATH")" == old-unit ]] || fail '未写回旧单元'
  rc=0
  out=$(rollback_previous_unit "" 1 2>&1) || rc=$?
  [[ "$rc" != 0 ]] || fail '无备份且原先在运行必须报未完成'
}
expect_arg_result() {
  local expect="$1" needle="$2" out
  shift 2
  out=$(
    DERPER_TEST_MODE=1 source "$SCRIPT"
    parse_args "$@" || { echo 'parse-failed'; exit 1; }
    if err=$(validate_arg_combos 2>&1); then
      printf 'accept\n'
    else
      printf 'reject\n%s\n' "$err"
    fi
  ) || fail "参数解析失败：$* / $out"
  if [[ "$expect" == accept ]]; then
    [[ "$(printf '%s\n' "$out" | head -n1)" == accept ]] || fail "应接受 $*：$out"
  else
    [[ "$(printf '%s\n' "$out" | head -n1)" == reject ]] || fail "应拒绝 $*：$out"
    grep -F -q -- "$needle" <<<"$out" || fail "拒绝 $* 缺少说明【$needle】：$out"
  fi
}
test_validate_arg_combos_explain_rejections() {
  expect_arg_result reject '--force' deploy --force
  expect_arg_result reject 'text 或 json' status --format xml
  expect_arg_result reject '64 位十六进制' deploy --binary "$tmp/bin" --binary-sha256 zz --derper-version v1.2.3
  expect_arg_result reject '1 到 120' deploy --probe-timeout 0
  expect_arg_result reject '1 到 120' deploy --probe-timeout 121
  expect_arg_result reject 'external-probe' check --external-probe /x --require-h3
  expect_arg_result reject 'external-probe' uninstall --external-probe /x
  expect_arg_result reject 'require-h3' recover --require-h3
  expect_arg_result reject '会忽略' check --probe-timeout 30
  expect_arg_result reject 'metrics-max-age' deploy --metrics-max-age 10
  expect_arg_result accept '' status --external-probe /x --require-h3
  expect_arg_result accept '' health --metrics-max-age 10 --probe-timeout 30
  expect_arg_result accept '' deploy --binary "$tmp/bin" --derper-version v1.2.3
  cp "$ROOT_DIR/examples/deploy.conf.example" "$tmp/deploy.conf"
  chmod 644 "$tmp/deploy.conf"
  expect_arg_result accept '' check --config "$tmp/deploy.conf"
}
test_json_number_accepts_safe_region_id() {
  [[ "$(json_number 900)" == 900 ]] || fail '普通 region 被拒绝'
  [[ "$(json_number 9007199254740991)" == 9007199254740991 ]] || fail '安全整数上限被写成 null'
  [[ "$(json_number -9007199254740991)" == -9007199254740991 ]] || fail '负向安全整数被拒绝'
  [[ "$(json_number 9007199254740992)" == null ]] || fail '超出安全整数仍输出数字'
  [[ "$(json_number 00012)" == null ]] || fail '前导零被当成数字'
  setup_snapshot
  REGION_ID=9007199254740991
  render_status_json >"$tmp/status.json"
  python3 - "$tmp/status.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
assert s["target"]["region_id"]==9007199254740991
PY
}
test_bug067_first_install_stops_before_cleanup() {
  DEPLOY_STATE_DIR="$tmp/deploy" BIN_PATH="$tmp/derper" SERVICE_PATH="$tmp/unit"
  printf 'candidate\n' >"$BIN_PATH"
  write_incomplete_marker first-install
  local runtime=active stop_fails=1 calls="$tmp/calls"
  systemctl() {
    case "$1" in
      stop)
        [[ -f "$DEPLOY_STATE_DIR/incomplete" && -f "$BIN_PATH" ]] || fail '停服之前不能清理二进制/标记'
        echo stop >>"$calls"
        [[ "$stop_fails" == 0 ]] || return 1
        runtime=inactive ;;
      is-active) [[ "$runtime" == active ]] ;;
      *) return 0 ;;
    esac
  }
  if rollback_deploy_change >/dev/null 2>&1; then fail 'first-install停止失败仍成功'; fi
  [[ -f "$BIN_PATH" && -f "$DEPLOY_STATE_DIR/incomplete" && -s "$calls" ]] || fail '停止失败必须保留候选和标记'
  stop_fails=0
  rollback_deploy_change || fail '停止成功后应能重试清理'
  [[ "$runtime" == inactive && ! -e "$BIN_PATH" && ! -e "$DEPLOY_STATE_DIR/incomplete" ]] || fail '未恢复到停止状态'
  printf 'candidate\n' >"$BIN_PATH"
  write_incomplete_marker first-install
  runtime=active stop_fails=1
  rollback_cert_update() { return 0; }
  if rollback_failed_release '' 0 >/dev/null 2>&1; then fail '发布包装层首装拒停不能报成功'; fi
  [[ -f "$BIN_PATH" && -f "$DEPLOY_STATE_DIR/incomplete" ]] || fail '包装层失败丢失恢复入口'
  stop_fails=0
  rollback_failed_release '' 0 || fail '包装层应能安全重试，不能在清标记后重复停止'
  [[ "$runtime" == inactive && ! -e "$BIN_PATH" && ! -e "$DEPLOY_STATE_DIR/incomplete" ]] || fail '包装层未完成首装回退'
}

test_bug066_known_ports_block_degraded_gate() {
  fill_degraded_snapshot 1
  port_observation_available() { return 0; }
  tls_observation_available() { return 1; }
  PORT_CHECK_UNKNOWN=0 PORT_TLS_OK=0 PORT_STUN_OK=0 CURRENT_DERPER_OWNS_PORTS=0
  if degraded_startup_satisfies_gate; then fail '缺openssl不能覆盖已确认的端口故障'; fi
  PORT_TLS_OK=1 PORT_STUN_OK=1 CURRENT_DERPER_OWNS_PORTS=1
  degraded_startup_satisfies_gate || fail '已确认端口正常时允许仅TLS观测降级'
}

test_bug071_ignoring_term_probe_is_bounded() {
  cat >"$tmp/stubborn-probe" <<'SH'
#!/bin/bash
trap '' TERM
printf '%s\n' "$$" >"$PROBE_PIDFILE"
sleep 30 &
printf '%s\n' "$!" >>"$PROBE_PIDFILE"
wait
SH
  chmod 755 "$tmp/stubborn-probe"
  python3 - "$SCRIPT" "$tmp/stubborn-probe" "$tmp/probe-pids" <<'PY'
import os, pathlib, signal, subprocess, sys
script, probe, pidfile = sys.argv[1:]
env = dict(os.environ, PROBE_PIDFILE=pidfile)
code = 'DERPER_TEST_MODE=1 source "$1"; probe_path_is_trusted(){ return 0; }; EXTERNAL_PROBE="$2"; PROBE_TIMEOUT=1; run_external_probe; printf "%s %s\\n" "$H3_STATUS" "$H3_REASON"'
p = subprocess.Popen(['bash','-c',code,'test',script,probe], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
try:
    out, err = p.communicate(timeout=5)
    assert p.returncode == 0 and out.strip() == 'unknown probe_timeout_or_error', (p.returncode,out,err)
    for pid in pathlib.Path(pidfile).read_text().split():
        stat = pathlib.Path('/proc')/pid/'stat'
        assert not stat.exists() or stat.read_text().split(') ',1)[1].split()[0] == 'Z', 'probe descendant remains running'
except BaseException:
    if pathlib.Path(pidfile).exists():
        for pid in pathlib.Path(pidfile).read_text().split():
            try: os.killpg(os.getpgid(int(pid)), signal.SIGKILL)
            except ProcessLookupError: pass
    try: os.killpg(p.pid, signal.SIGKILL)
    except ProcessLookupError: pass
    p.communicate()
    raise
# 主进程响应TERM退出，但子进程忽略TERM时，也不能留下子进程。
pathlib.Path(probe).write_text('''#!/bin/bash
trap 'exit 0' TERM
printf '%s\\n' "$$" >"$PROBE_PIDFILE"
bash -c 'trap "" TERM; echo $$ >>"$PROBE_PIDFILE"; sleep 30 & echo $! >>"$PROBE_PIDFILE"; wait' &
wait
''')
p = subprocess.Popen(['bash','-c',code,'test',script,probe], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
try:
    out, err = p.communicate(timeout=5)
    assert p.returncode == 0 and out.strip() == 'unknown probe_timeout_or_error', (p.returncode,out,err)
    for pid in pathlib.Path(pidfile).read_text().split():
        stat = pathlib.Path('/proc')/pid/'stat'
        assert not stat.exists() or stat.read_text().split(') ',1)[1].split()[0] == 'Z', 'orphaned probe child remains running'
finally:
    for pid in pathlib.Path(pidfile).read_text().split():
        try: os.kill(int(pid), signal.SIGKILL)
        except ProcessLookupError: pass
    if p.poll() is None:
        os.killpg(p.pid, signal.SIGKILL)
    p.communicate()
PY
}

test_bug073_directory_state_target_is_rejected() {
  setup_snapshot
  HEALTH_STATE_FILE="$tmp/state-dir"
  mkdir "$HEALTH_STATE_FILE"
  if write_health_state; then fail '目录目标不能报告状态写入成功'; fi
  [[ -z "$(ls -A "$HEALTH_STATE_FILE")" ]] || fail '不能把隐藏临时文件移入目标目录'
}

test_bug074_state_metrics_aliases_are_rejected() {
  HEALTH_CHECK=1
  mkdir "$tmp/real"
  ln -s "$tmp/real" "$tmp/alias"
  local pair
  for pair in "$tmp/real/file" "$tmp/real/../real/file" "$tmp/alias/file"; do
    METRICS_TEXTFILE="$tmp/real/file" HEALTH_STATE_FILE="$pair"
    if validate_arg_combos >/dev/null 2>&1; then fail '状态/指标同路径或路径别名必须拒绝'; fi
  done
  printf 'unchanged\n' >"$tmp/real/file"
  ln "$tmp/real/file" "$tmp/hardlink"
  HEALTH_STATE_FILE="$tmp/hardlink"
  if validate_arg_combos >/dev/null 2>&1; then fail '现有硬链接别名必须拒绝'; fi
  METRICS_TEXTFILE='' METRICS_SOURCE="$tmp/real/file"
  if validate_arg_combos >/dev/null 2>&1; then fail '状态输出也不能覆盖指标输入'; fi
  METRICS_TEXTFILE="$tmp/real/file" METRICS_SOURCE=''
  collect_health_status() { setup_snapshot; }
  HEALTH_STATE_FILE="$METRICS_TEXTFILE"
  health_check_report >"$tmp/out.json" 2>"$tmp/err"
  [[ "$(cat "$METRICS_TEXTFILE")" == unchanged && "$(health_check_exit_code)" != 0 ]] || fail '直接报告入口也不能先写指标再覆盖状态'
}

test_bug075_success_history_is_bound_to_scope() {
  setup_snapshot
  HEALTH_STATE_FILE="$tmp/history.json"
  write_health_state || fail '初始状态写入失败'
  local setting
  for setting in region ip port h3 probe metrics; do
    (
      H1_STATUS=failed
      case "$setting" in
        region) REGION_ID=901 ;; ip) IP_ADDR=8.8.8.8 ;; port) DERP_PORT=443 ;;
        h3) REQUIRE_H3=1 ;; probe) EXTERNAL_PROBE=/different-probe ;; metrics) METRICS_MAX_AGE=30 ;;
      esac
      load_health_last_success
      [[ "$HEALTH_LAST_SUCCESS" == 0 ]] || fail "${setting}变化不能沿用其他范围的成功历史"
    ) || fail '成功历史范围绑定失效'
  done
}

test_bug076_config_region_matches_cli_range() {
  printf 'CONFIG_VERSION=1\nREGION_ID=9007199254740991\n' >"$tmp/region.conf"
  load_deploy_config "$tmp/region.conf" || fail '配置应接受CLI合法的安全整数上限'
  [[ "$REGION_ID" == 9007199254740991 ]] || fail '配置值被截断'
  printf 'CONFIG_VERSION=1\nREGION_ID=9007199254740992\n' >"$tmp/region.conf"
  if load_deploy_config "$tmp/region.conf"; then fail '配置不能接受超出CLI上限的值'; fi
  [[ "$REGION_ID" == 9007199254740991 ]] || fail '非法配置不能部分赋值'
}

test_bug072_root_rejects_untrusted_state_ancestors() {
  [[ "$(id -u)" == 0 ]] || return 77
  setup_snapshot
  chmod 755 "$tmp"
  mkdir "$tmp/untrusted" "$tmp/protected" "$tmp/protected/sub"
  chmod 700 "$tmp/protected"
  chown nobody "$tmp/untrusted"
  printf 'PROTECTED\n' >"$tmp/protected/sub/status.json"
  runuser -u nobody -- ln -s "$tmp/protected" "$tmp/untrusted/alias"
  HEALTH_STATE_FILE="$tmp/untrusted/alias/sub/status.json"
  if write_health_state; then fail 'root不能穿过低权限用户控制的祖先路径写入'; fi
  [[ "$(cat "$tmp/protected/sub/status.json")" == PROTECTED ]] || fail '受保护文件被覆盖'
  HEALTH_STATE_FILE="$tmp/untrusted/plain.json"
  if write_health_state; then fail '无链接但低权限用户可改写的目录也必须拒绝'; fi
  DERPER_RUNNING=1 PORT_TLS_OK=1 PORT_STUN_OK=1 PURE_IP_OK=1 DESIRED_CONFIG_OK=1
  if write_prometheus_metrics "$tmp/untrusted/alias/sub/status.json" 120 0 >/dev/null 2>&1; then fail '指标输出也不能穿过不可信祖先'; fi
  [[ "$(cat "$tmp/protected/sub/status.json")" == PROTECTED ]] || fail '指标输出覆盖了受保护文件'
  write_prometheus_metrics "$tmp/readable-collector/nested/derper.prom" 120 0 || fail '可信指标路径应能写入'
  runuser -u nobody -- test -r "$tmp/readable-collector/nested/derper.prom" || fail '新指标目录必须允许只读采集用户遍历读取'
}

test_derpmap_unknown_identity_exits_2() {
  local rc=0
  setup_snapshot
  H1_STATUS=unknown
  set +e
  render_derpmap_json >"$tmp/map.json" 2>"$tmp/map.err"
  rc=$?
  set -e
  [[ "$rc" == 2 && ! -s "$tmp/map.json" ]] || fail "未知身份应退出 2：rc=$rc"
  grep -q '本地身份未验证' "$tmp/map.err" || fail '缺少未验证说明'
  H1_STATUS=failed
  set +e
  render_derpmap_json >"$tmp/map.json" 2>"$tmp/map.err"
  rc=$?
  set -e
  [[ "$rc" == 1 ]] || fail "确认失败应退出 1：rc=$rc"
  check_os_environment() { :; }
  infer_ip_from_existing_deployment() { :; }
  infer_healthcheck_settings_from_unit() { :; }
  systemctl() { return 0; }
  openssl() { return 0; }
  ss() { return 0; }
  check_tailscale_status() { TS_RUNNING=0; }
  check_derper_status() {
    DERPER_RUNNING=1 PORT_TLS_OK=1 PORT_STUN_OK=1 PURE_IP_OK=1 DESIRED_CONFIG_OK=1
    CURRENT_DERPER_OWNS_PORTS=1 DERPER_VERIFY_CLIENTS_EFFECTIVE=0
  }
  check_cert_status() { CERT_CHECK_UNKNOWN=1; }
  check_live_cert_status() { LIVE_CERT_CHECKED=0; CERT_LIVE_MATCH=0; }
  cert_days_remaining() { echo 120; }
  set +e
  (main derpmap --ip 47.120.74.191 >"$tmp/main-map.json" 2>"$tmp/main-map.err")
  rc=$?
  set -e
  [[ "$rc" == 2 && ! -s "$tmp/main-map.json" ]] || fail "derpmap 主流程未知身份应退出 2：rc=$rc $(cat "$tmp/main-map.err")"
}
selected=(test_config_precedence test_config_is_data test_command_conflicts test_json_escape test_probe_contract test_metrics_freshness test_snapshot_outputs_and_gate test_state_atomicity_and_last_success test_single_collection_json test_import_elf_version_hash_and_publish test_probe_timeout_and_stale test_rollback_does_not_restart_twice test_old_and_new_modes_equivalent test_config_nul_and_no_implicit_execution test_json_remains_valid_on_metrics_write_failure test_root_probe_path_trust test_probe_path_trust_rejects_untrusted_paths test_local_import_keeps_requested_version test_json_outputs_keep_stdout_clean_when_ip_inferred test_import_failure_aborts_before_mutation test_degraded_observation_does_not_roll_back test_fresh_install_rollback_reports_complete test_validate_arg_combos_explain_rejections test_json_number_accepts_safe_region_id test_derpmap_unknown_identity_exits_2)
selected+=(test_bug067_first_install_stops_before_cleanup test_bug066_known_ports_block_degraded_gate test_bug071_ignoring_term_probe_is_bounded test_bug072_root_rejects_untrusted_state_ancestors test_bug073_directory_state_target_is_rejected test_bug074_state_metrics_aliases_are_rejected test_bug075_success_history_is_bound_to_scope test_bug076_config_region_matches_cli_range)
[[ $# == 0 ]] || selected=("$@")
failed=0
for t in "${selected[@]}"; do
  if (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    "$t"
  ); then echo "ok - $t"; else
    rc=$?
    if [[ "$rc" == 77 ]]; then echo "skip - ${t}（需root，不能作为该项通过证据）"
    else echo "not ok - $t"; failed=$((failed+1)); fi
  fi
done
[[ $failed == 0 ]]
