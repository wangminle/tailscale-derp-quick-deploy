#!/usr/bin/env bash
# GB 会占用默认部署路径，仅允许人工标记的一次性 VM；不得在生产/开发主机运行。
# DERPER_INTEGRATION_VM=1 DERPER_TEST_BINARY=/root/derper bash tests/test_systemd_integration.sh
# systemctl、健康复验、文件操作均为真实实现；坏候选仅作为故障输入。
set -euo pipefail
if [[ "${DERPER_INTEGRATION_VM:-}" != 1 || "$(id -u)" != 0 || "$(cat /proc/1/comm)" != systemd \
   || ! -f /root/DERPER_DISPOSABLE_GB_VM ]] || ! systemd-detect-virt --vm >/dev/null; then
  echo 'not verified - 需要 root、systemd PID 1 和人工标记的一次性 VM' >&2
  exit 2
fi
if systemctl is-active --quiet derper || systemctl cat derper.service >/dev/null 2>&1 || [[ -e /opt/derper || -e /var/lib/derper || -e /var/lib/derper-deploy || -e /usr/local/bin/derper ]] \
   || systemctl cat derper-healthcheck.timer >/dev/null 2>&1 || getent passwd derper-gb >/dev/null; then
  echo 'not verified - 已有 DERP 部署，拒绝覆盖' >&2
  exit 2
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/deploy_derper_ip_selfsigned.sh"
fixture="${DERPER_TEST_BINARY:?请提供真实 derper 二进制}"
for tool in systemctl openssl ss curl runuser timeout sha256sum; do command -v "$tool" >/dev/null; done
[[ -x "$fixture" ]] || { echo 'not verified - fixture 不可执行'; exit 2; }
artifacts="${DERPER_TEST_ARTIFACTS:-/root/gb-artifacts}"
mkdir -p "$artifacts"
tmp=$(mktemp -d /root/derper-gb.XXXXXXXX)
cleanup() {
  local rc=$?
  trap - EXIT
  rm -f /etc/systemd/system/derper.service.d/refuse-stop.conf
  systemctl daemon-reload
  systemctl show derper -p MainPID -p ActiveState -p Result >"$artifacts/final-service.txt" 2>&1 || true
  journalctl -u derper -u derper-healthcheck --no-pager >"$artifacts/journal.txt" 2>&1 || true
  systemctl disable --now derper-healthcheck.timer >/dev/null 2>&1 || true
  systemctl disable --now derper.service >/dev/null 2>&1 || true
  systemctl stop derper.service >/dev/null 2>&1 || true
  systemctl stop derper-healthcheck.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/derper.service /etc/systemd/system/derper.service.bak.*
  rm -f /etc/systemd/system/derper-healthcheck.{service,timer}
  rm -rf /etc/systemd/system/derper.service.d /etc/systemd/system/derper.service.certs-rollback
  rm -f /usr/local/bin/derper /etc/cron.d/derper-healthcheck
  rm -rf /opt/derper /var/lib/derper /var/lib/derper-deploy /usr/local/lib/derper-deploy "$tmp"
  rm -f /etc/derper/derper.env
  rmdir /etc/derper 2>/dev/null || true
  systemctl daemon-reload
  systemctl reset-failed derper derper-healthcheck >/dev/null 2>&1 || true
  userdel derper-gb >/dev/null 2>&1 || true
  if [[ ! -e /usr/local/bin/derper && ! -e /opt/derper && ! -e /etc/systemd/system/derper-healthcheck.timer ]] \
     && ! systemctl is-active --quiet derper && ! ss -lntup | grep -Eq ':(30443|33478)\b'; then
    echo 'ok - 测试服务、调度、端口与安装文件已清理' >"$artifacts/cleanup.txt"
  else
    echo 'not ok - 清理不完整' >"$artifacts/cleanup.txt"
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
fail() { echo "not ok - $*" >&2; exit 1; }
ok() { echo "ok - $*"; }
DERPER_TEST_MODE=1
source "$SCRIPT"
unset DERPER_TEST_MODE
IP_ADDR=127.0.0.1
DERP_PORT=30443
STUN_PORT=33478
VERIFY_CLIENTS_MODE=off
ALLOW_NON_GLOBAL_IP=1
RUN_USER=derper-gb
NODE_STATE_DIR=/var/lib/derper
NON_INTERACTIVE=1
SECURITY_LEVEL=standard
SCRIPT_SELF="$SCRIPT"
METRICS_TEXTFILE=/var/lib/derper-deploy/gb.prom
useradd --system --no-create-home --shell /usr/sbin/nologin "$RUN_USER"
cp "$fixture" "$BIN_PATH"
chmod 755 "$BIN_PATH"
layout_install_tree
generate_selfsigned_cert >"$artifacts/bootstrap-cert.log" 2>&1
write_systemd_service >"$artifacts/bootstrap-service.log" 2>&1
commit_cert_update
printf 'old-state\n' >"$NODE_STATE_DIR/gb-state"
chown "$RUN_USER:$RUN_USER" "$NODE_STATE_DIR/gb-state"
service_verified_running || fail '基线真实 DERP 不可用'
baseline_pid=$(systemctl show derper -p MainPID --value)
old_hash=$(file_sha256 "$BIN_PATH")
unit_hash=$(file_sha256 "$SERVICE_PATH")
config_hash=$(file_sha256 "$(derper_config_path)")
cert_hash=$(file_sha256 "$(derper_manual_cert_file)")
key_hash=$(file_sha256 "$(derper_manual_key_file)")
curl -ksS --max-time 5 "https://127.0.0.1:$DERP_PORT/" >"$artifacts/baseline-http.txt"
ok '真实 systemd + 专用用户 + standard 加固 + DERP TLS/STUN 基线'
assert_old_files() {
  [[ "$(file_sha256 "$BIN_PATH")" == "$old_hash" ]] || fail '二进制未回退'
  [[ "$(file_sha256 "$SERVICE_PATH")" == "$unit_hash" ]] || fail 'unit 未回退'
  [[ "$(file_sha256 "$(derper_config_path)")" == "$config_hash" ]] || fail '节点身份未回退'
  [[ "$(cat "$NODE_STATE_DIR/gb-state")" == old-state ]] || fail '附加节点状态未回退'
  [[ "$(file_sha256 "$(derper_manual_cert_file)")" == "$cert_hash" ]] || fail '证书变化'
  [[ "$(file_sha256 "$(derper_manual_key_file)")" == "$key_hash" ]] || fail '私钥变化'
}
assert_old_live() {
  assert_old_files
  service_verified_running || fail '旧服务真实复验失败'
  local pid
  pid=$(systemctl show derper -p MainPID --value)
  [[ "$(sha256sum "/proc/$pid/exe" | awk '{print $1}')" == "$old_hash" ]] || fail '运行进程仍为候选'
  [[ ! -e "$DEPLOY_STATE_DIR/incomplete" ]] || fail '恢复后标记未清除'
}
printf '#!/bin/sh\nexit 42\n' >"$tmp/reject"
chmod 755 "$tmp/reject"
if publish_derper_candidate "$tmp/reject" >"$artifacts/reject.log" 2>&1; then fail '接受坏候选'; fi
assert_old_files
[[ "$(systemctl show derper -p MainPID --value)" == "$baseline_pid" ]] || fail '坏候选打断旧进程'
ok '坏候选拒绝，旧进程与文件保持'

# 帮助自检可通过，但 systemd 启动后立即退出；故障输入不代替服务管理器。
printf '#!/bin/sh\nif [ "$1" = -h ]; then echo "  -a address -stun -stun-port port -c file"; exit 0; fi\nexit 42\n' >"$tmp/crash"
chmod 755 "$tmp/crash"
(
  publish_derper_candidate "$tmp/crash"
  printf '\n' >>"$(derper_config_path)"
  printf 'candidate-state\n' >"$NODE_STATE_DIR/gb-state"
  SECURITY_LEVEL=basic
  write_systemd_service
) >"$artifacts/start-failure.log" 2>&1 && fail '启动失败竟返回成功'
assert_old_live
ok '真实启动失败返回非零，旧二进制、unit、身份和运行进程完整回退'
# 独立用例不共享 systemd 启动频率计数；单个失败/回退用例内部不干预计数。
systemctl reset-failed derper

# 同一个真实 ELF 尾部加标记产生不同摘要，验证产物切换，不冒充跨版本兼容验证。
cp "$fixture" "$tmp/candidate"
printf '\nDERPER_GB_CANDIDATE\n' >>"$tmp/candidate"
chmod 755 "$tmp/candidate"
new_hash=$(file_sha256 "$tmp/candidate")
[[ "$new_hash" != "$old_hash" ]] || fail '候选摘要未改变'
(
  publish_derper_candidate "$tmp/candidate"
  systemctl restart derper
  service_verified_running
  touch "$tmp/switched"
  exec sleep 300
) >"$artifacts/interruption-worker.log" 2>&1 &
worker=$!
for ((i=0; i<40; i++)); do [[ ! -f "$tmp/switched" ]] || break; sleep 1; done
[[ -f "$tmp/switched" ]] || fail '中断注入点未到达'
kill -KILL "$worker"
wait "$worker" 2>/dev/null || true
[[ -f "$DEPLOY_STATE_DIR/incomplete" ]] || fail 'SIGKILL 后缺少标记'
pid=$(systemctl show derper -p MainPID --value)
[[ "$(sha256sum "/proc/$pid/exe" | awk '{print $1}')" == "$new_hash" ]] || fail '未真正运行候选'
if bash "$SCRIPT" --repair --ip "$IP_ADDR" --no-verify-clients >"$artifacts/interruption-block.log" 2>&1; then fail '普通覆盖未阻断'; fi
bash "$SCRIPT" --recover-interrupted >"$artifacts/interruption-recover.log" 2>&1
assert_old_live
ok 'SIGKILL 留标记、阻断普通覆盖，独立 CLI 恢复磁盘和真实旧进程'
systemctl reset-failed derper

publish_derper_candidate "$tmp/candidate"
mkdir -p /etc/systemd/system/derper.service.d
printf '[Unit]\nConditionPathExists=/root/DERPER_GB_ALLOW_START\n' >/etc/systemd/system/derper.service.d/gb-block.conf
systemctl daemon-reload
if bash "$SCRIPT" --recover-interrupted >"$artifacts/recovery-failure.log" 2>&1; then fail '恢复失败返回成功'; fi
[[ -f "$DEPLOY_STATE_DIR/incomplete" && -f "$DEPLOY_STATE_DIR/recovery/binary" ]] || fail '恢复失败删除备份/标记'
[[ "$(file_sha256 "$DEPLOY_STATE_DIR/recovery/binary")" == "$old_hash" ]] || fail '恢复备份损坏'
cp "$DEPLOY_STATE_DIR/incomplete" "$artifacts/failed-recovery-marker.txt"
rm /etc/systemd/system/derper.service.d/gb-block.conf
rmdir /etc/systemd/system/derper.service.d
systemctl daemon-reload
bash "$SCRIPT" --recover-interrupted >"$artifacts/recovery-retry.log" 2>&1
assert_old_live
ok '真实恢复复验失败非零且保留备份/标记，解除故障后再次显式恢复成功'
systemctl reset-failed derper

systemctl stop derper
publish_derper_candidate "$tmp/candidate"
systemctl start derper
service_verified_running
bash "$SCRIPT" --recover-interrupted >"$artifacts/inactive-recover.log" 2>&1
assert_old_files
! systemctl is-active --quiet derper || fail '原停止意图未恢复'
[[ ! -e "$DEPLOY_STATE_DIR/incomplete" ]] || fail '停止意图恢复标记未清除'
ok '原停止意图恢复，已启动的候选真实停止'
systemctl reset-failed derper
systemctl start derper

publish_derper_candidate "$tmp/candidate"
check_cert_status
ensure_compatible_certs >"$artifacts/cert-reuse.log" 2>&1
write_systemd_service >"$artifacts/upgrade.log" 2>&1
commit_cert_update
[[ "$(file_sha256 "$BIN_PATH")" == "$new_hash" ]] || fail '升级未发布候选'
pid=$(systemctl show derper -p MainPID --value)
[[ "$(sha256sum "/proc/$pid/exe" | awk '{print $1}')" == "$new_hash" ]] || fail '升级进程未更换'
[[ "$(file_sha256 "$(derper_config_path)")" == "$config_hash" ]] || fail '升级改变身份'
[[ "$(file_sha256 "$(derper_manual_cert_file)")" == "$cert_hash" ]] || fail '升级改变证书'
[[ "$(file_sha256 "$(derper_manual_key_file)")" == "$key_hash" ]] || fail '升级改变私钥'
[[ ! -e "$DEPLOY_STATE_DIR/incomplete" ]] || fail '成功升级未提交'
ok '正常产物切换复用证书、私钥和节点身份，更换真实进程并清除标记'

install_healthcheck_cron >"$artifacts/timer-install.log" 2>&1
systemctl is-active --quiet derper-healthcheck.timer || fail 'timer 未启用'
systemctl start derper-healthcheck.service >"$artifacts/timer-run.log" 2>&1
[[ "$(systemctl show derper-healthcheck.service -p ExecMainStatus --value)" == 0 ]] || fail '健康任务失败'
grep -q '^derper_healthy 1$' "$METRICS_TEXTFILE" || fail '未实际生成健康指标'
cp "$METRICS_TEXTFILE" "$artifacts/metrics.prom"
systemctl cat derper-healthcheck.service derper-healthcheck.timer >"$artifacts/generated-units.txt"
remove_healthcheck_cron >"$artifacts/timer-remove.log" 2>&1
purge_healthcheck_program >>"$artifacts/timer-remove.log" 2>&1
systemctl daemon-reload
[[ ! -e /etc/systemd/system/derper-healthcheck.timer ]] || fail 'timer 清理失败'
ok '生成的 timer/oneshot 实际执行成功并生成健康指标，调度与副本已清理'
if [[ "${DERPER_INTEGRATION_C:-0}" == 1 ]]; then
  mkdir -p "$artifacts/c"
  printf 'CONFIG_VERSION=1\nIP_ADDR=127.0.0.1\nALLOW_NON_GLOBAL_IP=1\nREGION_NAME=VM-Test-Relay\n' >"$tmp/deploy.conf"
  bash "$SCRIPT" status --config "$tmp/deploy.conf" --format json --state-file "$artifacts/c/state.json" >"$artifacts/c/status.json" 2>"$artifacts/c/status.log"
  bash "$SCRIPT" derpmap --config "$tmp/deploy.conf" >"$artifacts/c/derpmap.json" 2>"$artifacts/c/derpmap.log"
  python3 - "$artifacts/c" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); s=json.loads((p/'status.json').read_text()); state=json.loads((p/'state.json').read_text()); m=json.loads((p/'derpmap.json').read_text())['Regions']['900']
assert s['result']=='healthy' and s['layers']['h3']=='not_checked'
assert s['target']['derp_port']==30443 and s['target']['region_name']=='VM-Test-Relay'
assert state['sampled_at']==s['sampled_at'] and state['last_success_at']>0
assert m['Nodes'][0]['CertName']=='sha256-raw:'+s['certificate']['live_sha256']
PY
  ok 'C1/C2真实CLI配置、JSON、持久状态和derpMap一致'
  cp "$SCRIPT" "$tmp/standalone.sh"
  bash "$tmp/standalone.sh" status --config "$tmp/deploy.conf" --format json >"$artifacts/c/standalone.json" 2>"$artifacts/c/standalone.log"
  systemctl reset-failed derper
  bash "$SCRIPT" deploy --binary "$fixture" --derper-version v1.104.1 --ip "$IP_ADDR" --derp-port "$DERP_PORT" --stun-port "$STUN_PORT" --no-verify-clients --allow-non-global-ip --yes >"$artifacts/c/import.log" 2>&1
  assert_old_live
  ok 'C2真实本地ELF从完整CLI导入，复用证书和身份，单文件副本可独立运行'
  systemctl reset-failed derper
  if bash "$SCRIPT" deploy --binary "$tmp/candidate" --derper-version v1.104.1 --ip "$IP_ADDR" --derp-port "$DERP_PORT" --stun-port "$STUN_PORT" --no-verify-clients --allow-non-global-ip --yes --require-h3 >"$artifacts/c/gate.log" 2>&1; then fail 'H3缺失仍提交发布'; fi
  assert_old_live
  ok 'C3要求H3但缺探针时，在切换前阻断'
  cat >"$tmp/failed-probe" <<'PROBE'
#!/bin/bash
printf 'schema=1\nregion_id=900\nip=127.0.0.1\nderp_port=30443\nstun_port=33478\nchecked_at=%s\nderp=failed\nstun=ok\n' "$(date +%s)"
exit 1
PROBE
  chmod 755 "$tmp/failed-probe"
  systemctl reset-failed derper
  if bash "$SCRIPT" deploy --binary "$tmp/candidate" --derper-version v1.104.1 --ip "$IP_ADDR" --derp-port "$DERP_PORT" --stun-port "$STUN_PORT" --no-verify-clients --allow-non-global-ip --yes --external-probe "$tmp/failed-probe" >"$artifacts/c/probe-failed-gate.log" 2>&1; then fail '外部探针故障仍提交发布'; fi
  assert_old_live
  ok 'C3合成协议故障经真实发布门禁触发完整回退（不作为真实H3证据）'
  printf 'derper_metrics_unixtime 1\n' >"$tmp/stale.prom"
  rc=0
  bash "$SCRIPT" status --config "$tmp/deploy.conf" --format json --metrics-source "$tmp/stale.prom" >"$artifacts/c/stale.json" 2>"$artifacts/c/stale.log" || rc=$?
  [[ "$rc" == 2 ]] || fail '过期指标未返回未知'
  python3 - "$artifacts/c/stale.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); assert s['result']=='unknown' and s['metrics']['freshness']=='stale'
PY
  ok 'C3过期指标在真实CLI中标记stale/unknown'
fi
# BUG-081：真实 systemd 下，原absent意图也要移除新unit并刷新缓存。
systemctl stop derper
cp -p "$SERVICE_PATH" "$tmp/saved-unit"
rm "$SERVICE_PATH"
systemctl daemon-reload
cp -p "$(derper_config_path)" "$INSTALL_DIR/derper.json"
migrate_node_state >"$artifacts/absent-migrate.log" 2>&1
state_before=$(read_kv_value "$(deploy_state_root)/recovery/manifest" state_sha256)
[[ "$(read_kv_value "$(deploy_state_root)/recovery/manifest" unit_sha256)" == absent ]] || fail '应记录unit原先不存在'
cp -p "$tmp/saved-unit" "$SERVICE_PATH"
printf 'new-state\n' >"$NODE_STATE_DIR/new-gb-state"
printf 'hidden-new-state\n' >"$NODE_STATE_DIR/.new-gb-state"
systemctl daemon-reload
rollback_deploy_change >"$artifacts/absent-rollback.log" 2>&1 || fail 'absent意图真实回退失败'
[[ ! -e "$SERVICE_PATH" && ! -e "$NODE_STATE_DIR/new-gb-state" && ! -e "$NODE_STATE_DIR/.new-gb-state" ]] || fail '新unit或附加状态残留'
[[ "$(recovery_state_digest "$NODE_STATE_DIR")" == "$state_before" ]] || fail '真实回退状态集合不一致'
[[ ! -e "$(deploy_state_root)/incomplete" ]] || fail '成功回退后标记残留'
if systemctl cat derper.service >/dev/null 2>&1; then fail 'systemd缓存中仍存在新unit'; fi
ok 'BUG-081真实systemd回退移除原先不存在的unit与新增状态，刷新缓存且保持停止意图'
cp -p "$tmp/saved-unit" "$SERVICE_PATH"
systemctl daemon-reload
systemctl reset-failed derper
systemctl start derper
systemctl is-active --quiet derper || fail '首装回退夹具必须真实运行'
write_incomplete_marker first-install
mkdir -p /etc/systemd/system/derper.service.d
printf '[Unit]\nRefuseManualStop=yes\n' >/etc/systemd/system/derper.service.d/refuse-stop.conf
systemctl daemon-reload
if rollback_deploy_change >"$artifacts/first-install-stop-failure.log" 2>&1; then fail '首装真实停止失败仍报成功'; fi
[[ -f "$BIN_PATH" && -f "$(deploy_state_root)/incomplete" ]] || fail '停止失败丢失首装候选或标记'
systemctl is-active --quiet derper || fail 'RefuseManualStop用例应仍在运行'
rm /etc/systemd/system/derper.service.d/refuse-stop.conf
systemctl daemon-reload
bash "$SCRIPT" --recover-interrupted >"$artifacts/first-install-retry.log" 2>&1 || fail '解除拒停后独立CLI恢复失败'
if systemctl is-active --quiet derper; then fail '首装回退未停止实际进程'; fi
[[ ! -e "$BIN_PATH" && ! -e "$(deploy_state_root)/incomplete" ]] || fail '确认停止后没有清理首装候选/标记'
ok 'BUG-067真实RefuseManualStop拒停保留候选/标记，解除后独立CLI重试先停服再清理'
printf 'old_binary=%s\ncandidate_binary=%s\nunit=%s\nnode_identity=%s\ncert=%s\n' "$old_hash" "$new_hash" "$unit_hash" "$config_hash" "$cert_hash" >"$artifacts/hashes.txt"
ok 'GB 真实 systemd 集成完成（不含跨版本/客户端鉴权/公网中继验证）'
