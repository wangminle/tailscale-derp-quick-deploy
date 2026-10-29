#!/usr/bin/env bash

# 说明：
#  - 面向“仅有公网 IP、无需域名”的轻量 DERP 部署；生成“基于 IP 的自签证书”。
#  - 适合测试/临时/小规模使用；生产建议配合受信任 CA 证书与 443 端口。
#  - 脚本会：安装依赖 -> 安装/构建 derper -> 生成证书 -> 写入 systemd -> 防火墙提示 -> 自检 -> 输出 ACL 片段。
#  - 兼容新版 derper（使用 -a :PORT），旧版则回退到 -https-port；默认启用 -verify-clients。

set -euo pipefail

# 脚本自身版本（与 docs/CHANGELOG_*.md、仓库根目录 VERSION 保持同步）
SCRIPT_VERSION="0.3.0"
SCRIPT_VERSION_DATE="2026-10-29"

# 默认端口
DERP_PORT="30399"        # DERP TLS 端口
DERP_PORT_EXPLICIT=0
STUN_PORT="3478"         # STUN 端口（UDP）
STUN_PORT_EXPLICIT=0
CERT_DAYS="365"          # 自签证书有效期（天）
CERT_DAYS_MAX="365000"   # 约 1000 年，避免超大数字在 Bash 算术中溢出
INSTALL_DIR="/opt/derper" # 安装/证书目录，root 管理
BIN_PATH="/usr/local/bin/derper"
# 节点私钥在 StateDirectory；安装树父目录不交给服务用户写。
NODE_STATE_DIR="${NODE_STATE_DIR:-}"
DEPLOY_STATE_DIR="${DEPLOY_STATE_DIR:-/var/lib/derper-deploy}"
RECOVER_INTERRUPTED=0
SERVICE_PATH="/etc/systemd/system/derper.service"

# 版本门槛（可通过环境变量覆盖）
REQUIRED_TS_VER="${REQUIRED_TS_VER:-1.66.3}"

# 可选：Go 模块代理 / 校验数据库 / 工具链策略
GOPROXY_ARG=""                 # 例：https://goproxy.cn,direct
GOSUMDB_ARG=""                 # 例：sum.golang.google.cn
GOTOOLCHAIN_ARG="auto"         # auto|local（默认 auto 以满足 >=1.25）

# Go 版本配置（用于 ensure_go 自动安装）
# GOTOOLCHAIN=auto 需要 Go >= 1.21；发行版 apt 包（如 Ubuntu 22.04 的 1.18）不够。
MIN_GO_VERSION="1.21"
GO_VERSION="1.22.6"
GO_SHA256_AMD64="999805bed7d9039ec3da1a53bfbcafc13e367da52aa823cb60b68ba22d44c616"
GO_SHA256_ARM64="c15fa895341b8eaf7f219fada25c36a610eb042985dc1a912410c1c90098eaf2"

# derper 版本（默认 latest，可通过 --derper-version 指定确定性版本）
DERPER_VERSION="${DERPER_VERSION:-latest}"

# 客户端校验：on=强制启用；off=禁用（默认 on）
VERIFY_CLIENTS_MODE="on"
VERIFY_CLIENTS_EXPLICIT=0

# ACL Region 配置（可自定义）
REGION_ID="900"
REGION_CODE="my-derp"
REGION_NAME="My IP DERP"

# 运行用户配置（可自定义）
# 验证 SUDO_USER 是否为合法的 POSIX 用户名（防止注入，CWE-20）
# 注意：$USER 在 sudo/CI/容器等最小环境下可能未导出，set -u 下直接引用会报错；
#       统一使用 ${USER:-$(id -un)} 兜底（id 来自 coreutils，必定可用）。
if [[ -n "${SUDO_USER:-}" ]]; then
  if [[ "${SUDO_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    RUN_USER="${SUDO_USER}"
  else
    echo "[警告] SUDO_USER 包含非法字符（${SUDO_USER}），已忽略，使用当前用户。" >&2
    RUN_USER="${USER:-$(id -un)}"
  fi
else
  RUN_USER="${USER:-$(id -un)}"
fi
RUN_USER_EXPLICIT=0
ACCEPT_CERT_ROTATION=0
USE_CURRENT_USER=1       # 默认使用当前用户
CREATE_DEDICATED_USER=0  # 是否强制创建专用用户
RELAX_SOCKET_PERMS=0     # 是否允许放宽 socket 权限（不推荐）
SOCKET_RELAXED_PATH=""   # --relax-socket-perms 改过的 socket，退出时恢复
SOCKET_RELAXED_ORIG_MODE=""
NON_INTERACTIVE=0        # 非交互模式（CI/自动化）
SECURITY_LEVEL="standard" # 安全加固级别：basic|standard|paranoid
SECURITY_LEVEL_EXPLICIT=0
TLS_CONNLIMIT=0          # 单 IP 并发 TLS 连接上限，0 表示不安装限速规则
TLS_CONNLIMIT_EXPLICIT=0 # 是否在命令行显式传入 --tls-connlimit
TLS_CONNLIMIT_MAX="1000000"
NFT_CONNLIMIT_TABLE="derper_tls_connlimit"  # 脚本专属表，禁止动用用户的 inet derper
INSTALL_HEALTHCHECK_CRON=0
HEALTHCHECK_CRON_PATH="/etc/cron.d/derper-healthcheck"
HEALTHCHECK_CRON_METRICS_DEFAULT="/var/lib/node_exporter/textfile_collector/derper.prom"

IP_ADDR=""
_tmpdir=""               # 安全临时目录（main 中初始化，trap EXIT 自动清理）
AUTO_UFW=0               # 是否自动放行 UFW
DRY_RUN=0                # 只做检查，不执行安装/写入
FORCE=0                  # 强制全量重装
REPAIR=0                 # 仅修复配置（不重装 derper）
CHECK_ONLY=0             # --check 别名（等价于 --dry-run）
ALLOW_NON_GLOBAL_IP=0    # 是否放行私有/保留/文档等非全局可路由 IP（仅内网测试）
ALLOW_REGION_ID_CONFLICT=0 # 是否显式允许共用/替换已占用 RegionID
DESIRED_CONFIG_OK=0      # 当前 systemd unit 是否与本次目标参数一致
DERPER_VERIFY_CLIENTS_EFFECTIVE=0 # 当前已部署 unit 是否启用了 -verify-clients
CURRENT_DERPER_OWNS_PORTS=0       # 当前监听端口是否来自已运行的 derper 服务

# 新增：健康检查 / 卸载 / 指标导出
HEALTH_CHECK=0           # 输出健康检查结果（便于 cron 监控）
UNINSTALL=0              # 停止并卸载 systemd 单元
PURGE=0                  # 与 --uninstall 一起使用：清理安装目录（证书等）
PURGE_ALL=0              # 与 --uninstall 一起使用：清理安装目录与二进制
METRICS_TEXTFILE=""      # 将健康检查指标写为 Prometheus textfile（供 node_exporter 收集）
CONFIG_FILE=""
SUBCOMMAND=""
OUTPUT_FORMAT=text
DERPMAP_ONLY=0
LOCAL_BINARY=""
BINARY_SHA256=""
EXTERNAL_PROBE=""
PROBE_TIMEOUT=15
PROBE_TIMEOUT_EXPLICIT=0
PROBE_MAX_AGE=60
PROBE_MAX_AGE_EXPLICIT=0
REQUIRE_H3=0
METRICS_SOURCE=""
METRICS_MAX_AGE=900
METRICS_MAX_AGE_EXPLICIT=0
HEALTH_STATE_FILE=""
HEALTH_SNAPSHOT_READY=0
CERT_PREPARE=0
CERT_APPLY=0
CERT_CANCEL=0
CERT_MAINTAIN=0
ENABLE_AUTO_MAINTAIN=0
DISABLE_AUTO_MAINTAIN=0
CERT_LEAD_DAYS=30
CERT_LEAD_DAYS_EXPLICIT=0
POLICY_CREDENTIAL_FILE="${POLICY_CREDENTIAL_FILE:-/etc/derper/policy-api.env}"
TS_API_BASE="${TS_API_BASE:-https://api.tailscale.com}"
TS_TAILNET="${TS_TAILNET:-}"
TS_API_CLIENT_ID=""
TS_API_CLIENT_SECRET=""
POLICY_SOURCE=""
POLICY_TOKEN=""
POLICY_GRANTED_SCOPE=""
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-}"

# 配置是数据，不是 shell；无自动搜索，无凭据字段，无操作模式字段。
load_deploy_config() {
  local file="$1" line key value seen='|' version='' size uid mode
  local keys=() values=()
  [[ -f "$file" && -r "$file" && ! -L "$file" ]] || { echo '[错误] 配置必须为可读普通文件，不能是符号链接。' >&2; return 1; }
  size=$(wc -c <"$file")
  (( size <= 65536 )) || { echo '[错误] 配置超过64KiB。' >&2; return 1; }
  if ! LC_ALL=C tr -d '\000' <"$file" | cmp -s "$file" -; then echo '[错误] 配置含NUL字节。' >&2; return 1; fi
  if [[ "$(id -u)" == 0 ]]; then
    uid=$(stat -c %u "$file" 2>/dev/null || stat -f %u "$file") || return 1
    mode=$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file") || return 1
    [[ "$uid" == 0 ]] && (( (8#$mode & 0022) == 0 )) || { echo '[错误] root使用的配置须归root所有且组/其他用户不可写。' >&2; return 1; }
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$line" && "$line" != \#* ]] || continue
    [[ "$line" == *=* ]] || { echo '[错误] 配置必须为KEY=value。' >&2; return 1; }
    key=${line%%=*}; value=${line#*=}
    value="${value%"${value##*[![:space:]]}"}"
    case "$key" in
      CONFIG_VERSION|IP_ADDR|DERP_PORT|STUN_PORT|CERT_DAYS|CERT_LEAD_DAYS|DERPER_VERSION|REGION_ID|REGION_CODE|REGION_NAME|RUN_USER|VERIFY_CLIENTS_MODE|SECURITY_LEVEL|TLS_CONNLIMIT|ALLOW_NON_GLOBAL_IP|EXTERNAL_PROBE|PROBE_TIMEOUT|PROBE_MAX_AGE|REQUIRE_H3|METRICS_MAX_AGE|TS_TAILNET|POLICY_CREDENTIAL_FILE) ;;
      *) echo '[错误] 配置含未知或不允许的字段。' >&2; return 1 ;;
    esac
    [[ "$seen" != *"|$key|"* ]] || { echo '[错误] 配置含重复字段。' >&2; return 1; }
    case "$value" in *'$'*|*'`'*|*';'*|*'|'*|*'&'*|*'<'*|*'>'*|*'"'*|*"'"*|*'\'*) echo '[错误] 配置值不允许shell语法或引号。' >&2; return 1 ;; esac
    if printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]'; then echo '[错误] 配置值含控制字符。' >&2; return 1; fi
    [[ -n "$value" ]] || return 1
    case "$key" in
      CONFIG_VERSION) version=$value ;;
      VERIFY_CLIENTS_MODE) [[ "$value" == on || "$value" == off ]] || return 1 ;;
      ALLOW_NON_GLOBAL_IP|REQUIRE_H3) [[ "$value" == 0 || "$value" == 1 ]] || return 1 ;;
      REGION_ID) decimal_in_closed_range "$value" 1 9007199254740991 || return 1 ;;
      DERP_PORT|STUN_PORT|CERT_DAYS|CERT_LEAD_DAYS|TLS_CONNLIMIT|PROBE_TIMEOUT|PROBE_MAX_AGE|METRICS_MAX_AGE) [[ "$value" =~ ^[0-9]{1,9}$ ]] || return 1 ;;
    esac
    seen+="$key|"
    keys+=("$key"); values+=("$value")
  done <"$file"
  [[ "$version" == 1 ]] || { echo '[错误] 配置必须声明CONFIG_VERSION=1。' >&2; return 1; }
  local i
  for ((i=0; i<${#keys[@]}; i++)); do
    key=${keys[i]}
    [[ "$key" != CONFIG_VERSION ]] || continue
    printf -v "$key" '%s' "${values[i]}"
    case "$key" in
      DERP_PORT) DERP_PORT_EXPLICIT=1 ;;
      STUN_PORT) STUN_PORT_EXPLICIT=1 ;;
      CERT_LEAD_DAYS) CERT_LEAD_DAYS_EXPLICIT=1 ;;
      RUN_USER) RUN_USER_EXPLICIT=1 ;;
      VERIFY_CLIENTS_MODE) VERIFY_CLIENTS_EXPLICIT=1 ;;
      SECURITY_LEVEL) SECURITY_LEVEL_EXPLICIT=1 ;;
    esac
  done
}

load_cli_config() {
  local args=("$@") file='' i count=$#
  for ((i=0; i<count; i++)); do
    if [[ "${args[i]}" == --config ]]; then
      [[ -z "$file" && $((i+1)) -lt $count ]] || return 1
      file=${args[i+1]}
      [[ -n "$file" && "$file" != --* ]] || return 1
      i=$((i+1))
    fi
  done
  [[ -n "$file" ]] || return 0
  load_deploy_config "$file" || return 1
  CONFIG_FILE=$file
}

usage() {
  cat <<EOF
用法：sudo bash $0 [选项]
或者：sudo bash $0 wizard  (启动交互式配置向导)

脚本版本：${SCRIPT_VERSION}（${SCRIPT_VERSION_DATE}）

C/D阶段入口（旧参数继续支持）：
  deploy | check | health | status | repair | uninstall | recover | derpmap
  prepare | apply | cancel | maintain
  --enable-auto-maintain    在写授权、Tailnet 目标和调度条件齐全时记录本节点自动换证
  --disable-auto-maintain   关闭自动换证，保留人工路径
  --lead-days N             到期前提前天数，默认 30（随短期证书收紧），显式值须在有效期内
  --policy-credential FILE  root 凭据文件，默认 /etc/derper/policy-api.env
  --tailnet NAME            目标 Tailnet，自动维护必填；不把本机登录当成写授权
  --config FILE             显式读取CONFIG_VERSION=1白名单配置，CLI优先
  --format text|json        health/status输出格式；derpmap输出JSON片段
  --binary FILE             导入本地Linux ELF，须固定--derper-version
  --binary-sha256 HEX        可选预期摘要；本地摘要不证明发布者身份
  --external-probe FILE     独立合法客户端探针适配器（详见用户指南）
  --probe-timeout SEC       探针超时1～120秒，默认15
  --probe-max-age SEC       探针结果最大年龄，默认60秒
  --require-h3              缺少真实外部检查结果时返回未知并阻断发布
  --metrics-source FILE     只读检查旧指标新鲜度
  --metrics-max-age SEC     旧指标最大年龄，默认900秒
  --state-file FILE         原子保存本次健康结果和最近成功时间

选项列表：
用法（向导模式）：sudo bash $0 wizard  [启动交互式配置向导]
用法（命令模式）：sudo bash $0 [--ip 公网IP] [--derp-port 30399] [--stun-port 3478] [--cert-days 365] [--auto-ufw]
               [--goproxy URL] [--gosumdb VALUE] [--gotoolchain auto|local]
               [--no-verify-clients | --force-verify-clients]
               [--region-id 900] [--region-code my-derp] [--region-name "My IP DERP"]
               [--user <username> | --use-current-user | --dedicated-user]
               [--allow-non-global-ip] [--allow-region-id-conflict] [--accept-cert-rotation]
               [--tls-connlimit N] [--install-healthcheck-cron]
               [--check | --dry-run] [--repair] [--force]
               [--health-check [--metrics-textfile 路径]]
               [--uninstall [--purge | --purge-all]]
               [--recover-interrupted]
               [-V | --version] [-h | --help]

参数说明：
  -V, --version           打印脚本版本并退出。
  -h, --help              显示本帮助并退出。
  --ip                    服务器公网 IPv4（推荐显式指定），缺省自动探测。
                          正式部署必须为全局可路由的公网地址；
                          内网/保留/文档地址默认拒绝，测试需加 --allow-non-global-ip。
  --derp-port             DERP TLS 端口，默认 30399/TCP；可改为其他空闲 TCP 端口。
                         云安全组/主机防火墙须放行同一端口，derpMap 的 DERPPort 须一致。
                         443 对受限网络更友好，但可能与现有 HTTPS 服务冲突。
  --stun-port             STUN 端口，默认 3478/UDP（同时写入 derpMap 的 STUNPort）。
  --cert-days             自签临时证书有效期（天），默认 365，范围 1–365000。
  --auto-ufw              若检测到 UFW，自动放行端口规则。
  --goproxy URL           设置 GOPROXY，例如 https://goproxy.cn,direct（默认继承环境）。
  --gosumdb VALUE         设置 GOSUMDB，例如 sum.golang.google.cn（默认继承环境）。
  --gotoolchain MODE      go 工具链策略，默认 auto 以便自动获取 >=1.25 的工具链。
  --no-verify-clients     不验证客户端身份（仅测试，默认并不推荐）。
  --force-verify-clients  强制启用客户端校验（默认行为）。
  --region-id             ACL derpMap 的 RegionID（默认 900）。
  --region-code           ACL derpMap 的 RegionCode（默认 my-derp）。
  --region-name           ACL derpMap 的 RegionName（默认 "My IP DERP"）。
  --allow-region-id-conflict  显式允许共用/替换已占用 RegionID；默认阻断其他节点冲突。
                          多节点策略仍须人工合并并保留既有 Nodes，不能整份替换。
  --user <username>       指定运行 derper 的用户（默认：当前登录用户）。
                          可指定现有用户（如 nobody、www-data 等）。
  --use-current-user      使用当前登录用户运行 derper（sudo 下为 \$SUDO_USER，否则为当前用户；默认行为）。
  --dedicated-user        强制创建专用 derper 系统账户（生产环境推荐）。
  --allow-non-global-ip   允许使用私有/保留/文档/组播等非全局可路由 IP（仅内网测试）。
  --security-level LEVEL  安全加固级别：basic|standard|paranoid（默认 standard）。
  --accept-cert-rotation  确认已有证书换指纹及 ACL 更新期间的中断风险（--yes 不代替此确认）。
  --relax-socket-perms    允许临时放宽 tailscaled socket 权限到 0666（不推荐，仅紧急情况）。
                          脚本退出时恢复原权限。
  --tls-connlimit N       限制单 IP 并发 DERP TLS 连接数（nftables/iptables connlimit）。
                          显式传 0 会移除已安装规则；省略该选项则不改动已有规则。
                          不能与 --health-check/--check/--dry-run 同时使用。
  --install-healthcheck-cron  安装每 5 分钟的健康检查。有 systemd 时写 oneshot timer，并去掉旧 cron；否则用显式 bash 调用 root 管理的稳定副本写入 cron。
                          --uninstall 会删除该 cron。
                          不能与 --uninstall/--health-check/--check/--dry-run 同时使用。
  --yes, --non-interactive 非交互模式，自动确认所有选择（适合 CI/自动化脚本）。
  --check, --dry-run      仅进行状态与参数检查，不执行安装/写服务/放行端口等操作。
                          不能与 --health-check/--repair/--force/--uninstall 同时使用。
  --repair                仅修复/重写配置（systemd/证书等），不中断可用的依赖；
                          默认不重装 derper，但若已部署二进制与目标版本不一致，
                          会重新安装以对齐（如 -verify-clients 的版本对齐）。
                          不能与 --health-check/--check/--dry-run/--force/--uninstall 同时使用。
  --force                 强制全量重装（重新安装 derper、重签证书、重写服务）。
                          不能与 --health-check/--check/--dry-run/--repair/--uninstall 同时使用。
  --derper-version VER    指定 derper 版本（默认 latest），例如 v1.74.1 以确保可复现构建；
                          也接受 Git commit（与 tailscaled 同源对齐时使用）。

  --health-check          输出健康检查摘要（适合 cron 周期探测；不更改系统）。
                          不能与 --check/--dry-run/--repair/--force/--uninstall 同时使用。
                          退出码：0 健康，1 已确认故障；2 保留给未知且不会被当成健康。任意非 0 都表示未通过。
  --metrics-textfile P    将健康检查结果以 Prometheus 文本格式写入到文件 P。
                          必须与 --health-check 或 --install-healthcheck-cron 一起使用；
                          建议结合 node_exporter 的 textfile collector 使用。
  --uninstall             停止并卸载 derper systemd 服务（保留二进制与证书）。
                          同时删除健康检查 timer/cron、证书维护 service/timer 与 --tls-connlimit 规则。
                          维护 unit 文件、启用或运行状态残留时退出非零，不报告完成。
                          不能与 --health-check/--check/--dry-run/--repair/--force 同时使用。
  --recover-interrupted   显式恢复未完成的升级/迁移。不会自动继续中断的步骤。
                          不能与安装、修复、检查或卸载同时使用。
  --purge                 必须与 --uninstall 一起使用：额外删除 ${INSTALL_DIR}（证书等）。
  --purge-all             必须与 --uninstall 一起使用：在 --purge 基础上，同时删除 ${BIN_PATH}、
                          /etc/derper/derper.env、健康检查稳定副本/状态、维护脚本副本及 target.conf、
                          以及脚本创建的 tailscaled socket drop-in。
                          防火墙规则和用户/组账户需手动确认，不会自动删除。

示例：
  sudo bash $0 --ip <你的公网IP> --derp-port 30399 --auto-ufw \
    --goproxy https://goproxy.cn,direct --gosumdb sum.golang.google.cn

   # 仅健康检查 + 导出 Prometheus 文本（可配合 cron）
   sudo bash $0 --ip <你的公网IP> --health-check --metrics-textfile /var/lib/node_exporter/textfile_collector/derper.prom

   # 一键卸载服务并清理安装目录
   sudo bash $0 --uninstall --purge
EOF
}

print_version() {
  echo "deploy_derper_ip_selfsigned.sh ${SCRIPT_VERSION} (${SCRIPT_VERSION_DATE})"
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "[错误] 需要 root 权限，请使用 sudo。" >&2
    exit 1
  fi
}

# 检查操作系统和运行环境
check_os_environment() {
  local os_type=""
  local is_wsl=0
  
  # 检测操作系统类型
  if [[ -f /proc/version ]]; then
    if grep -qi microsoft /proc/version 2>/dev/null; then
      is_wsl=1
      os_type="WSL"
    elif grep -qi linux /proc/version 2>/dev/null; then
      os_type="Linux"
    fi
  fi
  
  # 如果 /proc/version 不存在，通过 uname 检测
  if [[ -z "$os_type" ]]; then
    case "$(uname -s)" in
      Linux*)   os_type="Linux";;
      Darwin*)  os_type="macOS";;
      *)        os_type="Unknown";;
    esac
  fi
  
  # 检测 WSL 环境变量（仅当尚未确定为 Linux 时才检查，避免误判）
  if [[ "$os_type" != "Linux" ]]; then
    if [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ -n "${WSL_INTEROP:-}" ]]; then
      is_wsl=1
      os_type="WSL"
    fi
  fi
  
  # 阻断非 Linux 环境
  if [[ "$os_type" == "macOS" ]]; then
    cat >&2 <<'EOT'
╔══════════════════════════════════════════════════════════════════════════════╗
║                          ⚠️  不支持的操作系统：macOS                          ║
╚══════════════════════════════════════════════════════════════════════════════╝

[错误] 本脚本仅支持在具备公网 IPv4 的 Linux 服务器上部署 DERP 中继服务。

macOS 不适合作为 DERP 服务器的原因：
  ❌ macOS 设备通常位于家庭/办公网络的 NAT 后，缺乏公网可达性
  ❌ 桌面系统不适合作为 24/7 在线的中继节点
  ❌ Tailscale DERP 要求服务器可被全球客户端访问

推荐部署方案：
  ✅ 云服务器（阿里云、腾讯云、AWS、DigitalOcean 等）
  ✅ 家用 Linux 设备 + 公网 IP + 端口转发（如树莓派、软路由）
  ✅ VPS 或专用服务器

本地开发测试：
  如需在 macOS 上测试 derper 程序本身（非生产部署），可手动运行：
    derper -c ./derper.json -hostname 127.0.0.1 -certmode manual -certdir ./certs \
      -http-port -1 -a :30399 -stun
  注意：此模式仅供本地功能验证，无法作为 Tailscale 网络的中继节点。

EOT
    exit 1
  elif [[ "$is_wsl" -eq 1 ]]; then
    cat >&2 <<'EOT'
╔══════════════════════════════════════════════════════════════════════════════╗
║                       ⚠️  不支持的运行环境：WSL                              ║
╚══════════════════════════════════════════════════════════════════════════════╝

[错误] 本脚本仅支持在具备公网 IPv4 的 Linux 服务器上部署 DERP 中继服务。

WSL 不适合作为 DERP 服务器的原因：
  ❌ WSL 位于双重 NAT 后（Windows NAT + 家庭网络 NAT），外部无法访问
  ❌ WSL 网络栈不完整，无法稳定提供公网服务
  ❌ WSL 依赖 Windows 主机运行，不适合 24/7 在线服务
  ❌ Tailscale DERP 要求服务器可被全球客户端访问

推荐部署方案：
  ✅ 云服务器（阿里云、腾讯云、AWS、DigitalOcean 等）
  ✅ 家用 Linux 设备 + 公网 IP + 端口转发（如树莓派、软路由）
  ✅ VPS 或专用服务器

本地开发测试：
  如需在 WSL 上测试 derper 程序本身（非生产部署），可手动运行：
    derper -c ./derper.json -hostname 127.0.0.1 -certmode manual -certdir ./certs \
      -http-port -1 -a :30399 -stun
  注意：此模式仅供本地功能验证，无法作为 Tailscale 网络的中继节点。

EOT
    exit 1
  elif [[ "$os_type" != "Linux" ]]; then
    cat >&2 <<'EOT'
╔══════════════════════════════════════════════════════════════════════════════╗
║                          ⚠️  不支持的操作系统                                 ║
╚══════════════════════════════════════════════════════════════════════════════╝

[错误] 本脚本仅支持在具备公网 IPv4 的 Linux 服务器上部署 DERP 中继服务。

检测到的系统类型：未知或不受支持

推荐部署方案：
  ✅ 云服务器（阿里云、腾讯云、AWS、DigitalOcean 等）
  ✅ 家用 Linux 设备 + 公网 IP + 端口转发（如树莓派、软路由）
  ✅ VPS 或专用服务器

EOT
    exit 1
  fi
  
  # 检测 systemd（仅警告，不阻断，因为后续会有更详细的提示）
  if ! command -v systemctl >/dev/null 2>&1; then
    cat >&2 <<'EOT'
[警告] 未检测到 systemd 服务管理器
  本脚本依赖 systemd 来管理 derper 服务。
  如果你使用 OpenRC、SysV 或其他服务管理器，安装过程会在后续步骤中止，
  届时会提供手动运行的命令示例。
  
EOT
  fi
  
  echo "[✓] 环境检测通过：Linux 系统"
}

parse_args() {
  load_cli_config "$@" || { echo '[错误] 无法解析配置。' >&2; return 1; }
  case "${1:-}" in
    deploy|check|health|status|repair|uninstall|recover|derpmap|prepare|apply|cancel|maintain)
      SUBCOMMAND=$1; shift
      case "$SUBCOMMAND" in
        check) DRY_RUN=1; CHECK_ONLY=1 ;;
        health|status|derpmap) HEALTH_CHECK=1; [[ "$SUBCOMMAND" != derpmap ]] || DERPMAP_ONLY=1 ;;
        repair) REPAIR=1 ;;
        uninstall) UNINSTALL=1 ;;
        recover) RECOVER_INTERRUPTED=1 ;;
        prepare) CERT_PREPARE=1 ;;
        apply) CERT_APPLY=1 ;;
        cancel) CERT_CANCEL=1 ;;
        maintain) CERT_MAINTAIN=1 ;;
      esac ;;
  esac
  require_arg_value() {
    local opt="$1"
    local val="${2-}"
    if [[ -z "${val}" || "${val}" == --* ]]; then
      echo "[错误] 参数 ${opt} 需要一个值" >&2
      usage
      exit 1
    fi
  }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        require_arg_value "$1" "${2-}"; shift 2 ;;
      --format|--binary|--binary-sha256|--external-probe|--probe-timeout|--probe-max-age|--metrics-source|--metrics-max-age|--state-file)
        require_arg_value "$1" "${2-}"
        case "$1" in
          --format) OUTPUT_FORMAT=$2 ;;
          --binary) LOCAL_BINARY=$2 ;;
          --binary-sha256) BINARY_SHA256=$2 ;;
          --external-probe) EXTERNAL_PROBE=$2 ;;
          --probe-timeout) PROBE_TIMEOUT=$2; PROBE_TIMEOUT_EXPLICIT=1 ;;
          --probe-max-age) PROBE_MAX_AGE=$2; PROBE_MAX_AGE_EXPLICIT=1 ;;
          --metrics-source) METRICS_SOURCE=$2 ;;
          --metrics-max-age) METRICS_MAX_AGE=$2; METRICS_MAX_AGE_EXPLICIT=1 ;;
          --state-file) HEALTH_STATE_FILE=$2 ;;
        esac
        shift 2 ;;
      --require-h3) REQUIRE_H3=1; shift ;;
      --enable-auto-maintain) ENABLE_AUTO_MAINTAIN=1; shift ;;
      --disable-auto-maintain) DISABLE_AUTO_MAINTAIN=1; shift ;;
      --lead-days)
        require_arg_value "$1" "${2-}"
        CERT_LEAD_DAYS="$2"
        CERT_LEAD_DAYS_EXPLICIT=1
        shift 2 ;;
      --policy-credential)
        require_arg_value "$1" "${2-}"
        POLICY_CREDENTIAL_FILE="$2"
        shift 2 ;;
      --tailnet)
        require_arg_value "$1" "${2-}"
        TS_TAILNET="$2"
        shift 2 ;;
      --ip)
        require_arg_value "$1" "${2-}"
        IP_ADDR="$2"
        shift 2;;
      --derp-port)
        require_arg_value "$1" "${2-}"
        DERP_PORT="$2"
        DERP_PORT_EXPLICIT=1
        shift 2;;
      --stun-port)
        require_arg_value "$1" "${2-}"
        STUN_PORT="$2"
        STUN_PORT_EXPLICIT=1
        shift 2;;
      --cert-days)
        require_arg_value "$1" "${2-}"
        CERT_DAYS="$2"
        shift 2;;
      --auto-ufw)
        AUTO_UFW=1
        shift 1;;
      --goproxy)
        require_arg_value "$1" "${2-}"
        GOPROXY_ARG="$2"
        shift 2;;
      --gosumdb)
        require_arg_value "$1" "${2-}"
        GOSUMDB_ARG="$2"
        shift 2;;
      --gotoolchain)
        require_arg_value "$1" "${2-}"
        GOTOOLCHAIN_ARG="$2"
        shift 2;;
      --no-verify-clients)
        VERIFY_CLIENTS_MODE="off"
        VERIFY_CLIENTS_EXPLICIT=1
        shift 1;;
      --force-verify-clients)
        VERIFY_CLIENTS_MODE="on"
        VERIFY_CLIENTS_EXPLICIT=1
        shift 1;;
      --region-id)
        require_arg_value "$1" "${2-}"
        REGION_ID="$2"
        shift 2;;
      --region-code)
        require_arg_value "$1" "${2-}"
        REGION_CODE="$2"
        shift 2;;
      --region-name)
        require_arg_value "$1" "${2-}"
        REGION_NAME="$2"
        shift 2;;
      --allow-region-id-conflict)
        ALLOW_REGION_ID_CONFLICT=1
        shift 1;;
      --accept-cert-rotation)
        ACCEPT_CERT_ROTATION=1
        shift 1;;
      --user)
        RUN_USER_EXPLICIT=1
        require_arg_value "$1" "${2-}"
        RUN_USER="$2"
        shift 2;;
      --use-current-user)
        RUN_USER_EXPLICIT=1
        USE_CURRENT_USER=1
        CREATE_DEDICATED_USER=0
        RUN_USER="${SUDO_USER:-${USER:-$(id -un)}}"
        shift 1;;
      --allow-non-global-ip)
        ALLOW_NON_GLOBAL_IP=1
        shift 1;;
      --dedicated-user)
        RUN_USER_EXPLICIT=1
        CREATE_DEDICATED_USER=1
        USE_CURRENT_USER=0
        RUN_USER="derper"
        shift 1;;
      --security-level)
        require_arg_value "$1" "${2-}"
        SECURITY_LEVEL="$2"
        SECURITY_LEVEL_EXPLICIT=1
        shift 2;;
      --relax-socket-perms)
        RELAX_SOCKET_PERMS=1
        shift 1;;
      --tls-connlimit)
        require_arg_value "$1" "${2-}"
        TLS_CONNLIMIT="$2"
        TLS_CONNLIMIT_EXPLICIT=1
        shift 2;;
      --install-healthcheck-cron)
        INSTALL_HEALTHCHECK_CRON=1
        shift 1;;
      --yes|--non-interactive)
        NON_INTERACTIVE=1
        shift 1;;
      --check)
        DRY_RUN=1; CHECK_ONLY=1
        shift 1;;
      --dry-run)
        DRY_RUN=1; CHECK_ONLY=1
        shift 1;;
      --repair)
        REPAIR=1
        shift 1;;
      --force)
        FORCE=1
        shift 1;;
      --derper-version)
        require_arg_value "$1" "${2-}"
        DERPER_VERSION="$2"
        shift 2;;
      --health-check)
        HEALTH_CHECK=1
        shift 1;;
      --metrics-textfile)
        require_arg_value "$1" "${2-}"
        METRICS_TEXTFILE="$2"
        shift 2;;
      --uninstall)
        UNINSTALL=1
        shift 1;;
      --recover-interrupted)
        RECOVER_INTERRUPTED=1
        shift 1;;
      --purge)
        PURGE=1
        shift 1;;
      --purge-all)
        PURGE_ALL=1; PURGE=1
        shift 1;;
      -V|--version)
        print_version; exit 0;;
      -h|--help)
        usage; exit 0;;
      *)
        echo "未知参数：$1" >&2; usage; exit 1;;
    esac
  done
}

# 参数组合互斥/依赖校验：避免“静默取一个分支”或“选项被忽略”的误用。
validate_arg_combos() {
  local err=0
  health_output_paths_are_distinct || err=1
  case "$SUBCOMMAND" in
    deploy)
      if [[ "$FORCE$REPAIR$UNINSTALL$RECOVER_INTERRUPTED$HEALTH_CHECK$CHECK_ONLY" != 000000 ]]; then
        echo "[错误] deploy 不能与 --force、--repair、--check、--health-check、--uninstall 或 --recover-interrupted 一起使用；这些是互斥主模式。" >&2
        err=1
      fi
      ;;
    check)
      if [[ "$FORCE$REPAIR$UNINSTALL$RECOVER_INTERRUPTED$HEALTH_CHECK" != 00000 ]]; then
        echo "[错误] check 不能与 --force、--repair、--health-check、--uninstall 或 --recover-interrupted 一起使用；这些是互斥主模式。" >&2
        err=1
      fi
      ;;
    prepare|apply|cancel|maintain)
      if [[ "$FORCE$REPAIR$UNINSTALL$RECOVER_INTERRUPTED$HEALTH_CHECK$CHECK_ONLY" != 000000 ]]; then
        echo "[错误] ${SUBCOMMAND} 不能与 --force、--repair、--check、--health-check、--uninstall 或 --recover-interrupted 一起使用。" >&2
        err=1
      fi
      ;;
  esac
  if [[ "${ENABLE_AUTO_MAINTAIN}" -eq 1 && "${DISABLE_AUTO_MAINTAIN}" -eq 1 ]]; then
    echo "[错误] --enable-auto-maintain 与 --disable-auto-maintain 互斥。" >&2
    err=1
  fi
  if [[ "${CERT_LEAD_DAYS_EXPLICIT:-0}" -ne 1 && "$CERT_DAYS" =~ ^[0-9]+$ && "$CERT_LEAD_DAYS" =~ ^[0-9]+$ ]]; then
    if ! decimal_in_closed_range "$CERT_LEAD_DAYS" 1 "$CERT_DAYS"; then
      CERT_LEAD_DAYS=$CERT_DAYS
    fi
  fi
  if [[ ! "$CERT_LEAD_DAYS" =~ ^[0-9]+$ ]] || ! decimal_in_closed_range "$CERT_LEAD_DAYS" 1 "${CERT_DAYS}"; then
    echo "[错误] --lead-days 必须是 1 到证书有效期 ${CERT_DAYS} 天之间的整数，当前：${CERT_LEAD_DAYS}" >&2
    err=1
  fi
  if [[ "$OUTPUT_FORMAT" != text && "$OUTPUT_FORMAT" != json ]]; then
    echo "[错误] --format 只接受 text 或 json，当前：${OUTPUT_FORMAT}" >&2
    err=1
  fi
  if [[ "$OUTPUT_FORMAT" == json && "$HEALTH_CHECK" != 1 ]]; then
    echo "[错误] --format json 只能与 health、status 或 --health-check 一起使用。" >&2
    err=1
  fi
  if [[ -n "$BINARY_SHA256" && ( -z "$LOCAL_BINARY" || ! "$BINARY_SHA256" =~ ^[0-9a-fA-F]{64}$ ) ]]; then
    echo "[错误] --binary-sha256 必须是 64 位十六进制，且必须与 --binary 一起使用。" >&2
    err=1
  fi
  if [[ -n "$LOCAL_BINARY" ]]; then
    if [[ "$HEALTH_CHECK$CHECK_ONLY$UNINSTALL$RECOVER_INTERRUPTED" != 0000 || "$DERPER_VERSION" == latest || -z "$DERPER_VERSION" ]]; then
      echo "[错误] --binary 只能用于部署或修复，并且必须同时给出明确的 --derper-version（不能是 latest）。" >&2
      err=1
    fi
  fi
  if [[ -n "$METRICS_SOURCE" ]]; then
    if [[ "$HEALTH_CHECK" != 1 ]]; then
      echo "[错误] --metrics-source 只能与健康检查一起使用。" >&2
      err=1
    elif [[ -n "$METRICS_TEXTFILE" && "$METRICS_SOURCE" == "$METRICS_TEXTFILE" ]]; then
      echo "[错误] --metrics-source 与 --metrics-textfile 不能指向同一文件。" >&2
      err=1
    fi
  fi
  if [[ -n "$HEALTH_STATE_FILE" && "$HEALTH_CHECK" != 1 && "${INSTALL_HEALTHCHECK_CRON:-0}" != 1 ]]; then
    echo "[错误] --state-file 只能与健康检查或 --install-healthcheck-cron 一起使用。" >&2
    err=1
  fi
  if [[ "$PROBE_TIMEOUT" =~ ^[0-9]{1,6}$ ]]; then PROBE_TIMEOUT=$((10#$PROBE_TIMEOUT)); fi
  if [[ "$PROBE_MAX_AGE" =~ ^[0-9]{1,6}$ ]]; then PROBE_MAX_AGE=$((10#$PROBE_MAX_AGE)); fi
  if [[ "$METRICS_MAX_AGE" =~ ^[0-9]{1,6}$ ]]; then METRICS_MAX_AGE=$((10#$METRICS_MAX_AGE)); fi
  # 先按位数拒绝，避免超大数字进入 Bash 算术比较。
  if [[ ! "$PROBE_TIMEOUT" =~ ^[0-9]+$ || ${#PROBE_TIMEOUT} -gt 6 || "$PROBE_TIMEOUT" -lt 1 || "$PROBE_TIMEOUT" -gt 120 ]]; then
    echo "[错误] --probe-timeout 必须在 1 到 120 秒之间，当前：${PROBE_TIMEOUT}" >&2
    err=1
  fi
  if [[ ! "$PROBE_MAX_AGE" =~ ^[0-9]+$ || ${#PROBE_MAX_AGE} -gt 6 || "$PROBE_MAX_AGE" -lt 1 ]]; then
    echo "[错误] --probe-max-age 必须是 1 到 999999 的整数，当前：${PROBE_MAX_AGE}" >&2
    err=1
  fi
  if [[ ! "$METRICS_MAX_AGE" =~ ^[0-9]+$ || ${#METRICS_MAX_AGE} -gt 6 || "$METRICS_MAX_AGE" -lt 1 ]]; then
    echo "[错误] --metrics-max-age 必须是 1 到 999999 的整数，当前：${METRICS_MAX_AGE}" >&2
    err=1
  fi
  # 探针和指标年龄只在会采样的模式里被读取。check/uninstall/recover 不采集，静默收下会让人以为门禁已生效。
  if [[ "$CHECK_ONLY" == 1 || "$UNINSTALL" == 1 || "$RECOVER_INTERRUPTED" == 1 ]]; then
    if [[ -n "$EXTERNAL_PROBE" || "$REQUIRE_H3" == 1 ]]; then
      echo "[错误] --external-probe 与 --require-h3 只在健康检查或部署/修复时生效；check、uninstall、recover 会忽略它们，因此直接拒绝。" >&2
      err=1
    fi
    if [[ "${PROBE_TIMEOUT_EXPLICIT:-0}" == 1 || "${PROBE_MAX_AGE_EXPLICIT:-0}" == 1 || "$PROBE_TIMEOUT" != 15 || "$PROBE_MAX_AGE" != 60 ]]; then
      echo "[错误] --probe-timeout 与 --probe-max-age 只在健康检查或部署/修复时生效；check、uninstall、recover 会忽略它们，因此直接拒绝。" >&2
      err=1
    fi
  fi
  if [[ "$HEALTH_CHECK" != 1 && ( "${METRICS_MAX_AGE_EXPLICIT:-0}" == 1 || "$METRICS_MAX_AGE" != 900 ) ]]; then
    echo "[错误] --metrics-max-age 只能与健康检查一起使用。" >&2
    err=1
  fi
  if [[ "${PURGE}" -eq 1 || "${PURGE_ALL}" -eq 1 ]]; then
    if [[ "${UNINSTALL}" -ne 1 ]]; then
      echo "[错误] --purge/--purge-all 必须与 --uninstall 一起使用，单独使用不会执行清理。" >&2
      err=1
    fi
  fi
  if [[ -n "${METRICS_TEXTFILE}" && "${HEALTH_CHECK}" -ne 1 && "${INSTALL_HEALTHCHECK_CRON:-0}" -ne 1 ]]; then
    echo "[错误] --metrics-textfile 必须与 --health-check 或 --install-healthcheck-cron 一起使用（指标由健康检查生成）。" >&2
    err=1
  fi
  if [[ "${INSTALL_HEALTHCHECK_CRON:-0}" -eq 1 && "${UNINSTALL}" -eq 1 ]]; then
    echo "[错误] --install-healthcheck-cron 不能与 --uninstall 一起使用；卸载会删除已安装的 cron。" >&2
    err=1
  fi
  if [[ "${INSTALL_HEALTHCHECK_CRON:-0}" -eq 1 && "${DRY_RUN}" -eq 1 ]]; then
    echo "[错误] --install-healthcheck-cron 不能与 --check/--dry-run 一起使用。" >&2
    err=1
  fi
  if [[ "${INSTALL_HEALTHCHECK_CRON:-0}" -eq 1 && "${HEALTH_CHECK}" -eq 1 ]]; then
    echo "[错误] --install-healthcheck-cron 不能与 --health-check 一起使用；请单独安装 cron，或只做健康检查。" >&2
    err=1
  fi
  if [[ "${TLS_CONNLIMIT_EXPLICIT:-0}" -eq 1 && "${HEALTH_CHECK}" -eq 1 ]]; then
    echo "[错误] --tls-connlimit 不能与 --health-check 一起使用；连接上限只在部署/修复时生效。" >&2
    err=1
  fi
  if [[ "${TLS_CONNLIMIT_EXPLICIT:-0}" -eq 1 && "${DRY_RUN}" -eq 1 ]]; then
    echo "[错误] --tls-connlimit 不能与 --check/--dry-run 一起使用；连接上限只在部署/修复时生效。" >&2
    err=1
  fi
  if [[ "${FORCE}" -eq 1 && "${REPAIR}" -eq 1 ]]; then
    echo "[错误] --force 与 --repair 互斥，请只选择其中一个。" >&2
    err=1
  fi
  if [[ "${UNINSTALL}" -eq 1 ]]; then
    if [[ "${FORCE}" -eq 1 || "${REPAIR}" -eq 1 || "${DRY_RUN}" -eq 1 ]]; then
      echo "[错误] --uninstall 不能与 --force/--repair/--check/--dry-run 一起使用。" >&2
      err=1
    fi
  fi
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    if [[ "${FORCE}" -eq 1 || "${REPAIR}" -eq 1 ]]; then
      echo "[错误] --check/--dry-run 不能与 --force/--repair 一起使用。" >&2
      err=1
    fi
  fi
  # 部署是“未选择其他主模式”。只读检查与破坏性操作不能静默互相覆盖。
  if [[ "${HEALTH_CHECK}" -eq 1 ]]; then
    if [[ "${UNINSTALL}" -eq 1 || "${REPAIR}" -eq 1 || "${FORCE}" -eq 1 || "${DRY_RUN}" -eq 1 || "${CHECK_ONLY}" -eq 1 || "${RECOVER_INTERRUPTED}" -eq 1 ]]; then
      echo "[错误] --health-check 不能与 --check/--dry-run/--repair/--force/--uninstall/--recover-interrupted 一起使用；这些主模式互斥。" >&2
      err=1
    fi
  fi
  if [[ "${RECOVER_INTERRUPTED}" -eq 1 ]]; then
    if [[ "${UNINSTALL}" -eq 1 || "${REPAIR}" -eq 1 || "${FORCE}" -eq 1 || "${DRY_RUN}" -eq 1 || "${CHECK_ONLY}" -eq 1 ]]; then
      echo "[错误] --recover-interrupted 只负责显式恢复未完成变更，不能与安装、修复、检查或卸载同时使用。" >&2
      err=1
    fi
  fi
  [[ "$err" -eq 0 ]]
}

# 在任何安装/构建之前进行的前置检查：
# - 若要求启用 verify-clients，则本机必须检测到 tailscaled 正在运行并已登录。
# - 若未满足条件，给出两种登录方式的提示并退出（避免继续安装造成误导）。
precheck_verify_clients() {
  if [[ "${VERIFY_CLIENTS_MODE}" == "off" ]]; then
    echo "[警告] 你选择了 --no-verify-clients：将不验证客户端身份，仅供测试场景使用。"
    return 0
  fi

  local active="inactive"
  # 多种环境兼容：systemd / Unix socket / 进程名
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet tailscaled 2>/dev/null; then active="active"; fi
  if [[ -S /run/tailscale/tailscaled.sock ]]; then active="active"; fi
  if [[ -S /var/run/tailscale/tailscaled.sock ]]; then active="active"; fi
  if pgrep -x tailscaled >/dev/null 2>&1; then active="active"; fi

  if [[ "${active}" != "active" ]]; then
    # 根据是否存在 systemctl 给出差异化提示
    if command -v systemctl >/dev/null 2>&1; then
      cat >&2 <<'EOT'
[阻断] 脚本默认启用 -verify-clients，但未检测到本机 tailscaled 正在运行并登录 Tailnet。

请先安装并启动 tailscaled，并完成登录（两种方式任选其一）：

1) 浏览器登录方式：
   sudo systemctl enable --now tailscaled
   sudo tailscale up     # 复制输出的登录链接，在浏览器完成授权

2) 预生成 Auth Key 方式：
   sudo systemctl enable --now tailscaled
   sudo tailscale up --authkey tskey-xxxxxxxxxxxxxxxxxxxx

完成后再重新运行本脚本；若你确需跳过校验，可使用 --no-verify-clients（仅测试）。
EOT
    else
      cat >&2 <<'EOT'
[阻断] 脚本默认启用 -verify-clients，但未检测到本机 tailscaled 正在运行并登录 Tailnet（未发现 systemd）。

请先安装并启动 tailscaled，并完成登录（不同发行版可参考以下方式，二选一）：

1) OpenRC/Alpine：
   sudo rc-update add tailscaled default
   sudo rc-service tailscaled start
   sudo tailscale up     # 或：sudo tailscale up --authkey tskey-xxxx

2) SysV/init：
   sudo service tailscaled start
   sudo tailscale up     # 或：sudo tailscale up --authkey tskey-xxxx

若仍无法使用服务管理器，可临时前台运行（仅测试）：
   sudo tailscaled --state=/var/lib/tailscale/tailscaled.state \
     --socket=/run/tailscale/tailscaled.sock
   # 另开终端执行：sudo tailscale up

完成后再重新运行本脚本；若你确需跳过校验，可使用 --no-verify-clients（仅测试）。
EOT
    fi
    exit 2
  fi
  # 进一步校验：若 tailscale CLI 可用，必须确认已登录（已分配 Tailnet IP）后再继续
  if command -v tailscale >/dev/null 2>&1; then
    local tipv4
    tipv4=$(tailscale ip -4 2>/dev/null | head -n1 || true)
    if [[ -z "${tipv4}" ]]; then
      cat >&2 <<'EOT'
[阻断] 已检测到 tailscaled 进程，但未检测到已登录的 Tailnet IP。

请先完成登录（任选其一）：
  1) 浏览器登录：
     sudo tailscale up    # 复制输出的登录链接，在浏览器完成授权

  2) 使用 Auth Key：
     sudo tailscale up --authkey tskey-xxxxxxxxxxxxxxxxxxxx

完成登录后再运行本脚本；或使用 --no-verify-clients 跳过校验（仅测试）。
EOT
      exit 2
    fi
    echo "[信息] 已检测到 tailscaled 正常且已登录（${tipv4}），将启用 -verify-clients。"
  else
    echo "[信息] 检测到 tailscaled 在运行；未找到 tailscale CLI，无法进一步验证登录态，将继续并尝试启用 -verify-clients。"
  fi
}

# 与上游 cmd/derper/cert.go 的 unsafeHostnameCharacters 一致：仅保留 [a-zA-Z0-9-.]
# manual 模式读取 <certdir>/<basename>.crt 与 <basename>.key。
derper_manual_cert_basename() {
  local host="${1:-${IP_ADDR}}"
  printf '%s' "$host" | sed 's/[^a-zA-Z0-9.-]//g'
}

derper_manual_cert_file() {
  echo "${INSTALL_DIR}/certs/$(derper_manual_cert_basename "${1:-${IP_ADDR}}").crt"
}

derper_manual_key_file() {
  echo "${INSTALL_DIR}/certs/$(derper_manual_cert_basename "${1:-${IP_ADDR}}").key"
}

# 解析磁盘上应由 derper 使用的证书 PEM（优先上游命名，兼容旧 fullchain/cert.pem）
resolve_disk_cert_pem() {
  local crt legacy
  crt=$(derper_manual_cert_file)
  if [[ -f "$crt" ]]; then
    echo "$crt"
    return 0
  fi
  for legacy in "${INSTALL_DIR}/certs/cert.pem" "${INSTALL_DIR}/certs/fullchain.pem"; do
    if [[ -f "$legacy" ]]; then
      echo "$legacy"
      return 0
    fi
  done
  return 1
}

resolve_disk_key_pem() {
  local key legacy
  key=$(derper_manual_key_file)
  if [[ -f "$key" ]]; then
    echo "$key"
    return 0
  fi
  for legacy in "${INSTALL_DIR}/certs/key.pem" "${INSTALL_DIR}/certs/privkey.pem"; do
    if [[ -f "$legacy" ]]; then
      echo "$legacy"
      return 0
    fi
  done
  return 1
}

normalize_version_tag() {
  local v="${1:-}"
  v="${v#v}"
  printf '%s' "$v"
}

# 读取已安装 derper 二进制的 tailscale.com 模块版本。
# 保留预发布和伪版本后缀；失败返回空。无 Go 时不能把 v1.104.1-rc1 截成 1.104.1。
get_installed_derper_version() {
  [[ -x "${BIN_PATH}" ]] || { echo ""; return 1; }
  local ver="" module_re version_re
  module_re='tailscale\.com(/cmd/derper)?[[:space:]]+v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?'
  version_re='v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?'
  if command -v go >/dev/null 2>&1; then
    ver=$(go version -m "${BIN_PATH}" 2>/dev/null \
      | awk '/^[[:space:]]*mod[[:space:]]+tailscale\.com([[:space:]]|$)/ {print $3; exit}')
  fi
  if [[ -z "$ver" ]]; then
    # 无 go 或 go version -m 失败时，从二进制字符串抓取完整模块版本。
    # strings 在极简环境可能缺失，回退到 grep -a。
    local blob=""
    if command -v strings >/dev/null 2>&1; then
      blob=$(strings "${BIN_PATH}" 2>/dev/null || true)
    fi
    if [[ -z "$blob" ]]; then
      blob=$(grep -a -oE "$module_re" "${BIN_PATH}" 2>/dev/null || true)
    fi
    ver=$(printf '%s\n' "$blob" \
      | grep -oE "$module_re" \
      | head -n1 \
      | grep -oE "$version_re" || true)
  fi
  # 不再用裸 semver 回退：Go 工具链版本（go1.22.6）会先被匹配，导致误判已对齐。
  normalize_version_tag "$ver"
}

go_build_cache_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    printf '%s\n' "${DERPER_GO_BUILD_CACHE_DIR:-/var/cache/derper-deploy/go-build}"
  elif [[ -n "${_tmpdir:-}" ]]; then
    printf '%s/go-build\n' "${_tmpdir}"
  else
    return 1
  fi
}

prepare_go_build_root() {
  if [[ -z "${_tmpdir:-}" || ! -d "${_tmpdir}" ]]; then
    echo "[错误] 安全临时目录未初始化，无法检查构建空间。" >&2
    return 1
  fi
  local cache_root path available min_free uid
  cache_root=$(go_build_cache_root) || return 1
  min_free="${DERPER_GO_MIN_FREE_KB:-1048576}"
  [[ "$cache_root" == /* && "$cache_root" != / && ! -L "$cache_root" ]] || {
    echo "[错误] Go 构建缓存必须为绝对路径且不能是符号链接：${cache_root}" >&2
    return 1
  }
  mkdir -p "$cache_root" || return 1
  if [[ "$(id -u)" -eq 0 ]]; then
    uid=$(stat -c %u "$cache_root" 2>/dev/null || stat -f %u "$cache_root") || return 1
    [[ "$uid" -eq 0 ]] || { echo "[错误] root 的 Go 构建缓存必须归 root 所有：${cache_root}" >&2; return 1; }
  fi
  chmod 700 "$cache_root" || return 1
  mkdir -p "$cache_root/gopath/pkg/mod" "$cache_root/cache" "${_tmpdir}/go-work" || return 1
  for path in "${_tmpdir}" "$cache_root"; do
    available=$(df -Pk "$path" 2>/dev/null | awk 'NR == 2 {print $4}')
    if [[ ! "$available" =~ ^[0-9]+$ ]] || ! _decimal_ge "$available" "$min_free"; then
      echo "[错误] Go 构建空间不足：${path} 可用=${available:-未知}KiB，至少需要 ${min_free}KiB。请清理磁盘或调整缓存位置。" >&2
      return 1
    fi
  done
}

# 使用与构建一致的模块环境解析 commit；查询失败时保守重装，不冒充已对齐。
resolve_derper_module_version() {
  command -v go >/dev/null 2>&1 || return 1
  # go list 也可能自动下载工具链；必须与构建入口共用空间和缓存安全预检。
  # 独立调用时仅创建查询临时目录，不改变调用者的 _tmpdir 或删除持久缓存。
  local _tmpdir="${_tmpdir:-}" go_build_root owns_tmp=0 rc=0
  if [[ -z "$_tmpdir" ]]; then
    _tmpdir=$(mktemp -d /var/tmp/derper-go-query.XXXXXXXXXX) || return 1
    owns_tmp=1
  fi
  if prepare_go_build_root; then
    go_build_root=$(go_build_cache_root) || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      local envs=("GO111MODULE=on" "GOTOOLCHAIN=${GOTOOLCHAIN_ARG}" "GIT_TERMINAL_PROMPT=0"
        "GOPATH=${go_build_root}/gopath" "GOMODCACHE=${go_build_root}/gopath/pkg/mod" "GOCACHE=${go_build_root}/cache"
        "GOTMPDIR=${_tmpdir}/go-work" "TMPDIR=${_tmpdir}")
      [[ -z "$GOPROXY_ARG" ]] || envs+=("GOPROXY=$GOPROXY_ARG")
      [[ -z "$GOSUMDB_ARG" ]] || envs+=("GOSUMDB=$GOSUMDB_ARG")
      _run_with_progress '解析 derper 同源版本' /dev/null 60 env "${envs[@]}" go list -m -f '{{.Version}}' "tailscale.com@$1" || rc=$?
    fi
  else
    rc=$?
  fi
  if [[ "$owns_tmp" -ne 0 ]]; then
    chmod -R u+w "$_tmpdir" 2>/dev/null || true
    if ! rm -rf "$_tmpdir"; then
      echo "[警告] 无法完全清理查询临时目录：${_tmpdir}" >&2
      [[ "$rc" -ne 0 ]] || rc=1
    fi
  fi
  return "$rc"
}

# 判断是否需要安装/重装 derper：缺失、或目标版本（非 latest）与已安装不一致。
derper_binary_needs_install() {
  [[ -z "${LOCAL_BINARY:-}" ]] || return 0
  if [[ ! -x "${BIN_PATH}" ]]; then
    return 0
  fi
  local want have
  want=$(normalize_version_tag "${DERPER_VERSION}")
  if [[ -z "$want" || "$want" == "latest" ]]; then
    return 1
  fi
  have=$(get_installed_derper_version || true)
  if [[ -z "$have" ]]; then
    echo "[提示] 无法读取已安装 derper 版本，将按目标 ${DERPER_VERSION} 重新安装以确保对齐。" >&2
    return 0
  fi
  if [[ "$have" != "$want" ]]; then
    local want_lc have_lc
    want_lc=$(printf '%s' "$want" | tr 'A-Z' 'a-z')
    have_lc=$(printf '%s' "$have" | tr 'A-Z' 'a-z')
    if [[ "$want_lc" == "$have_lc" ]]; then
      return 1
    fi
    if [[ "$want_lc" =~ ^[0-9a-f]{7,40}$ ]]; then
      # Go 伪版本只保存 12 位 revision；必须比较末尾，不能任意子串命中。
      local revision="${have_lc##*-}" canonical=""
      if [[ "$have_lc" =~ [.-][0-9]{14}-[0-9a-f]{12}$ && "$want_lc" == "$revision"* ]]; then
        return 1
      fi
      # commit 恰好是发布标签时，Go 记录规范标签而非伪版本。
      canonical=$(resolve_derper_module_version "$want_lc" || true)
      if [[ -n "$canonical" && "$(normalize_version_tag "$canonical")" == "$have" ]]; then
        return 1
      fi
    fi
    echo "[信息] 已安装 derper=${have}，目标=${want}，将重新安装以对齐版本。"
    return 0
  fi
  return 1
}

# -verify-clients 要求 derper 与 tailscaled 由同一 Git revision 构建（上游约定），
# 否则本地 API 协议可能不兼容、客户端校验异常。
# 参考上游说明：https://github.com/tailscale/tailscale/blob/main/cmd/derper/README.md
# 当用户未显式指定 derper 版本（仍为 latest）且启用了 -verify-clients 时，
# 优先对齐到本机 tailscaled 的 Git commit（真正的同源），
# 取不到 commit 时才退化为语义版本标签并给出警告。
align_derper_version_with_tailscale() {
  # 本地输入必须保持操作者固定的版本；daemon兼容性由发布前独立校核，不能改写目标后放行。
  [[ -z "${LOCAL_BINARY:-}" ]] || return 0
  [[ "${VERIFY_CLIENTS_MODE}" == "on" ]] || return 0
  [[ "${DERPER_VERSION}" == "latest" ]] || return 0
  if [[ -z "${TS_VERSION:-}" ]]; then
    echo "[提示] --verify-clients 已启用，但未检测到 tailscale 版本；将安装 derper@latest。" >&2
    echo "       -verify-clients 要求 derper 与 tailscaled 同源构建；建议用 --derper-version 显式指定与 tailscaled 一致的版本。" >&2
    return 0
  fi
  local commit=""
  commit=$(ts_commit || true)
  if [[ -n "$commit" ]]; then
    DERPER_VERSION="$commit"
    echo "[信息] --verify-clients 已启用：derper 版本自动对齐到 tailscaled 的同一 Git revision（${commit}），确保二者同源构建。"
    echo "       如需改用其他版本，请用 --derper-version 显式指定。"
  else
    DERPER_VERSION="v${TS_VERSION}"
    echo "[警告] --verify-clients 已启用，但无法读取 tailscaled 的 Git commit（tailscale version 未提供）。" >&2
    echo "       将退化为按版本标签对齐（v${TS_VERSION}）；该标签可能与本地 tailscaled 并非同一 revision。" >&2
    echo "       建议升级 tailscale，或用 --derper-version 显式指定与 tailscaled 完全一致的 revision。" >&2
  fi
}

# IPv4 地址分类：global（全局可路由）/ private / 各类保留、文档、组播等。
# 依据 IANA 特殊用途地址注册表，正式部署仅接受 global。
ipv4_address_class() {
  local ip="$1" o1 o2 o3 o4 n
  if [[ ! "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    echo "invalid"; return 0
  fi
  o1=$((10#${BASH_REMATCH[1]})); o2=$((10#${BASH_REMATCH[2]}))
  o3=$((10#${BASH_REMATCH[3]})); o4=$((10#${BASH_REMATCH[4]}))
  if (( o1 > 255 || o2 > 255 || o3 > 255 || o4 > 255 )); then
    echo "invalid"; return 0
  fi
  n=$(( (o1<<24) + (o2<<16) + (o3<<8) + o4 ))

  in_cidr() { # n, a, b, c, d, prefix
    local base=$(( ($2<<24) + ($3<<16) + ($4<<8) + $5 ))
    local mask=$(( 0xFFFFFFFF & (0xFFFFFFFF << (32 - $6)) ))
    (( ( $1 & mask ) == ( base & mask ) ))
  }

  if (( o1 == 0 )); then echo "保留（0.0.0.0/8）"
  elif in_cidr "$n" 10 0 0 0 8; then echo "私有（10.0.0.0/8）"
  elif in_cidr "$n" 100 64 0 0 10; then echo "CGNAT 保留（100.64.0.0/10）"
  elif in_cidr "$n" 127 0 0 0 8; then echo "回环（127.0.0.0/8）"
  elif in_cidr "$n" 169 254 0 0 16; then echo "链路本地（169.254.0.0/16）"
  elif in_cidr "$n" 172 16 0 0 12; then echo "私有（172.16.0.0/12）"
  elif in_cidr "$n" 192 0 0 0 24; then echo "保留（192.0.0.0/24，IETF）"
  elif in_cidr "$n" 192 0 2 0 24; then echo "文档测试（192.0.2.0/24，TEST-NET-1）"
  elif in_cidr "$n" 192 88 99 0 24; then echo "保留（192.88.99.0/24，6to4 中继）"
  elif in_cidr "$n" 192 168 0 0 16; then echo "私有（192.168.0.0/16）"
  elif in_cidr "$n" 198 18 0 0 15; then echo "保留（198.18.0.0/15，基准测试）"
  elif in_cidr "$n" 198 51 100 0 24; then echo "文档测试（198.51.100.0/24，TEST-NET-2）"
  elif in_cidr "$n" 203 0 113 0 24; then echo "文档测试（203.0.113.0/24，TEST-NET-3）"
  elif in_cidr "$n" 224 0 0 0 4; then echo "组播（224.0.0.0/4）"
  elif in_cidr "$n" 240 0 0 0 4; then echo "保留（240.0.0.0/4）"
  elif (( o1 == 255 && o2 == 255 && o3 == 255 && o4 == 255 )); then echo "广播（255.255.255.255）"
  else echo "global"; fi
}

# 无溢出的无符号十进制比较：去掉前导零后按位数再按字典序比较。
_decimal_norm() {
  local s="$1"
  while [[ "$s" == 0* && ${#s} -gt 1 ]]; do
    s="${s#0}"
  done
  printf '%s' "$s"
}

_decimal_ge() {
  local a b la lb
  a=$(_decimal_norm "$1")
  b=$(_decimal_norm "$2")
  la=${#a}; lb=${#b}
  if (( la != lb )); then
    (( la > lb ))
    return
  fi
  [[ "$a" > "$b" || "$a" == "$b" ]]
}

decimal_in_closed_range() {
  local val="$1" min="$2" max="$3"
  [[ "$val" =~ ^[0-9]+$ ]] || return 1
  _decimal_ge "$val" "$min" && _decimal_ge "$max" "$val"
}

validate_settings() {
  # 端口/天数用字符串范围比较，避免 Bash 64 位算术溢出把超大非法值折成合法小数。
  if ! decimal_in_closed_range "${DERP_PORT}" 1 65535; then
    echo "[错误] --derp-port 必须为 1-65535 的整数，当前：${DERP_PORT}" >&2
    return 1
  fi
  DERP_PORT=$(_decimal_norm "${DERP_PORT}")
  if ! decimal_in_closed_range "${STUN_PORT}" 1 65535; then
    echo "[错误] --stun-port 必须为 1-65535 的整数，当前：${STUN_PORT}" >&2
    return 1
  fi
  STUN_PORT=$(_decimal_norm "${STUN_PORT}")
  if ! decimal_in_closed_range "${CERT_DAYS}" 1 "${CERT_DAYS_MAX}"; then
    echo "[错误] --cert-days 必须为 1-${CERT_DAYS_MAX} 的整数，当前：${CERT_DAYS}" >&2
    return 1
  fi
  CERT_DAYS=$(_decimal_norm "${CERT_DAYS}")
  # IPv4 合法性校验：格式 + 每段范围 0-255
  if ! [[ "${IP_ADDR}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "[错误] 公网 IP 不合法：${IP_ADDR}" >&2
    return 1
  fi
  IFS='.' read -r o1 o2 o3 o4 <<< "${IP_ADDR}"
  for _oct in "$o1" "$o2" "$o3" "$o4"; do
    if ! [[ "$_oct" =~ ^[0-9]+$ ]]; then
      echo "[错误] 公网 IP 字段必须为数字：${IP_ADDR}" >&2
      return 1
    fi
    # 去除前导零避免 bash 八进制解析（10#强制十进制）
    local _oct_dec=$((10#$_oct))
    if (( _oct_dec < 0 || _oct_dec > 255 )); then
      echo "[错误] 公网 IP 字段超出范围（0-255）：${IP_ADDR}" >&2
      return 1
    fi
  done

  # 全局可路由校验：正式部署模式拒绝私有/保留/文档/组播等非公网地址；
  # 内网测试必须通过 --allow-non-global-ip 显式放行。
  local ip_class
  ip_class=$(ipv4_address_class "${IP_ADDR}")
  if [[ "$ip_class" != "global" ]]; then
    if [[ "${ALLOW_NON_GLOBAL_IP}" -eq 1 ]]; then
      echo "[警告] IP ${IP_ADDR} 被识别为${ip_class}地址（非全局可路由），已通过 --allow-non-global-ip 显式放行。" >&2
      echo "  DERP 服务需要公网 IP 才能被远程客户端访问；内网测试可忽略此警告。" >&2
    else
      echo "[错误] IP ${IP_ADDR} 被识别为${ip_class}地址，不是全局可路由的公网 IPv4。" >&2
      echo "  DERP 中继必须部署在公网 IP 上；若确需在内网/保留地址上测试，请显式添加 --allow-non-global-ip。" >&2
      return 1
    fi
  fi

  # Region 字段白名单校验（防止 JSON 注入）
  if [[ ! "${RUN_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "[错误] --user 仅允许合法 POSIX 用户名（小写字母/数字/下划线/连字符，且以字母或下划线开头）：${RUN_USER}" >&2
    return 1
  fi
  if [[ ! "${REGION_CODE}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "[错误] --region-code 仅允许字母、数字、连字符、下划线：${REGION_CODE}" >&2
    return 1
  fi
  if [[ ! "${REGION_NAME}" =~ ^[a-zA-Z0-9\ _-]+$ ]]; then
    echo "[错误] --region-name 仅允许字母、数字、空格、连字符、下划线：${REGION_NAME}" >&2
    return 1
  fi
  if ! [[ "${REGION_ID}" =~ ^[0-9]+$ ]]; then
    echo "[错误] --region-id 必须为正整数：${REGION_ID}" >&2
    return 1
  fi
  if ! decimal_in_closed_range "${REGION_ID}" 1 9007199254740991; then
    echo "[错误] --region-id 超出 JavaScript 安全整数范围（1–9007199254740991）：${REGION_ID}" >&2
    return 1
  fi
  REGION_ID=$(_decimal_norm "${REGION_ID}")
  # 上游约定 900-999 保留给用户自建区域（位数很少，算术安全）
  if (( 10#$REGION_ID < 900 || 10#$REGION_ID > 999 )); then
    echo "[警告] --region-id ${REGION_ID} 不在 900-999 范围；上游约定该范围保留给用户自建区域，建议使用 900-999。" >&2
  fi

  # 安全级别前置校验（避免执行完所有安装步骤后才报错）
  case "${SECURITY_LEVEL}" in
    basic|standard|paranoid) ;;
    *) echo "[错误] --security-level 必须为 basic|standard|paranoid，当前：${SECURITY_LEVEL}" >&2; return 1 ;;
  esac

  if ! decimal_in_closed_range "${TLS_CONNLIMIT:-0}" 0 "${TLS_CONNLIMIT_MAX}"; then
    echo "[错误] --tls-connlimit 必须为 0-${TLS_CONNLIMIT_MAX} 的整数，当前：${TLS_CONNLIMIT}" >&2
    return 1
  fi
  TLS_CONNLIMIT=$(_decimal_norm "${TLS_CONNLIMIT:-0}")
}

precheck_region_id_conflict() {
  if [[ -z "${IP_ADDR:-}" ]]; then
    echo "[警告] 无法确认 Region ${REGION_ID} 是否已占用：本次公网 IP 未确定。" >&2
    return 2
  fi
  if ! command -v tailscale >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    echo "[警告] 无法确认 Region ${REGION_ID} 是否已占用：需要 tailscale 与 python3。部署可继续，但合并策略前必须人工核对。" >&2
    return 2
  fi
  local map="" rc=0
  map=$(_timeout_run 10 tailscale debug derp-map 2>/dev/null) || rc=$?
  if [[ "$rc" -ne 0 || -z "$map" ]]; then
    echo "[警告] 无法确认 Region ${REGION_ID} 是否已占用：tailscale debug derp-map 读取失败。部署可继续，但合并策略前必须人工核对。" >&2
    return 2
  fi

  local map_file result="" parse_rc=0
  map_file=$(mktemp "${_tmpdir:-/tmp}/derp-map.XXXXXXXXXX") || {
    echo "[警告] 无法确认 Region ${REGION_ID} 是否已占用：无法创建临时解析文件。" >&2
    return 2
  }
  printf '%s\n' "$map" >"$map_file"
  result=$(python3 - "$map_file" "$REGION_ID" "$IP_ADDR" "$DERP_PORT" "$STUN_PORT" 2>/dev/null <<'PY'
import json
import sys

try:
    map_file, rid, host, derp_port, stun_port = sys.argv[1:6]
    with open(map_file, encoding="utf-8") as stream:
        data = json.load(stream)
    if not isinstance(data, dict):
        raise ValueError("derpMap is not an object")
    regions = data.get("Regions")
    if not isinstance(regions, dict):
        raise ValueError("Regions is not an object")
    region_key = str(int(rid))
    if region_key not in regions:
        sys.exit(0)
    region = regions[region_key]
    if not isinstance(region, dict) or not isinstance(region.get("Nodes"), list):
        raise ValueError("region Nodes is not an array")
    nodes = region["Nodes"]
    if any(not isinstance(node, dict) for node in nodes):
        raise ValueError("region node is not an object")
    if not nodes:
        sys.exit(4)

    def port(value, default):
        try:
            return int(value or default)
        except (TypeError, ValueError):
            return -1

    same_identity = len(nodes) == 1 and (
        nodes[0].get("HostName") == host
        and nodes[0].get("IPv4", host) == host
    )
    if same_identity:
        same_ports = (
            port(nodes[0].get("DERPPort"), 443) == int(derp_port)
            and port(nodes[0].get("STUNPort"), 3478) == int(stun_port)
        )
        sys.exit(0 if same_ports else 3)
    names = [str(n.get("HostName", "?")) for n in nodes if isinstance(n, dict)]
    print("Region %s 已被 %d 个节点占用：%s" % (rid, len(nodes), ", ".join(names) or "未列出节点"))
    sys.exit(1)
except (ValueError, TypeError, json.JSONDecodeError):
    sys.exit(2)
PY
) || parse_rc=$?
  rm -f "$map_file"

  case "$parse_rc" in
    0)
      echo "[信息] Region ${REGION_ID} 未发现冲突，或为本次相同的唯一节点目标。"
      return 0
      ;;
    3)
      echo "[信息] Region ${REGION_ID} 的唯一节点与本次地址相同，仅端口配置变化；允许部署，但须同步控制面 DERPPort/STUNPort。"
      return 0
      ;;
    4)
      echo "[警告] 无法确认 Region ${REGION_ID} 是否已占用：Region 已存在但 Nodes 为空，请人工核对后再合并。" >&2
      return 2
      ;;
    1)
      if [[ "${ALLOW_REGION_ID_CONFLICT:-0}" -eq 1 ]]; then
        echo "[警告] ${result}；已显式放行 RegionID 冲突。合并策略时必须保留需要共存的 Nodes，或自行承担替换后果。" >&2
        return 0
      fi
      echo "[错误] RegionID 冲突：${result}。请改用未占用的 --region-id；确需共用或替换时，先规划策略合并并显式添加 --allow-region-id-conflict。" >&2
      return 1
      ;;
    *)
      echo "[警告] 无法确认 Region ${REGION_ID} 是否已占用：derpMap 格式无法可靠解析。部署可继续，但合并策略前必须人工核对。" >&2
      return 2
      ;;
  esac
}

detect_public_ip() {
  # 自动探测公网 IP（失败则需 --ip 指定）
  if [[ -z "${IP_ADDR}" ]]; then
    echo "[信息] 正在尝试自动探测公网 IP…"
    local IP1 IP2 IP3 IP4 IP5
    # 强制 IPv4 + 超时，避免卡住或返回 IPv6
    IP1=$(curl -4 --connect-timeout 3 --max-time 5 -fsS https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' || true)
    IP2=$(dig -4 +short +time=3 +tries=1 myip.opendns.com @resolver1.opendns.com 2>/dev/null || true)
    IP3=$(curl -4 --connect-timeout 3 --max-time 5 -fsS https://api.ipify.org 2>/dev/null || true)
    IP4=$(curl -4 --connect-timeout 3 --max-time 5 -fsS https://ifconfig.co 2>/dev/null || true)
    IP5=$(curl -4 --connect-timeout 3 --max-time 5 -fsS https://icanhazip.com 2>/dev/null || true)
    IP_ADDR=${IP1:-${IP2:-${IP3:-${IP4:-${IP5:-}}}}}
  fi
  if [[ -z "${IP_ADDR}" ]]; then
    echo "[错误] 无法自动探测公网 IP，请使用 --ip 明确指定。" >&2
    return 1
  fi
  echo "[信息] 使用公网 IP：${IP_ADDR}"
}

# 健康检查/cron 优先从已部署 unit 读 hostname，避免每次打外网探测 IP。
infer_ip_from_existing_deployment() {
  [[ -z "${IP_ADDR:-}" ]] || return 0
  local content host
  content=$(read_derper_unit_content || true)
  host=$(printf '%s\n' "$content" | grep -oE -- '-hostname[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | awk '{print $2}' | head -n1 || true)
  if [[ -n "$host" ]]; then
    IP_ADDR="$host"
    echo "[信息] 从已部署 unit 读取 hostname/IP：${IP_ADDR}（跳过外网探测）"
    return 0
  fi
  return 1
}

# 健康检查按已部署 unit 恢复端口/校验/安全级别，避免 cron 只带 IP 时用默认值误报。
infer_healthcheck_settings_from_unit() {
  local content="${1-}"
  [[ -n "$content" ]] || content=$(read_derper_unit_content || true)
  [[ -n "$content" ]] || return 0

  if [[ "${DERP_PORT_EXPLICIT:-0}" -ne 1 ]]; then
    local p=""
    p=$(printf '%s\n' "$content" | grep -oE -- '-a[[:space:]]+:[0-9]+' | grep -oE '[0-9]+$' | head -n1 || true)
    [[ -n "$p" ]] || p=$(printf '%s\n' "$content" | grep -oE -- '-https-port[[:space:]]+[0-9]+' | awk '{print $2}' | head -n1 || true)
    [[ -n "$p" ]] && DERP_PORT="$p"
  fi
  if [[ "${STUN_PORT_EXPLICIT:-0}" -ne 1 ]]; then
    local s=""
    s=$(printf '%s\n' "$content" | grep -oE -- '-stun-port[[:space:]]+[0-9]+' | awk '{print $2}' | head -n1 || true)
    if [[ -n "$s" ]]; then
      STUN_PORT="$s"
    fi
  fi
  if [[ "${VERIFY_CLIENTS_EXPLICIT:-0}" -ne 1 ]]; then
    if printf '%s\n' "$content" | grep -qE -- '(^|[[:space:]])-verify-clients([[:space:]]|$)'; then
      VERIFY_CLIENTS_MODE="on"
    else
      VERIFY_CLIENTS_MODE="off"
    fi
  fi
  if [[ "${SECURITY_LEVEL_EXPLICIT:-0}" -ne 1 ]]; then
    local lvl=""
    lvl=$(printf '%s\n' "$content" | grep -oE '安全加固（级别：[a-z]+' | head -n1 | sed 's/.*级别：//' || true)
    case "$lvl" in
      basic|standard|paranoid) SECURITY_LEVEL="$lvl" ;;
    esac
  fi
}

# 长任务提示只写 stderr；命令的 stdout 与错误文件保持原样。
# 通过局部变量把显示信息传给 timeout 的等待函数，不启动额外的动画后台进程，
# 也不改写部署事务的 trap。fd 3 在重定向命令错误前保留终端输出。
_run_with_progress() {
  local _progress_label="$1" error_file="$2" limit="$3"; shift 3
  local _progress_started=$SECONDS _progress_tty=0 rc=0
  if [[ -t 2 && "${TERM:-dumb}" != dumb && "${OUTPUT_FORMAT:-text}" != json && "${DERPMAP_ONLY:-0}" != 1 ]]; then
    _progress_tty=1
  fi
  printf '[进行中] %s（最长 %s 秒）\n' "$_progress_label" "$limit" >&2
  _timeout_run "$limit" "$@" 3>&2 2>"$error_file" || rc=$?
  if [[ "$rc" == 0 ]]; then
    printf '[完成] %s（用时 %s 秒）\n' "$_progress_label" "$((SECONDS - _progress_started))" >&2
  else
    printf '[未完成] %s（退出码 %s，用时 %s 秒）\n' "$_progress_label" "$rc" "$((SECONDS - _progress_started))" >&2
  fi
  return "$rc"
}

_wait_with_progress() {
  local child="$1" dots='.' rc=0
  if [[ "${_progress_tty:-0}" != 1 ]]; then
    wait "$child"
    return $?
  fi
  while kill -0 "$child" 2>/dev/null; do
    printf '\r\033[2K[进行中] %s%-3s 已等待 %s 秒' "$_progress_label" "$dots" "$((SECONDS - _progress_started))" >&3
    case "$dots" in ... ) dots='.' ;; * ) dots="${dots}." ;; esac
    sleep 1
  done
  wait "$child" || rc=$?
  printf '\r\033[2K' >&3
  return "$rc"
}

# 兼容 timeout：优先使用系统 timeout，缺失时用后台进程模拟。
# killer 必须重定向 stdout/stderr 并关闭进度 fd 3：否则在 $( ) 中调用时，命令提前结束后
# kill killer 只杀掉子 shell，其子进程 sleep 被孤儿化并继续持有管道写端，
# 调用方会阻塞满整个超时（无 timeout 主机每次模块查询必卡 60 秒）。
_timeout_run() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=1 "$secs" "$@" &
    local timed_pid=$! timed_rc=0
    _wait_with_progress "$timed_pid" || timed_rc=$?
    # timeout默认建立独立进程组；主进程提前响应TERM时，也清理仍留在该组中的子进程。
    kill -KILL -- "-$timed_pid" 2>/dev/null || true
    return "$timed_rc"
  else
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null || exit 0; sleep 1; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 3>&- &
    local killer=$!
    local rc=0
    _wait_with_progress "$pid" 2>/dev/null || rc=$?
    kill "$killer" 2>/dev/null || true
    wait "$killer" 2>/dev/null || true
    return $rc
  fi
}

# 从 `go version` 输出解析工具链版本号（如 1.18.1）。
parse_go_version() {
  printf '%s' "${1:-}" | grep -oE 'go[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 | sed 's/^go//'
}

# 当前 PATH 中的 go 是否满足 MIN_GO_VERSION（GOTOOLCHAIN=auto 的下限）。
go_toolchain_meets_min() {
  local have
  have=$(parse_go_version "$(go version 2>/dev/null || true)")
  [[ -n "$have" ]] && ver_ge "$have" "${MIN_GO_VERSION}"
}

# 版本比较：ver_ge A B => A >= B ?
ver_ge() {
  if sort -V </dev/null &>/dev/null; then
    local a="$1" b="$2"
    [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" == "$a" ]]
  else
    # 纯 bash 语义化版本逐段数字比较（修复字典序 "1.10" < "1.9" 的问题）
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

ts_version() {
  (tailscale version 2>/dev/null | head -n1 | sed -E 's/[^0-9\.].*$//' || true)
}

# 读取本机 tailscaled 的 Git commit（tailscale version 输出 "tailscale commit: <hash>"；
# 标准构建中 CLI 与 tailscaled 同源，该字段即 tailscaled 的 revision）。
# 上游 -verify-clients 要求 derper 与 tailscaled 来自同一 Git revision，而非仅版本号相同。
ts_commit() {
  tailscale version 2>/dev/null \
    | awk '/tailscale commit:/ {print $3; exit}' \
    | grep -E '^[0-9a-f]{7,40}$' || true
}

# 当前 SSH 传输是否走 Tailnet（含普通 OpenSSH；不表示启用了 Tailscale SSH）。
# 本脚本不调用 tailscale ssh、不启用 --ssh，也不修改已有 SSH 服务或 RunSSH 设置。
ssh_session_via_tailscale() {
  [[ -n "${SSH_CONNECTION:-}" ]] || return 1
  local src
  src=$(awk '{print $1}' <<<"${SSH_CONNECTION}")
  [[ "$src" == 100.* || "$src" == fd7a:115c:a1e0:* ]]
}

# 重启 tailscaled.socket 以使 drop-in 生效。经 Tailnet 传输的 OpenSSH 也可能受影响，默认跳过。
restart_tailscaled_socket_unit() {
  if ssh_session_via_tailscale; then
    echo "[警告] 检测到当前 SSH 连接可能经由 Tailscale（${SSH_CONNECTION%% *}）。" >&2
    echo "  重启 tailscaled.socket 将断开此连接，可能导致脚本中断和服务器不可达。" >&2
    if [[ "${NON_INTERACTIVE:-0}" -eq 1 ]]; then
      echo "[跳过] 非交互模式下跳过 tailscaled.socket 重启；drop-in 已写入，请在非 Tailscale 会话执行：systemctl restart tailscaled.socket" >&2
      return 1
    fi
    local confirm=""
    if ! read -r -p "  是否确认重启 tailscaled.socket？(yes/no): " confirm; then
      echo "[跳过] 输入已结束，跳过 tailscaled.socket 重启。" >&2
      return 1
    fi
    if [[ "$confirm" != "yes" ]]; then
      echo "[跳过] 已取消 tailscaled.socket 重启。" >&2
      return 1
    fi
  fi
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl daemon-reload 2>/dev/null || true
  systemctl restart tailscaled.socket 2>/dev/null
}

check_tailscale_status() {
  TS_INSTALLED=0; TS_RUNNING=0; TS_VERSION=""; TS_VER_OK=0
  if command -v tailscale >/dev/null 2>&1; then
    TS_INSTALLED=1
    TS_VERSION=$(ts_version || true)
    if [[ -n "$TS_VERSION" ]] && ver_ge "$TS_VERSION" "$REQUIRED_TS_VER"; then
      TS_VER_OK=1
    fi
  fi
  local active="inactive"
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet tailscaled 2>/dev/null; then active="active"; fi
  if [[ -S /run/tailscale/tailscaled.sock ]] || [[ -S /var/run/tailscale/tailscaled.sock ]]; then active="active"; fi
  if pgrep -x tailscaled >/dev/null 2>&1; then active="active"; fi
  [[ "$active" == "active" ]] && TS_RUNNING=1 || TS_RUNNING=0
  TS_AUTH_UNKNOWN=0
  TS_LOCALAPI_OK=0
  
  # 版本检查提示（非阻断）
  if [[ "${TS_INSTALLED}" -eq 1 && "${TS_VER_OK}" -eq 0 && -n "${TS_VERSION}" ]]; then
    cat >&2 <<EOT

[建议] 检测到 Tailscale 版本较旧
  当前版本：${TS_VERSION}
  推荐版本：>= ${REQUIRED_TS_VER}
  
  虽然不影响基本功能，但建议升级以获得最佳体验和安全性：
    sudo tailscale update
  
  或访问官网手动升级：
    https://tailscale.com/download

  此提示不会阻止部署，脚本将继续执行...

EOT
    sleep 2  # 给用户时间看到提示
  fi
}

get_derper_unit_path() {
  if [[ -f "${SERVICE_PATH}" ]]; then
    echo "${SERVICE_PATH}"; return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl show -p FragmentPath derper 2>/dev/null | awk -F= '/FragmentPath=/ {print $2}'
    return 0
  fi
  echo ""; return 0
}

read_derper_unit_content() {
  local unit
  unit=$(get_derper_unit_path)
  if [[ -n "$unit" && -f "$unit" ]]; then
    cat "$unit" 2>/dev/null || true
  elif command -v systemctl >/dev/null 2>&1; then
    systemctl cat derper 2>/dev/null || true
  fi
}

check_ports_status() {
  PORT_TLS_OK=0; PORT_STUN_OK=0
  PORT_CHECK_UNKNOWN=0; PORT_OWNER_DATA_AVAILABLE=0
  local derp_port stun_port
  local tcp_rows='' udp_rows=''
  derp_port=$(_decimal_norm "${DERP_PORT}")
  stun_port=$(_decimal_norm "${STUN_PORT}")
  if command -v ss >/dev/null 2>&1; then
    tcp_rows=$(ss -ltnp 2>/dev/null) || PORT_CHECK_UNKNOWN=1
    udp_rows=$(ss -lunp 2>/dev/null) || PORT_CHECK_UNKNOWN=1
  elif command -v netstat >/dev/null 2>&1; then
    tcp_rows=$(netstat -ltnp 2>/dev/null) || PORT_CHECK_UNKNOWN=1
    udp_rows=$(netstat -lunp 2>/dev/null) || PORT_CHECK_UNKNOWN=1
  else
    PORT_CHECK_UNKNOWN=1
  fi
  tcp_rows=$(printf '%s\n' "$tcp_rows" | grep -E ":${derp_port}([^0-9]|$)" || true)
  udp_rows=$(printf '%s\n' "$udp_rows" | grep -E ":${stun_port}([^0-9]|$)" || true)
  [[ -z "$tcp_rows" ]] || PORT_TLS_OK=1
  [[ -z "$udp_rows" ]] || PORT_STUN_OK=1
  if printf '%s\n' "$tcp_rows" | grep -qE 'pid=[0-9]+|[0-9]+/' && printf '%s\n' "$udp_rows" | grep -qE 'pid=[0-9]+|[0-9]+/'; then PORT_OWNER_DATA_AVAILABLE=1; fi
}

regex_escape() {
  printf '%s' "$1" | sed -e 's/[][\/.^$*+?{}()|]/\\&/g'
}

# 按逗号拆开 SAN 项后做精确字符串比对，避免 3.4.5.6 命中 13.4.5.6 这类子串。
cert_text_san_has_ip() {
  local text="$1" want="$2" item ip
  [[ -n "$text" && -n "$want" ]] || return 1
  while IFS= read -r item; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "$item" ]] || continue
    case "$item" in
      "IP Address:"*) ip="${item#IP Address:}" ;;
      "IP:"*) ip="${item#IP:}" ;;
      *) continue ;;
    esac
    ip="${ip#"${ip%%[![:space:]]*}"}"
    ip="${ip%"${ip##*[![:space:]]}"}"
    [[ "$ip" == "$want" ]] && return 0
  done < <(printf '%s\n' "$text" | tr ',' '\n')
  return 1
}

check_pure_ip_from_unit() {
  PURE_IP_OK=0
  local content="$1"
  [[ -z "$content" ]] && PURE_IP_OK=0 && return 0
  echo "$content" | grep -E -- '-hostname[[:space:]]+([0-9]{1,3}\.){3}[0-9]{1,3}' >/dev/null 2>&1 || return 0
  echo "$content" | grep -qE -- '-certmode[[:space:]]+manual' || return 0
  echo "$content" | grep -q -- '-certdir[[:space:]]' || return 0
  echo "$content" | grep -qE -- '-http-port[[:space:]]+-1' || return 0
  if echo "$content" | grep -qE -- '-https-port[[:space:]]+[0-9]'; then :; else
    echo "$content" | grep -qE -- '-a[[:space:]]+:[0-9]' || return 0
  fi
  echo "$content" | grep -q -- '-stun' || return 0
  PURE_IP_OK=1
}

unit_matches_desired_config() {
  local content="$1"
  [[ -n "$content" && -n "${IP_ADDR}" ]] || return 1

  local ip_re certdir_re config_re run_user_re
  ip_re=$(regex_escape "$IP_ADDR")
  certdir_re=$(regex_escape "${INSTALL_DIR}/certs")
  config_re=$(regex_escape "$(derper_config_path)")
  run_user_re=$(regex_escape "$RUN_USER")

  echo "$content" | grep -qE -- "-hostname[[:space:]]+${ip_re}([[:space:]]|$)" || return 1
  echo "$content" | grep -qE -- '-certmode[[:space:]]+manual([[:space:]]|$)' || return 1
  echo "$content" | grep -qE -- "-certdir[[:space:]]+${certdir_re}([[:space:]]|$)" || return 1
  echo "$content" | grep -qE -- '-http-port[[:space:]]+-1([[:space:]]|$)' || return 1
  echo "$content" | grep -qE -- "-c[[:space:]]+${config_re}([[:space:]]|$)" || return 1

  if ! echo "$content" | grep -qE -- "(-a[[:space:]]+:${DERP_PORT}|-https-port[[:space:]]+${DERP_PORT})([[:space:]]|$)"; then
    return 1
  fi

  echo "$content" | grep -qE -- '(^|[[:space:]])-stun([[:space:]]|$)' || return 1
  if echo "$content" | grep -qE -- '-stun-port[[:space:]]+[0-9]'; then
    echo "$content" | grep -qE -- "-stun-port[[:space:]]+${STUN_PORT}([[:space:]]|$)" || return 1
  elif [[ "${STUN_PORT}" != "3478" ]]; then
    return 1
  fi

  case "${VERIFY_CLIENTS_MODE}" in
    on)
      echo "$content" | grep -qE -- '(^|[[:space:]])-verify-clients([[:space:]]|$)' || return 1
      if derper_supports_socket_flag; then
        # 不仅要求存在 -socket，还必须与本机实际探测到的 socket 路径一致，
        # 否则错误的 socket 路径会被误判为"配置一致"，verify-clients 静默失效。
        local expected_sock sock_re
        expected_sock=$(expected_tailscaled_socket)
        sock_re=$(regex_escape "$expected_sock")
        echo "$content" | grep -qE -- "(^|[[:space:]])-socket[[:space:]]+${sock_re}([[:space:]]|$)" || return 1
      fi
      ;;
    off) ! echo "$content" | grep -qE -- '(^|[[:space:]])-verify-clients([[:space:]]|$)' || return 1 ;;
  esac

  echo "$content" | grep -qE "^User=${run_user_re}$" || return 1
  # 安全级别：注释标记必须匹配；paranoid 还需核对 MemoryDenyWriteExecute，
  # 若已主动降级则注释中应带“已禁用 MemoryDenyWriteExecute”标记。
  case "${SECURITY_LEVEL}" in
    paranoid)
      if echo "$content" | grep -qF "# 安全加固（级别：paranoid；已禁用 MemoryDenyWriteExecute）"; then
        if echo "$content" | grep -qE '^MemoryDenyWriteExecute='; then
          return 1
        fi
      elif echo "$content" | grep -qF "# 安全加固（级别：paranoid）"; then
        echo "$content" | grep -qE '^MemoryDenyWriteExecute=true$' || return 1
      else
        return 1
      fi
      ;;
    *)
      echo "$content" | grep -qF "# 安全加固（级别：${SECURITY_LEVEL}）" || return 1
      ;;
  esac
  return 0
}

# 判断监听端口是否属于当前 derper 服务（核对 MainPID，避免“他人占用同端口”误判）。
current_derper_owns_ports() {
  if [[ "${CURRENT_DERPER_OWNS_PORTS:-0}" -eq 1 ]]; then
    return 0
  fi
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl is-active --quiet derper 2>/dev/null || return 1
  [[ "${PORT_TLS_OK:-0}" -eq 1 && "${PORT_STUN_OK:-0}" -eq 1 ]] || return 1

  local main_pid
  main_pid=$(systemctl show -p MainPID --value derper 2>/dev/null || echo "0")
  if [[ -z "$main_pid" || "$main_pid" == "0" ]]; then
    return 1
  fi

  local listeners=""
  if command -v ss >/dev/null 2>&1; then
    listeners=$(ss -tulnp 2>/dev/null || true)
  elif command -v netstat >/dev/null 2>&1; then
    listeners=$(netstat -tulnp 2>/dev/null || true)
  else
    # 无 ss/netstat 时退化为“服务 active + 端口已监听”
    CURRENT_DERPER_OWNS_PORTS=1
    return 0
  fi

  echo "$listeners" | listening_port_lines_stdin tcp "${DERP_PORT}" | listener_pid_field_matches "$main_pid" || return 1
  echo "$listeners" | listening_port_lines_stdin udp "${STUN_PORT}" | listener_pid_field_matches "$main_pid" || return 1

  CURRENT_DERPER_OWNS_PORTS=1
  return 0
}

check_derper_status() {
  DERPER_BIN=0; DERPER_SERVICE_PRESENT=0; DERPER_RUNNING=0; PURE_IP_OK=0
  DESIRED_CONFIG_OK=0; DERPER_VERIFY_CLIENTS_EFFECTIVE=0; CURRENT_DERPER_OWNS_PORTS=0
  if [[ -x "${BIN_PATH}" ]] || command -v derper >/dev/null 2>&1; then DERPER_BIN=1; fi
  local unit_path; unit_path=$(get_derper_unit_path)
  [[ -n "$unit_path" && -f "$unit_path" ]] && DERPER_SERVICE_PRESENT=1
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet derper 2>/dev/null; then DERPER_RUNNING=1; fi
  if [[ $DERPER_RUNNING -eq 0 ]] && pgrep -x derper >/dev/null 2>&1; then DERPER_RUNNING=1; fi
  local content; content=$(read_derper_unit_content || true)
  check_pure_ip_from_unit "$content"
  if echo "$content" | grep -qE -- '(^|[[:space:]])-verify-clients([[:space:]]|$)'; then
    DERPER_VERIFY_CLIENTS_EFFECTIVE=1
  fi
  if unit_matches_desired_config "$content"; then
    DESIRED_CONFIG_OK=1
  fi
  check_ports_status
  current_derper_owns_ports || true
  note_tailscaled_auth_visibility
}

# 探测 tailscaled LocalAPI 连通性与 HTTP 状态码
probe_tailscaled_localapi() {
  local sock="$1" http_code=""
  if command -v curl >/dev/null 2>&1; then
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 --unix-socket "$sock" "http://local-tailscaled.sock/localapi/v0/status" 2>/dev/null || echo "")
  elif command -v python3 >/dev/null 2>&1; then
    http_code=$(python3 -c '
import socket, sys
sockpath = sys.argv[1]
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(sockpath)
    s.sendall(b"GET /localapi/v0/status HTTP/1.1\r\nHost: local-tailscaled.sock\r\n\r\n")
    data = s.recv(1024).decode("latin1", "replace")
    parts = data.split()
    if len(parts) > 1:
        print(parts[1])
except Exception:
    pass
' "$sock" 2>/dev/null || echo "")
  fi
  printf '%s\n' "$http_code"
}

# 已部署 unit 中的 User=（无 unit 或未声明时输出空）。
derper_unit_run_user() {
  read_derper_unit_content 2>/dev/null \
    | awk -F= '/^[[:space:]]*User=/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' || true
}

# 以指定用户身份向 LocalAPI 发起与调用者相同的状态请求。
# 能执行探测时输出 HTTP 状态码并返回 0（000 表示以该用户无法连接 socket）；
# 无法切换身份返回 1；没有可用的探测工具返回 2。
probe_localapi_as_user() {
  local user="$1" sock="$2" code=""
  local -a runner
  if running_as_root && command -v runuser >/dev/null 2>&1; then
    runner=(runuser -u "$user" --)
  elif command -v sudo >/dev/null 2>&1; then
    runner=(sudo -n -u "$user" --)
  else
    return 1
  fi
  if command -v curl >/dev/null 2>&1; then
    code=$("${runner[@]}" curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
      --unix-socket "$sock" "http://local-tailscaled.sock/localapi/v0/status" 2>/dev/null || true)
  elif command -v python3 >/dev/null 2>&1; then
    code=$("${runner[@]}" python3 -c '
import socket, sys
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(sys.argv[1])
    s.sendall(b"GET /localapi/v0/status HTTP/1.1\r\nHost: local-tailscaled.sock\r\n\r\n")
    parts = s.recv(1024).decode("latin1", "replace").split()
    print(parts[1] if len(parts) > 1 else "000")
except Exception:
    print("000")
' "$sock" 2>/dev/null || true)
  else
    return 2
  fi
  # 空输出说明没能真正以该用户执行请求，不能据此判断访问权限。
  [[ -n "$code" ]] || return 2
  printf '%s\n' "$code"
  return 0
}

# 以指定用户实际检查 socket 能否读写：0 可读写，1 确认不可读写，2 无法确认。
# 用 sh 包装以区分“确实不可读写”和“身份切换本身失败”。
socket_rw_as_user() {
  local user="$1" sock="$2" out=""
  [[ -S "$sock" ]] || return 1
  local -a runner
  if running_as_root && command -v runuser >/dev/null 2>&1; then
    runner=(runuser -u "$user" --)
  elif command -v sudo >/dev/null 2>&1; then
    runner=(sudo -n -u "$user" --)
  else
    return 2
  fi
  out=$("${runner[@]}" sh -c 'test -r "$1" && test -w "$1" && printf RW || printf NO' sh "$sock" 2>/dev/null || true)
  case "$out" in
    RW) return 0 ;;
    NO) return 1 ;;
    *) return 2 ;;
  esac
}

# 判断 derper 服务用户能否使用 LocalAPI：0 可以，1 确认不可，2 无法确认。
# 服务用户为空或与当前调用者相同时，调用者自身的判断已足够。
# 属主/权限位只能说明 socket 能否读写，无法证明 LocalAPI 接受该身份
# （属主正确但 mode 000，或 socket 可读写而 LocalAPI 按 peer 身份返回 401/403）。
derper_user_socket_access() {
  local user="$1" sock="$2" code="" probe_rc=0 rw_rc=0
  [[ -n "$user" ]] || return 0
  if [[ "$user" == "$(id -un 2>/dev/null || true)" ]]; then return 0; fi
  # 用户不存在时 systemd 也无法启动服务，视为确认不可访问
  id "$user" >/dev/null 2>&1 || return 1
  code=$(probe_localapi_as_user "$user" "$sock" 2>/dev/null) || probe_rc=$?
  if [[ "$probe_rc" -eq 0 ]]; then
    case "$code" in
      2[0-9][0-9]) return 0 ;;
      000|'') return 1 ;;
      401|403) return 1 ;;
      *) return 2 ;;
    esac
  fi
  # 无法以服务用户身份发起请求：只有实际确认连 socket 都不可读写时才报告
  # 确认不可；能读写时 LocalAPI 是否接受该身份仍然未知。
  socket_rw_as_user "$user" "$sock" || rw_rc=$?
  if [[ "$rw_rc" -eq 1 ]]; then return 1; fi
  return 2
}

# verify-clients 开启时，区分 tailscaled 已停止、LocalAPI 明确拒绝和当前身份无法确认。
note_tailscaled_auth_visibility() {
  TS_AUTH_UNKNOWN=0
  TS_LOCALAPI_OK=0
  [[ "${DERPER_VERIFY_CLIENTS_EFFECTIVE:-0}" -eq 1 ]] || return 0
  if [[ "${TS_RUNNING:-0}" -ne 1 ]]; then
    return 0
  fi
  local sock
  sock=$(expected_tailscaled_socket)
  if [[ ! -S "$sock" || ! -r "$sock" || ! -w "$sock" ]]; then
    TS_AUTH_UNKNOWN=1
    return 0
  fi
  local http_code
  http_code=$(probe_tailscaled_localapi "$sock")
  if [[ "$http_code" =~ ^2[0-9]{2}$ ]]; then
    # 调用者（常为 root）能访问不代表 derper 服务用户也能访问：按 unit 的 User= 实际请求。
    local svc_user access_rc=0
    svc_user=$(derper_unit_run_user)
    derper_user_socket_access "$svc_user" "$sock" || access_rc=$?
    case "$access_rc" in
      0) TS_LOCALAPI_OK=1; TS_AUTH_UNKNOWN=0 ;;
      1)
        TS_LOCALAPI_OK=0
        TS_AUTH_UNKNOWN=0
        echo "[警告] derper 服务用户 ${svc_user} 无法使用 tailscaled LocalAPI：${sock}（调用者可访问不代表服务可用）。" >&2
        ;;
      *) TS_LOCALAPI_OK=0; TS_AUTH_UNKNOWN=1 ;;
    esac
  elif [[ "$http_code" == "403" || "$http_code" == "401" ]]; then
    TS_LOCALAPI_OK=0
    TS_AUTH_UNKNOWN=0
  else
    TS_LOCALAPI_OK=0
    TS_AUTH_UNKNOWN=1
  fi
}

# 0 公钥一致，1 确认不匹配，2 无法读取或无法解析（未知，不是坏证书）。
cert_keypair_matches() {
  local cert="$1" key="$2" cpub kpub
  [[ -r "$cert" && -r "$key" ]] || return 2
  cpub=$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null) || return 2
  kpub=$(openssl pkey -in "$key" -pubout 2>/dev/null) || return 2
  [[ -n "$cpub" && "$cpub" == "$kpub" ]]
}

check_cert_status() {
  CERT_PRESENT=0; CERT_SAN_MATCH=0; CERT_EXPIRY_OK=0; CERT_NAMING_OK=0
  CERT_KEY_MATCH=1; CERT_CHECK_UNKNOWN=0
  local cert_dir="${INSTALL_DIR}/certs"
  if [[ -e "$cert_dir" && ( ! -r "$cert_dir" || ! -x "$cert_dir" ) ]]; then
    CERT_CHECK_UNKNOWN=1
    return 0
  fi
  local cert_pem key_pem
  cert_pem=$(resolve_disk_cert_pem 2>/dev/null || true)
  key_pem=$(resolve_disk_key_pem 2>/dev/null || true)
  if [[ -n "$cert_pem" && -n "$key_pem" && -e "$cert_pem" && -e "$key_pem" ]]; then
    if [[ ! -r "$cert_pem" || ! -r "$key_pem" ]]; then
      CERT_CHECK_UNKNOWN=1
      return 0
    fi
    CERT_PRESENT=1
    # 上游 manual 模式固定读取 <hostname>.crt/.key；旧命名视为需迁移
    if [[ -f "$(derper_manual_cert_file)" && -f "$(derper_manual_key_file)" ]]; then
      CERT_NAMING_OK=1
    fi
    if command -v openssl >/dev/null 2>&1; then
      local san_text="" match_rc=0
      san_text=$(openssl x509 -in "$cert_pem" -noout -ext subjectAltName 2>/dev/null || true)
      [[ -n "$san_text" ]] || san_text=$(openssl x509 -in "$cert_pem" -noout -text 2>/dev/null || true)
      if cert_text_san_has_ip "$san_text" "$IP_ADDR"; then
        CERT_SAN_MATCH=1
      fi
      if openssl x509 -checkend $((30*24*3600)) -in "$cert_pem" -noout >/dev/null 2>&1; then
        CERT_EXPIRY_OK=1
      fi
      cert_keypair_matches "$cert_pem" "$key_pem" || match_rc=$?
      if [[ "$match_rc" -eq 2 ]]; then
        CERT_CHECK_UNKNOWN=1
      elif [[ "$match_rc" -eq 0 ]]; then
        CERT_KEY_MATCH=1
      else
        CERT_KEY_MATCH=0
      fi
    fi
  fi
}

# 计算证书剩余天数（失败返回空）
cert_days_remaining() {
  command -v openssl >/dev/null 2>&1 || { echo ""; return 0; }
  local cert_pem raw ts_now ts_end
  cert_pem=$(resolve_disk_cert_pem 2>/dev/null || true)
  [[ -n "$cert_pem" && -f "$cert_pem" ]] || { echo ""; return 0; }
  raw=$(openssl x509 -in "$cert_pem" -noout -enddate 2>/dev/null | awk -F= '{print $2}') || true
  [[ -n "$raw" ]] || { echo ""; return 0; }
  ts_now=$(date +%s)
  # GNU date
  if ts_end=$(LC_ALL=C date -d "$raw" +%s 2>/dev/null); then
    :
  else
    # BSD date 兼容（较少见于本脚本目标环境）
    ts_end=$(LC_ALL=C date -j -f "%b %d %T %Y %Z" "$raw" +%s 2>/dev/null || echo "")
  fi
  [[ -n "$ts_end" ]] || { echo ""; return 0; }
  echo $(( (ts_end - ts_now) / 86400 ))
}

cert_not_after() {
  command -v openssl >/dev/null 2>&1 || return 0
  local cert_pem
  cert_pem=$(resolve_disk_cert_pem 2>/dev/null || true)
  [[ -n "$cert_pem" && -f "$cert_pem" ]] || return 0
  openssl x509 -in "$cert_pem" -noout -enddate 2>/dev/null | awk -F= '{print $2}'
}

install_deps() {
  # 按需安装：仅在缺少必要命令时才访问包管理器，避免无谓的网络访问
  local need_pkgs=()
  # 基础必需：curl、openssl、git（go 的获取在 ensure_go 内部处理）
  command -v curl >/dev/null 2>&1     || need_pkgs+=(curl)
  command -v openssl >/dev/null 2>&1  || need_pkgs+=(openssl)
  command -v git >/dev/null 2>&1      || need_pkgs+=(git)
  # tar 是 ensure_go 兜底安装 Go 官方 tarball 的必要工具
  command -v tar >/dev/null 2>&1      || need_pkgs+=(tar)
  # 可选但常用：nc/ss，用于自检；缺失不强制
  if ! command -v nc >/dev/null 2>&1; then
    if command -v apt >/dev/null 2>&1; then need_pkgs+=(netcat-openbsd);
    elif command -v dnf >/dev/null 2>&1; then need_pkgs+=(nmap-ncat);
    elif command -v yum >/dev/null 2>&1; then need_pkgs+=(nmap-ncat);
    fi
  fi
  if ! command -v ss >/dev/null 2>&1; then
    if command -v apt >/dev/null 2>&1; then need_pkgs+=(iproute2);
    elif command -v dnf >/dev/null 2>&1; then need_pkgs+=(iproute);
    elif command -v yum >/dev/null 2>&1; then need_pkgs+=(iproute);
    fi
  fi

  if [[ ${#need_pkgs[@]} -eq 0 ]]; then
    echo "[信息] 依赖已就绪，跳过安装。"
    return 0
  fi

  echo "[步骤] 按需安装依赖：${need_pkgs[*]} …"
  local install_failed=0
  if command -v apt >/dev/null 2>&1; then
    if ! DEBIAN_FRONTEND=noninteractive apt update -y 2>"${_tmpdir}/apt_update.err"; then
      echo "[警告] apt update 失败，可能影响依赖安装" >&2
      sed -n '1,20p' "${_tmpdir}/apt_update.err" >&2 || true
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt install -y "${need_pkgs[@]}" 2>"${_tmpdir}/apt_install.err"; then
      install_failed=1
    fi
  elif command -v dnf >/dev/null 2>&1; then
    if ! dnf install -y "${need_pkgs[@]}" 2>"${_tmpdir}/dnf_install.err"; then
      install_failed=1
    fi
  elif command -v yum >/dev/null 2>&1; then
    if ! yum install -y "${need_pkgs[@]}" 2>"${_tmpdir}/yum_install.err"; then
      install_failed=1
    fi
  else
    echo "[警告] 未检测到常见包管理器（apt/dnf/yum），请手动安装以下依赖：" >&2
    echo "  ${need_pkgs[*]}" >&2
    install_failed=1
  fi
  
  if [[ $install_failed -eq 1 ]]; then
    echo "[警告] 依赖安装可能失败，缺少的包：${need_pkgs[*]}" >&2
    echo "  请手动安装后重新运行脚本，或检查网络/软件源配置。" >&2
    # 不中止，继续尝试（某些依赖非强制）
  fi
  
  if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates >/dev/null 2>&1 || true
  elif command -v update-ca-trust >/dev/null 2>&1; then
    update-ca-trust extract >/dev/null 2>&1 || true
  fi
}

# 解析 GOPROXY 列表，跳过 direct/off，供连通性预检使用。
goproxy_probe_spec() {
  printf '%s\n' "${GOPROXY_ARG:-${GOPROXY:-https://proxy.golang.org,direct}}"
}

goproxy_probe_targets() {
  local spec part
  spec=$(goproxy_probe_spec)
  local IFS=','
  for part in $spec; do
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"
    [[ -n "$part" && "$part" != "direct" && "$part" != "off" ]] || continue
    printf '%s\n' "$part"
  done
}

goproxy_spec_allows_direct() {
  local spec part
  spec=$(goproxy_probe_spec)
  local IFS=','
  for part in $spec; do
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"
    [[ "$part" == "direct" ]] && return 0
  done
  return 1
}

probe_http_url() {
  local url="$1"
  curl --connect-timeout 5 --max-time 5 -I -fsS -o /dev/null "$url" 2>/dev/null \
    || curl --connect-timeout 5 --max-time 5 -fsS -o /dev/null "$url" 2>/dev/null
}

# 构建前探测模块代理；失败立即提示 --goproxy，不自动切换第三方代理。
# GOPROXY 含 direct 时，代理全不可达仍交由 Go 直连，避免误杀 ,direct 回退。
precheck_go_network() {
  local target any=0
  while IFS= read -r target; do
    any=1
    if probe_http_url "$target"; then
      echo "[信息] 模块代理可达：${target}"
      return 0
    fi
    echo "[警告] 无法连通模块代理：${target}" >&2
  done < <(goproxy_probe_targets)
  if [[ "$any" -eq 0 ]]; then
    echo "[信息] GOPROXY 为 direct/off，跳过代理预检。"
    return 0
  fi
  if goproxy_spec_allows_direct; then
    echo "[警告] 模块代理均不可达，GOPROXY 含 direct，将交由 Go 直连模块源。若直连也失败，请显式指定 --goproxy。" >&2
    return 0
  fi
  echo "[错误] Go 模块代理不可达。国内网络请显式使用 --goproxy https://goproxy.cn,direct；脚本不会自动切换第三方代理或关闭 GOSUMDB。" >&2
  return 1
}

precheck_go_download() {
  if probe_http_url "https://go.dev/dl/"; then
    return 0
  fi
  echo "[错误] 无法连通 https://go.dev/dl/ ，无法下载官方 Go 工具链。请检查网络，或预先安装 Go >= ${MIN_GO_VERSION}。" >&2
  return 1
}

# 确保系统有足够新的 Go（>= MIN_GO_VERSION）。发行版包经常偏旧，GOTOOLCHAIN=auto 在 1.21 之前不可用。
ensure_go() {
  if go_toolchain_meets_min; then
    echo "[信息] 已检测到 Go：$(go version 2>/dev/null)"
    return 0
  fi
  if command -v go >/dev/null 2>&1; then
    echo "[警告] 已安装 Go 版本过低（$(go version 2>/dev/null)），需要 >= ${MIN_GO_VERSION}（GOTOOLCHAIN=auto 在此之前不可用）。将安装官方工具链 ${GO_VERSION}。" >&2
  else
    echo "[步骤] 未检测到 go，尝试通过系统包管理器安装 golang-go…"
    if command -v apt >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt install -y golang-go || true
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y golang || true
    elif command -v yum >/dev/null 2>&1; then
      yum install -y golang || true
    fi
    if go_toolchain_meets_min; then
      echo "[信息] Go 安装完成：$(go version 2>/dev/null)"
      return 0
    fi
    if command -v go >/dev/null 2>&1; then
      echo "[警告] 发行版 Go 仍低于 ${MIN_GO_VERSION}（$(go version 2>/dev/null)），改为安装官方工具链 ${GO_VERSION}。" >&2
    fi
  fi
  # 兜底：按架构安装官方二进制（最新稳定工具链可再由 GOTOOLCHAIN 自动拉取）。
  local arch os url tarball sha256_expected
  os="linux"
  case "$(uname -m)" in
    x86_64|amd64) 
      arch="amd64"
      sha256_expected="${GO_SHA256_AMD64}"
      ;;
    aarch64|arm64) 
      arch="arm64"
      sha256_expected="${GO_SHA256_ARM64}"
      ;;
    *) echo "[错误] 未支持的架构 $(uname -m)，请自行安装 Go >= 1.21" >&2; exit 1;;
  esac
  
  url="https://go.dev/dl/go${GO_VERSION}.${os}-${arch}.tar.gz"
  tarball="${_tmpdir}/go${GO_VERSION}.${os}-${arch}.tar.gz"
  command -v curl >/dev/null 2>&1 || install_deps
  precheck_go_download || exit 1
  echo "[步骤] 下载安装 Go ${GO_VERSION} (${arch}) 作为基础工具链…"
  curl --connect-timeout 10 --max-time 180 --retry 2 -fsSL "$url" -o "$tarball"
  
  # SHA256 完整性校验
  echo "[步骤] 校验 Go tarball 完整性（SHA256）…"
  local sha256_actual
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
  
  if [[ "$sha256_actual" != "$sha256_expected" ]]; then
    echo "[错误] Go tarball SHA256 校验失败：" >&2
    echo "  期望：$sha256_expected" >&2
    echo "  实际：$sha256_actual" >&2
    echo "  文件可能被篡改或下载不完整，已中止安装。" >&2
    rm -f "$tarball"
    exit 1
  fi
  echo "[信息] SHA256 校验通过"
  
  if [[ -d /usr/local/go ]]; then
    local existing_go_ver
    existing_go_ver=$(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}' || echo "未知")
    echo "[警告] 将替换已有 Go 安装：$existing_go_ver → Go ${GO_VERSION}" >&2
    if [[ "${NON_INTERACTIVE}" -ne 1 ]]; then
      local _go_confirm=""
      if ! read -r -p "  确认删除 /usr/local/go 并重新安装？(y/n): " _go_confirm; then
        echo "[中止] 输入已结束，请手动安装 Go 后重试。" >&2
        exit 1
      fi
      [[ "$_go_confirm" == "y" ]] || { echo "[中止] 请手动安装 Go 后重试。" >&2; exit 1; }
    fi
    rm -rf /usr/local/go
  fi
  tar -C /usr/local -xzf "$tarball"
  rm -f "$tarball"
  mkdir -p /etc/profile.d
  echo 'export PATH=/usr/local/go/bin:$PATH' >/etc/profile.d/go.sh
  export PATH=/usr/local/go/bin:$PATH
  echo "[信息] Go 安装完成：$(go version 2>/dev/null || echo 失败)"
}

deploy_state_root() {
  printf '%s\n' "${DEPLOY_STATE_DIR:-/var/lib/derper-deploy}"
}

derper_node_state_dir() {
  if [[ -n "${NODE_STATE_DIR:-}" ]]; then
    printf '%s\n' "$NODE_STATE_DIR"
  else
    printf '%s/state\n' "$INSTALL_DIR"
  fi
}

derper_config_path() {
  printf '%s/derper.json\n' "$(derper_node_state_dir)"
}

file_sha256() {
  [[ -f "$1" && ! -L "$1" ]] || return 1
  sha256_hex <"$1"
}

# 恢复载荷允许空文件。sha256_hex 会拒绝空输入，那是为了不把空摘要当成证书指纹。
payload_sha256() {
  local out=""
  [[ -f "$1" && ! -L "$1" ]] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum <"$1" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    out=$(shasum -a 256 <"$1" | awk '{print $1}')
  else
    out=$(openssl dgst -sha256 <"$1" | awk '{print $2}')
  fi
  [[ "$out" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$out"
}

recovery_file_digest() {
  local file="$1"
  if [[ -L "$file" || ( -e "$file" && ! -f "$file" ) ]]; then
    return 1
  fi
  if [[ -f "$file" ]]; then
    payload_sha256 "$file" || return 1
    return 0
  fi
  printf 'absent\n'
}

recovery_state_digest() {
  local dir="$1" entry file name sum listing="" any=0 sorted
  if [[ ! -e "$dir" ]]; then
    printf 'absent\n'
    return 0
  fi
  if [[ -L "$dir" || ! -d "$dir" ]]; then
    return 1
  fi
  local files=()
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    if [[ -L "$entry" || ! -f "$entry" ]]; then
      return 1
    fi
    files+=("$entry")
  done
  if [[ "${#files[@]}" -eq 0 ]]; then
    printf 'absent\n'
    return 0
  fi
  sorted=$(printf '%s\n' "${files[@]}" | LC_ALL=C sort) || return 1
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    name=$(basename "$file")
    case "$name" in
      ''|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    sum=$(payload_sha256 "$file") || return 1
    listing+="${name} ${sum}"$'\n'
    any=1
  done <<<"$sorted"
  [[ "$any" -eq 1 ]] || return 1
  printf '%s' "$listing" | sha256_hex
}

read_kv_value() {
  local file="$1" want="$2" line key value found=""
  [[ -f "$file" && ! -L "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    case "$line" in
      *'`'*|*'$('*|*';'*|*'|'*|*'&'*|*'<'*|*'>'*)
        echo "[错误] 恢复记录含不可执行内容，已拒绝。" >&2
        return 2
        ;;
    esac
    case "$line" in
      *=*) ;;
      *) echo "[错误] 恢复记录不是白名单键值。" >&2; return 2 ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      phase|recovery|binary_sha256|unit_sha256|config_sha256|state_sha256|cert_sha256|run_intent|verify_clients|daemon_revision|kind) ;;
      *) echo "[错误] 恢复记录含未知字段。" >&2; return 2 ;;
    esac
    if [[ "$key" == "$want" ]]; then
      found=$value
    fi
  done <"$file"
  [[ -n "$found" ]] || return 1
  printf '%s\n' "$found"
}

mode_grants_write_to() {
  local mode="$1" owner_uid="$2" group_gid="$3" uid="$4" gid="$5"
  local bits=$((8#$mode))
  if [[ "$uid" == "$owner_uid" ]]; then
    (( (bits & 0200) != 0 ))
    return
  fi
  if [[ "$gid" == "$group_gid" ]]; then
    (( (bits & 0020) != 0 ))
    return
  fi
  (( (bits & 0002) != 0 ))
}

acquire_deploy_lock() {
  local root
  root=$(deploy_state_root)
  mkdir -p "$root" || return 1
  chmod 700 "$root" || return 1
  if ! command -v flock >/dev/null 2>&1; then
    echo "[错误] 缺少 flock，拒绝开始升级、回退、迁移、轮换或卸载。" >&2
    return 1
  fi
  exec 9>>"${root}/deploy.lock" || return 1
  if ! flock -n 9; then
    echo "[错误] 变更锁已被占用。请等待另一项升级、回退、迁移、轮换或卸载结束。" >&2
    return 1
  fi
  DEPLOY_LOCK_HELD=1
}

ordinary_change_allowed() {
  local marker
  marker="$(deploy_state_root)/incomplete"
  [[ -e "$marker" ]] || return 0
  if [[ -L "$marker" ]] || ! read_kv_value "$marker" phase >/dev/null; then
    echo "[错误] 未完成变更记录无法按白名单读取，已阻断普通覆盖。请显式执行 --recover-interrupted；脚本不会 source 或自动继续。" >&2
    return 1
  fi
  echo "[错误] 存在未完成变更，普通安装、修复、轮换和卸载已阻断。请显式执行 --recover-interrupted；脚本不会自动继续。" >&2
  return 1
}

write_incomplete_marker() {
  local phase="$1" root tmp recovery
  case "$phase" in
    switch|migrate|first-install) ;;
    *) return 1 ;;
  esac
  root=$(deploy_state_root)
  recovery="${root}/recovery"
  mkdir -p "$root" || return 1
  tmp=$(mktemp "${root}/.incomplete.XXXXXX") || return 1
  printf 'phase=%s\nrecovery=%s\n' "$phase" "$recovery" >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "${root}/incomplete" || { rm -f "$tmp"; return 1; }
}

expect_payload_digest() {
  local manifest="$1" key="$2" actual="$3" expect=""
  if expect=$(read_kv_value "$manifest" "$key"); then
    [[ "$expect" == "$actual" ]] || return 1
    return 0
  fi
  # 旧恢复集没有该字段时，只接受载荷确实不存在。已有文件却没有摘要必须拒绝。
  [[ "$actual" == "absent" ]]
}

verify_recovery_payload() {
  local dir="$1" manifest="${1}/manifest" actual="" intent=""
  [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
  actual=$(recovery_file_digest "${dir}/unit") || return 1
  expect_payload_digest "$manifest" unit_sha256 "$actual" || return 1
  actual=$(recovery_file_digest "${dir}/config") || return 1
  expect_payload_digest "$manifest" config_sha256 "$actual" || return 1
  actual=$(recovery_state_digest "${dir}/state") || return 1
  expect_payload_digest "$manifest" state_sha256 "$actual" || return 1
  intent=$(read_kv_value "$manifest" run_intent) || return 1
  case "$intent" in
    active|inactive|absent) return 0 ;;
    *) return 1 ;;
  esac
}

verify_recovery_dir() {
  local dir="$1" expect="" got=""
  [[ -f "${dir}/manifest" && ! -L "${dir}/manifest" && -f "${dir}/binary" && ! -L "${dir}/binary" ]] || return 1
  expect=$(read_kv_value "${dir}/manifest" binary_sha256) || return 1
  got=$(file_sha256 "${dir}/binary") || return 1
  [[ "$expect" == "$got" ]] || return 1
  verify_recovery_payload "$dir"
}

promote_recovery_staging() {
  local root staging recovery
  root=$(deploy_state_root)
  staging="${root}/recovery.staging"
  recovery="${root}/recovery"
  if ! verify_recovery_dir "$staging"; then
    echo "[错误] 暂存恢复集未通过校验，不会覆盖唯一有效备份。" >&2
    return 1
  fi
  rm -rf "${root}/recovery.replacing"
  if [[ -d "$recovery" ]]; then
    mv "$recovery" "${root}/recovery.replacing" || return 1
  fi
  if ! mv "$staging" "$recovery"; then
    if [[ -d "${root}/recovery.replacing" ]]; then
      mv "${root}/recovery.replacing" "$recovery" || true
    fi
    echo "[错误] 无法提交恢复集，已尝试放回原备份。" >&2
    return 1
  fi
  rm -rf "${root}/recovery.replacing"
  return 0
}

current_service_run_intent() {
  if [[ ! -e "${SERVICE_PATH}" ]]; then
    if ! command -v systemctl >/dev/null 2>&1 || ! systemctl cat derper >/dev/null 2>&1; then
      printf 'absent\n'
      return 0
    fi
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet derper; then
    printf 'active\n'
    return 0
  fi
  printf 'inactive\n'
}

capture_and_promote_recovery() {
  local root staging intent sum config unit_sum config_sum state_sum
  root=$(deploy_state_root)
  staging="${root}/recovery.staging"
  rm -rf "$staging"
  mkdir -p "$staging" || return 1
  if [[ ! -f "$BIN_PATH" || -L "$BIN_PATH" ]]; then
    echo "[错误] 没有可备份的正式二进制。" >&2
    rm -rf "$staging"
    return 1
  fi
  cp -p "$BIN_PATH" "${staging}/binary" || { rm -rf "$staging"; return 1; }
  chmod 755 "${staging}/binary" || { rm -rf "$staging"; return 1; }
  if [[ -f "$SERVICE_PATH" && ! -L "$SERVICE_PATH" ]]; then
    cp -p "$SERVICE_PATH" "${staging}/unit" || { rm -rf "$staging"; return 1; }
  fi
  config=$(derper_config_path)
  if [[ -f "$config" && ! -L "$config" ]]; then
    cp -p "$config" "${staging}/config" || { rm -rf "$staging"; return 1; }
  fi
  local state_dir state_file
  state_dir=$(derper_node_state_dir)
  if [[ -d "$state_dir" && ! -L "$state_dir" ]]; then
    mkdir -p "${staging}/state" || { rm -rf "$staging"; return 1; }
    for state_file in "$state_dir"/* "$state_dir"/.[!.]* "$state_dir"/..?*; do
      [[ -e "$state_file" || -L "$state_file" ]] || continue
      [[ -f "$state_file" && ! -L "$state_file" ]] || { rm -rf "$staging"; return 1; }
      cp -p "$state_file" "${staging}/state/$(basename "$state_file")" || { rm -rf "$staging"; return 1; }
    done
  fi
  intent=$(current_service_run_intent)
  sum=$(file_sha256 "${staging}/binary") || { rm -rf "$staging"; return 1; }
  unit_sum=$(recovery_file_digest "${staging}/unit") || { rm -rf "$staging"; return 1; }
  config_sum=$(recovery_file_digest "${staging}/config") || { rm -rf "$staging"; return 1; }
  state_sum=$(recovery_state_digest "${staging}/state") || { rm -rf "$staging"; return 1; }
  {
    printf 'binary_sha256=%s\n' "$sum"
    printf 'unit_sha256=%s\n' "$unit_sum"
    printf 'config_sha256=%s\n' "$config_sum"
    printf 'state_sha256=%s\n' "$state_sum"
    printf 'run_intent=%s\n' "$intent"
    printf 'verify_clients=%s\n' "${VERIFY_CLIENTS_MODE:-off}"
  } >"${staging}/manifest" || { rm -rf "$staging"; return 1; }
  promote_recovery_staging || return 1
}

stage_replace_file() {
  local src="$1" dest="$2" dest_dir tmp src_sum tmp_sum
  [[ -f "$src" && ! -L "$src" ]] || return 1
  refuse_symlink "$dest" || return 1
  dest_dir=$(dirname "$dest")
  mkdir -p "$dest_dir" || return 1
  tmp=$(mktemp "${dest_dir}/.derper-bin.XXXXXX") || return 1
  if ! cp -p "$src" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 755 "$tmp" || { rm -f "$tmp"; return 1; }
  src_sum=$(file_sha256 "$src") || { rm -f "$tmp"; return 1; }
  tmp_sum=$(file_sha256 "$tmp") || { rm -f "$tmp"; return 1; }
  if [[ "$src_sum" != "$tmp_sum" ]]; then
    rm -f "$tmp"
    echo "[错误] 暂存副本与来源摘要不一致，已中止替换。" >&2
    return 1
  fi
  if ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
}

candidate_self_check() {
  local bin="$1" out
  [[ -x "$bin" && ! -L "$bin" ]] || return 1
  out=$("$bin" -h 2>&1 || true)
  if ! printf '%s\n' "$out" | grep -q -- '-a'; then
    echo "[错误] 候选 derper 缺少 -a 监听能力，拒绝切换。" >&2
    return 1
  fi
}

# 进程名只能定位候选，不能授权 root 执行普通用户的程序。
tailscaled_process_is_trusted() {
  local pid="$1" caller uids real effective saved fs extra comm
  [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/${pid}/status" ]] || return 1
  caller=$(id -u) || return 1
  uids=$(awk '/^Uid:/ {print $2, $3, $4, $5; exit}' "/proc/${pid}/status") || return 1
  read -r real effective saved fs extra <<<"$uids"
  [[ -z "$extra" && "$real" == "$caller" && "$effective" == "$caller" && "$saved" == "$caller" && "$fs" == "$caller" ]] || return 1
  comm=$(cat "/proc/${pid}/comm" 2>/dev/null) || return 1
  [[ "$comm" == tailscaled ]]
}

tailscaled_executable_is_trusted() {
  local file="$1" caller owner mode
  [[ -f "$file" && -x "$file" ]] || return 1
  caller=$(id -u) || return 1
  owner=$(stat -Lc %u "$file" 2>/dev/null) || return 1
  mode=$(stat -Lc %a "$file" 2>/dev/null) || return 1
  [[ "$owner" == 0 || "$owner" == "$caller" ]] || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  # 拒绝组/其他用户可写，以及 setuid/setgid 文件。
  (( (8#$mode & 06022) == 0 ))
}

# 只认仍在运行且凭据可信的 tailscaled。磁盘新文件不能代表旧进程。
tailscaled_daemon_pid() {
  local pid="" comm="" ids="" count=0 chosen=""
  if command -v systemctl >/dev/null 2>&1; then
    pid=$(systemctl show -p MainPID --value tailscaled 2>/dev/null || true)
    pid=${pid//$'\r'/}
    pid=${pid//$'\n'/}
    if [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/${pid}/comm" ]]; then
      comm=$(tr -d '[:space:]' <"/proc/${pid}/comm" 2>/dev/null || true)
      if [[ "$comm" == "tailscaled" ]] && tailscaled_process_is_trusted "$pid"; then
        printf '%s\n' "$pid"
        return 0
      fi
    fi
  fi
  command -v pgrep >/dev/null 2>&1 || return 1
  ids=$(pgrep -x tailscaled 2>/dev/null || true)
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    count=$((count + 1))
    [[ "$count" -le 1 ]] || return 1
    chosen=$pid
  done <<<"$ids"
  [[ "$count" -eq 1 && -r "/proc/${chosen}/comm" ]] || return 1
  comm=$(tr -d '[:space:]' <"/proc/${chosen}/comm" 2>/dev/null || true)
  [[ "$comm" == "tailscaled" ]] && tailscaled_process_is_trusted "$chosen" || return 1
  printf '%s\n' "$chosen"
}

tailscaled_running_exe() {
  local pid exe
  pid=$(tailscaled_daemon_pid) || return 1
  exe="/proc/${pid}/exe"
  [[ -x "$exe" ]] || return 1
  printf '%s\n' "$exe"
}

tailscaled_daemon_revision() {
  local exe out rev=""
  exe=$(tailscaled_running_exe) || return 1
  # 在子 shell 固定 inode，检查与执行使用同一个描述符，避免 PID/路径替换竞争。
  out=$(
    exec 8<"$exe" || exit 1
    tailscaled_executable_is_trusted /proc/self/fd/8 || exit 1
    /proc/self/fd/8 --version 2>/dev/null
  ) || return 1
  rev=$(printf '%s\n' "$out" | awk '$1 == "tailscale" && $2 == "commit:" {print $3; exit}' | grep -E '^[0-9a-f]{7,40}$' || true)
  [[ -n "$rev" ]] || return 1
  printf '%s\n' "$rev"
}

derper_artifact_revision() {
  local bin="$1" saved have
  saved="${BIN_PATH}"
  BIN_PATH="$bin"
  have=$(get_installed_derper_version || true)
  BIN_PATH="$saved"
  [[ -n "$have" ]] || return 1
  printf '%s\n' "$have"
}

same_derper_identity() {
  local left right commit module canon rev
  left=$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')
  right=$(printf '%s' "${2:-}" | tr 'A-Z' 'a-z')
  left="${left#v}"
  right="${right#v}"
  [[ -n "$left" && -n "$right" ]] || return 1
  [[ "$left" == "$right" ]] && return 0
  if [[ "$left" =~ ^[0-9a-f]{7,40}$ ]]; then
    commit="$left"
    module="$right"
  elif [[ "$right" =~ ^[0-9a-f]{7,40}$ ]]; then
    commit="$right"
    module="$left"
  else
    return 1
  fi
  rev="${module##*-}"
  if [[ "$module" =~ [.-][0-9]{14}-[0-9a-f]{12}$ && "$commit" == "$rev"* ]]; then
    return 0
  fi
  canon=$(resolve_derper_module_version "$commit" || true)
  canon=$(normalize_version_tag "$canon")
  module=$(normalize_version_tag "$module")
  [[ -n "$canon" && "$canon" == "$module" ]]
}

candidate_matches_running_daemon() {
  local candidate="$1" daemon_rev artifact_rev
  [[ "${VERIFY_CLIENTS_MODE:-off}" == "on" ]] || return 0
  daemon_rev=$(tailscaled_daemon_revision) || {
    echo "[错误] 无法确认正在运行的 tailscaled daemon 身份，已转人工处理，不会切换 derper，也不会升级或降级 tailscaled。" >&2
    return 1
  }
  artifact_rev=$(derper_artifact_revision "$candidate") || {
    echo "[错误] 无法读取候选 derper 的 revision，已转人工处理，不会切换。" >&2
    return 1
  }
  if ! same_derper_identity "$daemon_rev" "$artifact_rev"; then
    echo "[错误] 候选 derper 与 tailscaled daemon revision 不一致（daemon=${daemon_rev}，候选=${artifact_rev}）。已转人工处理，不会切换，也不会升级或降级 tailscaled。" >&2
    return 1
  fi
}

publish_derper_candidate() {
  local candidate="$1"
  candidate_self_check "$candidate" || return 1
  candidate_matches_running_daemon "$candidate" || return 1
  if [[ -e "$BIN_PATH" ]]; then
    capture_and_promote_recovery || return 1
    write_incomplete_marker switch || return 1
    if ! stage_replace_file "$candidate" "$BIN_PATH"; then
      echo "[错误] 写入正式二进制失败，未宣称成功。恢复集仍保留。" >&2
      return 1
    fi
    return 0
  fi
  echo "[信息] 首次安装，没有可回退的上一版本。" >&2
  write_incomplete_marker first-install || return 1
  if ! stage_replace_file "$candidate" "$BIN_PATH"; then
    rm -f "$BIN_PATH"
    echo "[错误] 首次安装写入失败，已清理半成品，没有伪造上一版本。" >&2
    return 1
  fi
}

rollback_deploy_change() {
  local root marker phase recovery intent
  # 恢复使用旧 unit 的身份；不能污染调用方仍在使用的目标参数。
  local RUN_USER="$RUN_USER" IP_ADDR="$IP_ADDR" restored_user restored_ip
  root=$(deploy_state_root)
  marker="${root}/incomplete"
  [[ -f "$marker" && ! -L "$marker" ]] || return 0
  phase=$(read_kv_value "$marker" phase) || return 1
  recovery=$(read_kv_value "$marker" recovery) || return 1
  if [[ "$recovery" != "${root}/recovery" ]]; then
    echo "[错误] 未完成标记中的恢复路径不在固定恢复集内，已拒绝。" >&2
    return 1
  fi
  if [[ "$phase" == "first-install" ]]; then
    ensure_derper_stopped || return 1
    remove_restored_plain_file "$BIN_PATH" || return 1
    rm -f "$marker" || return 1
    echo "[信息] 首次安装未完成，已清理半成品。没有可恢复的上一版本。" >&2
    return 0
  fi
  if [[ "$phase" == "migrate" ]]; then
    if [[ -f "${recovery}/binary" && ! -L "${recovery}/binary" ]]; then
      if ! verify_recovery_dir "$recovery"; then
        echo "[错误] 迁移恢复集无法校验，已保留备份。" >&2
        return 1
      fi
    elif ! verify_recovery_payload "$recovery"; then
      echo "[错误] 迁移恢复集无法校验，已保留备份。" >&2
      return 1
    fi
  elif ! verify_recovery_dir "$recovery"; then
    echo "[错误] 恢复集无法校验，已保留备份且不会宣称恢复成功。" >&2
    return 1
  fi
  if ! ensure_derper_stopped; then
    echo "[错误] 未能停止正在运行的 derper，已保留未完成标记。" >&2
    return 1
  fi
  if [[ -f "${recovery}/binary" && ! -L "${recovery}/binary" ]]; then
    if ! stage_replace_file "${recovery}/binary" "$BIN_PATH"; then
      echo "[错误] 恢复正式二进制失败，已保留恢复集。" >&2
      return 1
    fi
  fi
  if [[ -f "${recovery}/unit" && ! -L "${recovery}/unit" ]]; then
    restored_user=$(awk -F= '/^[[:space:]]*User=/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); user=$2} END {print user}' "${recovery}/unit") || return 1
    restored_user="${restored_user:-root}"
    if [[ ! "$restored_user" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*\$?$ ]]; then
      echo "[错误] 恢复 unit 的运行用户无法安全识别，已保留恢复集。" >&2
      return 1
    fi
    RUN_USER="$restored_user"
    restored_ip=$(sed -nE 's/.*-hostname[[:space:]]+([^[:space:]]+).*/\1/p' "${recovery}/unit" | head -n1)
    [[ -z "$restored_ip" ]] || IP_ADDR="$restored_ip"
    install_without_following_link "${recovery}/unit" "$SERVICE_PATH" || {
      echo "[错误] 恢复 unit 失败，已保留恢复集。" >&2
      return 1
    }
  elif [[ "$(read_kv_value "${recovery}/manifest" unit_sha256 || true)" == absent ]]; then
    remove_restored_plain_file "$SERVICE_PATH" || return 1
  fi
  if ! expect_payload_digest "${recovery}/manifest" unit_sha256 "$(recovery_file_digest "$SERVICE_PATH")"; then
    echo "[错误] unit 的恢复结果与快照不一致，已保留标记。" >&2
    return 1
  fi
  if ! restore_saved_payload "$recovery"; then
    echo "[错误] 恢复配置或节点状态失败，已保留恢复集。" >&2
    return 1
  fi
  if running_as_root && [[ -d "${INSTALL_DIR}/certs" ]]; then
    harden_cert_dir || return 1
  fi
  intent=$(read_kv_value "${recovery}/manifest" run_intent) || return 1
  # inactive/absent 也可能写回或移除了 unit，必须同步 systemd 缓存。
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || return 1
  fi
  if [[ "$intent" == "active" ]]; then
    if command -v systemctl >/dev/null 2>&1; then
      # 坏候选可能耗尽启动频率；只在明确回退旧文件后清除失败计数。
      systemctl reset-failed derper >/dev/null 2>&1 || return 1
      systemctl start derper || return 1
    fi
    if ! verify_restored_service; then
      echo "[错误] 已恢复文件，但复验未通过。恢复集仍保留。" >&2
      return 1
    fi
  fi
  rm -f "$marker" || return 1
  return 0
}

ensure_derper_stopped() {
  command -v systemctl >/dev/null 2>&1 || return 0
  if ! systemctl stop derper; then
    # 首装在写unit之前中断时，明确not-found也属于没有运行服务；通信失败不能当成停止。
    [[ "$(systemctl show -p LoadState --value derper 2>/dev/null)" == not-found ]] || return 1
  fi
  if systemctl is-active --quiet derper; then
    echo "[错误] derper 仍在运行，不能继续恢复。" >&2
    return 1
  fi
}

commit_deploy_change() {
  rm -f "$(deploy_state_root)/incomplete"
}

running_as_root() {
  local uid
  uid=$(id -u 2>/dev/null || true)
  [[ "$uid" == "0" ]]
}

claim_node_state_dir() {
  local dir="$1"
  running_as_root || return 0
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  chown root:root "$dir" || return 1
  chmod 700 "$dir" || return 1
}

release_node_state_dir() {
  local dir="$1" group
  running_as_root || return 0
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  group=$(id -g -n "$RUN_USER" 2>/dev/null || echo "$RUN_USER")
  chown "${RUN_USER}:${group}" "$dir" || return 1
  chmod 700 "$dir" || return 1
}

node_config_readable_by_run_user() {
  local config="$1" owner mode
  [[ -f "$config" && ! -L "$config" ]] || return 1
  if stat -c %U "$config" >/dev/null 2>&1; then
    owner=$(stat -c %U "$config") || return 1
    mode=$(stat -c %a "$config") || return 1
  else
    owner=$(stat -f %Su "$config") || return 1
    mode=$(stat -f %Lp "$config") || return 1
  fi
  [[ "$owner" == "$RUN_USER" ]] || return 1
  mode="${mode#0}"
  [[ "$mode" == "600" ]]
}

install_without_following_link() {
  local src="$1" dest="$2" dir tmp src_sum dest_sum
  [[ -f "$src" && ! -L "$src" ]] || return 1
  dir=$(dirname "$dest")
  if [[ -L "$dir" ]]; then
    echo "[错误] 拒绝把恢复内容写入符号链接目录：${dir}" >&2
    return 1
  fi
  mkdir -p "$dir" || return 1
  if [[ -L "$dir" ]]; then
    echo "[错误] 拒绝把恢复内容写入符号链接目录：${dir}" >&2
    return 1
  fi
  if [[ -L "$dest" ]]; then
    rm -f -- "$dest" || return 1
  fi
  if [[ -L "$dest" ]]; then
    echo "[错误] 拒绝把恢复内容写入符号链接：${dest}" >&2
    return 1
  fi
  tmp=$(mktemp "${dir}/.restore.XXXXXX") || return 1
  if ! cp -p "$src" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if [[ -L "$dest" ]]; then
    rm -f "$tmp"
    echo "[错误] 恢复目标在写入前变成符号链接：${dest}" >&2
    return 1
  fi
  if ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
  if [[ -L "$dest" ]]; then
    echo "[错误] 恢复目标仍是符号链接：${dest}" >&2
    return 1
  fi
  src_sum=$(payload_sha256 "$src") || return 1
  dest_sum=$(payload_sha256 "$dest") || return 1
  [[ "$src_sum" == "$dest_sum" ]]
}

remove_restored_plain_file() {
  local file="$1"
  [[ ! -L "$file" && ( ! -e "$file" || -f "$file" ) ]] || return 1
  [[ ! -e "$file" ]] || rm -f -- "$file" || return 1
  [[ ! -e "$file" && ! -L "$file" ]]
}

restore_saved_payload() {
  local recovery="$1" dest state_dir state_file name rc=0 claimed=0 declared="" state_declared=""
  declared=$(read_kv_value "${recovery}/manifest" config_sha256 2>/dev/null || true)
  state_declared=$(read_kv_value "${recovery}/manifest" state_sha256 2>/dev/null || true)
  if [[ -n "$declared$state_declared" || -f "${recovery}/config" ]] || [[ -d "${recovery}/state" && ! -L "${recovery}/state" ]]; then
    state_dir=$(derper_node_state_dir)
    if [[ "$state_dir" == / || -L "$state_dir" ]]; then
      echo "[错误] 节点状态目录是符号链接，拒绝恢复。" >&2
      return 1
    fi
    mkdir -p "$state_dir" || return 1
    if [[ -L "$state_dir" ]]; then
      echo "[错误] 节点状态目录是符号链接，拒绝恢复。" >&2
      return 1
    fi
    claim_node_state_dir "$state_dir" || return 1
    claimed=1
  fi
  # 只清理已明确快照的专用状态目录的普通文件；链接/子目录先拒绝，绝不递归删除。
  if [[ -n "$state_declared" ]]; then
    for state_file in "$state_dir"/* "$state_dir"/.[!.]* "$state_dir"/..?*; do
      [[ -e "$state_file" || -L "$state_file" ]] || continue
      [[ -f "$state_file" && ! -L "$state_file" ]] || { rc=1; break; }
    done
    if [[ "$rc" == 0 ]]; then
      for state_file in "$state_dir"/* "$state_dir"/.[!.]* "$state_dir"/..?*; do
        [[ -e "$state_file" || -L "$state_file" ]] || continue
        name=$(basename "$state_file")
        if [[ ! -f "${recovery}/state/${name}" ]]; then
          remove_restored_plain_file "$state_file" || { rc=1; break; }
        fi
      done
    fi
  fi
  if [[ "$rc" == 0 && -f "${recovery}/config" && ! -L "${recovery}/config" ]]; then
    dest=$(derper_config_path)
    install_without_following_link "${recovery}/config" "$dest" || rc=1
  fi
  if [[ "$rc" -eq 0 && -d "${recovery}/state" && ! -L "${recovery}/state" ]]; then
    state_dir=$(derper_node_state_dir)
    for state_file in "${recovery}/state/"* "${recovery}/state/".[!.]* "${recovery}/state/"..?*; do
      [[ -f "$state_file" && ! -L "$state_file" ]] || continue
      install_without_following_link "$state_file" "${state_dir}/$(basename "$state_file")" || rc=1
    done
  fi
  if [[ "$rc" -eq 0 && ! -f "${recovery}/config" ]]; then
    if [[ "$declared" == "absent" ]]; then
      state_dir=$(derper_node_state_dir)
      dest=$(derper_config_path)
      if [[ -L "$state_dir" || -L "$dest" ]]; then
        echo "[错误] 节点状态目录是符号链接，拒绝恢复。" >&2
        rc=1
      elif [[ -e "$dest" && ! -f "$dest" ]]; then
        echo "[错误] 当前节点配置不是普通文件，拒绝删除迁移产物。" >&2
        rc=1
      elif ! remove_restored_plain_file "$dest"; then
        rc=1
      fi
    fi
  fi
  if [[ "$rc" == 0 && -n "$declared" ]]; then
    dest=$(derper_config_path)
    [[ "$(recovery_file_digest "$dest")" == "$declared" ]] || rc=1
  fi
  if [[ "$rc" == 0 && -n "$state_declared" ]]; then
    [[ "$(recovery_state_digest "$state_dir")" == "$state_declared" ]] || rc=1
  fi
  if [[ "$claimed" -eq 1 ]]; then
    release_node_state_dir "$state_dir" || rc=1
  fi
  return "$rc"
}

cert_tree_fingerprint() {
  local dir="${INSTALL_DIR}/certs" file sum=""
  [[ -d "$dir" && ! -L "$dir" ]] || {
    printf '\n'
    return 0
  }
  for file in "$dir"/*; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    sum+=$(file_sha256 "$file" || return 1)
  done
  printf '%s\n' "$sum"
}

resume_service_intent() {
  local intent="$1" do_verify="${2:-}"
  if [[ "$intent" != "active" ]]; then
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl start derper || return 1
  fi
  if [[ "$do_verify" == "verify" ]]; then
    verify_restored_service
  fi
}

recover_interrupted_change() {
  local marker
  marker="$(deploy_state_root)/incomplete"
  if [[ ! -f "$marker" || -L "$marker" ]]; then
    echo "[错误] 没有可显式恢复的未完成标记。" >&2
    return 1
  fi
  rollback_deploy_change
}

snapshot_migration_recovery() {
  local legacy="$1" root staging intent sum phase recovery config state_dir state_file unit_sum config_sum state_sum
  root=$(deploy_state_root)
  # 发布已经开始时必须复用唯一恢复集，不能用已发布的候选覆盖旧版本。
  if [[ -e "${root}/incomplete" || -L "${root}/incomplete" ]]; then
    phase=$(read_kv_value "${root}/incomplete" phase) || return 1
    recovery=$(read_kv_value "${root}/incomplete" recovery) || return 1
    [[ "$recovery" == "${root}/recovery" ]] || return 1
    case "$phase" in
      switch) verify_recovery_dir "$recovery" || return 1 ;;
      migrate)
        if [[ -f "${recovery}/binary" && ! -L "${recovery}/binary" ]]; then
          verify_recovery_dir "$recovery" || return 1
        else
          verify_recovery_payload "$recovery" || return 1
        fi
        ;;
      first-install) ;;
      *) return 1 ;;
    esac
    return 0
  fi
  if ! mkdir -p "$root" 2>/dev/null || [[ ! -w "$root" || -L "$root" ]]; then
    running_as_root && return 1
    DEPLOY_STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/derper-deploy.XXXXXX") || return 1
    chmod 700 "$DEPLOY_STATE_DIR" || return 1
    root="$DEPLOY_STATE_DIR"
  else
    chmod 700 "$root" || return 1
  fi
  staging="${root}/recovery.staging"
  rm -rf "$staging"
  mkdir -p "$staging" || return 1
  if [[ ! -f "$legacy" || -L "$legacy" ]]; then
    echo "[错误] 迁移来源不是普通文件，拒绝建立恢复集。" >&2
    rm -rf "$staging"
    return 1
  fi
  intent=$(current_service_run_intent)
  # 恢复目标是迁移前已经生效的节点身份，不是 INSTALL_DIR 里的遗留文件。
  config=$(derper_config_path)
  if [[ -f "$config" && ! -L "$config" ]]; then
    cp -p "$config" "${staging}/config" || { rm -rf "$staging"; return 1; }
  elif [[ -e "$config" || -L "$config" ]]; then
    echo "[错误] 当前节点配置不是普通文件，拒绝迁移。" >&2
    rm -rf "$staging"
    return 1
  fi
  state_dir=$(derper_node_state_dir)
  if [[ -d "$state_dir" && ! -L "$state_dir" ]]; then
    mkdir -p "${staging}/state" || { rm -rf "$staging"; return 1; }
    for state_file in "$state_dir"/* "$state_dir"/.[!.]* "$state_dir"/..?*; do
      [[ -e "$state_file" || -L "$state_file" ]] || continue
      if [[ ! -f "$state_file" || -L "$state_file" ]]; then
        echo "[错误] 节点状态含符号链接或非普通文件，拒绝迁移。" >&2
        rm -rf "$staging"
        return 1
      fi
      cp -p "$state_file" "${staging}/state/$(basename "$state_file")" || { rm -rf "$staging"; return 1; }
    done
  elif [[ -e "$state_dir" || -L "$state_dir" ]]; then
    echo "[错误] 节点状态目录不是普通目录，拒绝迁移。" >&2
    rm -rf "$staging"
    return 1
  fi
  if [[ -f "$SERVICE_PATH" && ! -L "$SERVICE_PATH" ]]; then
    cp -p "$SERVICE_PATH" "${staging}/unit" || { rm -rf "$staging"; return 1; }
  fi
  unit_sum=$(recovery_file_digest "${staging}/unit") || { rm -rf "$staging"; return 1; }
  config_sum=$(recovery_file_digest "${staging}/config") || { rm -rf "$staging"; return 1; }
  state_sum=$(recovery_state_digest "${staging}/state") || { rm -rf "$staging"; return 1; }
  {
    printf 'kind=migrate\n'
    printf 'run_intent=%s\n' "$intent"
    printf 'unit_sha256=%s\n' "$unit_sum"
    printf 'config_sha256=%s\n' "$config_sum"
    printf 'state_sha256=%s\n' "$state_sum"
  } >"${staging}/manifest" || { rm -rf "$staging"; return 1; }
  if [[ -f "$BIN_PATH" && ! -L "$BIN_PATH" ]]; then
    cp -p "$BIN_PATH" "${staging}/binary" || { rm -rf "$staging"; return 1; }
    sum=$(file_sha256 "${staging}/binary") || { rm -rf "$staging"; return 1; }
    printf 'binary_sha256=%s\n' "$sum" >>"${staging}/manifest" || { rm -rf "$staging"; return 1; }
    verify_recovery_dir "$staging" || { rm -rf "$staging"; return 1; }
  else
    verify_recovery_payload "$staging" || { rm -rf "$staging"; return 1; }
  fi
  rm -rf "${root}/recovery.replacing"
  if [[ -d "${root}/recovery" ]]; then
    mv "${root}/recovery" "${root}/recovery.replacing" || { rm -rf "$staging"; return 1; }
  fi
  if ! mv "$staging" "${root}/recovery"; then
    if [[ -d "${root}/recovery.replacing" ]]; then
      mv "${root}/recovery.replacing" "${root}/recovery" || true
    fi
    return 1
  fi
  rm -rf "${root}/recovery.replacing"
  write_incomplete_marker migrate
}

migration_fail() {
  local intent="$1"
  echo "[错误] 节点状态迁移失败。" >&2
  if ! resume_service_intent "$intent" verify; then
    echo "[错误] 服务未能按原意图恢复。未完成标记已保留，请执行 --recover-interrupted。" >&2
    return 1
  fi
  # 即使旧服务已恢复运行，外层发布尚未完成；保留显式恢复入口。
  return 1
}

# 当前身份已经位于目标状态目录时，不因遗留副本仍在而再次停服。
# 只核对路径、属主/组、最小权限与可读性；内容仍由derper加载，运行状态由发布门禁验证。
node_state_is_ready() {
  local config="$1" state="$2" uid gid config_meta state_meta
  [[ -f "$config" && -s "$config" && ! -L "$config" && -d "$state" && ! -L "$state" ]] || return 1
  uid=$(id -u "$RUN_USER") && gid=$(id -g "$RUN_USER") || return 1
  config_meta=$(stat -c '%u:%g:%a' "$config" 2>/dev/null || stat -f '%u:%g:%Lp' "$config") || return 1
  state_meta=$(stat -c '%u:%g:%a' "$state" 2>/dev/null || stat -f '%u:%g:%Lp' "$state") || return 1
  [[ "$config_meta" == "${uid}:${gid}:600" && "$state_meta" == "${uid}:${gid}:700" ]] || return 1
  if running_as_root && [[ "$uid" != 0 ]]; then
    command -v runuser >/dev/null 2>&1 || return 1
    runuser -u "$RUN_USER" -- test -r "$config" || return 1
  else
    [[ -r "$config" && -x "$state" ]] || return 1
  fi
}

migrate_node_state() {
  local legacy config state trim a b intent before after group
  legacy="${INSTALL_DIR}/derper.json"
  config=$(derper_config_path)
  state=$(derper_node_state_dir)
  mkdir -p "$state" || return 1
  if [[ -L "$legacy" || -L "$config" || -L "$state" ]]; then
    echo "[错误] 节点配置路径是符号链接，拒绝迁移。" >&2
    return 1
  fi
  # 不清除外层发布/首次迁移的恢复集或未完成标记，也不删除遗留私钥副本。
  if node_state_is_ready "$config" "$state"; then
    return 0
  fi
  if [[ ! -f "$legacy" ]]; then
    return 0
  fi
  trim=$(tr -d ' \t\r\n' <"$legacy" 2>/dev/null || true)
  if [[ -z "$trim" || "$trim" == "{}" ]]; then
    rm -f "$legacy"
    return 0
  fi
  snapshot_migration_recovery "$legacy" || return 1
  before=$(cert_tree_fingerprint) || { migration_fail "$(current_service_run_intent)"; return 1; }
  intent=$(current_service_run_intent)
  if [[ "$intent" == "active" ]]; then
    systemctl stop derper || { migration_fail "$intent"; return 1; }
  fi
  claim_node_state_dir "$state" || { migration_fail "$intent"; return 1; }
  if [[ ! -f "$config" ]]; then
    if ! install_without_following_link "$legacy" "$config"; then
      release_node_state_dir "$state" || true
      migration_fail "$intent" || return 1
      return 1
    fi
    a=$(file_sha256 "$legacy") || {
      release_node_state_dir "$state" || true
      migration_fail "$intent" || return 1
      return 1
    }
    b=$(file_sha256 "$config") || {
      release_node_state_dir "$state" || true
      migration_fail "$intent" || return 1
      return 1
    }
    if [[ "$a" != "$b" ]]; then
      rm -f "$config"
      echo "[错误] 节点身份副本与原文件不一致，已中止迁移。" >&2
      release_node_state_dir "$state" || true
      migration_fail "$intent" || return 1
      return 1
    fi
  fi
  if [[ -L "$config" ]]; then
    echo "[错误] 节点配置是符号链接，拒绝修改属主。" >&2
    release_node_state_dir "$state" || true
    migration_fail "$intent" || return 1
    return 1
  fi
  group=$(id -g -n "$RUN_USER" 2>/dev/null || echo "$RUN_USER")
  chown "${RUN_USER}:${group}" "$config" || {
    release_node_state_dir "$state" || true
    migration_fail "$intent" || return 1
    return 1
  }
  chmod 600 "$config" || {
    release_node_state_dir "$state" || true
    migration_fail "$intent" || return 1
    return 1
  }
  if running_as_root && ! node_config_readable_by_run_user "$config"; then
    echo "[错误] 运行用户无法读取节点配置：${config}" >&2
    release_node_state_dir "$state" || true
    migration_fail "$intent" || return 1
    return 1
  fi
  after=$(cert_tree_fingerprint) || {
    release_node_state_dir "$state" || true
    migration_fail "$intent" || return 1
    return 1
  }
  if [[ "$before" != "$after" ]]; then
    echo "[错误] 迁移改变了证书内容，已中止。" >&2
    release_node_state_dir "$state" || true
    migration_fail "$intent" || return 1
    return 1
  fi
  release_node_state_dir "$state" || { migration_fail "$intent"; return 1; }
  if running_as_root && command -v runuser >/dev/null 2>&1; then
    if ! runuser -u "$RUN_USER" -- test -r "$config"; then
      echo "[错误] 运行用户无法读取节点配置：${config}" >&2
      resume_service_intent "$intent" verify || true
      return 1
    fi
  fi
  if ! resume_service_intent "$intent"; then
    echo "[错误] 迁移后的服务未能按原意图启动。未完成标记已保留。" >&2
    return 1
  fi
  # 由最终 unit/服务验证后的 commit_deploy_change 提交整个变更。
  echo "[信息] 已保留节点身份：${config}"
}

layout_install_tree() {
  local state certs group
  state=$(derper_node_state_dir)
  certs="${INSTALL_DIR}/certs"
  if [[ -L "$INSTALL_DIR" || -L "$certs" || ( -e "$state" && -L "$state" ) ]]; then
    echo "[错误] 安装树、证书目录或节点状态目录是符号链接，拒绝迁移。" >&2
    return 1
  fi
  mkdir -p "$INSTALL_DIR" "$certs" "$state" || return 1
  if [[ -L "$certs" || -L "$state" ]]; then
    echo "[错误] 安装树、证书目录或节点状态目录是符号链接，拒绝迁移。" >&2
    return 1
  fi
  chown root:root "$INSTALL_DIR" || return 1
  chmod 755 "$INSTALL_DIR" || return 1
  group=$(id -g -n "$RUN_USER" 2>/dev/null || echo "$RUN_USER")
  chown "${RUN_USER}:${group}" "$state" || return 1
  chmod 700 "$state" || return 1
  harden_cert_dir || return 1
  migrate_node_state || return 1
}

validate_local_elf() {
  local bin="$1" header machine want
  command -v od >/dev/null 2>&1 || return 1
  header=$(od -An -tx1 -N20 "$bin" | tr -d ' \n') || return 1
  # 64位、小端、System V/Linux ABI；在执行候选之前拒绝脚本及其他平台。
  [[ ${#header} -eq 40 && "${header:0:14}" == 7f454c46020101 ]] || return 1
  [[ "${header:14:2}" == 00 || "${header:14:2}" == 03 ]] || return 1
  case "$(uname -m)" in x86_64|amd64) want=3e00 ;; aarch64|arm64) want=b700 ;; *) return 1 ;; esac
  machine=${header:36:4}
  [[ "$machine" == "$want" ]]
}

import_local_derper() {
  local dir candidate actual expected version
  [[ -f "$LOCAL_BINARY" && ! -L "$LOCAL_BINARY" && -r "$LOCAL_BINARY" ]] || { echo '[错误] 本地二进制必须为可读普通文件。' >&2; return 1; }
  [[ "$DERPER_VERSION" != latest && -n "$DERPER_VERSION" ]] || return 1
  dir="$(deploy_state_root)/candidate"
  mkdir -p "$dir" && chmod 700 "$dir" || return 1
  candidate=$(mktemp "$dir/import.XXXXXXXX") || return 1
  if ! cp "$LOCAL_BINARY" "$candidate" || ! chmod 755 "$candidate" || ! validate_local_elf "$candidate"; then
    rm -f "$candidate"
    echo '[错误] 本地产物不是当前架构的Linux ELF，未执行或发布。' >&2
    return 1
  fi
  actual=$(file_sha256 "$candidate") || { rm -f "$candidate"; return 1; }
  expected=$(printf '%s' "$BINARY_SHA256" | tr 'A-F' 'a-f')
  if [[ -n "$expected" && "$actual" != "$expected" ]]; then rm -f "$candidate"; echo '[错误] 本地产物摘要不符。' >&2; return 1; fi
  version=$(derper_artifact_revision "$candidate" || true)
  if [[ -z "$version" ]] || ! same_derper_identity "$version" "$DERPER_VERSION"; then
    rm -f "$candidate"
    echo '[错误] 本地产物版本无法确认或与目标不符。' >&2
    return 1
  fi
  local help rc=0 flag
  help=$(_timeout_run 10 "$candidate" -h 2>&1) || rc=$?
  if [[ "$rc" != 0 && "$rc" != 2 ]]; then rm -f "$candidate"; echo '[错误] 候选帮助检查失败或超时。' >&2; return 1; fi
  for flag in -a -c -certdir -certmode -stun; do
    if ! printf '%s\n' "$help" | grep -qE -- "(^|[[:space:]])${flag}([[:space:]]|$)"; then rm -f "$candidate"; echo '[错误] 候选缺少部署所需能力。' >&2; return 1; fi
  done
  if [[ "$STUN_PORT" != 3478 ]] && ! printf '%s\n' "$help" | grep -q -- -stun-port; then rm -f "$candidate"; return 1; fi
  if ! publish_derper_candidate "$candidate"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  echo "[信息] 本地产物已发布：version=${version} sha256=${actual}（摘要仅校验完整性，不认证来源）"
}

install_derper() {
  if [[ -n "${LOCAL_BINARY:-}" ]]; then import_local_derper || return 1; return 0; fi
  echo "[步骤] 安装/构建 derper 可执行文件…"
  # root 的 Go 依赖与编译缓存持久保存在磁盘；工具链和事务文件使用安全临时目录。
  if [[ -z "${_tmpdir:-}" || ! -d "${_tmpdir}" ]]; then
    echo "[错误] 内部错误：安全临时目录未初始化，已中止构建，未改动现有二进制。" >&2
    exit 1
  fi
  prepare_go_build_root || exit 1
  precheck_go_network || exit 1
  ensure_go
  local candidate_dir go_build_root
  candidate_dir="$(deploy_state_root)/candidate"
  go_build_root=$(go_build_cache_root) || exit 1
  mkdir -p "$candidate_dir" "$go_build_root/gopath/pkg/mod" "$go_build_root/cache" || exit 1
  rm -f "${candidate_dir}/derper"
  export GOBIN="${candidate_dir}"
  local envs=("GOBIN=${candidate_dir}" "GO111MODULE=on" "GOTOOLCHAIN=${GOTOOLCHAIN_ARG}"
    "GOPATH=${go_build_root}/gopath" "GOMODCACHE=${go_build_root}/gopath/pkg/mod" "GOCACHE=${go_build_root}/cache"
    "GOTMPDIR=${_tmpdir}/go-work" "TMPDIR=${_tmpdir}")
  if [[ -n "${GOPROXY_ARG}" ]]; then envs+=("GOPROXY=${GOPROXY_ARG}"); fi
  if [[ -n "${GOSUMDB_ARG}" ]]; then envs+=("GOSUMDB=${GOSUMDB_ARG}"); fi
  echo "[信息] 安装 derper 版本：${DERPER_VERSION}"
  if ! _run_with_progress '下载/编译 derper' "${_tmpdir}/derper_install.err" 900 env "${envs[@]}" go install "tailscale.com/cmd/derper@${DERPER_VERSION}"; then
    echo "[错误] go install 失败；请检查模块代理/校验数据库连通性。国内网络可显式使用 --goproxy https://goproxy.cn,direct；脚本保留现有代理设置，不自动切换第三方代理或关闭校验。" >&2
    sed -n '1,160p' "${_tmpdir}/derper_install.err" >&2 || true
    exit 1
  fi
  if [[ ! -x "${candidate_dir}/derper" ]]; then
    echo "[错误] 候选 derper 未生成：${candidate_dir}/derper。正式二进制未被覆盖。" >&2
    exit 1
  fi
  publish_derper_candidate "${candidate_dir}/derper" || exit 1
  echo "[信息] derper 安装到：${BIN_PATH}"
}

ensure_deploy_dependencies() {
  if [[ -z "$LOCAL_BINARY" ]]; then install_deps; return; fi
  local tool
  for tool in openssl curl od; do
    command -v "$tool" >/dev/null 2>&1 || { echo "[错误] 本地导入缺少依赖 ${tool}，请先安装。" >&2; return 1; }
  done
}

derper_supports_stun_port() {
  local bin help_output
  if [[ -x "${BIN_PATH}" ]]; then bin="${BIN_PATH}"; else bin="$(command -v derper 2>/dev/null || echo ${BIN_PATH})"; fi
  # derper -h 会以状态码 2 退出，先捕获输出以避免 pipefail 导致检测失败
  help_output=$("$bin" -h 2>&1 || true)
  if echo "$help_output" | grep -q -- '-stun-port'; then
    return 0
  else
    return 1
  fi
}

# 新旧参数兼容检测：新版本使用 -a :PORT 指定 TLS 监听地址，旧版本使用 -https-port
derper_supports_https_port() {
  local bin help_output
  if [[ -x "${BIN_PATH}" ]]; then bin="${BIN_PATH}"; else bin="$(command -v derper 2>/dev/null || echo ${BIN_PATH})"; fi
  # derper -h 会以状态码 2 退出，先捕获输出以避免 pipefail 导致检测失败
  help_output=$("$bin" -h 2>&1 || true)
  if echo "$help_output" | grep -q -- '-https-port'; then
    return 0
  else
    return 1
  fi
}

# 新监听参数支持检测：是否支持使用 -a :PORT 指定 TLS 监听地址（新版）
derper_supports_listen_a() {
  local bin help_output
  if [[ -x "${BIN_PATH}" ]]; then bin="${BIN_PATH}"; else bin="$(command -v derper 2>/dev/null || echo ${BIN_PATH})"; fi
  # derper -h 会以状态码 2 退出，先捕获输出以避免 pipefail 导致检测失败
  help_output=$("$bin" -h 2>&1 || true)
  if echo "$help_output" | grep -qE '(^|[[:space:]])-a([[:space:]]|$)'; then
    return 0
  else
    return 1
  fi
}

derper_supports_socket_flag() {
  local bin help_output
  if [[ -x "${BIN_PATH}" ]]; then bin="${BIN_PATH}"; else bin="$(command -v derper 2>/dev/null || echo ${BIN_PATH})"; fi
  help_output=$("$bin" -h 2>&1 || true)
  echo "$help_output" | grep -qE '(^|[[:space:]])-socket([[:space:]]|$)'
}

# 拒绝写入符号链接路径（防止低权限服务账户诱导 root 沿链接覆盖任意文件）。
refuse_symlink() {
  if [[ -L "$1" ]]; then
    echo "[错误] 拒绝写入：$1 是符号链接（可能存在恶意替换风险），请手动检查后删除。" >&2
    return 1
  fi
}

# 同目录临时文件 + mv 原子替换；拒绝把目标写成符号链接。
atomic_install_file() {
  local dest="$1" dir tmp
  refuse_symlink "$dest" || return 1
  if [[ -d "$dest" ]]; then
    echo "[错误] 拒绝写入：$dest 是目录，无法写入文件。" >&2
    return 1
  fi
  dir=$(dirname "$dest")
  tmp=$(mktemp "${dir}/.derper-unit.XXXXXX") || return 1
  if ! cat >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 644 "$tmp" 2>/dev/null || true
  if ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
}

atomic_copy_file() {
  local src="$1" dest="$2" dir tmp
  [[ -f "$src" ]] || return 1
  refuse_symlink "$dest" || return 1
  dir=$(dirname "$dest")
  tmp=$(mktemp "${dir}/.derper-unit.XXXXXX") || return 1
  if ! cp -p "$src" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
}

# 加固证书目录：certs 目录与证书/私钥保持 root 所有，服务用户仅通过组权限只读，
# 防止 derper 账户篡改证书或预埋符号链接等待 root 重签时触发覆盖。
harden_cert_dir() {
  local certs_dir="${INSTALL_DIR}/certs"
  [[ -d "$certs_dir" ]] || return 0
  if [[ -L "$certs_dir" ]]; then
    echo "[错误] ${certs_dir} 是符号链接，拒绝加固（可能存在安全风险）。" >&2
    return 1
  fi
  local group="root"
  if [[ -n "${RUN_USER:-}" ]] && id -g -n "$RUN_USER" >/dev/null 2>&1; then
    group=$(id -g -n "$RUN_USER")
  fi
  chown root:"$group" "$certs_dir" 2>/dev/null || chown root:root "$certs_dir" 2>/dev/null || return 1
  chmod 750 "$certs_dir" 2>/dev/null || return 1

  local cert_file key_file
  cert_file=$(derper_manual_cert_file)
  key_file=$(derper_manual_key_file)
  if [[ -f "$key_file" && ! -L "$key_file" ]]; then
    chown root:"$group" "$key_file" 2>/dev/null || chown root:root "$key_file" 2>/dev/null || return 1
    chmod 640 "$key_file" 2>/dev/null || return 1
  fi
  if [[ -f "$cert_file" && ! -L "$cert_file" ]]; then
    chown root:"$group" "$cert_file" 2>/dev/null || chown root:root "$cert_file" 2>/dev/null || return 1
    chmod 644 "$cert_file" 2>/dev/null || return 1
  fi
  return 0
}

# 事务备份留在磁盘上，进程被杀后下一次修复仍可恢复原证书对。
begin_cert_update() {
  local backup="${SERVICE_PATH}.certs-rollback"
  refuse_symlink "$backup" || return 1
  [[ ! -e "$backup" ]] || { echo "[错误] 存在未完成的证书事务，请先运行 --repair 恢复。" >&2; return 1; }
  mkdir -m 700 "$backup" || return 1
  if ! cp -a "${INSTALL_DIR}/certs" "$backup/certs"; then
    rm -rf "$backup"
    return 1
  fi
  rm -f "$backup"/certs/.derper-*
  if [[ -f "$SERVICE_PATH" ]]; then
    cp -L -p "$SERVICE_PATH" "$backup/unit" || return 1
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet derper; then
    touch "$backup/was-running" || return 1
  fi
  touch "$backup/ready" || return 1
  CERT_TRANSACTION_ACTIVE=1
}

rollback_cert_update() {
  CERT_ROLLBACK_OCCURRED=0
  CERT_ROLLBACK_WAS_RUNNING=0
  local backup="${SERVICE_PATH}.certs-rollback"
  [[ -e "$backup" || -L "$backup" ]] || return 0
  refuse_symlink "$backup" || return 1
  # 未写 ready 表示尚未替换任何证书，原目录仍然有效。
  if [[ ! -f "$backup/ready" ]]; then rm -rf "$backup"; return 0; fi
  [[ ! -f "$backup/was-running" ]] || CERT_ROLLBACK_WAS_RUNNING=1
  refuse_symlink "${INSTALL_DIR}/certs" || return 1
  refuse_symlink "$backup/certs" || return 1
  [[ -d "$backup/certs" ]] || return 1
  # 备份保持不动；恢复本身被中断也可以重复执行。
  rm -rf "$backup/restore"
  cp -a "$backup/certs" "$backup/restore" || return 1
  if [[ -d "${INSTALL_DIR}/certs" ]]; then
    rm -rf "$backup/failed"
    mv "${INSTALL_DIR}/certs" "$backup/failed" || return 1
  fi
  if ! mv "$backup/restore" "${INSTALL_DIR}/certs"; then
    [[ ! -d "$backup/failed" ]] || mv "$backup/failed" "${INSTALL_DIR}/certs"
    return 1
  fi
  if [[ -f "$backup/unit" ]]; then
    atomic_copy_file "$backup/unit" "$SERVICE_PATH" || return 1
    if command -v systemctl >/dev/null 2>&1; then
      systemctl daemon-reload || return 1
    fi
  fi
  rm -rf "$backup"
  CERT_ROLLBACK_OCCURRED=1
  echo "[信息] 已恢复上次证书事务之前的证书、密钥及兼容链接。" >&2
}

commit_cert_update() {
  local backup="${SERVICE_PATH}.certs-rollback"
  if [[ -e "$backup" || -L "$backup" ]]; then
    refuse_symlink "$backup" || return 1
    rm -rf "$backup"
  fi
  CERT_TRANSACTION_ACTIVE=0
}

cert_layout_is_ok() {
  local cert_file key_file alias target mode uid
  cert_file=$(derper_manual_cert_file)
  key_file=$(derper_manual_key_file)
  for alias in fullchain.pem cert.pem privkey.pem key.pem; do
    case "$alias" in fullchain.pem|cert.pem) target=$(basename "$cert_file");; *) target=$(basename "$key_file");; esac
    [[ -L "${INSTALL_DIR}/certs/$alias" && "$(readlink "${INSTALL_DIR}/certs/$alias")" == "$target" ]] || return 1
  done
  for target in "${INSTALL_DIR}/certs" "$key_file" "$cert_file"; do
    [[ ! -L "$target" ]] || return 1
    mode=$(stat -c '%a' "$target" 2>/dev/null || stat -f '%Lp' "$target") || return 1
    uid=$(stat -c '%u' "$target" 2>/dev/null || stat -f '%u' "$target") || return 1
    [[ "$uid" == 0 ]] || return 1
    case "$target" in
      "$key_file") [[ "$mode" == 640 ]] || return 1;;
      "$cert_file") [[ "$mode" == 644 ]] || return 1;;
      *) [[ "$mode" == 750 ]] || return 1;;
    esac
  done
  [[ ! -e "${SERVICE_PATH}.certs-rollback" ]]
}

repair_cert_layout() {
  local cert_file key_file
  cert_file=$(derper_manual_cert_file)
  key_file=$(derper_manual_key_file)
  refuse_symlink "$cert_file" || return 1
  refuse_symlink "$key_file" || return 1
  harden_cert_dir || return 1
  ln -sfn "$(basename "$cert_file")" "${INSTALL_DIR}/certs/fullchain.pem" || return 1
  ln -sfn "$(basename "$key_file")" "${INSTALL_DIR}/certs/privkey.pem" || return 1
  ln -sfn "$(basename "$cert_file")" "${INSTALL_DIR}/certs/cert.pem" || return 1
  ln -sfn "$(basename "$key_file")" "${INSTALL_DIR}/certs/key.pem" || return 1
}

confirm_cert_rotation() {
  local old_cert new_fp answer=""
  old_cert=$(resolve_disk_cert_pem || true)
  [[ -n "$old_cert" && -f "$old_cert" ]] || return 0
  new_fp=$(openssl x509 -in "$1" -outform DER | sha256_hex) || return 1
  [[ -n "$new_fp" ]] || return 1
  echo "[警告] 即将替换已有证书并重启 DERP。旧 ACL 指纹随后失效；更新 ACL 与服务切换之间可能中断连接。请保留备用中继/管理连接。" >&2
  echo "[信息] 待启用的新证书 ACL（尚未切换，请安排好变更窗口）：" >&2
  print_acl_snippet_cert "$IP_ADDR" "$DERP_PORT" "$new_fp"
  [[ "${ACCEPT_CERT_ROTATION:-0}" -eq 1 ]] && return 0
  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    echo "[中止] --yes 不确认指纹轮换；安排变更窗口后使用 --accept-cert-rotation。原证书保持不变。" >&2
    return 1
  fi
  read -r -p "确认接受指纹切换及 ACL 更新窗口？输入 rotate 继续：" answer || return 1
  [[ "$answer" == rotate ]]
}

cert_rotation_root() {
  printf '%s/cert-rotation\n' "$(deploy_state_root)"
}

cert_rotation_record_path() {
  printf '%s/record\n' "$(cert_rotation_root)"
}

cert_rotation_candidate_cert() {
  printf '%s/candidate/cert.pem\n' "$(cert_rotation_root)"
}

cert_rotation_candidate_key() {
  printf '%s/candidate/key.pem\n' "$(cert_rotation_root)"
}

cert_rotation_snippet_path() {
  printf '%s/snippet.json\n' "$(cert_rotation_root)"
}

maintenance_status_path() {
  printf '%s/maintenance/status\n' "$(deploy_state_root)"
}

_read_whitelist_kv() {
  local file="$1" want="$2" allowed="$3" line key value found=""
  [[ -f "$file" && ! -L "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    case "$line" in
      *'`'*|*'$('*|*';'*|*'|'*|*'&'*|*'<'*|*'>'*) echo "[错误] 记录含不可执行内容，已拒绝。" >&2; return 2 ;;
    esac
    [[ "$line" == *=* ]] || { echo "[错误] 记录不是白名单键值。" >&2; return 2; }
    key=${line%%=*}; value=${line#*=}
    case "|$allowed|" in *"|$key|"*) ;; *) echo "[错误] 记录含未知字段。" >&2; return 2 ;; esac
    [[ "$key" == "$want" ]] && found=$value
  done <"$file"
  [[ -n "$found" ]] || return 1
  printf '%s\n' "$found"
}

read_rotation_kv() {
  _read_whitelist_kv "$(cert_rotation_record_path)" "$1" "kind|phase|old_sha256|new_sha256|region_id|ip|derp_port|stun_port|cert_days|tailnet|etag|policy_mode|lead_days"
}

read_maintenance_kv() {
  _read_whitelist_kv "$(maintenance_status_path)" "$1" "mode|result|reason|needs_manual|last_run|next_due|lead_days|intent|scheduler_state"
}

maintenance_scheduler_state() {
  local state
  state=$(read_maintenance_kv scheduler_state 2>/dev/null || true)
  if [[ -n "$state" ]]; then
    printf '%s\n' "$state"
  elif [[ "$(read_maintenance_kv mode 2>/dev/null || true)" == unknown && "$(read_maintenance_kv result 2>/dev/null || true)" == failed ]]; then
    # 旧版仅在维护任务安装/启用失败时写 unknown+failed，升级后同样保留失败。
    printf 'failed\n'
  else
    printf 'unknown\n'
  fi
}

write_rotation_record() {
  local root rec tmp
  root=$(cert_rotation_root)
  rec=$(cert_rotation_record_path)
  mkdir -p "$root" || return 1
  chmod 700 "$root" 2>/dev/null || true
  tmp=$(mktemp "${root}/.record.XXXXXX") || return 1
  cat >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$rec"
}

write_maintenance_status() {
  local dir file tmp mode result reason needs due intent scheduler_state
  mode="${1:-manual}"
  result="${2:-idle}"
  reason="${3:-}"
  needs="${4:-0}"
  due="${5:-0}"
  intent="${6-}"
  scheduler_state="${7-}"
  if [[ -z "$scheduler_state" ]]; then
    scheduler_state=$(maintenance_scheduler_state)
  fi
  if [[ -z "$intent" ]]; then
    intent=$(read_maintenance_kv intent 2>/dev/null || true)
  fi
  if [[ -z "$intent" ]]; then
    if [[ "$mode" == ready ]]; then
      intent=enabled
    else
      intent=unset
    fi
  fi
  dir=$(dirname "$(maintenance_status_path)")
  file=$(maintenance_status_path)
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  tmp=$(mktemp "${dir}/.status.XXXXXX") || return 1
  {
    printf 'mode=%s\n' "$mode"
    printf 'result=%s\n' "$result"
    printf 'reason=%s\n' "$reason"
    printf 'needs_manual=%s\n' "$needs"
    printf 'last_run=%s\n' "$(date +%s 2>/dev/null || echo 0)"
    printf 'next_due=%s\n' "$due"
    printf 'lead_days=%s\n' "${CERT_LEAD_DAYS:-30}"
    printf 'intent=%s\n' "$intent"
    printf 'scheduler_state=%s\n' "$scheduler_state"
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file"
}

write_selfsigned_pair() {
  local dest_cert="$1" dest_key="$2" dir key_tmp cert_tmp cnf_tmp="" ok=0
  dir=$(dirname "$dest_cert")
  mkdir -p "$dir" || return 1
  key_tmp=$(mktemp "${dir}/.derper-key.XXXXXX") || return 1
  cert_tmp=$(mktemp "${dir}/.derper-cert.XXXXXX") || { rm -f "$key_tmp"; return 1; }
  if openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
      -keyout "$key_tmp" -out "$cert_tmp" -days "${CERT_DAYS}" \
      -subj "/CN=${IP_ADDR}" -addext "subjectAltName = IP:${IP_ADDR}" >/dev/null 2>&1; then
    ok=1
  else
    rm -f "$key_tmp" "$cert_tmp"
    key_tmp=$(mktemp "${dir}/.derper-key.XXXXXX") || return 1
    cert_tmp=$(mktemp "${dir}/.derper-cert.XXXXXX") || { rm -f "$key_tmp"; return 1; }
    cnf_tmp=$(mktemp "${dir}/.derper-cnf.XXXXXX") || { rm -f "$key_tmp" "$cert_tmp"; return 1; }
    cat >"$cnf_tmp" <<CONF
[ req ]
default_bits = 2048
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[ req_distinguished_name ]
CN = ${IP_ADDR}
[ v3_req ]
subjectAltName = IP:${IP_ADDR}
CONF
    if openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
      -keyout "$key_tmp" -out "$cert_tmp" -days "${CERT_DAYS}" \
      -config "$cnf_tmp" >/dev/null 2>&1; then
      ok=1
    fi
  fi
  rm -f "$cnf_tmp"
  if [[ "$ok" -ne 1 ]]; then
    rm -f "$key_tmp" "$cert_tmp"
    echo "[错误] 自签证书生成失败。" >&2
    return 1
  fi
  chmod 600 "$key_tmp" "$cert_tmp" 2>/dev/null || true
  mv -f "$key_tmp" "$dest_key" || { rm -f "$key_tmp" "$cert_tmp"; return 1; }
  mv -f "$cert_tmp" "$dest_cert" || { rm -f "$cert_tmp"; return 1; }
}

cert_archive_path() {
  printf '%s.certs-archive\n' "$SERVICE_PATH"
}

archive_completed_cert_transaction() {
  local backup="${SERVICE_PATH}.certs-rollback" archive
  archive=$(cert_archive_path)
  if [[ ! -e "$backup" && ! -L "$backup" ]]; then
    CERT_TRANSACTION_ACTIVE=0
    return 0
  fi
  refuse_symlink "$backup" || return 1
  rm -rf "$archive"
  mv "$backup" "$archive" || return 1
  CERT_TRANSACTION_ACTIVE=0
}

cert_contains_ip_san() {
  local cert="$1" ip="$2" text
  text=$(openssl x509 -in "$cert" -noout -text 2>/dev/null) || return 1
  printf '%s\n' "$text" | grep -F "IP Address:${ip}" >/dev/null && return 0
  printf '%s\n' "$text" | grep -F "IP:${ip}" >/dev/null && return 0
  return 1
}

cert_public_matches_key() {
  local cert="$1" key="$2" cert_pub key_pub
  cert_pub=$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null || true)
  key_pub=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256 2>/dev/null || openssl rsa -in "$key" -pubout 2>/dev/null | openssl sha256 2>/dev/null || true)
  [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}

# 候选证书至少还要有效 1 小时，避免 apply 时切换到已过期或即将过期的证书。
candidate_validity_ok() {
  openssl x509 -in "$1" -noout -checkend 3600 >/dev/null 2>&1 &&
    openssl verify -CAfile "$1" "$1" >/dev/null 2>&1
}

rotation_candidate_reusable() {
  local phase cand key fp rec
  cand=$(cert_rotation_candidate_cert)
  key=$(cert_rotation_candidate_key)
  [[ -f "$cand" && -f "$key" && ! -L "$cand" && ! -L "$key" ]] || return 1
  [[ -f "$(cert_rotation_record_path)" ]] || return 1
  phase=$(read_rotation_kv phase 2>/dev/null || true)
  [[ "$phase" == prepared || "$phase" == needs_coordination ]] || return 1
  [[ "$(read_rotation_kv ip 2>/dev/null || true)" == "$IP_ADDR" ]] || return 1
  [[ "$(read_rotation_kv region_id 2>/dev/null || true)" == "$REGION_ID" ]] || return 1
  [[ "$(read_rotation_kv derp_port 2>/dev/null || true)" == "$DERP_PORT" ]] || return 1
  [[ "$(read_rotation_kv stun_port 2>/dev/null || true)" == "$STUN_PORT" ]] || return 1
  # 用户改了 --cert-days 就不能继续复用旧有效期的候选；候选已过期或即将过期同样不可复用。
  [[ "$(read_rotation_kv cert_days 2>/dev/null || true)" == "$CERT_DAYS" ]] || return 1
  candidate_validity_ok "$cand" || return 1
  cert_contains_ip_san "$cand" "$IP_ADDR" || return 1
  fp=$(openssl x509 -in "$cand" -outform DER | sha256_hex) || return 1
  rec=$(read_rotation_kv new_sha256 2>/dev/null || true)
  [[ "$fp" == "$rec" ]]
}

retire_unusable_candidate() {
  local cand key prev
  cand=$(cert_rotation_candidate_cert)
  key=$(cert_rotation_candidate_key)
  [[ -e "$cand" || -e "$key" ]] || return 0
  prev="$(cert_rotation_root)/previous-candidate"
  mkdir -p "$prev" || return 1
  if [[ -e "$cand" ]]; then
    mv -f "$cand" "$prev/cert.pem" || rm -f "$cand"
  fi
  if [[ -e "$key" ]]; then
    mv -f "$key" "$prev/key.pem" || rm -f "$key"
  fi
}

prepare_cert_rotation() {
  local live candidate_cert candidate_key root old_fp new_fp days
  [[ -n "$IP_ADDR" ]] || { echo "[错误] prepare 需要公网 IP。" >&2; return 1; }
  root=$(cert_rotation_root)
  mkdir -p "${root}/candidate" || return 1
  chmod 700 "$root" "${root}/candidate" 2>/dev/null || true
  live=$(resolve_disk_cert_pem || true)
  old_fp=""
  if [[ -n "$live" && -f "$live" && ! -L "$live" ]]; then
    old_fp=$(openssl x509 -in "$live" -outform DER | sha256_hex) || return 1
  fi
  candidate_cert=$(cert_rotation_candidate_cert)
  candidate_key=$(cert_rotation_candidate_key)
  if rotation_candidate_reusable; then
    new_fp=$(openssl x509 -in "$candidate_cert" -outform DER | sha256_hex) || return 1
  else
    retire_unusable_candidate || return 1
    write_selfsigned_pair "$candidate_cert" "$candidate_key" || return 1
    new_fp=$(openssl x509 -in "$candidate_cert" -outform DER | sha256_hex) || return 1
  fi
  days=$(cert_days_remaining || true)
  write_rotation_record <<EOF
kind=cert-rotation
phase=prepared
old_sha256=${old_fp:-none}
new_sha256=${new_fp}
region_id=${REGION_ID}
ip=${IP_ADDR}
derp_port=${DERP_PORT}
stun_port=${STUN_PORT}
cert_days=${CERT_DAYS}
tailnet=${TS_TAILNET:-unset}
etag=none
policy_mode=manual
lead_days=${CERT_LEAD_DAYS}
EOF
  print_acl_snippet_cert "$IP_ADDR" "$DERP_PORT" "$new_fp" >"$(cert_rotation_snippet_path)"
  echo "[信息] 已准备候选证书，正式服务未切换。片段：$(cert_rotation_snippet_path)" >&2
  echo "[信息] 旧指纹=${old_fp:-无} 新指纹=${new_fp}" >&2
}

cancel_cert_rotation() {
  local root
  root=$(cert_rotation_root)
  rm -rf "$root"
  echo "[信息] 已丢弃候选证书，正式证书未改动。" >&2
}

verify_switched_derper() {
  local expect live
  service_verified_running || return 1
  expect=$(openssl x509 -in "$(derper_manual_cert_file)" -outform DER | sha256_hex) || return 1
  live=$(live_cert_sha256_raw) || {
    echo "[错误] 未能读取服务实际加载的证书指纹。" >&2
    return 1
  }
  [[ "$live" == "$expect" ]] || {
    echo "[错误] 服务加载的指纹与新证书不一致。" >&2
    return 1
  }
}

restore_service_after_cert_rollback() {
  local was_running=0
  [[ -f "${SERVICE_PATH}.certs-rollback/was-running" ]] && was_running=1
  rollback_cert_update || return 1
  if [[ "$was_running" -eq 1 ]]; then
    if ! systemctl restart derper || ! verify_restored_service; then
      echo "[错误] 旧证书已恢复，但原服务未能重新启动并通过验证。" >&2
      return 1
    fi
  fi
}

_switch_live_certificate_from_candidate() {
  local live_cert live_key cand_cert cand_key backup
  live_cert=$(derper_manual_cert_file)
  live_key=$(derper_manual_key_file)
  cand_cert=$(cert_rotation_candidate_cert)
  cand_key=$(cert_rotation_candidate_key)
  [[ -f "$cand_cert" && -f "$cand_key" && ! -L "$cand_cert" && ! -L "$cand_key" ]] || return 1
  refuse_symlink "$INSTALL_DIR" || return 1
  refuse_symlink "${INSTALL_DIR}/certs" || return 1
  refuse_symlink "$live_cert" || return 1
  refuse_symlink "$live_key" || return 1
  begin_cert_update || return 1
  backup="${SERVICE_PATH}.certs-rollback"
  if ! cp -p "$cand_cert" "$live_cert" || ! cp -p "$cand_key" "$live_key"; then
    restore_service_after_cert_rollback || return 1
    return 1
  fi
  if ! repair_cert_layout; then
    restore_service_after_cert_rollback || return 1
    return 1
  fi
  if [[ -f "$backup/was-running" ]]; then
    if ! systemctl restart derper; then
      restore_service_after_cert_rollback || return 1
      return 1
    fi
    if ! verify_switched_derper; then
      echo "[错误] 切换后服务未通过运行或指纹核验，已恢复旧证书。" >&2
      restore_service_after_cert_rollback || return 1
      return 1
    fi
  fi
  if ! archive_completed_cert_transaction; then
    # 归档失败也要先恢复本地，再让调用者按实际旧身份决定云端补偿；
    # 不能等 EXIT 才回退，否则云端协调会早于本地身份恢复。
    restore_service_after_cert_rollback || return 1
    return 1
  fi
}

hujson_patch_certname() {
  _hujson_invoke patch "$@"
}

_hujson_invoke() {
  local hujson_mode="$1"
  shift
  local host="$2" region="$3" new="$4" old="${5:-}"
  command -v python3 >/dev/null 2>&1 || { echo "[错误] 自动策略补丁需要 python3。" >&2; return 1; }
  printf '%s' "$1" | env \
    POLICY_HUJSON_MODE="$hujson_mode" \
    POLICY_HUJSON_HOST="$host" POLICY_HUJSON_REGION="$region" POLICY_HUJSON_NEW="$new" POLICY_HUJSON_OLD="$old" \
    POLICY_HUJSON_CODE="${REGION_CODE}" POLICY_HUJSON_NAME="${REGION_NAME}" \
    POLICY_HUJSON_DERP="${DERP_PORT}" POLICY_HUJSON_STUN="${STUN_PORT}" \
    python3 -c '
import os, sys
s = sys.stdin.read()
host = os.environ["POLICY_HUJSON_HOST"]
region = os.environ["POLICY_HUJSON_REGION"]
new = os.environ["POLICY_HUJSON_NEW"]
old = os.environ.get("POLICY_HUJSON_OLD") or ""
code = os.environ.get("POLICY_HUJSON_CODE") or "my-derp"
name = os.environ.get("POLICY_HUJSON_NAME") or "My IP DERP"
derp = os.environ.get("POLICY_HUJSON_DERP") or "30399"
stun = os.environ.get("POLICY_HUJSON_STUN") or "3478"

def skip(t, i):
    n = len(t)
    while i < n:
        if t[i] in " \t\r\n":
            i += 1
            continue
        if t.startswith("//", i):
            nl = t.find("\n", i)
            i = n if nl < 0 else nl + 1
            continue
        if t.startswith("/*", i):
            end = t.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        break
    return i

def parse_str(t, i):
    assert t[i] == "\""
    i += 1
    out = []
    while i < len(t):
        c = t[i]
        if c == "\\":
            out.append(t[i:i+2]); i += 2; continue
        if c == "\"":
            return ("".join(out), i + 1)
        out.append(c); i += 1
    raise ValueError("unterminated string")

def match(t, i, open_ch, close_ch):
    depth = 0
    n = len(t)
    while i < n:
        j = skip(t, i)
        if j != i:
            i = j
            continue
        if t[i] == "\"":
            _, i = parse_str(t, i)
            continue
        if t[i] == open_ch:
            depth += 1
        elif t[i] == close_ch:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1

def object_fields(t, a, b):
    fields = {}
    i = a + 1
    while i < b:
        i = skip(t, i)
        if i >= b or t[i] in "}]":
            break
        if t[i] != "\"":
            i += 1
            continue
        key, i = parse_str(t, i)
        i = skip(t, i)
        if i < b and t[i] == ":":
            i += 1
        i = skip(t, i)
        if i >= b:
            break
        if t[i] == "\"":
            vs = i
            val, i = parse_str(t, i)
            fields[key] = ("str", val, vs, i)
        elif t[i] == "{":
            e = match(t, i, "{", "}")
            if e < 0:
                i = b
            else:
                fields[key] = ("obj", "", i, e + 1)
                i = e + 1
        elif t[i] == "[":
            e = match(t, i, "[", "]")
            if e < 0:
                i = b
            else:
                fields[key] = ("arr", "", i, e + 1)
                i = e + 1
        else:
            vs = i
            while i < b and t[i] not in ",}":
                i += 1
            fields[key] = ("raw", t[vs:i].strip(), vs, i)
        i = skip(t, i)
        if i < b and t[i] == ",":
            i += 1
    return fields

def iter_objects(t):
    i = 0
    n = len(t)
    while i < n:
        j = skip(t, i)
        if j != i:
            i = j
            continue
        if t[i] == "\"":
            _, i = parse_str(t, i)
            continue
        if t[i] == "{":
            e = match(t, i, "{", "}")
            if e < 0:
                break
            yield i, e
            i += 1
            continue
        i += 1

def last_significant(t, a, b):
    i = a + 1
    last = ""
    while i < b:
        j = skip(t, i)
        if j != i:
            i = j
            continue
        if i >= b:
            break
        c = t[i]
        if c == "\"":
            _, i = parse_str(t, i)
            last = "\""
            continue
        if c == "{":
            e = match(t, i, "{", "}")
            if e < 0:
                break
            last = "}"
            i = e + 1
            continue
        if c == "[":
            e = match(t, i, "[", "]")
            if e < 0:
                break
            last = "]"
            i = e + 1
            continue
        last = c
        i += 1
    return last

def insert_before_close(t, a, b, payload):
    last = last_significant(t, a, b)
    prefix = "" if last in ("", ",") else ","
    return t[:b] + prefix + payload + t[b:]

def find_root(t):
    i = skip(t, 0)
    if i < len(t) and t[i] == "{":
        e = match(t, i, "{", "}")
        if e >= 0 and skip(t, e + 1) == len(t):
            return i, e
    return None

matches = []
for a, b in iter_objects(s):
    f = object_fields(s, a, b)
    if "HostName" not in f:
        continue
    hn = f["HostName"][1]
    if hn != host:
        continue
    rid = ""
    if "RegionID" in f:
        rid = f["RegionID"][1]
    matches.append((a, b, f, rid))

host_hits = [m for m in matches if m[2]["HostName"][1] == host]
tool_mode = os.environ.get("POLICY_HUJSON_MODE") or "patch"
if tool_mode == "absent":
    # 只有策略根可解析且完全没有同 HostName 节点，才证明目标不存在；
    # 重复、Region 不匹配、CertName 缺失或结构异常一律不算“不存在”。
    if find_root(s) is None:
        sys.stderr.write("unparsable policy\n")
        sys.exit(2)
    sys.exit(0 if not host_hits else 2)
if tool_mode == "read":
    scoped = []
    for item in host_hits:
        rid = item[3]
        if (not region) or rid == str(region) or rid == "":
            scoped.append(item)
    if len(scoped) == 1 and "CertName" in scoped[0][2]:
        sys.stdout.write(scoped[0][2]["CertName"][1])
    sys.exit(0)
if tool_mode == "current":
    root = find_root(s)
    if root is None or len(host_hits) != 1:
        sys.exit(2)
    a, b, f, rid = host_hits[0]
    if (rid and rid != str(region)) or "CertName" not in f or f["CertName"][1] != new:
        sys.exit(2)
    # 必须位于指定 derpMap.Regions[region].Nodes 中，不能仅匹配全局同名对象。
    fields = object_fields(s, *root)
    for key in ("derpMap", "Regions", str(region)):
        entry = fields.get(key)
        if not entry or entry[0] != "obj":
            sys.exit(2)
        fields = object_fields(s, entry[2], entry[3] - 1)
    nodes = fields.get("Nodes")
    if (not nodes or nodes[0] != "arr" or not (nodes[2] < a < b < nodes[3])
            or ("RegionID" in fields and fields["RegionID"][1] != str(region))):
        sys.exit(2)
    sys.exit(0)
if len(host_hits) > 1:
    sys.stderr.write("conflict: duplicate HostName\n")
    sys.exit(2)
if len(host_hits) == 1:
    a, b, f, rid = host_hits[0]
    if rid and rid != str(region):
        sys.stderr.write("conflict: HostName region mismatch\n")
        sys.exit(2)
    if "CertName" not in f:
        sys.stderr.write("missing CertName\n")
        sys.exit(2)
    cur = f["CertName"][1]
    if old:
        if cur != old:
            sys.stderr.write("conflict: old fingerprint\n")
            sys.exit(2)
    else:
        sys.stderr.write("target exists\n")
        sys.exit(2)
    vs, ve = f["CertName"][2], f["CertName"][3]
    sys.stdout.write(s[:vs] + "\"" + new + "\"" + s[ve:])
    sys.exit(0)

# append
node = "{\"Name\":\"%sa\",\"RegionID\":%s,\"HostName\":\"%s\",\"DERPPort\":%s,\"STUNPort\":%s,\"CertName\":\"%s\"}" % (
    region, region, host, derp, stun, new)
region_obj = "\"%s\":{\"RegionID\":%s,\"RegionCode\":\"%s\",\"RegionName\":\"%s\",\"Nodes\":[%s]}" % (
    region, region, code.replace("\\", "\\\\").replace("\"", "\\\""), name.replace("\\", "\\\\").replace("\"", "\\\""), node)

# existing region?
region_span = None
for a, b in iter_objects(s):
    f = object_fields(s, a, b)
    if "RegionID" in f and f["RegionID"][1] == str(region) and "Nodes" in f:
        region_span = (a, b)
        break
if region_span:
    a, b = region_span
    rf = object_fields(s, a, b)
    if "Nodes" not in rf or rf["Nodes"][0] != "arr":
        sys.stderr.write("nodes array missing\n")
        sys.exit(2)
    ns, ne = rf["Nodes"][2], rf["Nodes"][3] - 1
    insert = node
    if last_significant(s, ns, ne) not in ("", ","):
        insert = "," + insert
    sys.stdout.write(s[:ne] + insert + s[ne:])
    sys.exit(0)

# insert region into derpMap.Regions or create
# find object with OmitDefaultRegions or key Regions containing RegionID children — locate "Regions" object by scanning keys of objects that have Regions nested. Simpler: find the substring '"Regions"' as a key outside comments via object_fields of derpMap-like objects.
regions_obj = None
for a, b in iter_objects(s):
    f = object_fields(s, a, b)
    if "Regions" in f or "OmitDefaultRegions" in f:
        # the Regions value is nested; find child object after the Regions key
        i = a + 1
        while i < b:
            i = skip(s, i)
            if i >= b or s[i] != "\"":
                if i < b:
                    if s[i] == "{":
                        i = match(s, i, "{", "}") + 1
                    else:
                        i += 1
                continue
            key, i = parse_str(s, i)
            i = skip(s, i)
            if i < b and s[i] == ":":
                i += 1
            i = skip(s, i)
            if key == "Regions" and i < b and s[i] == "{":
                e = match(s, i, "{", "}")
                regions_obj = (i, e)
                break
            if i < b and s[i] == "{":
                i = match(s, i, "{", "}") + 1
            elif i < b and s[i] == "[":
                i = match(s, i, "[", "]") + 1
            elif i < b and s[i] == "\"":
                _, i = parse_str(s, i)
            else:
                while i < b and s[i] not in ",}":
                    i += 1
        if regions_obj:
            break
if regions_obj:
    a, b = regions_obj
    last = last_significant(s, a, b)
    prefix = "" if last in ("", ",") else ","
    sys.stdout.write(s[:b] + prefix + region_obj + s[b:])
    sys.exit(0)

root = find_root(s)
if not root:
    sys.stderr.write("policy root is not an object\n")
    sys.exit(2)
ra, rb = root
rf = object_fields(s, ra, rb)
if "derpMap" not in rf:
    payload = "\"derpMap\":{\"Regions\":{" + region_obj + "}}"
    sys.stdout.write(insert_before_close(s, ra, rb, payload))
    sys.exit(0)
if rf["derpMap"][0] != "obj":
    sys.stderr.write("derpMap is not an object\n")
    sys.exit(2)
ds, de = rf["derpMap"][2], rf["derpMap"][3] - 1
df = object_fields(s, ds, de)
if "Regions" in df:
    if df["Regions"][0] != "obj":
        sys.stderr.write("Regions is not an object\n")
        sys.exit(2)
    rs, re_ = df["Regions"][2], df["Regions"][3] - 1
    last = last_significant(s, rs, re_)
    prefix = "" if last in ("", ",") else ","
    sys.stdout.write(s[:re_] + prefix + region_obj + s[re_:])
    sys.exit(0)
payload = "\"Regions\":{" + region_obj + "}"
sys.stdout.write(insert_before_close(s, ds, de, payload))
sys.exit(0)
' || return 1
}

load_policy_credentials() {
  local file="${POLICY_CREDENTIAL_FILE:-}" line key value uid mode
  TS_API_CLIENT_ID=""; TS_API_CLIENT_SECRET=""; POLICY_SOURCE=""; POLICY_TOKEN=""; POLICY_GRANTED_SCOPE=""
  [[ -n "${TS_TAILNET:-}" ]] || true
  [[ -n "$file" && -f "$file" && ! -L "$file" ]] || return 1
  if [[ "$(id -u 2>/dev/null || true)" == 0 ]]; then
    uid=$(stat -c %u "$file" 2>/dev/null || stat -f %u "$file") || return 1
    mode=$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file") || return 1
    [[ "$uid" == 0 ]] && (( (8#$mode & 0077) == 0 )) || { echo "[错误] 策略凭据必须归 root 且权限为 0600。" >&2; return 1; }
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$line" && "$line" != \#* ]] || continue
    [[ "$line" == *=* ]] || return 1
    key=${line%%=*}; value=${line#*=}
    case "$value" in *'$'*|*'`'*|*';'*|*'|'*|*'&'*) echo "[错误] 凭据文件不允许 shell 语法。" >&2; return 1 ;; esac
    case "$key" in
      TS_TAILNET) TS_TAILNET=$value ;;
      TS_API_CLIENT_ID) TS_API_CLIENT_ID=$value ;;
      TS_API_CLIENT_SECRET) TS_API_CLIENT_SECRET=$value ;;
      TS_API_BASE) TS_API_BASE=$value ;;
      TS_API_TOKEN) POLICY_TOKEN=$value ;;
      POLICY_SOURCE) POLICY_SOURCE=$value ;;
      *) echo "[错误] 凭据文件含未知字段。" >&2; return 1 ;;
    esac
  done <"$file"
  return 0
}

policy_http_request() {
  local method="$1" urlpath="$2" body="${3:-}" url out rc=0
  url="${TS_API_BASE}${urlpath}"
  if ! command -v curl >/dev/null 2>&1; then
    echo "[错误] 缺少 curl，无法访问策略 API。" >&2
    return 1
  fi
  local args=(-sS -D - --max-time 20 -X "$method")
  [[ -n "${POLICY_TOKEN:-}" ]] && args+=(-H "Authorization: Bearer ${POLICY_TOKEN}")
  case "$urlpath" in
    */acl|*/acl/validate) args+=(-H "Accept: application/hujson") ;;
  esac
  if [[ "$method" == POST && "$urlpath" == */acl/validate ]]; then
    args+=(-H "Content-Type: application/hujson")
  fi
  if [[ "$method" == POST && "$urlpath" == */acl && "$urlpath" != */validate ]]; then
    [[ -n "${POLICY_IF_MATCH:-}" ]] && args+=(-H "If-Match: ${POLICY_IF_MATCH}")
    args+=(-H "Content-Type: application/hujson")
  fi
  if [[ "$urlpath" == */oauth/token ]]; then
    args+=(-H "Content-Type: application/x-www-form-urlencoded")
  fi
  if [[ -n "$body" ]]; then
    out=$(curl "${args[@]}" --data-binary "$body" "$url") || rc=$?
  else
    out=$(curl "${args[@]}" "$url") || rc=$?
  fi
  printf '%s' "$out"
  return "$rc"
}

_policy_http_status() {
  local out="$1" line
  line=$(printf '%s\n' "$out" | head -n 1 | tr -d '\r')
  case "$line" in
    HTTP/*)
      printf '%s\n' "$line" | awk '{print $2}'
      ;;
    *)
      printf '200\n'
      ;;
  esac
}

_policy_http_body() {
  local out="$1"
  if printf '%s\n' "$out" | grep -q $'^etag:'; then
    printf '%s\n' "$out" | awk 'BEGIN{b=0} /^etag:/{next} /^\r?$/{b=1; next} b{print}'
    return 0
  fi
  printf '%s\n' "$out" | awk 'BEGIN{b=0} /^\r?$/{b=1; next} b{print}'
}

_policy_http_etag() {
  local out="$1"
  printf '%s\n' "$out" | awk 'tolower($1)=="etag:"{sub("\r",""); $1=""; sub(/^ /,""); print; exit}'
}

obtain_policy_token() {
  [[ -n "${POLICY_TOKEN:-}" ]] && return 0
  [[ -n "${TS_API_CLIENT_ID:-}" && -n "${TS_API_CLIENT_SECRET:-}" ]] || return 1
  local body out rc=0 status parsed token scope
  body="grant_type=client_credentials&client_id=${TS_API_CLIENT_ID}&client_secret=${TS_API_CLIENT_SECRET}&scope=policy_file"
  out=$(policy_http_request POST /api/v2/oauth/token "$body") || rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"
  status=$(_policy_http_status "$out")
  case "$status" in
    2*) ;;
    *) return 1 ;;
  esac
  command -v python3 >/dev/null 2>&1 || { echo "[错误] 解析 OAuth 响应需要 python3。" >&2; return 1; }
  parsed=$(printf '%s\n' "$out" | python3 -c '
import json, sys
raw = sys.stdin.read()
if "\r\n\r\n" in raw:
    raw = raw.split("\r\n\r\n", 1)[1]
elif "\n\n" in raw:
    raw = raw.split("\n\n", 1)[1]
raw = raw.strip()
token = ""
scope = ""
if raw.startswith("{"):
    try:
        data = json.loads(raw)
    except Exception:
        sys.exit(1)
    token = data.get("access_token") or ""
    scope = data.get("scope") or ""
    if isinstance(scope, list):
        scope = " ".join(str(item) for item in scope)
else:
    text = raw.replace("&", "\n").replace(",", "\n").replace("{", "\n").replace("}", "\n").replace("\"", "")
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("access_token="):
            token = line.split("=", 1)[1].strip()
        elif line.startswith("scope="):
            scope = line.split("=", 1)[1].strip()
if not token:
    sys.exit(1)
sys.stdout.write(token + "\n" + str(scope) + "\n")
') || return 1
  token=$(printf '%s\n' "$parsed" | sed -n '1p')
  scope=$(printf '%s\n' "$parsed" | sed -n '2p')
  [[ -n "$token" ]] || return 1
  POLICY_TOKEN=$token
  POLICY_GRANTED_SCOPE=$scope
}

policy_target_is_configured() {
  local tailnet="${TS_TAILNET:-}"
  [[ -n "${tailnet//[[:space:]]/}" ]]
}

policy_auth_state() {
  if ! load_policy_credentials 2>/dev/null; then
    printf 'none\n'
    return 0
  fi
  if [[ "${POLICY_SOURCE:-}" == gitops ]]; then
    printf 'gitops\n'
    return 0
  fi
  if ! policy_target_is_configured; then
    printf 'none\n'
    return 0
  fi
  if [[ -z "$TS_API_CLIENT_ID$POLICY_TOKEN" ]]; then
    printf 'none\n'
    return 0
  fi
  local rc=0
  obtain_policy_token || rc=$?
  if [[ "$rc" -eq 28 ]]; then
    printf 'unknown\n'
    return 0
  fi
  if [[ "$rc" -ne 0 || -z "$POLICY_TOKEN" ]]; then
    printf 'none\n'
    return 0
  fi
  local scope="${POLICY_GRANTED_SCOPE:-}"
  if [[ -z "$scope" ]]; then
    printf 'unknown\n'
    return 0
  fi
  if printf '%s' "$scope" | grep -Eq '(^|[ ,])policy_file($|[ ,])'; then
    printf 'write_ready\n'
  elif printf '%s' "$scope" | grep -q 'policy_file:read'; then
    printf 'read_only\n'
  else
    printf 'unknown\n'
  fi
}

auto_maintain_consented() {
  local intent mode
  [[ "${DISABLE_AUTO_MAINTAIN:-0}" == 1 ]] && return 1
  intent=$(read_maintenance_kv intent 2>/dev/null || true)
  mode=$(read_maintenance_kv mode 2>/dev/null || true)
  [[ "${ENABLE_AUTO_MAINTAIN:-0}" == 1 ]] && return 0
  [[ "$intent" == enabled ]] && return 0
  [[ "$intent" != disabled && "$mode" == ready ]] && return 0
  return 1
}

evaluate_auto_maintain_readiness() {
  local auth
  if [[ "${DISABLE_AUTO_MAINTAIN:-0}" == 1 ]]; then
    printf 'manual\n'
    return 0
  fi
  # 用户启用意图与调度安装结果分开保存；授权恢复和维护重试不能抹去调度失败。
  if [[ "$(maintenance_scheduler_state)" == failed ]]; then
    printf 'unknown\n'
    return 0
  fi
  auth=$(policy_auth_state)
  case "$auth" in
    gitops|none|read_only)
      printf 'manual\n'
      ;;
    unknown)
      printf 'unknown\n'
      ;;
    write_ready)
      if auto_maintain_consented; then
        printf 'ready\n'
      else
        printf 'manual\n'
      fi
      ;;
    *)
      printf 'unknown\n'
      ;;
  esac
}

print_auto_maintain_feedback() {
  local mode="$1" days
  days=$(cert_days_remaining || true)
  echo "[信息] 服务器已部署。"
  case "$mode" in
    ready)
      echo "云端授权和维护任务已就绪；已启用本节点自动换证及指纹同步。"
      echo "当前证书剩余约 ${days:-未知} 天；提前维护 ${CERT_LEAD_DAYS} 天；结果查看：$(maintenance_status_path) 与 journalctl -u derper-cert-maintain。"
      echo "当前没有站外通知。"
      ;;
    unknown)
      echo "云端检查超时/授权状态无法确认/维护执行条件未就绪，目前不能承诺自动更新。"
      echo "请查看原因后重试；也可按下面的人工步骤处理。不要把当前状态当成确定的授权结论。"
      [[ "${DEPLOY_CLIENT_GUIDANCE_PRINTED:-0}" == 1 ]] || print_client_verify_steps
      ;;
    *)
      echo "未配置云端自动维护授权/当前凭据只读，因此没有启用自动换证。"
      echo "到期提示仅在执行检查时输出；如需周期检查，请显式配置 --install-healthcheck-cron 并核对 timer/cron。当前没有站外通知。"
      echo "片段已保存：$(cert_rotation_snippet_path 2>/dev/null || echo 见部署输出)。"
      [[ "${DEPLOY_CLIENT_GUIDANCE_PRINTED:-0}" == 1 ]] || print_client_verify_steps
      ;;
  esac
}

policy_get_acl() {
  local out rc=0
  out=$(policy_http_request GET "/api/v2/tailnet/${TS_TAILNET}/acl") || rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"
  POLICY_HTTP_STATUS=$(_policy_http_status "$out")
  POLICY_IF_MATCH=$(_policy_http_etag "$out")
  _policy_http_body "$out"
}

policy_load_acl() {
  local out rc=0
  out=$(policy_http_request GET "/api/v2/tailnet/${TS_TAILNET}/acl") || rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"
  POLICY_HTTP_STATUS=$(_policy_http_status "$out")
  case "$POLICY_HTTP_STATUS" in
    2*) ;;
    *) echo "[错误] 读取云端策略失败，HTTP ${POLICY_HTTP_STATUS}。" >&2; return 1 ;;
  esac
  POLICY_IF_MATCH=$(_policy_http_etag "$out")
  POLICY_ACL_BODY=$(_policy_http_body "$out")
  [[ -n "$POLICY_IF_MATCH" ]] || { echo "[错误] 策略响应没有 ETag，拒绝自动提交。" >&2; return 1; }
}

policy_validate_acl() {
  local body="$1" out rc=0 status response
  out=$(policy_http_request POST "/api/v2/tailnet/${TS_TAILNET}/acl/validate" "$body") || rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"
  status=$(_policy_http_status "$out")
  POLICY_HTTP_STATUS=$status
  response=$(_policy_http_body "$out")
  case "$status" in
    2*) ;;
    *) echo "[错误] 策略 validate 被拒绝，HTTP ${status}。" >&2; return 1 ;;
  esac
  if printf '%s' "$response" | grep -q '"message"'; then
    echo "[错误] 策略 validate 返回错误。" >&2
    return 1
  fi
}

policy_put_acl() {
  local body="$1" out rc=0 status
  out=$(policy_http_request POST "/api/v2/tailnet/${TS_TAILNET}/acl" "$body") || rc=$?
  status=$(_policy_http_status "$out")
  POLICY_HTTP_STATUS=$status
  if [[ "$rc" -ne 0 ]]; then
    return "$rc"
  fi
  case "$status" in
    2*) printf '%s' "$out" ;;
    *) return 1 ;;
  esac
}

# 0 确认云端没有本节点；非 0 表示存在、有歧义或策略无法可靠解析。
_cloud_target_absent_from_acl() {
  local acl="$1" host="$2" region="${3:-${REGION_ID:-}}"
  _hujson_invoke absent "$acl" "$host" "$region" placeholder "" >/dev/null 2>&1
}

_cloud_certname_from_acl() {
  local acl="$1" host="$2" region="${3:-${REGION_ID:-}}"
  _hujson_invoke read "$acl" "$host" "$region" placeholder "" 2>/dev/null || true
}

sync_policy_for_candidate() {
  local old_fp new_fp old_name new_name acl patched rc=0 readback current
  old_fp=$(read_rotation_kv old_sha256)
  new_fp=$(read_rotation_kv new_sha256)
  [[ "$old_fp" == none ]] && old_fp=""
  old_name=""; [[ -n "$old_fp" ]] && old_name="sha256-raw:${old_fp}"
  new_name="sha256-raw:${new_fp}"
  if ! policy_load_acl; then
    echo "[错误] 无法读取云端策略。" >&2
    return 1
  fi
  acl=$POLICY_ACL_BODY
  # 上次提交成功但读回失败或进程中断：先核验唯一目标与当前候选，
  # 确认后直接继续本地切换，避免用旧指纹再次补丁造成永久冲突。
  if _hujson_invoke current "$acl" "$IP_ADDR" "$REGION_ID" "$new_name" "" >/dev/null 2>&1; then
    echo "[信息] 云端已采用当前候选指纹，继续本地切换。" >&2
    return 0
  fi
  patched=$(hujson_patch_certname "$acl" "$IP_ADDR" "$REGION_ID" "$new_name" "$old_name") || {
    echo "[错误] 云端目标冲突或无法生成最小补丁，已转人工协调。" >&2
    write_rotation_record <<EOF
kind=cert-rotation
phase=needs_coordination
old_sha256=${old_fp:-none}
new_sha256=${new_fp}
region_id=${REGION_ID}
ip=${IP_ADDR}
derp_port=${DERP_PORT}
stun_port=${STUN_PORT}
cert_days=${CERT_DAYS}
tailnet=${TS_TAILNET:-unset}
etag=none
policy_mode=manual
lead_days=${CERT_LEAD_DAYS}
EOF
    write_maintenance_status unknown needs_coordination "云端目标冲突" 1
    return 1
  }
  policy_validate_acl "$patched" || { echo "[错误] 策略 validate 失败，未提交。" >&2; return 1; }
  rc=0
  policy_put_acl "$patched" >/dev/null || rc=$?
  if [[ "${POLICY_HTTP_STATUS:-}" == 412 ]]; then
    echo "[错误] 云端 ETag 冲突，其他人可能已修改策略。待协调，未切换本地证书。" >&2
    write_maintenance_status unknown needs_coordination "ETag冲突" 1
    write_rotation_record <<EOF
kind=cert-rotation
phase=needs_coordination
old_sha256=${old_fp:-none}
new_sha256=${new_fp}
region_id=${REGION_ID}
ip=${IP_ADDR}
derp_port=${DERP_PORT}
stun_port=${STUN_PORT}
cert_days=${CERT_DAYS}
tailnet=${TS_TAILNET:-unset}
etag=none
policy_mode=manual
lead_days=${CERT_LEAD_DAYS}
EOF
    return 1
  fi
  if ! policy_load_acl; then
    POLICY_ACL_BODY=""
  fi
  current=$(_cloud_certname_from_acl "${POLICY_ACL_BODY:-}" "$IP_ADDR")
  if [[ "$current" == "$new_name" ]]; then
    return 0
  fi
  if [[ "$rc" -eq 28 ]]; then
    echo "[错误] 策略提交超时且读回未确认新指纹，不把超时当作未写入成功，也不切换本地。" >&2
    write_maintenance_status unknown needs_coordination "提交超时待确认" 1
    return 1
  fi
  if [[ -n "$current" && "$current" != "$old_name" && "$current" != "$new_name" ]]; then
    echo "[错误] 云端 CertName 已被他人改动，停止自动回退，待协调。" >&2
    write_maintenance_status unknown needs_coordination "他人已改目标" 1
    return 1
  fi
  echo "[错误] 云端未接受本次 CertName 更新。" >&2
  return 1
}

assert_prepared_identity() {
  local rec_ip rec_region rec_derp rec_stun rec_tail rec_days rec_new rec_old cand live cur
  rec_ip=$(read_rotation_kv ip) || return 1
  rec_region=$(read_rotation_kv region_id) || return 1
  rec_derp=$(read_rotation_kv derp_port) || return 1
  rec_stun=$(read_rotation_kv stun_port) || return 1
  rec_tail=$(read_rotation_kv tailnet) || return 1
  rec_days=$(read_rotation_kv cert_days) || return 1
  rec_new=$(read_rotation_kv new_sha256) || return 1
  rec_old=$(read_rotation_kv old_sha256) || return 1
  if [[ "$rec_ip" != "$IP_ADDR" || "$rec_region" != "$REGION_ID" || "$rec_derp" != "$DERP_PORT" || "$rec_stun" != "$STUN_PORT" || "$rec_days" != "$CERT_DAYS" ]]; then
    echo "[错误] 本次参数与 prepare 记录的目标身份不一致，请重新 prepare。" >&2
    return 1
  fi
  if [[ -n "${TS_TAILNET:-}" && "$rec_tail" != unset && "$rec_tail" != "$TS_TAILNET" ]]; then
    echo "[错误] Tailnet 与 prepare 记录不一致，请重新 prepare。" >&2
    return 1
  fi
  cand=$(cert_rotation_candidate_cert)
  [[ -f "$cand" && ! -L "$cand" ]] || { echo "[错误] 候选证书不存在，请重新 prepare。" >&2; return 1; }
  cert_contains_ip_san "$cand" "$IP_ADDR" || { echo "[错误] 候选证书 SAN 与目标 IP 不一致，请重新 prepare。" >&2; return 1; }
  candidate_validity_ok "$cand" || { echo "[错误] 候选证书尚未生效、已过期或剩余有效期不足 1 小时，请重新 prepare。" >&2; return 1; }
  cert_public_matches_key "$cand" "$(cert_rotation_candidate_key)" || { echo "[错误] 候选证书与私钥不匹配，请重新 prepare。" >&2; return 1; }
  cur=$(openssl x509 -in "$cand" -outform DER | sha256_hex) || return 1
  [[ "$cur" == "$rec_new" ]] || { echo "[错误] 候选指纹与 prepare 记录不一致，请重新 prepare。" >&2; return 1; }
  live=$(resolve_disk_cert_pem || true)
  if [[ "$rec_old" == none || -z "$rec_old" ]]; then
    if [[ -n "$live" && -f "$live" ]]; then
      echo "[错误] prepare 之后出现了正式证书，请重新 prepare。" >&2
      return 1
    fi
  else
    [[ -n "$live" && -f "$live" && ! -L "$live" ]] || { echo "[错误] 正式证书已变化，请重新 prepare。" >&2; return 1; }
    cur=$(openssl x509 -in "$live" -outform DER | sha256_hex) || return 1
    [[ "$cur" == "$rec_old" ]] || { echo "[错误] 正式证书指纹与 prepare 记录不一致，请重新 prepare。" >&2; return 1; }
  fi
}

# 磁盘回退成功不代表运行进程已重新加载旧证书。曾运行的服务必须恢复并匹配旧指纹；
# 原先停止的服务保持停止时，只核对磁盘旧身份，不擅自启动服务。
local_old_cert_identity_restored() {
  local old_fp disk_fp live_fp backup="${SERVICE_PATH}.certs-rollback"
  old_fp=$(read_rotation_kv old_sha256) || return 1
  [[ "$old_fp" != none && -n "$old_fp" ]] || return 1
  disk_fp=$(openssl x509 -in "$(derper_manual_cert_file)" -outform DER 2>/dev/null | sha256_hex) || return 1
  [[ "$disk_fp" == "$old_fp" ]] || return 1
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet derper; then
    verify_restored_service || return 1
    live_fp=$(live_cert_sha256_raw) || return 1
    [[ "$live_fp" == "$old_fp" ]] || return 1
  else
    [[ "${CERT_ROLLBACK_WAS_RUNNING:-0}" != 1 && ! -f "$backup/was-running" ]] || return 1
  fi
}

# D2/D4 安全反向补偿：自动模式下云端 PUT 已成功（云端指向本次新指纹）后本地切换失败时，
# 基于最新策略和 ETag 只撤回本工具写入的 CertName 字段，不回写整份旧策略。
# 云端已被他人改动目标则停止自动回退并转人工；首次登记无旧指纹时无法反向补丁，转人工。
reverse_compensate_certname() {
  local old_fp new_fp old_name new_name acl patched rc current
  old_fp=$(read_rotation_kv old_sha256)
  new_fp=$(read_rotation_kv new_sha256)
  new_name="sha256-raw:${new_fp}"
  if [[ "$old_fp" == none || -z "$old_fp" ]]; then
    echo "[错误] 首次登记无旧指纹，无法生成反向最小补丁；若云端已登记本节点新指纹，转人工协调，不回写整份旧策略。" >&2
    write_maintenance_status unknown needs_coordination "首次登记无法反向补偿" 1
    return 1
  fi
  old_name="sha256-raw:${old_fp}"
  if ! policy_load_acl; then
    echo "[错误] 反向补偿：无法读取最新云端策略，转人工协调，未回写整份旧策略。" >&2
    write_maintenance_status unknown needs_coordination "反向补偿读策略失败" 1
    return 1
  fi
  acl=$POLICY_ACL_BODY
  current=$(_cloud_certname_from_acl "$acl" "$IP_ADDR")
  if [[ -z "$current" ]]; then
    if _cloud_target_absent_from_acl "$acl" "$IP_ADDR"; then
      echo "[信息] 云端确认没有本节点条目，无需反向补偿。" >&2
      return 0
    fi
    echo "[错误] 反向补偿：云端目标有歧义（重复 HostName、Region 不匹配、CertName 缺失）或策略无法可靠解析，不能当作无需补偿，转人工协调。" >&2
    write_maintenance_status unknown needs_coordination "反向补偿目标歧义" 1
    return 1
  fi
  if [[ "$current" != "$new_name" ]]; then
    echo "[错误] 云端 CertName 已非本次新指纹（他人可能已改动），停止自动反向回退，转人工协调。" >&2
    write_maintenance_status unknown needs_coordination "反向补偿目标已变" 1
    return 1
  fi
  patched=$(hujson_patch_certname "$acl" "$IP_ADDR" "$REGION_ID" "$old_name" "$new_name") || {
    echo "[错误] 反向补偿：无法生成最小补丁，转人工协调，未回写整份旧策略。" >&2
    write_maintenance_status unknown needs_coordination "反向补偿补丁失败" 1
    return 1
  }
  policy_validate_acl "$patched" || { echo "[错误] 反向补偿 validate 失败，未提交。" >&2; write_maintenance_status unknown needs_coordination "反向补偿validate失败" 1; return 1; }
  rc=0
  policy_put_acl "$patched" >/dev/null || rc=$?
  if [[ "${POLICY_HTTP_STATUS:-}" == 412 ]]; then
    echo "[错误] 反向补偿 ETag 冲突，他人可能已修改策略，转人工协调。" >&2
    write_maintenance_status unknown needs_coordination "反向补偿ETag冲突" 1
    return 1
  fi
  if [[ "$rc" -ne 0 && "$rc" -ne 28 ]]; then
    echo "[错误] 反向补偿提交失败（rc=$rc），转人工协调。" >&2
    write_maintenance_status unknown needs_coordination "反向补偿提交失败" 1
    return 1
  fi
  # 超时(rc=28)或成功：读回核实，不把超时直接当作已回退。
  if ! policy_load_acl; then
    POLICY_ACL_BODY=""
  fi
  current=$(_cloud_certname_from_acl "${POLICY_ACL_BODY:-}" "$IP_ADDR")
  if [[ "$current" == "$old_name" ]]; then
    echo "[信息] 反向补偿成功：云端 CertName 已回退到旧指纹。" >&2
    return 0
  fi
  if [[ "$current" == "$new_name" ]]; then
    echo "[错误] 反向补偿读回仍为新指纹，未确认回退，转人工协调。" >&2
    write_maintenance_status unknown needs_coordination "反向补偿读回未确认" 1
    return 1
  fi
  echo "[错误] 反向补偿读回为未知值（他人已改），转人工协调。" >&2
  write_maintenance_status unknown needs_coordination "反向补偿读回已变" 1
  return 1
}

apply_cert_rotation() {
  local phase auth auto=0 auth_file
  if [[ "${DISABLE_AUTO_MAINTAIN:-0}" == 1 && "${ACCEPT_CERT_ROTATION:-0}" -ne 1 ]]; then
    echo "[信息] 已请求停用自动维护，本次不按历史授权切换证书。" >&2
    return 0
  fi
  # 在任何云端指纹变更前拒绝不安全的安装根目录；底层切换仍在事务前复查。
  refuse_symlink "$INSTALL_DIR" || return 1
  load_policy_credentials 2>/dev/null || true
  [[ -f "$(cert_rotation_record_path)" ]] || { echo "[错误] 没有可应用的候选，请先 prepare。" >&2; return 1; }
  phase=$(read_rotation_kv phase) || return 1
  [[ "$phase" == prepared || "$phase" == needs_coordination ]] || { echo "[错误] 候选阶段不是 prepared。" >&2; return 1; }
  assert_prepared_identity || return 1
  auth_file=$(mktemp)
  policy_auth_state >"$auth_file"
  auth=$(cat "$auth_file")
  rm -f "$auth_file"
  if auto_maintain_consented; then
    if [[ "$auth" == write_ready ]]; then
      auto=1
    fi
  fi
  if [[ "$auto" -eq 1 ]]; then
    sync_policy_for_candidate || return 1
  else
    if [[ "${ACCEPT_CERT_ROTATION:-0}" -ne 1 ]]; then
      echo "[中止] --yes 不确认指纹轮换；安排变更窗口后使用 --accept-cert-rotation。原证书保持不变。" >&2
      return 1
    fi
  fi
  _switch_live_certificate_from_candidate || {
    if [[ "$auto" -eq 1 ]]; then
      if local_old_cert_identity_restored; then
        echo "[错误] 本地切换失败，已确认旧身份恢复。尝试基于最新策略和 ETag 只反向补偿本工具写入的云端字段，不回写整份旧策略。" >&2
        reverse_compensate_certname || true
      else
        echo "[错误] 本地旧身份未确认恢复，保留云端指纹，停止自动反向补偿，转人工协调。" >&2
        write_maintenance_status unknown needs_coordination "本地旧身份未确认恢复" 1
      fi
    fi
    return 1
  }
  write_rotation_record <<EOF
kind=cert-rotation
phase=applied
old_sha256=$(read_rotation_kv old_sha256)
new_sha256=$(read_rotation_kv new_sha256)
region_id=${REGION_ID}
ip=${IP_ADDR}
derp_port=${DERP_PORT}
stun_port=${STUN_PORT}
cert_days=${CERT_DAYS}
tailnet=${TS_TAILNET:-unset}
etag=none
policy_mode=$([[ "$auto" -eq 1 ]] && echo auto || echo manual)
lead_days=${CERT_LEAD_DAYS}
EOF
  echo "[信息] 已切换本地证书。单节点 CertName 更新不是原子操作，不承诺零中断。" >&2
  echo "[信息] 未验证独立客户端是否已收到新指纹；真实 H3 另验。" >&2
}

cert_rotation_is_due() {
  local days lead
  days=$(cert_days_remaining || true)
  lead="${CERT_LEAD_DAYS:-30}"
  # 0 已到维护日期；1 确定未到；2 到期日或提前天数无法确定（不能伪装成“未到期”）。
  [[ "$days" =~ ^-?[0-9]+$ ]] || return 2
  [[ "$lead" =~ ^[0-9]+$ ]] || return 2
  [[ "$lead" -lt 1 ]] && return 2
  if [[ "$days" -le "$lead" ]]; then
    return 0
  fi
  return 1
}

run_cert_maintain() {
  local mode
  mode=$(evaluate_auto_maintain_readiness)
  if [[ "$mode" != ready ]]; then
    write_maintenance_status "$mode" skipped "条件不满足，未更换证书" 1
    echo "[信息] 维护条件为 ${mode}，保留现有有效证书。" >&2
    return 1
  fi
  local due_rc=0
  cert_rotation_is_due || due_rc=$?
  case "$due_rc" in
    0) ;;
    1)
      write_maintenance_status ready idle "未到提前维护日期" 0
      return 0
      ;;
    *)
      echo "[错误] 无法计算证书到期时间（证书不可读、openssl 异常或日期无法解析），不能判断是否需要续期，请人工检查。" >&2
      write_maintenance_status ready failed "无法计算证书到期时间" 1
      return 1
      ;;
  esac
  prepare_cert_rotation || { write_maintenance_status ready failed "prepare失败" 1; return 1; }
  if apply_cert_rotation; then
    write_maintenance_status ready success_replaced "已按登记策略换证" 0
    return 0
  fi
  if [[ "$(read_maintenance_kv result 2>/dev/null || true)" != needs_coordination ]]; then
    write_maintenance_status ready failed "换证失败已保留候选" 1
  fi
  return 1
}

write_maintain_target_config() {
  local file="$1" tmp dir
  dir=$(dirname "$file")
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "${dir}/.target.XXXXXX") || return 1
  {
    printf 'CONFIG_VERSION=1\n'
    [[ -n "${IP_ADDR:-}" ]] && printf 'IP_ADDR=%s\n' "$IP_ADDR"
    printf 'DERP_PORT=%s\n' "$DERP_PORT"
    printf 'STUN_PORT=%s\n' "$STUN_PORT"
    printf 'CERT_DAYS=%s\n' "$CERT_DAYS"
    printf 'CERT_LEAD_DAYS=%s\n' "${CERT_LEAD_DAYS:-30}"
    printf 'REGION_ID=%s\n' "$REGION_ID"
    printf 'REGION_CODE=%s\n' "$REGION_CODE"
    printf 'REGION_NAME=%s\n' "$REGION_NAME"
    printf 'ALLOW_NON_GLOBAL_IP=%s\n' "${ALLOW_NON_GLOBAL_IP:-0}"
    printf 'RUN_USER=%s\n' "$RUN_USER"
    printf 'VERIFY_CLIENTS_MODE=%s\n' "$VERIFY_CLIENTS_MODE"
    [[ -n "${TS_TAILNET:-}" ]] && printf 'TS_TAILNET=%s\n' "$TS_TAILNET"
    [[ -n "${POLICY_CREDENTIAL_FILE:-}" ]] && printf 'POLICY_CREDENTIAL_FILE=%s\n' "$POLICY_CREDENTIAL_FILE"
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file"
}

activate_cert_maintain_timer() {
  command -v systemctl >/dev/null 2>&1 || { echo "[错误] 未找到 systemctl，不能启用维护 timer。" >&2; return 1; }
  systemctl daemon-reload || return 1
  systemctl enable --now derper-cert-maintain.timer || return 1
  systemctl is-enabled --quiet derper-cert-maintain.timer || return 1
  systemctl is-active --quiet derper-cert-maintain.timer || return 1
}

install_cert_maintain_units() {
  local unit_dir self dest svc timer lib conf prog conf_esc
  unit_dir="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
  mkdir -p "$unit_dir" || return 1
  self=$(script_self_path 2>/dev/null || true)
  [[ -n "$self" && -f "$self" && ! -L "$self" ]] || { echo "[错误] 找不到部署脚本，不能安装维护任务。" >&2; return 1; }
  lib="$(deploy_state_root)/maintenance"
  mkdir -p "$lib" || return 1
  chmod 700 "$lib" 2>/dev/null || true
  dest="${lib}/deploy_derper_ip_selfsigned.sh"
  if [[ "$self" != "$dest" ]]; then
    atomic_copy_file "$self" "$dest" || return 1
  fi
  chmod 755 "$dest" || return 1
  conf="${lib}/target.conf"
  write_maintain_target_config "$conf" || return 1
  svc="${unit_dir}/derper-cert-maintain.service"
  timer="${unit_dir}/derper-cert-maintain.timer"
  prog=$(systemd_escape_arg "$dest")
  conf_esc=$(systemd_escape_arg "$conf")
  atomic_install_file "$svc" <<EOF || return 1
[Unit]
Description=DERP certificate maintenance
After=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash ${prog} maintain --config ${conf_esc}
Nice=10
EOF
  atomic_install_file "$timer" <<'EOF' || return 1
[Unit]
Description=Periodic DERP certificate maintenance
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
EOF
  echo "[信息] 已写出独立维护任务 ${svc} / ${timer}。凭据仍只在 ${POLICY_CREDENTIAL_FILE}。" >&2
}

remove_cert_maintain_units() {
  local unit_dir svc timer
  unit_dir="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
  svc="${unit_dir}/derper-cert-maintain.service"
  timer="${unit_dir}/derper-cert-maintain.timer"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now derper-cert-maintain.timer >/dev/null 2>&1 || true
    systemctl disable --now derper-cert-maintain.service >/dev/null 2>&1 || true
  fi
  rm -f "$svc" "$timer" 2>/dev/null || true
  if [[ -e "$svc" || -L "$svc" || -e "$timer" || -L "$timer" ]]; then
    echo "[错误] 维护 unit 文件未能删除：${svc} / ${timer}" >&2
    return 1
  fi
  if command -v systemctl >/dev/null 2>&1; then
    if ! systemctl daemon-reload >/dev/null 2>&1; then
      echo "[错误] 删除维护 unit 后 systemctl daemon-reload 失败，无法确认调度状态已刷新。" >&2
      return 1
    fi
    # 文件已删除并不代表调度已停止：核对启用状态与运行状态。
    local unit
    for unit in derper-cert-maintain.timer derper-cert-maintain.service; do
      if systemctl is-enabled --quiet "$unit" >/dev/null 2>&1; then
        echo "[错误] ${unit} 仍处于启用状态，自动换证调度可能继续执行。" >&2
        return 1
      fi
      if systemctl is-active --quiet "$unit" >/dev/null 2>&1; then
        echo "[错误] ${unit} 仍在运行，自动换证调度可能继续执行。" >&2
        return 1
      fi
    done
  fi
  return 0
}

apply_auto_maintain_policy() {
  if [[ "${DISABLE_AUTO_MAINTAIN:-0}" == 1 ]]; then
    write_maintenance_status manual disabled "已关闭自动换证" 0 "" disabled disabled || return 1
    if ! remove_cert_maintain_units; then
      write_maintenance_status manual failed "未能完全删除维护任务" 1 "" disabled failed || true
      echo "[错误] 未能完全删除维护 service/timer，自动换证调度可能仍会执行，请人工清理后重试。" >&2
      return 1
    fi
    return 0
  fi
  if [[ "${ENABLE_AUTO_MAINTAIN:-0}" == 1 ]]; then
    # 在父 shell 中加载有效目标，使定时配置也保存凭据文件提供的 Tailnet。
    load_policy_credentials 2>/dev/null || true
    if ! policy_target_is_configured; then
      echo "[错误] 未配置有效 TS_TAILNET，不能启用自动维护。请在部署配置或独立凭据文件中指定目标。" >&2
      return 1
    fi
  fi
  if [[ "${ENABLE_AUTO_MAINTAIN:-0}" == 1 && "$(policy_auth_state)" == write_ready ]]; then
    if ! install_cert_maintain_units; then
      write_maintenance_status unknown failed "未能安装维护任务" 1 "" "" failed || true
      echo "[警告] 未能安装维护 timer，未登记为就绪。" >&2
      return 1
    fi
    if ! activate_cert_maintain_timer; then
      write_maintenance_status unknown failed "未能启用维护 timer" 1 "" "" failed || true
      echo "[警告] 未能启用维护 timer，未登记为就绪。" >&2
      return 1
    fi
    write_maintenance_status ready recorded "已登记本节点自动换证" 0 "" enabled ready || return 1
  fi
}

finish_deploy_auto_maintain() {
  local rc=0
  apply_auto_maintain_policy || rc=$?
  print_auto_maintain_feedback "$(evaluate_auto_maintain_readiness)"
  [[ "$(maintenance_scheduler_state)" != failed ]] || rc=1
  return "$rc"
}

run_d_stage_command() {
  case "$SUBCOMMAND" in
    prepare) prepare_cert_rotation ;;
    apply) apply_cert_rotation ;;
    cancel) cancel_cert_rotation ;;
    maintain) run_cert_maintain ;;
    *) return 1 ;;
  esac
}


generate_selfsigned_cert() {
  echo "[步骤] 生成基于 IP 的自签临时证书（SAN=IP:${IP_ADDR}）…"
  mkdir -p "${INSTALL_DIR}"

  local certs_dir="${INSTALL_DIR}/certs"
  if [[ -L "$certs_dir" ]]; then
    echo "[错误] ${certs_dir} 是符号链接，拒绝继续（可能存在安全风险）。请删除后重试。" >&2
    return 1
  fi
  mkdir -p "$certs_dir"
  # 生成前先把证书目录收紧为 root 所有，杜绝服务账户在生成过程中插入符号链接
  harden_cert_dir || return 1

  local cert_file key_file
  cert_file=$(derper_manual_cert_file)
  key_file=$(derper_manual_key_file)
  refuse_symlink "$cert_file" || return 1
  refuse_symlink "$key_file" || return 1

  # 在证书目录内创建随机临时文件，成功后原子替换（mv 会替换符号链接本身，不会沿链接写入）
  # cnf_tmp 仅在降级分支赋值；初始化以确保 set -u 下各路径均可安全清理。
  local key_tmp="" cert_tmp="" cnf_tmp=""
  if ! key_tmp=$(mktemp "${certs_dir}/.derper-key.XXXXXX" 2>/dev/null); then
    echo "[错误] 无法在 ${certs_dir} 创建密钥临时文件。" >&2
    return 1
  fi
  if ! cert_tmp=$(mktemp "${certs_dir}/.derper-cert.XXXXXX" 2>/dev/null); then
    rm -f "$key_tmp"
    echo "[错误] 无法在 ${certs_dir} 创建证书临时文件。" >&2
    return 1
  fi

  local ok=0
  # 优先使用 -addext；若系统 openssl 太旧则降级到配置文件方式
  # 上游 derper manual 模式固定读取 <hostname>.crt / <hostname>.key
  if openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
      -keyout "${key_tmp}" \
      -out "${cert_tmp}" \
      -days "${CERT_DAYS}" \
      -subj "/CN=${IP_ADDR}" \
      -addext "subjectAltName = IP:${IP_ADDR}" >/dev/null 2>&1; then
    ok=1
  else
    rm -f "$key_tmp" "$cert_tmp"
    if ! key_tmp=$(mktemp "${certs_dir}/.derper-key.XXXXXX" 2>/dev/null) ||
       ! cert_tmp=$(mktemp "${certs_dir}/.derper-cert.XXXXXX" 2>/dev/null) ||
       ! cnf_tmp=$(mktemp "${certs_dir}/.derper-cnf.XXXXXX" 2>/dev/null); then
      rm -f "$key_tmp" "$cert_tmp" "$cnf_tmp" 2>/dev/null || true
      echo "[错误] 无法在 ${certs_dir} 创建临时文件。" >&2
      return 1
    fi
    cat >"${cnf_tmp}" <<CONF
[ req ]
default_bits       = 2048
distinguished_name = req_distinguished_name
req_extensions     = req_ext
x509_extensions    = v3_req
prompt             = no

[ req_distinguished_name ]
CN = ${IP_ADDR}

[ req_ext ]
subjectAltName = @alt_names

[ v3_req ]
subjectAltName = @alt_names

[ alt_names ]
IP.1 = ${IP_ADDR}
CONF
    if openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
      -keyout "${key_tmp}" \
      -out "${cert_tmp}" \
      -days "${CERT_DAYS}" \
      -config "${cnf_tmp}" >/dev/null 2>&1; then
      ok=1
    fi
  fi

  if [[ "$ok" -ne 1 ]]; then
    rm -f "$key_tmp" "$cert_tmp" "$cnf_tmp" 2>/dev/null || true
    echo "[错误] 自签证书生成失败，请检查 openssl 版本与磁盘状态。" >&2
    return 1
  fi

  if ! confirm_cert_rotation "$cert_tmp" || ! begin_cert_update; then
    rm -f "$key_tmp" "$cert_tmp" "$cnf_tmp"
    return 1
  fi

  # 原子替换到最终路径（mv 不沿符号链接写入，并替换残留符号链接本身）
  chmod 600 "$key_tmp" "$cert_tmp" 2>/dev/null || true
  if ! mv -f "$key_tmp" "$key_file" || ! mv -f "$cert_tmp" "$cert_file"; then
    rm -f "$key_tmp" "$cert_tmp" "$cnf_tmp" 2>/dev/null || true
    rollback_cert_update || true
    echo "[错误] 证书文件写入失败：${key_file} / ${cert_file}" >&2
    return 1
  fi
  rm -f "$cnf_tmp" 2>/dev/null || true

  if ! repair_cert_layout; then
    rollback_cert_update || true
    return 1
  fi

  echo "[信息] 证书文件生成于：${cert_file} / ${key_file}"
  echo "[信息] 兼容链接：${INSTALL_DIR}/certs/{fullchain.pem,privkey.pem,cert.pem,key.pem}"
  
  # 生成 derper 配置文件（新版 derper 要求必须指定 -c 参数）
  if ! generate_derper_config; then
    rollback_cert_update || true
    return 1
  fi
}

# 证书就绪：已兼容则跳过；仅命名过旧则迁移（保留指纹）；否则重签。
# --repair 与默认幂等路径共用，避免 repair 把可迁移证书直接重签导致 ACL 指纹变化。
ensure_compatible_certs() {
  CERTS_CHANGED=0
  if [[ "${CERT_CHECK_UNKNOWN:-0}" -eq 1 ]]; then
    echo "[错误] 无法读取证书或私钥，不能确认是否匹配，已阻止重启。" >&2
    return 1
  fi
  if [[ "${CERT_KEY_MATCH:-1}" -eq 0 ]]; then
    echo "[错误] 证书与私钥公钥不一致，已阻止重启。" >&2
    if [[ -d "${SERVICE_PATH}.certs-rollback" ]]; then
      if rollback_cert_update; then
        echo "[信息] 已恢复备份中的证书对；本次不会用错误私钥重启服务。" >&2
      else
        echo "[错误] 证书备份恢复失败，当前保护不完整。" >&2
      fi
    elif [[ "${ACCEPT_CERT_ROTATION:-0}" -eq 1 ]]; then
      generate_selfsigned_cert || return 1
      CERTS_CHANGED=1
      return 0
    else
      echo "[错误] 没有可恢复的证书备份。重签会改变指纹，确认窗口后使用 --accept-cert-rotation。" >&2
    fi
    return 1
  fi
  if [[ ${CERT_PRESENT:-0} -eq 1 && ${CERT_SAN_MATCH:-0} -eq 1 && ${CERT_EXPIRY_OK:-0} -eq 1 && ${CERT_NAMING_OK:-0} -eq 1 ]]; then
    repair_cert_layout || return 1
    return 0
  fi
  command -v openssl >/dev/null 2>&1 || install_deps
  if [[ ${CERT_NAMING_OK:-0} -ne 1 && ${CERT_PRESENT:-0} -eq 1 ]]; then
    echo "[信息] 检测到旧证书命名（非 <IP>.crt/.key），将迁移为上游 derper manual 模式兼容命名。"
  fi
  if [[ ${CERT_PRESENT:-0} -eq 1 && ${CERT_SAN_MATCH:-0} -eq 1 && ${CERT_EXPIRY_OK:-0} -eq 1 && ${CERT_NAMING_OK:-0} -ne 1 ]]; then
    local old_cert old_key new_cert new_key
    old_cert=$(resolve_disk_cert_pem || true)
    old_key=$(resolve_disk_key_pem || true)
    new_cert=$(derper_manual_cert_file)
    new_key=$(derper_manual_key_file)
    if [[ -n "$old_cert" && -n "$old_key" && -f "$old_cert" && -f "$old_key" ]]; then
      mkdir -p "${INSTALL_DIR}/certs"
      harden_cert_dir || { echo "[错误] 证书目录加固失败，迁移中止。" >&2; return 1; }
      refuse_symlink "$new_cert" || return 1
      refuse_symlink "$new_key" || return 1
      begin_cert_update || return 1
      local _mig_cert_tmp _mig_key_tmp
      _mig_cert_tmp=$(mktemp "${INSTALL_DIR}/certs/.derper-cert.XXXXXX") || return 1
      _mig_key_tmp=$(mktemp "${INSTALL_DIR}/certs/.derper-key.XXXXXX") || { rm -f "$_mig_cert_tmp"; return 1; }
      cat "$old_cert" > "$_mig_cert_tmp" && mv -f "$_mig_cert_tmp" "$new_cert" || { rm -f "$_mig_cert_tmp" "$_mig_key_tmp"; rollback_cert_update || true; echo "[错误] 证书迁移失败。" >&2; return 1; }
      cat "$old_key" > "$_mig_key_tmp" && mv -f "$_mig_key_tmp" "$new_key" || { rm -f "$_mig_cert_tmp" "$_mig_key_tmp"; rollback_cert_update || true; echo "[错误] 密钥迁移失败。" >&2; return 1; }
      if ! repair_cert_layout; then
        rollback_cert_update || true
        return 1
      fi
      echo "[信息] 已迁移证书到上游命名：${new_cert} / ${new_key}"
      CERT_NAMING_OK=1
      CERTS_CHANGED=1
      return 0
    fi
  fi
  if [[ "${CERT_PRESENT:-0}" == 1 ]]; then
    echo "[警告] 即将重签证书：CertName 指纹会变化，请同步更新 ACL。" >&2
  else
    echo "[信息] 首次签发证书：将生成本节点 CertName，部署后需合并到 Tailnet 策略。"
  fi
  generate_selfsigned_cert || return 1
  CERTS_CHANGED=1
  return 0
}

generate_derper_config() {
  echo "[步骤] 生成 derper 配置文件…"
  prepare_derper_config
  
  # 创建环境变量文件模板（用于敏感配置）
  local env_file="/etc/derper/derper.env"
  mkdir -p "$(dirname "$env_file")" 2>/dev/null || true
  
  if [[ ! -f "$env_file" ]]; then
    cat >"$env_file" <<'ENVFILE'
# DERP 环境变量配置文件
# 本文件用于存储敏感配置，权限设置为 600
#
# 使用说明：
# - 取消注释并填写需要的配置项
# - 修改后执行：systemctl restart derper

# Tailscale Auth Key（仅当容器内运行 tailscaled 时需要）
# TS_AUTHKEY=tskey-auth-xxxxxx

# Headscale 客户端验证 URL（使用 Headscale 时）
# DERP_VERIFY_CLIENT_URL=https://headscale.example.com/verify

# tailscaled 本地 API Socket 由部署脚本探测，并通过 derper 的 -socket 参数传入。

# 其他自定义环境变量
# ...
ENVFILE
    
    chmod 600 "$env_file"
    chown root:root "$env_file" 2>/dev/null || true
    echo "[信息] 环境变量模板已创建：$env_file"
    echo "       如需使用，请编辑该文件并重启服务"
  else
    echo "[信息] 环境变量文件已存在：$env_file"
  fi
}

prepare_derper_config() {
  mkdir -p "${INSTALL_DIR}" || return 1
  migrate_node_state || return 1
  local config_path
  config_path=$(derper_config_path)
  if [[ ! -f "$config_path" ]]; then
    echo "[信息] derper 将在首次启动时自动生成节点私钥配置：${config_path}"
  fi
}

# 计算证书 DER 原始字节的 SHA256，用于 ACL 的 CertName（sha256-raw:<hex>）
sha256_hex() {
  # 从标准输入读取，返回十六进制 sha256 值
  local out=""
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    out=$(shasum -a 256 | awk '{print $1}')
  else
    out=$(openssl dgst -sha256 | awk '{print $2}')
  fi
  # 空输入的 SHA256 是公开常量 e3b0c442…，不能当成证书指纹。
  if [[ -z "$out" || "$out" == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]]; then
    return 1
  fi
  printf '%s\n' "$out"
}

cert_file_sha256_raw() {
  # 计算本地证书（优先 derper 实际读取的 <hostname>.crt）的指纹
  if command -v openssl >/dev/null 2>&1; then
    local pem
    pem=$(resolve_disk_cert_pem 2>/dev/null || true)
    [[ -n "$pem" && -f "$pem" ]] || return 1
    openssl x509 -in "$pem" -outform DER 2>/dev/null | sha256_hex
  fi
}

# TLS 握手探测目标：优先本机回环，避免 NAT hairpin 导致误报；失败再回退公网 IP。
tls_probe_endpoints() {
  local endpoints=("127.0.0.1" "localhost")
  if [[ -n "${IP_ADDR:-}" ]]; then
    endpoints+=("${IP_ADDR}")
  fi
  printf '%s\n' "${endpoints[@]}"
}

live_cert_sha256_raw() {
  # 通过在线握手读取 derper 实际呈现的证书并计算指纹，最为权威
  # 依赖 openssl；添加超时避免卡住；优先连本机避免 hairpin 误报
  command -v openssl >/dev/null 2>&1 || return 1
  local host pem
  while IFS= read -r host; do
    [[ -n "$host" ]] || continue
    pem=$(_timeout_run 6 openssl s_client -connect "${host}:${DERP_PORT}" -servername "${IP_ADDR}" -showcerts </dev/null 2>/dev/null \
          | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p') || true
    if [[ -n "$pem" ]]; then
      printf "%s\n" "$pem" | openssl x509 -outform DER 2>/dev/null | sha256_hex
      return 0
    fi
  done < <(tls_probe_endpoints)
  return 1
}

journal_certname_raw() {
  # 从 systemd 日志中提取 derper 打印的 CertName（若可用）
  command -v journalctl >/dev/null 2>&1 || return 1
  local fp
  fp=$(journalctl -u derper -n 200 --no-pager 2>/dev/null \
       | grep -oE 'sha256-raw:[0-9a-f]+' 2>/dev/null | tail -n1 | sed 's/^sha256-raw://' || true)
  [[ -n "$fp" ]] && echo "$fp" || return 1
}

check_live_cert_status() {
  LIVE_CERT_CHECKED=1
  CERT_LIVE_MATCH=0
  local file_fp="" live_fp=""
  file_fp=$(cert_file_sha256_raw || true)
  live_fp=$(live_cert_sha256_raw || true)
  HEALTH_CERT_SHA256="$file_fp"
  HEALTH_LIVE_SHA256="$live_fp"
  if [[ -n "$file_fp" && -n "$live_fp" && "$file_fp" == "$live_fp" ]]; then
    CERT_LIVE_MATCH=1
  fi
}

# 返回本机应使用的 tailscaled 本地 API socket 路径。
# 与 write_systemd_service 内 chosen_socket 的探测口径保持一致：
# 优先标准路径，缺失时回退到默认 /run/tailscale/tailscaled.sock。
expected_tailscaled_socket() {
  if [[ -S /run/tailscale/tailscaled.sock ]]; then
    echo "/run/tailscale/tailscaled.sock"
  elif [[ -S /var/run/tailscale/tailscaled.sock ]]; then
    echo "/var/run/tailscale/tailscaled.sock"
  else
    echo "/run/tailscale/tailscaled.sock"
  fi
}

socket_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%OLp' "$1" 2>/dev/null
}

relax_socket_world_writable() {
  local sock="$1"
  [[ -S "$sock" ]] || return 1
  SOCKET_RELAXED_ORIG_MODE=$(socket_mode "$sock")
  [[ -n "$SOCKET_RELAXED_ORIG_MODE" ]] || return 1
  SOCKET_RELAXED_PATH="$sock"
  echo "[警告] 已启用 --relax-socket-perms，临时将 ${sock} 权限 ${SOCKET_RELAXED_ORIG_MODE} → 0666（脚本退出时恢复）。" >&2
  echo "  verify-clients 在恢复后可能失效；请改用 tailscaled.socket drop-in 或 ACL。" >&2
  chmod 666 "$sock"
}

restore_relaxed_socket_perms() {
  local sock="${SOCKET_RELAXED_PATH:-}"
  local mode="${SOCKET_RELAXED_ORIG_MODE:-}"
  SOCKET_RELAXED_PATH=""
  SOCKET_RELAXED_ORIG_MODE=""
  [[ -n "$sock" && -n "$mode" ]] || return 0
  [[ -S "$sock" ]] || return 0
  if chmod "$mode" "$sock" 2>/dev/null; then
    echo "[信息] 已将 ${sock} 权限恢复为 ${mode}。" >&2
  else
    echo "[警告] 无法将 ${sock} 恢复为 ${mode}，请手动检查。" >&2
    return 1
  fi
}

warn_world_writable_socket() {
  local sock="$1"
  [[ -n "$sock" && -S "$sock" ]] || return 0
  local perms
  perms=$(socket_mode "$sock")
  if [[ "$perms" == "666" ]]; then
    echo "[警告] tailscaled socket ${sock} 权限为 0666。支持 peer credentials 的平台会主动使用该权限，这本身不是应急状态，也不能证明管理权限已放开；LocalAPI 另行鉴权。" >&2
  fi
}

# 判断指定用户是否已能读写 socket（优先实际探测，避免仅因组名不同就侵入式改组/重启）。
user_can_access_socket() {
  local user="$1" sock="$2"
  [[ -n "$user" && -S "$sock" ]] || return 1

  # world 可读写时任何人都能访问
  local perms mode_oct=0 other
  perms=$(stat -c '%a' "$sock" 2>/dev/null || true)
  if [[ -n "$perms" ]]; then
    mode_oct=$((8#$perms))
    other=$(( mode_oct & 7 ))
    if (( (other & 6) == 6 )); then
      return 0
    fi
  fi

  # 属主匹配且属主位可读写
  local owner
  owner=$(stat -c '%U' "$sock" 2>/dev/null || true)
  local owner_bits=$(( (mode_oct >> 6) & 7 ))
  if [[ -n "$owner" && "$owner" == "$user" ]] && (( (owner_bits & 6) == 6 )); then
    return 0
  fi

  # 属组匹配且组可读写
  local group
  group=$(stat -c '%G' "$sock" 2>/dev/null || true)
  if [[ -n "$group" && "$group" != "root" ]]; then
    local group_bits=$(( (mode_oct >> 3) & 7 ))
    if (( (group_bits & 6) == 6 )) && id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$group"; then
      return 0
    fi
  fi

  # 实际探测：以目标用户执行 test -r/-w（最权威，能识别 ACL）
  if running_as_root && command -v runuser >/dev/null 2>&1; then
    runuser -u "$user" -- test -r "$sock" -a -w "$sock" 2>/dev/null && return 0
  elif command -v sudo >/dev/null 2>&1; then
    sudo -n -u "$user" test -r "$sock" -a -w "$sock" 2>/dev/null && return 0
  fi
  return 1
}

setup_service_user() {
  # 智能设置服务运行用户：创建新用户或使用现有用户
  
  # 检查是否为 root
  if [[ "$RUN_USER" == "root" ]]; then
    echo "[警告] 不推荐以 root 用户运行 derper 服务" >&2
    echo "  建议使用 --user 指定非 root 用户，或使用默认的 derper 用户" >&2
  fi
  
  # 检查用户是否已存在
  if id "$RUN_USER" >/dev/null 2>&1; then
    echo "[信息] 将使用现有用户运行 derper：$RUN_USER"
    
    layout_install_tree || return 1
    return 0
  fi
  
  # 用户不存在，尝试创建
  echo "[步骤] 创建系统用户：$RUN_USER …"
  
  # 动态发现 nologin 路径（兼容多种发行版）
  local nologin_path
  if command -v nologin >/dev/null 2>&1; then
    nologin_path=$(command -v nologin)
  elif [[ -x /sbin/nologin ]]; then
    nologin_path="/sbin/nologin"
  elif [[ -x /usr/sbin/nologin ]]; then
    nologin_path="/usr/sbin/nologin"
  else
    nologin_path="/bin/false"
  fi
  
  # 确保用户组存在（某些系统不会自动创建同名组）
  if ! getent group "$RUN_USER" >/dev/null 2>&1; then
    groupadd -r "$RUN_USER" 2>/dev/null || true
  fi
  
  # 创建系统用户（-r 系统用户，-M 不创建家目录，-g 指定组，-s 指定 shell）
  if useradd -r -M -g "$RUN_USER" -s "$nologin_path" "$RUN_USER" 2>/dev/null; then
    echo "[信息] 用户 $RUN_USER 创建成功（shell: ${nologin_path}）"
  else
    # 回退：尝试不指定组（让系统自动处理）
    if useradd --system --no-create-home --shell "$nologin_path" "$RUN_USER" 2>/dev/null; then
      echo "[信息] 用户 $RUN_USER 创建成功（回退方案）"
    else
      echo "[错误] 无法创建系统用户：$RUN_USER" >&2
      echo "  请手动创建后重试，或使用现有用户（--user <existing-user>）。" >&2
      echo "  手动创建命令示例：" >&2
      echo "    groupadd -r $RUN_USER" >&2
      echo "    useradd -r -M -g $RUN_USER -s $nologin_path $RUN_USER" >&2
      exit 1
    fi
  fi
  
  # 强校验：确认用户已成功创建
  if ! id "$RUN_USER" >/dev/null 2>&1; then
    echo "[错误] 用户 $RUN_USER 创建失败（校验未通过）" >&2
    exit 1
  fi
  
  echo "[步骤] 设置安装树与节点状态权限：${INSTALL_DIR}"
  layout_install_tree || exit 1
}

# 启动后强制健康验证：active 状态、TLS/STUN 端口监听、TLS 握手、进程存活。
# systemctl start/restart 即时返回成功并不代表服务真正可用（可能启动后立即崩溃）。
# ss/netstat/openssl 缺失时跳过对应核验并警告，避免把“缺诊断工具”误判成启动失败而回滚。
service_verified_running() {
  command -v systemctl >/dev/null 2>&1 || return 1
  local tries=0
  while (( tries < 15 )); do
    if systemctl is-active --quiet derper 2>/dev/null; then
      break
    fi
    sleep 1
    tries=$((tries + 1))
  done
  systemctl is-active --quiet derper 2>/dev/null || return 1
  # 防止启动后立即崩溃：短暂等待后复核 active 状态
  sleep 2
  systemctl is-active --quiet derper 2>/dev/null || return 1

  if command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1; then
    check_ports_status
    [[ "${PORT_TLS_OK:-0}" -eq 1 && "${PORT_STUN_OK:-0}" -eq 1 ]] || return 1
  else
    echo "[警告] 未找到 ss/netstat，跳过端口监听核验（服务已 active）。" >&2
  fi

  if command -v openssl >/dev/null 2>&1; then
    local host pem tls_ok=0
    while IFS= read -r host; do
      [[ -n "$host" ]] || continue
      pem=$(_timeout_run 6 openssl s_client -connect "${host}:${DERP_PORT}" -servername "${IP_ADDR}" -showcerts </dev/null 2>/dev/null \
            | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p') || true
      if [[ -n "$pem" ]]; then
        tls_ok=1
        break
      fi
    done < <(tls_probe_endpoints)
    [[ "$tls_ok" -eq 1 ]] || return 1
  else
    echo "[警告] 未找到 openssl，跳过 TLS 握手核验（服务已 active）。" >&2
  fi

  # derper 主进程仍在运行（未崩溃退出）
  local main_pid
  main_pid=$(systemctl show -p MainPID --value derper 2>/dev/null || echo "0")
  [[ -n "$main_pid" && "$main_pid" != "0" ]] || return 1
  kill -0 "$main_pid" 2>/dev/null || return 1
  return 0
}

# 失败回滚：恢复备份的旧 unit，并尝试重新启动旧服务（若此前在运行）后验证。
# 返回 0 表示回滚已经做完（全新安装已停止，或旧单元已写回且原服务本来就停着）。
# 返回 1 只表示原先在运行的服务没能恢复，调用方这时才应提示保留恢复材料。
rollback_previous_unit() {
  local backup="$1" was_running="${2:-0}"
  if [[ -z "$backup" || ! -f "$backup" ]]; then
    if [[ "$was_running" -ne 1 ]]; then
      # 全新安装失败且无备份：停止残留的半启动状态。回滚到此结束。
      ensure_derper_stopped || return 1
      echo "[信息] 新安装启动失败，服务已停止；请排查后重新运行本脚本。" >&2
      return 0
    fi
    echo "[警告] 无可用备份单元，旧服务可能已停止；请立即检查 systemctl status derper。" >&2
    return 1
  fi
  echo "[步骤] 正在恢复备份的 systemd 单元：${backup}" >&2
  if ! atomic_copy_file "$backup" "${SERVICE_PATH}"; then
    echo "[错误] 恢复备份单元失败，旧服务可能处于停止状态。" >&2
    return 1
  fi
  systemctl daemon-reload 2>/dev/null || true
  if [[ "$was_running" -eq 1 ]]; then
    echo "[步骤] 原服务此前在运行，尝试按旧配置重新启动并验证…" >&2
    if systemctl restart derper 2>/dev/null || systemctl start derper 2>/dev/null; then
      if verify_restored_service; then
        echo "[信息] 已恢复旧服务并通过健康验证。" >&2
        return 0
      fi
    fi
    echo "[错误] 旧配置未能重新启动并通过验证；服务当前可能处于停止状态。" >&2
    echo "  请立即执行 systemctl status derper 与 journalctl -u derper -n 100 排查。" >&2
    return 1
  fi
  ensure_derper_stopped || return 1
  echo "[信息] 已恢复旧单元；新配置启动失败，服务保持停止状态。" >&2
  return 0
}

intercept_non_systemd_environment() {
  local socket_path="$1"
  local stun_args=()
  if derper_supports_stun_port; then
    stun_args=("-stun" "-stun-port" "${STUN_PORT}")
  else
    stun_args=("-stun")
  fi

  local listen_args=()
  if derper_supports_listen_a; then
    listen_args=("-a" ":${DERP_PORT}")
  elif derper_supports_https_port; then
    listen_args=("-https-port" "${DERP_PORT}")
  else
    listen_args=("-a" ":${DERP_PORT}")
  fi

  local verify_flag=""
  case "${VERIFY_CLIENTS_MODE}" in
    on) verify_flag="-verify-clients" ;;
    off) verify_flag="" ;;
  esac

  local manual_cmd="${BIN_PATH} -c $(derper_config_path)"
  manual_cmd+=" -hostname ${IP_ADDR} -certmode manual -certdir ${INSTALL_DIR}/certs -http-port -1"
  manual_cmd+=" ${listen_args[*]} ${stun_args[*]}"
  [[ -n "${verify_flag}" ]] && manual_cmd+=" ${verify_flag}"
  if [[ -n "${verify_flag}" ]] && derper_supports_socket_flag; then
    manual_cmd+=" -socket ${socket_path:-/run/tailscale/tailscaled.sock}"
  fi
  cat >&2 <<EOT
[阻断] 未检测到 systemd，无法写入服务单元：${SERVICE_PATH}

你可以手动前台运行 derper（示例）：
  ${manual_cmd}

说明：若 derper 旧版本不支持 "-a" 或 "-stun-port"，请改用 "-https-port ${DERP_PORT}"，并去掉 "-stun-port"。
EOT
}

configure_service_user_and_socket() {
  setup_service_user

  local tailscale_socket_group=""
  local socket_needs_permission_fix=0
  local tailscaled_socket_unit_has_override=0
  local tailscaled_socket_override_group=""
  local need_add_user_to_tailscale_group=0
  local socket_path=""

  if [[ "${VERIFY_CLIENTS_MODE}" == "on" ]]; then
    if [[ -S /run/tailscale/tailscaled.sock ]]; then
      socket_path="/run/tailscale/tailscaled.sock"
    elif [[ -S /var/run/tailscale/tailscaled.sock ]]; then
      socket_path="/var/run/tailscale/tailscaled.sock"
    fi

    if [[ -n "$socket_path" ]]; then
      tailscale_socket_group=$(stat -c '%G' "$socket_path" 2>/dev/null || true)
      local socket_perms
      socket_perms=$(stat -c '%a' "$socket_path" 2>/dev/null || true)

      if user_can_access_socket "$RUN_USER" "$socket_path"; then
        echo "[信息] ${RUN_USER} 已可访问 tailscaled socket（${socket_path}，组=${tailscale_socket_group:-?}，权限=${socket_perms:-?}），跳过权限修复。"
      else
        socket_needs_permission_fix=1
        echo "[步骤] 配置 tailscaled socket 访问权限（当前组：${tailscale_socket_group}，权限：${socket_perms}）"

        if [[ "$socket_needs_permission_fix" -eq 1 ]]; then
          if getent group tailscale >/dev/null 2>&1; then
            need_add_user_to_tailscale_group=1
            usermod -a -G tailscale "$RUN_USER" 2>/dev/null || true
          fi
          if command -v systemctl >/dev/null 2>&1 && systemctl cat tailscaled.socket >/dev/null 2>&1; then
            if getent group tailscale >/dev/null 2>&1; then
              tailscaled_socket_override_group="tailscale"
            else
              tailscaled_socket_override_group="${RUN_USER}"
            fi
            local dropin_dir="/etc/systemd/system/tailscaled.socket.d"
            local dropin_file="${dropin_dir}/10-derper-localapi.conf"
            mkdir -p "$dropin_dir" 2>/dev/null || true
            cat >"$dropin_file" <<EOF
[Socket]
SocketGroup=${tailscaled_socket_override_group}
SocketMode=0660
EOF
            if restart_tailscaled_socket_unit; then
              tailscaled_socket_unit_has_override=1
              echo "[信息] 已为 tailscaled.socket 应用覆盖：SocketGroup=${tailscaled_socket_override_group} SocketMode=0660"
              if [[ "$tailscaled_socket_override_group" == "tailscale" ]]; then
                usermod -a -G tailscale "$RUN_USER" 2>/dev/null || true
              fi
            else
              echo "[警告] tailscaled.socket 覆盖未能立即生效（重启被跳过或失败），将回退到临时权限调整或 ACL。" >&2
            fi
          fi

          if [[ "$tailscaled_socket_unit_has_override" -ne 1 ]]; then
            local acl_success=0
            if command -v setfacl >/dev/null 2>&1; then
              echo "[步骤] 使用 ACL 赋权 $RUN_USER 访问 tailscaled.sock"
              if setfacl -m "u:${RUN_USER}:rw" "$socket_path" 2>/dev/null; then
                acl_success=1
                echo "[信息] ACL 权限设置成功（注意：重启 tailscaled 后需重新设置）"
              else
                echo "[警告] ACL 设置失败" >&2
              fi
            fi

            if [[ "$acl_success" -ne 1 ]]; then
              if ! user_can_access_socket "$RUN_USER" "$socket_path"; then
                if [[ "$RELAX_SOCKET_PERMS" -eq 1 ]]; then
                  relax_socket_world_writable "$socket_path" || return 1
                else
                  cat >&2 <<EOT

╔══════════════════════════════════════════════════════════════════════════════╗
║                    ⚠️  tailscaled socket 权限不足                              ║
╚══════════════════════════════════════════════════════════════════════════════╝

[错误] derper 用户 ($RUN_USER) 无法访问 tailscaled 本地 API socket

当前状态：
  Socket 路径：$socket_path
  所属组：$tailscale_socket_group
  权限：$socket_perms
  运行用户：$RUN_USER

推荐解决方案（按优先级排序）：

方案 1：使用 systemd socket 覆盖（最安全，持久化） ✅
  已尝试自动配置但未生效，请手动执行：
    mkdir -p /etc/systemd/system/tailscaled.socket.d
    cat > /etc/systemd/system/tailscaled.socket.d/10-derper-localapi.conf <<'EOF'
[Socket]
SocketGroup=tailscale
SocketMode=0660
EOF
    systemctl daemon-reload
    systemctl restart tailscaled.socket
    # 确保 $RUN_USER 在 tailscale 组中
    usermod -a -G tailscale $RUN_USER

方案 2：使用 ACL（灵活，需 acl 包）
  已尝试但失败，可能需要安装 acl 包：
    # Debian/Ubuntu
    apt-get install acl
    # RHEL/CentOS
    yum install acl
    
  然后重新运行本脚本

方案 3：使用当前用户运行 derper（简单，适合个人环境）
  重新执行脚本并使用当前用户：
    bash \$0 --use-current-user [其他参数]

方案 4：临时放宽权限（不推荐，仅紧急情况）
  如果你了解风险，可添加 --relax-socket-perms 参数：
    bash \$0 --relax-socket-perms [其他参数]
  注意：该方案在 tailscaled 重启后失效，且存在安全风险

EOT
                  exit 1
                fi
              fi
            fi
          fi
        fi
      fi
      if ! user_can_access_socket "$RUN_USER" "$socket_path"; then
        echo "[错误] socket 权限修复后运行用户仍不可访问，停止部署。" >&2
        return 1
      fi
    else
      echo "[警告] 未检测到 tailscaled socket，-verify-clients 可能无法正常工作" >&2
    fi
  fi

  if [[ "$need_add_user_to_tailscale_group" -eq 1 ]] && getent group tailscale >/dev/null 2>&1; then
    usermod -a -G tailscale "$RUN_USER" 2>/dev/null || true
  fi

  local run_group
  run_group=$(id -g -n "$RUN_USER" 2>/dev/null || echo "$RUN_USER")

  local supplementary_groups_line=""
  local target_group_for_access=""
  if [[ -n "$tailscaled_socket_override_group" ]]; then
    target_group_for_access="$tailscaled_socket_override_group"
  else
    target_group_for_access="$tailscale_socket_group"
  fi
  if [[ -n "$target_group_for_access" && "$target_group_for_access" != "$RUN_USER" && "$target_group_for_access" != "root" ]]; then
    supplementary_groups_line="SupplementaryGroups=${target_group_for_access}"
  fi

  SERVICE_RUN_GROUP="$run_group"
  if [[ -n "${supplementary_groups_line}" ]]; then
    SERVICE_SUPPLEMENTARY_GROUPS_SECTION="
${supplementary_groups_line}"
  else
    SERVICE_SUPPLEMENTARY_GROUPS_SECTION=""
  fi
  DETECTED_SOCKET_PATH="$socket_path"
}

prepare_derper_exec_start_line() {
  local socket_path="$1"
  local stun_args=()
  if derper_supports_stun_port; then
    stun_args=("-stun" "-stun-port" "${STUN_PORT}")
  else
    stun_args=("-stun")
    if [[ "${STUN_PORT}" != "3478" ]]; then
      echo "[错误] 当前 derper 不支持 -stun-port，无法使用自定义 STUN 端口 ${STUN_PORT}。" >&2
      echo "  请改用 --stun-port 3478，或升级 derper 后重试。" >&2
      return 1
    fi
  fi

  local listen_args=()
  if derper_supports_listen_a; then
    listen_args=("-a" ":${DERP_PORT}")
  elif derper_supports_https_port; then
    listen_args=("-https-port" "${DERP_PORT}")
  else
    listen_args=("-a" ":${DERP_PORT}")
  fi

  local verify_flag=""
  case "${VERIFY_CLIENTS_MODE}" in
    on) verify_flag="-verify-clients" ;;
    off) verify_flag="" ;;
  esac

  local exec_args=("${BIN_PATH}" "-c" "$(derper_config_path)")
  exec_args+=("-hostname" "${IP_ADDR}")
  exec_args+=("-certmode" "manual")
  exec_args+=("-certdir" "${INSTALL_DIR}/certs")
  exec_args+=("-http-port" "-1")
  exec_args+=("${listen_args[@]}")
  exec_args+=("${stun_args[@]}")
  [[ -n "${verify_flag}" ]] && exec_args+=("${verify_flag}")

  if [[ "${VERIFY_CLIENTS_MODE}" == "on" ]]; then
    local chosen_socket=""
    if [[ -S /run/tailscale/tailscaled.sock ]]; then
      chosen_socket="/run/tailscale/tailscaled.sock"
    elif [[ -S /var/run/tailscale/tailscaled.sock ]]; then
      chosen_socket="/var/run/tailscale/tailscaled.sock"
    elif [[ -n "$socket_path" ]]; then
      chosen_socket="$socket_path"
    fi
    [[ -z "$chosen_socket" ]] && chosen_socket="/run/tailscale/tailscaled.sock"
    if derper_supports_socket_flag; then
      exec_args+=("-socket" "${chosen_socket}")
    elif [[ "$chosen_socket" != "/run/tailscale/tailscaled.sock" ]]; then
      echo "[错误] 当前 derper 不支持 -socket，无法使用非默认 tailscaled socket：${chosen_socket}" >&2
      return 1
    fi
  fi

  DERPER_EXEC_START_LINE="${exec_args[*]}"
}

get_security_hardening_options() {
  local hardening_basic="NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true"

  local hardening_standard="NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
RestrictSUIDSGID=true
ProtectClock=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true"

  local hardening_paranoid="NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
RestrictSUIDSGID=true
ProtectClock=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectProc=invisible
LockPersonality=true
RestrictRealtime=true
RestrictNamespaces=true
RemoveIPC=true
MemoryDenyWriteExecute=true"

  case "${SECURITY_LEVEL}" in
    basic)
      echo "[信息] 使用 basic 安全级别（最大兼容性）" >&2
      printf '%s' "$hardening_basic"
      ;;
    standard)
      echo "[信息] 使用 standard 安全级别（推荐）" >&2
      printf '%s' "$hardening_standard"
      ;;
    paranoid)
      echo "[信息] 使用 paranoid 安全级别（最严格加固）" >&2
      printf '%s' "$hardening_paranoid"
      ;;
    *)
      echo "[错误] 无效的安全级别：${SECURITY_LEVEL}" >&2
      echo "  可选值：basic | standard | paranoid" >&2
      exit 1
      ;;
  esac
}

render_derper_service_unit() {
  local exec_cmd="$1" run_user="$2" run_group="$3" supplementary_section="$4" hardening_opts="$5" state_dir="$6"
  local state_access="ReadWritePaths=${state_dir}"
  if [[ "$state_dir" == "/var/lib/derper" ]]; then
    state_access="StateDirectory=derper
StateDirectoryMode=0700
ReadWritePaths=/var/lib/derper"
  fi
  cat <<SERVICE
[Unit]
Description=Tailscale DERP (derper) with self-signed IP cert
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service
StartLimitBurst=5
StartLimitIntervalSec=60

[Service]
Type=simple
User=${run_user}
Group=${run_group}${supplementary_section}

# 环境变量（支持敏感配置）
EnvironmentFile=-/etc/derper/derper.env

ExecStart=${exec_cmd}
Restart=on-failure
RestartSec=2
LimitNOFILE=65535

# 能力边界
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# 安全加固（级别：${SECURITY_LEVEL}）
${hardening_opts}

# 只放行节点状态目录。证书和安装树保持 root 管理。
${state_access}

[Install]
WantedBy=multi-user.target
SERVICE
}

rollback_failed_release() {
  local backup="$1" was_running="$2" marker phase
  rollback_cert_update || return 1
  marker="$(deploy_state_root)/incomplete"
  if [[ -e "$marker" || -L "$marker" ]]; then
    phase=$(read_kv_value "$marker" phase) || return 1
    if [[ "$phase" == first-install && -n "$backup" && -f "$backup" ]]; then
      # 首装没有旧二进制可重启。先停服并放回已有unit，再清理候选与标记。
      ensure_derper_stopped || return 1
      atomic_copy_file "$backup" "$SERVICE_PATH" || return 1
      systemctl daemon-reload || return 1
    fi
    if ! rollback_deploy_change; then
      echo '[错误] 发布回退未完成，恢复集与标记已保留。' >&2
      return 1
    fi
    # A/B回退已经恢复并复验进程，不能再执行旧unit分支重复重启。
    return 0
  fi
  rollback_previous_unit "$backup" "$was_running"
}

deploy_and_verify_derper_service() {
  local svc_path="$1" unit_content="$2"
  local unit_backup=""
  refuse_symlink "${svc_path}" || return 1
  if [[ -f "${svc_path}" ]]; then
    unit_backup="${svc_path}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${svc_path}" "$unit_backup" 2>/dev/null || unit_backup=""
    if [[ -n "$unit_backup" ]]; then
      echo "[信息] 已备份旧 systemd 单元：$unit_backup"
    fi
  fi

  atomic_install_file "${svc_path}" <<<"$unit_content"

  systemctl daemon-reload

  systemctl enable derper >/dev/null 2>&1 || true
  local was_running=0
  if systemctl is-active --quiet derper 2>/dev/null; then
    was_running=1
  fi
  local service_started=0
  if [[ "$was_running" -eq 1 ]]; then
    if systemctl restart derper 2>/dev/null; then
      service_started=1
    fi
  elif systemctl start derper 2>/dev/null; then
    service_started=1
  fi

  if [[ "${service_started}" -eq 1 ]]; then
    if ! service_verified_running || ! publish_verification_gate; then
      echo "[警告] 服务启动命令成功，但未通过健康验证（active/端口/TLS/进程）。" >&2
      service_started=0
    fi
  fi

  if [[ "${service_started}" -ne 1 ]]; then
    echo "[警告] 服务启动失败或健康验证未通过（active/端口/TLS/进程）。" >&2

    if [[ "${SECURITY_LEVEL}" == "paranoid" ]]; then
      echo "[信息] paranoid 加固可能与当前系统不兼容，尝试禁用 MemoryDenyWriteExecute 后重试。" >&2
      sed -i.bak \
        -e '/^MemoryDenyWriteExecute=/d' \
        -e 's/# 安全加固（级别：paranoid）/# 安全加固（级别：paranoid；已禁用 MemoryDenyWriteExecute）/' \
        "${svc_path}" && rm -f "${svc_path}.bak"
      systemctl daemon-reload

      systemctl enable derper >/dev/null 2>&1 || true
      local degraded_ok=0
      if systemctl restart derper 2>/dev/null || systemctl start derper 2>/dev/null; then
        if service_verified_running && publish_verification_gate; then
          degraded_ok=1
          echo "[信息] 服务已成功启动（已禁用 MemoryDenyWriteExecute；unit 已标记为 paranoid 降级）"
        fi
      fi
      if [[ "$degraded_ok" -ne 1 ]]; then
        echo "[警告] 降级后服务仍未通过健康验证，开始回滚。" >&2
        rollback_failed_release "$unit_backup" "$was_running" || echo '[错误] 回退未完成，请保留恢复材料并检查日志。' >&2
        cat >&2 <<'EOT'

[错误] 服务仍然无法启动

可能原因：
  1. paranoid 级别的加固选项在您的系统上不兼容
     - ProtectProc=invisible 需要 Linux 5.8+ 和 systemd 247+
     - RestrictNamespaces 需要较新的内核和 systemd
  
解决方案：
  1) 降级到 standard 安全级别（推荐）：
     sudo bash $0 --security-level standard --repair
  
  2) 降级到 basic 安全级别（最大兼容）：
     sudo bash $0 --security-level basic --repair
  
  3) 查看详细错误日志：
     journalctl -u derper -n 50 --no-pager

EOT
        exit 1
      fi
    else
      echo "[步骤] 启动失败，正在回滚到备份的旧服务配置。" >&2
      rollback_failed_release "$unit_backup" "$was_running" || echo '[错误] 回退未完成，请保留恢复材料并检查日志。' >&2
      cat >&2 <<'EOT'

[错误] 服务启动失败

解决方案：
  1) 如果是 standard 级别，尝试降级到 basic：
     sudo bash $0 --security-level basic --repair
  
  2) 查看详细错误日志：
     journalctl -u derper -n 50 --no-pager
  
  3) 手动排查 systemd 服务配置：
     systemctl status derper

EOT
      exit 1
    fi
  fi

  commit_deploy_change
  systemctl status derper --no-pager -l || true

  if command -v systemd-analyze >/dev/null 2>&1; then
    echo ""
    echo "[信息] systemd 安全评分摘要（详细项：systemd-analyze security derper.service）："
    systemd-analyze security derper.service 2>/dev/null | tail -1 || true
  fi
}

write_systemd_service() {
  echo "[步骤] 写入 systemd 服务单元：${SERVICE_PATH}…"
  prepare_derper_config

  local DETECTED_SOCKET_PATH="" SERVICE_RUN_GROUP="" SERVICE_SUPPLEMENTARY_GROUPS_SECTION=""
  configure_service_user_and_socket || return 1

  # 非 systemd 环境前置拦截并给出手动运行示例
  if ! command -v systemctl >/dev/null 2>&1; then
    intercept_non_systemd_environment "$DETECTED_SOCKET_PATH"
    exit 1
  fi

  local DERPER_EXEC_START_LINE=""
  prepare_derper_exec_start_line "$DETECTED_SOCKET_PATH" || return 1

  local hardening_options
  hardening_options=$(get_security_hardening_options)

  local unit_content
  unit_content=$(render_derper_service_unit "$DERPER_EXEC_START_LINE" "$RUN_USER" "$SERVICE_RUN_GROUP" "$SERVICE_SUPPLEMENTARY_GROUPS_SECTION" "$hardening_options" "$(derper_node_state_dir)")

  deploy_and_verify_derper_service "${SERVICE_PATH}" "$unit_content"
}

iptables_append_connlimit() {
  local chain="$1"
  iptables -A "$chain" -p tcp --dport "${DERP_PORT}" \
    -m connlimit --connlimit-above "${TLS_CONNLIMIT}" --connlimit-mask 32 \
    -j REJECT --reject-with tcp-reset
}

discard_iptables_connlimit_staging() {
  local staging="$1"
  iptables -F "$staging" 2>/dev/null || true
  iptables -X "$staging" 2>/dev/null || true
}

# 回放 iptables -S 保存的规则。调用方处于条件表达式中，必须显式检查返回值。
restore_iptables_connlimit_snapshot() {
  local chain="$1" snapshot="$2" chain_existed="$3"
  if [[ "$chain_existed" -eq 0 ]]; then
    iptables -F "$chain" 2>/dev/null || true
    iptables -X "$chain" 2>/dev/null || return 1
    return 0
  fi
  iptables -F "$chain" || return 1
  local line rc=0
  while IFS= read -r line; do
    [[ "$line" == "-A ${chain} "* || "$line" == "-A ${chain}" ]] || continue
    set -f
    # shellcheck disable=SC2086
    iptables $line
    rc=$?
    set +f
    [[ "$rc" -eq 0 ]] || return 1
  done <<<"$snapshot"
  return 0
}

apply_tls_connlimit_nft() {
  local table="${NFT_CONNLIMIT_TABLE}"
  local rule batch
  rule="add rule inet ${table} input tcp dport ${DERP_PORT} ct state new meter derper_tls { ip saddr ct count over ${TLS_CONNLIMIT} } counter drop comment \"derper-tls-connlimit\""
  if ! nft list table inet "${table}" >/dev/null 2>&1; then
    batch=$(cat <<EOF
add table inet ${table}
add chain inet ${table} input { type filter hook input priority 0; policy accept; }
${rule}
EOF
)
  elif ! nft list chain inet "${table}" input >/dev/null 2>&1; then
    batch=$(cat <<EOF
add chain inet ${table} input { type filter hook input priority 0; policy accept; }
${rule}
EOF
)
  else
    # flush 与 add rule 放进同一次 nft -f，提交失败时内核回滚，旧规则保持原样。
    batch=$(cat <<EOF
flush chain inet ${table} input
${rule}
EOF
)
  fi
  if ! nft -f - <<<"$batch"; then
    echo "[错误] nft 限流规则提交失败，已有规则保持原样。" >&2
    return 1
  fi
  remove_legacy_nft_derper_connlimit_rules || true
  return 0
}

# 旧版误用 inet derper 表：只按 comment 删除本脚本规则，绝不 flush/删除该表。
remove_legacy_nft_derper_connlimit_rules() {
  local handle
  while read -r handle; do
    [[ -n "$handle" ]] || continue
    nft delete rule inet derper input handle "$handle" 2>/dev/null || true
  done < <(nft -a list chain inet derper input 2>/dev/null \
    | awk '/derper-tls-connlimit/ { for (i=1;i<=NF;i++) if ($i=="handle") { print $(i+1); break } }' || true)
}

apply_tls_connlimit_iptables() {
  local chain="DERPER-CONNLIMIT"
  local staging="${chain}-NEW"
  local snapshot="" chain_existed=0 jump_existed=0
  if iptables -S "$chain" >/dev/null 2>&1; then
    chain_existed=1
    if ! snapshot=$(iptables -S "$chain" 2>/dev/null); then
      discard_iptables_connlimit_staging "$staging"
      echo "[错误] 无法读取既有 iptables 限流规则快照，已有规则保持原样。" >&2
      return 1
    fi
  fi
  if iptables -C INPUT -j "$chain" >/dev/null 2>&1; then
    jump_existed=1
  fi

  discard_iptables_connlimit_staging "$staging"
  if ! iptables -N "$staging"; then
    echo "[错误] 无法准备 iptables 限流临时链，已有规则保持原样。" >&2
    return 1
  fi
  if ! iptables_append_connlimit "$staging"; then
    discard_iptables_connlimit_staging "$staging"
    echo "[错误] iptables 限流规则未能装入临时链，已有规则保持原样。" >&2
    return 1
  fi

  if [[ "$chain_existed" -eq 0 ]]; then
    if ! iptables -N "$chain"; then
      discard_iptables_connlimit_staging "$staging"
      echo "[错误] 无法创建 iptables 限流链，已有规则保持原样。" >&2
      return 1
    fi
  elif ! iptables -F "$chain"; then
    discard_iptables_connlimit_staging "$staging"
    echo "[错误] 无法更新 iptables 限流链，已有规则保持原样。" >&2
    return 1
  fi

  if ! iptables_append_connlimit "$chain"; then
    if ! restore_iptables_connlimit_snapshot "$chain" "$snapshot" "$chain_existed"; then
      discard_iptables_connlimit_staging "$staging"
      echo "[错误] iptables 限流规则安装失败，且旧规则恢复失败，当前保护不完整。" >&2
      return 1
    fi
    discard_iptables_connlimit_staging "$staging"
    echo "[错误] iptables 限流规则安装失败，已恢复旧规则。" >&2
    return 1
  fi

  if [[ "$jump_existed" -eq 0 ]]; then
    if ! iptables -C INPUT -j "$chain" >/dev/null 2>&1; then
      if ! iptables -I INPUT -j "$chain"; then
        if ! restore_iptables_connlimit_snapshot "$chain" "$snapshot" "$chain_existed"; then
          discard_iptables_connlimit_staging "$staging"
          echo "[错误] iptables 限流跳转安装失败，且旧规则恢复失败，当前保护不完整。" >&2
          return 1
        fi
        discard_iptables_connlimit_staging "$staging"
        echo "[错误] iptables 限流跳转安装失败，已恢复旧规则。" >&2
        return 1
      fi
    fi
  fi

  discard_iptables_connlimit_staging "$staging"
  return 0
}

apply_tls_connlimit() {
  decimal_in_closed_range "${TLS_CONNLIMIT:-0}" 0 "${TLS_CONNLIMIT_MAX}" || return 1
  if _decimal_ge "${TLS_CONNLIMIT:-0}" 1; then
    echo "[步骤] 安装单 IP TLS 连接上限：${TLS_CONNLIMIT}"
    if command -v nft >/dev/null 2>&1; then
      apply_tls_connlimit_nft || return 1
    elif command -v iptables >/dev/null 2>&1; then
      apply_tls_connlimit_iptables || return 1
    else
      echo "[错误] --tls-connlimit 需要 nft 或 iptables。" >&2
      return 1
    fi
    return 0
  fi
  if [[ "${TLS_CONNLIMIT_EXPLICIT:-0}" -eq 1 ]]; then
    echo "[步骤] --tls-connlimit 0：移除已安装的 TLS 连接上限规则"
    remove_tls_connlimit || return 1
    return 0
  fi
}

remove_tls_connlimit() {
  local attempted=0 failed=0 err_file rc=0
  err_file=$(mktemp 2>/dev/null || true)
  if command -v nft >/dev/null 2>&1; then
    attempted=$((attempted + 1))
    rc=0
    if [[ -n "$err_file" ]]; then
      nft delete table inet "${NFT_CONNLIMIT_TABLE}" >/dev/null 2>"$err_file" || rc=$?
    else
      nft delete table inet "${NFT_CONNLIMIT_TABLE}" >/dev/null 2>&1 || rc=$?
    fi
    if [[ "$rc" -ne 0 ]]; then
      local err=""
      [[ -n "$err_file" && -f "$err_file" ]] && err=$(cat "$err_file")
      if [[ "$err" != *"No such file or directory"* && "$err" != *"no such table"* ]]; then
        failed=$((failed + 1))
      fi
    fi
    remove_legacy_nft_derper_connlimit_rules || true
  fi
  if command -v iptables >/dev/null 2>&1; then
    attempted=$((attempted + 1))
    local ipt_fail=0
    rc=0
    if [[ -n "$err_file" ]]; then
      iptables -D INPUT -j DERPER-CONNLIMIT >/dev/null 2>"$err_file" || rc=$?
    else
      iptables -D INPUT -j DERPER-CONNLIMIT >/dev/null 2>&1 || rc=$?
    fi
    if [[ "$rc" -ne 0 ]]; then
      local err=""
      [[ -n "$err_file" && -f "$err_file" ]] && err=$(cat "$err_file")
      if [[ "$err" != *"Bad rule"* && "$err" != *"No chain"* ]]; then
        ipt_fail=$((ipt_fail + 1))
      fi
    fi

    rc=0
    if [[ -n "$err_file" ]]; then
      iptables -F DERPER-CONNLIMIT >/dev/null 2>"$err_file" || rc=$?
    else
      iptables -F DERPER-CONNLIMIT >/dev/null 2>&1 || rc=$?
    fi
    if [[ "$rc" -ne 0 ]]; then
      local err=""
      [[ -n "$err_file" && -f "$err_file" ]] && err=$(cat "$err_file")
      if [[ "$err" != *"No chain"* ]]; then
        ipt_fail=$((ipt_fail + 1))
      fi
    fi

    rc=0
    if [[ -n "$err_file" ]]; then
      iptables -X DERPER-CONNLIMIT >/dev/null 2>"$err_file" || rc=$?
    else
      iptables -X DERPER-CONNLIMIT >/dev/null 2>&1 || rc=$?
    fi
    if [[ "$rc" -ne 0 ]]; then
      local err=""
      [[ -n "$err_file" && -f "$err_file" ]] && err=$(cat "$err_file")
      if [[ "$err" != *"No chain"* ]]; then
        ipt_fail=$((ipt_fail + 1))
      fi
    fi

    if [[ "$ipt_fail" -gt 0 ]]; then
      failed=$((failed + 1))
    fi
  fi
  [[ -n "$err_file" ]] && rm -f "$err_file"
  if [[ "$failed" -gt 0 ]]; then
    echo "[错误] 移除 TLS 限流规则失败，可能残留部分防护规则。" >&2
    return 1
  fi
  return 0
}

script_self_path() {
  if [[ -n "${SCRIPT_SELF:-}" ]]; then
    printf '%s\n' "$SCRIPT_SELF"
    return 0
  fi
  local src="${BASH_SOURCE[0]}"
  if command -v readlink >/dev/null 2>&1; then
    local resolved
    resolved=$(readlink -f "$src" 2>/dev/null || true)
    if [[ -n "$resolved" ]]; then
      printf '%s\n' "$resolved"
      return 0
    fi
  fi
  (cd "$(dirname "$src")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$src")")
}

systemd_escape_arg() {
  local arg="$1"
  if [[ "$arg" =~ ^[a-zA-Z0-9_./:-]+$ ]]; then
    printf '%s' "$arg"
  else
    local escaped="${arg//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    printf '"%s"' "$escaped"
  fi
}

render_healthcheck_commands() {
  local prog="$1" ip="$2" metrics="$3"
  local cron_prog cron_ip cron_metrics cron_port cron_stun cron_level cron_verify non_global_arg=""
  local scheduler_config="${4:-${CONFIG_FILE:-}}" cron_config="" sys_config="" config_dir=""
  if [[ -n "$scheduler_config" ]]; then
    if [[ "$scheduler_config" != /* ]]; then
      if ! config_dir=$(cd "$(dirname "$scheduler_config")" 2>/dev/null && pwd -P); then
        echo "[错误] 无法解析健康检查配置文件目录：${scheduler_config}（调度命令不能使用相对路径）" >&2
        return 1
      fi
      scheduler_config="${config_dir}/$(basename "$scheduler_config")"
    fi
    printf -v cron_config ' --config %q' "$scheduler_config"
    sys_config=" --config $(systemd_escape_arg "$scheduler_config")"
  fi
  cron_prog=$(printf '%q' "$prog")
  cron_metrics=$(printf '%q' "$metrics")
  local sys_prog sys_metrics
  sys_prog=$(systemd_escape_arg "$prog")
  sys_metrics=$(systemd_escape_arg "$metrics")
  if [[ -n "$scheduler_config" ]]; then
    BASH_HEALTHCHECK_CMD="bash ${cron_prog}${cron_config} --health-check --metrics-textfile ${cron_metrics}"
    SYSTEMD_HEALTHCHECK_EXEC="/bin/bash ${sys_prog}${sys_config} --health-check --metrics-textfile ${sys_metrics}"
  else
    if [[ "${ALLOW_NON_GLOBAL_IP:-0}" -eq 1 ]]; then
      non_global_arg=" --allow-non-global-ip"
    fi
    cron_ip=$(printf '%q' "$ip")
    cron_port=$(printf '%q' "${DERP_PORT}")
    cron_stun=$(printf '%q' "${STUN_PORT}")
    cron_level=$(printf '%q' "${SECURITY_LEVEL}")
    if [[ "${VERIFY_CLIENTS_MODE}" == "off" ]]; then
      cron_verify="--no-verify-clients"
    else
      cron_verify="--force-verify-clients"
    fi
    BASH_HEALTHCHECK_CMD="bash ${cron_prog} --health-check --ip ${cron_ip} --derp-port ${cron_port} --stun-port ${cron_stun} --security-level ${cron_level} ${cron_verify}${non_global_arg} --metrics-textfile ${cron_metrics}"
    local sys_ip sys_port sys_stun sys_level
    sys_ip=$(systemd_escape_arg "$ip")
    sys_port=$(systemd_escape_arg "${DERP_PORT}")
    sys_stun=$(systemd_escape_arg "${STUN_PORT}")
    sys_level=$(systemd_escape_arg "${SECURITY_LEVEL}")
    SYSTEMD_HEALTHCHECK_EXEC="/bin/bash ${sys_prog} --health-check --ip ${sys_ip} --derp-port ${sys_port} --stun-port ${sys_stun} --security-level ${sys_level} ${cron_verify}${non_global_arg} --metrics-textfile ${sys_metrics}"
  fi
  local extra flag val
  for flag in state-file external-probe; do
    [[ -z "$scheduler_config" || "$flag" == state-file ]] || continue
    case "$flag" in state-file) val=$HEALTH_STATE_FILE ;; *) val=$EXTERNAL_PROBE ;; esac
    [[ -n "$val" ]] || continue
    printf -v extra '%q' "$val"
    BASH_HEALTHCHECK_CMD+=" --$flag $extra"
    SYSTEMD_HEALTHCHECK_EXEC+=" --$flag $(systemd_escape_arg "$val")"
  done
  if [[ -z "$scheduler_config" ]]; then
    local cron_region_id cron_region_code cron_region_name
    cron_region_id=$(printf '%q' "$REGION_ID")
    cron_region_code=$(printf '%q' "$REGION_CODE")
    cron_region_name=$(printf '%q' "$REGION_NAME")
    BASH_HEALTHCHECK_CMD+=" --region-id $cron_region_id --region-code $cron_region_code --region-name $cron_region_name"
    SYSTEMD_HEALTHCHECK_EXEC+=" --region-id $(systemd_escape_arg "$REGION_ID") --region-code $(systemd_escape_arg "$REGION_CODE") --region-name $(systemd_escape_arg "$REGION_NAME")"
    if [[ -n "$EXTERNAL_PROBE" || "$REQUIRE_H3" == 1 ]]; then
      BASH_HEALTHCHECK_CMD+=" --probe-timeout $PROBE_TIMEOUT --probe-max-age $PROBE_MAX_AGE"
      SYSTEMD_HEALTHCHECK_EXEC+=" --probe-timeout $PROBE_TIMEOUT --probe-max-age $PROBE_MAX_AGE"
      if [[ "$REQUIRE_H3" == 1 ]]; then BASH_HEALTHCHECK_CMD+=' --require-h3'; SYSTEMD_HEALTHCHECK_EXEC+=' --require-h3'; fi
    fi
  fi
}

render_healthcheck_units() {
  local svc_path="$1" timer_path="$2" sys_exec="$3"
  cat >"$svc_path" <<EOF
[Unit]
Description=DERP health check
[Service]
Type=oneshot
ExecStart=${sys_exec}
EOF

  cat >"$timer_path" <<EOF
[Unit]
Description=Run DERP health check every 5 minutes
[Timer]
OnCalendar=*:0/5
Persistent=true
Unit=derper-healthcheck.service
[Install]
WantedBy=timers.target
EOF
}

render_healthcheck_cron_file() {
  local cron_path="$1" bash_cmd="$2"
  cat >"$cron_path" <<EOF
# Managed by deploy_derper_ip_selfsigned.sh. Re-run --install-healthcheck-cron to refresh.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root ${bash_cmd} >/dev/null 2>&1
EOF
}

# 备份必须区分「原文件不存在」和「复制失败」。复制失败时不得进入会删原文件的回滚。
snapshot_healthcheck_file() {
  local src="$1" bak="$2" missing="$3"
  rm -f "$bak" "$missing" 2>/dev/null || true
  if [[ ! -e "$src" ]]; then
    : >"$missing" || return 1
    return 0
  fi
  if ! cp -f "$src" "$bak" || ! [[ -f "$bak" ]]; then
    echo "[错误] 无法备份已有调度文件：${src}。已中止更新，原文件保持不变。" >&2
    return 1
  fi
  if command -v cmp >/dev/null 2>&1; then
    if ! cmp -s "$src" "$bak"; then
      echo "[错误] 无法备份已有调度文件：${src}。已中止更新，原文件保持不变。" >&2
      return 1
    fi
  elif [[ "$(wc -c <"$src")" != "$(wc -c <"$bak")" ]]; then
    echo "[错误] 无法备份已有调度文件：${src}。已中止更新，原文件保持不变。" >&2
    return 1
  fi
  return 0
}

restore_healthcheck_snapshot() {
  local path="$1" bak="$2" missing="$3" mode="${4:-}"
  if [[ -f "$bak" ]]; then
    if ! cp -f "$bak" "$path"; then
      echo "[错误] 无法从备份恢复 ${path}，已保留快照 ${bak}。" >&2
      return 1
    fi
    if [[ -n "$mode" ]] && ! chmod "$mode" "$path"; then
      echo "[错误] 无法恢复 ${path} 的权限，已保留快照 ${bak}。" >&2
      return 1
    fi
    return 0
  fi
  if [[ -f "$missing" && -e "$path" ]] && ! rm -f "$path"; then
    echo "[错误] 无法删除本次新增的 ${path}，已保留快照。" >&2
    return 1
  fi
  return 0
}

# 在修改调度前记录两个独立状态，更新已有 timer 和迁移到 cron 共用。
snapshot_timer_runtime() {
  local tx_dir="$1"
  if systemctl is-active --quiet derper-healthcheck.timer 2>/dev/null; then
    : >"${tx_dir}/timer.was-active" || return 1
  fi
  if systemctl is-enabled --quiet derper-healthcheck.timer 2>/dev/null; then
    : >"${tx_dir}/timer.was-enabled" || return 1
  fi
  : >"${tx_dir}/timer.runtime-recorded" || return 1
}

# active 与 enabled 分别恢复，原本停止或禁用的 timer 不会被回滚拉起。
restore_recorded_timer_runtime() {
  local tx_dir="$1"
  [[ -f "${tx_dir}/timer.runtime-recorded" ]] || return 0
  command -v systemctl >/dev/null 2>&1 || return 1
  if [[ -f "${tx_dir}/timer.was-enabled" ]]; then
    systemctl enable derper-healthcheck.timer >/dev/null 2>&1 || return 1
  else
    systemctl disable derper-healthcheck.timer >/dev/null 2>&1 || return 1
  fi
  if [[ -f "${tx_dir}/timer.was-active" ]]; then
    systemctl start derper-healthcheck.timer >/dev/null 2>&1 || return 1
  else
    systemctl stop derper-healthcheck.timer >/dev/null 2>&1 || return 1
  fi
}

rollback_healthcheck_transaction() {
  local tx_dir="$1" dest="$2" stable="$3" svc_file="$4" timer_file="$5" cron_file="$6"
  local failed=0 units_changed=0
  if [[ -z "$tx_dir" || ! -d "$tx_dir" ]]; then
    return 0
  fi
  if [[ -f "${tx_dir}/timer.activation-attempted" && ( -f "${tx_dir}/timer.missing" || -f "${tx_dir}/svc.missing" ) ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now derper-healthcheck.timer >/dev/null 2>&1 || failed=1
  fi
  restore_healthcheck_snapshot "$svc_file" "${tx_dir}/svc.bak" "${tx_dir}/svc.missing" || failed=1
  restore_healthcheck_snapshot "$timer_file" "${tx_dir}/timer.bak" "${tx_dir}/timer.missing" || failed=1
  if [[ -f "${tx_dir}/svc.bak" || -f "${tx_dir}/timer.bak" || -f "${tx_dir}/svc.missing" || -f "${tx_dir}/timer.missing" ]]; then
    units_changed=1
  fi
  if [[ "$units_changed" -eq 1 ]] && command -v systemctl >/dev/null 2>&1; then
    if ! systemctl daemon-reload >/dev/null 2>&1; then
      echo "[错误] 回滚后 systemctl daemon-reload 失败，已保留快照：${tx_dir}" >&2
      failed=1
    fi
  fi

  restore_healthcheck_snapshot "$dest" "${tx_dir}/dest.bak" "${tx_dir}/dest.missing" 755 || failed=1
  restore_healthcheck_snapshot "$cron_file" "${tx_dir}/cron.bak" "${tx_dir}/cron.missing" 644 || failed=1
  restore_healthcheck_snapshot "${stable}/status" "${tx_dir}/status.bak" "${tx_dir}/status.missing" || failed=1
  restore_healthcheck_snapshot "${stable}/target.conf" "${tx_dir}/config.bak" "${tx_dir}/config.missing" 600 || failed=1
  if [[ "$failed" -eq 0 ]] && ! restore_recorded_timer_runtime "$tx_dir"; then
    echo "[错误] 无法恢复原 timer 运行状态，已保留快照：${tx_dir}" >&2
    failed=1
  fi
  if [[ "$failed" -ne 0 ]]; then
    echo "[错误] 调度回滚不完整，已保留快照目录：${tx_dir}" >&2
    return 1
  fi
  rm -rf "$tx_dir" 2>/dev/null || true
  return 0
}

finish_healthcheck_rollback() {
  local reason="$1"
  shift
  if rollback_healthcheck_transaction "$@"; then
    echo "[错误] ${reason}，已有调度保持原样。" >&2
  else
    echo "[错误] ${reason}，回滚不完整，已保留快照，请手工恢复。" >&2
  fi
  return 1
}

install_healthcheck_cron() {
  local HEALTH_STATE_FILE="${HEALTH_STATE_FILE:-$(deploy_state_root)/health/status.json}"
  local self ip metrics stable dest stable_config="" source_config="" config_dir
  self=$(script_self_path)
  if [[ ! -f "$self" ]]; then
    echo "[错误] 无法定位可重复执行的脚本文件（当前路径：${self}）。curl | bash 无法写入可靠 cron，请先把脚本保存到磁盘后再使用 --install-healthcheck-cron。" >&2
    return 1
  fi
  ip="${IP_ADDR:-}"
  [[ -n "$ip" ]] || { echo "[错误] 安装健康检查 cron 需要 --ip 或已探测到公网 IP。" >&2; return 1; }
  metrics="${METRICS_TEXTFILE:-${HEALTHCHECK_CRON_METRICS_DEFAULT}}"
  if [[ -n "${HEALTHCHECK_PROGRAM_DIR:-}" ]]; then
    stable="${HEALTHCHECK_PROGRAM_DIR}"
  elif mkdir -p /usr/local/lib/derper-deploy 2>/dev/null && [[ -w /usr/local/lib/derper-deploy ]]; then
    stable=/usr/local/lib/derper-deploy
  else
    stable="$(dirname "$HEALTHCHECK_CRON_PATH")/derper-healthcheck-program"
  fi
  mkdir -p "$stable" || return 1
  dest="${stable}/deploy_derper_ip_selfsigned.sh"
  if [[ -n "${CONFIG_FILE:-}" ]]; then
    source_config="$CONFIG_FILE"
    if [[ "$source_config" != /* ]]; then
      config_dir=$(cd "$(dirname "$source_config")" 2>/dev/null && pwd -P) || {
        echo "[错误] 无法解析健康检查配置文件目录：${source_config}" >&2
        return 1
      }
      source_config="${config_dir}/$(basename "$source_config")"
    fi
    stable_config="${stable}/target.conf"
  fi

  local BASH_HEALTHCHECK_CMD="" SYSTEMD_HEALTHCHECK_EXEC=""
  render_healthcheck_commands "$dest" "$ip" "$metrics" "$stable_config" || return 1

  local unit_dir="${HEALTHCHECK_UNIT_DIR:-/etc/systemd/system}"
  local svc_file="${unit_dir}/derper-healthcheck.service"
  local timer_file="${unit_dir}/derper-healthcheck.timer"
  local cron_file="${HEALTHCHECK_CRON_PATH}"

  local use_timer=0
  if command -v systemctl >/dev/null 2>&1 && mkdir -p "$unit_dir" 2>/dev/null && [[ -w "$unit_dir" ]]; then
    use_timer=1
  fi

  local tx_dir=""
  tx_dir=$(mktemp -d "${stable}/.healthcheck-tx.XXXXXX" 2>/dev/null || mktemp -d 2>/dev/null || true)
  if [[ -z "$tx_dir" || ! -d "$tx_dir" ]]; then
    echo "[错误] 无法创建调度备份目录，已中止更新，原文件保持不变。" >&2
    return 1
  fi
  if [[ -n "$tx_dir" && -d "$tx_dir" ]]; then
    if ! snapshot_healthcheck_file "$dest" "${tx_dir}/dest.bak" "${tx_dir}/dest.missing" \
      || ! snapshot_healthcheck_file "${stable}/status" "${tx_dir}/status.bak" "${tx_dir}/status.missing" \
      || ! snapshot_healthcheck_file "$cron_file" "${tx_dir}/cron.bak" "${tx_dir}/cron.missing"; then
      rm -rf "$tx_dir" 2>/dev/null || true
      return 1
    fi
    if [[ -n "$stable_config" ]] && ! snapshot_healthcheck_file "$stable_config" "${tx_dir}/config.bak" "${tx_dir}/config.missing"; then
      rm -rf "$tx_dir" 2>/dev/null || true
      return 1
    fi
    if [[ "$use_timer" -eq 1 || -e "$svc_file" || -e "$timer_file" ]]; then
      if ! snapshot_healthcheck_file "$svc_file" "${tx_dir}/svc.bak" "${tx_dir}/svc.missing" \
        || ! snapshot_healthcheck_file "$timer_file" "${tx_dir}/timer.bak" "${tx_dir}/timer.missing"; then
        rm -rf "$tx_dir" 2>/dev/null || true
        return 1
      fi
    fi
  fi

  if [[ -n "$tx_dir" && ( -e "$svc_file" || -e "$timer_file" ) ]] && command -v systemctl >/dev/null 2>&1; then
    if ! snapshot_timer_runtime "$tx_dir"; then
      echo "[错误] 无法记录原 timer 状态，已中止更新，原文件保持不变。" >&2
      rm -rf "$tx_dir" 2>/dev/null || true
      return 1
    fi
  fi

  # 写入稳定运行程序副本
  local dest_tmp
  dest_tmp=$(mktemp "${stable}/.deploy_derper_ip_selfsigned.XXXXXX" 2>/dev/null || true)
  [[ -z "$dest_tmp" ]] && dest_tmp="${dest}.tmp.$$"
  if ! cp -f "$self" "$dest_tmp" 2>/dev/null || ! chmod 755 "$dest_tmp" 2>/dev/null || ! mv -f "$dest_tmp" "$dest" 2>/dev/null; then
    rm -f "$dest_tmp" 2>/dev/null || true
    finish_healthcheck_rollback "无法安装健康检查稳定副本程序" "$tx_dir" "$dest" "$stable" "$svc_file" "$timer_file" "$cron_file" || return 1
  fi

  if [[ -n "$stable_config" ]]; then
    local config_tmp
    config_tmp=$(mktemp "${stable}/.derper-healthcheck-config.XXXXXX" 2>/dev/null || true)
    [[ -z "$config_tmp" ]] && config_tmp="${stable_config}.tmp.$$"
    if ! cp -f "$source_config" "$config_tmp" 2>/dev/null || ! chmod 600 "$config_tmp" 2>/dev/null || ! mv -f "$config_tmp" "$stable_config" 2>/dev/null; then
      rm -f "$config_tmp" 2>/dev/null || true
      finish_healthcheck_rollback "无法安装健康检查稳定配置副本" "$tx_dir" "$dest" "$stable" "$svc_file" "$timer_file" "$cron_file" || return 1
    fi
  fi

  if [[ "$use_timer" -eq 1 ]]; then
    if [[ -d "$svc_file" || -d "$timer_file" ]]; then
      finish_healthcheck_rollback "无法安装 healthcheck unit：路径是目录（${svc_file}）" "$tx_dir" "$dest" "$stable" "$svc_file" "$timer_file" "$cron_file" || return 1
    fi

    local svc_tmp timer_tmp
    svc_tmp=$(mktemp "${unit_dir}/.derper-healthcheck.service.XXXXXX" 2>/dev/null) || {
      finish_healthcheck_rollback "无法写入 healthcheck service 临时文件" "$tx_dir" "$dest" "$stable" "$svc_file" "$timer_file" "$cron_file" || return 1
    }
    timer_tmp=$(mktemp "${unit_dir}/.derper-healthcheck.timer.XXXXXX" 2>/dev/null) || {
      rm -f "$svc_tmp"
      finish_healthcheck_rollback "无法写入 healthcheck timer 临时文件" "$tx_dir" "$dest" "$stable" "$svc_file" "$timer_file" "$cron_file" || return 1
    }

    render_healthcheck_units "$svc_tmp" "$timer_tmp" "$SYSTEMD_HEALTHCHECK_EXEC"

    if ! mv -f "$svc_tmp" "$svc_file" 2>/dev/null; then
      rm -f "$svc_tmp" "$timer_tmp"
      finish_healthcheck_rollback "无法安装 healthcheck service unit 文件" "$tx_dir" "$dest" "$stable" "$svc_file" "$timer_file" "$cron_file" || return 1
    fi
    if ! mv -f "$timer_tmp" "$timer_file" 2>/dev/null; then
      rm -f "$timer_tmp"
      finish_healthcheck_rollback "无法安装 healthcheck timer unit 文件" "$tx_dir" "$dest" "$stable" "$svc_file" "$timer_file" "$cron_file" || return 1
    fi

    if ! systemctl daemon-reload; then
      finish_healthcheck_rollback "systemctl daemon-reload 失败，已撤销 timer 文件" "$tx_dir" "$dest" "$stable" "$svc_file" "$timer_file" "$cron_file" || return 1
    fi

    if ! : >"${tx_dir}/timer.activation-attempted"; then
      finish_healthcheck_rollback "无法记录新 timer 的启用尝试" "$tx_dir" "$dest" "$stable" "$svc_file" "$timer_file" "$cron_file" || return 1
    fi
    if ! systemctl enable --now derper-healthcheck.timer; then
      finish_healthcheck_rollback "无法启用 derper-healthcheck.timer，已尝试撤销 timer 文件" "$tx_dir" "$dest" "$stable" "$svc_file" "$timer_file" "$cron_file" || return 1
    fi

    if [[ -e "${cron_file}" ]]; then
      rm -f "${cron_file}" 2>/dev/null || true
      if [[ -e "${cron_file}" ]]; then
        finish_healthcheck_rollback "无法删除旧 cron（${cron_file}），已尝试撤销新 timer，避免双重调度" "$tx_dir" "$dest" "$stable" "$svc_file" "$timer_file" "$cron_file" || return 1
      fi
    fi
    printf 'scheduler=timer\nprogram=%s\ncommand=%s\n' "$dest" "$BASH_HEALTHCHECK_CMD" >"${stable}/status"
    [[ -n "$tx_dir" ]] && rm -rf "$tx_dir" 2>/dev/null || true
    echo "[信息] 已安装健康检查 timer：${unit_dir}/derper-healthcheck.timer（每 5 分钟，显式 bash 调用稳定副本）"
    return 0
  fi

  # cron 分支
  if [[ -d "$cron_file" ]]; then
    finish_healthcheck_rollback "无法安装 healthcheck cron：路径是目录（${cron_file}）" "$tx_dir" "$dest" "$stable" "$svc_file" "$timer_file" "$cron_file" || return 1
  fi
  local cron_dir cron_tmp
  cron_dir="$(dirname "$cron_file")"
  mkdir -p "$cron_dir" || {
    finish_healthcheck_rollback "无法创建 healthcheck cron 目录" "$tx_dir" "$dest" "$stable" "$svc_file" "$timer_file" "$cron_file" || return 1
  }
  cron_tmp=$(mktemp "${cron_dir}/.derper-healthcheck.cron.XXXXXX" 2>/dev/null || true)
  [[ -z "$cron_tmp" ]] && cron_tmp="${cron_file}.tmp.$$"
  render_healthcheck_cron_file "$cron_tmp" "$BASH_HEALTHCHECK_CMD"
  chmod 644 "$cron_tmp" 2>/dev/null || true
  if ! mv -f "$cron_tmp" "$cron_file" 2>/dev/null; then
    rm -f "$cron_tmp" 2>/dev/null || true
    finish_healthcheck_rollback "无法写入 healthcheck cron 文件" "$tx_dir" "$dest" "$stable" "$svc_file" "$timer_file" "$cron_file" || return 1
  fi
  printf 'scheduler=cron\nprogram=%s\ncommand=%s\n' "$dest" "$BASH_HEALTHCHECK_CMD" >"${stable}/status"
  if [[ -e "$timer_file" || -e "$svc_file" ]]; then
    if command -v systemctl >/dev/null 2>&1; then
      systemctl disable --now derper-healthcheck.timer >/dev/null 2>&1 || true
    fi
    rm -f "$timer_file" "$svc_file" 2>/dev/null || true
    if [[ -e "$timer_file" || -e "$svc_file" ]]; then
      finish_healthcheck_rollback "无法删除旧 timer/service（${timer_file}），已尝试撤销新 cron，避免双重调度" "$tx_dir" "$dest" "$stable" "$svc_file" "$timer_file" "$cron_file" || return 1
    fi
  fi
  [[ -n "$tx_dir" ]] && rm -rf "$tx_dir" 2>/dev/null || true
  echo "[信息] 已安装健康检查 cron：${cron_file}（每 5 分钟，--ip ${ip}，显式 bash 调用稳定副本）"
}

remove_healthcheck_cron() {
  if [[ -f "${HEALTHCHECK_CRON_PATH}" ]]; then
    rm -f "${HEALTHCHECK_CRON_PATH}"
    echo "[信息] 已删除健康检查 cron：${HEALTHCHECK_CRON_PATH}"
  fi
  local unit_dir="${HEALTHCHECK_UNIT_DIR:-/etc/systemd/system}"
  if [[ -f "${unit_dir}/derper-healthcheck.timer" || -f "${unit_dir}/derper-healthcheck.service" ]]; then
    if command -v systemctl >/dev/null 2>&1; then
      systemctl disable --now derper-healthcheck.timer >/dev/null 2>&1 || true
    fi
    rm -f "${unit_dir}/derper-healthcheck.timer" "${unit_dir}/derper-healthcheck.service"
    echo "[信息] 已删除健康检查 timer：${unit_dir}/derper-healthcheck.timer"
  fi
}

purge_maintain_program() {
  local dir
  dir="$(deploy_state_root)/maintenance"
  [[ -e "$dir" || -L "$dir" ]] || return 0
  refuse_symlink "$dir" || return 1
  [[ -d "$dir" ]] || { echo "[错误] 维护副本路径不是目录：${dir}" >&2; return 1; }
  if ! rm -f -- "${dir}/deploy_derper_ip_selfsigned.sh" "${dir}/target.conf"; then
    echo "[错误] 无法删除维护脚本或配置：${dir}" >&2
    return 1
  fi
  if [[ -e "${dir}/deploy_derper_ip_selfsigned.sh" || -L "${dir}/deploy_derper_ip_selfsigned.sh" || -e "${dir}/target.conf" || -L "${dir}/target.conf" ]]; then
    echo "[错误] 维护脚本或配置仍有残留：${dir}" >&2
    return 1
  fi
  if ! rmdir "$dir" 2>/dev/null; then
    if [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
      echo "[错误] 无法删除空维护目录：${dir}" >&2
      return 1
    fi
    echo "[信息] 已保留维护目录中的其他文件：${dir}"
  fi
  echo "[信息] 已清理维护脚本和配置：${dir}"
}

purge_healthcheck_program() {
  local stable
  local dirs=(/usr/local/lib/derper-deploy "$(dirname "$HEALTHCHECK_CRON_PATH")/derper-healthcheck-program")
  if [[ -n "${HEALTHCHECK_PROGRAM_DIR:-}" ]]; then
    dirs=("$HEALTHCHECK_PROGRAM_DIR")
  fi
  for stable in "${dirs[@]}"; do
    [[ -e "$stable" || -L "$stable" ]] || continue
    refuse_symlink "$stable" || return 1
    [[ -d "$stable" ]] || { echo "[错误] 健康检查副本路径不是目录：${stable}" >&2; return 1; }
    if ! rm -f -- "${stable}/deploy_derper_ip_selfsigned.sh" "${stable}/status" "${stable}/target.conf"; then
      echo "[错误] 无法删除健康检查稳定副本、配置或状态：${stable}" >&2
      return 1
    fi
    if [[ -e "${stable}/deploy_derper_ip_selfsigned.sh" || -L "${stable}/deploy_derper_ip_selfsigned.sh" || -e "${stable}/status" || -L "${stable}/status" || -e "${stable}/target.conf" || -L "${stable}/target.conf" ]]; then
      echo "[错误] 健康检查稳定副本或状态仍有残留：${stable}" >&2
      return 1
    fi
    # 只清理本脚本写入的文件，目录内其他用户文件保持原样。
    if ! rmdir "$stable" 2>/dev/null; then
      if [[ -z "$(ls -A "$stable" 2>/dev/null)" ]]; then
        echo "[错误] 无法删除空健康检查副本目录：${stable}" >&2
        return 1
      fi
      echo "[信息] 已保留健康检查目录中的其他用户文件：${stable}"
    fi
    echo "[信息] 已清理健康检查稳定副本和状态：${stable}"
  done
}

post_deploy_extras() {
  apply_tls_connlimit || return 1
  if [[ "${INSTALL_HEALTHCHECK_CRON:-0}" -eq 1 ]]; then
    install_healthcheck_cron || return 1
  fi
  warn_world_writable_socket "$(expected_tailscaled_socket)"
}

# extras 失败时证书事务已提交，只报告、不回滚已验证的部署。
run_post_deploy_extras() {
  post_deploy_extras && return 0
  echo "[错误] 服务与证书已部署成功，但后续加固失败（--tls-connlimit 或健康检查 cron）。已保留当前部署，不会回滚证书。" >&2
  return 1
}

print_firewall_tips() {
  echo "[步骤] 端口放行提示（请确保云厂商安全组也已放行）："
  echo "  - 必需：${DERP_PORT}/tcp（DERP TLS），${STUN_PORT}/udp（STUN）"
  echo "  - 可选：80/tcp（仅当使用 ACME 自动签发时；本脚本为自签证书，无需）"
  
  # UFW
  if command -v ufw >/dev/null 2>&1; then
    if [[ "${AUTO_UFW}" -eq 1 ]]; then
      echo "[信息] 自动放行 UFW 端口规则…"
      ufw allow ${DERP_PORT}/tcp || true
      ufw allow ${STUN_PORT}/udp || true
    else
      echo "[信息] 检测到 UFW，可手动执行："
      echo "  ufw allow ${DERP_PORT}/tcp"
      echo "  ufw allow ${STUN_PORT}/udp"
    fi
  fi
  
  # firewalld
  if command -v firewall-cmd >/dev/null 2>&1; then
    echo "[信息] 检测到 firewalld，可手动执行："
    echo "  firewall-cmd --permanent --add-port=${DERP_PORT}/tcp"
    echo "  firewall-cmd --permanent --add-port=${STUN_PORT}/udp"
    echo "  firewall-cmd --reload"
  fi
  
  # iptables（仅提示，不自动执行）
  if command -v iptables >/dev/null 2>&1 && ! command -v ufw >/dev/null 2>&1 && ! command -v firewall-cmd >/dev/null 2>&1; then
    echo "[信息] 未检测到 UFW/firewalld，若使用 iptables 可手动执行："
    echo "  iptables -I INPUT -p tcp --dport ${DERP_PORT} -j ACCEPT"
    echo "  iptables -I INPUT -p udp --dport ${STUN_PORT} -j ACCEPT"
    echo "  # 保存规则（Debian/Ubuntu）："
    echo "  netfilter-persistent save"
    echo "  # 或（RHEL/CentOS）："
    echo "  service iptables save"
  fi

  # 主机与云层面加固建议（公网中继的关键风险不在 DERP 协议，而在主机本身）
  echo ""
  echo "[建议] 主机加固（公网中继关键项）："
  echo "  - 云安全组入方向只放行 ${DERP_PORT}/tcp 与 ${STUN_PORT}/udp；其余端口（尤其 22/tcp）不要对 0.0.0.0/0 开放。"
  echo "  - 管理连接使用系统 OpenSSH（sshd）经 Tailnet 传输，不启用 Tailscale SSH；保留云厂商 VNC/控制台兜底；"
  echo "    或至少限源 IP + 禁用密码登录（PasswordAuthentication no）。"
  echo "  - 出方向不要收紧：tailscaled 需要访问控制面与官方 DERP/STUN 做探测（netcheck/升级）。"
  echo "  - 单机单用途：本机只跑 derper + tailscaled，减少暴露面。"
  echo "  - 定期查看 journalctl -u derper：-verify-clients 的拒绝记录是异常访问/滥用信号。"
  check_extra_attack_surface || true
  check_automatic_updates || true
}

runtime_checks() {
  echo "[步骤] 运行时快速自检…"
  echo "- 检查端口监听："
  if command -v ss >/dev/null 2>&1; then
    ss -tulpn | sed -n '1,200p' | grep -E ":(${DERP_PORT}|${STUN_PORT})([^0-9]|$)" || true
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tulpn | sed -n '1,200p' | grep -E ":(${DERP_PORT}|${STUN_PORT})([^0-9]|$)" || true
  fi

  echo "- 测试 HTTPS 握手（优先本机回环，避免 NAT hairpin 误报；自签证书会提示不受信）："
  local tls_ok=0 probe_host
  if command -v openssl >/dev/null 2>&1; then
    while IFS= read -r probe_host; do
      [[ -n "$probe_host" ]] || continue
      if _timeout_run 5 openssl s_client -connect "${probe_host}:${DERP_PORT}" -servername "${IP_ADDR}" -brief </dev/null >/dev/null 2>&1; then
        echo "  [信息] TLS 握手成功：${probe_host}:${DERP_PORT}"
        tls_ok=1
        break
      fi
    done < <(tls_probe_endpoints)
    [[ "$tls_ok" -eq 1 ]] || echo "  [警告] TLS 握手失败（127.0.0.1 与 ${IP_ADDR} 均不可达）" >&2
  else
    echo "  [提示] 未找到 openssl，跳过 TLS 探测。"
  fi

  echo "- 测试 STUN 端口可达性（UDP，仅粗检；nc -zvu 可能假阳性）："
  if command -v nc >/dev/null 2>&1; then
    (_timeout_run 3 nc -zvu 127.0.0.1 "${STUN_PORT}" || _timeout_run 3 nc -zvu "${IP_ADDR}" "${STUN_PORT}" || true)
  else
    echo "  [提示] 未找到 nc，跳过 UDP 探测。"
  fi

  echo "- 网络区域探测（不等于合法客户端中继验收）："
  if command -v tailscale >/dev/null 2>&1; then
    tailscale netcheck 2>/dev/null | sed -n '1,40p' || true
  fi
  echo "  [未验范围] netcheck 的成功或最近区域不等于 Region ${REGION_ID} 的合法客户端中继往返。"
  echo "  [下一步] 核对客户端下发配置，再运行独立合法客户端 H3 探针；当前快速自检不报告 H3 通过。"
  echo "  [说明] debug derp 使用临时身份，verify-clients 开启时可能被正常拒绝，不自动执行。"
}

# 从 ss -tulnp 或 netstat -tulnp 的混合输出中取出一种协议上的一个端口。
# tcp6/udp6 分别归入 tcp/udp；端口在比较前去掉前导零。同行的另一种协议不参与判断。
listening_port_lines_stdin() {
  local proto="$1" canon
  case "$proto" in
    tcp|udp) ;;
    *) return 1 ;;
  esac
  canon=$(_decimal_norm "$2")
  grep -E "^${proto}6?[[:space:]].*:${canon}([^0-9]|$)" || true
}

listening_port_lines() {
  printf '%s\n' "$1" | listening_port_lines_stdin "$2" "$3"
}

# 只认 ss 的 pid=<PID> 或 netstat 的 <PID>/程序名，不把 Recv-Q/Send-Q 当成 PID。
listener_pid_field_matches() {
  local pid="$1"
  [[ -n "$pid" && "$pid" != "0" ]] || return 1
  grep -Eq "(^|[^[:alnum:]])pid=${pid}([^0-9]|$)|[[:space:]]${pid}/[^[:space:]/]+"
}

# 判断指定协议上的端口是否由 derper 占用（旧部署可能只听 TLS、没有 STUN）。
port_listening_owned_by_derper() {
  local listening="$1" proto="$2" port="$3" main_pid="${4:-}"
  local lines
  lines=$(listening_port_lines "$listening" "$proto" "$port")
  [[ -n "$lines" ]] || return 1
  if [[ -n "$main_pid" && "$main_pid" != "0" ]]; then
    printf '%s\n' "$lines" | listener_pid_field_matches "$main_pid" && return 0
    return 1
  fi
  printf '%s\n' "$lines" | grep -Eq '("derper"|/derper([[:space:]]|$))' && return 0
  return 1
}

# 在写入 systemd 服务前，预检端口占用，避免启动后才失败。
# 自家 derper 占用的端口（含「有 TLS、无 STUN」的旧部署）不视为冲突，否则 --force/--repair 会被卡死。
check_port_conflicts_from_listening() {
  local listening="$1"
  if current_derper_owns_ports; then
    echo "[信息] 目标端口当前由 derper 服务占用，允许修复/重启流程继续。"
    return 0
  fi

  local main_pid=""
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet derper 2>/dev/null; then
    main_pid=$(systemctl show -p MainPID --value derper 2>/dev/null || echo "")
  fi

  local conflict=0
  local derp_lines stun_lines derp_port stun_port
  derp_port=$(_decimal_norm "${DERP_PORT}")
  stun_port=$(_decimal_norm "${STUN_PORT}")
  derp_lines=$(listening_port_lines "$listening" tcp "$derp_port")
  stun_lines=$(listening_port_lines "$listening" udp "$stun_port")

  if [[ -n "$derp_lines" ]]; then
    if port_listening_owned_by_derper "$listening" tcp "$derp_port" "$main_pid"; then
      echo "[信息] TCP 端口 ${derp_port} 当前由 derper 占用，允许修复/重启流程继续。"
    else
      echo "[错误] 检测到 TCP 端口 ${derp_port} 已被占用。请更换 --derp-port 或释放占用进程：" >&2
      printf '%s\n' "$derp_lines" | sed -n '1,200p' >&2 || true
      conflict=1
    fi
  fi
  if [[ -n "$stun_lines" ]]; then
    if port_listening_owned_by_derper "$listening" udp "$stun_port" "$main_pid"; then
      echo "[信息] UDP 端口 ${stun_port} 当前由 derper 占用，允许修复/重启流程继续。"
    else
      echo "[错误] 检测到 UDP 端口 ${stun_port} 已被占用。请更换 --stun-port 或释放占用进程：" >&2
      printf '%s\n' "$stun_lines" | sed -n '1,200p' >&2 || true
      conflict=1
    fi
  fi
  [[ ${conflict} -eq 0 ]]
}

check_port_conflicts() {
  echo "[步骤] 端口占用预检…"
  local listening=""
  if command -v ss >/dev/null 2>&1; then
    listening=$(ss -ltunp 2>/dev/null || true)
  elif command -v netstat >/dev/null 2>&1; then
    listening=$(netstat -tulnp 2>/dev/null || true)
  fi
  if ! check_port_conflicts_from_listening "$listening"; then
    echo "[提示] 你也可以使用如下命令进一步排查：" >&2
    echo "  ss -tulpn | grep -E ':${DERP_PORT}|:${STUN_PORT}'" >&2
    echo "  netstat -tulpn | grep -E ':${DERP_PORT}|:${STUN_PORT}'" >&2
    exit 1
  fi
  echo "[信息] 端口未发现占用。"
}

# 暴露面检查：列出除本脚本 DERP 端口外、面向非回环地址的 TCP 监听端口。
# 只警告不阻断——单机单用途是公网 DERP 服务器的重要基线，
# 每个额外的公网监听端口（尤其是 0.0.0.0:22 的 SSH）都会扩大被攻击面。
check_extra_attack_surface() {
  EXTRA_LISTENERS=""
  local listening=""
  # ss/netstat 可输出 %lo 等接口后缀；IPv6 后缀可位于方括号内或外。
  # 完整匹配地址与端口，避免把 ::1:2 等非回环 IPv6 地址当成 ::1。
  local loopback_endpoint_re='^(127(\.[0-9]{1,3}){3}(%[^:]+)?|\[::1(%[^]:]+)?\](%[^:]+)?|::1(%[^:]+)?):[0-9]+$'
  if command -v ss >/dev/null 2>&1; then
    listening=$(ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' \
      | grep -E ':[0-9]+$' \
      | grep -vE "$loopback_endpoint_re" \
      | grep -vE ":${DERP_PORT}$" || true)
  elif command -v netstat >/dev/null 2>&1; then
    listening=$(netstat -ltn 2>/dev/null | awk 'NR>2 && $1 ~ /^tcp6?/ {print $4}' \
      | grep -E ':[0-9]+$' \
      | grep -vE "$loopback_endpoint_re" \
      | grep -vE ":${DERP_PORT}$" || true)
  fi
  EXTRA_LISTENERS=$(printf '%s\n' "$listening" | sort -u | grep -v '^$' || true)
  if [[ -n "$EXTRA_LISTENERS" ]]; then
    echo "[警告] 检测到除 DERP 端口外，仍有面向非回环地址的 TCP 监听端口：" >&2
    printf '%s\n' "$EXTRA_LISTENERS" | sed 's/^/  - /' >&2
    echo "  公网 DERP 服务器建议单机单用途；每个额外端口都会扩大暴露面。" >&2
    if printf '%s\n' "$EXTRA_LISTENERS" | grep -qE '(^|:)22$|^\[::\]:22$'; then
      echo "  尤其注意 SSH 端口：使用系统 OpenSSH 经 Tailnet 传输或限源 IP，不启用 Tailscale SSH。" >&2
    fi
  fi
  return 0
}

# 检测是否启用了操作系统自动安全更新（unattended-upgrades / dnf-automatic）。
# 公网机器长期最大风险是"忘记打补丁的已知漏洞"，只提示不阻断。
check_automatic_updates() {
  AUTO_UPDATES_OK=0
  if command -v apt >/dev/null 2>&1; then
    if grep -rqsE 'APT::Periodic::Unattended-Upgrade[[:space:]]+"1"' /etc/apt/apt.conf.d/ 2>/dev/null; then
      AUTO_UPDATES_OK=1
    fi
  fi
  if [[ "$AUTO_UPDATES_OK" -ne 1 ]] && command -v dnf >/dev/null 2>&1; then
    if systemctl is-enabled dnf-automatic.timer >/dev/null 2>&1 || \
       systemctl is-enabled dnf-automatic-install.timer >/dev/null 2>&1; then
      AUTO_UPDATES_OK=1
    fi
  fi
  if [[ "$AUTO_UPDATES_OK" -ne 1 ]]; then
    echo "[警告] 未检测到自动安全更新（unattended-upgrades / dnf-automatic）。" >&2
    echo "  公网机器建议开启自动安全补丁：Debian/Ubuntu 安装并启用 unattended-upgrades；RHEL/Fedora 启用 dnf-automatic。" >&2
  else
    echo "[信息] 已启用操作系统自动安全更新。"
  fi
  return 0
}

print_acl_snippet_cert() {
  local ip="$1" port="$2" fp="$3"
  cat <<JSON
==================== 推荐粘贴到 Tailscale 管理后台（Access Controls）的 derpMap 片段（使用 CertName 更安全） ====================
{
  "derpMap": {
    "OmitDefaultRegions": false,
    "Regions": {
      "${REGION_ID}": {
        "RegionID": ${REGION_ID},
        "RegionCode": "${REGION_CODE}",
        "RegionName": "${REGION_NAME}",
        "Nodes": [
          {
            "Name": "${REGION_ID}a",
            "RegionID": ${REGION_ID},
            "HostName": "${ip}",
            "DERPPort": ${port},
            "STUNPort": ${STUN_PORT},
            "CertName": "sha256-raw:${fp}"
          }
        ]
      }
    }
  }
}
============================================================================================================================================
JSON
}

print_client_verify_steps() {
  cat <<EOF
============================== 客户端验证步骤（在同一 Tailnet 的任意设备上执行） ==============================
1) 合并策略：上面仅是本节点片段，不是完整策略替换文件。
   - 保留现有 grants、ssh、其他规则和 Regions；只合并本次节点，先核对 Region ${REGION_ID} 无冲突。
   - 上游 derper 日志中的 Region 900 可能只是示例；以本次脚本生成的 Region ${REGION_ID} 为准。
   - 若你修改了端口，请同步更新 "DERPPort" 与 "STUNPort"。
   - 保存后等待 10~60 秒，客户端会自动拉取最新 derpMap。

2) 在客户端验证：
   - 查看 DERP 拓扑：
       tailscale netcheck | sed -n '1,160p'
     观察目标 Region ${REGION_ID} / ${REGION_CODE} 是否出现；这只证明区域探测，不证明中继往返。
   - 确认实际下发配置：tailscale debug derp-map（核对 IP、端口和 CertName）。

   - 查看连接状态：
       tailscale status
     某些直连失败的对端会显示 "relay \"my-derp\"" 或你的 Region/Node 名称。

3) UDP STUN 探测（可选）：
   - 在 Linux/macOS 客户端上可运行：
       nc -zvu <你的公网IP> ${STUN_PORT}
     succeeded / open 也可能是假阳性，不作为 STUN 验收通过条件。
   - 用 stunc、已正确配置的 derpprobe 或 scripts/h3_probe.py 验证真实 STUN Binding 响应。
   - debug derp 使用随机临时身份，verify-clients 开启时可能被正常拒绝，不能代替合法客户端。

4) 完整中继验收（H3）：
   - 在独立合法 Linux 客户端按 docs/ACCEPTANCE_CN.md 运行 h3_probe.py，指定 Region ${REGION_ID} 和合法对端。
   - 必须同时核对下发配置、在线证书、指定 Region 的真实往返及 STUN；直连/其他区域记为未验，不是 DERP 故障。
   - Windows 实证需保留自己的指定区域往返；不要为了出结果全局封 UDP 或关闭 verify-clients。

5) 常见排查：
   - derper 启动失败：journalctl -u derper -f 查看报错（证书路径/端口占用/参数）。
   - 证书文件名：derper manual 模式读取 /opt/derper/certs/<公网IP>.crt 与 .key。
   - 客户端未走你的 DERP：确认 derpMap 已保存、HostName 为公网 IP、CertName 指纹与在线证书一致。
   - 证书轮换会改变 CertName：按 prepare/apply 流程安排策略同步与切换窗口；默认不自动换证。
   - 端口被拦截：确认云安全组/本机防火墙已放行 ${DERP_PORT}/tcp 与 ${STUN_PORT}/udp。
=========================================================================================================
EOF
}

# 建议：约束本服务器节点在 Tailnet 内的身份。Tailscale 默认 ACL 全通，
# 若这台公网 DERP 机器被攻破，攻击者将获得一个可访问整个 Tailnet 的节点身份；
# 打 tag 并最小授权后，"中继被攻破 ≠ 内网失守"。
print_server_node_acl_advice() {
  cat <<'EOF'
==================== 建议：约束本服务器节点在 Tailnet 内的身份（重要） ====================
Tailscale 默认 ACL 是全通的：如果这台公网机器被攻破，攻击者会获得一个
可访问整个 Tailnet 的节点身份。建议给服务器打 tag 并最小授权：

1) 在管理后台 Machines 页给该节点打 tag，或在首次登录时使用：
     sudo tailscale up --advertise-tags=tag:derper-server
   已登录的 Linux CLI 没有 tailscale set --tags。

2) 在管理后台 Access Controls 中声明 tag 所有者：
     "tagOwners": {
       "tag:derper-server": ["autogroup:admin"]
     }

3) 不要在任何放行规则里把 "tag:derper-server" 写成 "src"；
   确需从服务器访问内网资源时，再加最小规则（如仅允许访问特定设备/端口）。
   verify-clients 还要求这台服务器能看到合法客户端。只打 tag 并删掉所有可见性，
   中继会拒绝连接。同一 Tailnet 不等于校验已经通过，变更后要用合法客户端实测。
====================================================================================
EOF
}

# JSON渲染不依赖jq/Python，单文件仍可直接复制运行。
json_quote() {
  local s="${1-}" ch code i
  printf '"'
  for ((i=0; i<${#s}; i++)); do
    ch=${s:i:1}
    case "$ch" in
      '"') printf '\\"' ;; '\') printf '\\\\' ;;
      $'\n') printf '\\n' ;; $'\r') printf '\\r' ;; $'\t') printf '\\t' ;;
      # Bash 3.2 按字节切片，printf %d 对 >=0x80 的字节返回符号扩展的负数；先还原为无符号再判断控制字符。
      *) printf -v code '%d' "'$ch"; (( code >= 0 )) || code=$((code + 256)); if (( code < 32 )); then printf '\\u%04x' "$code"; else printf '%s' "$ch"; fi ;;
    esac
  done
  printf '"'
}

json_nullable() { if [[ -n "${1-}" ]]; then json_quote "$1"; else printf null; fi; }
# 与 REGION_ID 一样只输出 JSON 安全整数（绝对值不超过 2^53-1）。超出则 null，避免大整数被静默截断。
json_number() {
  local n="${1-}" abs
  [[ "$n" =~ ^-?(0|[1-9][0-9]*)$ ]] || { printf null; return; }
  abs=${n#-}
  if decimal_in_closed_range "$abs" 0 9007199254740991; then printf '%s' "$n"; else printf null; fi
}

probe_path_is_trusted() {
  local path="$1" uid mode
  [[ "$path" == /* && -f "$path" && -x "$path" && ! -L "$path" ]] || return 1
  [[ "$(id -u)" == 0 ]] || return 0
  while :; do
    [[ ! -L "$path" ]] || return 1
    uid=$(stat -c %u "$path" 2>/dev/null) || return 1
    mode=$(stat -c %a "$path" 2>/dev/null) || return 1
    [[ "$uid" == 0 ]] && (( (8#$mode & 0022) == 0 )) || return 1
    [[ "$path" != / ]] || break
    path=$(dirname "$path")
  done
}

run_external_probe() {
  H3_STATUS=not_checked; H3_REASON=probe_not_configured
  [[ -n "$EXTERNAL_PROBE" ]] || return 0
  H3_STATUS=unknown; H3_REASON=probe_untrusted_or_unavailable
  probe_path_is_trusted "$EXTERNAL_PROBE" || return 0
  command -v timeout >/dev/null 2>&1 || { H3_REASON=probe_timeout_tool_missing; return 0; }
  local out err rc=0 line key value seen='|' now checked='' schema='' region='' ip='' dp='' sp='' derp='' stun=''
  out=$(mktemp) || return 0
  err=$(mktemp) || { rm -f "$out"; return 0; }
  # 文件大小与运行时间均有界；不把适配器的输出/凭据直接打到日志。
  ( ulimit -f 128; _timeout_run "$PROBE_TIMEOUT" "$EXTERNAL_PROBE" --region-id "$REGION_ID" --ip "$IP_ADDR" --derp-port "$DERP_PORT" --stun-port "$STUN_PORT" ) >"$out" 2>"$err" || rc=$?
  H3_REASON=probe_invalid_report
  if [[ "$rc" != 0 && "$rc" != 1 ]]; then H3_REASON=probe_timeout_or_error; rm -f "$out" "$err"; return 0; fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || { rm -f "$out" "$err"; return 0; }
    key=${line%%=*}; value=${line#*=}
    [[ "$seen" != *"|$key|"* ]] || { rm -f "$out" "$err"; return 0; }
    seen+="$key|"
    case "$key" in
      schema) schema=$value ;; region_id) region=$value ;; ip) ip=$value ;;
      derp_port) dp=$value ;; stun_port) sp=$value ;; checked_at) checked=$value ;;
      derp) derp=$value ;; stun) stun=$value ;;
      *) rm -f "$out" "$err"; return 0 ;;
    esac
  done <"$out"
  rm -f "$out" "$err"
  [[ "$schema" == 1 && "$region" == "$REGION_ID" && "$ip" == "$IP_ADDR" && "$dp" == "$DERP_PORT" && "$sp" == "$STUN_PORT" && "$checked" =~ ^[1-9][0-9]{0,10}$ ]] || return 0
  [[ "$derp" == ok || "$derp" == failed ]] && [[ "$stun" == ok || "$stun" == failed ]] || return 0
  now=$(date +%s)
  if (( checked > now+5 || now-checked > PROBE_MAX_AGE )); then H3_REASON=probe_stale; return 0; fi
  if [[ "$rc" == 0 && "$derp" == ok && "$stun" == ok ]]; then
    H3_STATUS=healthy; H3_REASON=external_derp_and_stun_verified
  elif [[ "$rc" == 1 && ( "$derp" == failed || "$stun" == failed ) ]]; then
    H3_STATUS=failed; H3_REASON=external_derp_or_stun_failed
  fi
}

check_metrics_freshness() {
  METRICS_FRESHNESS=not_checked; METRICS_AGE=''
  [[ -n "$METRICS_SOURCE" ]] || return 0
  METRICS_FRESHNESS=unknown
  [[ -r "$METRICS_SOURCE" && -f "$METRICS_SOURCE" && ! -L "$METRICS_SOURCE" ]] || return 0
  local stamp count
  count=$(grep -c '^derper_metrics_unixtime ' "$METRICS_SOURCE" || true)
  [[ "$count" == 1 ]] || return 0
  stamp=$(awk '$1=="derper_metrics_unixtime" && NF==2 {print $2}' "$METRICS_SOURCE")
  [[ "$stamp" =~ ^[1-9][0-9]{0,10}$ ]] || return 0
  (( stamp <= SAMPLED_AT+5 )) || return 0
  METRICS_AGE=$((SAMPLED_AT-stamp))
  (( METRICS_AGE >= 0 )) || METRICS_AGE=0
  if (( METRICS_AGE > METRICS_MAX_AGE )); then METRICS_FRESHNESS=stale; else METRICS_FRESHNESS=fresh; fi
}

derive_health_layers() {
  H0_STATUS=healthy; H1_STATUS=failed; H2_STATUS=not_applicable
  local tool
  for tool in openssl systemctl; do command -v "$tool" >/dev/null 2>&1 || H0_STATUS=unknown; done
  if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then H0_STATUS=unknown; fi
  if [[ "$H0_STATUS" == unknown || "${CERT_CHECK_UNKNOWN:-0}" == 1 || "${PORT_CHECK_UNKNOWN:-0}" == 1 ]]; then
    H1_STATUS=unknown
  elif [[ "${DERPER_RUNNING:-0}" == 1 && "${PORT_TLS_OK:-0}" == 1 && "${PORT_STUN_OK:-0}" == 1 && "${CURRENT_DERPER_OWNS_PORTS:-0}" != 1 && "${PORT_OWNER_DATA_AVAILABLE:-0}" != 1 ]]; then
    H1_STATUS=unknown
  elif ( local DERPER_VERIFY_CLIENTS_EFFECTIVE=0; health_is_ok ) && [[ "${CURRENT_DERPER_OWNS_PORTS:-0}" == 1 ]]; then
    H1_STATUS=healthy
  fi
  if [[ "${DERPER_VERIFY_CLIENTS_EFFECTIVE:-0}" == 1 ]]; then
    H2_STATUS=failed
    if [[ "${TS_AUTH_UNKNOWN:-0}" == 1 ]]; then H2_STATUS=unknown
    elif [[ "${TS_RUNNING:-0}" == 1 && "${TS_LOCALAPI_OK:-0}" == 1 ]]; then H2_STATUS=healthy; fi
  fi
}

snapshot_exit_code() {
  if [[ "${HEALTH_SNAPSHOT_READY:-0}" != 1 ]]; then health_check_exit_code "${1:-0}"; return; fi
  local status unknown=0 failed=0
  for status in "$H0_STATUS" "$H1_STATUS" "$H2_STATUS"; do
    [[ "$status" != unknown ]] || unknown=1
    [[ "$status" != failed ]] || failed=1
  done
  if [[ -n "$EXTERNAL_PROBE" || "$REQUIRE_H3" == 1 ]]; then
    [[ "$H3_STATUS" != failed ]] || failed=1
    [[ "$H3_STATUS" == healthy || "$H3_STATUS" == failed ]] || unknown=1
  fi
  case "$METRICS_FRESHNESS" in stale|unknown) unknown=1 ;; esac
  if [[ "${METRICS_WRITE_FAILED:-0}" == 1 || "${STATE_WRITE_FAILED:-0}" == 1 || "${1:-${HEALTH_VALIDATE_FAILED:-0}}" != 0 ]]; then failed=1; fi
  if [[ "$unknown" == 1 ]]; then printf '2\n'; elif [[ "$failed" == 1 ]]; then printf '1\n'; else printf '0\n'; fi
}

render_status_json() {
  local rc result reason=verified_local_scope attention=false success="${HEALTH_LAST_SUCCESS:-0}"
  rc=$(snapshot_exit_code "${HEALTH_VALIDATE_FAILED:-0}")
  case "$rc" in 0) result=healthy; success=$SAMPLED_AT ;; 1) result=failed ;; *) result=unknown ;; esac
  if [[ "$rc" != 0 ]]; then
    attention=true; reason=local_health_not_verified
    if [[ "$METRICS_FRESHNESS" == stale || "$METRICS_FRESHNESS" == unknown ]]; then reason=metrics_source_not_fresh
    elif [[ -n "$EXTERNAL_PROBE" || "$REQUIRE_H3" == 1 ]] && [[ "$H3_STATUS" != healthy ]]; then reason=$H3_REASON
    elif [[ "${METRICS_WRITE_FAILED:-0}" == 1 || "${STATE_WRITE_FAILED:-0}" == 1 ]]; then reason=result_write_failed; fi
  fi
  printf '{"schema_version":1,"scope_id":'
  json_nullable "$(health_scope_id || true)"
  printf ',"sampled_at":%s,"last_success_at":' "$SAMPLED_AT"
  if [[ "$success" == 0 ]]; then printf null; else printf '%s' "$success"; fi
  printf ',"result":'
  json_quote "$result"
  printf ',"reason":'; json_quote "$reason"; printf ',"needs_manual_attention":%s,"config_file":' "$attention"; json_nullable "$CONFIG_FILE"
  printf ',"journal_storage":'; json_quote "${JOURNAL_STORAGE:-unknown}"
  printf ',"scope":"H0-H2; H3 requires independent client","layers":{"h0":'; json_quote "$H0_STATUS"
  printf ',"h1":'; json_quote "$H1_STATUS"; printf ',"h2":'; json_quote "$H2_STATUS"; printf ',"h3":'; json_quote "$H3_STATUS"
  printf '},"h3_reason":'; json_quote "$H3_REASON"
  printf ',"metrics":{"freshness":'; json_quote "$METRICS_FRESHNESS"; printf ',"age_seconds":'; json_number "$METRICS_AGE"
  printf '},"target":{"ip":'; json_quote "$IP_ADDR"; printf ',"derp_port":'; json_number "$DERP_PORT"
  printf ',"stun_port":'; json_number "$STUN_PORT"; printf ',"region_id":'; json_number "$REGION_ID"
  printf ',"region_code":'; json_quote "$REGION_CODE"; printf ',"region_name":'; json_quote "$REGION_NAME"
  printf ',"verify_clients":'; json_quote "$VERIFY_CLIENTS_MODE"; printf '},"certificate":{"disk_sha256":'; json_nullable "${HEALTH_CERT_SHA256:-}"
  printf ',"live_sha256":'; json_nullable "${HEALTH_LIVE_SHA256:-}"; printf ',"days_remaining":'; json_number "${HEALTH_DAYS_LEFT:-}"
  printf '},"writes":{"metrics_failed":%s,"state_failed":%s}' "${METRICS_WRITE_FAILED:-0}" "${STATE_WRITE_FAILED:-0}"
  printf ',"maintenance":{"mode":'
  json_quote "$(read_maintenance_kv mode 2>/dev/null || echo manual)"
  printf ',"result":'
  json_quote "$(read_maintenance_kv result 2>/dev/null || echo idle)"
  printf ',"reason":'
  json_quote "$(read_maintenance_kv reason 2>/dev/null || echo '')"
  printf ',"needs_manual":%s' "$(read_maintenance_kv needs_manual 2>/dev/null || echo 0)"
  printf ',"intent":'
  json_quote "$(read_maintenance_kv intent 2>/dev/null || echo unset)"
  printf '}}\n'
}

render_derpmap_json() {
  if [[ "$H1_STATUS" != healthy || ! "${HEALTH_LIVE_SHA256:-}" =~ ^[0-9a-f]{64}$ ]]; then
    echo '[错误] 本地身份未验证，不能生成可信derpMap。' >&2
    # 确认故障是 1；采不到（未知或没有指纹）是 2，不能把未知报成故障。
    if [[ "$H1_STATUS" == failed ]]; then return 1; fi
    return 2
  fi
  printf '{"Regions":{'; json_quote "$REGION_ID"
  printf ':{"RegionID":%s,"RegionCode":' "$REGION_ID"; json_quote "$REGION_CODE"
  printf ',"RegionName":'; json_quote "$REGION_NAME"
  printf ',"Nodes":[{"Name":"custom","RegionID":%s,"HostName":' "$REGION_ID"; json_quote "$IP_ADDR"
  printf ',"IPv4":'; json_quote "$IP_ADDR"; printf ',"DERPPort":%s,"STUNPort":%s,"CertName":' "$DERP_PORT" "$STUN_PORT"
  json_quote "sha256-raw:$HEALTH_LIVE_SHA256"; printf '}]}}}\n'
}

# 路径比较不创建目录；父目录物理路径和词法归一化用于识别尚不存在的输出别名。
canonical_output_path() {
  local path="$1" dir base tail='' parent
  [[ -n "$path" && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
  [[ "$path" == /* ]] || path="$PWD/$path"
  dir=$(dirname "$path"); base=$(basename "$path")
  while [[ ! -d "$dir" ]]; do
    parent=$(dirname "$dir")
    [[ "$parent" != "$dir" ]] || return 1
    tail="/$(basename "$dir")$tail"; dir=$parent
  done
  dir=$(cd -P "$dir" && pwd) || return 1
  printf '%s\n' "$dir$tail/$base" | awk -F/ '{n=0; for(i=1;i<=NF;i++){if($i==""||$i==".")continue;if($i==".."){if(n)n--}else a[++n]=$i}for(i=1;i<=n;i++)printf "/%s",a[i];print ""}'
}

health_output_paths_are_distinct() {
  local left right a b
  for left in "$HEALTH_STATE_FILE" "$METRICS_TEXTFILE"; do
    [[ -n "$left" ]] || continue
    right=$METRICS_SOURCE
    if [[ -n "$right" ]]; then
      a=$(canonical_output_path "$left") && b=$(canonical_output_path "$right") || return 1
      if [[ "$a" == "$b" || "$left" -ef "$right" ]]; then
        echo '[错误] 健康状态/指标输出不能覆盖指标输入。' >&2; return 1
      fi
    fi
  done
  if [[ -n "$HEALTH_STATE_FILE" && -n "$METRICS_TEXTFILE" ]]; then
    a=$(canonical_output_path "$HEALTH_STATE_FILE") && b=$(canonical_output_path "$METRICS_TEXTFILE") || return 1
    if [[ "$a" == "$b" || "$HEALTH_STATE_FILE" -ef "$METRICS_TEXTFILE" ]]; then
      echo '[错误] --state-file 与 --metrics-textfile 不能指向同一文件或别名。' >&2; return 1
    fi
  fi
  return 0
}

# 按原始路径逐层检查，不能先解析不可信链接再把其目标当成用户授权的路径。
health_state_parent_is_safe() {
  local file="$1" create="${2:-0}" create_mode="${3:-700}" dir rest part current=/ caller owner mode
  [[ -n "$file" && "$file" != *$'\n'* && "$file" != *$'\r'* && ! -L "$file" && ( ! -e "$file" || -f "$file" ) ]] || return 1
  [[ "$file" == /* ]] || file="$PWD/$file"
  dir=$(dirname "$file"); rest=${dir#/}
  caller=$(id -u) || return 1
  while [[ -n "$rest" ]]; do
    part=${rest%%/*}
    if [[ "$rest" == "$part" ]]; then rest=''; else rest=${rest#*/}; fi
    [[ -n "$part" && "$part" != . ]] || continue
    [[ "$part" != .. ]] || return 1
    current="${current%/}/$part"
    if [[ ! -e "$current" && ! -L "$current" ]]; then
      [[ "$create" == 1 ]] || return 1
      mkdir -m "$create_mode" "$current" || return 1
    fi
    [[ -d "$current" ]] || return 1
    [[ "$caller" != 0 || ! -L "$current" ]] || return 1
    owner=$(stat -Lc %u "$current" 2>/dev/null || stat -L -f %u "$current") || return 1
    mode=$(stat -Lc %a "$current" 2>/dev/null || stat -L -f %Lp "$current") || return 1
    [[ "$owner" == 0 || "$owner" == "$caller" ]] || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    if (( (8#$mode & 0022) != 0 )); then
      [[ "$owner" == 0 ]] && (( (8#$mode & 01000) != 0 )) || return 1
    fi
  done
  # /tmp这样的sticky目录可以是祖先，不能直接作为结果文件的父目录。
  mode=$(stat -Lc %a "$dir" 2>/dev/null || stat -L -f %Lp "$dir") || return 1
  (( (8#$mode & 0022) == 0 )) || return 1
}

health_scope_id() {
  printf '%s\000' 1 "$IP_ADDR" "$DERP_PORT" "$STUN_PORT" "$REGION_ID" "$REGION_CODE" "$REGION_NAME" "$VERIFY_CLIENTS_MODE" "${DERPER_VERIFY_CLIENTS_EFFECTIVE:-0}" "$REQUIRE_H3" "$EXTERNAL_PROBE" "$PROBE_TIMEOUT" "$PROBE_MAX_AGE" "$METRICS_SOURCE" "$METRICS_MAX_AGE" | sha256_hex
}

load_health_last_success() {
  HEALTH_LAST_SUCCESS=0
  [[ -n "$HEALTH_STATE_FILE" && -r "$HEALTH_STATE_FILE" && -f "$HEALTH_STATE_FILE" && ! -L "$HEALTH_STATE_FILE" ]] || return 0
  health_state_parent_is_safe "$HEALTH_STATE_FILE" || return 0
  local prior stored scope
  scope=$(health_scope_id) || return 0
  stored=$(sed -nE 's/^\{"schema_version":1,"scope_id":"([0-9a-f]{64})","sampled_at":[0-9]+,"last_success_at":([0-9]+),.*/\1 \2/p' "$HEALTH_STATE_FILE")
  [[ "$stored" == "$scope "* ]] || return 0
  prior=${stored#* }
  if [[ "$prior" =~ ^(0|[1-9][0-9]{0,10})$ ]] && (( prior <= SAMPLED_AT )); then HEALTH_LAST_SUCCESS=$prior; fi
}

write_health_state() {
  [[ -n "$HEALTH_STATE_FILE" ]] || return 0
  local dir tmp
  dir=$(dirname "$HEALTH_STATE_FILE")
  health_state_parent_is_safe "$HEALTH_STATE_FILE" 1 || return 1
  tmp=$(mktemp "$dir/.health.XXXXXXXX") || return 1
  if ! render_status_json >"$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$HEALTH_STATE_FILE"; then rm -f "$tmp"; return 1; fi
  [[ -f "$HEALTH_STATE_FILE" && ! -L "$HEALTH_STATE_FILE" ]] || return 1
}

port_observation_available() {
  if command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

tls_observation_available() {
  command -v openssl >/dev/null 2>&1
}

# service_verified_running 在缺 ss/netstat/openssl 时只警告并继续（BUG-027）。
# 发布门禁不能把同一种“观测工具缺失”再当成故障，把刚验证过的服务回滚掉。
# 工具齐备时的未知、已确认故障，以及 H3/指标问题，仍然阻断提交。
degraded_startup_satisfies_gate() {
  local missing=0
  port_observation_available || missing=1
  tls_observation_available || missing=1
  [[ "$missing" == 1 ]] || return 1
  [[ "$H0_STATUS" != failed && "$H1_STATUS" != failed && "$H2_STATUS" != failed && "$H3_STATUS" != failed ]] || return 1
  [[ "$H2_STATUS" == healthy || "$H2_STATUS" == not_applicable ]] || return 1
  if [[ -n "$EXTERNAL_PROBE" || "$REQUIRE_H3" == 1 ]]; then
    [[ "$H3_STATUS" == healthy ]] || return 1
  fi
  case "$METRICS_FRESHNESS" in
    stale|unknown) return 1 ;;
  esac
  [[ "${METRICS_WRITE_FAILED:-0}" == 0 && "${STATE_WRITE_FAILED:-0}" == 0 && "${HEALTH_VALIDATE_FAILED:-0}" == 0 ]] || return 1
  [[ "${DERPER_RUNNING:-0}" == 1 && "${PURE_IP_OK:-0}" == 1 && "${DESIRED_CONFIG_OK:-0}" == 1 ]] || return 1
  if port_observation_available; then
    [[ "${PORT_CHECK_UNKNOWN:-0}" == 0 && "${PORT_TLS_OK:-0}" == 1 && "${PORT_STUN_OK:-0}" == 1 && "${CURRENT_DERPER_OWNS_PORTS:-0}" == 1 ]] || return 1
  fi
  if tls_observation_available; then
    [[ "${CERT_CHECK_UNKNOWN:-0}" == 0 && "${CERT_PRESENT:-0}" == 1 && "${CERT_NAMING_OK:-0}" == 1 ]] || return 1
    [[ "${CERT_SAN_MATCH:-0}" == 1 && "${CERT_EXPIRY_OK:-0}" == 1 && "${CERT_KEY_MATCH:-1}" == 1 ]] || return 1
    if [[ "${LIVE_CERT_CHECKED:-0}" == 1 ]]; then
      [[ "${CERT_LIVE_MATCH:-0}" == 1 ]] || return 1
    fi
  fi
  return 0
}

publish_verification_gate() {
  collect_health_status >&2
  local rc
  rc=$(snapshot_exit_code)
  if [[ "$rc" == 0 ]]; then return 0; fi
  if degraded_startup_satisfies_gate; then
    echo "[警告] 缺少 ss/netstat 或 openssl，发布门禁沿用启动验证的降级结果，不回滚已通过启动验证的服务（H0=${H0_STATUS} H1=${H1_STATUS} H2=${H2_STATUS}）。" >&2
    return 0
  fi
  echo "[错误] 发布门禁未通过：H0=$H0_STATUS H1=$H1_STATUS H2=$H2_STATUS H3=${H3_STATUS}。" >&2
  return 1
}

# 健康检查摘要（适合 cron 调用）
health_is_ok() {
  [[ "${DERPER_RUNNING:-0}" -eq 1 ]] || return 1
  [[ "${PORT_TLS_OK:-0}" -eq 1 ]] || return 1
  [[ "${PORT_STUN_OK:-0}" -eq 1 ]] || return 1
  [[ "${PURE_IP_OK:-0}" -eq 1 ]] || return 1
  [[ "${DESIRED_CONFIG_OK:-0}" -eq 1 ]] || return 1
  [[ "${CERT_PRESENT:-0}" -eq 1 ]] || return 1
  [[ "${CERT_NAMING_OK:-0}" -eq 1 ]] || return 1
  [[ "${CERT_SAN_MATCH:-0}" -eq 1 ]] || return 1
  [[ "${CERT_EXPIRY_OK:-0}" -eq 1 ]] || return 1
  if [[ "${LIVE_CERT_CHECKED:-0}" -eq 1 ]]; then
    [[ "${CERT_LIVE_MATCH:-0}" -eq 1 ]] || return 1
  fi
  [[ "${CERT_KEY_MATCH:-1}" -eq 1 ]] || return 1
  [[ "${CERT_CHECK_UNKNOWN:-0}" -eq 0 ]] || return 1
  if [[ "${DERPER_VERIFY_CLIENTS_EFFECTIVE:-0}" -eq 1 ]]; then
    [[ "${TS_AUTH_UNKNOWN:-0}" -eq 0 ]] || return 1
    [[ "${TS_RUNNING:-0}" -eq 1 ]] || return 1
    [[ "${TS_LOCALAPI_OK:-0}" -eq 1 ]] || return 1
  fi
  return 0
}

# 健康检查退出码。旧 cron 丢弃退出码；`if ! --health-check` 把任意非 0 当成未通过。
# 0 健康；1 已确认故障；2 未知（无权限或无法采集）。未知不能返回 0。
health_check_exit_code() {
  if [[ "${HEALTH_SNAPSHOT_READY:-0}" == 1 ]]; then snapshot_exit_code "${1:-0}"; return 0; fi
  local validate_failed="${1:-0}" unknown="${2:-0}"
  if [[ "$unknown" -eq 1 || "${CERT_CHECK_UNKNOWN:-0}" -eq 1 || "${TS_AUTH_UNKNOWN:-0}" -eq 1 ]]; then
    printf '2\n'
    return 0
  fi
  if [[ "${METRICS_WRITE_FAILED:-0}" -eq 1 || "$validate_failed" -ne 0 ]] || ! health_is_ok; then
    printf '1\n'
    return 0
  fi
  printf '0\n'
}

cert_expiry_alarm() {
  local days="$1"
  if (( days < 0 )); then
    printf 'expired\n'
  elif (( days < 7 )); then
    printf 'warn-7\n'
  elif (( days < 30 )); then
    printf 'warn-30\n'
  elif (( days < 90 )); then
    printf 'warn-90\n'
  else
    printf 'ok\n'
  fi
}

collect_health_status() {
  HEALTH_SNAPSHOT_READY=0
  SAMPLED_AT=$(date +%s)
  HEALTH_VALIDATE_FAILED=0
  # 检查关键依赖工具
  local missing_tools=()
  command -v timeout >/dev/null 2>&1 || missing_tools+=(timeout)
  command -v openssl >/dev/null 2>&1 || missing_tools+=(openssl)
  if [[ ${#missing_tools[@]} -gt 0 ]]; then
    echo "[提示] 健康检查建议安装以下工具以获得完整功能：${missing_tools[*]}" >&2
  fi

  infer_ip_from_existing_deployment || true
  infer_healthcheck_settings_from_unit || true
  validate_settings || HEALTH_VALIDATE_FAILED=1
  check_tailscale_status
  check_derper_status
  check_cert_status
  check_live_cert_status
  HEALTH_DAYS_LEFT=$(cert_days_remaining || true)
  HEALTH_RSS_KB=0
  local pid
  pid=$(systemctl show -p MainPID --value derper 2>/dev/null || true)
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    HEALTH_RSS_KB=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{s+=$1} END {print s+0}') || HEALTH_RSS_KB=0
  fi
  derive_health_layers
  run_external_probe
  check_metrics_freshness
  load_health_last_success
  JOURNAL_STORAGE=volatile_or_unconfigured
  [[ ! -d /var/log/journal ]] || JOURNAL_STORAGE=persistent_directory_present
  HEALTH_SNAPSHOT_READY=1
}

render_health_summary_text() {
  local days_left="$1" rss_kb="${2:-0}"
  echo "[健康检查] DERP 服务健康状态摘要："
  [[ $DERPER_RUNNING -eq 1 ]] && echo "✅ 服务：derper 处于运行中" || echo "❌ 服务：derper 未在运行"
  [[ $PORT_TLS_OK -eq 1 ]] && echo "✅ 端口：TLS ${DERP_PORT}/tcp 正在监听" || echo "❌ 端口：TLS ${DERP_PORT}/tcp 未监听"
  [[ $PORT_STUN_OK -eq 1 ]] && echo "✅ 端口：STUN ${STUN_PORT}/udp 正在监听" || echo "❌ 端口：STUN ${STUN_PORT}/udp 未监听"
  [[ $PURE_IP_OK -eq 1 ]] && echo "✅ 配置：当前 unit 为纯 IP 模式" || echo "❌ 配置：当前 unit 不是纯 IP 模式"
  [[ $DESIRED_CONFIG_OK -eq 1 ]] && echo "✅ 配置：当前 unit 与本次目标参数一致" || echo "❌ 配置：当前 unit 与本次目标参数不一致，建议执行 --repair"
  if [[ "${CERT_CHECK_UNKNOWN:-0}" -eq 1 ]]; then
    echo "⚠️  证书：无权限确认，不能判断证书是否匹配或命名是否兼容"
  else
    [[ $CERT_LIVE_MATCH -eq 1 ]] && echo "✅ 证书：在线服务与磁盘证书一致" || echo "❌ 证书：在线服务未提供当前磁盘证书（或握手失败）"
    [[ ${CERT_NAMING_OK:-0} -eq 1 ]] && echo "✅ 证书：命名兼容 derper manual（<hostname>.crt/.key）" || echo "❌ 证书：命名不兼容（缺少 <IP>.crt/.key，derper 可能自签另一套）"
    if [[ "${CERT_KEY_MATCH:-1}" -eq 0 ]]; then
      echo "❌ 证书：证书与私钥不匹配，已阻止重启"
    fi
  fi
  if [[ "${DERPER_VERIFY_CLIENTS_EFFECTIVE:-0}" -eq 1 ]]; then
    if [[ "${TS_AUTH_UNKNOWN:-0}" -eq 1 ]]; then
      echo "⚠️  客户端校验：已启用，但当前身份无法确认 tailscaled LocalAPI"
    elif [[ "${TS_RUNNING:-0}" -eq 1 ]]; then
      echo "✅ 客户端校验：tailscaled 正在运行"
    else
      echo "❌ 客户端校验：已启用，但 tailscaled 未运行"
    fi
  else
    echo "ℹ️  客户端校验：当前 unit 未启用 -verify-clients"
  fi

  if [[ -n "$days_left" ]]; then
    case "$(cert_expiry_alarm "$days_left")" in
      ok) echo "✅ 证书：有效期剩余 ${days_left} 天" ;;
      warn-90) echo "⚠️  证书：有效期剩余 ${days_left} 天（90 天预警，此时不换证）" ;;
      warn-30) echo "⚠️  证书：有效期剩余 ${days_left} 天（30 天预警，此时不因预警天数换证）" ;;
      warn-7) echo "⚠️  证书：有效期剩余 ${days_left} 天（7 天预警）" ;;
      *) echo "❌ 证书：已过期（请重签）" ;;
    esac
  else
    echo "⚠️  证书：未能计算有效期（可能缺少 openssl 或证书文件）"
  fi

  # 进程内存占用（RSS）
  local rss_mb
  if [[ "$rss_kb" -gt 0 ]]; then
    rss_mb=$(( (rss_kb + 1023) / 1024 ))
    echo "ℹ️  资源：derper 内存 RSS 约 ${rss_mb} MiB"
  else
    echo "ℹ️  资源：未发现 derper 进程，略过内存统计"
  fi

  # 主机层面暴露面与自动补丁状态（只提示，不影响退出码）
  check_extra_attack_surface || true
  if [[ -n "${EXTRA_LISTENERS:-}" ]]; then
    echo "⚠️  暴露面：除 DERP 外仍有面向非回环地址的 TCP 监听（${EXTRA_LISTENERS}），建议单机单用途"
  fi
  check_automatic_updates || true
  warn_world_writable_socket "$(expected_tailscaled_socket)"
}

health_check_report() {
  METRICS_WRITE_FAILED=0; STATE_WRITE_FAILED=0
  collect_health_status >&2
  local days_left="${HEALTH_DAYS_LEFT:-}" rss_kb="${HEALTH_RSS_KB:-0}"

  if ! health_output_paths_are_distinct; then
    METRICS_WRITE_FAILED=1; STATE_WRITE_FAILED=1
    if [[ "$OUTPUT_FORMAT" == json ]]; then render_status_json; else echo '[错误] 输出路径冲突，未写入任何结果文件。' >&2; fi
    return 0
  fi

  # 导出 Prometheus 文本（可被 node_exporter textfile collector 收集）
  if [[ -n "${METRICS_TEXTFILE}" ]]; then
    if write_prometheus_metrics "${METRICS_TEXTFILE}" "$days_left" "$rss_kb"; then
      METRICS_WRITE_FAILED=0
      echo "[信息] 已写入 Prometheus 指标：${METRICS_TEXTFILE}" >&2
    else
      METRICS_WRITE_FAILED=1
      echo "[错误] Prometheus 指标写入失败：${METRICS_TEXTFILE}。旧指标文件保持不变，可按 derper_metrics_unixtime 识别为过期。" >&2
    fi
  fi
  if ! write_health_state; then STATE_WRITE_FAILED=1; echo '[错误] 健康状态持久化失败，旧文件保持。' >&2; fi
  if [[ "$DERPMAP_ONLY" == 1 ]]; then
    local map_rc=0
    render_derpmap_json || map_rc=$?
    return "$map_rc"
  elif [[ "$OUTPUT_FORMAT" == json ]]; then render_status_json
  else
    render_health_summary_text "$days_left" "$rss_kb"
    echo "[检查范围] H0=$H0_STATUS H1=$H1_STATUS H2=$H2_STATUS H3=$H3_STATUS ($H3_REASON)"
    echo "[指标新鲜度] ${METRICS_FRESHNESS}；缺少H3时未验证外部客户端中继。"
    echo "[结果入口] journalctl -u derper-healthcheck；journal=${JOURNAL_STORAGE}；状态文件=${HEALTH_STATE_FILE:-未启用}"
  fi
}

write_prometheus_metrics() {
  local path="$1" days_left="$2" rss_kb="$3"
  local dir base tmp
  dir=$(dirname "$path")
  base=$(basename "$path")
  health_state_parent_is_safe "$path" 1 755 || { METRICS_WRITE_FAILED=1; return 1; }
  if ! tmp=$(mktemp "${dir}/.${base}.tmp.XXXXXX" 2>/dev/null); then
    echo "[错误] 无法在指标目录创建安全临时文件：${dir}" >&2
    METRICS_WRITE_FAILED=1
    return 1
  fi
  local overall=0 cert_live=0
  if [[ "${HEALTH_SNAPSHOT_READY:-0}" == 1 ]]; then
    [[ "$(snapshot_exit_code "${HEALTH_VALIDATE_FAILED:-0}")" != 0 ]] || overall=1
  elif health_is_ok; then overall=1; fi
  if [[ "${LIVE_CERT_CHECKED:-0}" -eq 1 && "${CERT_LIVE_MATCH:-0}" -eq 1 ]]; then cert_live=1; fi
  if ! {
    echo "# HELP derper_up Whether derper service is up (1)"
    echo "# TYPE derper_up gauge"
    [[ $DERPER_RUNNING -eq 1 ]] && echo "derper_up 1" || echo "derper_up 0"

    echo "# HELP derper_healthy Whether all derper health checks pass (1)"
    echo "# TYPE derper_healthy gauge"
    echo "derper_healthy $overall"

    echo "# HELP derper_tls_listen TLS port listen state"
    echo "# TYPE derper_tls_listen gauge"
    [[ $PORT_TLS_OK -eq 1 ]] && echo "derper_tls_listen 1" || echo "derper_tls_listen 0"

    echo "# HELP derper_stun_listen STUN port listen state"
    echo "# TYPE derper_stun_listen gauge"
    [[ $PORT_STUN_OK -eq 1 ]] && echo "derper_stun_listen 1" || echo "derper_stun_listen 0"

    echo "# HELP derper_cert_days_remaining Days until certificate expiry"
    echo "# TYPE derper_cert_days_remaining gauge"
    if [[ -n "$days_left" ]]; then
      echo "derper_cert_days_remaining $days_left"
    else
      echo "derper_cert_days_remaining -1"
    fi

    echo "# HELP derper_verify_clients Whether verify-clients is enabled"
    echo "# TYPE derper_verify_clients gauge"
    [[ $DERPER_VERIFY_CLIENTS_EFFECTIVE -eq 1 ]] && echo "derper_verify_clients 1" || echo "derper_verify_clients 0"

    echo "# HELP derper_pure_ip_config_ok Whether pure IP mode config is detected"
    echo "# TYPE derper_pure_ip_config_ok gauge"
    [[ $PURE_IP_OK -eq 1 ]] && echo "derper_pure_ip_config_ok 1" || echo "derper_pure_ip_config_ok 0"

    echo "# HELP derper_desired_config_ok Whether deployed unit matches requested script parameters"
    echo "# TYPE derper_desired_config_ok gauge"
    [[ $DESIRED_CONFIG_OK -eq 1 ]] && echo "derper_desired_config_ok 1" || echo "derper_desired_config_ok 0"

    echo "# HELP derper_cert_live_match Whether live TLS certificate matches disk certificate (0 = mismatch or not checked)"
    echo "# TYPE derper_cert_live_match gauge"
    echo "derper_cert_live_match $cert_live"

    echo "# HELP derper_metrics_unixtime Unix time when this metrics file was written"
    echo "# TYPE derper_metrics_unixtime gauge"
    echo "derper_metrics_unixtime $(date +%s)"
    if [[ "${HEALTH_SNAPSHOT_READY:-0}" == 1 ]]; then
      echo "derper_sample_unixtime $SAMPLED_AT"
      local layer state code lower
      for layer in H0 H1 H2 H3; do
        case "$layer" in H0) state=$H0_STATUS ;; H1) state=$H1_STATUS ;; H2) state=$H2_STATUS ;; H3) state=$H3_STATUS ;; esac
        case "$state" in healthy) code=1 ;; failed) code=0 ;; unknown) code=-1 ;; not_checked) code=-2 ;; *) code=2 ;; esac
        lower=$(printf '%s' "$layer" | tr 'A-Z' 'a-z')
        echo "derper_${lower}_status $code"
      done
      echo "derper_metrics_source_age_seconds ${METRICS_AGE:--1}"
      if [[ "$overall" == 1 ]]; then echo "derper_last_success_unixtime $SAMPLED_AT"; else echo "derper_last_success_unixtime ${HEALTH_LAST_SUCCESS:-0}"; fi
    fi

    echo "# HELP derper_check_unknown Whether the health result is unknown rather than a confirmed fault"
    echo "# TYPE derper_check_unknown gauge"
    if [[ "${CERT_CHECK_UNKNOWN:-0}" -eq 1 || "${TS_AUTH_UNKNOWN:-0}" -eq 1 ]] || { [[ "${HEALTH_SNAPSHOT_READY:-0}" == 1 ]] && [[ "$(snapshot_exit_code "${HEALTH_VALIDATE_FAILED:-0}")" == 2 ]]; }; then
      echo "derper_check_unknown 1"
    else
      echo "derper_check_unknown 0"
    fi

    echo "# HELP derper_process_rss_bytes Total RSS of derper process in bytes"
    echo "# TYPE derper_process_rss_bytes gauge"
    if [[ -n "$rss_kb" ]]; then
      echo "derper_process_rss_bytes $((rss_kb*1024))"
    else
      echo "derper_process_rss_bytes 0"
    fi
  } >"$tmp"; then
    echo "[错误] Prometheus 指标写入临时文件失败：${tmp}（权限或路径问题）" >&2
    rm -f "$tmp" 2>/dev/null || true
    METRICS_WRITE_FAILED=1
    return 1
  fi
  chmod 644 "$tmp" 2>/dev/null || true
  if ! mv -f "$tmp" "$path" 2>/dev/null; then
    echo "[错误] Prometheus 指标未能替换目标文件，旧内容保持不变：$path" >&2
    rm -f "$tmp" 2>/dev/null || true
    METRICS_WRITE_FAILED=1
    return 1
  fi
}

uninstall_derper() {
  require_root
  echo "[步骤] 停止并卸载 derper systemd 服务…"
  remove_healthcheck_cron
  # 维护 unit 删除失败不能被吞掉：继续清理其余部分，但最终必须非零且不报告“完成”。
  local uninstall_rc=0
  if ! remove_cert_maintain_units; then
    echo "[错误] 维护 service/timer 未能完全删除，自动换证调度可能仍会执行。" >&2
    uninstall_rc=1
  fi
  remove_tls_connlimit

  # 在移除单元前尽力识别当前服务运行用户
  local svc_user=""
  if command -v systemctl >/dev/null 2>&1; then
    svc_user=$(systemctl cat derper 2>/dev/null | awk -F= '/^[[:space:]]*User=/{print $2}' | tail -n1 || true)
  fi
  if [[ -z "$svc_user" && -f "${SERVICE_PATH}" ]]; then
    svc_user=$(awk -F= '/^[[:space:]]*User=/{print $2}' "${SERVICE_PATH}" | tail -n1 || true)
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now derper 2>/dev/null || true
  fi
  if [[ -f "${SERVICE_PATH}" ]]; then
    rm -f "${SERVICE_PATH}"
    systemctl daemon-reload 2>/dev/null || true
  fi
  rm -rf "${SERVICE_PATH}.certs-rollback" "${SERVICE_PATH}.certs-archive" 2>/dev/null || true
  echo "[信息] 已卸载 service：${SERVICE_PATH}"

  if [[ ${PURGE} -eq 1 ]]; then
    echo "[步骤] 清理安装目录：${INSTALL_DIR} …"
    rm -rf "${INSTALL_DIR}"
    echo "[信息] 安装目录已清理。"
  fi

  if [[ ${PURGE_ALL} -eq 1 ]]; then
    purge_maintain_program || return 1
    purge_healthcheck_program || return 1
    if [[ -x "${BIN_PATH}" ]]; then
      echo "[步骤] 删除 derper 二进制：${BIN_PATH} …"
      rm -f "${BIN_PATH}" || true
    fi
    if [[ -f /etc/derper/derper.env ]]; then
      echo "[步骤] 删除 derper 环境变量文件：/etc/derper/derper.env …"
      rm -f /etc/derper/derper.env || true
      rmdir /etc/derper 2>/dev/null || true
    fi
    if [[ -f /etc/systemd/system/tailscaled.socket.d/10-derper-localapi.conf ]]; then
      echo "[步骤] 删除 tailscaled socket 覆盖配置：/etc/systemd/system/tailscaled.socket.d/10-derper-localapi.conf …"
      rm -f /etc/systemd/system/tailscaled.socket.d/10-derper-localapi.conf || true
      rmdir /etc/systemd/system/tailscaled.socket.d 2>/dev/null || true
      if command -v systemctl >/dev/null 2>&1; then
        restart_tailscaled_socket_unit || true
      fi
    fi
    # 根据已识别的服务用户给出更准确的清理提示
    if [[ -n "$svc_user" && "$svc_user" != "root" ]]; then
      echo "[提示] 检测到服务运行用户：${svc_user}。如需删除该账户，可执行："
      echo "  userdel ${svc_user}"
    else
      echo "[提示] 未能识别非 root 的服务运行用户；如需删除账户请手动确认后执行 userdel。"
    fi
    echo "[提示] 防火墙/云安全组规则可能由用户手工维护，脚本不会自动删除端口放行规则。"
  fi
  if [[ "$uninstall_rc" -ne 0 ]]; then
    echo "[错误] 卸载未完整完成：维护调度残留，请检查 derper-cert-maintain.service/timer 的文件、启用与运行状态后重试。" >&2
    return 1
  fi
  echo "完成：已卸载 derper 服务。"
}

wizard_read_choice() {
  local prompt="$1" allowed="$2" reply=""
  while true; do
    read -r -p "$prompt" reply || { echo "[中止] 输入已结束，退出向导。" >&2; return 1; }
    reply=$(printf '%s' "$reply" | tr 'A-Z' 'a-z')
    case "$reply" in
      [$allowed]) printf '%s\n' "$reply"; return 0 ;;
    esac
    echo "[错误] 无效选项，请输入 ${allowed} 中的字母。" >&2
  done
}

deployment_wizard() {
  # 非交互模式检测
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    cat >&2 <<'EOT'
[错误] 向导模式需要交互式输入，与 --non-interactive/--yes 冲突

建议：
  1) 去掉 --non-interactive 标志，正常使用向导
  2) 或者直接使用命令行参数，例如：
     sudo bash $0 --ip <IP> --dedicated-user --auto-ufw
EOT
    exit 1
  fi
  
  cat <<'EOT'
╔══════════════════════════════════════════════════════════════════════════════╗
║                      DERP 部署配置向导                                        ║
╚══════════════════════════════════════════════════════════════════════════════╝

本向导将引导您生成适合您场景的部署命令。

EOT

  local scenario="" account_pref="" port_choice="" verify_choice="" region_choice="" health_choice=""
  local execute="" user_ip="" final_confirm=""

  # 问题1：使用场景
  echo "1. 您的使用场景？"
  echo "   a) 个人测试/学习"
  echo "   b) 小团队（<10人）"
  echo "   c) 生产环境"
  scenario=$(wizard_read_choice "   请选择 (a/b/c): " "abc") || return 1
  
  # 问题2：账户偏好
  echo ""
  echo "2. 账户管理偏好？"
  echo "   a) 简单优先（使用当前账户）"
  echo "   b) 安全优先（创建专用账户）"
  account_pref=$(wizard_read_choice "   请选择 (a/b): " "ab") || return 1
  
  # 问题3：端口选择
  echo ""
  echo "3. DERP 端口？"
  echo "   a) 443（对受限网络更友好，可能与 HTTPS 服务冲突）"
  echo "   b) 30399（默认，避免与其他服务冲突）"
  echo "   也可在生成的命令中用 --derp-port 指定其他空闲 TCP 端口。"
  echo "   云安全组/主机防火墙与 derpMap 的 DERPPort 必须使用同一端口。"
  port_choice=$(wizard_read_choice "   请选择 (a/b): " "ab") || return 1
  
  # 问题4：客户端验证
  echo ""
  echo "4. 是否启用客户端验证？"
  echo "   a) 是（推荐，更安全）- 需要本地 tailscaled 已登录"
  echo "   b) 否（仅测试环境）"
  verify_choice=$(wizard_read_choice "   请选择 (a/b): " "ab") || return 1
  
  # 问题5：网络环境
  echo ""
  echo "5. 服务器是否位于中国大陆？（用于 Go 代理加速）"
  echo "   a) 是（推荐，配置 goproxy.cn）"
  echo "   b) 否（全球环境）"
  region_choice=$(wizard_read_choice "   请选择 (a/b): " "ab") || return 1

  # 问题6：周期健康检查
  echo ""
  echo "6. 是否安装每 5 分钟的本机健康检查？"
  echo "   a) 是（长期运行推荐，记录状态与 Prometheus 指标）"
  echo "   b) 否（仅人工执行检查）"
  echo "   健康检查不等于自动换证，当前没有站外通知；告警须另行配置。"
  health_choice=$(wizard_read_choice "   请选择 (a/b): " "ab") || return 1
  
  # 生成命令（使用模板替换，不用 eval）
  # 注意：每个参数必须是独立的数组元素，以便 exec 正确执行
  local cmd_parts=()
  if [[ "$(id -u)" -eq 0 ]]; then
    cmd_parts+=("bash" "$0")
  elif command -v sudo >/dev/null 2>&1; then
    cmd_parts+=("sudo" "bash" "$0")
  else
    echo "[错误] 需要 root 权限部署，且当前环境没有 sudo。请用 root 重新运行向导。" >&2
    return 1
  fi
  cmd_parts+=("--ip" "__IP_PLACEHOLDER__")
  
  # 账户策略
  case "$account_pref" in
    a) cmd_parts+=("--use-current-user") ;;
    b) cmd_parts+=("--dedicated-user") ;;
  esac
  
  # 端口
  case "$port_choice" in
    a) cmd_parts+=("--derp-port" "443") ;;
    b) cmd_parts+=("--derp-port" "30399") ;;
  esac
  
  # 客户端验证
  case "$verify_choice" in
    b) cmd_parts+=("--no-verify-clients") ;;
  esac
  
  # 安全级别
  case "$scenario" in
    a) cmd_parts+=("--security-level" "basic") ;;
    c) cmd_parts+=("--security-level" "paranoid") ;;
    # b) 使用默认 standard，不需要添加参数
  esac
  
  # 自动防火墙
  cmd_parts+=("--auto-ufw")
  [[ "$health_choice" == b ]] || cmd_parts+=("--install-healthcheck-cron")
  
  # 网络环境（代理）
  case "$region_choice" in
    a|y|Y)
      cmd_parts+=("--goproxy" "https://goproxy.cn,direct")
      cmd_parts+=("--gosumdb" "sum.golang.google.cn")
      ;;
  esac
  
  # 组装完整命令（人类可读，使用 shell 安全转义）
  local full_cmd
  if printf -v full_cmd '%q ' "${cmd_parts[@]}" 2>/dev/null; then
    full_cmd=${full_cmd% }  # 去掉末尾空格
  else
    full_cmd="${cmd_parts[*]}"
  fi
  
  cat <<EOT

╔══════════════════════════════════════════════════════════════════════════════╗
║                      推荐的部署命令                                           ║
╚══════════════════════════════════════════════════════════════════════════════╝

$full_cmd

提示：
- 请将 __IP_PLACEHOLDER__ 替换为您的实际公网 IP
- --derp-port 可更换为其他空闲 TCP 端口；同步云安全组/主机防火墙和 derpMap 的 DERPPort
- 命令已保存到 derper_deploy_cmd.sh，方便后续使用

是否立即执行？(y/n)
EOT
  
  # 保存到当前工作目录（用户需要在 EXIT 清理后仍能访问此文件）
  echo "$full_cmd" > derper_deploy_cmd.sh
  chmod +x derper_deploy_cmd.sh
  
  read -r -p "> " execute || { echo "[中止] 输入已结束，命令已保存到 derper_deploy_cmd.sh。" >&2; return 1; }
  if [[ "$execute" == "y" || "$execute" == "Y" ]]; then
    echo ""
    read -r -p "请输入您的公网 IP: " user_ip || { echo "[中止] 输入已结束。" >&2; return 1; }
    
    # 严格验证 IPv4 格式
    if [[ ! "$user_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "[错误] IP 格式不正确，请手动修改 derper_deploy_cmd.sh 后执行" >&2
      exit 1
    fi
    
    # 验证每个字段范围（0-255）
    IFS='.' read -ra octets <<< "$user_ip"
    for octet in "${octets[@]}"; do
      # 去除前导零避免 bash 八进制解析（10#强制十进制）
      local octet_dec=$((10#$octet))
      if (( octet_dec < 0 || octet_dec > 255 )); then
        echo "[错误] IP 地址字段超出范围（0-255），请重新输入" >&2
        exit 1
      fi
    done
    
    # 构建安全的参数数组（避免 eval）
    local exec_args=()
    for part in "${cmd_parts[@]}"; do
      if [[ "$part" == *"__IP_PLACEHOLDER__"* ]]; then
        exec_args+=("${part//__IP_PLACEHOLDER__/$user_ip}")
      else
        exec_args+=("$part")
      fi
    done
    
    echo ""
    echo "[信息] 即将执行："
    local preview
    if printf -v preview '%q ' "${exec_args[@]}" 2>/dev/null; then
      preview=${preview% }
      echo "  $preview"
    else
      echo "  ${exec_args[*]}"
    fi
    echo ""
    read -r -p "确认执行？(yes/no): " final_confirm || { echo "[中止] 输入已结束。" >&2; return 1; }
    
    if [[ "$final_confirm" == "yes" ]]; then
      # exec 会替换当前进程，EXIT trap 不会运行；先丢掉临时目录避免泄漏
      release_tmpdir
      exec "${exec_args[@]}"
    else
      echo "[信息] 已取消执行，命令已保存到 derper_deploy_cmd.sh"
    fi
  else
    echo "[信息] 命令已保存到 derper_deploy_cmd.sh"
    echo "       手动执行前请替换 __IP_PLACEHOLDER__ 为实际 IP"
  fi
}

service_needs_reconcile() {
  local artifacts_changed="${1:-0}"
  [[ "${DERPER_SERVICE_PRESENT:-0}" -ne 1 ]] ||
    [[ "${DESIRED_CONFIG_OK:-0}" -ne 1 ]] ||
    [[ "${DERPER_RUNNING:-0}" -ne 1 ]] ||
    [[ "${PORT_TLS_OK:-0}" -ne 1 ]] ||
    [[ "${PORT_STUN_OK:-0}" -ne 1 ]] ||
    [[ "$artifacts_changed" -eq 1 ]] ||
    # 在线证书与磁盘证书不一致（如外部替换了磁盘证书但 derper 未重启）→ 需重启加载
    { [[ "${LIVE_CERT_CHECKED:-0}" -eq 1 ]] && [[ "${CERT_LIVE_MATCH:-0}" -ne 1 ]]; }
}

# 丢掉部署临时目录。exec 替换进程时 EXIT trap 不会运行，向导在 exec 前必须调用。
release_tmpdir() {
  if [[ -n "${_tmpdir:-}" && -d "${_tmpdir}" ]]; then
    chmod -R u+w "${_tmpdir}" 2>/dev/null || true
    rm -rf "${_tmpdir}"
  fi
  trap - EXIT
  _tmpdir=""
}

# 显式参数优先；未指定时保留已部署身份，首次非交互 root 部署才选专用用户。
resolve_run_user() {
  local deployed_user=""
  deployed_user=$(read_derper_unit_content | awk -F= '/^[[:space:]]*User=/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' || true)
  DEPLOYED_RUN_USER="$deployed_user"
  [[ "${RUN_USER_EXPLICIT:-0}" -eq 0 ]] || return 0
  if [[ -n "$deployed_user" ]]; then
    RUN_USER="$deployed_user"
  elif [[ "$(id -u)" -eq 0 && -z "${SUDO_USER:-}" && "${NON_INTERACTIVE}" -eq 1 && "$RUN_USER" == root ]]; then
    RUN_USER=derper
    CREATE_DEDICATED_USER=1
    USE_CURRENT_USER=0
  fi
}

verify_restored_service() (
  local content
  content=$(read_derper_unit_content)
  IP_ADDR=$(printf '%s\n' "$content" | sed -nE 's/.*-hostname[[:space:]]+([^[:space:]]+).*/\1/p' | head -n1)
  DERP_PORT=$(printf '%s\n' "$content" | sed -nE 's/.*(-a[[:space:]]+:|-https-port[[:space:]]+)([0-9]+).*/\2/p' | head -n1)
  STUN_PORT=$(printf '%s\n' "$content" | sed -nE 's/.*-stun-port[[:space:]]+([0-9]+).*/\1/p' | head -n1)
  STUN_PORT="${STUN_PORT:-3478}"
  [[ -n "$IP_ADDR" && -n "$DERP_PORT" ]] || return 1
  service_verified_running
)

recover_cert_update() {
  rollback_cert_update || return 1
  if [[ "${CERT_ROLLBACK_OCCURRED:-0}" -eq 1 && "${CERT_ROLLBACK_WAS_RUNNING:-0}" -eq 1 ]]; then
    if [[ ! -f "${SERVICE_PATH}" ]]; then
      echo "[警告] 已恢复证书，但 derper unit 已不存在，跳过服务重启。" >&2
      return 0
    fi
    if ! systemctl restart derper || ! verify_restored_service; then
      echo "[警告] 旧证书已恢复，但原服务未通过重启验证，请检查 derper。" >&2
      return 0
    fi
  fi
}

cleanup_deployment() {
  local rc="$1"
  restore_relaxed_socket_perms || true
  if [[ "$rc" -ne 0 && "${CERT_TRANSACTION_ACTIVE:-0}" -eq 1 ]]; then
    recover_cert_update || echo "[错误] 证书或服务恢复失败，请检查 ${SERVICE_PATH}.certs-rollback 和服务日志。" >&2
  fi
  if [[ -n "${_tmpdir:-}" ]]; then
    # Go 模块缓存目录是只读的，直接 rm -rf 会留下残骸；先恢复写权限。
    chmod -R u+w "$_tmpdir" 2>/dev/null || true
    rm -rf "$_tmpdir" || echo "[警告] 无法完全清理临时目录：${_tmpdir}" >&2
  fi
}

main() {
  # 工具链下载与事务文件使用磁盘上的安全临时目录，避免小内存 tmpfs。
  _tmpdir=$(mktemp -d /var/tmp/derper-deploy.XXXXXXXXXX)
  trap 'cleanup_deployment $?' EXIT

  # 特殊子命令处理：先记录 wizard，再解析其后的通用参数。
  local wizard_mode=0
  if [[ "${1:-}" == "wizard" ]]; then
    wizard_mode=1
    shift
  fi
  
  parse_args "$@" || exit 1

  # 参数组合校验：--purge 需配合 --uninstall、--metrics-textfile 需配合 --health-check、
  # --force/--repair/--uninstall/--check 等互斥组合直接报错，避免静默取分支或选项被忽略。
  if ! validate_arg_combos; then
    echo "[错误] 参数组合不合法，请检查选项组合。" >&2
    exit 1
  fi

  # 明确缺少探针的变更在取锁/切换前拒绝；健康查询仍输出unknown及缺失原因。
  if [[ "$wizard_mode" == 0 && "$HEALTH_CHECK$CHECK_ONLY$CERT_PREPARE$CERT_APPLY$CERT_CANCEL$CERT_MAINTAIN" == 000000 && "$UNINSTALL$RECOVER_INTERRUPTED" == 00 ]]; then
    if [[ "$REQUIRE_H3" == 1 && -z "$EXTERNAL_PROBE" ]]; then echo '[错误] 请求H3发布门禁但未配置外部合法客户端探针，未开始变更。' >&2; exit 1; fi
    if [[ -n "$EXTERNAL_PROBE" ]] && { ! probe_path_is_trusted "$EXTERNAL_PROBE" || ! command -v timeout >/dev/null 2>&1; }; then echo '[错误] 外部探针路径或超时工具未就绪，未开始变更。' >&2; exit 1; fi
  fi

  if [[ "${wizard_mode}" -eq 1 ]]; then
    deployment_wizard
    exit 0
  fi

  resolve_run_user
  if [[ -z "${NODE_STATE_DIR:-}" ]]; then
    NODE_STATE_DIR=/var/lib/derper
  fi

  if [[ "${RECOVER_INTERRUPTED}" -eq 1 ]]; then
    require_root
    acquire_deploy_lock || exit 1
    recover_interrupted_change || exit 1
    exit 0
  fi
  if [[ "${CHECK_ONLY}" -ne 1 && "${HEALTH_CHECK}" -ne 1 ]]; then
    ordinary_change_allowed || exit 1
    acquire_deploy_lock || exit 1
  fi

  # 环境检测（优先级最高，除了 --help 和 --uninstall）
  if [[ "${UNINSTALL}" -eq 1 ]]; then
    # 卸载优先处理：不依赖环境检测/公网 IP 探测/参数校验
    uninstall_derper || exit 1
    exit 0
  fi
  
  # 检查操作系统和运行环境（Linux only）
  if [[ "$OUTPUT_FORMAT" == json || "$DERPMAP_ONLY" == 1 ]]; then check_os_environment >&2; else check_os_environment; fi

  if [[ "$CHECK_ONLY" -ne 1 && "$DRY_RUN" -ne 1 && "$HEALTH_CHECK" -ne 1 ]]; then
    require_root
    recover_cert_update || return 1
  fi

  # 探测 IP 与校验参数（即使非 root 也可做检查）
  # --health-check（cron）：不打外网，优先从已部署 unit 推断 IP
  # --check/--dry-run：IP 探测可容错；但参数校验失败时最终必须非 0 退出
  local check_validate_failed=0
  if [[ "${HEALTH_CHECK}" -eq 1 ]]; then
    # 机器可读模式下 stdout 只能是 JSON；推断提示与环境检测一样改走 stderr。
    if [[ "$OUTPUT_FORMAT" == json || "$DERPMAP_ONLY" == 1 ]]; then
      infer_ip_from_existing_deployment >&2 || true
      infer_healthcheck_settings_from_unit >&2 || true
    else
      infer_ip_from_existing_deployment || true
      infer_healthcheck_settings_from_unit || true
    fi
  else
    detect_public_ip || true
  fi
  if ! validate_settings; then
    check_validate_failed=1
    if [[ "${CERT_CANCEL}" -eq 1 ]]; then
      echo "[信息] cancel 只丢弃候选证书，不依赖公网 IP 校验。" >&2
    elif [[ "${DRY_RUN}" -ne 1 && "${CHECK_ONLY}" -ne 1 && "${HEALTH_CHECK}" -ne 1 ]]; then
      echo "[错误] 参数校验失败，请检查 IP、端口等配置" >&2
      exit 1
    else
      echo "[警告] 参数校验失败；检查模式将继续输出状态，但最终退出码为失败。" >&2
    fi
  fi

  if [[ "$HEALTH_CHECK" -ne 1 && "$CERT_PREPARE$CERT_APPLY$CERT_CANCEL$CERT_MAINTAIN" == 0000 ]]; then
    local region_check_rc=0
    precheck_region_id_conflict || region_check_rc=$?
    if [[ "$region_check_rc" -eq 1 ]]; then
      if [[ "${DRY_RUN}" -eq 1 || "${CHECK_ONLY}" -eq 1 ]]; then
        check_validate_failed=1
      else
        exit 1
      fi
    fi
  fi

  if [[ "$CERT_PREPARE$CERT_APPLY$CERT_CANCEL$CERT_MAINTAIN" != 0000 ]]; then
    # 停用维护本身就是本次 maintain 的操作：先持久化并移除调度，不再运行换证。
    if [[ "$CERT_MAINTAIN" -eq 1 && "${DISABLE_AUTO_MAINTAIN:-0}" -eq 1 ]]; then
      apply_auto_maintain_policy || exit 1
      exit 0
    fi
    run_d_stage_command || exit 1
    if [[ "$CERT_CANCEL" -eq 1 ]]; then
      exit 0
    fi
    if [[ "${ENABLE_AUTO_MAINTAIN:-0}" -eq 1 || "${DISABLE_AUTO_MAINTAIN:-0}" -eq 1 ]]; then
      apply_auto_maintain_policy || exit 1
    fi
    if [[ "$CERT_MAINTAIN" -ne 1 ]]; then
      print_auto_maintain_feedback "$(evaluate_auto_maintain_readiness)"
    fi
    exit 0
  fi

  # 健康检查模式（仅输出状态/指标，不变更系统；单次采集）
  if [[ "${HEALTH_CHECK}" -eq 1 ]]; then
    local report_rc=0
    health_check_report || report_rc=$?
    # derpmap 身份未知返回 2、确认失败返回 1；不要把这两种都折成 1。
    if [[ "$report_rc" -ne 0 ]]; then exit "$report_rc"; fi
    # 0 健康，1 已确认故障，2 未知。旧调用把任意非 0 视为未通过。
    exit "$(health_check_exit_code "$check_validate_failed")"
  fi

  # 收集当前状态
  check_tailscale_status
  check_derper_status
  check_cert_status
  check_live_cert_status

  if [[ "${DRY_RUN}" -eq 1 || "${CHECK_ONLY}" -eq 1 ]]; then
    local ip_show="<未探测到>"
    [[ -n "${IP_ADDR}" ]] && ip_show="${IP_ADDR}"
    echo "[检查] 参数与环境状态总结："
    echo "- 公网 IP：${ip_show}"
    echo "- DERP 端口：${DERP_PORT}/tcp；STUN 端口：${STUN_PORT}/udp"
    local region_check_text="未知"
    case "${region_check_rc:-0}" in
      0) region_check_text="未发现冲突或为同一目标" ;;
      1) region_check_text="确认冲突" ;;
    esac
    echo "- Region ${REGION_ID} 预检：${region_check_text}"
    echo "- tailscale：安装=${TS_INSTALLED} 运行=${TS_RUNNING} 版本=${TS_VERSION:-<未知>} (>=${REQUIRED_TS_VER}) 满足=${TS_VER_OK}"
    echo "- derper：二进制=${DERPER_BIN} 服务文件=${DERPER_SERVICE_PRESENT} 运行=${DERPER_RUNNING}"
    local derper_installed_ver=""
    derper_installed_ver=$(get_installed_derper_version 2>/dev/null || true)
    echo "- derper 版本：已安装=${derper_installed_ver:-<未知>} 目标=${DERPER_VERSION}"
    echo "- 端口监听：TLS=${PORT_TLS_OK} STUN=${PORT_STUN_OK}"
    echo "- 纯 IP 配置判定（基于 unit）：${PURE_IP_OK}"
    echo "- 目标配置匹配（基于 unit）：${DESIRED_CONFIG_OK}"
    echo "- 证书：存在=${CERT_PRESENT} 命名兼容=${CERT_NAMING_OK:-0} SAN匹配IP=${CERT_SAN_MATCH} 30天内不过期=${CERT_EXPIRY_OK}"
    local layout_ok=0
    cert_layout_is_ok && layout_ok=1
    echo "- 证书权限/兼容链接/事务完整：${layout_ok}"
    echo "- 客户端校验模式：目标=${VERIFY_CLIENTS_MODE} 已部署=${DERPER_VERIFY_CLIENTS_EFFECTIVE}"
    # 展示将要使用的运行用户与组（若用户尚未创建则组名以用户名代替）
    local chk_group
    chk_group=$(id -g -n "$RUN_USER" 2>/dev/null || echo "$RUN_USER")
    echo "- 运行用户：目标=${RUN_USER}（组：${chk_group}） 已部署=${DEPLOYED_RUN_USER:-<无>}"

    local suggest="--repair"
    if [[ "$check_validate_failed" -eq 0 ]] && health_is_ok && cert_layout_is_ok; then
      suggest="<已就绪：可直接跳过>"
    elif [[ $DERPER_BIN -eq 0 ]]; then
      suggest="安装 derper（缺少二进制）"
    fi
    echo "- 建议：${suggest}"

    echo "- 关键可执行检查："
    for bin in curl openssl git go tailscale; do
      if command -v "$bin" >/dev/null 2>&1; then
        echo "  * $bin: $(command -v "$bin")"
      else
        echo "  * $bin: 未找到（正式安装时将尝试通过包管理器或 go 安装）"
      fi
    done
    if command -v systemctl >/dev/null 2>&1; then
      echo "- 服务管理器：systemd 可用"
    else
      echo "- 服务管理器：未检测到 systemd（将无法写入 systemd 服务，请改用手动或其他服务管理器）"
    fi

    echo "- 主机加固状态："
    check_extra_attack_surface || true
    if [[ -n "${EXTRA_LISTENERS:-}" ]]; then
      echo "  * 暴露面：除 DERP 外仍有非回环 TCP 监听：${EXTRA_LISTENERS}（建议单机单用途）"
    else
      echo "  * 暴露面：未发现除 DERP 端口外的非回环 TCP 监听"
    fi
    check_automatic_updates || true

    echo "[检查结束] 使用 --repair 修复配置，或 --force 全量重装；若一切就绪可直接跳过。"
    if [[ "$check_validate_failed" -eq 1 ]]; then
      return 1
    fi
    return 0
  fi

  # 正式执行需要 root
  require_root

  # 进入安装/修复分支前，强制校验参数（不容错）
  echo "[步骤] 强制校验参数..."
  if ! detect_public_ip; then
    echo "[错误] 无法探测或验证公网 IP，请使用 --ip 显式指定" >&2
    exit 1
  fi
  if ! validate_settings; then
    echo "[错误] 参数校验失败，请检查 IP、端口等配置" >&2
    exit 1
  fi

  # 默认启用 verify-clients 并在未登录时阻断
  precheck_verify_clients
  # verify-clients 启用时，将 derper 版本对齐到本机 tailscale 版本（同源构建）
  align_derper_version_with_tailscale

  # 对齐后若目标版本与已安装二进制不一致，必须重装（无需额外 --force）
  local need_derper_install=0
  if derper_binary_needs_install; then
    need_derper_install=1
  fi

  if [[ "${FORCE}" -eq 1 ]]; then
    ensure_deploy_dependencies || exit 1
    # Bash 3.2 不会因函数内 `|| return` 触发调用方 set -e，导入失败必须显式退出。
    install_derper || exit 1
    generate_selfsigned_cert
    check_port_conflicts
    write_systemd_service
    print_firewall_tips
    runtime_checks
    commit_cert_update || exit 1
    run_post_deploy_extras || exit 1
  elif [[ "${REPAIR}" -eq 1 ]]; then
    ensure_deploy_dependencies || exit 1
    if [[ "$need_derper_install" -eq 1 ]]; then
      install_derper || exit 1
    fi
    ensure_compatible_certs || exit 1
    check_port_conflicts
    write_systemd_service
    print_firewall_tips
    runtime_checks
    commit_cert_update || exit 1
    run_post_deploy_extras || exit 1
  else
    # 默认幂等：按需修复
    local changed=0
    local service_reload_needed=0
    if [[ "$need_derper_install" -eq 1 || $DERPER_BIN -ne 1 ]]; then
      ensure_deploy_dependencies || exit 1
      install_derper || exit 1
      changed=1
      service_reload_needed=1
    fi
    ensure_compatible_certs || exit 1
    if [[ ${CERTS_CHANGED:-0} -eq 1 ]]; then
      changed=1
      service_reload_needed=1
    fi
    if service_needs_reconcile "$service_reload_needed"; then
      check_port_conflicts
      write_systemd_service; changed=1
    fi
    if [[ $changed -eq 0 ]] && health_is_ok; then
      publish_verification_gate || exit 1
      echo "✅ 已就绪：检测到 derper 正在以纯 IP 模式运行，跳过安装。"
      commit_cert_update || exit 1
      run_post_deploy_extras || exit 1
      finish_deploy_auto_maintain || exit 1
      exit 0
    fi
    if [[ $changed -eq 0 ]]; then
      # 未改动但 health_is_ok 失败（如 LocalAPI 明确故障）：不能跳过门禁后继续成功收尾。
      publish_verification_gate || exit 1
    fi
    print_firewall_tips
    runtime_checks
    commit_cert_update || exit 1
    run_post_deploy_extras || exit 1
  fi

  finalize_deployment_report || exit 1
}

# 部署收尾：输出基于 CertName 的安全 derpMap 与验证步骤。
# 若无法取得证书指纹，宁可失败并要求排查 TLS，也不输出 InsecureForTests 配置：
# 上游明确说明该字段仅用于单元测试，用户不应在生产配置中设置。
finalize_deployment_report() {
  local FP fp_source=在线TLS
  FP=$(live_cert_sha256_raw || true)
  if [[ -z "$FP" ]]; then FP=$(journal_certname_raw || true); fp_source=服务日志; fi
  if [[ -z "$FP" ]]; then FP=$(cert_file_sha256_raw || true); fp_source=磁盘证书; fi
  if [[ -n "$FP" ]]; then
    print_acl_snippet_cert "${IP_ADDR}" "${DERP_PORT}" "$FP"
    echo "[信息] 片段指纹来源：${fp_source}；CertName=sha256-raw:${FP}。公网与客户端传播须另行确认。"
    print_client_verify_steps
    local DEPLOY_CLIENT_GUIDANCE_PRINTED=1
    print_server_node_acl_advice
    warn_world_writable_socket "$(expected_tailscaled_socket)"
    local cert_expiry cert_days cert_expiry_text
    cert_expiry=$(cert_not_after || true)
    cert_days=$(cert_days_remaining || true)
    cert_expiry_text="${cert_expiry:-无法确认}"
    [[ -z "$cert_expiry" || ! "$cert_days" =~ ^-?[0-9]+$ ]] || cert_expiry_text+="（剩余 ${cert_days} 天）"

    local health_timer=未安装 health_cron=未发现
    if command -v systemctl >/dev/null 2>&1 && systemctl cat derper-healthcheck.timer >/dev/null 2>&1; then
      health_timer=$(systemctl is-active derper-healthcheck.timer 2>/dev/null || true)
    fi
    [[ -f /etc/cron.d/derper-healthcheck ]] && health_cron=文件存在
    cat <<INFO
完成：本机部署步骤完成；公网可达、策略下发和实际中继须分别确认。
- 本次目标：${IP_ADDR}；TCP ${DERP_PORT} / UDP ${STUN_PORT}；Region ${REGION_ID} / ${REGION_CODE} / ${REGION_NAME}
- 客户端校验：verify-clients=${VERIFY_CLIENTS_MODE}；运行用户：${RUN_USER}；加固：${SECURITY_LEVEL}
- 本地门禁：H0=${H0_STATUS:-unknown} H1=${H1_STATUS:-unknown} H2=${H2_STATUS:-unknown} H3=${H3_STATUS:-not_checked}
- 健康检查调度：timer=${health_timer:-unknown}；cron=${health_cron}（文件存在不证明 cron 正在执行）
- 服务：systemctl status derper
- 日志：journalctl -u derper -f
- 证书：$(derper_manual_cert_file) / $(derper_manual_key_file)（上游 derper manual 模式读取；兼容链接 fullchain.pem/privkey.pem）
- 证书到期：${cert_expiry_text}；过期后本节点 TLS 校验失败，客户端可能回落其他 DERP
- 维护：人工续期入口 prepare/apply；周期检查与自动换证须分别显式启用，当前没有站外通知
- 配置：$(derper_config_path)

下一步：合并本节点片段并保留现有策略，读取客户端实际 derpMap 确认下发，再验证公网 TLS/STUN 与指定 Region 中继。
上游服务日志的示例 Region 不是配置依据；请使用本次目标 ${REGION_ID}。
INFO
    finish_deploy_auto_maintain || return 1
    return 0
  fi

  cat >&2 <<EOT
[错误] 部署步骤已执行，但无法获取证书指纹，无法生成基于 CertName 的安全 derpMap。

为安全起见，脚本不会输出 InsecureForTests 配置：
上游明确说明该字段仅用于单元测试，用户不应设置（设置后将关闭 TLS 证书校验，
无法验证服务身份并有中间人风险，并非关闭 TLS 加密，参考 https://github.com/tailscale/tailscale/blob/main/tailcfg/derpmap.go）。

请先排查 TLS 后再重试：
  1) systemctl status derper && journalctl -u derper -n 100（确认服务与端口）
  2) ss -tlnp | grep ${DERP_PORT}（确认 DERP TLS 端口在监听）
  3) openssl s_client -connect ${IP_ADDR}:${DERP_PORT} -servername ${IP_ADDR} -showcerts（确认握手与证书）
  4) 确认本机已安装 openssl（脚本依赖它计算指纹）

修复后重新运行本脚本（幂等），即可生成安全 derpMap 片段。
EOT
  return 1
}

if [[ "${DERPER_TEST_MODE:-0}" != "1" ]]; then
  main "$@"
fi
