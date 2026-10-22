#!/usr/bin/env bash
# S2 证据：真实 flock 双进程，以及非 root 服务用户不能改名或重建 certs。
# 需要 root、flock 和 useradd。开发机不是该环境时退出 2，不能当成通过。
set -euo pipefail
if [[ "$(id -u)" -ne 0 ]] || ! command -v flock >/dev/null 2>&1 || ! command -v gcc >/dev/null 2>&1; then
  echo "not verified - S2 evidence requires root, flock and gcc" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/deploy_derper_ip_selfsigned.sh"
fail() { echo "not ok - $*" >&2; exit 1; }

tmp=$(mktemp -d)
chmod 755 "$tmp"
trap 'rm -rf "$tmp"' EXIT
DERPER_TEST_MODE=1
# shellcheck disable=SC1090
source "$SCRIPT"
DEPLOY_STATE_DIR="$tmp/deploy-state"
acquire_deploy_lock || fail "root 进程必须取得 flock"
result=$(DEPLOY_STATE_DIR="$DEPLOY_STATE_DIR" bash -c '
  DERPER_TEST_MODE=1
  source "$1"
  DEPLOY_STATE_DIR="$2"
  if acquire_deploy_lock; then echo took; else echo blocked; fi
' _ "$SCRIPT" "$DEPLOY_STATE_DIR")
[[ "$result" == "blocked" ]] || fail "第二个进程不得取得同一把变更锁：${result}"
echo "ok - second process blocked by real flock"

if ! id derper-s2 >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin derper-s2
fi
INSTALL_DIR="$tmp/install"
NODE_STATE_DIR="$tmp/node-state"
RUN_USER=derper-s2
SERVICE_PATH="$tmp/missing.service"
mkdir -p "$INSTALL_DIR/certs"
printf 'cert-bytes\n' >"$INSTALL_DIR/certs/node.crt"
printf 'node-identity\n' >"$INSTALL_DIR/derper.json"
before=$(sha256sum "$INSTALL_DIR/certs/node.crt" | awk '{print $1}')
layout_install_tree >/dev/null
after=$(sha256sum "$INSTALL_DIR/certs/node.crt" | awk '{print $1}')
[[ "$before" == "$after" ]] || fail "布局改变了证书指纹"
state=$(derper_node_state_dir)
[[ "$(cat "$state/derper.json")" == "node-identity" ]] || fail "布局改变了节点身份"
if runuser -u derper-s2 -- mv "$INSTALL_DIR/certs" "$INSTALL_DIR/certs-renamed" >/dev/null 2>&1; then
  fail "服务用户 rename 了 certs"
fi
if runuser -u derper-s2 -- mkdir "$INSTALL_DIR/certs-rebuilt" >/dev/null 2>&1; then
  fail "服务用户重建了 certs 目录"
fi
[[ -d "$INSTALL_DIR/certs" && ! -e "$INSTALL_DIR/certs-renamed" ]] || fail "certs 目录必须留在原处"
runuser -u derper-s2 -- touch "$state/probe" || fail "服务用户必须能写自己的状态目录"
echo "ok - service user cannot rename or recreate certs and can write state"

# BUG-060：真实双用户，验证回退后旧服务能遍历状态目录并读取身份/私钥。
if ! id derper-s2-next >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin derper-s2-next
fi
DEPLOY_STATE_DIR="$tmp/rollback-deploy"
BIN_PATH="$tmp/bin/derper"
SERVICE_PATH="$tmp/derper.service"
INSTALL_DIR="$tmp/rollback-install"
NODE_STATE_DIR="$tmp/rollback-state"
IP_ADDR=203.0.113.10
RUN_USER=derper-s2
mkdir -p "$(dirname "$BIN_PATH")" "$INSTALL_DIR/certs" "$NODE_STATE_DIR"
printf '#!/bin/sh\necho -a\n' >"$BIN_PATH"
chmod 755 "$BIN_PATH"
printf '[Service]\nUser=derper-s2\nExecStart=%s -hostname %s -c %s/derper.json\n' "$BIN_PATH" "$IP_ADDR" "$NODE_STATE_DIR" >"$SERVICE_PATH"
printf 'old-node-identity\n' >"$NODE_STATE_DIR/derper.json"
printf 'private-key-bytes\n' >"$INSTALL_DIR/certs/$IP_ADDR.key"
printf 'certificate-bytes\n' >"$INSTALL_DIR/certs/$IP_ADDR.crt"
chown -R derper-s2:derper-s2 "$NODE_STATE_DIR"
chmod 700 "$NODE_STATE_DIR"
chmod 600 "$NODE_STATE_DIR/derper.json"
harden_cert_dir
runtime=active
systemctl() {
  case "$1" in
    is-active) [[ "$runtime" == active ]] ;;
    stop) runtime=inactive ;;
    start) runtime=active ;;
    *) return 0 ;;
  esac
}
verify_restored_service() {
  [[ "$runtime" == active ]] || return 1
  runuser -u derper-s2 -- test -r "$NODE_STATE_DIR/derper.json" || return 1
  runuser -u derper-s2 -- test -r "$INSTALL_DIR/certs/$IP_ADDR.key"
}
capture_and_promote_recovery || fail "必须备份旧用户的恢复集"
write_incomplete_marker switch
RUN_USER=derper-s2-next
sed -i 's/User=derper-s2$/User=derper-s2-next/' "$SERVICE_PATH"
chown -R derper-s2-next:derper-s2-next "$NODE_STATE_DIR"
harden_cert_dir
rollback_deploy_change || fail "必须按旧用户完成回退"
[[ "$(stat -c %U "$NODE_STATE_DIR")" == derper-s2 ]] || fail "状态目录必须归旧用户"
[[ "$(cat "$NODE_STATE_DIR/derper.json")" == old-node-identity ]] || fail "节点身份必须保持原字节"
[[ "$RUN_USER" == derper-s2-next ]] || fail "回退不能污染调用方的目标身份"
[[ ! -e "$DEPLOY_STATE_DIR/incomplete" ]] || fail "复验通过后应清除标记"
echo "ok - rollback restores old service user access to node state and private key"

# BUG-080：真实低权限进程不能被 root 当成 daemon 执行（包括 MainPID 与 pgrep 分支）。
(
  attacker_pid="" launcher_pid=""
  trap 'if [[ -n "$attacker_pid" ]]; then kill "$attacker_pid" 2>/dev/null || true; fi; if [[ -n "$launcher_pid" ]]; then wait "$launcher_pid" 2>/dev/null || true; fi' EXIT
  mkdir -p "$tmp/process-public" "$tmp/process-protected"
  chown derper-s2:derper-s2 "$tmp/process-public"
  chmod 700 "$tmp/process-protected"
  export BUG080_TARGET="$tmp/process-protected/proof" BUG080_PIDFILE="$tmp/process-public/pid"
  printf 'ORIGINAL\n' >"$BUG080_TARGET"
  chmod 600 "$BUG080_TARGET"
  cat >"$tmp/process.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc,char **argv) {
  if(argc>1 && !strcmp(argv[1],"--version")) {
    FILE *f=fopen(getenv("BUG080_TARGET"),"w");
    if(f) { fprintf(f,"executed_euid=%ld\n",(long)geteuid()); fclose(f); }
    puts("tailscale commit: aaaaaaaaaaaa"); return 0;
  }
  FILE *f=fopen(getenv("BUG080_PIDFILE"),"w");
  if(!f) return 1;
  fprintf(f,"%ld\n",(long)getpid()); fclose(f);
  for(;;) pause();
}
C
  gcc "$tmp/process.c" -o "$tmp/process-public/tailscaled" || fail "编译低权限进程失败"
  chown derper-s2:derper-s2 "$tmp/process-public/tailscaled"
  runuser -u derper-s2 -- "$tmp/process-public/tailscaled" >/dev/null 2>&1 & launcher_pid=$!
  for _ in {1..40}; do [[ ! -s "$BUG080_PIDFILE" ]] || break; sleep 0.05; done
  attacker_pid=$(cat "$BUG080_PIDFILE")
  # 只选择本测试进程，避免干扰主机上其他进程。
  systemctl() { [[ "$1" != show ]] || printf '%s\n' "$attacker_pid"; }
  pgrep() { printf '%s\n' "$attacker_pid"; }
  if tailscaled_daemon_revision >/dev/null 2>&1; then fail "root不得执行低权限MainPID程序"; fi
  systemctl() { return 1; }
  if tailscaled_daemon_revision >/dev/null 2>&1; then fail "root不得执行低权限唯一同名进程"; fi
  # 即使进程定位被替换，执行前仍应校验已固定的 inode。
  tailscaled_running_exe() { printf '/proc/%s/exe\n' "$attacker_pid"; }
  if tailscaled_daemon_revision >/dev/null 2>&1; then fail "root不得执行低权限用户所有的inode"; fi
  [[ "$(cat "$BUG080_TARGET")" == ORIGINAL ]] || fail "低权限程序不应以root身份执行"
  echo "ok - root refuses untrusted process credentials and executable inode"
)
