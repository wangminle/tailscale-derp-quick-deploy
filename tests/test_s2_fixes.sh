#!/usr/bin/env bash
# S2 修复行为回归：只操作临时目录，服务管理使用替身。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/deploy_derper_ip_selfsigned.sh"
fail() { echo "not ok - $*" >&2; exit 1; }

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
      is-active) [[ "$runtime" == active ]] ;;
      stop) runtime=inactive ;;
      start) runtime=active ;;
      *) return 0 ;;
    esac
  }
  verify_restored_service() { [[ "$runtime" == active ]]; }
}

test_bug055_standard_daemon_identity() {
  VERIFY_CLIENTS_MODE=on
  printf '#!/bin/sh\n# tailscale.com v1.104.1\necho -- -a\n' >"$case_tmp/candidate"
  chmod 755 "$case_tmp/candidate"
  tailscaled() { printf '1.104.1\n  tailscale commit: abcdef0123456789abcdef0123456789abcdef01\n  other commit: 1111111111111111111111111111111111111111\n'; }
  resolve_derper_module_version() { printf 'v1.104.1\n'; }
  candidate_matches_running_daemon "$case_tmp/candidate" || fail "标准 daemon 输出的同源候选必须通过"
  resolve_derper_module_version() { printf 'v1.104.2\n'; }
  if candidate_matches_running_daemon "$case_tmp/candidate" >/dev/null 2>&1; then
    fail "不同来源候选必须被拒绝"
  fi
  tailscaled() { printf '1.104.1\n  other commit: abcdef0123456789abcdef0123456789abcdef01\n'; }
  if tailscaled_daemon_revision; then fail "不能把 other commit 冒充 tailscale commit"; fi
  tailscaled() { printf '1.104.1\n  tailscale commit: malformed\n'; }
  if tailscaled_daemon_revision; then fail "畸形 commit 必须拒绝"; fi
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

if [[ "$#" -gt 0 ]]; then
  selected=("$@")
else
  selected=(test_bug055_standard_daemon_identity test_bug059_upgrade_migration_keeps_snapshot test_bug059_migration_failure_preserves_outer_marker test_bug059_standalone_migration_waits_for_service_commit test_bug060_rollback_uses_saved_user test_bug053_purge_all_removes_stable_copy test_bug053_cleanup_failure_is_not_success test_bug053_empty_directory_failure_is_not_success)
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
