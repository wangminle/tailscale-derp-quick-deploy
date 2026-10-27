#!/usr/bin/env bash
# S2 修复行为回归：只操作临时目录，服务管理使用替身。
# 可传测试函数名单独运行；退出码 0=全部通过，1=有失败（累计列出）。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/deploy_derper_ip_selfsigned.sh"
fail() { echo "not ok - $*" >&2; exit 1; }

use_running_tailscaled() {
  local body="$1"
  printf '#!/bin/sh\n%s\n' "$body" >"$case_tmp/running-tailscaled"
  chmod 755 "$case_tmp/running-tailscaled"
  tailscaled_running_exe() { printf '%s\n' "$case_tmp/running-tailscaled"; }
}

setup_install() {
  DEPLOY_STATE_DIR="$case_tmp/deploy"
  INSTALL_DIR="$case_tmp/install"
  NODE_STATE_DIR="$case_tmp/state"
  BIN_PATH="$case_tmp/bin/derper"
  SERVICE_PATH="$case_tmp/derper.service"
  RUN_USER="$(id -un)"
  VERIFY_CLIENTS_MODE=off
  mkdir -p "$INSTALL_DIR/certs" "$NODE_STATE_DIR" "$(dirname "$BIN_PATH")"
  printf '#!/bin/sh\necho -- -a\n# old-binary\n' >"$BIN_PATH"
  printf '#!/bin/sh\necho -- -a\n# new-binary\n' >"$case_tmp/candidate"
  chmod 755 "$BIN_PATH" "$case_tmp/candidate"
  printf '[Service]\nUser=%s\nExecStart=%s -c %s/derper.json\n' "$RUN_USER" "$BIN_PATH" "$INSTALL_DIR" >"$SERVICE_PATH"
  printf '{"PrivateKey":"stable-node-key"}\n' >"$INSTALL_DIR/derper.json"
  printf 'cert-bytes\n' >"$INSTALL_DIR/certs/node.crt"
  runtime=inactive
  systemctl() {
    case "$1" in
      is-enabled) return 1 ;;
      is-active) [[ "$runtime" == active ]] ;;
      stop) runtime=inactive ;;
      start) runtime=active ;;
      *) return 0 ;;
    esac
  }
  verify_restored_service() { [[ "$runtime" == active ]]; }
}

record_migration_service_calls() {
  : >"$case_tmp/service-calls"
  runtime=active
  systemctl() {
    case "$1" in
      is-active) [[ "$runtime" == active ]] ;;
      stop) printf 'stop\n' >>"$case_tmp/service-calls"; runtime=inactive ;;
      start|restart) printf '%s\n' "$1" >>"$case_tmp/service-calls"; runtime=active ;;
      *) return 0 ;;
    esac
  }
}

prepare_ready_node_state() {
  printf 'current-node-identity\n' >"$NODE_STATE_DIR/derper.json"
  chmod 700 "$NODE_STATE_DIR"
  chmod 600 "$NODE_STATE_DIR/derper.json"
}

test_bug110_ready_state_skips_migration_and_keeps_outer_recovery() {
  setup_install
  prepare_ready_node_state
  record_migration_service_calls
  migrate_node_state || fail "就绪配置应直接成功"
  [[ ! -s "$case_tmp/service-calls" ]] || fail "配置已就绪不得停启服务"
  [[ ! -e "$DEPLOY_STATE_DIR/incomplete" ]] || fail "无状态变更不得建立迁移标记"
  [[ "$(cat "$INSTALL_DIR/derper.json")" == '{"PrivateKey":"stable-node-key"}' ]] || fail "不得清理遗留私钥副本"
  capture_and_promote_recovery || fail "外层发布应能建立恢复集"
  write_incomplete_marker switch || fail "应能写入外层标记"
  local marker_sum manifest_sum
  marker_sum=$(file_sha256 "$DEPLOY_STATE_DIR/incomplete")
  manifest_sum=$(file_sha256 "$DEPLOY_STATE_DIR/recovery/manifest")
  migrate_node_state && migrate_node_state || fail "重复准备应成功"
  [[ ! -s "$case_tmp/service-calls" ]] || fail "外层发布期间也不得重复停启"
  [[ "$(file_sha256 "$DEPLOY_STATE_DIR/incomplete")" == "$marker_sum" && "$(file_sha256 "$DEPLOY_STATE_DIR/recovery/manifest")" == "$manifest_sum" ]] || fail "跳过迁移必须原样保留外层恢复材料"
  [[ "$(cat "$NODE_STATE_DIR/derper.json")" == current-node-identity ]] || fail "遗留文件不得覆盖当前身份"
}

test_bug110_first_migration_stops_once_and_keeps_recovery() {
  setup_install
  chmod 700 "$NODE_STATE_DIR"
  record_migration_service_calls
  migrate_node_state || fail "首次迁移必须成功"
  [[ "$(cat "$case_tmp/service-calls")" == $'stop\nstart' ]] || fail "首次迁移必须停服一次并恢复运行"
  [[ -f "$DEPLOY_STATE_DIR/incomplete" && -f "$DEPLOY_STATE_DIR/recovery/manifest" ]] || fail "服务最终验收前必须保留首次迁移恢复集"
  migrate_node_state || fail "同一事务内重复迁移应成功"
  [[ "$(cat "$case_tmp/service-calls")" == $'stop\nstart' ]] || fail "首次迁移完成后不得再停启"
  rollback_deploy_change || fail "跳过重复迁移后仍应能回退"
  [[ ! -e "$NODE_STATE_DIR/derper.json" ]] || fail "回退必须恢复当前配置原先不存在的状态"
}

test_bug110_permission_repair_still_migrates() {
  setup_install
  prepare_ready_node_state
  chmod 644 "$NODE_STATE_DIR/derper.json"
  record_migration_service_calls
  migrate_node_state || fail "配置权限不符仍需修复"
  [[ "$(cat "$case_tmp/service-calls")" == $'stop\nstart' ]] || fail "权限修复必须保留停服保护"
  node_config_readable_by_run_user "$NODE_STATE_DIR/derper.json" || fail "修复后配置应为运行用户所有且0600"
  [[ -f "$DEPLOY_STATE_DIR/incomplete" ]] || fail "权限修复必须保留恢复材料"
  migrate_node_state || fail "修复后再次准备应成功"
  [[ "$(cat "$case_tmp/service-calls")" == $'stop\nstart' ]] || fail "权限修复完成后不得重复停启"
}

test_bug110_unit_write_has_only_final_restart() {
  setup_install
  prepare_ready_node_state
  record_migration_service_calls
  # 保留实际配置准备和用户布局入口；只替换root权限及最终发布的外部副作用。
  chown() { :; }
  harden_cert_dir() { :; }
  configure_service_user_and_socket() { setup_service_user; SERVICE_RUN_GROUP="$RUN_USER"; }
  prepare_derper_exec_start_line() { DERPER_EXEC_START_LINE="$BIN_PATH -c $NODE_STATE_DIR/derper.json"; }
  deploy_and_verify_derper_service() { systemctl restart derper; }
  write_systemd_service || fail "unit编排应成功"
  [[ "$(cat "$case_tmp/service-calls")" == restart ]] || fail "配置和布局不得额外停启，只允许最终unit发布重启"
  local victim="$case_tmp/victim"
  printf 'unchanged\n' >"$victim"
  rm "$NODE_STATE_DIR/derper.json"
  ln -s "$victim" "$NODE_STATE_DIR/derper.json"
  if migrate_node_state >/dev/null 2>&1; then fail "就绪优化不得放行符号链接配置"; fi
  [[ "$(cat "$victim")" == unchanged ]] || fail "不得修改链接目标"
}

test_bug055_standard_daemon_identity() {
  VERIFY_CLIENTS_MODE=on
  local canary="$case_tmp/disk-tailscaled-called"
  printf '#!/bin/sh\n# tailscale.com v1.104.1\necho -- -a\n' >"$case_tmp/candidate"
  chmod 755 "$case_tmp/candidate"
  use_running_tailscaled 'printf "1.104.1\n  tailscale commit: abcdef0123456789abcdef0123456789abcdef01\n  other commit: 1111111111111111111111111111111111111111\n"'
  tailscaled() { echo called >"$canary"; printf 'tailscale commit: bbbbbbbbbbbb\n'; }
  resolve_derper_module_version() { printf 'v1.104.1\n'; }
  candidate_matches_running_daemon "$case_tmp/candidate" || fail "标准 daemon 输出的同源候选必须通过"
  [[ ! -e "$canary" ]] || fail "同源门禁不得执行磁盘上的 tailscaled"
  resolve_derper_module_version() { printf 'v1.104.2\n'; }
  if candidate_matches_running_daemon "$case_tmp/candidate" >/dev/null 2>&1; then
    fail "不同来源候选必须被拒绝"
  fi
  use_running_tailscaled 'printf "1.104.1\n  other commit: abcdef0123456789abcdef0123456789abcdef01\n"'
  if tailscaled_daemon_revision; then fail "不能把 other commit 冒充 tailscale commit"; fi
  use_running_tailscaled 'printf "1.104.1\n  tailscale commit: malformed\n"'
  if tailscaled_daemon_revision; then fail "畸形 commit 必须拒绝"; fi
}

test_bug070_offline_version_keeps_suffix() {
  local ver bin="$case_tmp/module-bin"
  go() { return 1; }
  strings() { return 127; }
  resolve_derper_module_version() { return 1; }
  printf 'go1.22.6\ntailscale.com/cmd/derper v1.104.1-rc1\n' >"$bin"
  chmod 755 "$bin"
  BIN_PATH="$bin"
  ver=$(get_installed_derper_version || true)
  [[ "$ver" == "1.104.1-rc1" ]] || fail "无 Go 时必须保留 rc 后缀，实际 ${ver}"
  if same_derper_identity "$ver" "1.104.1"; then
    fail "rc 候选不能被当成正式版"
  fi
  printf 'go1.22.6\ntailscale.com/cmd/derper v1.104.2-0.20261021010203-aaaaaaaaaaaa\n' >"$bin"
  ver=$(get_installed_derper_version || true)
  [[ "$ver" == "1.104.2-0.20261021010203-aaaaaaaaaaaa" ]] || fail "无 Go 时必须保留伪版本，实际 ${ver}"
  same_derper_identity "$ver" "aaaaaaaaaaaa" || fail "完整伪版本必须能离线匹配 daemon commit"
  if same_derper_identity "1.104.2" "aaaaaaaaaaaa"; then
    fail "截断后的正式版不能冒充该 commit"
  fi
}

test_bug059_upgrade_migration_keeps_snapshot() {
  setup_install
  publish_derper_candidate "$case_tmp/candidate" || fail "候选应能发布"
  local old_sum
  old_sum=$(file_sha256 "$DEPLOY_STATE_DIR/recovery/binary")
  prepare_derper_config || fail "升级中的迁移应成功"
  prepare_derper_config || fail "重复准备配置应幂等"
  [[ "$(file_sha256 "$DEPLOY_STATE_DIR/recovery/binary")" == "$old_sum" ]] || fail "迁移不得覆盖升级的旧二进制恢复集"
  [[ -f "$DEPLOY_STATE_DIR/incomplete" ]] || fail "服务验证前必须保留外层标记"
  [[ "$(read_kv_value "$DEPLOY_STATE_DIR/incomplete" phase)" == switch ]] || fail "不能把外层 switch 标记改成 migrate"
  rollback_deploy_change || fail "后续服务失败应能回退"
  [[ "$(tail -n1 "$BIN_PATH")" == '# old-binary' ]] || fail "回退必须恢复旧二进制"
  [[ ! -e "$DEPLOY_STATE_DIR/incomplete" ]] || fail "成功回退后应清除标记"
}

test_bug059_migration_failure_preserves_outer_marker() {
  setup_install
  publish_derper_candidate "$case_tmp/candidate" || fail "候选应能发布"
  local sum rc=0
  sum=$(file_sha256 "$DEPLOY_STATE_DIR/recovery/binary")
  install_without_following_link() { return 1; }
  migrate_node_state >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || fail "迁移写入失败必须失败"
  [[ -f "$DEPLOY_STATE_DIR/incomplete" ]] || fail "迁移失败不得清除外层升级标记"
  [[ "$(file_sha256 "$DEPLOY_STATE_DIR/recovery/binary")" == "$sum" ]] || fail "迁移失败不得破坏唯一旧版本"
}

test_bug059_standalone_migration_waits_for_service_commit() {
  setup_install
  migrate_node_state || fail "独立迁移应成功"
  [[ -f "$DEPLOY_STATE_DIR/incomplete" ]] || fail "新 unit 验证前不得提前提交迁移"
  [[ "$(read_kv_value "$DEPLOY_STATE_DIR/incomplete" phase)" == migrate ]] || fail "独立迁移应记录 migrate 阶段"
  commit_deploy_change || fail "最终验证后应能提交"
  [[ ! -e "$DEPLOY_STATE_DIR/incomplete" ]] || fail "提交应清除标记"
}

test_bug060_rollback_uses_saved_user() {
  setup_install
  local old_user="$RUN_USER" calls="$case_tmp/chown-calls"
  printf 'node-config\n' >"$NODE_STATE_DIR/derper.json"
  capture_and_promote_recovery || fail "应能保存旧状态"
  write_incomplete_marker switch || fail "应能记录切换"
  RUN_USER=new-target-user
  printf '[Service]\nUser=new-target-user\n' >"$SERVICE_PATH"
  running_as_root() { return 0; }
  chown() { printf '%s\n' "$*" >>"$calls"; return 0; }
  rollback_deploy_change || fail "恢复旧用户应成功"
  grep -E "^${old_user}:[^ ]+ ${NODE_STATE_DIR}$" "$calls" >/dev/null || fail "状态目录必须交还旧 unit 用户"
  if grep -F 'new-target-user:' "$calls" >/dev/null; then fail "回退不能把旧状态目录交给新用户"; fi
  [[ "$RUN_USER" == new-target-user ]] || fail "恢复身份不应污染调用方目标用户"
}

setup_uninstall() {
  setup_install
  HEALTHCHECK_PROGRAM_DIR="$case_tmp/stable"
  HEALTHCHECK_CRON_PATH="$case_tmp/cron/derper-healthcheck"
  HEALTHCHECK_UNIT_DIR="$case_tmp/units"
  mkdir -p "$HEALTHCHECK_PROGRAM_DIR" "$HEALTHCHECK_UNIT_DIR" "$(dirname "$HEALTHCHECK_CRON_PATH")"
  printf 'program\n' >"$HEALTHCHECK_PROGRAM_DIR/deploy_derper_ip_selfsigned.sh"
  printf 'scheduler=cron\n' >"$HEALTHCHECK_PROGRAM_DIR/status"
  require_root() { :; }
  remove_tls_connlimit() { :; }
  # 不允许用例删除任何真实系统路径。
  rm() {
    local arg
    for arg in "$@"; do
      case "$arg" in -*) ;; "$case_tmp"/*) ;; *) return 0 ;; esac
    done
    command rm "$@"
  }
}

test_bug053_purge_all_removes_stable_copy() {
  setup_uninstall
  PURGE=0 PURGE_ALL=0
  uninstall_derper >/dev/null || fail "普通卸载应成功"
  [[ -f "$HEALTHCHECK_PROGRAM_DIR/status" ]] || fail "普通卸载应保留稳定副本"
  PURGE=1 PURGE_ALL=1
  uninstall_derper >/dev/null || fail "完全卸载应成功"
  [[ ! -e "$HEALTHCHECK_PROGRAM_DIR" ]] || fail "完全卸载应删除稳定副本及状态"
}

test_bug053_cleanup_failure_is_not_success() {
  setup_uninstall
  PURGE=1 PURGE_ALL=1
  rm() {
    local arg
    for arg in "$@"; do [[ "$arg" != "$HEALTHCHECK_PROGRAM_DIR/status" ]] || return 1; done
    command rm "$@"
  }
  local rc=0 out
  out=$(uninstall_derper 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "副本无法删除时不能返回完全卸载成功"
  [[ "$out" != *'完成：已卸载'* ]] || fail "删除失败不能输出完成"
}

test_bug053_empty_directory_failure_is_not_success() {
  setup_uninstall
  PURGE=1 PURGE_ALL=1
  rmdir() {
    [[ "$1" != "$HEALTHCHECK_PROGRAM_DIR" ]] || return 1
    command rmdir "$@"
  }
  local rc=0
  uninstall_derper >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || fail "空副本目录无法删除时必须报告不完整清理"
}

test_bug061_scheduled_healthcheck_keeps_non_global_ip_opt_in() {
  IP_ADDR=127.0.0.1
  VERIFY_CLIENTS_MODE=off
  ALLOW_NON_GLOBAL_IP=1
  render_healthcheck_commands /usr/local/lib/derper-deploy/deploy_derper_ip_selfsigned.sh "$IP_ADDR" "$case_tmp/metrics.prom"
  [[ "$BASH_HEALTHCHECK_CMD" == *' --allow-non-global-ip'* ]] || fail "cron 丢失显式内网测试许可"
  [[ "$SYSTEMD_HEALTHCHECK_EXEC" == *' --allow-non-global-ip'* ]] || fail "systemd 丢失显式内网测试许可"
  ALLOW_NON_GLOBAL_IP=0
  render_healthcheck_commands /usr/local/lib/derper-deploy/deploy_derper_ip_selfsigned.sh 47.120.74.191 "$case_tmp/metrics.prom"
  [[ "$BASH_HEALTHCHECK_CMD" != *' --allow-non-global-ip'* && "$SYSTEMD_HEALTHCHECK_EXEC" != *' --allow-non-global-ip'* ]] || fail "默认调度不应额外放宽 IP 校验"
}

test_bug077_running_exe_not_disk_binary() {
  local src="$case_tmp/tailscaled.c" pid="" rev="" disk_rev=""
  cat >"$src" <<'EOF'
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "--version") == 0) {
    printf("tailscale commit: %s\n", COMMIT);
    return 0;
  }
  for (;;) pause();
  return 0;
}
EOF
  command -v gcc >/dev/null 2>&1 || fail "需要 gcc 才能区分运行中的 tailscaled 与磁盘文件"
  gcc -std=c11 -DCOMMIT='"aaaaaaaaaaaa"' -o "$case_tmp/live-a" "$src" || fail "无法编译运行中的 daemon"
  gcc -std=c11 -DCOMMIT='"bbbbbbbbbbbb"' -o "$case_tmp/disk-b" "$src" || fail "无法编译磁盘上的 tailscaled"
  mkdir -p "$case_tmp/bin"
  cp "$case_tmp/live-a" "$case_tmp/bin/tailscaled"
  "$case_tmp/bin/tailscaled" >/dev/null 2>&1 &
  pid=$!
  BUG077_PID=$pid
  trap 'if [[ -n "${BUG077_PID:-}" ]]; then kill "$BUG077_PID" 2>/dev/null || true; wait "$BUG077_PID" 2>/dev/null || true; fi; rm -rf "$case_tmp"' EXIT
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [[ -x "/proc/${pid}/exe" ]] && break
    sleep 0.05
  done
  [[ -d "/proc/${pid}" ]] || fail "测试进程没有启动"
  mv -f "$case_tmp/disk-b" "$case_tmp/bin/tailscaled"
  systemctl() {
    if [[ "$*" == "show -p MainPID --value tailscaled" ]]; then
      printf '%s\n' "$BUG077_PID"
      return 0
    fi
    return 1
  }
  rev=$(tailscaled_daemon_revision) || fail "应读取仍在运行的旧 inode"
  [[ "$rev" == "aaaaaaaaaaaa" ]] || fail "门禁读到磁盘版本 ${rev}，运行中的仍是 aaaaaaaaaaaa"
  disk_rev=$("$case_tmp/bin/tailscaled" --version | awk '{print $3}')
  [[ "$disk_rev" == "bbbbbbbbbbbb" ]] || fail "磁盘二进制应已换成 b，实际 ${disk_rev}"
  VERIFY_CLIENTS_MODE=on
  resolve_derper_module_version() { return 1; }
  go() { return 1; }
  printf '#!/bin/sh\n# tailscale.com/cmd/derper v1.104.2-0.20261021010203-bbbbbbbbbbbb\necho -- -a\n' >"$case_tmp/candidate-b"
  printf '#!/bin/sh\n# tailscale.com/cmd/derper v1.104.2-0.20261021010203-aaaaaaaaaaaa\necho -- -a\n' >"$case_tmp/candidate-a"
  chmod 755 "$case_tmp/candidate-a" "$case_tmp/candidate-b"
  if candidate_matches_running_daemon "$case_tmp/candidate-b" >/dev/null 2>&1; then
    fail "磁盘版本 b 的候选不得通过仍在运行的 a"
  fi
  candidate_matches_running_daemon "$case_tmp/candidate-a" || fail "运行中 commit a 的同源候选必须通过"
}

test_bug077_ambiguous_daemon_pid_is_refused() {
  systemctl() { printf '0\n'; return 0; }
  pgrep() { printf '111\n222\n'; }
  if tailscaled_daemon_pid >/dev/null; then
    fail "多个 tailscaled 进程时必须拒绝，不能猜测"
  fi
  pgrep() { return 1; }
  if tailscaled_daemon_pid >/dev/null; then
    fail "没有正在运行的 tailscaled 时必须拒绝"
  fi
  VERIFY_CLIENTS_MODE=on
  tailscaled() { echo disk >"$case_tmp/disk-used"; printf 'tailscale commit: aaaaaaaaaaaa\n'; }
  printf '#!/bin/sh\n# tailscale.com v1.104.1\necho -- -a\n' >"$case_tmp/candidate"
  chmod 755 "$case_tmp/candidate"
  if candidate_matches_running_daemon "$case_tmp/candidate" >/dev/null 2>&1; then
    fail "无法确认运行身份时不得放行候选"
  fi
  [[ ! -e "$case_tmp/disk-used" ]] || fail "身份无法确认时不得改去执行磁盘 tailscaled"
}

test_bug078_rollback_restores_current_identity() {
  setup_install
  printf 'stale-legacy-key\n' >"$INSTALL_DIR/derper.json"
  printf 'current-node-key\n' >"$NODE_STATE_DIR/derper.json"
  printf 'current-state\n' >"$NODE_STATE_DIR/node.key"
  migrate_node_state || fail "当前身份已存在时迁移应成功"
  [[ "$(cat "$NODE_STATE_DIR/derper.json")" == "current-node-key" ]] || fail "迁移不得先改掉当前身份"
  [[ "$(cat "$DEPLOY_STATE_DIR/recovery/config")" == "current-node-key" ]] || fail "恢复集必须保存当前身份，不能只存遗留配置"
  [[ "$(cat "$DEPLOY_STATE_DIR/recovery/state/node.key")" == "current-state" ]] || fail "恢复集必须保存当前状态"
  printf 'replaced-during-failure\n' >"$NODE_STATE_DIR/derper.json"
  rollback_deploy_change || fail "回退应恢复迁移前的当前身份"
  [[ "$(cat "$NODE_STATE_DIR/derper.json")" == "current-node-key" ]] || fail "回退不得把当前身份换成遗留密钥"
  [[ "$(cat "$NODE_STATE_DIR/node.key")" == "current-state" ]] || fail "回退必须写回迁移前的状态"
  [[ "$(cat "$INSTALL_DIR/derper.json")" == "stale-legacy-key" ]] || fail "遗留文件应保持原样"
  [[ ! -e "$DEPLOY_STATE_DIR/incomplete" ]] || fail "成功回退后才可以清除标记"
}

test_bug078_rollback_removes_created_config() {
  setup_install
  [[ ! -e "$NODE_STATE_DIR/derper.json" ]] || fail "此用例的当前配置必须尚不存在"
  local legacy
  legacy=$(cat "$INSTALL_DIR/derper.json")
  migrate_node_state || fail "只存在遗留配置时迁移应成功"
  [[ -f "$NODE_STATE_DIR/derper.json" ]] || fail "迁移应把遗留身份复制到当前路径"
  [[ ! -f "$DEPLOY_STATE_DIR/recovery/config" ]] || fail "迁移前没有当前配置时，恢复集不能把遗留文件当成当前身份"
  rollback_deploy_change || fail "回退应撤掉迁移新建的当前配置"
  [[ ! -e "$NODE_STATE_DIR/derper.json" ]] || fail "回退必须恢复成迁移前不存在当前配置"
  [[ "$(cat "$INSTALL_DIR/derper.json")" == "$legacy" ]] || fail "遗留身份文件必须还在"
  [[ ! -e "$DEPLOY_STATE_DIR/incomplete" ]] || fail "成功回退后才可以清除标记"
}

test_bug079_corrupt_payload_is_not_restored() {
  setup_install
  printf 'live-config\n' >"$NODE_STATE_DIR/derper.json"
  printf 'live-state\n' >"$NODE_STATE_DIR/node.key"
  capture_and_promote_recovery || fail "应能建立恢复集"
  write_incomplete_marker switch || fail "应能记录未完成变更"
  printf 'BROKEN-CONFIG\n' >"$DEPLOY_STATE_DIR/recovery/config"
  printf 'BROKEN-STATE\n' >"$DEPLOY_STATE_DIR/recovery/state/node.key"
  local rc=0
  verify_recovery_dir "$DEPLOY_STATE_DIR/recovery" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || fail "配置或状态被改过后，二进制摘要正确也不能通过校验"
  rc=0
  rollback_deploy_change >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || fail "损坏的恢复载荷不得回退成功"
  [[ "$(cat "$NODE_STATE_DIR/derper.json")" == "live-config" ]] || fail "校验失败不得把损坏配置写回"
  [[ "$(cat "$NODE_STATE_DIR/node.key")" == "live-state" ]] || fail "校验失败不得把损坏状态写回"
  [[ -e "$DEPLOY_STATE_DIR/incomplete" ]] || fail "校验失败必须保留未完成标记"
  [[ -f "$DEPLOY_STATE_DIR/recovery/manifest" ]] || fail "校验失败不得丢掉恢复集"
}

test_bug080_untrusted_executable_is_not_run() {
  local exe="$case_tmp/untrusted" canary="$case_tmp/executed"
  printf '#!/bin/sh\necho executed >"%s"\necho "tailscale commit: aaaaaaaaaaaa"\n' "$canary" >"$exe"
  chmod 777 "$exe"
  tailscaled_running_exe() { printf '%s/untrusted\n' "$case_tmp"; }
  if tailscaled_daemon_revision >/dev/null 2>&1; then
    fail "可被其他用户改写的程序不得通过版本读取"
  fi
  [[ ! -e "$canary" ]] || fail "信任检查必须先于执行，不能先运行再拒绝"
}

test_bug081_rollback_restores_absent_unit_and_state_set() {
  setup_install
  rm "$SERVICE_PATH"
  printf 'current-key\n' >"$NODE_STATE_DIR/derper.json"
  printf 'old-state\n' >"$NODE_STATE_DIR/node.key"
  migrate_node_state || fail "应建立独立迁移恢复集"
  local expected
  expected=$(read_kv_value "$DEPLOY_STATE_DIR/recovery/manifest" state_sha256)
  printf '[Service]\nExecStart=/bin/false\n' >"$SERVICE_PATH"
  printf 'new-state\n' >"$NODE_STATE_DIR/new.key"
  rollback_deploy_change || fail "回退应完成"
  [[ ! -e "$SERVICE_PATH" ]] || fail "原先没有unit，回退必须移除新unit"
  [[ ! -e "$NODE_STATE_DIR/new.key" ]] || fail "回退必须移除新增受管状态"
  [[ "$(recovery_state_digest "$NODE_STATE_DIR")" == "$expected" ]] || fail "恢复后的完整状态必须与快照一致"
  [[ ! -e "$DEPLOY_STATE_DIR/incomplete" ]] || fail "成功才清除标记"
}

test_bug081_cleanup_failure_keeps_marker() {
  setup_install
  migrate_node_state || fail "应建立恢复集"
  printf 'cannot-remove\n' >"$NODE_STATE_DIR/new.key"
  rm() { [[ "${*: -1}" != "$NODE_STATE_DIR/new.key" ]] || return 1; command rm "$@"; }
  if rollback_deploy_change >/dev/null 2>&1; then fail "清理失败不得报回退成功"; fi
  [[ -f "$DEPLOY_STATE_DIR/incomplete" && -d "$DEPLOY_STATE_DIR/recovery" ]] || fail "失败必须保留恢复入口"
}

test_bug081_hidden_state_and_unsafe_entries() {
  setup_install
  printf 'hidden-original\n' >"$NODE_STATE_DIR/.identity"
  : >"$NODE_STATE_DIR/empty-state"
  migrate_node_state || fail "隐藏普通文件也必须备份"
  [[ -f "$DEPLOY_STATE_DIR/recovery/state/.identity" ]] || fail "不能静默遗漏隐藏状态"
  printf 'changed\n' >"$NODE_STATE_DIR/.identity"
  printf 'new\n' >"$NODE_STATE_DIR/.new"
  mkdir "$NODE_STATE_DIR/unmanaged-directory"
  printf 'preserve\n' >"$NODE_STATE_DIR/unmanaged-directory/file"
  if rollback_deploy_change >/dev/null 2>&1; then fail "遇到目录等非受管条目时必须拒绝，不能递归清理"; fi
  [[ -f "$NODE_STATE_DIR/unmanaged-directory/file" && -f "$DEPLOY_STATE_DIR/incomplete" ]] || fail "未知目录和恢复标记应保留"
  rmdir "$NODE_STATE_DIR/unmanaged-directory" 2>/dev/null && fail "不能删除非空目录"
  command rm "$NODE_STATE_DIR/unmanaged-directory/file"
  rmdir "$NODE_STATE_DIR/unmanaged-directory"
  rollback_deploy_change || fail "移除不支持条目后应能重试"
  [[ "$(cat "$NODE_STATE_DIR/.identity")" == hidden-original && ! -e "$NODE_STATE_DIR/.new" ]] || fail "隐藏状态必须恢复内容及存在性"
  [[ -f "$NODE_STATE_DIR/empty-state" && ! -s "$NODE_STATE_DIR/empty-state" ]] || fail "空状态文件也必须可恢复"
}

test_bug081_unit_cleanup_and_reload_failure_keep_marker() {
  setup_install
  rm "$SERVICE_PATH"
  migrate_node_state || fail "应保存unit缺失状态"
  printf '[Service]\nExecStart=/bin/false\n' >"$SERVICE_PATH"
  rm() { [[ "${*: -1}" != "$SERVICE_PATH" ]] || return 1; command rm "$@"; }
  if rollback_deploy_change >/dev/null 2>&1; then fail "unit删除失败不得报成功"; fi
  [[ -f "$DEPLOY_STATE_DIR/incomplete" && -f "$SERVICE_PATH" ]] || fail "删除失败必须保留标记"
  unset -f rm
  systemctl() { case "$1" in is-active|cat|daemon-reload) return 1 ;; start) fail "原absent意图不得启动" ;; *) return 0 ;; esac; }
  if rollback_deploy_change >/dev/null 2>&1; then fail "原absent意图也必须处理daemon-reload失败"; fi
  [[ -f "$DEPLOY_STATE_DIR/incomplete" && ! -e "$SERVICE_PATH" ]] || fail "reload失败保留标记，文件恢复可重试"
  systemctl() { case "$1" in is-active|cat) return 1 ;; *) return 0 ;; esac; }
  rollback_deploy_change || fail "修复reload后可幂等重试"
  [[ ! -e "$DEPLOY_STATE_DIR/incomplete" ]] || fail "最终成功才清标记"
}

if [[ "$#" -gt 0 ]]; then
  selected=("$@")
else
  selected=(test_bug055_standard_daemon_identity test_bug070_offline_version_keeps_suffix test_bug077_running_exe_not_disk_binary test_bug077_ambiguous_daemon_pid_is_refused test_bug078_rollback_restores_current_identity test_bug078_rollback_removes_created_config test_bug079_corrupt_payload_is_not_restored test_bug080_untrusted_executable_is_not_run test_bug081_rollback_restores_absent_unit_and_state_set test_bug081_cleanup_failure_keeps_marker test_bug081_hidden_state_and_unsafe_entries test_bug081_unit_cleanup_and_reload_failure_keep_marker test_bug059_upgrade_migration_keeps_snapshot test_bug059_migration_failure_preserves_outer_marker test_bug059_standalone_migration_waits_for_service_commit test_bug060_rollback_uses_saved_user test_bug053_purge_all_removes_stable_copy test_bug053_cleanup_failure_is_not_success test_bug053_empty_directory_failure_is_not_success test_bug061_scheduled_healthcheck_keeps_non_global_ip_opt_in)
  selected+=(test_bug110_ready_state_skips_migration_and_keeps_outer_recovery test_bug110_first_migration_stops_once_and_keeps_recovery test_bug110_permission_repair_still_migrates test_bug110_unit_write_has_only_final_restart)
fi
failed=0
for test_name in "${selected[@]}"; do
  if (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    case_tmp=$(mktemp -d)
    trap 'command rm -rf "$case_tmp"' EXIT
    "$test_name"
  ); then
    echo "ok - $test_name"
  else
    echo "not ok - $test_name" >&2
    failed=$((failed + 1))
  fi
done
[[ "$failed" -eq 0 ]]
