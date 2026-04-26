# DERP 部署脚本缺陷整改分析报告

> **审查对象**：`scripts/deploy_derper_ip_selfsigned.sh`（2212 行）  
> **审查日期**：2026-04-26  
> **审查方式**：两轮独立审查交叉比对、合并去重  

---

## 一、问题汇总

共识别 **22 项** 独立缺陷，按严重程度分布如下：

| 严重程度 | 数量 | 占比 |
|----------|------|------|
| 🔴 高危 | 5 | 23% |
| 🟡 中危 | 10 | 45% |
| 🟢 低危 | 7 | 32% |

### 完整清单

| ID | 严重程度 | 类型 | 行号 | 缺陷标题 | 来源 |
|----|----------|------|------|----------|------|
| D-01 | 🔴 高 | 安全 | 679-691, 785 | `/tmp` 可预测路径 — 符号链接攻击（错误日志） | 两轮均发现 |
| D-02 | 🔴 高 | 安全 | 742-743 | `/tmp` 可预测路径 — 符号链接攻击（Go tarball） | 两轮均发现 |
| D-03 | 🔴 高 | 安全 | 755-758 | SHA256 完整性校验可被静默跳过 | 第一轮 |
| D-04 | 🔴 高 | Bug | 1068-1075, 1319-1320 | `stun_flag` / `listen_flag` 空格拼接导致参数合并 | 第二轮 |
| D-05 | 🔴 高 | 安全 | 1124-1125 | 重启 tailscaled 可能中断 Tailscale SSH 连接 | 第二轮 |
| D-06 | 🟡 中 | 安全 | 41 | `SUDO_USER` 环境变量可被伪造 | 第一轮 |
| D-07 | 🟡 中 | 安全 | 1618-1637 | `REGION_CODE` / `REGION_NAME` JSON 注入 | 第二轮 |
| D-08 | 🟡 中 | Bug | 508-515 | `ver_ge()` 回退路径使用字典序比较 | 两轮均发现 |
| D-09 | 🟡 中 | Bug | 770 | `rm -rf /usr/local/go` 无条件删除已有 Go 环境 | 第一轮 |
| D-10 | 🟡 中 | Bug | 1126-1130 | tailscaled 重启后 `sleep 1` 竞态条件 | 第一轮 |
| D-11 | 🟡 中 | 安全 | 785 | `go install ...@latest` 非确定性构建 | 第二轮 |
| D-12 | 🟡 中 | 健壮性 | 467-484 | 未验证 IP 是否为公网地址（RFC 1918 检查缺失） | 第一轮 |
| D-13 | 🟡 中 | 健壮性 | 1802-1811 | `write_prometheus_metrics` 错误信息与实际失败原因不匹配 | 第二轮 |
| D-14 | 🟡 中 | 健壮性 | 743-776 | Go tarball 安装成功后未清理（约 140 MB 残留） | 第二轮 |
| D-15 | 🟡 中 | 文档 | — | 仓库缺失 `LICENSE`、`tests/`、`docs/ACCOUNT_AND_SECURITY.md` | 第一轮 |
| D-16 | 🟢 低 | Bug | 1557 | `runtime_checks` 端口 grep 缺少词边界限制 | 第一轮 |
| D-17 | 🟢 低 | Bug | 660-668 | 多包管理器并存时包名重复添加 | 第一轮 |
| D-18 | 🟢 低 | 健壮性 | 901 | `derper.json` 权限 644 全局可读 | 第二轮 |
| D-19 | 🟢 低 | 健壮性 | 1457 | `sed -i` 无备份直接修改 systemd unit 文件 | 第二轮 |
| D-20 | 🟢 低 | 健壮性 | 1415-1446 | systemd 单元缺少 `StartLimitBurst` / `StartLimitIntervalSec` | 第二轮 |
| D-21 | 🟢 低 | 兼容性 | 323-326 | `--security-level` 输入延迟验证 | 第一轮 |
| D-22 | 🟢 低 | 兼容性 | 1563 | `timeout` 命令在最小化环境可能缺失 | 第二轮 |

> **说明**：第一轮审查另发现的 `openssl dgst` 输出格式差异（L947）、端口重复未检测（L453）、BSD date 兼容（L646）、Go 版本硬编码（L28）、`grep \b` BSD 兼容性（L581）等问题，经评估为极低概率或已被脚本自身的 Linux-only 约束覆盖，不单独列入整改项。其中 Go 版本问题已并入 D-11（`@latest` 非确定性构建）统一处理；wizard 写入不安全目录问题影响面有限，并入 D-01 统一治理 `/tmp` 相关风险。

---

## 二、缺陷详细分析与解决方案

### D-01：`/tmp` 可预测路径 — 符号链接攻击（错误日志）

**CWE 分类**：CWE-377（不安全的临时文件）  
**影响行**：679, 681, 683, 687, 691, 785  
**风险**：脚本以 root 身份运行，向 `/tmp/apt_update.err` 等可预测路径重定向输出。本地攻击者可提前创建指向 `/etc/shadow` 等敏感文件的符号链接，导致 root 进程覆盖关键系统文件。

**当前代码**：
```bash
DEBIAN_FRONTEND=noninteractive apt update -y 2>/tmp/apt_update.err
```

**修复方案**：
```bash
_tmpdir=$(mktemp -d /tmp/derper-deploy.XXXXXXXXXX)
trap 'rm -rf "$_tmpdir"' EXIT

DEBIAN_FRONTEND=noninteractive apt update -y 2>"${_tmpdir}/apt_update.err"
```

**工作分解**：
- [ ] 在脚本初始化区（`main` 函数入口处）创建安全临时目录
- [ ] 注册 `trap ... EXIT` 清理钩子
- [ ] 替换所有 6 处 `/tmp/xxx.err` 硬编码路径
- [ ] wizard 生成的 `derper_deploy_cmd.sh` 改写到 `$_tmpdir` 并提示用户路径

---

### D-02：`/tmp` 可预测路径 — 符号链接攻击（Go tarball）

**CWE 分类**：CWE-377  
**影响行**：742-743  
**风险**：Go tarball 下载到 `/tmp/go1.22.6.linux-amd64.tar.gz`，路径完全可预测。虽有 SHA256 校验，但若 D-03 的校验绕过也成立，则攻击链完整。

**修复方案**：
```bash
tarball=$(mktemp "${_tmpdir}/go-XXXXXXXXXX.tar.gz")
curl -fsSL "$url" -o "$tarball"
```

**工作分解**：
- [ ] 将 tarball 下载路径改为 D-01 创建的安全临时目录内
- [ ] 安装成功后立即 `rm -f "$tarball"`（同时修复 D-14）

---

### D-03：SHA256 完整性校验可被静默跳过

**CWE 分类**：CWE-354（校验缺失）  
**影响行**：755-758  
**风险**：当 `sha256sum` 和 `shasum` 都不存在时，脚本将期望哈希赋给实际值，等于完全跳过校验。攻击者可在精简系统上注入恶意 Go 二进制。

**当前代码**：
```bash
echo "[警告] 未找到 sha256sum/shasum，跳过完整性校验（不推荐）" >&2
sha256_actual="$sha256_expected"  # 跳过校验
```

**修复方案**：使用 `openssl dgst -sha256`（脚本已依赖 openssl）作为兜底，若三者都不存在则 **拒绝安装**：
```bash
if command -v sha256sum >/dev/null 2>&1; then
  sha256_actual=$(sha256sum "$tarball" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  sha256_actual=$(shasum -a 256 "$tarball" | awk '{print $1}')
elif command -v openssl >/dev/null 2>&1; then
  sha256_actual=$(openssl dgst -sha256 "$tarball" | awk '{print $NF}')
else
  echo "[错误] 无法校验 Go tarball 完整性：sha256sum/shasum/openssl 均不可用，已中止安装。" >&2
  rm -f "$tarball"
  exit 1
fi
```

**工作分解**：
- [ ] 添加 `openssl dgst -sha256` 作为第三优先级校验工具
- [ ] 所有工具都缺失时改为 `exit 1`（不允许跳过）
- [ ] 使用 `awk '{print $NF}'` 兼容不同 openssl 输出格式

---

### D-04：`stun_flag` / `listen_flag` 空格拼接导致参数合并

**影响行**：1068-1075, 1077-1085, 1319-1320  
**风险**：`stun_flag="-stun -stun-port 3478"` 作为单个字符串被 `exec_args+=("${stun_flag}")` 添加为一个数组元素。当前写入 systemd `ExecStart` 时依赖 systemd 的空格分词碰巧能工作，但如果代码被改为直接 `exec` 调用，`-stun -stun-port 3478` 会被视为单个参数，导致 derper 启动失败。

**修复方案**：拆分为独立数组元素：
```bash
# 替换 stun_flag 为数组
local stun_args=()
if derper_supports_stun_port; then
  stun_args=("-stun" "-stun-port" "${STUN_PORT}")
else
  stun_args=("-stun")
fi

# 替换 listen_flag 为数组
local listen_args=()
if derper_supports_listen_a; then
  listen_args=("-a" ":${DERP_PORT}")
elif derper_supports_https_port; then
  listen_args=("-https-port" "${DERP_PORT}")
else
  listen_args=("-a" ":${DERP_PORT}")
fi

# 构建 exec_args 时展开数组
exec_args+=("${listen_args[@]}")
exec_args+=("${stun_args[@]}")
```

**工作分解**：
- [ ] 将 `stun_flag` 字符串变量重构为 `stun_args` 数组
- [ ] 将 `listen_flag` 字符串变量重构为 `listen_args` 数组
- [ ] 更新 `exec_args` 的构建逻辑，使用 `"${arr[@]}"` 展开
- [ ] 同步更新非 systemd 环境的手动命令输出（L1260-1274）

---

### D-05：重启 tailscaled 可能中断 Tailscale SSH 连接

**影响行**：1124-1125  
**风险**：如果用户正通过 Tailscale SSH 连接到服务器执行部署脚本，`systemctl restart tailscaled` 会立即断开连接，导致脚本中断、服务器不可达。

**修复方案**：
```bash
# 检测当前 SSH 连接是否经由 Tailscale
local via_tailscale=0
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  local ssh_src_ip
  ssh_src_ip=$(echo "$SSH_CONNECTION" | awk '{print $1}')
  if [[ "$ssh_src_ip" == 100.* ]] || [[ "$ssh_src_ip" == fd7a:115c:a1e0:* ]]; then
    via_tailscale=1
  fi
fi

if [[ "$via_tailscale" -eq 1 ]]; then
  echo "[警告] 检测到当前 SSH 连接可能经由 Tailscale（源 IP: ${ssh_src_ip}）。" >&2
  echo "  重启 tailscaled 将断开此连接，可能导致脚本中断和服务器不可达。" >&2
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    echo "[跳过] 非交互模式下跳过 tailscaled 重启，将使用备选方案配置 socket 权限。" >&2
  else
    read -p "  是否确认重启 tailscaled？(yes/no): " _confirm
    [[ "$_confirm" == "yes" ]] || { echo "[跳过] 已取消重启，将使用备选方案。"; }
  fi
fi
```

**工作分解**：
- [ ] 添加 Tailscale SSH 连接检测函数
- [ ] 在 `systemctl restart tailscaled` 前调用检测
- [ ] 非交互模式下自动跳过，改用 ACL / 其他方案
- [ ] 交互模式下要求用户显式确认

---

### D-06：`SUDO_USER` 环境变量可被伪造

**影响行**：41  
**风险**：攻击者可通过 `SUDO_USER=malicious_value sudo bash script.sh` 注入任意用户名。虽然后续 `id` 命令会过滤无效用户名，但包含特殊字符的用户名可能在 `chown`、`useradd` 等命令中产生意外行为。

**修复方案**：
```bash
# 验证 SUDO_USER 是否为合法的系统用户名
if [[ -n "${SUDO_USER:-}" ]]; then
  if ! [[ "${SUDO_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "[警告] SUDO_USER 包含非法字符（${SUDO_USER}），已忽略，使用 \$USER。" >&2
    RUN_USER="$USER"
  else
    RUN_USER="${SUDO_USER}"
  fi
else
  RUN_USER="$USER"
fi
```

**工作分解**：
- [ ] 添加 `SUDO_USER` 格式校验（POSIX 用户名规则）
- [ ] 校验失败时回退到 `$USER`

---

### D-07：`REGION_CODE` / `REGION_NAME` JSON 注入

**影响行**：1618-1637  
**风险**：用户传入 `--region-name 'My "Special" DERP'` 时，生成的 JSON 中双引号未转义，导致 JSON 语法错误。粘贴到 Tailscale ACL 后台会导致配置失效。

**修复方案**：在 `parse_args` 或 `validate_settings` 中添加输入校验：
```bash
# 校验 Region 字段：仅允许字母、数字、空格、连字符、下划线
if [[ ! "${REGION_CODE}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "[错误] --region-code 仅允许字母、数字、连字符、下划线：${REGION_CODE}" >&2
  return 1
fi
if [[ ! "${REGION_NAME}" =~ ^[a-zA-Z0-9\ _-]+$ ]]; then
  echo "[错误] --region-name 仅允许字母、数字、空格、连字符、下划线：${REGION_NAME}" >&2
  return 1
fi
```

**工作分解**：
- [ ] 在 `validate_settings` 中添加 `REGION_CODE` 和 `REGION_NAME` 白名单校验
- [ ] 在 `REGION_ID` 校验中确认为正整数

---

### D-08：`ver_ge()` 回退路径使用字典序比较

**影响行**：508-515  
**风险**：`[[ "1.10.0" > "1.9.0" ]]` 在 bash 中做字典序比较，返回 false（字符 `1` < `9`），但语义上 1.10.0 > 1.9.0。在无 `sort -V` 的系统上导致版本判断完全错误。

**修复方案**：实现纯 bash 的逐段数字比较：
```bash
ver_ge() {
  if sort -V </dev/null &>/dev/null; then
    local a="$1" b="$2"
    [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" == "$a" ]]
  else
    # 纯 bash 语义化版本比较
    local IFS='.'
    local -a va=($1) vb=($2)
    local i max=$(( ${#va[@]} > ${#vb[@]} ? ${#va[@]} : ${#vb[@]} ))
    for ((i=0; i<max; i++)); do
      local na=$((10#${va[i]:-0}))
      local nb=$((10#${vb[i]:-0}))
      if ((na > nb)); then return 0; fi
      if ((na < nb)); then return 1; fi
    done
    return 0  # 相等
  fi
}
```

**工作分解**：
- [ ] 替换回退路径为逐段数字比较实现
- [ ] 添加测试用例覆盖边界情况（1.9 vs 1.10、相等、空段）

---

### D-09：`rm -rf /usr/local/go` 无条件删除已有 Go 环境

**影响行**：770  
**风险**：用户手动安装的 Go 环境（含自定义包、GOPATH 配置）被无条件删除。无备份、无确认。

**修复方案**：
```bash
if [[ -d /usr/local/go ]]; then
  local existing_go_ver
  existing_go_ver=$(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}' || echo "未知")
  echo "[警告] 将替换已有 Go 安装：$existing_go_ver → Go ${GO_VERSION}" >&2
  if [[ "${NON_INTERACTIVE}" -ne 1 ]]; then
    read -p "  确认删除 /usr/local/go 并重新安装？(y/n): " _go_confirm
    [[ "$_go_confirm" == "y" ]] || { echo "[中止] 请手动安装 Go 后重试。" >&2; exit 1; }
  fi
  rm -rf /usr/local/go
fi
```

**工作分解**：
- [ ] 删除前检测已有 Go 版本并提示用户
- [ ] 非交互模式下显示警告但继续（行为不变，增加日志）
- [ ] 交互模式下要求确认

---

### D-10：tailscaled 重启后 `sleep 1` 竞态条件

**影响行**：1126-1130  
**风险**：重启 tailscaled 后仅 `sleep 1` 就读取 socket 属性。在高负载或慢速磁盘系统上，tailscaled 可能尚未创建新 socket，导致权限检测基于旧状态或失败。

**修复方案**：使用轮询等待替代固定 sleep：
```bash
local wait_count=0
while [[ ! -S "$socket_path" ]] && ((wait_count < 10)); do
  sleep 1
  ((wait_count++))
done
if [[ ! -S "$socket_path" ]]; then
  echo "[警告] tailscaled 重启后 socket 未在 10 秒内恢复" >&2
fi
```

**工作分解**：
- [ ] 将 `sleep 1` 替换为轮询等待循环（最多 10 秒）
- [ ] 超时后输出明确警告

---

### D-11：`go install ...@latest` 非确定性构建

**影响行**：785  
**风险**：不同时间运行的脚本安装不同版本的 derper，缺乏可复现性。上游破坏性更新可能导致脚本突然失败或行为变更。

**修复方案**：
```bash
DERPER_VERSION="${DERPER_VERSION:-latest}"  # 全局默认值，可通过环境变量或参数覆盖

# parse_args 添加 --derper-version 参数
# install_derper 中使用：
go install "tailscale.com/cmd/derper@${DERPER_VERSION}"
```

**工作分解**：
- [ ] 添加 `DERPER_VERSION` 全局变量，默认 `latest`
- [ ] 添加 `--derper-version` 命令行参数
- [ ] 在 `usage()` 和 wizard 中体现此参数

---

### D-12：未验证 IP 是否为公网地址

**影响行**：467-484  
**风险**：用户传入 `10.0.0.1`、`192.168.1.1` 等私有 IP 时脚本正常执行，但部署的 DERP 服务对外不可达，浪费时间排查。

**修复方案**：在 `validate_settings` 中添加 RFC 1918 / 环回 / 链路本地地址检测：
```bash
# 检测常见非公网 IP 段
local o1_dec=$((10#$o1)) o2_dec=$((10#$o2))
if (( o1_dec == 10 )) || \
   (( o1_dec == 172 && o2_dec >= 16 && o2_dec <= 31 )) || \
   (( o1_dec == 192 && o2_dec == 168 )) || \
   (( o1_dec == 127 )) || \
   (( o1_dec == 169 && o2_dec == 254 )); then
  echo "[警告] IP ${IP_ADDR} 似乎是私有/保留地址，DERP 服务需要公网 IP 才能被远程客户端访问。" >&2
  echo "  如果你确定这是你的场景（例如内网测试），可忽略此警告。" >&2
fi
```

**工作分解**：
- [ ] 添加私有 IP / 环回 / 链路本地地址检测
- [ ] 仅发出警告，不阻断（兼容内网测试场景）

---

### D-13：`write_prometheus_metrics` 错误信息不准确

**影响行**：1802-1811  
**风险**：写入 `$tmp` 成功但 `mv` 失败时（如跨文件系统），错误消息说"写入失败"，误导用户排查方向。

**修复方案**：
```bash
if ! mv -f "$tmp" "$path" 2>/dev/null; then
  echo "[警告] Prometheus 指标写入成功但无法移动到目标路径：$path" >&2
  echo "  可能原因：跨文件系统、目录权限不足。请确保路径可写。" >&2
  rm -f "$tmp" 2>/dev/null || true
  return 1
fi
```

**工作分解**：
- [ ] 区分写入失败和移动失败的错误消息
- [ ] 在移动失败的消息中提供可能原因

---

### D-14：Go tarball 安装成功后未清理

**影响行**：743-776  
**风险**：约 140 MB 的 tarball 遗留在 `/tmp` 中。仅在 SHA256 校验失败（L765）时才清理。

**修复方案**：在 `tar` 解压成功后添加：
```bash
rm -f "$tarball"
```

**工作分解**：
- [ ] 在 `tar -C /usr/local -xzf "$tarball"` 之后添加 `rm -f "$tarball"`
- [ ] 若使用 D-01 的 `trap EXIT` 方案，tarball 在临时目录中会自动清理，但显式清理更及时

---

### D-15：仓库文件缺失

**影响范围**：README.md、CHANGELOG  
**风险**：README 引用了不存在的 `LICENSE`、`tests/`、`docs/ACCOUNT_AND_SECURITY.md`，给用户造成困惑，且无许可证文件意味着代码默认"保留所有权利"。

**工作分解**：
- [ ] 添加 `LICENSE` 文件（建议 MIT 或 Apache-2.0）
- [ ] 移除 README 和 CHANGELOG 中对不存在的 `tests/` 目录的引用，或创建基本测试框架
- [ ] 移除或创建 `docs/ACCOUNT_AND_SECURITY.md`

---

### D-16：`runtime_checks` 端口 grep 缺少词边界

**影响行**：1557  
**风险**：若 `DERP_PORT=80`，`grep -E ":80"` 会匹配 `:8080`、`:80443` 等，输出误导信息。

**修复方案**：
```bash
grep -E ":(${DERP_PORT}|${STUN_PORT})\b" || true
```
或使用更精确的模式：
```bash
grep -E ":(${DERP_PORT}|${STUN_PORT})([^0-9]|$)" || true
```

**工作分解**：
- [ ] 在 `runtime_checks` 的 grep 中添加词边界或后跟非数字断言

---

### D-17：多包管理器并存时包名重复添加

**影响行**：660-668  
**风险**：使用 `if-if-if` 结构，若系统同时存在 `apt` 和 `dnf`，会将两者的包名都加入列表。

**修复方案**：改为 `if-elif-elif` 互斥逻辑，与后续实际安装（L678-698）的优先级一致。

**工作分解**：
- [ ] 将可选包的检测逻辑从 `if-if-if` 改为 `if-elif-elif`

---

### D-18：`derper.json` 权限 644 全局可读

**影响行**：901  
**风险**：默认内容虽为 `{}`，但用户后续可能添加敏感配置，全局可读存在信息泄露风险。

**修复方案**：改为 `640`，仅 root 和运行用户组可读。

**工作分解**：
- [ ] `chmod 644` 改为 `chmod 640`
- [ ] 在 `setup_service_user` 中确保运行用户可读此文件

---

### D-19：`sed -i` 无备份直接修改 systemd unit 文件

**影响行**：1457  
**风险**：若 `sed` 执行中系统崩溃或断电，unit 文件可能损坏，服务无法启动。

**修复方案**：
```bash
sed -i.bak '/MemoryDenyWriteExecute/d' "${SERVICE_PATH}"
rm -f "${SERVICE_PATH}.bak"  # 成功后清理备份
```

**工作分解**：
- [ ] 使用 `sed -i.bak` 保留备份，操作成功后再删除

---

### D-20：systemd 单元缺少重启风暴保护

**影响行**：1415-1446  
**风险**：`RestartSec=2` + `Restart=on-failure` 未配合启动频率限制。若 derper 持续立即崩溃，短时间内反复重启造成日志洪泛和系统负担。

**修复方案**：在 `[Service]` 段添加：
```ini
StartLimitBurst=5
StartLimitIntervalSec=60
```

**工作分解**：
- [ ] 在 systemd unit 模板中添加 `StartLimitBurst` 和 `StartLimitIntervalSec`

---

### D-21：`--security-level` 输入延迟验证

**影响行**：323-326  
**风险**：用户传入非法安全级别（如 `--security-level high`），脚本会执行完所有安装步骤后才在 `write_systemd_service` 中报错退出。

**修复方案**：在 `validate_settings` 中前置校验：
```bash
case "${SECURITY_LEVEL}" in
  basic|standard|paranoid) ;;
  *) echo "[错误] --security-level 必须为 basic|standard|paranoid，当前：${SECURITY_LEVEL}" >&2; return 1 ;;
esac
```

**工作分解**：
- [ ] 在 `validate_settings` 中添加 `SECURITY_LEVEL` 合法值校验

---

### D-22：`timeout` 命令在最小化环境可能缺失

**影响行**：1563  
**风险**：`timeout` 是 GNU coreutils 的一部分，在 Alpine 或最小化容器中可能不存在，导致 `runtime_checks` 和 `live_cert_sha256_raw` 失败。

**修复方案**：在调用 `timeout` 前检查可用性，缺失时降级：
```bash
if command -v timeout >/dev/null 2>&1; then
  timeout 5 openssl s_client ...
else
  openssl s_client ... &
  local pid=$!
  sleep 5 && kill $pid 2>/dev/null &
  wait $pid 2>/dev/null || true
fi
```

**工作分解**：
- [ ] 添加 `timeout` 存在性检查
- [ ] 缺失时使用后台进程 + sleep + kill 模拟超时

---

## 三、整改优先级与工作计划

### 第一批：高危修复（P0 — 建议立即修复）

| 工作项 | 涉及缺陷 | 预估改动量 | 说明 |
|--------|----------|------------|------|
| 安全临时目录治理 | D-01, D-02, D-14 | ~20 行 | `mktemp -d` + `trap EXIT` + 替换所有 `/tmp` 硬编码 |
| SHA256 校验兜底 | D-03 | ~10 行 | 添加 openssl 回退，移除"跳过"逻辑 |
| 参数数组拆分 | D-04 | ~30 行 | `stun_flag` / `listen_flag` 重构为数组 |
| Tailscale SSH 保护 | D-05 | ~20 行 | 添加连接检测和确认逻辑 |

### 第二批：中危修复（P1 — 建议本版本修复）

| 工作项 | 涉及缺陷 | 预估改动量 | 说明 |
|--------|----------|------------|------|
| 输入校验加固 | D-06, D-07, D-12, D-21 | ~40 行 | SUDO_USER / Region / IP / security-level 校验 |
| 版本比较修复 | D-08 | ~15 行 | 纯 bash 逐段比较回退 |
| Go 安装安全 | D-09 | ~10 行 | 删除前确认 |
| 竞态修复 | D-10 | ~10 行 | sleep 改轮询 |
| 构建可复现性 | D-11 | ~10 行 | 添加 `--derper-version` 参数 |
| Prometheus 错误消息 | D-13 | ~5 行 | 区分写入/移动失败 |
| 仓库补全 | D-15 | ~文件级 | 添加 LICENSE，清理失效引用 |

### 第三批：低危修复（P2 — 可合入后续版本）

| 工作项 | 涉及缺陷 | 预估改动量 | 说明 |
|--------|----------|------------|------|
| grep 健壮性 | D-16 | ~2 行 | 添加词边界 |
| 包管理器互斥 | D-17 | ~6 行 | if-if 改 if-elif |
| 文件权限加固 | D-18 | ~1 行 | 644 改 640 |
| sed 安全写入 | D-19 | ~2 行 | sed -i.bak |
| systemd 重启保护 | D-20 | ~2 行 | 添加 StartLimitBurst |
| timeout 兼容 | D-22 | ~10 行 | 降级方案 |

---

## 四、架构层面建议（非阻塞）

| 建议 | 说明 |
|------|------|
| 引入 ShellCheck CI | 在 GitHub Actions 中集成 `shellcheck`，自动发现引用、管道、兼容性问题 |
| 添加基本测试框架 | 使用 `bats-core` 或类似工具，覆盖核心函数（`ver_ge`、`validate_settings`、`parse_args`） |
| 考虑模块化拆分 | 2200+ 行的单文件维护成本较高，可拆分为 `lib/` 下的功能模块并通过 `source` 引入 |

---

> **报告结束**。总计 22 项缺陷，建议按 P0 → P1 → P2 分批整改。
