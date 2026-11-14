#!/usr/bin/env bash
# 迭代一真实 Go/受限源码路径验收；只在明确标记的一次性 Linux VM 中运行。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/deploy_derper_ip_selfsigned.sh"
PROXY_FIXTURE="$ROOT_DIR/tests/fixtures/iter1_connect_proxy.py"

if [[ "${DERPER_ITER1_VM:-0}" != 1 || ! -f /root/DERPER_DISPOSABLE_ITER1_VM ]] \
  || [[ "$(id -u)" -ne 0 || "$(uname -s)" != Linux ]]; then
  echo '环境不符：需要 root + Linux + DERPER_ITER1_VM=1 + /root/DERPER_DISPOSABLE_ITER1_VM' >&2
  exit 2
fi
for tool in go git curl openssl tar python3 sha256sum systemd-detect-virt; do
  command -v "$tool" >/dev/null 2>&1 || { echo "环境不符：缺少 $tool" >&2; exit 2; }
done
artifacts="${DERPER_TEST_ARTIFACTS:-/root/derper-iter1-evidence/$(date -u +%Y%m%dT%H%M%SZ)-$$}"
mkdir -p "$artifacts"
chmod 700 "$artifacts"
virt=$(systemd-detect-virt 2>/dev/null || true)
printf 'virtualization=%s\n' "${virt:-unknown}" >"$artifacts/environment.txt"
if ! systemd-detect-virt --vm >/dev/null 2>&1 || systemd-detect-virt --container >/dev/null 2>&1; then
  echo "环境不符：检测到 ${virt:-unknown}，必须是真实 VM；普通容器/WSL不得替代" >&2
  exit 2
fi

DERPER_TEST_MODE=1 source "$SCRIPT"
go_toolchain_meets_min || { echo '环境不符：基础 Go 必须 >= 1.21；不在验收中顺带安装基础工具链' >&2; exit 2; }
base_go=$(parse_go_version "$(GOTOOLCHAIN=local go version)")
requested=3b273a64cef3fe6d3d495afae7bb6a553344ce64
expected_source=c54807352ae196919497b3f8fddc3cedf88368b9
expected_module=v1.104.6
{
  printf 'utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat /etc/os-release
  uname -a
  printf 'pid1=%s\nvirtualization=%s\n' "$(cat /proc/1/comm)" "$virt"
  GOTOOLCHAIN=local go version
  GOTOOLCHAIN=local go env GOPROXY GOSUMDB GOTOOLCHAIN
  sha256sum "$SCRIPT" "$ROOT_DIR/tests/test_iter1_vm.sh" "$PROXY_FIXTURE"
} >>"$artifacts/environment.txt" 2>&1

tmp=$(mktemp -d /var/tmp/derper-iter1-vm.XXXXXXXXXX)
runtime_pid=''
proxy_pid=''
cleanup() {
  local rc=$? runtime_stopped=not_present proxy_stopped=not_present tmp_removed=not_present
  trap - EXIT
  if [[ -n "$runtime_pid" ]]; then
    if kill -0 "$runtime_pid" 2>/dev/null; then
      kill "$runtime_pid" 2>/dev/null || true
      wait "$runtime_pid" 2>/dev/null || true
    fi
    if kill -0 "$runtime_pid" 2>/dev/null; then runtime_stopped=no; else runtime_stopped=yes; fi
  fi
  if [[ -n "$proxy_pid" ]]; then
    if kill -0 "$proxy_pid" 2>/dev/null; then
      kill "$proxy_pid" 2>/dev/null || true
      wait "$proxy_pid" 2>/dev/null || true
    fi
    if kill -0 "$proxy_pid" 2>/dev/null; then proxy_stopped=no; else proxy_stopped=yes; fi
  fi
  if [[ -n "$tmp" ]]; then
    chmod -R u+w "$tmp" 2>/dev/null || true
    rm -rf "$tmp" || true
    if [[ -e "$tmp" ]]; then tmp_removed=no; else tmp_removed=yes; fi
  fi
  {
    printf 'suite_exit=%s\n' "$rc"
    printf 'runtime_fixture_stopped=%s\nproxy_stopped=%s\ntmp_removed=%s\n' \
      "$runtime_stopped" "$proxy_stopped" "$tmp_removed"
    printf 'tmp_path=%s\nartifacts=%s\n' "$tmp" "$artifacts"
  } >"$artifacts/cleanup.txt"
  if [[ "$runtime_stopped" == no || "$proxy_stopped" == no || "$tmp_removed" == no ]]; then
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

_tmpdir="$tmp/work"
DERPER_GO_BUILD_CACHE_DIR="$tmp/cache"
DEPLOY_STATE_DIR="$tmp/state"
INSTALL_DIR="$tmp/install"
NODE_STATE_DIR="$INSTALL_DIR/state"
SERVICE_PATH="$tmp/derper.service"
BIN_PATH="$tmp/bin/derper"
mkdir -p "$_tmpdir" "$(dirname "$BIN_PATH")" "$NODE_STATE_DIR" "$INSTALL_DIR/certs"
VERIFY_CLIENTS_MODE=off
LOCAL_BINARY=''
GOTOOLCHAIN_ARG=auto
GOPROXY_ARG="${DERPER_TEST_GOPROXY:-https://goproxy.cn,direct}"
GOSUMDB_ARG="${DERPER_TEST_GOSUMDB:-sum.golang.google.cn}"
printf 'test_goproxy=%s\ntest_gosumdb=%s\ngotoolchain=auto\nfresh_go_cache=%s\n' \
  "$GOPROXY_ARG" "$GOSUMDB_ARG" "$DERPER_GO_BUILD_CACHE_DIR" >>"$artifacts/environment.txt"

# 若 Go 错误进入 GitHub direct，这个仅属于测试进程的映射会立即失败；成功必须来自模块代理。
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0='url.https://invalid.invalid/tailscale/tailscale.insteadOf'
export GIT_CONFIG_VALUE_0='https://github.com/tailscale/tailscale'

python3 "$PROXY_FIXTURE" --port-file "$tmp/proxy.port" --log "$artifacts/network-proxy.log" \
  >"$artifacts/proxy-stderr.log" 2>&1 &
proxy_pid=$!
for ((i=0; i<100; i++)); do [[ ! -s "$tmp/proxy.port" ]] || break; sleep 0.1; done
[[ -s "$tmp/proxy.port" ]] || { echo '本地网络故障注入代理未启动' >&2; exit 1; }
proxy_port=$(cat "$tmp/proxy.port")
export http_proxy="http://127.0.0.1:$proxy_port"
export https_proxy="$http_proxy"
export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$http_proxy" NO_PROXY='' no_proxy=''
printf 'scoped_connect_proxy=127.0.0.1:%s\ngo_dev_policy=blocked\n' "$proxy_port" >>"$artifacts/environment.txt"
{
  rc=0
  curl --connect-timeout 5 --max-time 10 -fsS https://go.dev/dl/ >"$artifacts/go-dev-response.txt" 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || { echo 'go.dev 故障注入未生效' >&2; exit 1; }
  grep -q '^blocked go.dev:443$' "$artifacts/network-proxy.log" || { echo '缺少go.dev实际阻断证据' >&2; exit 1; }
  echo "ok - go.dev 已在测试进程网络路径阻断（curl_exit=$rc）"
} > >(tee "$artifacts/00-network.log") 2>&1

{
  DERPER_VERSION="$requested"
  reset_derper_version_model
  install_derper
  [[ "$DERPER_VERSION" == "$expected_module" && "$DERPER_REQUESTED_VERSION" == "$requested" ]] \
    || { echo '请求值或规范模块版本不一致' >&2; exit 1; }
  [[ "$DERPER_ORIGINAL_REVISION" == "$requested" && "$DERPER_SOURCE_COMMIT" == "$expected_source" ]] \
    || { echo '原始 revision 与最终源 commit 未分别保留' >&2; exit 1; }
  [[ "$DERPER_MODULE_GO_VERSION" == 1.27.3 ]] \
    || { echo "目标 Go 要求不符：${DERPER_MODULE_GO_VERSION:-未知}" >&2; exit 1; }
  if [[ "$base_go" == "$DERPER_MODULE_GO_VERSION" ]] \
    || [[ "$(printf '%s\n' "$base_go" "$DERPER_MODULE_GO_VERSION" | sort -V | head -n1)" != "$base_go" ]]; then
    echo "环境不符：基础 Go $base_go 必须低于目标要求 $DERPER_MODULE_GO_VERSION，才能验证真实工具链获取" >&2
    exit 2
  fi
  [[ "$DERPER_BUILD_TOOLCHAIN_SOURCE" == go_install_switch_message \
    && "$DERPER_BUILD_TOOLCHAIN" != "go$base_go" ]] \
    || { echo '未观察到目标工具链切换；不能声称验证了工具链下载' >&2; exit 1; }
  grep -q '^allowed ' "$artifacts/network-proxy.log" || { echo '模块代理未经过故障注入通道' >&2; exit 1; }
  # 先完整落盘再解析：管道里 awk 提前 exit 会让 go 写后续行时 SIGPIPE，在 pipefail 下误杀整个验收。
  GOTOOLCHAIN=local go version -m "$BIN_PATH" >"$artifacts/binary-build-info.txt"
  actual_module=$(awk '/^[[:space:]]*mod[[:space:]]+tailscale\.com([[:space:]]|$)/ && !found {print $3; found=1}' \
    "$artifacts/binary-build-info.txt")
  [[ "$actual_module" == "$expected_module" ]] || { echo "二进制模块版本不符：$actual_module" >&2; exit 1; }
  printf 'requested=%s\nmodule=%s\noriginal_revision=%s\nsource_commit=%s\nbase_go=%s\nmodule_go=%s\nbuild_toolchain=%s\ntoolchain_evidence=%s\n' \
    "$requested" "$actual_module" "$DERPER_ORIGINAL_REVISION" "$DERPER_SOURCE_COMMIT" \
    "$base_go" "$DERPER_MODULE_GO_VERSION" "$DERPER_BUILD_TOOLCHAIN" "$DERPER_BUILD_TOOLCHAIN_SOURCE" \
    >"$artifacts/resolved-model.txt"
  echo "ok - GitHub/go.dev受阻时，真实模块与工具链经代理完成构建：$DERPER_BUILD_TOOLCHAIN"
} > >(tee "$artifacts/01-build.log") 2>&1

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=127.0.0.1' \
  -addext 'subjectAltName=IP:127.0.0.1' \
  -keyout "$INSTALL_DIR/certs/127.0.0.1.key" -out "$INSTALL_DIR/certs/127.0.0.1.crt" \
  >"$artifacts/cert-fixture.log" 2>&1
# 显式隔离配置：derper 在 root 下默认读写 /var/lib/derper/derper.key；-c 让其在临时目录生成有效 PrivateKey 配置。
printf '[Service]\nExecStart=%s -c %s -hostname 127.0.0.1 -certmode manual -certdir %s -http-port -1 -a 127.0.0.1:0 -stun -stun-port 0\n' \
  "$BIN_PATH" "$NODE_STATE_DIR/derper.json" "$INSTALL_DIR/certs" >"$SERVICE_PATH"
"$BIN_PATH" -c "$NODE_STATE_DIR/derper.json" -hostname 127.0.0.1 -certmode manual -certdir "$INSTALL_DIR/certs" \
  -http-port -1 -a 127.0.0.1:0 -stun -stun-port 0 >"$artifacts/runtime-fixture.log" 2>&1 &
runtime_pid=$!
for ((i=0; i<100; i++)); do
  grep -q '"PrivateKey"' "$NODE_STATE_DIR/derper.json" 2>/dev/null && break
  kill -0 "$runtime_pid" 2>/dev/null || break
  sleep 0.1
done
sleep 2
kill -0 "$runtime_pid" 2>/dev/null || { echo '真实 derper 运行夹具未能启动' >&2; exit 1; }
grep -q '"PrivateKey"' "$NODE_STATE_DIR/derper.json" 2>/dev/null \
  || { echo '隔离配置未生成有效 PrivateKey，不能作为配置保全基线' >&2; exit 1; }

snapshot_fixture() {
  printf 'binary_sha256=%s\n' "$(sha256_hex <"$BIN_PATH")"
  printf 'cert_sha256=%s\n' "$(sha256_hex <"$INSTALL_DIR/certs/127.0.0.1.crt")"
  printf 'key_sha256=%s\n' "$(sha256_hex <"$INSTALL_DIR/certs/127.0.0.1.key")"
  printf 'unit_sha256=%s\n' "$(sha256_hex <"$SERVICE_PATH")"
  printf 'config_sha256=%s\n' "$(sha256_hex <"$NODE_STATE_DIR/derper.json")"
  if kill -0 "$runtime_pid" 2>/dev/null; then printf 'runtime_state=active\n'; else printf 'runtime_state=inactive\n'; fi
  printf 'runtime_pid=%s\n' "$runtime_pid"
  printf 'runtime_exe=%s\n' "$(readlink "/proc/$runtime_pid/exe" 2>/dev/null || true)"
  printf 'runtime_start_ticks=%s\n' "$(awk '{print $22}' "/proc/$runtime_pid/stat" 2>/dev/null || true)"
}
fixture_before=$(snapshot_fixture)
snapshot_fixture >"$artifacts/fixture-before.txt"

{
  DERPER_VERSION=abcdef1234567890abcdef1234567890abcdef12
  reset_derper_version_model
  # 必须用 `|`：逗号只在 404/410 时才回退下一项，代理连接失败不会触发 direct；`|` 才覆盖任意错误回退。
  GOPROXY_ARG='https://invalid.invalid|direct'
  GOSUMDB_ARG="${DERPER_TEST_GOSUMDB:-sum.golang.google.cn}"
  # 清除场景 01 遗留的 Go 错误日志，避免把成功构建的旧日志误存为本场景失败证据。
  rm -f "$_tmpdir/derper_module_query.err" "$_tmpdir/derper_install.err"
  proxy_lines_before=$(wc -l <"$artifacts/network-proxy.log")
  if (install_derper) >"$artifacts/02-resolution-install.out" 2>&1; then
    cat "$artifacts/02-resolution-install.out"
    echo '不可解析目标在代理和 direct 均失败时不得成功' >&2
    exit 1
  fi
  cat "$artifacts/02-resolution-install.out"
  # 断言失败原因：Go 已回退 direct 且 Git 被阻断，而不是其他偶发错误。
  grep -q 'Go 目标模块解析/构建失败' "$artifacts/02-resolution-install.out" \
    || { echo '场景02缺少目标模块解析失败的诊断' >&2; exit 1; }
  grep -q '回退 direct' "$artifacts/02-resolution-install.out" \
    || { echo '场景02未观察到 GOPROXY 回退 direct 后 Git 失败的诊断' >&2; exit 1; }
  # 不用 tail|grep -q 管道：grep 提前退出在 pipefail 下可能因 SIGPIPE 误判失败。
  tail -n +"$((proxy_lines_before + 1))" "$artifacts/network-proxy.log" >"$artifacts/02-proxy-delta.log"
  grep -q '^connect_failed invalid\.invalid:443$' "$artifacts/02-proxy-delta.log" \
    || { echo '场景02代理日志缺少 invalid.invalid 实际失败证据' >&2; exit 1; }
  fixture_after=$(snapshot_fixture)
  [[ "$fixture_before" == "$fixture_after" ]] || { echo '解析失败改变了二进制、证书、unit、配置或运行状态' >&2; exit 1; }
  snapshot_fixture >"$artifacts/fixture-after-resolution-failure.txt"
  [[ ! -f "$_tmpdir/derper_module_query.err" ]] || cp "$_tmpdir/derper_module_query.err" "$artifacts/02-resolution-query.err"
  [[ ! -f "$_tmpdir/derper_install.err" ]] || cp "$_tmpdir/derper_install.err" "$artifacts/02-resolution-install.err"
  echo 'ok - 代理与 direct 均失败时，既有部署文件和真实 derper 进程保持'
} > >(tee "$artifacts/02-resolution-failure.log") 2>&1

{
  DERPER_VERSION=v1.104.5
  reset_derper_version_model
  GOPROXY_ARG="${DERPER_TEST_GOPROXY:-https://goproxy.cn,direct}"
  # 保留合法内置 verifier 名（sum.golang.org），仅把服务 URL 指向不可解析主机；裸 sum.golang.invalid 会先触发配置解析错误。
  GOSUMDB_ARG='sum.golang.org https://sum.golang.invalid'
  rm -f "$_tmpdir/derper_module_query.err" "$_tmpdir/derper_install.err"
  proxy_lines_before=$(wc -l <"$artifacts/network-proxy.log")
  if (install_derper) >"$artifacts/03-gosumdb-install.out" 2>&1; then
    cat "$artifacts/03-gosumdb-install.out"
    echo '独立 GOSUMDB 故障不得成功' >&2
    exit 1
  fi
  cat "$artifacts/03-gosumdb-install.out"
  # 断言失败确由校验数据库不可用引起，而非其他偶发错误。
  grep -q 'sum\.golang\.invalid' "$artifacts/03-gosumdb-install.out" \
    || { echo '场景03失败输出缺少 sum.golang.invalid 原因' >&2; exit 1; }
  # 排除配置解析错误：必须是合法配置下对校验库的真实请求失败。
  ! grep -qiE 'malformed|invalid GOSUMDB|bad .*GOSUMDB' "$artifacts/03-gosumdb-install.out" \
    || { echo '场景03疑似 GOSUMDB 配置解析错误，而非校验库不可达' >&2; exit 1; }
  tail -n +"$((proxy_lines_before + 1))" "$artifacts/network-proxy.log" >"$artifacts/03-proxy-delta.log"
  grep -q '^connect_failed sum\.golang\.invalid:443$' "$artifacts/03-proxy-delta.log" \
    || { echo '场景03代理日志缺少 sum.golang.invalid 实际请求失败证据' >&2; exit 1; }
  fixture_after=$(snapshot_fixture)
  [[ "$fixture_before" == "$fixture_after" ]] || { echo 'GOSUMDB失败改变了二进制、证书、unit、配置或运行状态' >&2; exit 1; }
  snapshot_fixture >"$artifacts/fixture-after-gosumdb-failure.txt"
  [[ ! -f "$_tmpdir/derper_module_query.err" ]] || cp "$_tmpdir/derper_module_query.err" "$artifacts/03-gosumdb-query.err"
  [[ ! -f "$_tmpdir/derper_install.err" ]] || cp "$_tmpdir/derper_install.err" "$artifacts/03-gosumdb-install.err"
  echo 'ok - 独立 GOSUMDB 故障非零退出，既有部署文件和真实 derper 进程保持'
} > >(tee "$artifacts/03-gosumdb-failure.log") 2>&1

echo "通过范围：真实Go受限构建、工具链获取、目标解析/GOSUMDB失败保全；证据目录=$artifacts"
echo '不是 systemd、H3 或生产部署验收；运行夹具与临时缓存由EXIT清理并记录结果。'
