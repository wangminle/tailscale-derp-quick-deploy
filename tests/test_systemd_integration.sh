#!/usr/bin/env bash
# GB：只在一次性 Ubuntu VM（systemd 为 PID 1）里做故障注入。
# 开发机、部署机和普通 CI 没有这个标记时必须失败退出，不能把跳过写成通过。
set -euo pipefail
if [[ "${DERPER_INTEGRATION_VM:-}" != "1" || ! -d /run/systemd/system ]]; then
  echo "not verified - phase B VM fault injection requires DERPER_INTEGRATION_VM=1 on a disposable Ubuntu VM whose PID 1 is systemd" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/deploy_derper_ip_selfsigned.sh"
fail() { echo "not ok - $*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
DERPER_TEST_MODE=1
# shellcheck disable=SC1090
source "$SCRIPT"
DEPLOY_STATE_DIR="$tmp/deploy-state"
BIN_PATH="$tmp/bin/derper"
SERVICE_PATH="$tmp/derper.service"
INSTALL_DIR="$tmp/install"
VERIFY_CLIENTS_MODE=off
mkdir -p "$(dirname "$BIN_PATH")" "$INSTALL_DIR"
printf '#!/bin/sh\necho old\n' >"$BIN_PATH"
chmod 755 "$BIN_PATH"
printf 'old-unit\n' >"$SERVICE_PATH"
candidate="$tmp/candidate"
printf '#!/bin/sh\nexit 42\n' >"$candidate"
chmod 755 "$candidate"
if publish_derper_candidate "$candidate" >/dev/null 2>&1; then
  fail "bad candidate must not publish"
fi
[[ "$(sed -n '2p' "$BIN_PATH")" == "echo old" ]] || fail "live binary changed"
printf 'phase=switch\nrecovery=%s/recovery\n$(touch %s/pwn)\n' "$DEPLOY_STATE_DIR" "$tmp" >"$DEPLOY_STATE_DIR/incomplete" 2>/dev/null || mkdir -p "$DEPLOY_STATE_DIR"
printf 'phase=switch\nrecovery=%s/recovery\n$(touch %s/pwn)\n' "$DEPLOY_STATE_DIR" "$tmp" >"$DEPLOY_STATE_DIR/incomplete"
if ordinary_change_allowed >/dev/null 2>&1; then
  fail "incomplete marker must block overwrite"
fi
[[ ! -e "$tmp/pwn" ]] || fail "marker was executed"

printf '#!/bin/sh\necho -a\n' >"$candidate"
chmod 755 "$candidate"
(
  cp() { return 1; }
  if publish_derper_candidate "$candidate" >/dev/null 2>&1; then
    exit 1
  fi
)
[[ "$(sed -n '2p' "$BIN_PATH")" == "echo old" ]] || fail "disk write failure changed the live binary"

mkdir -p "$DEPLOY_STATE_DIR/recovery"
printf '#!/bin/sh\necho old\n' >"$DEPLOY_STATE_DIR/recovery/binary"
chmod 755 "$DEPLOY_STATE_DIR/recovery/binary"
sum=$(sha256_hex <"$DEPLOY_STATE_DIR/recovery/binary")
printf 'binary_sha256=%s\nrun_intent=active\n' "$sum" >"$DEPLOY_STATE_DIR/recovery/manifest"
printf 'phase=switch\nrecovery=%s/recovery\n' "$DEPLOY_STATE_DIR" >"$DEPLOY_STATE_DIR/incomplete"
systemctl() { return 0; }
verify_restored_service() { return 1; }
if rollback_deploy_change >/dev/null 2>&1; then
  fail "reverify failure must be non-zero"
fi
[[ -f "$DEPLOY_STATE_DIR/recovery/binary" ]] || fail "reverify failure removed the only backup"
echo "ok - vm fault injection kept the live binary, blocked the incomplete marker, and kept the backup"
