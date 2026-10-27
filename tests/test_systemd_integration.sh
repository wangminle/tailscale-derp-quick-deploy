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
   || systemctl cat derper-healthcheck.timer >/dev/null 2>&1 || systemctl cat derper-cert-maintain.timer >/dev/null 2>&1 \
   || [[ -e /etc/derper || -e /usr/local/lib/derper-deploy || -e /etc/systemd/system/derper.service.d || -e /etc/systemd/system/derper.service.certs-archive ]] || getent passwd derper-gb >/dev/null; then
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
{
  cat /etc/os-release
  uname -a
  systemd --version | head -1
  printf 'pid1=%s\nvirt=%s\n' "$(cat /proc/1/comm)" "$(systemd-detect-virt)"
  sha256sum "$SCRIPT" "$fixture"
} >"$artifacts/environment.txt"
tmp=$(mktemp -d /root/derper-gb.XXXXXXXX)
cleanup() {
  local rc=$?
  trap - EXIT
  [[ -z "${policy_fixture_pid:-}" ]] || { kill "$policy_fixture_pid" 2>/dev/null || true; wait "$policy_fixture_pid" 2>/dev/null || true; }
  rm -f /etc/systemd/system/derper.service.d/refuse-stop.conf /etc/systemd/system/derper.service.d/restart-once.conf /etc/systemd/system/derper.service.d/block-start.conf
  systemctl daemon-reload
  systemctl show derper -p MainPID -p ActiveState -p Result >"$artifacts/final-service.txt" 2>&1 || true
  journalctl -u derper -u derper-healthcheck -u derper-cert-maintain --no-pager >"$artifacts/journal.txt" 2>&1 || true
  systemctl disable --now derper-cert-maintain.timer derper-cert-maintain.service >/dev/null 2>&1 || true
  systemctl disable --now derper-healthcheck.timer >/dev/null 2>&1 || true
  systemctl disable --now derper.service >/dev/null 2>&1 || true
  systemctl stop derper.service >/dev/null 2>&1 || true
  systemctl stop derper-healthcheck.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/derper.service /etc/systemd/system/derper.service.bak.*
  rm -f /etc/systemd/system/derper-healthcheck.{service,timer} /etc/systemd/system/derper-cert-maintain.{service,timer}
  rm -rf /etc/systemd/system/derper.service.certs-archive
  rm -rf /etc/systemd/system/derper.service.d /etc/systemd/system/derper.service.certs-rollback
  rm -f /usr/local/bin/derper /etc/cron.d/derper-healthcheck
  rm -rf /opt/derper /var/lib/derper /var/lib/derper-deploy /usr/local/lib/derper-deploy "$tmp"
  rm -f /etc/derper/derper.env /etc/derper/policy-api.env
  rmdir /etc/derper 2>/dev/null || true
  systemctl daemon-reload
  systemctl reset-failed derper derper-healthcheck derper-cert-maintain >/dev/null 2>&1 || true
  userdel derper-gb >/dev/null 2>&1 || true
  if [[ ! -e /usr/local/bin/derper && ! -e /opt/derper && ! -e /etc/systemd/system/derper-healthcheck.timer ]] \
     && [[ ! -e /etc/systemd/system/derper.service.certs-archive && ! -e /etc/systemd/system/derper-cert-maintain.timer && ! -e /var/lib/derper-deploy && ! -e /etc/derper/policy-api.env ]] \
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
# D集成：systemd/服务/磁盘/HTTP均真实；云端只用显式loopback fixture，不是GD。
if [[ "${DERPER_INTEGRATION_D:-0}" == 1 ]]; then
  mkdir -p "$artifacts/d" "$tmp/policy"
  d_old_fp=$(live_cert_sha256_raw)
  python3 - "$tmp/policy/policy.json" "$d_old_fp" <<'DPY'
import json,pathlib,sys
node={'Name':'900a','RegionID':900,'HostName':'127.0.0.1','IPv4':'127.0.0.1','DERPPort':30443,'STUNPort':33478,'CertName':'sha256-raw:'+sys.argv[2]}
pathlib.Path(sys.argv[1]).write_text(json.dumps({'derpMap':{'Regions':{'900':{'RegionID':900,'RegionCode':'my-derp','RegionName':'VM-Test','Nodes':[node]}}}}))
DPY
  python3 "$ROOT_DIR/tests/fixtures/policy_api.py" --state-dir "$tmp/policy" --port-file "$tmp/policy/port" >"$artifacts/d/fixture.log" 2>&1 &
  policy_fixture_pid=$!
  for ((i=0; i<50; i++)); do [[ ! -f "$tmp/policy/port" ]] || break; sleep 0.1; done
  [[ -s "$tmp/policy/port" ]] || fail '本地策略fixture未启动'
  mkdir -p /etc/derper
  POLICY_CREDENTIAL_FILE=/etc/derper/policy-api.env
  printf 'TS_TAILNET=fixture.test\nTS_API_BASE=http://127.0.0.1:%s\nTS_API_CLIENT_ID=fixture\nTS_API_CLIENT_SECRET=fixture-only\n' "$(cat "$tmp/policy/port")" >"$POLICY_CREDENTIAL_FILE"
  chmod 600 "$POLICY_CREDENTIAL_FILE"
  TS_TAILNET=fixture.test
  CERT_DAYS=365
  CERT_LEAD_DAYS=30
  ENABLE_AUTO_MAINTAIN=1
  cp "$SCRIPT" "$tmp/maintenance-source.sh"
  chmod 644 "$tmp/maintenance-source.sh"
  SCRIPT_SELF="$tmp/maintenance-source.sh"
  apply_auto_maintain_policy >"$artifacts/d/install.log" 2>&1
  systemctl is-enabled --quiet derper-cert-maintain.timer || fail '维护timer未enable'
  systemctl is-active --quiet derper-cert-maintain.timer || fail '维护timer未激活'
  # 防止daily调度与下面的手动故障注入并发；实际oneshot仍通过systemd执行。
  systemctl stop derper-cert-maintain.timer
  systemctl stop derper-cert-maintain.service
  mv "$tmp/maintenance-source.sh" "$tmp/source-moved.sh"
  stable="$(deploy_state_root)/maintenance/deploy_derper_ip_selfsigned.sh"
  target_conf="$(deploy_state_root)/maintenance/target.conf"
  [[ -f "$stable" && "$(stat -c %a "$target_conf")" == 600 ]] || fail '维护副本/配置权限错误'
  grep -qx 'ALLOW_NON_GLOBAL_IP=1' "$target_conf" || fail '维护任务丢失内网显式放行'
  if runuser -u "$RUN_USER" -- test -r "$POLICY_CREDENTIAL_FILE"; then fail 'derper用户可读维护凭据'; fi
  systemctl start derper-cert-maintain.service >"$artifacts/d/idle.log" 2>&1
  [[ "$(read_maintenance_kv result)" == idle && "$(live_cert_sha256_raw)" == "$d_old_fp" ]] || fail '未到期任务意外换证'
  systemctl cat derper-cert-maintain.service derper-cert-maintain.timer >"$artifacts/d/generated-units.txt"
  cp "$target_conf" "$artifacts/d/target.conf"
  ok 'D真实timer启用、root凭据隔离、源脚本移走后稳定副本执行且未到期不换证'

  sed -i 's/^CERT_LEAD_DAYS=.*/CERT_LEAD_DAYS=365/' "$target_conf"
  systemctl start derper-cert-maintain.service >"$artifacts/d/due.log" 2>&1
  d_current_fp=$(live_cert_sha256_raw)
  cp "$(maintenance_status_path)" "$artifacts/d/due-status.txt"
  printf 'before=%s\nafter=%s\n' "$d_old_fp" "$d_current_fp" >"$artifacts/d/due-fingerprints.txt"
  [[ "$d_current_fp" != "$d_old_fp" && "$(read_maintenance_kv result)" == success_replaced ]] || fail '到期维护未更换实际服务身份'
  grep -q "sha256-raw:$d_current_fp" "$tmp/policy/policy.json" || fail '本地fixture与运行身份不一致'
  ok 'D到期oneshot通过真实HTTP fixture更新字段并加载新证书（非真实云端）'

  touch "$tmp/policy/deny"
  if systemctl start derper-cert-maintain.service >"$artifacts/d/revoked.log" 2>&1; then fail '撤权仍报维护成功'; fi
  [[ "$(live_cert_sha256_raw)" == "$d_current_fp" ]] || fail '撤权后更换了证书'
  [[ "$(read_maintenance_kv mode)" == manual && "$(read_maintenance_kv needs_manual)" == 1 ]] || fail '撤权未转人工'
  rm "$tmp/policy/deny"
  systemctl reset-failed derper-cert-maintain derper
  ok 'D真实oneshot撤权失败非零、旧服务保留并记录人工处理'

  # 仅首次ExecStartPre失败；恢复旧证书后的第二次真实restart成功。
  cat >"$INSTALL_DIR/reject-once.sh" <<'DSH'
#!/bin/sh
if [ ! -e /var/lib/derper/d-restart-attempted ]; then
  touch /var/lib/derper/d-restart-attempted
  exit 42
fi
DSH
  chmod 755 "$INSTALL_DIR/reject-once.sh"
  mkdir -p /etc/systemd/system/derper.service.d
  printf '[Service]\nExecStartPre=/bin/sh /opt/derper/reject-once.sh\n' >/etc/systemd/system/derper.service.d/restart-once.conf
  systemctl daemon-reload
  if systemctl start derper-cert-maintain.service >"$artifacts/d/restart-failed.log" 2>&1; then fail '故障注入仍报成功'; fi
  [[ -f /var/lib/derper/d-restart-attempted ]] || fail '未命中真实启动失败注入点'
  service_verified_running || fail '换证失败后旧服务未恢复'
  [[ "$(live_cert_sha256_raw)" == "$d_current_fp" ]] || fail '旧服务身份未确认恢复'
  grep -q "sha256-raw:$d_current_fp" "$tmp/policy/policy.json" || fail '反向补偿未恢复本地fixture字段'
  [[ "$(read_maintenance_kv result)" == failed ]] || fail '失败被误记成功'
  rm /etc/systemd/system/derper.service.d/restart-once.conf "$INSTALL_DIR/reject-once.sh" /var/lib/derper/d-restart-attempted
  systemctl daemon-reload
  systemctl reset-failed derper derper-cert-maintain
  ok 'D真实换证restart失败，旧磁盘/实际进程恢复后才反向补偿fixture指纹'

  # 新/旧两次启动均被真实Unit条件阻断：不得撤回仍在云端的新指纹。
  writes_before=$(cat "$tmp/policy/writes")
  printf '[Unit]\nConditionPathExists=/root/DERPER_D_ALLOW_START\n' >/etc/systemd/system/derper.service.d/block-start.conf
  systemctl daemon-reload
  if systemctl start derper-cert-maintain.service >"$artifacts/d/restore-failed.log" 2>&1; then fail '原服务恢复失败仍报成功'; fi
  d_pending_fp=$(read_rotation_kv new_sha256)
  [[ "$d_pending_fp" != "$d_current_fp" ]] || fail '失败用例未生成新候选身份'
  [[ "$(cat "$tmp/policy/writes")" == "$((writes_before + 1))" ]] || fail '旧服务未恢复时发生了反向云写'
  [[ "$(read_maintenance_kv result)" == needs_coordination && "$(read_maintenance_kv needs_manual)" == 1 ]] || fail '原服务恢复失败没有保留待协调'
  grep -q "sha256-raw:$d_pending_fp" "$tmp/policy/policy.json" || fail '未保留fixture新指纹'
  cp "$(maintenance_status_path)" "$artifacts/d/needs-coordination.txt"
  rm /etc/systemd/system/derper.service.d/block-start.conf
  systemctl daemon-reload
  systemctl reset-failed derper derper-cert-maintain
  systemctl start derper
  service_verified_running || fail '解除故障后旧服务仍不可用'
  [[ "$(live_cert_sha256_raw)" == "$d_current_fp" ]] || fail '解除故障后身份错误'
  # 测试执行人显式协调：恢复已确认后才调用字段级补偿；不是无人值守自动重试。
  load_policy_credentials
  obtain_policy_token
  local_old_cert_identity_restored || fail '人工协调前旧身份未通过确认'
  reverse_compensate_certname >"$artifacts/d/manual-coordination.log" 2>&1
  grep -q "sha256-raw:$d_current_fp" "$tmp/policy/policy.json" || fail '人工协调fixture字段失败'
  ok 'D旧服务无法恢复时保留新云端字段并转待协调，解除故障后显式核验再恢复'

  ENABLE_AUTO_MAINTAIN=0
  DISABLE_AUTO_MAINTAIN=1
  apply_auto_maintain_policy >"$artifacts/d/disable.log" 2>&1
  systemctl daemon-reload
  [[ "$(read_maintenance_kv intent)" == disabled && ! -e /etc/systemd/system/derper-cert-maintain.timer ]] || fail '显式停用未撤销登记/调度'
  ! systemctl is-active --quiet derper-cert-maintain.timer || fail '维护timer仍激活'
  DISABLE_AUTO_MAINTAIN=0
  SCRIPT_SELF="$SCRIPT"
  cert_hash=$(file_sha256 "$(derper_manual_cert_file)")
  key_hash=$(file_sha256 "$(derper_manual_key_file)")
  printf 'before=%s\nafter=%s\n' "$d_old_fp" "$d_current_fp" >"$artifacts/d/fingerprints.txt"
  kill "$policy_fixture_pid"
  wait "$policy_fixture_pid" 2>/dev/null || true
  policy_fixture_pid=''
  ok 'D停用登记与真实timer删除，最终卸载清理由EXIT断言检查'
fi

# BUG-081：真实 systemd 下，原absent意图也要移除新unit并刷新缓存。
systemctl stop derper
cp -p "$SERVICE_PATH" "$tmp/saved-unit"
rm "$SERVICE_PATH"
systemctl daemon-reload
cp -p "$(derper_config_path)" "$INSTALL_DIR/derper.json"
# BUG-110 会跳过已经就绪的状态目录；这里需真实构造待修复权限，
# 才能让迁移创建本用例专属的 absent-unit 恢复集，而非读取上一场景的记录。
chmod 755 "$NODE_STATE_DIR"
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
if [[ "${DERPER_INTEGRATION_D:-0}" == 1 ]]; then
  # 完整GB结束后再卸载，避免改变前面用例的基线。只写入/enable调度，不启动维护。
  install_cert_maintain_units >"$artifacts/d/reinstall-before-uninstall.log" 2>&1
  systemctl daemon-reload
  systemctl enable derper-cert-maintain.timer >>"$artifacts/d/reinstall-before-uninstall.log" 2>&1
  bash "$SCRIPT" uninstall --purge-all --yes >"$artifacts/d/uninstall.log" 2>&1
  [[ ! -e /etc/systemd/system/derper-cert-maintain.service && ! -e /etc/systemd/system/derper-cert-maintain.timer ]] || fail '完整卸载残留维护unit'
  [[ ! -e "$(deploy_state_root)/maintenance/deploy_derper_ip_selfsigned.sh" ]] || fail '完整卸载残留维护副本'
  ! systemctl is-enabled --quiet derper-cert-maintain.timer || fail '完整卸载仍有启用登记'
  ok 'D实际CLI完整卸载删除维护service/timer/副本及启用登记'
fi
ok 'GB 真实 systemd 集成完成（不含跨版本/客户端鉴权/公网中继验证）'
