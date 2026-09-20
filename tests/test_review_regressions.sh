#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/deploy_derper_ip_selfsigned.sh"
fail() { echo "not ok - $*" >&2; exit 1; }

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
for test_name in test_legacy_symlink_migration test_cleanup_restarts_previously_running_service test_new_root_default test_real_certificate_write_failure test_interrupted_rollback test_rotation_decline_preserves_certificate test_module_query_preserves_network_settings test_explicit_user test_existing_user test_commit_versions test_certificate_resume test_rotation_requires_ack test_certificate_rollback test_recover_restart_failure_is_warning; do
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
