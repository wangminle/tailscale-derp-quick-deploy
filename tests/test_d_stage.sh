#!/usr/bin/env bash
# D 阶段契约与行为回归：prepare/apply/cancel、策略 API 替身、
# 自动/人工/未知三态、同机维护任务与云端协调失败边界。
# 合成策略与 HTTP 替身只证明本地编排；真实隔离 Tailnet 另记。
# 需 openssl；HuJSON 补丁需 python3。可传测试函数名单独运行。
# 退出码 0=全部通过，1=有失败。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/deploy_derper_ip_selfsigned.sh"
fail() { echo "not ok - $*" >&2; exit 1; }

make_cert_pair() {
  local dest="$1" ip="${2:-203.0.113.10}" days="${3:-365}"
  mkdir -p "$(dirname "$dest.crt")"
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
    -keyout "$dest.key" -out "$dest.crt" -days "$days" \
    -subj "/CN=${ip}" -addext "subjectAltName = IP:${ip}" >/dev/null 2>&1
}

# 生成真正已过期的同 IP 证书（openssl ca 指定过去的有效期），不依赖系统时间伪造。
make_expired_cert_pair() {
  local dest="$1" ip="${2:-203.0.113.10}" start="${3:-20200101000000Z}" end="${4:-20200102000000Z}" work
  work=$(mktemp -d)
  : >"$work/index.txt"
  printf '01\n' >"$work/serial"
  cat >"$work/ca.cnf" <<CNF
[ ca ]
default_ca = CA_default
[ CA_default ]
database = $work/index.txt
new_certs_dir = $work
serial = $work/serial
default_md = sha256
policy = pol
unique_subject = no
x509_extensions = ext
[ pol ]
commonName = supplied
[ ext ]
subjectAltName = IP:${ip}
[ req ]
distinguished_name = dn
prompt = no
[ dn ]
CN = ${ip}
CNF
  openssl req -new -newkey rsa:2048 -nodes -keyout "$dest.key" -out "$work/c.csr" -config "$work/ca.cnf" >/dev/null 2>&1 &&
    openssl ca -batch -config "$work/ca.cnf" -selfsign -keyfile "$dest.key" -in "$work/c.csr" -out "$dest.crt" \
      -startdate "$start" -enddate "$end" -notext >/dev/null 2>&1 || { rm -rf "$work"; return 1; }
  rm -rf "$work"
}

cert_fp() {
  openssl x509 -in "$1" -outform DER 2>/dev/null | sha256_hex
}

setup_rotation_env() {
  INSTALL_DIR="$tmp/install"
  NODE_STATE_DIR="$tmp/state"
  DEPLOY_STATE_DIR="$tmp/deploy-state"
  SERVICE_PATH="$tmp/derper.service"
  IP_ADDR=203.0.113.10
  REGION_ID=900
  REGION_CODE=my-derp
  REGION_NAME="My IP DERP"
  DERP_PORT=30399
  STUN_PORT=3478
  CERT_DAYS=365
  TS_TAILNET=example.com
  RUN_USER=derper
  mkdir -p "$INSTALL_DIR/certs" "$NODE_STATE_DIR" "$DEPLOY_STATE_DIR"
  make_cert_pair "$INSTALL_DIR/certs/$IP_ADDR" "$IP_ADDR" 365
  ln -sfn "$IP_ADDR.crt" "$INSTALL_DIR/certs/fullchain.pem"
  ln -sfn "$IP_ADDR.key" "$INSTALL_DIR/certs/privkey.pem"
  printf 'old-unit\n' >"$SERVICE_PATH"
  flock() { return 0; }
  systemctl() { return 1; }
  chown() { return 0; }
  harden_cert_dir() { return 0; }
  generate_derper_config() { return 0; }
  verify_restored_service() { return 0; }
}

test_prepare_does_not_switch_live_cert() {
  setup_rotation_env
  local before after
  before=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  prepare_cert_rotation >/dev/null || fail 'prepare 应成功'
  after=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  [[ "$before" == "$after" ]] || fail 'prepare 不得替换正在使用的证书'
  [[ -f "$(cert_rotation_candidate_cert)" && ! -L "$(cert_rotation_candidate_cert)" ]] || fail '必须留下候选证书'
  local rec new_fp
  rec=$(cert_rotation_record_path)
  [[ -f "$rec" && ! -L "$rec" ]] || fail '必须写下候选记录'
  new_fp=$(cert_fp "$(cert_rotation_candidate_cert)")
  [[ "$new_fp" != "$before" ]] || fail '候选必须是新指纹'
  [[ "$(read_rotation_kv old_sha256)" == "$before" ]] || fail '记录应保存旧指纹'
  [[ "$(read_rotation_kv new_sha256)" == "$new_fp" ]] || fail '记录应保存新指纹'
  [[ "$(read_rotation_kv phase)" == prepared ]] || fail '阶段应为 prepared'
  [[ -f "$(cert_rotation_snippet_path)" ]] || fail '应生成本节点 derpMap 片段'
  grep -q "sha256-raw:${new_fp}" "$(cert_rotation_snippet_path)" || fail '片段必须使用候选指纹'
}

test_yes_does_not_apply_or_resign() {
  setup_rotation_env
  NON_INTERACTIVE=1
  local before
  before=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  parse_args prepare --ip "$IP_ADDR" --yes --allow-non-global-ip
  [[ "$CERT_PREPARE" == 1 ]] || fail 'prepare 子命令未识别'
  prepare_cert_rotation >/dev/null || fail 'prepare 在 --yes 下仍应只准备'
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$before" ]] || fail '--yes 不得重签正式证书'
  if apply_cert_rotation >/dev/null 2>&1; then fail '--yes 不能代替 --accept-cert-rotation'; fi
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$before" ]] || fail '未确认 apply 不得切换'
}

test_cancel_discards_candidate_keeps_live() {
  setup_rotation_env
  local before
  before=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  prepare_cert_rotation >/dev/null || fail 'prepare 应成功'
  cancel_cert_rotation >/dev/null || fail 'cancel 应成功'
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$before" ]] || fail 'cancel 不得改正式证书'
  [[ ! -e "$(cert_rotation_candidate_cert)" ]] || fail 'cancel 应删除候选'
  [[ ! -e "$(cert_rotation_record_path)" ]] || fail 'cancel 应删除记录'
}

test_apply_switches_after_accept_and_keeps_old_recoverable() {
  setup_rotation_env
  ACCEPT_CERT_ROTATION=1
  local old new
  old=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  prepare_cert_rotation >/dev/null || fail 'prepare 应成功'
  new=$(cert_fp "$(cert_rotation_candidate_cert)")
  apply_cert_rotation >/dev/null || fail '已确认的 apply 应成功'
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$new" ]] || fail 'apply 应装上候选'
  [[ "$(read_rotation_kv phase)" == applied ]] || fail '阶段应为 applied'
  [[ ! -e "${SERVICE_PATH}.certs-rollback" ]] || fail '成功切换后不得留下未完成事务'
  [[ -d "${SERVICE_PATH}.certs-archive" ]] || fail '旧证书应归档，供显式恢复'
}

test_prepare_conflicts_with_deploy() {
  parse_args prepare --force
  if validate_arg_combos >/dev/null 2>&1; then fail 'prepare 与 --force 必须互斥'; fi
  CERT_PREPARE=0 FORCE=0
  parse_args apply --uninstall
  if validate_arg_combos >/dev/null 2>&1; then fail 'apply 与 uninstall 必须互斥'; fi
}

test_hujson_patch_preserves_comments_and_other_nodes() {
  command -v python3 >/dev/null 2>&1 || { echo "skip - 无 python3，HuJSON 补丁未测"; return 0; }
  local src out
  src="$tmp/acl.hujson"
  cat >"$src" <<'EOF'
{
  // keep this comment
  "grants": [{"src": ["autogroup:member"], "dst": ["*"]}],
  "derpMap": {
    "OmitDefaultRegions": false,
    "Regions": {
      "900": {
        "RegionID": 900,
        "RegionCode": "my-derp",
        "Nodes": [
          {
            "Name": "900a",
            "RegionID": 900,
            "HostName": "203.0.113.10",
            "CertName": "sha256-raw:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "unknownField": true,
          },
        ],
      },
      "901": {
        "RegionID": 901,
        "Nodes": [{ "HostName": "198.51.100.9", "CertName": "sha256-raw:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }],
      },
    },
  },
}
EOF
  out=$(hujson_patch_certname "$(cat "$src")" "203.0.113.10" 900 \
    "sha256-raw:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" \
    "sha256-raw:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") || fail '合法补丁应成功'
  printf '%s' "$out" | grep -q 'keep this comment' || fail '必须保留注释'
  printf '%s' "$out" | grep -q 'unknownField' || fail '必须保留未知字段'
  printf '%s' "$out" | grep -q 'autogroup:member' || fail '必须保留 grants'
  printf '%s' "$out" | grep -q '198.51.100.9' || fail '不得改其他节点'
  printf '%s' "$out" | grep -q 'sha256-raw:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' || fail '本节点 CertName 应更新'
  if hujson_patch_certname "$(cat "$src")" "203.0.113.10" 900 \
    "sha256-raw:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" \
    "sha256-raw:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" >/dev/null 2>&1; then
    fail '旧指纹冲突必须拒绝'
  fi
}

test_hujson_first_register_appends_without_overwrite() {
  command -v python3 >/dev/null 2>&1 || { echo "skip - 无 python3，首次登记未测"; return 0; }
  local src out
  src="$tmp/acl.hujson"
  cat >"$src" <<'EOF'
{ "derpMap": { "Regions": { "1": { "RegionID": 1, "Nodes": [{ "HostName": "127.3.3.40", "CertName": "sha256-raw:official" }] } } } }
EOF
  out=$(hujson_patch_certname "$(cat "$src")" "203.0.113.10" 900 "sha256-raw:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" "") || fail '首次追加应成功'
  printf '%s' "$out" | grep -q '127.3.3.40' || fail '不得覆盖官方节点'
  printf '%s' "$out" | grep -q '203.0.113.10' || fail '应追加本节点'
  if hujson_patch_certname "$(cat "$src")" "127.3.3.40" 1 "sha256-raw:new" "" >/dev/null 2>&1; then
    fail '目标已存在且未给旧指纹时不得覆盖'
  fi
}

test_policy_read_does_not_imply_write() {
  POLICY_CREDENTIAL_FILE="$tmp/creds.env"
  printf 'TS_TAILNET=example.com\nTS_API_CLIENT_ID=id\nTS_API_CLIENT_SECRET=sec\nPOLICY_SOURCE=api\n' >"$POLICY_CREDENTIAL_FILE"
  policy_http_request() {
    case "$1 $2" in
      "POST /api/v2/oauth/token") printf 'access_token=tok\nscope=policy_file:read\n' ;;
      "GET /api/v2/tailnet/example.com/acl") printf 'etag: "abc"\n\n{}\n' ;;
      *) return 1 ;;
    esac
  }
  load_policy_credentials || fail '凭据应可读'
  [[ "$(policy_auth_state)" == read_only ]] || fail "GET/只读 scope 不得报可写：$(policy_auth_state)"
  printf 'POLICY_SOURCE=gitops\nTS_TAILNET=example.com\n' >"$POLICY_CREDENTIAL_FILE"
  load_policy_credentials || fail 'gitops 凭据文件应可读'
  [[ "$(policy_auth_state)" == gitops ]] || fail 'GitOps 不得走 API 双写'
}

test_policy_timeout_reads_back_before_rollback() {
  setup_rotation_env
  ACCEPT_CERT_ROTATION=1
  ENABLE_AUTO_MAINTAIN=1
  POLICY_CREDENTIAL_FILE="$tmp/creds.env"
  printf 'TS_TAILNET=example.com\nTS_API_CLIENT_ID=id\nTS_API_CLIENT_SECRET=sec\nPOLICY_SOURCE=api\n' >"$POLICY_CREDENTIAL_FILE"
  local old new posted=0
  printf '0\n' >"$tmp/got"
  old=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  prepare_cert_rotation >/dev/null
  new=$(read_rotation_kv new_sha256)
  policy_auth_state() { printf 'write_ready\n'; }
  policy_http_request() {
    case "$1 $2" in
      "GET /api/v2/tailnet/example.com/acl")
        local n
        n=$(cat "$tmp/got")
        n=$((n+1))
        printf '%s\n' "$n" >"$tmp/got"
        if [[ "$n" -eq 1 ]]; then
          printf 'etag: "v1"\n\n{"derpMap":{"Regions":{"900":{"RegionID":900,"Nodes":[{"HostName":"203.0.113.10","CertName":"sha256-raw:%s"}]}}}}\n' "$old"
        else
          printf 'etag: "v2"\n\n{"derpMap":{"Regions":{"900":{"RegionID":900,"Nodes":[{"HostName":"203.0.113.10","CertName":"sha256-raw:%s"}]}}}}\n' "$new"
        fi
        ;;
      "POST /api/v2/tailnet/example.com/acl/validate") printf 'ok\n' ;;
      "POST /api/v2/tailnet/example.com/acl")
        posted=1
        return 28
        ;;
      *) return 1 ;;
    esac
  }
  apply_cert_rotation >/dev/null || fail 'POST 超时但读回已是新指纹时应继续本地切换'
  [[ "$posted" == 1 || "$(cat "$tmp/got")" -ge 1 ]] || fail '应尝试提交'
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$new" ]] || fail '读回确认写入后应切换本地'
}

test_foreign_cloud_change_stops_auto_rollback() {
  setup_rotation_env
  ACCEPT_CERT_ROTATION=1
  ENABLE_AUTO_MAINTAIN=1
  POLICY_CREDENTIAL_FILE="$tmp/creds.env"
  printf 'TS_TAILNET=example.com\nTS_API_CLIENT_ID=id\nTS_API_CLIENT_SECRET=sec\nPOLICY_SOURCE=api\n' >"$POLICY_CREDENTIAL_FILE"
  local old new posted=0
  printf '0\n' >"$tmp/posted"
  old=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  prepare_cert_rotation >/dev/null
  new=$(read_rotation_kv new_sha256)
  policy_auth_state() { printf 'write_ready\n'; }
  policy_http_request() {
    case "$1 $2" in
      "GET /api/v2/tailnet/example.com/acl")
        printf 'HTTP/2 200\r\nETag: "version-17"\r\n\r\n{"derpMap":{"Regions":{"900":{"RegionID":900,"Nodes":[{"HostName":"203.0.113.10","CertName":"sha256-raw:%s"}]}}}}\n' "$old"
        ;;
      "POST /api/v2/tailnet/example.com/acl/validate")
        printf 'HTTP/2 200\r\n\r\n\n'
        ;;
      "POST /api/v2/tailnet/example.com/acl")
        printf '1\n' >"$tmp/posted"
        printf '%s\n' "${POLICY_IF_MATCH-}" >"$tmp/if-match"
        printf 'HTTP/2 412\r\nContent-Type: application/json\r\n\r\n{"message":"precondition failed"}\n'
        ;;
      *) return 1 ;;
    esac
  }
  local rc=0
  apply_cert_rotation >/dev/null 2>"$tmp/apply.err" || rc=$?
  posted=$(cat "$tmp/posted")
  [[ "$posted" == 1 ]] || fail '云端旧指纹匹配时必须真正 POST'
  [[ "$(cat "$tmp/if-match")" == '"version-17"' || "$(cat "$tmp/if-match")" == 'version-17' ]] || fail "POST 必须带上 GET 的 ETag，实际：$(cat "$tmp/if-match" 2>/dev/null || true)"
  [[ "$rc" -ne 0 ]] || fail 'HTTP 412 必须失败'
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$old" ]] || fail 'ETag 冲突时不得切换本地证书'
  grep -E -q '待协调|ETag' "$tmp/apply.err" || fail '应提示 ETag 冲突待协调'
  [[ "$(read_rotation_kv phase)" != applied ]] || fail '冲突后不得记为 applied'
  : "$new"
}

test_auto_manual_unknown_feedback() {
  setup_rotation_env
  POLICY_CREDENTIAL_FILE="$tmp/missing.env"
  local mode
  mode=$(evaluate_auto_maintain_readiness)
  [[ "$mode" == manual ]] || fail "无凭据应为人工：$mode"
  print_auto_maintain_feedback "$mode" >"$tmp/fb.txt"
  grep -q '未配置云端自动维护授权' "$tmp/fb.txt" || fail '人工说明缺失'
  grep -q '服务器已部署' "$tmp/fb.txt" || fail '安装与维护应分开报告'
  printf 'TS_TAILNET=example.com\nTS_API_CLIENT_ID=id\nTS_API_CLIENT_SECRET=sec\nPOLICY_SOURCE=api\n' >"$tmp/creds.env"
  POLICY_CREDENTIAL_FILE="$tmp/creds.env"
  policy_auth_state() { printf 'unknown\n'; }
  mode=$(evaluate_auto_maintain_readiness)
  [[ "$mode" == unknown ]] || fail "授权未知应保持未知：$mode"
  print_auto_maintain_feedback unknown >"$tmp/fb2.txt"
  grep -q '不能承诺自动更新' "$tmp/fb2.txt" || fail '未知说明缺失'
  grep -q '权限不足' "$tmp/fb2.txt" && fail '未知不得冒充权限不足'
  policy_auth_state() { printf 'write_ready\n'; }
  command -v systemctl >/dev/null 2>&1 || true
  SYSTEMD_UNIT_DIR="$tmp/systemd"
  mkdir -p "$SYSTEMD_UNIT_DIR"
  ENABLE_AUTO_MAINTAIN=1
  mode=$(evaluate_auto_maintain_readiness)
  [[ "$mode" == ready ]] || fail "写授权且显式启用应为就绪：$mode"
}

test_maintain_does_not_replace_when_not_due_or_unready() {
  setup_rotation_env
  ENABLE_AUTO_MAINTAIN=1
  POLICY_CREDENTIAL_FILE="$tmp/creds.env"
  printf 'TS_TAILNET=example.com\nTS_API_CLIENT_ID=id\nTS_API_CLIENT_SECRET=sec\nPOLICY_SOURCE=api\n' >"$POLICY_CREDENTIAL_FILE"
  policy_auth_state() { printf 'write_ready\n'; }
  local before
  before=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  CERT_LEAD_DAYS=30
  run_cert_maintain >/dev/null || fail '未到期的维护应成功且无切换'
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$before" ]] || fail '未到期不得换证'
  policy_auth_state() { printf 'none\n'; }
  if run_cert_maintain >/dev/null 2>&1; then :; else
    :
  fi
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$before" ]] || fail '缺条件不得先换旧证书'
  [[ "$(read_maintenance_kv result)" != success_replaced ]] || fail '缺条件不得报换证成功'
}

test_maintain_reuses_same_candidate() {
  setup_rotation_env
  ACCEPT_CERT_ROTATION=1
  ENABLE_AUTO_MAINTAIN=1
  make_cert_pair "$INSTALL_DIR/certs/$IP_ADDR" "$IP_ADDR" 1
  CERT_LEAD_DAYS=30
  POLICY_CREDENTIAL_FILE="$tmp/creds.env"
  printf 'TS_TAILNET=example.com\nTS_API_CLIENT_ID=id\nTS_API_CLIENT_SECRET=sec\nPOLICY_SOURCE=api\n' >"$POLICY_CREDENTIAL_FILE"
  policy_auth_state() { printf 'write_ready\n'; }
  policy_http_request() { echo 'down' >&2; return 1; }
  run_cert_maintain >/dev/null 2>&1 || true
  [[ -f "$(cert_rotation_candidate_cert)" ]] || fail '到期维护失败后必须留下候选'
  local first
  first=$(cert_fp "$(cert_rotation_candidate_cert)")
  run_cert_maintain >/dev/null 2>&1 || true
  [[ "$(cert_fp "$(cert_rotation_candidate_cert)")" == "$first" ]] || fail '失败重试必须复用同一轮候选'
}

test_maintain_unit_is_independent() {
  SYSTEMD_UNIT_DIR="$tmp/systemd"
  mkdir -p "$SYSTEMD_UNIT_DIR"
  DEPLOY_STATE_DIR="$tmp/deploy-state"
  CONFIG_FILE="$tmp/deploy.conf"
  printf 'CONFIG_VERSION=1\nIP_ADDR=203.0.113.10\n' >"$CONFIG_FILE"
  flock() { return 0; }
  install_cert_maintain_units >/dev/null || fail '应写出独立维护 unit'
  [[ -f "$SYSTEMD_UNIT_DIR/derper-cert-maintain.service" ]] || fail '缺少 maintain service'
  [[ -f "$SYSTEMD_UNIT_DIR/derper-cert-maintain.timer" ]] || fail '缺少 maintain timer'
  grep -q 'derper-healthcheck' "$SYSTEMD_UNIT_DIR/derper-cert-maintain.service" && fail '维护任务不得复用健康检查 unit'
  grep -q ' maintain' "$SYSTEMD_UNIT_DIR/derper-cert-maintain.service" || fail 'ExecStart 应调用 maintain'
  grep -vq 'TS_API_CLIENT_SECRET' "$SYSTEMD_UNIT_DIR/derper-cert-maintain.service" || fail 'unit 不得写入 secret'
}

test_enable_persists_ready_for_timer() {
  setup_rotation_env
  SYSTEMD_UNIT_DIR="$tmp/systemd"
  mkdir -p "$SYSTEMD_UNIT_DIR"
  ENABLE_AUTO_MAINTAIN=1
  POLICY_CREDENTIAL_FILE="$tmp/creds.env"
  printf 'TS_TAILNET=example.com\nTS_API_CLIENT_ID=id\nTS_API_CLIENT_SECRET=sec\nPOLICY_SOURCE=api\n' >"$POLICY_CREDENTIAL_FILE"
  policy_auth_state() { printf 'write_ready\n'; }
  stub_timer_systemctl
  apply_auto_maintain_policy >/dev/null || fail '启用自动维护应成功'
  [[ "$(read_maintenance_kv mode)" == ready ]] || fail '启用后必须把 mode=ready 写入持久状态'
  [[ -f "$SYSTEMD_UNIT_DIR/derper-cert-maintain.timer" ]] || fail '启用后应安装维护 timer'
  ENABLE_AUTO_MAINTAIN=0
  [[ "$(evaluate_auto_maintain_readiness)" == ready ]] || fail 'timer 再次执行时仍应视为已登记自动维护'
}

test_disable_persists_manual_and_removes_units() {
  setup_rotation_env
  SYSTEMD_UNIT_DIR="$tmp/systemd"
  mkdir -p "$SYSTEMD_UNIT_DIR"
  ENABLE_AUTO_MAINTAIN=1
  POLICY_CREDENTIAL_FILE="$tmp/creds.env"
  printf 'TS_TAILNET=example.com\nTS_API_CLIENT_ID=id\nTS_API_CLIENT_SECRET=sec\nPOLICY_SOURCE=api\n' >"$POLICY_CREDENTIAL_FILE"
  policy_auth_state() { printf 'write_ready\n'; }
  stub_timer_systemctl
  apply_auto_maintain_policy >/dev/null || fail '启用应成功'
  ENABLE_AUTO_MAINTAIN=0
  DISABLE_AUTO_MAINTAIN=1
  apply_auto_maintain_policy >/dev/null || fail '停用应成功'
  [[ "$(read_maintenance_kv mode)" == manual ]] || fail '停用后必须把 mode=manual 写入持久状态'
  [[ ! -e "$SYSTEMD_UNIT_DIR/derper-cert-maintain.service" ]] || fail '停用应删除 maintain service'
  [[ ! -e "$SYSTEMD_UNIT_DIR/derper-cert-maintain.timer" ]] || fail '停用应删除 maintain timer'
  DISABLE_AUTO_MAINTAIN=0
  [[ "$(evaluate_auto_maintain_readiness)" != ready ]] || fail '撤掉登记后 timer 不得继续自动换证'
}

test_revoked_credentials_keep_old_cert() {
  setup_rotation_env
  ENABLE_AUTO_MAINTAIN=1
  make_cert_pair "$INSTALL_DIR/certs/$IP_ADDR" "$IP_ADDR" 1
  CERT_LEAD_DAYS=30
  POLICY_CREDENTIAL_FILE="$tmp/creds.env"
  printf 'TS_TAILNET=example.com\nTS_API_CLIENT_ID=id\nTS_API_CLIENT_SECRET=sec\nPOLICY_SOURCE=api\n' >"$POLICY_CREDENTIAL_FILE"
  local before
  before=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  policy_auth_state() { printf 'none\n'; }
  run_cert_maintain >/dev/null 2>&1 || true
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$before" ]] || fail '凭据撤销后不得换证'
  [[ "$(read_maintenance_kv needs_manual)" == 1 ]] || fail '撤销后应标记需人工'
}

stub_timer_systemctl() {
  systemctl() {
    printf '%s\n' "$*" >>"$tmp/systemctl.log"
    case "$1" in
      # 有状态替身：enable 后维护 unit 才处于启用/运行，disable 后恢复；卸载核验依赖该状态。
      enable) [[ "$*" == *derper-cert-maintain* ]] && : >"$tmp/maintain-enabled"; return 0 ;;
      disable) [[ "$*" == *derper-cert-maintain* ]] && rm -f "$tmp/maintain-enabled"; return 0 ;;
      is-enabled|is-active)
        if [[ "$*" == *derper-cert-maintain* ]]; then [[ -e "$tmp/maintain-enabled" ]]; return; fi
        return 0 ;;
      *) return 0 ;;
    esac
  }
}

test_applied_cert_is_not_rolled_back_by_next_command() {
  setup_rotation_env
  ACCEPT_CERT_ROTATION=1
  local old new
  old=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  prepare_cert_rotation >/dev/null || fail 'prepare 应成功'
  apply_cert_rotation >/dev/null || fail 'apply 应成功'
  new=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  [[ "$new" != "$old" ]] || fail 'apply 应换成新证书'
  systemctl() { return 0; }
  recover_cert_update || fail '下一次命令的恢复步骤本身应可执行'
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$new" ]] || fail '成功 apply 后，下一次普通命令不得自动恢复旧证书'
  [[ "$(read_rotation_kv phase)" == applied ]] || fail '阶段应保持 applied'
  [[ ! -e "${SERVICE_PATH}.certs-rollback" ]] || fail '已完成的事务不得继续留在待恢复目录'
  [[ -d "${SERVICE_PATH}.certs-archive" ]] || fail '旧证书应归档，供显式恢复'
}

test_hujson_keeps_policy_without_derpmap() {
  command -v python3 >/dev/null 2>&1 || { echo "skip - 无 python3"; return 0; }
  local out
  out=$(hujson_patch_certname '{"groups":{"group:ops":["u@example.com"]},"grants":[{"src":["*"],"dst":["*"],"ip":["*"]}]}' 203.0.113.10 900 sha256-raw:new '') || fail '无 derpMap 时应插入而不是丢弃原策略'
  printf '%s' "$out" | grep -q 'group:ops' || fail '必须保留 groups'
  printf '%s' "$out" | grep -q '"grants"' || fail '必须保留 grants'
  printf '%s' "$out" | grep -q '203.0.113.10' || fail '应加入本节点'
  out=$(hujson_patch_certname '{"keep":true,"derpMap":{"OmitDefaultRegions":true}}' 203.0.113.10 900 sha256-raw:new '') || fail '只有 OmitDefaultRegions 时也应插入'
  printf '%s' "$out" | grep -q '"keep":true' || fail '必须保留原根字段'
  printf '%s' "$out" | grep -q 'OmitDefaultRegions' || fail '必须保留 OmitDefaultRegions'
  printf '%s' "$out" | grep -q '203.0.113.10' || fail '应在原 derpMap 中加入节点'
  out=$(hujson_patch_certname '{"keep":1,"derpMap":{}}' 203.0.113.10 900 sha256-raw:new '') || fail '空 derpMap 时应插入 Regions'
  printf '%s' "$out" | grep -q '"keep":1' || fail '空 derpMap 不得丢掉原策略'
  printf '%s' "$out" | grep -q '203.0.113.10' || fail '空 derpMap 应加入节点'
}

test_policy_post_refuses_without_etag() {
  setup_rotation_env
  ENABLE_AUTO_MAINTAIN=1
  POLICY_CREDENTIAL_FILE="$tmp/creds.env"
  printf 'TS_TAILNET=example.com\nTS_API_CLIENT_ID=id\nTS_API_CLIENT_SECRET=sec\nPOLICY_SOURCE=api\n' >"$POLICY_CREDENTIAL_FILE"
  local old
  old=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  prepare_cert_rotation >/dev/null
  policy_auth_state() { printf 'write_ready\n'; }
  policy_http_request() {
    case "$1 $2" in
      "GET /api/v2/tailnet/example.com/acl")
        printf 'HTTP/2 200\r\n\r\n{"derpMap":{"Regions":{"900":{"RegionID":900,"Nodes":[{"HostName":"203.0.113.10","CertName":"sha256-raw:%s"}]}}}}\n' "$old"
        ;;
      "POST /api/v2/tailnet/example.com/acl")
        printf 'posted\n' >"$tmp/posted"
        printf 'HTTP/2 200\r\n\r\n{}\n'
        ;;
      *) printf 'HTTP/2 200\r\n\r\n\n' ;;
    esac
  }
  apply_cert_rotation >/dev/null 2>&1 || true
  [[ ! -e "$tmp/posted" ]] || fail '没有 ETag 时不得 POST'
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$old" ]] || fail '没有 ETag 时不得切换本地证书'
}

test_oauth_json_token_reaches_acl_request() {
  setup_rotation_env
  ENABLE_AUTO_MAINTAIN=1
  POLICY_CREDENTIAL_FILE="$tmp/creds.env"
  printf 'TS_TAILNET=example.com\nTS_API_CLIENT_ID=id\nTS_API_CLIENT_SECRET=fake-secret\nPOLICY_SOURCE=api\n' >"$POLICY_CREDENTIAL_FILE"
  local old
  old=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  prepare_cert_rotation >/dev/null
  policy_http_request() {
    case "$2" in
      /api/v2/oauth/token)
        printf 'HTTP/2 200\r\nContent-Type: application/json\r\n\r\n{"access_token":"fake-token","token_type":"Bearer","expires_in":3600,"scope":"policy_file"}\n'
        ;;
      *)
        printf 'token=%s\n' "${POLICY_TOKEN:-}" >>"$tmp/calls"
        printf 'HTTP/2 200\r\nETag: "v1"\r\n\r\n{"derpMap":{"Regions":{"900":{"RegionID":900,"Nodes":[{"HostName":"203.0.113.10","CertName":"sha256-raw:%s"}]}}}}\n' "$old"
        ;;
    esac
  }
  apply_cert_rotation >/dev/null 2>&1 || true
  [[ "$POLICY_TOKEN" == fake-token ]] || fail "父 shell 应拿到 OAuth token，实际：${POLICY_TOKEN:-空}"
  [[ "${POLICY_GRANTED_SCOPE:-}" == policy_file ]] || fail "应解析 JSON scope，实际：${POLICY_GRANTED_SCOPE:-空}"
  grep -q 'token=fake-token' "$tmp/calls" || fail '后续策略请求必须带上同一 shell 中的 token'
}

test_cloud_certname_ignores_order_and_distance() {
  command -v python3 >/dev/null 2>&1 || { echo "skip - 无 python3"; return 0; }
  local acl current pad
  acl='{"derpMap":{"Regions":{"900":{"RegionID":900,"Nodes":[{"CertName":"sha256-raw:new","HostName":"203.0.113.10","RegionID":900}]}}}}'
  current=$(_cloud_certname_from_acl "$acl" 203.0.113.10)
  [[ "$current" == sha256-raw:new ]] || fail "CertName 在 HostName 之前也应读到，实际：${current:-空}"
  pad=$(python3 -c 'print("x"*500)')
  acl='{"derpMap":{"Regions":{"900":{"Nodes":[{"HostName":"203.0.113.10","RegionID":900,"Note":"'"$pad"'","CertName":"sha256-raw:far"}]}}}}'
  current=$(_cloud_certname_from_acl "$acl" 203.0.113.10)
  [[ "$current" == sha256-raw:far ]] || fail "字段间较长文本不得导致漏读，实际：${current:-空}"
  acl='{"derpMap":{"Regions":{"1":{"Nodes":[{"HostName":"198.51.100.9","CertName":"sha256-raw:other"}]},"900":{"Nodes":[{"CertName":"sha256-raw:mine","HostName":"203.0.113.10","RegionID":900}]}}}}'
  current=$(_cloud_certname_from_acl "$acl" 203.0.113.10)
  [[ "$current" == sha256-raw:mine ]] || fail "不得读到其他节点的 CertName，实际：${current:-空}"
}

test_apply_rejects_changed_target_identity() {
  setup_rotation_env
  ACCEPT_CERT_ROTATION=1
  local old
  old=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  prepare_cert_rotation >/dev/null || fail 'prepare 应成功'
  IP_ADDR=203.0.113.11
  if apply_cert_rotation >/dev/null 2>"$tmp/apply.err"; then
    fail 'prepare 目标与 apply 参数不一致时必须失败'
  fi
  [[ ! -e "$INSTALL_DIR/certs/203.0.113.11.crt" ]] || fail '不得给另一地址安装证书'
  [[ "$(cert_fp "$INSTALL_DIR/certs/203.0.113.10.crt")" == "$old" ]] || fail '原正式证书必须保持不变'
  grep -E -q 'prepare|身份|重新' "$tmp/apply.err" || fail '应说明需要重新 prepare'
}

test_next_prepare_issues_fresh_candidate() {
  setup_rotation_env
  ACCEPT_CERT_ROTATION=1
  prepare_cert_rotation >/dev/null || fail '首次 prepare 应成功'
  apply_cert_rotation >/dev/null || fail 'apply 应成功'
  local applied
  applied=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  prepare_cert_rotation >/dev/null || fail '下一周期 prepare 应成功'
  local candidate
  candidate=$(cert_fp "$(cert_rotation_candidate_cert)")
  [[ "$candidate" != "$applied" ]] || fail '已应用的候选不得在下一周期复用'
  [[ "$(read_rotation_kv old_sha256)" == "$applied" ]] || fail '下一周期的旧指纹应是刚启用的证书'
  [[ "$(read_rotation_kv new_sha256)" == "$candidate" ]] || fail '记录应指向新候选'
  [[ "$(read_rotation_kv phase)" == prepared ]] || fail '新一轮阶段应为 prepared'
}

test_apply_fails_when_service_does_not_load_cert() {
  setup_rotation_env
  ACCEPT_CERT_ROTATION=1
  local old
  old=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  systemctl() {
    case "$1" in
      is-active) [[ ! -e "$tmp/crashed" ]] ;;
      restart) touch "$tmp/crashed"; return 0 ;;
      *) return 0 ;;
    esac
  }
  service_verified_running() { printf 'checked\n' >"$tmp/health-checked"; return 1; }
  prepare_cert_rotation >/dev/null || fail 'prepare 应成功'
  local rc=0
  apply_cert_rotation >/dev/null 2>"$tmp/apply.err" || rc=$?
  [[ -s "$tmp/health-checked" ]] || fail '服务原先在运行时，切换后必须做健康验证'
  [[ "$rc" -ne 0 ]] || fail '健康验证失败时 apply 不得成功'
  [[ "$(read_rotation_kv phase)" != applied ]] || fail '服务未加载新证书时不得记 applied'
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$old" ]] || fail '健康验证失败应恢复旧证书'
}

# D2/D4 安全反向补偿：自动模式下云端 PUT 已成功（云端指向新指纹）后本地切换失败，
# 必须基于最新策略和 ETag 只反向撤回本工具写入的 CertName，不回写整份旧策略。
test_local_switch_failure_reverses_cloud_field() {
  setup_rotation_env
  ACCEPT_CERT_ROTATION=1
  ENABLE_AUTO_MAINTAIN=1
  POLICY_CREDENTIAL_FILE="$tmp/creds.env"
  printf 'TS_TAILNET=example.com\nTS_API_CLIENT_ID=id\nTS_API_CLIENT_SECRET=sec\nPOLICY_SOURCE=api\n' >"$POLICY_CREDENTIAL_FILE"
  local old new
  old=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  prepare_cert_rotation >/dev/null
  new=$(read_rotation_kv new_sha256)
  policy_auth_state() { printf 'write_ready\n'; }
  printf '%s\n' "$old" >"$tmp/cloud-fp"
  printf '0\n' >"$tmp/puts"
  policy_http_request() {
    case "$1 $2" in
      "GET /api/v2/tailnet/example.com/acl")
        local fp; fp=$(cat "$tmp/cloud-fp")
        printf 'etag: "v-%s"\n\n{"derpMap":{"Regions":{"900":{"RegionID":900,"Nodes":[{"HostName":"203.0.113.10","CertName":"sha256-raw:%s"}]}}}}\n' "$fp" "$fp"
        ;;
      "POST /api/v2/tailnet/example.com/acl/validate") printf 'ok\n' ;;
      "POST /api/v2/tailnet/example.com/acl")
        local n; n=$(cat "$tmp/puts"); n=$((n+1)); printf '%s\n' "$n" >"$tmp/puts"
        printf '%s\n' "${POLICY_IF_MATCH-}" >"$tmp/if-match-$n"
        if printf '%s' "$3" | grep -q "sha256-raw:$new"; then
          printf '%s\n' "$new" >"$tmp/cloud-fp"
        elif printf '%s' "$3" | grep -q "sha256-raw:$old"; then
          printf '%s\n' "$old" >"$tmp/cloud-fp"
        fi
        printf 'HTTP/2 200\r\nETag: "v-%s"\r\n\r\n{}\r\n' "$(cat "$tmp/cloud-fp")"
        ;;
      *) return 1 ;;
    esac
  }
  local restarted=0
  systemctl() {
    case "$1" in
      is-active) [[ ! -e "$tmp/crashed" ]] ;;
      restart)
        restarted=$((restarted+1))
        if [[ "$restarted" == 1 ]]; then touch "$tmp/crashed"; else rm -f "$tmp/crashed"; fi
        return 0 ;;
      *) return 0 ;;
    esac
  }
  service_verified_running() { return 1; }
  live_cert_sha256_raw() { cert_fp "$(derper_manual_cert_file)"; }
  local rc=0
  apply_cert_rotation >/dev/null 2>"$tmp/apply.err" || rc=$?
  [[ "$rc" -ne 0 ]] || fail '本地切换失败时 apply 不得成功'
  [[ "$(cat "$tmp/puts")" -ge 2 ]] || fail '本地切换失败后应尝试反向补偿 POST（第二次 PUT）'
  [[ "$(cat "$tmp/cloud-fp")" == "$old" ]] || fail '反向补偿应把云端 CertName 回退到旧指纹，实际：'"$(cat "$tmp/cloud-fp")"
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$old" ]] || fail '本地证书应保持旧指纹'
  grep -E -q '反向补偿' "$tmp/apply.err" || fail '应提示反向补偿'
  [[ "$(read_maintenance_kv result 2>/dev/null || true)" != applied ]] || fail '反向补偿期间不得记 applied'
}

# D2/D4 反向补偿安全边界：云端已被他人改成第三方指纹时，必须停止自动回退并转人工，不得覆盖他人配置。
test_local_switch_failure_foreign_change_blocks_reverse() {
  setup_rotation_env
  ACCEPT_CERT_ROTATION=1
  ENABLE_AUTO_MAINTAIN=1
  POLICY_CREDENTIAL_FILE="$tmp/creds.env"
  printf 'TS_TAILNET=example.com\nTS_API_CLIENT_ID=id\nTS_API_CLIENT_SECRET=sec\nPOLICY_SOURCE=api\n' >"$POLICY_CREDENTIAL_FILE"
  local old new third=foreignfingerprint
  old=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  prepare_cert_rotation >/dev/null
  new=$(read_rotation_kv new_sha256)
  policy_auth_state() { printf 'write_ready\n'; }
  printf '0\n' >"$tmp/gets"
  printf '0\n' >"$tmp/puts"
  policy_http_request() {
    case "$1 $2" in
      "GET /api/v2/tailnet/example.com/acl")
        local n fp; n=$(cat "$tmp/gets"); n=$((n+1)); printf '%s\n' "$n" >"$tmp/gets"
        case "$n" in
          1) fp="$old" ;;   # sync 加载
          2) fp="$new" ;;   # sync 读回（正向 PUT 已成功）
          *) fp="$third" ;; # 反向补偿加载：他人已改成第三方指纹
        esac
        printf 'etag: "v-%s"\n\n{"derpMap":{"Regions":{"900":{"RegionID":900,"Nodes":[{"HostName":"203.0.113.10","CertName":"sha256-raw:%s"}]}}}}\n' "$fp" "$fp"
        ;;
      "POST /api/v2/tailnet/example.com/acl/validate") printf 'ok\n' ;;
      "POST /api/v2/tailnet/example.com/acl")
        local n; n=$(cat "$tmp/puts"); n=$((n+1)); printf '%s\n' "$n" >"$tmp/puts"
        printf 'HTTP/2 200\r\nETag: "v-new"\r\n\r\n{}\r\n'
        ;;
      *) return 1 ;;
    esac
  }
  local restarted=0
  systemctl() {
    case "$1" in
      is-active) [[ ! -e "$tmp/crashed" ]] ;;
      restart)
        restarted=$((restarted+1))
        if [[ "$restarted" == 1 ]]; then touch "$tmp/crashed"; else rm -f "$tmp/crashed"; fi
        return 0 ;;
      *) return 0 ;;
    esac
  }
  service_verified_running() { return 1; }
  live_cert_sha256_raw() { cert_fp "$(derper_manual_cert_file)"; }
  local rc=0
  apply_cert_rotation >/dev/null 2>"$tmp/apply.err" || rc=$?
  [[ "$rc" -ne 0 ]] || fail '本地切换失败时 apply 不得成功'
  [[ "$(cat "$tmp/puts")" -eq 1 ]] || fail '云端已被他人改动时不得发起反向 PUT，实际 PUT 次数：'"$(cat "$tmp/puts")"
  [[ "$(read_maintenance_kv result 2>/dev/null || true)" == needs_coordination ]] || fail '他人改动目标应记 needs_coordination 转人工'
  grep -E -q '待协调|他人|转人工' "$tmp/apply.err" || fail '应提示他人已改目标、转人工协调'
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$old" ]] || fail '本地证书应保持旧指纹'
}

test_timer_ready_only_after_enable() {
  setup_rotation_env
  SYSTEMD_UNIT_DIR="$tmp/systemd"
  mkdir -p "$SYSTEMD_UNIT_DIR"
  ENABLE_AUTO_MAINTAIN=1
  POLICY_CREDENTIAL_FILE="$tmp/creds.env"
  printf 'TS_TAILNET=example.com\nTS_API_CLIENT_ID=id\nTS_API_CLIENT_SECRET=sec\nPOLICY_SOURCE=api\n' >"$POLICY_CREDENTIAL_FILE"
  policy_auth_state() { printf 'write_ready\n'; }
  : >"$tmp/systemctl.log"
  systemctl() { printf '%s\n' "$*" >>"$tmp/systemctl.log"; return 1; }
  apply_auto_maintain_policy >/dev/null 2>&1 || true
  [[ "$(read_maintenance_kv mode 2>/dev/null || true)" != ready ]] || fail 'timer 启用失败时不得持久报告 ready'
  : >"$tmp/systemctl.log"
  stub_timer_systemctl
  apply_auto_maintain_policy >/dev/null || fail 'systemctl 可用时应完成启用'
  [[ "$(read_maintenance_kv mode)" == ready ]] || fail '启用成功后才可记 ready'
  grep -q 'daemon-reload' "$tmp/systemctl.log" || fail '必须 daemon-reload'
  grep -q 'enable --now' "$tmp/systemctl.log" || fail '必须 enable --now'
  grep -q 'is-enabled' "$tmp/systemctl.log" || fail '必须核验 is-enabled'
  grep -q 'is-active' "$tmp/systemctl.log" || fail '必须核验 is-active'
}

test_timer_keeps_node_and_schedule() {
  setup_rotation_env
  SYSTEMD_UNIT_DIR="$tmp/systemd"
  mkdir -p "$SYSTEMD_UNIT_DIR"
  IP_ADDR=203.0.113.99
  DERP_PORT=4444
  STUN_PORT=5555
  CERT_DAYS=90
  CERT_LEAD_DAYS=7
  REGION_ID=901
  REGION_CODE=lab
  REGION_NAME="Lab DERP"
  TS_TAILNET=target.example
  POLICY_CREDENTIAL_FILE="$tmp/custom.env"
  printf 'TS_TAILNET=target.example\nTS_API_CLIENT_ID=id\nTS_API_CLIENT_SECRET=super-secret\nPOLICY_SOURCE=api\n' >"$POLICY_CREDENTIAL_FILE"
  install_cert_maintain_units >/dev/null || fail '应写出维护 unit'
  local unit line conf stable
  unit="$SYSTEMD_UNIT_DIR/derper-cert-maintain.service"
  line=$(sed -n '/^ExecStart=/p' "$unit")
  printf '%s' "$line" | grep -q 'maintain' || fail "ExecStart 应调用 maintain：$line"
  printf '%s' "$line" | grep -q -- '--config ' || fail 'ExecStart 应带上持久配置'
  if grep -q 'super-secret' "$unit"; then fail 'unit 不得写入 secret'; fi
  stable="$(deploy_state_root)/maintenance/deploy_derper_ip_selfsigned.sh"
  [[ -f "$stable" && ! -L "$stable" ]] || fail '脚本应复制到稳定受管路径'
  printf '%s' "$line" | grep -q "$stable" || fail 'ExecStart 应使用稳定脚本路径'
  conf=$(printf '%s\n' "$line" | sed -n 's/.*--config //p')
  [[ -f "$conf" && ! -L "$conf" ]] || fail "维护配置不存在：$conf"
  (
    load_deploy_config "$conf" || exit 1
    [[ "$IP_ADDR" == 203.0.113.99 ]] || exit 1
    [[ "$DERP_PORT" == 4444 && "$STUN_PORT" == 5555 ]] || exit 1
    [[ "$CERT_DAYS" == 90 && "$CERT_LEAD_DAYS" == 7 ]] || exit 1
    [[ "$REGION_ID" == 901 ]] || exit 1
    [[ "$TS_TAILNET" == target.example ]] || exit 1
    [[ "$POLICY_CREDENTIAL_FILE" == "$tmp/custom.env" ]] || exit 1
  ) || fail '维护配置必须保留节点、端口、有效期、提前天数、Tailnet 和凭据路径'
  if grep -q 'super-secret' "$conf"; then fail '配置只保存凭据路径，不保存 secret'; fi
}

test_transient_unknown_keeps_auto_intent() {
  setup_rotation_env
  write_maintenance_status ready recorded '已登记' 0
  policy_auth_state() { printf 'unknown\n'; }
  run_cert_maintain >/dev/null 2>&1 || true
  policy_auth_state() { printf 'write_ready\n'; }
  ENABLE_AUTO_MAINTAIN=0
  [[ "$(evaluate_auto_maintain_readiness)" == ready ]] || fail '临时 unknown 不得取消已登记的自动维护'
  DISABLE_AUTO_MAINTAIN=1
  stub_timer_systemctl
  apply_auto_maintain_policy >/dev/null || fail '显式停用应成功'
  DISABLE_AUTO_MAINTAIN=0
  policy_auth_state() { printf 'write_ready\n'; }
  [[ "$(evaluate_auto_maintain_readiness)" == manual ]] || fail '只有显式停用才撤销自动维护'
}

test_hujson_regions_trailing_comma() {
  command -v python3 >/dev/null 2>&1 || { echo "skip - 无 python3"; return 0; }
  local out
  out=$(hujson_patch_certname '{"derpMap":{"Regions":{"1":{"RegionID":1,"Nodes":[]},}}}' 203.0.113.10 900 sha256-raw:new '') || fail '尾逗号的 Regions 应能追加'
  printf '%s' "$out" | grep -q ',,' && fail "尾逗号被加成双逗号：$out"
  printf '%s' "$out" | grep -q '203.0.113.10' || fail '应追加本节点'
  out=$(hujson_patch_certname '{"derpMap":{"Regions":{"1":{"RegionID":1,"Nodes":[],}, // keep
}}}' 203.0.113.10 900 sha256-raw:new '') || fail '尾逗号加注释也应能追加'
  printf '%s' "$out" | grep -q ',,' && fail "注释后的尾逗号被加成双逗号：$out"
  printf '%s' "$out" | grep -q 'keep' || fail '必须保留注释'
  printf '%s' "$out" | grep -q '203.0.113.10' || fail '注释场景也应追加节点'
}

test_validate_honors_http_status_and_hujson() {
  TS_API_BASE=https://example.invalid
  TS_TAILNET=example.com
  POLICY_TOKEN=fake-token
  curl() {
    printf '%s\n' "$*" >"$tmp/curl.args"
    printf 'HTTP/2 400\r\nContent-Type: application/json\r\n\r\n{"message":"invalid policy"}\n'
    return 0
  }
  local rc=0
  policy_validate_acl '{}' >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || fail 'HTTP 400 的 validate 必须失败'
  grep -q 'application/hujson' "$tmp/curl.args" || fail 'validate 必须声明 HuJSON'
  curl() {
    printf '%s\n' "$*" >"$tmp/curl-get.args"
    printf 'HTTP/2 200\r\nETag: "v"\r\n\r\n{"derpMap":{}}\n'
    return 0
  }
  policy_get_acl >/dev/null || fail 'GET 替身应成功'
  grep -q 'application/hujson' "$tmp/curl-get.args" || fail 'GET 必须请求 HuJSON'
}

stub_main_guards() {
  check_os_environment() { return 0; }
  require_root() { return 0; }
  detect_public_ip() { return 1; }
}

test_maintain_units_refuse_symlink() {
  setup_rotation_env
  SYSTEMD_UNIT_DIR="$tmp/systemd"
  mkdir -p "$SYSTEMD_UNIT_DIR"
  local sentinel lib
  sentinel="$tmp/sentinel"
  printf 'keep-me\n' >"$sentinel"
  ln -s "$sentinel" "$SYSTEMD_UNIT_DIR/derper-cert-maintain.service"
  if install_cert_maintain_units >/dev/null 2>"$tmp/err"; then
    fail '维护 unit 是符号链接时必须拒绝写入'
  fi
  [[ "$(cat "$sentinel")" == 'keep-me' ]] || fail '不得沿 unit 符号链接覆盖其他文件'
  grep -q '符号链接' "$tmp/err" || fail '应说明拒绝符号链接'
  rm -f "$SYSTEMD_UNIT_DIR/derper-cert-maintain.service"
  lib="$(deploy_state_root)/maintenance"
  mkdir -p "$lib"
  rm -f "$lib/deploy_derper_ip_selfsigned.sh"
  ln -s "$sentinel" "$lib/deploy_derper_ip_selfsigned.sh"
  if install_cert_maintain_units >/dev/null 2>"$tmp/err2"; then
    fail '稳定脚本副本是符号链接时必须拒绝覆盖'
  fi
  [[ "$(cat "$sentinel")" == 'keep-me' ]] || fail '不得沿脚本符号链接覆盖其他文件'
}

test_maintain_config_keeps_private_ip_permission() {
  setup_rotation_env
  SYSTEMD_UNIT_DIR="$tmp/systemd"
  mkdir -p "$SYSTEMD_UNIT_DIR"
  IP_ADDR=192.168.1.10
  ALLOW_NON_GLOBAL_IP=1
  RUN_USER=derper
  RUN_USER_EXPLICIT=1
  VERIFY_CLIENTS_MODE=off
  VERIFY_CLIENTS_EXPLICIT=1
  install_cert_maintain_units >/dev/null || fail '应写出维护配置'
  local conf
  conf="$(deploy_state_root)/maintenance/target.conf"
  (
    ALLOW_NON_GLOBAL_IP=0
    RUN_USER=root
    VERIFY_CLIENTS_MODE=on
    load_deploy_config "$conf" || exit 1
    [[ "$IP_ADDR" == 192.168.1.10 ]] || exit 1
    [[ "$ALLOW_NON_GLOBAL_IP" == 1 ]] || exit 1
    [[ "$RUN_USER" == derper ]] || exit 1
    [[ "$VERIFY_CLIENTS_MODE" == off ]] || exit 1
    validate_settings >/dev/null || exit 1
  ) || fail '定时维护必须继承内网放行、运行用户和客户端校验模式'
}

test_cancel_without_ip_discards_candidate_quietly() {
  setup_rotation_env
  prepare_cert_rotation >/dev/null || fail 'prepare 应成功'
  [[ -f "$(cert_rotation_candidate_cert)" ]] || fail '应已有候选'
  stub_main_guards
  IP_ADDR=""
  local out="" rc=0
  out=$(main cancel 2>&1) || rc=$?
  [[ "$rc" -eq 0 ]] || fail "离线且未传 IP 时 cancel 仍应成功，实际退出 ${rc}：${out}"
  [[ ! -e "$(cert_rotation_candidate_cert)" ]] || fail 'cancel 应丢弃候选'
  if printf '%s\n' "$out" | grep -q '服务器已部署'; then fail 'cancel 不得打印部署反馈'; fi
  printf '%s\n' "$out" | grep -q '已丢弃候选' || fail '应说明已丢弃候选'
}

test_maintain_does_not_repeat_deploy_feedback() {
  setup_rotation_env
  write_maintenance_status ready recorded '已登记' 0
  policy_auth_state() { printf 'write_ready\n'; }
  stub_main_guards
  local out rc=0
  out=$(main maintain --ip "$IP_ADDR" --allow-non-global-ip 2>&1) || rc=$?
  [[ "$rc" -eq 0 ]] || fail "未到期的维护应成功，实际退出 $rc：$out"
  if printf '%s\n' "$out" | grep -q '服务器已部署'; then fail '定时维护不得重复打印部署向导'; fi
}

test_purge_all_removes_maintain_program() {
  setup_rotation_env
  SYSTEMD_UNIT_DIR="$tmp/systemd"
  mkdir -p "$SYSTEMD_UNIT_DIR"
  install_cert_maintain_units >/dev/null || fail '应先安装维护副本'
  local script conf
  script="$(deploy_state_root)/maintenance/deploy_derper_ip_selfsigned.sh"
  conf="$(deploy_state_root)/maintenance/target.conf"
  [[ -f "$script" && -f "$conf" ]] || fail '维护副本应存在'
  require_root() { :; }
  remove_healthcheck_cron() { :; }
  remove_tls_connlimit() { :; }
  systemctl() { case "$1" in is-enabled|is-active) return 1 ;; *) return 0 ;; esac; }
  SERVICE_PATH="$tmp/derper.service"
  INSTALL_DIR="$tmp/install-tree"
  BIN_PATH="$tmp/derper-bin"
  mkdir -p "$INSTALL_DIR"
  printf 'bin\n' >"$BIN_PATH"
  printf 'User=derper\n' >"$SERVICE_PATH"
  UNINSTALL=1
  PURGE=0
  PURGE_ALL=0
  uninstall_derper >/dev/null || fail '普通卸载应成功'
  [[ -f "$script" && -f "$conf" ]] || fail '普通卸载应保留维护副本'
  mkdir -p "$INSTALL_DIR"
  printf 'bin\n' >"$BIN_PATH"
  printf 'User=derper\n' >"$SERVICE_PATH"
  PURGE=1
  PURGE_ALL=1
  uninstall_derper >/dev/null || fail '完全卸载应成功'
  [[ ! -e "$script" && ! -e "$conf" ]] || fail 'purge-all 应删除维护脚本和 target.conf'
}

test_status_includes_maintenance_state() {
  setup_rotation_env
  write_maintenance_status manual idle '未配置云端自动维护授权' 0
  setup_snapshot() { :; }
  H0_STATUS=healthy H1_STATUS=healthy H2_STATUS=not_applicable H3_STATUS=not_checked H3_REASON=probe_not_configured
  METRICS_FRESHNESS=not_checked METRICS_AGE='' HEALTH_SNAPSHOT_READY=1
  SAMPLED_AT=$(date +%s)
  HEALTH_DAYS_LEFT=120 HEALTH_LAST_SUCCESS=0
  HEALTH_CERT_SHA256=$(printf '%064d' 1)
  HEALTH_LIVE_SHA256=$HEALTH_CERT_SHA256
  render_status_json >"$tmp/status.json"
  grep -q '"maintenance"' "$tmp/status.json" || fail 'JSON 应包含 maintenance'
  grep -q '"mode":"manual"' "$tmp/status.json" || fail '应报告人工模式'
}

test_bug107_apply_refuses_live_key_symlink_before_copy() {
  setup_rotation_env
  ACCEPT_CERT_ROTATION=1
  prepare_cert_rotation >/dev/null || fail 'prepare 应成功'
  local key sentinel
  key=$(derper_manual_key_file)
  sentinel="$tmp/secret-target"
  printf 'do-not-overwrite\n' >"$sentinel"
  rm -f "$key"
  ln -s "$sentinel" "$key"
  if apply_cert_rotation >/dev/null 2>"$tmp/err"; then
    fail '正式私钥是符号链接时 apply 必须失败'
  fi
  [[ "$(cat "$sentinel")" == 'do-not-overwrite' ]] || fail '复制前必须拒绝符号链接，不能覆盖链接目标'
  grep -q '符号链接' "$tmp/err" || fail '应说明拒绝符号链接'
}

test_bug108_failed_switch_restarts_previous_service() {
  setup_rotation_env
  ACCEPT_CERT_ROTATION=1
  local old
  old=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  printf '0\n' >"$tmp/restarts"
  systemctl() {
    case "$1" in
      is-active) [[ ! -e "$tmp/down" ]] ;;
      restart)
        local n
        n=$(cat "$tmp/restarts")
        n=$((n + 1))
        printf '%s\n' "$n" >"$tmp/restarts"
        if [[ "$n" -eq 1 ]]; then
          touch "$tmp/down"
          return 1
        fi
        rm -f "$tmp/down"
        return 0
        ;;
      *) return 0 ;;
    esac
  }
  verify_restored_service() {
    printf 'verified\n' >"$tmp/verified"
    [[ ! -e "$tmp/down" ]]
  }
  prepare_cert_rotation >/dev/null || fail 'prepare 应成功'
  if apply_cert_rotation >/dev/null 2>"$tmp/err"; then
    fail '新证书重启失败时 apply 必须失败'
  fi
  [[ "$(cat "$tmp/restarts")" -ge 2 ]] || fail '回滚后必须再次启动原服务'
  [[ -s "$tmp/verified" ]] || fail '回滚后必须验证原服务'
  [[ ! -e "$tmp/down" ]] || fail '原服务应被重新拉起'
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$old" ]] || fail '正式证书应恢复为旧证书'
  [[ "$(read_rotation_kv phase)" != applied ]] || fail '失败后不得记为 applied'
}

test_bug102_disable_blocks_historical_auto_apply() {
  setup_rotation_env
  prepare_cert_rotation >/dev/null || fail 'prepare 应成功'
  write_maintenance_status ready recorded '已登记' 0
  DISABLE_AUTO_MAINTAIN=1
  ACCEPT_CERT_ROTATION=0
  ENABLE_AUTO_MAINTAIN=0
  policy_auth_state() { printf 'write_ready\n'; }
  printf '0\n' >"$tmp/posted"
  policy_http_request() {
    printf '1\n' >"$tmp/posted"
    printf 'HTTP/2 200\r\nETag: "v"\r\n\r\n{}\n'
  }
  local before rc=0
  before=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  apply_cert_rotation >/dev/null 2>"$tmp/err" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "停用自动维护时，未确认换证的 apply 应结束停用流程而不是失败：${rc} $(cat "$tmp/err")"
  [[ "$(cat "$tmp/posted")" == 0 ]] || fail '停用选项不得沿用历史授权去写云端'
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$before" ]] || fail '停用选项不得切换正式证书'
}

test_bug103_idempotent_deploy_honors_maintain_switch() {
  DEPLOY_STATE_DIR="$tmp/deploy-state"
  SYSTEMD_UNIT_DIR="$tmp/systemd"
  TS_TAILNET=example.com
  mkdir -p "$DEPLOY_STATE_DIR" "$SYSTEMD_UNIT_DIR"
  flock() { return 0; }
  check_os_environment() { :; }
  require_root() { :; }
  recover_cert_update() { return 0; }
  check_tailscale_status() { TS_INSTALLED=1 TS_RUNNING=1 TS_VERSION="1.80.0" TS_VER_OK=1; }
  check_derper_status() {
    DERPER_BIN=1 DERPER_SERVICE_PRESENT=1 DERPER_RUNNING=1 PURE_IP_OK=1
    DESIRED_CONFIG_OK=1 DERPER_VERIFY_CLIENTS_EFFECTIVE=1
    PORT_TLS_OK=1 PORT_STUN_OK=1 CURRENT_DERPER_OWNS_PORTS=1
    TS_LOCALAPI_OK=1 TS_AUTH_UNKNOWN=0
  }
  check_cert_status() { CERT_PRESENT=1 CERT_NAMING_OK=1 CERT_SAN_MATCH=1 CERT_EXPIRY_OK=1; }
  check_live_cert_status() { LIVE_CERT_CHECKED=1 CERT_LIVE_MATCH=1; }
  cert_layout_is_ok() { return 0; }
  check_extra_attack_surface() { EXTRA_LISTENERS=""; }
  check_automatic_updates() { AUTO_UPDATES_OK=1; }
  precheck_verify_clients() { return 0; }
  # 幂等用例不依赖真实 Tailnet；固定 Region 预检，避免本机 derpMap 占用导致误失败。
  precheck_region_id_conflict() { return 0; }
  align_derper_version_with_tailscale() { :; }
  derper_binary_needs_install() { return 1; }
  ensure_compatible_certs() { CERTS_CHANGED=0; return 0; }
  commit_cert_update() { return 0; }
  run_post_deploy_extras() { return 0; }
  publish_verification_gate() { return 0; }
  write_systemd_service() { fail '幂等部署不得重写 derper unit'; }
  stub_timer_systemctl
  policy_auth_state() { printf 'write_ready\n'; }
  local out rc=0
  out=$(main --enable-auto-maintain --ip 8.8.8.8 2>&1) || rc=$?
  [[ "$rc" -eq 0 ]] || fail "已就绪节点启用自动维护应成功：${rc} ${out}"
  [[ -f "$SYSTEMD_UNIT_DIR/derper-cert-maintain.timer" ]] || fail '幂等部署的启用选项必须安装 timer'
  [[ "$(read_maintenance_kv mode)" == ready ]] || fail '启用成功后应登记 ready'
  out=$(main --disable-auto-maintain --ip 8.8.8.8 2>&1) || rc=$?
  [[ "$rc" -eq 0 ]] || fail "已就绪节点停用自动维护应成功：${rc} ${out}"
  [[ "$(read_maintenance_kv mode)" == manual ]] || fail '幂等部署的停用选项必须撤销登记'
  [[ ! -e "$SYSTEMD_UNIT_DIR/derper-cert-maintain.timer" ]] || fail '停用必须删除 timer'
}

test_bug104_failed_timer_install_is_not_reported_ready() {
  setup_rotation_env
  SYSTEMD_UNIT_DIR="$tmp/systemd"
  mkdir -p "$SYSTEMD_UNIT_DIR"
  ENABLE_AUTO_MAINTAIN=1
  policy_auth_state() { printf 'write_ready\n'; }
  systemctl() { return 1; }
  local rc=0 mode text
  apply_auto_maintain_policy >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || fail 'timer 启用失败时安装结果必须失败'
  mode=$(evaluate_auto_maintain_readiness)
  [[ "$mode" != ready ]] || fail '调度安装失败后不得仍判断为 ready'
  text=$(print_auto_maintain_feedback "$mode")
  if printf '%s\n' "$text" | grep -q '已启用本节点自动换证'; then
    fail '摘要不得宣称维护任务已就绪'
  fi
}

test_bug104_timer_failures_survive_fresh_commands() {
  local stage failed_stage=0
  for stage in install activate; do (
    setup_rotation_env
    SYSTEMD_UNIT_DIR="$tmp/systemd-$stage"
    mkdir -p "$SYSTEMD_UNIT_DIR"
    policy_auth_state() { printf 'write_ready\n'; }
    stub_timer_systemctl
    ENABLE_AUTO_MAINTAIN=1
    apply_auto_maintain_policy >/dev/null || fail '首次启用应成功'
    remove_cert_maintain_units || fail '应能移除旧调度'
    if [[ "$stage" == install ]]; then
      printf 'keep\n' >"$tmp/unit-target"
      ln -s "$tmp/unit-target" "$SYSTEMD_UNIT_DIR/derper-cert-maintain.timer"
    else
      systemctl() { return 1; }
    fi
    if finish_deploy_auto_maintain >"$tmp/failure-feedback" 2>&1; then
      fail "$stage 失败时收尾必须失败"
    fi
    [[ "$(read_maintenance_kv mode)" == unknown ]] || fail '失败必须记录 unknown'
    [[ "$(read_maintenance_kv intent)" == enabled ]] || fail '调度失败不应撤销用户启用意图'
    local out rc=0
    out=$(bash -c '
      DERPER_TEST_MODE=1 source "$1"
      DEPLOY_STATE_DIR="$2"
      policy_auth_state() { echo write_ready; }
      cert_days_remaining() { echo 365; }
      finish_deploy_auto_maintain
    ' acceptance "$SCRIPT" "$DEPLOY_STATE_DIR" 2>&1) || rc=$?
    if printf '%s\n' "$out" | grep -q '已启用本节点自动换证'; then
      fail "$stage 失败后新进程不得宣称 ready"
    fi
    [[ "$rc" -ne 0 ]] || fail "$stage 失败后新进程收尾必须非零"
    ENABLE_AUTO_MAINTAIN=0
    [[ "$(evaluate_auto_maintain_readiness)" == unknown ]] || fail '历史授权不能掩盖调度失败'
    rm -f "$SYSTEMD_UNIT_DIR/derper-cert-maintain.timer"
    stub_timer_systemctl
    ENABLE_AUTO_MAINTAIN=1
    finish_deploy_auto_maintain >/dev/null || fail '成功重新启用应解除调度失败'
    ENABLE_AUTO_MAINTAIN=0
    [[ "$(evaluate_auto_maintain_readiness)" == ready ]] || fail '重新启用成功后应保持 ready'
  ) || failed_stage=1; done
  [[ "$failed_stage" == 0 ]]
}

test_bug104_maintain_retries_preserve_schedule_failure() {
  setup_rotation_env
  SYSTEMD_UNIT_DIR="$tmp/systemd"
  mkdir -p "$SYSTEMD_UNIT_DIR"
  write_maintenance_status ready recorded '已登记' 0
  policy_auth_state() { printf 'write_ready\n'; }
  ENABLE_AUTO_MAINTAIN=1
  systemctl() { return 1; }
  if apply_auto_maintain_policy >/dev/null 2>&1; then fail '应注入启用失败'; fi
  ENABLE_AUTO_MAINTAIN=0
  prepare_cert_rotation() { fail '调度失败未解除前不得开始换证'; }
  policy_auth_state() { printf 'unknown\n'; }
  if run_cert_maintain >/dev/null 2>&1; then fail '授权未知时维护必须失败'; fi
  policy_auth_state() { printf 'write_ready\n'; }
  local i
  for i in 1 2; do
    if run_cert_maintain >/dev/null 2>&1; then fail '授权恢复不得清除调度失败'; fi
    [[ "$(evaluate_auto_maintain_readiness)" == unknown ]] || fail '维护状态重写后仍须 unknown'
  done
  DISABLE_AUTO_MAINTAIN=1
  stub_timer_systemctl
  finish_deploy_auto_maintain >/dev/null || fail '显式停用应能解除失败并返回人工模式'
  DISABLE_AUTO_MAINTAIN=0
  [[ "$(evaluate_auto_maintain_readiness)" == manual ]] || fail '停用后须保持人工模式'
}

test_bug104_legacy_failed_schedule_is_not_ready() {
  setup_rotation_env
  local status
  status=$(maintenance_status_path)
  mkdir -p "$(dirname "$status")"
  printf 'mode=unknown\nresult=failed\nreason=未能启用维护 timer\nintent=enabled\n' >"$status"
  policy_auth_state() { printf 'write_ready\n'; }
  [[ "$(evaluate_auto_maintain_readiness)" == unknown ]] || fail '旧版调度失败记录也必须阻止 ready'
  if run_cert_maintain >/dev/null 2>&1; then fail '旧版调度失败不得进入维护'; fi
  [[ "$(evaluate_auto_maintain_readiness)" == unknown ]] || fail '旧版失败须在状态更新后继续保留'
}

test_bug107_apply_refuses_install_root_symlink() {
  setup_rotation_env
  ACCEPT_CERT_ROTATION=1
  prepare_cert_rotation >/dev/null || fail 'prepare 应成功'
  local cert_before key_before unit_before
  cert_before=$(file_sha256 "$INSTALL_DIR/certs/$IP_ADDR.crt")
  key_before=$(file_sha256 "$INSTALL_DIR/certs/$IP_ADDR.key")
  unit_before=$(file_sha256 "$SERVICE_PATH")
  mv "$INSTALL_DIR" "$tmp/external-install"
  ln -s "$tmp/external-install" "$INSTALL_DIR"
  write_maintenance_status ready recorded '已登记' 0
  policy_auth_state() { printf 'write_ready\n'; }
  sync_policy_for_candidate() { touch "$tmp/cloud-written"; return 0; }
  if apply_cert_rotation >/dev/null 2>"$tmp/apply.err"; then
    fail '安装根目录为链接时 apply 必须拒绝'
  fi
  [[ ! -e "$tmp/cloud-written" ]] || fail '发现不安全目录后不得先更新云端指纹'
  if _switch_live_certificate_from_candidate >/dev/null 2>"$tmp/switch.err"; then
    fail '底层切换入口也必须拒绝安装根目录链接'
  fi
  [[ "$(file_sha256 "$tmp/external-install/certs/$IP_ADDR.crt")" == "$cert_before" ]] || fail '不得覆盖外部证书'
  [[ "$(file_sha256 "$tmp/external-install/certs/$IP_ADDR.key")" == "$key_before" ]] || fail '不得覆盖外部私钥'
  [[ "$(file_sha256 "$SERVICE_PATH")" == "$unit_before" ]] || fail '不得改动原服务 unit'
  [[ ! -e "${SERVICE_PATH}.certs-rollback" ]] || fail '拒绝目录链接时不应开始证书事务'
  [[ "$(read_rotation_kv phase)" == prepared ]] || fail '拒绝后应保留待处理候选'
  grep -q '符号链接' "$tmp/apply.err" || fail 'apply 应说明拒绝目录链接'
  grep -q '符号链接' "$tmp/switch.err" || fail '底层切换应说明拒绝目录链接'
}

test_bug101_missing_tailnet_has_no_write_authorization() {
  setup_rotation_env
  TS_TAILNET=''
  POLICY_CREDENTIAL_FILE="$tmp/credentials"
  printf 'TS_API_CLIENT_ID=id\nTS_API_CLIENT_SECRET=fake-secret\nPOLICY_SOURCE=api\n' >"$POLICY_CREDENTIAL_FILE"
  chmod 600 "$POLICY_CREDENTIAL_FILE"
  policy_http_request() {
    touch "$tmp/http-called"
    printf 'HTTP/2 200\r\n\r\n{"access_token":"fake-token","scope":"policy_file"}\n'
  }
  [[ "$(policy_auth_state)" == none ]] || fail '缺少 Tailnet 时不得判为可写或尝试获取授权'
  [[ ! -e "$tmp/http-called" ]] || fail '缺少目标时不得调用 OAuth 或策略 API'
  printf 'TS_TAILNET=   \nTS_API_CLIENT_ID=id\nTS_API_CLIENT_SECRET=fake-secret\nPOLICY_SOURCE=api\n' >"$POLICY_CREDENTIAL_FILE"
  [[ "$(policy_auth_state)" == none ]] || fail '只有空白的 Tailnet 也应视为缺目标'
  [[ ! -e "$tmp/http-called" ]] || fail '空白目标不得触发 HTTP 请求'
}

test_bug101_missing_tailnet_cannot_enable_timer() {
  setup_rotation_env
  TS_TAILNET=''
  POLICY_CREDENTIAL_FILE="$tmp/credentials"
  printf 'TS_API_CLIENT_ID=id\nTS_API_CLIENT_SECRET=fake-secret\nPOLICY_SOURCE=api\n' >"$POLICY_CREDENTIAL_FILE"
  chmod 600 "$POLICY_CREDENTIAL_FILE"
  SYSTEMD_UNIT_DIR="$tmp/systemd"
  ENABLE_AUTO_MAINTAIN=1
  stub_timer_systemctl
  policy_http_request() {
    touch "$tmp/http-called"
    printf 'HTTP/2 200\r\n\r\n{"access_token":"fake-token","scope":"policy_file"}\n'
  }
  if finish_deploy_auto_maintain >"$tmp/feedback" 2>&1; then
    fail '显式启用但缺少 Tailnet 时应返回失败'
  fi
  [[ ! -e "$SYSTEMD_UNIT_DIR/derper-cert-maintain.timer" ]] || fail '缺目标不得安装 timer'
  [[ ! -e "$tmp/http-called" ]] || fail '缺目标不得访问 HTTP'
  [[ "$(read_maintenance_kv mode 2>/dev/null || true)" != ready ]] || fail '缺目标不得登记 ready'
  grep -q TS_TAILNET "$tmp/feedback" || fail '应明确提示缺少 TS_TAILNET'
  if grep -q '已启用本节点自动换证' "$tmp/feedback"; then fail '不得宣称已启用'; fi
}

test_bug101_tailnet_from_config_or_credentials_can_enable() {
  local origin failed_origin=0
  for origin in config credentials; do (
    setup_rotation_env
    TS_TAILNET=''
    POLICY_CREDENTIAL_FILE="$tmp/credentials-$origin"
    printf 'TS_API_CLIENT_ID=id\nTS_API_CLIENT_SECRET=fake-secret\nPOLICY_SOURCE=api\n' >"$POLICY_CREDENTIAL_FILE"
    chmod 600 "$POLICY_CREDENTIAL_FILE"
    if [[ "$origin" == config ]]; then
      printf 'CONFIG_VERSION=1\nTS_TAILNET=example.com\n' >"$tmp/deploy.conf"
      load_deploy_config "$tmp/deploy.conf" || fail '应能从部署配置读取 Tailnet'
    else
      printf 'TS_TAILNET=example.com\n' >>"$POLICY_CREDENTIAL_FILE"
    fi
    SYSTEMD_UNIT_DIR="$tmp/systemd-$origin"
    ENABLE_AUTO_MAINTAIN=1
    stub_timer_systemctl
    policy_http_request() {
      [[ "$2" == /api/v2/oauth/token ]] || fail '登记前不应写策略'
      printf 'HTTP/2 200\r\n\r\n{"access_token":"fake-token","scope":"policy_file"}\n'
    }
    [[ "$(policy_auth_state)" == write_ready ]] || fail "$origin 提供有效目标和写 scope 时应允许登记"
    finish_deploy_auto_maintain >/dev/null || fail "$origin 提供的目标应能启用 timer"
    [[ "$(read_maintenance_kv mode)" == ready ]] || fail '启用成功应登记 ready'
    [[ -f "$SYSTEMD_UNIT_DIR/derper-cert-maintain.timer" ]] || fail '应安装维护 timer'
    grep -q '^TS_TAILNET=example.com$' "$(deploy_state_root)/maintenance/target.conf" || fail '定时配置必须保留实际目标'
  ) || failed_origin=1; done
  [[ "$failed_origin" == 0 ]]
}

test_bug106_config_lead_days_are_explicit() {
  printf 'CONFIG_VERSION=1\nCERT_DAYS=7\nCERT_LEAD_DAYS=30\n' >"$tmp/deploy.conf"
  parse_args check --config "$tmp/deploy.conf" --ip 203.0.113.10 --allow-non-global-ip
  if validate_arg_combos >"$tmp/out" 2>"$tmp/err"; then
    fail '配置中显式超过有效期的提前天数必须拒绝，不能静默收紧'
  fi
  [[ "$CERT_LEAD_DAYS" == 30 ]] || fail '拒绝时应保留用户指定值'
  grep -q '1 到证书有效期' "$tmp/err" || fail '应说明提前天数范围'
}

test_bug106_config_lead_defaults_and_cli_precedence() {
  printf 'CONFIG_VERSION=1\nCERT_DAYS=7\nCERT_LEAD_DAYS=30\n' >"$tmp/explicit.conf"
  (
    parse_args check --config "$tmp/explicit.conf" --lead-days 2
    validate_arg_combos >/dev/null || fail 'CLI 提前天数应覆盖配置中的越界值'
    [[ "$CERT_LEAD_DAYS" == 2 ]] || fail '应使用 CLI 提前天数'
  ) || return 1
  (
    parse_args check --config "$tmp/explicit.conf" --cert-days 90
    validate_arg_combos >/dev/null || fail 'CLI 有效期覆盖后应重新校验配置提前量'
    [[ "$CERT_DAYS" == 90 && "$CERT_LEAD_DAYS" == 30 ]] || fail '应保留配置提前量并应用 CLI 有效期'
  ) || return 1
  printf 'CONFIG_VERSION=1\nCERT_DAYS=7\n' >"$tmp/default.conf"
  parse_args check --config "$tmp/default.conf"
  validate_arg_combos >/dev/null || fail '配置只指定短期证书时默认提前量仍应自动收紧'
  [[ "$CERT_LEAD_DAYS" -le 7 && "$CERT_LEAD_DAYS_EXPLICIT" == 0 ]] || fail '未指定提前量时须保留默认语义'
}

test_bug105_expired_certificate_is_due_for_maintain() {
  setup_rotation_env
  write_maintenance_status ready recorded '已登记' 0
  policy_auth_state() { printf 'write_ready\n'; }
  cert_days_remaining() { echo -2; }
  policy_http_request() { return 1; }
  run_cert_maintain >/dev/null 2>&1 || true
  [[ "$(read_maintenance_kv result)" != idle ]] || fail '已过期证书不得记成未到维护日期'
  [[ "$(read_maintenance_kv reason)" != '未到提前维护日期' ]] || fail '负数剩余天数必须进入换证'
}

test_bug106_short_cert_days_keep_default_lead_in_range() {
  parse_args check --cert-days 7 --ip 203.0.113.10 --allow-non-global-ip
  validate_arg_combos >/dev/null 2>"$tmp/lead.err" || fail "7 天证书不应被默认 30 天提前量拒绝：$(cat "$tmp/lead.err")"
  [[ "$CERT_LEAD_DAYS" -le 7 ]] || fail '未显式指定时，提前天数应收进证书有效期'
  parse_args check --cert-days 7 --lead-days 30 --ip 203.0.113.10 --allow-non-global-ip
  if validate_arg_combos >/dev/null 2>&1; then
    fail '显式 --lead-days 超过有效期时仍应拒绝'
  fi
}


# BUG-111：保留真实切换/回滚/补偿函数，仅用替身模拟旧进程恢复失败。
run_bug111_recovery_scenario() {
  local scenario="$1" old new rc=0
  setup_rotation_env
  ACCEPT_CERT_ROTATION=1 ENABLE_AUTO_MAINTAIN=1
  POLICY_CREDENTIAL_FILE="$tmp/creds.env"
  printf 'TS_TAILNET=example.com\nTS_API_CLIENT_ID=id\nTS_API_CLIENT_SECRET=fake\nPOLICY_SOURCE=api\n' >"$POLICY_CREDENTIAL_FILE"
  old=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  prepare_cert_rotation >/dev/null || fail 'prepare 应成功'
  new=$(read_rotation_kv new_sha256)
  printf '%s\n' "$old" >"$tmp/cloud-fp"
  printf '%s\n' "$old" >"$tmp/live-fp"
  printf '0\n' >"$tmp/puts"
  printf '0\n' >"$tmp/restarts"
  policy_auth_state() { echo write_ready; }
  policy_http_request() {
    local fp n
    case "$1 $2" in
      'GET /api/v2/tailnet/example.com/acl')
        fp=$(cat "$tmp/cloud-fp")
        printf 'HTTP/2 200\r\nETag: "v-%s"\r\n\r\n{"derpMap":{"Regions":{"900":{"RegionID":900,"Nodes":[{"HostName":"203.0.113.10","CertName":"sha256-raw:%s"}]}}}}' "$fp" "$fp" ;;
      'POST /api/v2/tailnet/example.com/acl/validate') printf 'HTTP/2 200\r\n\r\n' ;;
      'POST /api/v2/tailnet/example.com/acl')
        n=$(cat "$tmp/puts"); printf '%s\n' "$((n+1))" >"$tmp/puts"
        fp=$(_cloud_certname_from_acl "$3" "$IP_ADDR")
        printf '%s\n' "${fp#sha256-raw:}" >"$tmp/cloud-fp"
        printf 'HTTP/2 200\r\n\r\n{}' ;;
      *) return 1 ;;
    esac
  }
  systemctl() {
    local n
    case "$1" in
      is-active) [[ "$scenario" != inactive ]] ;;
      restart)
        n=$(cat "$tmp/restarts"); printf '%s\n' "$((n+1))" >"$tmp/restarts"
        if [[ "$n" == 0 ]]; then
          printf '%s\n' "$new" >"$tmp/live-fp"
          return 0
        fi
        [[ "$scenario" != restart_failure ]] || return 1
        if [[ "$scenario" == restored || "$scenario" == archive_failure ]]; then printf '%s\n' "$old" >"$tmp/live-fp"; fi
        return 0 ;;
      *) return 0 ;;
    esac
  }
  live_cert_sha256_raw() { cat "$tmp/live-fp"; }
  verify_switched_derper() { [[ "$scenario" == archive_failure ]]; }
  if [[ "$scenario" == archive_failure ]]; then
    mv() {
      [[ "$1" != "${SERVICE_PATH}.certs-rollback" || "$2" != "$(cert_archive_path)" ]] || return 1
      command mv "$@"
    }
  elif [[ "$scenario" == inactive ]]; then
    cp() {
      [[ "$1" != -p || "$2" != "$(cert_rotation_candidate_cert)" ]] || return 1
      command cp "$@"
    }
  fi
  verify_restored_service() { return 0; }
  cert_days_remaining() { echo 1; }
  if [[ "$scenario" == restored || "$scenario" == archive_failure || "$scenario" == inactive ]]; then
    apply_cert_rotation >"$tmp/out" 2>&1 || rc=$?
  else
    run_cert_maintain >"$tmp/out" 2>&1 || rc=$?
  fi
  cleanup_deployment "$rc"
  [[ "$rc" != 0 ]] || fail '本地换证失败必须非零'
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$old" ]] || fail '磁盘应恢复旧证书'
  if [[ "$scenario" == restored || "$scenario" == archive_failure || "$scenario" == inactive ]]; then
    if [[ "$scenario" == inactive ]]; then [[ "$(cat "$tmp/restarts")" == 0 ]] || fail '原停止服务不得被启动'; fi
    [[ "$(cat "$tmp/cloud-fp")" == "$old" && "$(cat "$tmp/live-fp")" == "$old" && "$(cat "$tmp/puts")" == 2 ]] || fail '只有确认旧运行身份恢复后才能反向写旧指纹'
  else
    [[ "$(cat "$tmp/cloud-fp")" == "$new" && "$(cat "$tmp/puts")" == 1 ]] || fail '旧服务未恢复时不得反向覆盖云端新指纹'
    [[ "$(read_maintenance_kv result)" == needs_coordination && "$(read_maintenance_kv mode)" == unknown && "$(read_maintenance_kv needs_manual)" == 1 ]] || fail '定时维护必须保留本地恢复失败的待协调状态'
  fi
}

test_bug111_failed_restore_keeps_cloud_fingerprint() { run_bug111_recovery_scenario restart_failure; }
test_bug111_wrong_live_cert_blocks_reverse() { run_bug111_recovery_scenario wrong_live; }
test_bug111_confirmed_restore_allows_reverse() { run_bug111_recovery_scenario restored; }

test_bug111_archive_failure_restores_both_identities() { run_bug111_recovery_scenario archive_failure; }
test_bug111_stopped_service_stays_stopped() { run_bug111_recovery_scenario inactive; }

test_bug113_bsd_cert_date_uses_C_locale() {
  setup_rotation_env
  # 不依赖宿主是否安装中文locale；BSD替身只接受明确指定的C locale。
  date() {
    case "$1" in
      +%s) echo 100000 ;;
      -d) return 1 ;;
      -j) [[ "${LC_ALL:-}" == C ]] || return 1; echo 272800 ;;
      *) return 1 ;;
    esac
  }
  local days
  days=$(LC_ALL=POSIX cert_days_remaining)
  [[ "$days" == 2 ]] || fail "BSD证书日期必须与调用者locale无关，实际：${days:-empty}"
}

test_bug114_vm_workflow_exports_fixture() {
  local stage fixture captured rc out
  mkdir -p "$tmp/work/tests"
  cat >"$tmp/work/tests/test_systemd_integration.sh" <<'SH'
#!/usr/bin/env bash
set -eu
: "${DERPER_TEST_BINARY:?fixture missing}"
printf '%s\n' "$DERPER_TEST_BINARY" >"$FIXTURE_CAPTURE"
SH
  # 执行仓库中的实际workflow run块，仅把root默认路径换成临时路径。
  awk -v fallback="$tmp/default fixture" '
    /- name: Run systemd integration suite/ {found=1; next}
    found && /run: \|/ {body=1; next}
    body && /^      - / {exit}
    body {sub(/^          /, ""); gsub(/\/root\/derper/, fallback); print}
  ' "$ROOT_DIR/.github/workflows/tests.yml" >"$tmp/vm-step.sh"
  [[ -s "$tmp/vm-step.sh" ]] || fail '未找到VM实际执行步骤'
  for stage in default explicit missing; do
    fixture="$tmp/default fixture"
    [[ "$stage" != explicit ]] || fixture="$tmp/explicit fixture"
    printf '#!/bin/sh\nexit 0\n' >"$fixture"
    chmod 755 "$fixture"
    [[ "$stage" != missing ]] || rm -f "$fixture"
    captured="$tmp/captured-$stage"
    rc=0
    out=$(
      cd "$tmp/work"
      unset DERPER_TEST_BINARY
      export FIXTURE_CAPTURE="$captured"
      export GITHUB_WORKSPACE="$tmp/work"
      if [[ "$stage" == explicit ]]; then export DERPER_TEST_BINARY="$fixture"; fi
      bash -e "$tmp/vm-step.sh"
    ) || rc=$?
    if [[ "$stage" == missing ]]; then
      [[ "$rc" == 2 ]] || fail "fixture缺失必须明确未验收并返回2：$rc"
      [[ ! -e "$captured" ]] || fail 'fixture缺失时不得执行集成脚本'
      [[ "$out" == *'not verified'* ]] || fail '跳过必须明确标记未验收'
    else
      [[ "$rc" == 0 ]] || fail "VM的${stage}路径传递失败：${rc} ${out}"
      [[ -f "$captured" && "$(cat "$captured")" == "$fixture" ]] || fail '集成脚本必须收到实际fixture路径'
    fi
  done
}

# BUG-118：改 --cert-days 不得复用旧有效期候选；apply 必须拒绝已过期候选。
test_bug118_cert_days_change_regenerates_candidate() {
  setup_rotation_env
  CERT_DAYS=1
  prepare_cert_rotation >/dev/null 2>&1 || fail '1 天候选 prepare 应成功'
  local first_fp first_end second_fp second_end
  first_fp=$(cert_fp "$(cert_rotation_candidate_cert)")
  first_end=$(openssl x509 -in "$(cert_rotation_candidate_cert)" -noout -enddate)
  CERT_DAYS=3650
  prepare_cert_rotation >/dev/null 2>&1 || fail '3650 天候选 prepare 应成功'
  second_fp=$(cert_fp "$(cert_rotation_candidate_cert)")
  second_end=$(openssl x509 -in "$(cert_rotation_candidate_cert)" -noout -enddate)
  [[ "$first_fp" != "$second_fp" ]] || fail '修改 --cert-days 后不得复用旧候选'
  [[ "$first_end" != "$second_end" ]] || fail '十年候选的到期时间必须不同于一天候选'
  [[ "$(read_rotation_kv cert_days)" == 3650 ]] || fail '记录必须保存新的有效期'
  [[ "$(read_rotation_kv new_sha256)" == "$second_fp" ]] || fail '记录必须指向新候选'
  # 相同参数重复 prepare 仍复用同一候选（幂等）
  prepare_cert_rotation >/dev/null 2>&1 || fail '重复 prepare 应成功'
  [[ "$(cert_fp "$(cert_rotation_candidate_cert)")" == "$second_fp" ]] || fail '参数不变时应复用候选'
}

test_bug118_apply_refuses_expired_candidate() {
  setup_rotation_env
  ACCEPT_CERT_ROTATION=1
  CERT_LEAD_DAYS=30
  local live_before expired_fp rc=0
  live_before=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  prepare_cert_rotation >/dev/null 2>&1 || fail 'prepare 应成功'
  # 用真实已过期的同 IP 证书替换候选，并让记录与之保持一致。
  make_expired_cert_pair "$tmp/expired" "$IP_ADDR" || fail '无法生成已过期证书'
  openssl x509 -in "$tmp/expired.crt" -noout -checkend 0 >/dev/null 2>&1 && fail '测试证书必须真实过期'
  cp "$tmp/expired.crt" "$(cert_rotation_candidate_cert)"
  cp "$tmp/expired.key" "$(cert_rotation_candidate_key)"
  expired_fp=$(cert_fp "$tmp/expired.crt")
  write_rotation_record <<RECORD
kind=cert-rotation
phase=prepared
old_sha256=${live_before}
new_sha256=${expired_fp}
region_id=${REGION_ID}
ip=${IP_ADDR}
derp_port=${DERP_PORT}
stun_port=${STUN_PORT}
cert_days=${CERT_DAYS}
tailnet=${TS_TAILNET}
etag=none
policy_mode=manual
lead_days=${CERT_LEAD_DAYS}
RECORD
  apply_cert_rotation >"$tmp/out" 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || fail 'apply 不得切换到已过期候选'
  grep -q '已过期或剩余有效期不足' "$tmp/out" || fail "应说明候选有效期不足：$(cat "$tmp/out")"
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$live_before" ]] || fail '拒绝后正式证书必须保持不变'
  # 重新 prepare 必须丢弃过期候选，而不是复用。
  prepare_cert_rotation >/dev/null 2>&1 || fail '重新 prepare 应成功'
  [[ "$(cert_fp "$(cert_rotation_candidate_cert)")" != "$expired_fp" ]] || fail '过期候选不得被复用'
}

# BUG-119：到期日未知必须非零并留下人工处理信号，不能写成 idle。
test_bug119_unknown_expiry_is_not_idle() {
  setup_rotation_env
  write_maintenance_status ready recorded '已登记' 0
  policy_auth_state() { printf 'write_ready\n'; }
  CERT_LEAD_DAYS=30
  cert_days_remaining() { printf '\n'; }
  local rc=0
  run_cert_maintain >"$tmp/out" 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || fail '到期日未知时维护必须非零'
  [[ "$(read_maintenance_kv result)" != idle ]] || fail '到期日未知不得记为 idle'
  [[ "$(read_maintenance_kv reason)" != '未到提前维护日期' ]] || fail '到期日未知不得写成未到日期'
  [[ "$(read_maintenance_kv needs_manual)" == 1 ]] || fail '到期日未知必须标记需人工'
  grep -q '无法计算证书到期时间' "$tmp/out" || fail '必须输出原因'
  # 确定未到期仍然是 idle 且成功。
  cert_days_remaining() { echo 200; }
  run_cert_maintain >/dev/null 2>&1 || fail '确定未到期应成功'
  [[ "$(read_maintenance_kv result)" == idle && "$(read_maintenance_kv needs_manual)" == 0 ]] || fail '确定未到期应为 idle 且无需人工'
}

test_bug119_cert_rotation_is_due_tristate() {
  setup_rotation_env
  CERT_LEAD_DAYS=30
  local rc
  cert_days_remaining() { echo 10; }
  rc=0; cert_rotation_is_due || rc=$?; [[ "$rc" == 0 ]] || fail "到期应返回 0，实际 $rc"
  cert_days_remaining() { echo 100; }
  rc=0; cert_rotation_is_due || rc=$?; [[ "$rc" == 1 ]] || fail "未到期应返回 1，实际 $rc"
  cert_days_remaining() { echo ''; }
  rc=0; cert_rotation_is_due || rc=$?; [[ "$rc" == 2 ]] || fail "未知应返回 2，实际 $rc"
  cert_days_remaining() { echo 10; }
  CERT_LEAD_DAYS=abc
  rc=0; cert_rotation_is_due || rc=$?; [[ "$rc" == 2 ]] || fail "提前天数非法应返回 2，实际 $rc"
}

# BUG-120：目标歧义/策略不可解析不能当作“云端没有本节点”。
run_bug120_reverse_scenario() {
  local scenario="$1" old new rc=0 policy_body=""
  command -v python3 >/dev/null 2>&1 || { echo "skip - 无 python3，HuJSON 解析未测"; return 0; }
  setup_rotation_env
  ENABLE_AUTO_MAINTAIN=1
  prepare_cert_rotation >/dev/null 2>&1 || fail 'prepare 应成功'
  old=$(read_rotation_kv old_sha256)
  new=$(read_rotation_kv new_sha256)
  write_maintenance_status ready recorded '已登记' 0
  case "$scenario" in
    duplicate)
      policy_body=$(printf '{"derpMap":{"Regions":{"900":{"RegionID":900,"Nodes":[{"HostName":"203.0.113.10","CertName":"sha256-raw:%s"},{"HostName":"203.0.113.10","CertName":"sha256-raw:%s"}]}}}}' "$new" "$new") ;;
    region_mismatch)
      policy_body=$(printf '{"derpMap":{"Regions":{"901":{"RegionID":901,"Nodes":[{"HostName":"203.0.113.10","RegionID":901,"CertName":"sha256-raw:%s"}]}}}}' "$new") ;;
    missing_certname)
      policy_body='{"derpMap":{"Regions":{"900":{"RegionID":900,"Nodes":[{"HostName":"203.0.113.10"}]}}}}' ;;
    unparsable)
      policy_body='<<<not a policy>>>' ;;
    trailing_garbage)
      policy_body='{} trailing-garbage' ;;
    multiple_roots)
      policy_body='{} {}' ;;
    absent)
      policy_body='{"derpMap":{"Regions":{"900":{"RegionID":900,"Nodes":[{"HostName":"198.51.100.7","CertName":"sha256-raw:abc"}]}}}}' ;;
  esac
  BUG120_POLICY_BODY="$policy_body"
  # 注意：被测函数内部有同名局部变量 acl，替身必须读不会被遮蔽的全局变量。
  policy_load_acl() { POLICY_ACL_BODY="$BUG120_POLICY_BODY"; POLICY_IF_MATCH='"etag"'; return 0; }
  printf '0\n' >"$tmp/puts"
  policy_validate_acl() { return 0; }
  policy_put_acl() { printf '1\n' >"$tmp/puts"; return 0; }
  reverse_compensate_certname >"$tmp/out" 2>&1 || rc=$?
  if [[ "$scenario" == absent ]]; then
    [[ "$rc" == 0 ]] || fail "云端确认没有本节点时无需补偿应成功：$(cat "$tmp/out")"
    [[ "$(read_maintenance_kv result)" != needs_coordination ]] || fail '确认不存在时不应转人工'
  else
    [[ "$rc" != 0 ]] || fail "${scenario}：目标歧义不得当作无需补偿：$(cat "$tmp/out")"
    [[ "$(read_maintenance_kv result)" == needs_coordination ]] || fail "${scenario}：必须记录 needs_coordination"
    [[ "$(read_maintenance_kv needs_manual)" == 1 ]] || fail "${scenario}：必须标记需人工"
    [[ "$(cat "$tmp/puts")" == 0 ]] || fail "${scenario}：歧义时不得写云端"
  fi
}

test_bug120_duplicate_hostname_requires_coordination() { run_bug120_reverse_scenario duplicate; }
test_bug120_region_mismatch_requires_coordination() { run_bug120_reverse_scenario region_mismatch; }
test_bug120_missing_certname_requires_coordination() { run_bug120_reverse_scenario missing_certname; }
test_bug120_unparsable_policy_requires_coordination() { run_bug120_reverse_scenario unparsable; }
test_bug120_confirmed_absent_needs_no_compensation() { run_bug120_reverse_scenario absent; }

# BUG-121：卸载吞掉维护调度删除失败。完整 CLI 入口必须非零且不报告完成。
test_bug121_uninstall_propagates_maintain_unit_removal_failure() {
  setup_rotation_env
  SYSTEMD_UNIT_DIR="$tmp/systemd"
  mkdir -p "$SYSTEMD_UNIT_DIR"
  DEPLOY_STATE_DIR="$tmp/deploy-state"
  install_cert_maintain_units >/dev/null || fail '应先安装维护 unit'
  # 把 timer 替换成非空目录：rm -f 无法删除，模拟删除失败。
  rm -f "$SYSTEMD_UNIT_DIR/derper-cert-maintain.timer"
  mkdir -p "$SYSTEMD_UNIT_DIR/derper-cert-maintain.timer/keep"
  check_os_environment() { :; }
  require_root() { :; }
  remove_healthcheck_cron() { :; }
  remove_tls_connlimit() { :; }
  ordinary_change_allowed() { return 0; }
  recover_interrupted_change() { return 0; }
  acquire_deploy_lock() { return 0; }
  stub_timer_systemctl
  : >"$tmp/maintain-enabled"
  local out rc=0
  out=$(main --uninstall 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "维护 unit 删除失败时卸载必须非零：${out}"
  [[ "$out" != *'完成：已卸载 derper 服务'* ]] || fail '删除失败不得报告卸载完成'
  [[ "$out" == *'维护 unit 文件未能删除'* ]] || fail "必须说明具体失败原因：${out}"
  [[ ! -e "$SERVICE_PATH" ]] || fail '其余卸载步骤仍应继续（derper unit 已移除）'
}

test_bug121_uninstall_checks_enabled_and_running_state() {
  setup_rotation_env
  SYSTEMD_UNIT_DIR="$tmp/systemd"
  mkdir -p "$SYSTEMD_UNIT_DIR"
  install_cert_maintain_units >/dev/null || fail '应先安装维护 unit'
  # 文件可删除，但 timer 仍被 systemd 报告为启用：不能算删除成功。
  systemctl() { return 0; }
  if remove_cert_maintain_units >/dev/null 2>"$tmp/err"; then fail '仍处于启用状态时必须失败'; fi
  grep -q '仍处于启用状态' "$tmp/err" || fail '应说明启用状态残留'
  systemctl() {
    case "$1" in
      is-enabled) return 1 ;;
      is-active) [[ "$*" == *timer* ]] ;;
      *) return 0 ;;
    esac
  }
  if remove_cert_maintain_units >/dev/null 2>"$tmp/err"; then fail '仍在运行时必须失败'; fi
  grep -q '仍在运行' "$tmp/err" || fail '应说明运行状态残留'
  systemctl() { case "$1" in is-enabled|is-active) return 1 ;; *) return 0 ;; esac; }
  remove_cert_maintain_units >/dev/null 2>&1 || fail '已停用且文件已删除应成功'
}

test_bug121_disable_failure_is_not_recorded_as_clean_manual() {
  setup_rotation_env
  SYSTEMD_UNIT_DIR="$tmp/systemd"
  mkdir -p "$SYSTEMD_UNIT_DIR/derper-cert-maintain.service/keep"
  DISABLE_AUTO_MAINTAIN=1
  systemctl() { case "$1" in is-enabled|is-active) return 1 ;; *) return 0 ;; esac; }
  local rc=0
  apply_auto_maintain_policy >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || fail '停用时删除 unit 失败必须向外传播'
  [[ "$(read_maintenance_kv scheduler_state)" == failed ]] || fail '调度残留必须记录为 failed'
  [[ "$(read_maintenance_kv needs_manual)" == 1 ]] || fail '调度残留必须标记需人工'
}

test_bug118_apply_rejects_changed_cert_days() {
  setup_rotation_env
  ACCEPT_CERT_ROTATION=1
  ENABLE_AUTO_MAINTAIN=1
  CERT_DAYS=1
  prepare_cert_rotation >/dev/null 2>&1 || fail 'prepare 应成功'
  local live_before
  live_before=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  CERT_DAYS=3650
  policy_auth_state() { printf 'write_ready\n'; }
  policy_load_acl() { touch "$tmp/cloud-called"; return 1; }
  local rc=0
  apply_cert_rotation >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || fail 'apply 不得接受与 prepare 不一致的 cert-days'
  [[ ! -e "$tmp/cloud-called" ]] || fail 'cert-days 不匹配时不得读取或写入云端以尝试切换'
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$live_before" ]] || fail 'cert-days 不匹配时正式证书不得改变'
}

test_bug120_trailing_garbage_requires_coordination() { run_bug120_reverse_scenario trailing_garbage; }
test_bug120_multiple_roots_require_coordination() { run_bug120_reverse_scenario multiple_roots; }

test_bug121_daemon_reload_failure_propagates() {
  setup_rotation_env
  SYSTEMD_UNIT_DIR="$tmp/systemd"
  mkdir -p "$SYSTEMD_UNIT_DIR"
  systemctl() { case "$1" in daemon-reload) return 1 ;; *) return 0 ;; esac; }
  if remove_cert_maintain_units >/dev/null 2>"$tmp/err"; then
    fail 'daemon-reload 失败不得算维护调度删除成功'
  fi
  grep -q 'daemon-reload' "$tmp/err" || fail '应说明 daemon-reload 失败'
}

test_bug121_uninstall_daemon_reload_failure_is_not_success() {
  setup_rotation_env
  SYSTEMD_UNIT_DIR="$tmp/systemd"
  mkdir -p "$SYSTEMD_UNIT_DIR"
  check_os_environment() { :; }
  require_root() { :; }
  remove_healthcheck_cron() { :; }
  remove_tls_connlimit() { :; }
  ordinary_change_allowed() { return 0; }
  recover_interrupted_change() { return 0; }
  acquire_deploy_lock() { return 0; }
  systemctl() { case "$1" in daemon-reload) return 1 ;; is-enabled|is-active) return 1 ;; *) return 0 ;; esac; }
  local out rc=0
  out=$(main --uninstall 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail '卸载时 daemon-reload 失败必须非零'
  [[ "$out" != *'完成：已卸载 derper 服务'* ]] || fail 'daemon-reload 失败不得报告卸载完成'
  [[ "$out" == *'daemon-reload'* ]] || fail '卸载应说明 daemon-reload 失败'
  [[ ! -e "$SERVICE_PATH" ]] || fail '其余卸载步骤仍应继续'
}

test_bug121_disable_daemon_reload_failure_marks_failed() {
  setup_rotation_env
  SYSTEMD_UNIT_DIR="$tmp/systemd"
  mkdir -p "$SYSTEMD_UNIT_DIR"
  DISABLE_AUTO_MAINTAIN=1
  systemctl() { case "$1" in daemon-reload) return 1 ;; is-enabled|is-active) return 1 ;; *) return 0 ;; esac; }
  local rc=0
  apply_auto_maintain_policy >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || fail '停用时 daemon-reload 失败必须非零'
  [[ "$(read_maintenance_kv scheduler_state)" == failed ]] || fail 'reload 失败必须记录 scheduler_state=failed'
  [[ "$(read_maintenance_kv needs_manual)" == 1 ]] || fail 'reload 失败必须标记需人工'
}

# BUG-116：定时任务内部执行 maintain 成功后，不得被 main 重新登记覆盖。
test_bug116_maintain_success_state_survives_main() {
  local old new unit_marker
  setup_rotation_env
  SYSTEMD_UNIT_DIR="$tmp/systemd"
  mkdir -p "$SYSTEMD_UNIT_DIR"
  POLICY_CREDENTIAL_FILE="$tmp/creds.env"
  printf 'TS_TAILNET=example.com\nTS_API_CLIENT_ID=id\nTS_API_CLIENT_SECRET=fake\nPOLICY_SOURCE=api\n' >"$POLICY_CREDENTIAL_FILE"
  old=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  printf '%s\n' "$old" >"$tmp/cloud-fp"
  printf '%s\n' "$old" >"$tmp/live-fp"
  policy_auth_state() { echo write_ready; }
  policy_http_request() {
    local fp
    case "$1 $2" in
      'GET /api/v2/tailnet/example.com/acl')
        fp=$(cat "$tmp/cloud-fp")
        printf 'HTTP/2 200\r\nETag: "v-%s"\r\n\r\n{"derpMap":{"Regions":{"900":{"RegionID":900,"Nodes":[{"HostName":"203.0.113.10","CertName":"sha256-raw:%s"}]}}}}' "$fp" "$fp" ;;
      'POST /api/v2/tailnet/example.com/acl/validate') printf 'HTTP/2 200\r\n\r\n' ;;
      'POST /api/v2/tailnet/example.com/acl')
        fp=$(_cloud_certname_from_acl "$3" "$IP_ADDR")
        printf '%s\n' "${fp#sha256-raw:}" >"$tmp/cloud-fp"
        printf 'HTTP/2 200\r\n\r\n{}' ;;
      *) return 1 ;;
    esac
  }
  stub_timer_systemctl
  # 登记自动维护（用户显式启用）：写入 ready/recorded 并安装 unit。
  ENABLE_AUTO_MAINTAIN=1
  apply_auto_maintain_policy >/dev/null || fail '首次启用应成功'
  ENABLE_AUTO_MAINTAIN=0
  unit_marker="$SYSTEMD_UNIT_DIR/derper-cert-maintain.service"
  [[ -f "$unit_marker" ]] || fail '启用后应存在维护 unit'
  rm -f "$unit_marker"   # 若 main 重新登记，会重新装回 unit
  # 之后的 maintain 与 timer 一样：不带 --enable-auto-maintain。
  flock() { return 0; }
  check_os_environment() { :; }
  require_root() { :; }
  recover_cert_update() { return 0; }
  ordinary_change_allowed() { return 0; }
  recover_interrupted_change() { return 0; }
  acquire_deploy_lock() { return 0; }
  cert_days_remaining() { echo 1; }
  verify_switched_derper() { return 0; }
  live_cert_sha256_raw() { cat "$tmp/live-fp"; }
  systemctl() {
    case "$1" in
      is-enabled|is-active) return 0 ;;
      restart) cert_fp "$(derper_manual_cert_file)" >"$tmp/live-fp"; return 0 ;;
      *) return 0 ;;
    esac
  }
  local out rc=0
  out=$(main maintain --ip 203.0.113.10 --allow-non-global-ip --region-id 900 2>&1) || rc=$?
  [[ "$rc" -eq 0 ]] || fail "maintain 成功应退出 0：${rc} ${out}"
  new=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  [[ "$new" != "$old" ]] || fail '到期维护应实际换证'
  [[ "$(cat "$tmp/cloud-fp")" == "$new" ]] || fail '云端指纹应同步为新证书'
  [[ "$(read_maintenance_kv result)" == success_replaced ]] || fail "最终结果必须保留 success_replaced：$(read_maintenance_kv result)"
  [[ "$(read_maintenance_kv reason)" == '已按登记策略换证' ]] || fail '最终原因不得被覆盖为重新登记'
  [[ ! -e "$unit_marker" ]] || fail 'maintain 不得重新安装维护 unit'
  [[ "$(read_maintenance_kv intent)" == enabled ]] || fail '用户启用意图必须保留'
}

test_retry_already_updated_cloud() {
  setup_rotation_env
  ENABLE_AUTO_MAINTAIN=1
  prepare_cert_rotation >/dev/null 2>&1 || fail 'prepare 失败'
  local new
  new=$(read_rotation_kv new_sha256)
  policy_auth_state() { echo write_ready; }
  policy_load_acl() {
    POLICY_ACL_BODY="{\"derpMap\":{\"Regions\":{\"900\":{\"RegionID\":900,\"Nodes\":[{\"HostName\":\"203.0.113.10\",\"CertName\":\"sha256-raw:${new}\"}]}}}}"
    POLICY_IF_MATCH='"v2"'
  }
  policy_put_acl() { fail '云端已经采用候选时不得再次提交'; }
  apply_cert_rotation >/dev/null 2>&1 || fail '云端已采用候选的重试应完成本地切换'
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$new" ]] || fail '本地应切换到候选'
}

test_retry_cloud_identity_must_be_unambiguous() {
  setup_rotation_env
  local pin='sha256-raw:abcd' acl
  acl='{"derpMap":{"Regions":{"901":{"RegionID":901,"Nodes":[{"HostName":"203.0.113.10","CertName":"sha256-raw:abcd"}]}}}}'
  if _hujson_invoke current "$acl" "$IP_ADDR" "$REGION_ID" "$pin" '' >/dev/null 2>&1; then fail '其他 Region 不得视为当前候选'; fi
  acl='{"derpMap":{"Regions":{"900":{"RegionID":900,"Nodes":[{"HostName":"203.0.113.10","CertName":"sha256-raw:abcd"},{"HostName":"203.0.113.10","CertName":"sha256-raw:abcd"}]}}}}'
  if _hujson_invoke current "$acl" "$IP_ADDR" "$REGION_ID" "$pin" '' >/dev/null 2>&1; then fail '重复目标不得视为当前候选'; fi
}

test_post_success_readback_failure_then_retry() {
  setup_rotation_env
  ENABLE_AUTO_MAINTAIN=1
  local old new
  old=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  prepare_cert_rotation >/dev/null 2>&1 || fail 'prepare 失败'
  new=$(read_rotation_kv new_sha256)
  printf '%s' "$old" >"$tmp/cloud"
  printf 0 >"$tmp/gets"
  policy_auth_state() { echo write_ready; }
  policy_load_acl() {
    local n fp
    n=$(cat "$tmp/gets"); n=$((n + 1)); printf '%s' "$n" >"$tmp/gets"
    [[ "$n" != 2 ]] || return 1
    fp=$(cat "$tmp/cloud")
    POLICY_ACL_BODY="{\"derpMap\":{\"Regions\":{\"900\":{\"RegionID\":900,\"Nodes\":[{\"HostName\":\"203.0.113.10\",\"CertName\":\"sha256-raw:${fp}\"}]}}}}"
    POLICY_IF_MATCH='"v"'
  }
  policy_validate_acl() { :; }
  policy_put_acl() { printf '%s' "$new" >"$tmp/cloud"; POLICY_HTTP_STATUS=200; }
  if apply_cert_rotation >/dev/null 2>&1; then fail '读回失败时不得切换'; fi
  [[ "$(cat "$tmp/cloud")" == "$new" && "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$old" ]] || fail '应保留云端新指纹和本地旧证书'
  apply_cert_rotation >/dev/null 2>&1 || fail '重试应恢复本地切换'
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$new" ]] || fail '重试后本地指纹错误'
}

test_future_candidate_is_rejected_and_not_reused() {
  setup_rotation_env
  ACCEPT_CERT_ROTATION=1
  prepare_cert_rotation >/dev/null 2>&1 || fail 'prepare 失败'
  make_expired_cert_pair "$tmp/future" "$IP_ADDR" 20400101000000Z 20410101000000Z || fail '无法生成未来证书'
  cp "$tmp/future.crt" "$(cert_rotation_candidate_cert)"
  cp "$tmp/future.key" "$(cert_rotation_candidate_key)"
  local future live
  future=$(cert_fp "$tmp/future.crt")
  live=$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")
  sed "s/^new_sha256=.*/new_sha256=$future/" "$(cert_rotation_record_path)" >"$tmp/record"
  cat "$tmp/record" >"$(cert_rotation_record_path)"
  if apply_cert_rotation >/dev/null 2>&1; then fail '尚未生效的证书不得应用'; fi
  [[ "$(cert_fp "$INSTALL_DIR/certs/$IP_ADDR.crt")" == "$live" ]] || fail '正式证书必须不变'
  prepare_cert_rotation >/dev/null 2>&1 || fail '重新 prepare 失败'
  [[ "$(cert_fp "$(cert_rotation_candidate_cert)")" != "$future" ]] || fail '尚未生效的候选不得复用'
}

test_main_maintain_disable_persists_and_removes_timer() {
  setup_rotation_env
  SYSTEMD_UNIT_DIR="$tmp/systemd"
  mkdir -p "$SYSTEMD_UNIT_DIR"
  stub_timer_systemctl
  ENABLE_AUTO_MAINTAIN=1
  TS_API_CLIENT_ID=id
  TS_API_CLIENT_SECRET=secret
  policy_auth_state() { echo write_ready; }
  apply_auto_maintain_policy >/dev/null 2>&1 || fail '启用失败'
  [[ -f "$SYSTEMD_UNIT_DIR/derper-cert-maintain.timer" ]] || fail '缺少 timer'
  ENABLE_AUTO_MAINTAIN=0
  flock() { return 0; }
  check_os_environment() { :; }
  require_root() { :; }
  recover_cert_update() { :; }
  ordinary_change_allowed() { :; }
  recover_interrupted_change() { :; }
  acquire_deploy_lock() { :; }
  local rc=0
  (main maintain --disable-auto-maintain --ip 203.0.113.10 --allow-non-global-ip --region-id 900) >"$tmp/out" 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]] || fail "停用命令应成功：$(cat "$tmp/out")"
  [[ "$(read_maintenance_kv intent)" == disabled ]] || fail '停用意图未持久化'
  [[ ! -e "$SYSTEMD_UNIT_DIR/derper-cert-maintain.timer" ]] || fail 'timer 未删除'
}

selected=(
  test_retry_already_updated_cloud
  test_retry_cloud_identity_must_be_unambiguous
  test_post_success_readback_failure_then_retry
  test_future_candidate_is_rejected_and_not_reused
  test_main_maintain_disable_persists_and_removes_timer
  test_prepare_does_not_switch_live_cert
  test_yes_does_not_apply_or_resign
  test_cancel_discards_candidate_keeps_live
  test_apply_switches_after_accept_and_keeps_old_recoverable
  test_prepare_conflicts_with_deploy
  test_hujson_patch_preserves_comments_and_other_nodes
  test_hujson_first_register_appends_without_overwrite
  test_policy_read_does_not_imply_write
  test_policy_timeout_reads_back_before_rollback
  test_foreign_cloud_change_stops_auto_rollback
  test_auto_manual_unknown_feedback
  test_maintain_does_not_replace_when_not_due_or_unready
  test_maintain_reuses_same_candidate
  test_maintain_unit_is_independent
  test_enable_persists_ready_for_timer
  test_disable_persists_manual_and_removes_units
  test_revoked_credentials_keep_old_cert
  test_status_includes_maintenance_state
  test_applied_cert_is_not_rolled_back_by_next_command
  test_hujson_keeps_policy_without_derpmap
  test_policy_post_refuses_without_etag
  test_oauth_json_token_reaches_acl_request
  test_cloud_certname_ignores_order_and_distance
  test_apply_rejects_changed_target_identity
  test_next_prepare_issues_fresh_candidate
  test_apply_fails_when_service_does_not_load_cert
  test_bug111_failed_restore_keeps_cloud_fingerprint
  test_bug111_wrong_live_cert_blocks_reverse
  test_bug111_confirmed_restore_allows_reverse
  test_bug111_archive_failure_restores_both_identities
  test_bug111_stopped_service_stays_stopped
  test_bug113_bsd_cert_date_uses_C_locale
  test_bug114_vm_workflow_exports_fixture
  test_local_switch_failure_reverses_cloud_field
  test_local_switch_failure_foreign_change_blocks_reverse
  test_timer_ready_only_after_enable
  test_timer_keeps_node_and_schedule
  test_transient_unknown_keeps_auto_intent
  test_hujson_regions_trailing_comma
  test_validate_honors_http_status_and_hujson
  test_maintain_units_refuse_symlink
  test_maintain_config_keeps_private_ip_permission
  test_cancel_without_ip_discards_candidate_quietly
  test_maintain_does_not_repeat_deploy_feedback
  test_purge_all_removes_maintain_program
  test_bug107_apply_refuses_live_key_symlink_before_copy
  test_bug108_failed_switch_restarts_previous_service
  test_bug102_disable_blocks_historical_auto_apply
  test_bug103_idempotent_deploy_honors_maintain_switch
  test_bug104_failed_timer_install_is_not_reported_ready
  test_bug104_timer_failures_survive_fresh_commands
  test_bug104_maintain_retries_preserve_schedule_failure
  test_bug104_legacy_failed_schedule_is_not_ready
  test_bug107_apply_refuses_install_root_symlink
  test_bug101_missing_tailnet_has_no_write_authorization
  test_bug101_missing_tailnet_cannot_enable_timer
  test_bug101_tailnet_from_config_or_credentials_can_enable
  test_bug106_config_lead_days_are_explicit
  test_bug106_config_lead_defaults_and_cli_precedence
  test_bug105_expired_certificate_is_due_for_maintain
  test_bug106_short_cert_days_keep_default_lead_in_range
  test_bug118_cert_days_change_regenerates_candidate
  test_bug118_apply_refuses_expired_candidate
  test_bug118_apply_rejects_changed_cert_days
  test_bug119_unknown_expiry_is_not_idle
  test_bug119_cert_rotation_is_due_tristate
  test_bug120_duplicate_hostname_requires_coordination
  test_bug120_region_mismatch_requires_coordination
  test_bug120_missing_certname_requires_coordination
  test_bug120_unparsable_policy_requires_coordination
  test_bug120_trailing_garbage_requires_coordination
  test_bug120_multiple_roots_require_coordination
  test_bug120_confirmed_absent_needs_no_compensation
  test_bug121_uninstall_propagates_maintain_unit_removal_failure
  test_bug121_uninstall_checks_enabled_and_running_state
  test_bug121_disable_failure_is_not_recorded_as_clean_manual
  test_bug121_daemon_reload_failure_propagates
  test_bug121_uninstall_daemon_reload_failure_is_not_success
  test_bug121_disable_daemon_reload_failure_marks_failed
  test_bug116_maintain_success_state_survives_main
)
[[ $# == 0 ]] || selected=("$@")
failed=0
for t in "${selected[@]}"; do
  if (
    DERPER_TEST_MODE=1 source "$SCRIPT"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    "$t"
  ); then echo "ok - $t"; else
    echo "not ok - $t"
    failed=$((failed+1))
  fi
done
[[ $failed == 0 ]]
