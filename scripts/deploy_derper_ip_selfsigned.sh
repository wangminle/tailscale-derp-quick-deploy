#!/usr/bin/env bash

# 说明：
#  - 面向“仅有公网 IP、无需域名”的轻量 DERP 部署；生成“基于 IP 的自签证书”。
#  - 适合测试/临时/小规模使用；生产建议配合受信任 CA 证书与 443 端口。
#  - 脚本会：安装依赖 -> 安装/构建 derper -> 生成证书 -> 写入 systemd -> 防火墙提示 -> 自检 -> 输出 ACL 片段。
#  - 兼容新版 derper（使用 -a :PORT），旧版则回退到 -https-port；默认启用 -verify-clients。

set -euo pipefail

# 默认端口
DERP_PORT="30399"        # DERP TLS 端口
STUN_PORT="3478"         # STUN 端口（UDP）
CERT_DAYS="365"          # 自签证书有效期（天）
INSTALL_DIR="/opt/derper" # 安装/证书目录
BIN_PATH="/usr/local/bin/derper"
SERVICE_PATH="/etc/systemd/system/derper.service"

# 版本门槛（可通过环境变量覆盖）
REQUIRED_TS_VER="${REQUIRED_TS_VER:-1.66.3}"

# 可选：Go 模块代理 / 校验数据库 / 工具链策略
GOPROXY_ARG=""                 # 例：https://goproxy.cn,direct
GOSUMDB_ARG=""                 # 例：sum.golang.google.cn
GOTOOLCHAIN_ARG="auto"         # auto|local（默认 auto 以满足 >=1.25）

# 客户端校验：on=强制启用；off=禁用（默认 on）
VERIFY_CLIENTS_MODE="on"

# ACL Region 配置（可自定义）
REGION_ID="900"
REGION_CODE="my-derp"
REGION_NAME="My IP DERP"

# 运行用户配置（可自定义）
RUN_USER="${SUDO_USER:-$USER}"  # 默认使用当前用户（个人环境友好）
USE_CURRENT_USER=1       # 默认使用当前用户
CREATE_DEDICATED_USER=0  # 是否强制创建专用用户
RELAX_SOCKET_PERMS=0     # 是否允许放宽 socket 权限（不推荐）
NON_INTERACTIVE=0        # 非交互模式（CI/自动化）
SECURITY_LEVEL="standard" # 安全加固级别：basic|standard|paranoid

IP_ADDR=""
AUTO_UFW=0               # 是否自动放行 UFW
DRY_RUN=0                # 只做检查，不执行安装/写入
FORCE=0                  # 强制全量重装
REPAIR=0                 # 仅修复配置（不重装 derper）
CHECK_ONLY=0             # --check 别名（等价于 --dry-run）

# 新增：健康检查 / 卸载 / 指标导出
HEALTH_CHECK=0           # 输出健康检查结果（便于 cron 监控）
UNINSTALL=0              # 停止并卸载 systemd 单元
PURGE=0                  # 与 --uninstall 一起使用：清理安装目录（证书等）
PURGE_ALL=0              # 与 --uninstall 一起使用：清理安装目录与二进制
METRICS_TEXTFILE=""      # 将健康检查指标写为 Prometheus textfile（供 node_exporter 收集）

usage() {
  cat <<EOF
用法：sudo bash $0 [选项]
或者：sudo bash $0 wizard  (启动交互式配置向导)

选项列表：
用法（向导模式）：sudo bash $0 wizard  [启动交互式配置向导]
用法（命令模式）：sudo bash $0 [--ip 公网IP] [--derp-port 30399] [--stun-port 3478] [--cert-days 365] [--auto-ufw]
               [--goproxy URL] [--gosumdb VALUE] [--gotoolchain auto|local]
               [--no-verify-clients | --force-verify-clients]
               [--region-id 900] [--region-code my-derp] [--region-name "My IP DERP"]
               [--user <username> | --use-current-user]
               [--check | --dry-run] [--repair] [--force]
               [--health-check [--metrics-textfile 路径]]
               [--uninstall [--purge | --purge-all]]

参数说明：
  --ip                    服务器公网 IPv4（推荐显式指定），缺省自动探测。
  --derp-port             DERP TLS 端口，默认 30399/TCP。
  --stun-port             STUN 端口，默认 3478/UDP。
  --cert-days             自签临时证书有效期（天），默认 365。
  --auto-ufw              若检测到 UFW，自动放行端口规则。
  --goproxy URL           设置 GOPROXY，例如 https://goproxy.cn,direct（默认继承环境）。
  --gosumdb VALUE         设置 GOSUMDB，例如 sum.golang.google.cn（默认继承环境）。
  --gotoolchain MODE      go 工具链策略，默认 auto 以便自动获取 >=1.25 的工具链。
  --no-verify-clients     不验证客户端身份（仅测试，默认并不推荐）。
  --force-verify-clients  强制启用客户端校验（默认行为）。
  --region-id             ACL derpMap 的 RegionID（默认 900）。
  --region-code           ACL derpMap 的 RegionCode（默认 my-derp）。
  --region-name           ACL derpMap 的 RegionName（默认 "My IP DERP"）。
  --user <username>       指定运行 derper 的用户（默认：当前登录用户）。
                          可指定现有用户（如 nobody、www-data 等）。
  --use-current-user      使用当前登录用户运行 derper（等价于 --user \$USER，默认行为）。
  --dedicated-user        强制创建专用 derper 系统账户（生产环境推荐）。
  --security-level LEVEL  安全加固级别：basic|standard|paranoid（默认 standard）。
  --relax-socket-perms    允许临时放宽 tailscaled socket 权限到 0666（不推荐，仅紧急情况）。
  --yes, --non-interactive 非交互模式，自动确认所有选择（适合 CI/自动化脚本）。
  --check, --dry-run      仅进行状态与参数检查，不执行安装/写服务/放行端口等操作。
  --repair                仅修复/重写配置（systemd/证书等），不中断可用的依赖；不重装 derper。
  --force                 强制全量重装（重新安装 derper、重签证书、重写服务）。

  --health-check          输出健康检查摘要（适合 cron 周期探测；不更改系统）。
  --metrics-textfile P    将健康检查结果以 Prometheus 文本格式写入到文件 P。
                          建议结合 node_exporter 的 textfile collector 使用。
  --uninstall             停止并卸载 derper systemd 服务（保留二进制与证书）。
  --purge                 与 --uninstall 配合：额外删除 ${INSTALL_DIR}（证书等）。
  --purge-all             与 --uninstall 配合：在 --purge 基础上，同时删除 ${BIN_PATH}。

示例：
  sudo bash $0 --ip 203.0.113.10 --derp-port 30399 --auto-ufw \
    --goproxy https://goproxy.cn,direct --gosumdb sum.golang.google.cn

   # 仅健康检查 + 导出 Prometheus 文本（可配合 cron）
   sudo bash $0 --ip 203.0.113.10 --health-check --metrics-textfile /var/lib/node_exporter/textfile_collector/derper.prom

   # 一键卸载服务并清理安装目录
   sudo bash $0 --uninstall --purge
EOF
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
    derper -hostname 127.0.0.1 -certmode manual -certdir ./certs \
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
    derper -hostname 127.0.0.1 -certmode manual -certdir ./certs \
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
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ip)
        IP_ADDR=${2:-}
        shift 2;;
      --derp-port)
        DERP_PORT=${2:-}
        shift 2;;
      --stun-port)
        STUN_PORT=${2:-}
        shift 2;;
      --cert-days)
        CERT_DAYS=${2:-}
        shift 2;;
      --auto-ufw)
        AUTO_UFW=1
        shift 1;;
      --goproxy)
        GOPROXY_ARG=${2:-}
        shift 2;;
      --gosumdb)
        GOSUMDB_ARG=${2:-}
        shift 2;;
      --gotoolchain)
        GOTOOLCHAIN_ARG=${2:-auto}
        shift 2;;
      --no-verify-clients)
        VERIFY_CLIENTS_MODE="off"
        shift 1;;
      --force-verify-clients)
        VERIFY_CLIENTS_MODE="on"
        shift 1;;
      --region-id)
        REGION_ID=${2:-}
        shift 2;;
      --region-code)
        REGION_CODE=${2:-}
        shift 2;;
      --region-name)
        REGION_NAME=${2:-}
        shift 2;;
      --user)
        RUN_USER=${2:-}
        shift 2;;
      --use-current-user)
        USE_CURRENT_USER=1
        CREATE_DEDICATED_USER=0
        RUN_USER="${SUDO_USER:-$USER}"
        shift 1;;
      --dedicated-user)
        CREATE_DEDICATED_USER=1
        USE_CURRENT_USER=0
        RUN_USER="derper"
        shift 1;;
      --security-level)
        SECURITY_LEVEL=${2:-standard}
        shift 2;;
      --relax-socket-perms)
        RELAX_SOCKET_PERMS=1
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
      --health-check)
        HEALTH_CHECK=1
        shift 1;;
      --metrics-textfile)
        METRICS_TEXTFILE=${2:-}
        shift 2;;
      --uninstall)
        UNINSTALL=1
        shift 1;;
      --purge)
        PURGE=1
        shift 1;;
      --purge-all)
        PURGE_ALL=1; PURGE=1
        shift 1;;
      -h|--help)
        usage; exit 0;;
      *)
        echo "未知参数：$1" >&2; usage; exit 1;;
    esac
  done
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

validate_settings() {
  # 端口合法性
  if ! [[ "${DERP_PORT}" =~ ^[0-9]+$ ]] || (( DERP_PORT < 1 || DERP_PORT > 65535 )); then
    echo "[错误] --derp-port 必须为 1-65535 的整数，当前：${DERP_PORT}" >&2
    exit 1
  fi
  if ! [[ "${STUN_PORT}" =~ ^[0-9]+$ ]] || (( STUN_PORT < 1 || STUN_PORT > 65535 )); then
    echo "[错误] --stun-port 必须为 1-65535 的整数，当前：${STUN_PORT}" >&2
    exit 1
  fi
  if ! [[ "${CERT_DAYS}" =~ ^[0-9]+$ ]] || (( CERT_DAYS < 1 )); then
    echo "[错误] --cert-days 必须为正整数，当前：${CERT_DAYS}" >&2
    exit 1
  fi
  # IPv4 合法性校验：格式 + 每段范围 0-255
  if ! [[ "${IP_ADDR}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "[错误] 公网 IP 不合法：${IP_ADDR}" >&2
    exit 1
  fi
  IFS='.' read -r o1 o2 o3 o4 <<< "${IP_ADDR}"
  for _oct in "$o1" "$o2" "$o3" "$o4"; do
    if ! [[ "$_oct" =~ ^[0-9]+$ ]] || (( _oct < 0 || _oct > 255 )); then
      echo "[错误] 公网 IP 字段超出范围（0-255）：${IP_ADDR}" >&2
      exit 1
    fi
  done
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
    exit 1
  fi
  echo "[信息] 使用公网 IP：${IP_ADDR}"
}

# 版本比较：ver_ge A B => A >= B ?
ver_ge() {
  if sort -V </dev/null &>/dev/null; then
    local a="$1" b="$2"
    [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" == "$a" ]]
  else
    [[ "$1" == "$2" ]] || [[ "$1" > "$2" ]]
  fi
}

ts_version() {
  (tailscale version 2>/dev/null | head -n1 | sed -E 's/[^0-9\.].*$//' || true)
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
    cat "$unit"
  elif command -v systemctl >/dev/null 2>&1; then
    systemctl cat derper 2>/dev/null || true
  fi
}

check_ports_status() {
  PORT_TLS_OK=0; PORT_STUN_OK=0
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | grep -E ":${DERP_PORT}\b" >/dev/null 2>&1 && PORT_TLS_OK=1 || true
    ss -lunp 2>/dev/null | grep -E ":${STUN_PORT}\b" >/dev/null 2>&1 && PORT_STUN_OK=1 || true
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltnp 2>/dev/null | grep -E ":${DERP_PORT}\b" >/dev/null 2>&1 && PORT_TLS_OK=1 || true
    netstat -lunp 2>/dev/null | grep -E ":${STUN_PORT}\b" >/dev/null 2>&1 && PORT_STUN_OK=1 || true
  fi
}

check_pure_ip_from_unit() {
  PURE_IP_OK=0
  local content="$1"
  [[ -z "$content" ]] && PURE_IP_OK=0 && return 0
  echo "$content" | grep -E -- '-hostname[[:space:]]+([0-9]{1,3}\.){3}[0-9]{1,3}' >/dev/null 2>&1 || return 0
  echo "$content" | grep -q -- '-certmode[[:space:]]+manual' || return 0
  echo "$content" | grep -q -- '-certdir[[:space:]]' || return 0
  echo "$content" | grep -q -- '-http-port[[:space:]]+-1' || return 0
  if echo "$content" | grep -q -- '-https-port[[:space:]]+[0-9]'; then :; else
    echo "$content" | grep -q -- '-a[[:space:]]+:[0-9]' || return 0
  fi
  echo "$content" | grep -q -- '-stun' || return 0
  PURE_IP_OK=1
}

check_derper_status() {
  DERPER_BIN=0; DERPER_SERVICE_PRESENT=0; DERPER_RUNNING=0; PURE_IP_OK=0
  if [[ -x "${BIN_PATH}" ]] || command -v derper >/dev/null 2>&1; then DERPER_BIN=1; fi
  local unit_path; unit_path=$(get_derper_unit_path)
  [[ -n "$unit_path" && -f "$unit_path" ]] && DERPER_SERVICE_PRESENT=1
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet derper 2>/dev/null; then DERPER_RUNNING=1; fi
  if [[ $DERPER_RUNNING -eq 0 ]] && pgrep -x derper >/dev/null 2>&1; then DERPER_RUNNING=1; fi
  local content; content=$(read_derper_unit_content || true)
  check_pure_ip_from_unit "$content"
  check_ports_status
}

check_cert_status() {
  CERT_PRESENT=0; CERT_SAN_MATCH=0; CERT_EXPIRY_OK=0
  if [[ -f "${INSTALL_DIR}/certs/fullchain.pem" && -f "${INSTALL_DIR}/certs/privkey.pem" ]]; then
    CERT_PRESENT=1
    if command -v openssl >/dev/null 2>&1; then
      if openssl x509 -in "${INSTALL_DIR}/certs/fullchain.pem" -noout -text 2>/dev/null | grep -E "IP( Address)?:[[:space:]]*${IP_ADDR}" >/dev/null 2>&1; then
        CERT_SAN_MATCH=1
      elif openssl x509 -in "${INSTALL_DIR}/certs/fullchain.pem" -noout -ext subjectAltName 2>/dev/null | grep -E "IP(:| Address:)[[:space:]]*${IP_ADDR}" >/dev/null 2>&1; then
        CERT_SAN_MATCH=1
      fi
      if openssl x509 -checkend $((30*24*3600)) -in "${INSTALL_DIR}/certs/fullchain.pem" -noout >/dev/null 2>&1; then
        CERT_EXPIRY_OK=1
      fi
    fi
  fi
}

# 计算证书剩余天数（失败返回空）
cert_days_remaining() {
  command -v openssl >/dev/null 2>&1 || { echo ""; return 0; }
  [[ -f "${INSTALL_DIR}/certs/fullchain.pem" ]] || { echo ""; return 0; }
  local end raw ts_now ts_end
  raw=$(openssl x509 -in "${INSTALL_DIR}/certs/fullchain.pem" -noout -enddate 2>/dev/null | awk -F= '{print $2}') || true
  [[ -n "$raw" ]] || { echo ""; return 0; }
  ts_now=$(date +%s)
  # GNU date
  if ts_end=$(date -d "$raw" +%s 2>/dev/null); then
    :
  else
    # BSD date 兼容（较少见于本脚本目标环境）
    ts_end=$(date -j -f "%b %d %T %Y %Z" "$raw" +%s 2>/dev/null || echo "")
  fi
  [[ -n "$ts_end" ]] || { echo ""; return 0; }
  echo $(( (ts_end - ts_now) / 86400 ))
}

install_deps() {
  # 按需安装：仅在缺少必要命令时才访问包管理器，避免无谓的网络访问
  local need_pkgs=()
  # 基础必需：curl、openssl、git（go 的获取在 ensure_go 内部处理）
  command -v curl >/dev/null 2>&1     || need_pkgs+=(curl)
  command -v openssl >/dev/null 2>&1  || need_pkgs+=(openssl)
  command -v git >/dev/null 2>&1      || need_pkgs+=(git)
  # 可选但常用：nc/ss，用于自检；缺失不强制
  if ! command -v nc >/dev/null 2>&1; then
    if command -v apt >/dev/null 2>&1; then need_pkgs+=(netcat-openbsd); fi
    if command -v dnf >/dev/null 2>&1; then need_pkgs+=(nmap-ncat); fi
    if command -v yum >/dev/null 2>&1; then need_pkgs+=(nmap-ncat); fi
  fi
  if ! command -v ss >/dev/null 2>&1; then
    if command -v apt >/dev/null 2>&1; then need_pkgs+=(iproute2); fi
    if command -v dnf >/dev/null 2>&1; then need_pkgs+=(iproute); fi
    if command -v yum >/dev/null 2>&1; then need_pkgs+=(iproute); fi
  fi

  if [[ ${#need_pkgs[@]} -eq 0 ]]; then
    echo "[信息] 依赖已就绪，跳过安装。"
    return 0
  fi

  echo "[步骤] 按需安装依赖：${need_pkgs[*]} …"
  local install_failed=0
  if command -v apt >/dev/null 2>&1; then
    if ! DEBIAN_FRONTEND=noninteractive apt update -y 2>/tmp/apt_update.err; then
      echo "[警告] apt update 失败，可能影响依赖安装" >&2
      sed -n '1,20p' /tmp/apt_update.err >&2 || true
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt install -y "${need_pkgs[@]}" 2>/tmp/apt_install.err; then
      install_failed=1
    fi
  elif command -v dnf >/dev/null 2>&1; then
    if ! dnf install -y "${need_pkgs[@]}" 2>/tmp/dnf_install.err; then
      install_failed=1
    fi
  elif command -v yum >/dev/null 2>&1; then
    if ! yum install -y "${need_pkgs[@]}" 2>/tmp/yum_install.err; then
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
  
  update-ca-certificates >/dev/null 2>&1 || true
}

# 轻量检测：确保系统有 go 命令。优先用发行版包，工具链版本交由 GOTOOLCHAIN=auto 处理。
ensure_go() {
  if command -v go >/dev/null 2>&1; then
    echo "[信息] 已检测到 Go：$(go version 2>/dev/null)"
    return 0
  fi
  echo "[步骤] 未检测到 go，尝试通过系统包管理器安装 golang-go…"
  if command -v apt >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt install -y golang-go || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y golang || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y golang || true
  fi
  if command -v go >/dev/null 2>&1; then
    echo "[信息] Go 安装完成：$(go version 2>/dev/null)"
    return 0
  fi
  # 兜底：按架构安装官方二进制（最新稳定工具链可再由 GOTOOLCHAIN 自动拉取）。
  local arch os url tarball gov sha256_expected
  os="linux"
  case "$(uname -m)" in
    x86_64|amd64) 
      arch="amd64"
      sha256_expected="999805bed7d9039ec3da1a53bfbcafc13e367da52aa823cb60b68ba22d44c616"
      ;;
    aarch64|arm64) 
      arch="arm64"
      sha256_expected="c15fa895341b8eaf7f219fada25c36a610eb042985dc1a912410c1c90098eaf2"
      ;;
    *) echo "[错误] 未支持的架构 $(uname -m)，请自行安装 Go >= 1.21" >&2; exit 1;;
  esac
  gov="1.22.6"
  url="https://go.dev/dl/go${gov}.${os}-${arch}.tar.gz"
  tarball="/tmp/go${gov}.${os}-${arch}.tar.gz"
  command -v curl >/dev/null 2>&1 || install_deps
  echo "[步骤] 下载安装 Go ${gov} (${arch}) 作为基础工具链…"
  curl -fsSL "$url" -o "$tarball"
  
  # SHA256 完整性校验
  echo "[步骤] 校验 Go tarball 完整性（SHA256）…"
  local sha256_actual
  if command -v sha256sum >/dev/null 2>&1; then
    sha256_actual=$(sha256sum "$tarball" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    sha256_actual=$(shasum -a 256 "$tarball" | awk '{print $1}')
  else
    echo "[警告] 未找到 sha256sum/shasum，跳过完整性校验（不推荐）" >&2
    sha256_actual="$sha256_expected"  # 跳过校验
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
  
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$tarball"
  mkdir -p /etc/profile.d
  echo 'export PATH=/usr/local/go/bin:$PATH' >/etc/profile.d/go.sh
  export PATH=/usr/local/go/bin:$PATH
  echo "[信息] Go 安装完成：$(go version 2>/dev/null || echo 失败)"
}

install_derper() {
  echo "[步骤] 安装/构建 derper 可执行文件…"
  ensure_go
  # 组装环境：可选 GOPROXY/GOSUMDB，自动工具链（避免被墙/版本不足问题）
  local envs=("GOBIN=/usr/local/bin" "GO111MODULE=on" "GOTOOLCHAIN=${GOTOOLCHAIN_ARG}")
  if [[ -n "${GOPROXY_ARG}" ]]; then envs+=("GOPROXY=${GOPROXY_ARG}"); fi
  if [[ -n "${GOSUMDB_ARG}" ]]; then envs+=("GOSUMDB=${GOSUMDB_ARG}"); fi
  if ! env "${envs[@]}" go install tailscale.com/cmd/derper@latest 2>/tmp/derper_install.err; then
    echo "[错误] go install 失败：" >&2
    sed -n '1,160p' /tmp/derper_install.err >&2 || true
    exit 1
  fi
  if [[ ! -x "${BIN_PATH}" ]]; then
    echo "[错误] 未找到 derper 可执行文件：${BIN_PATH}" >&2
    exit 1
  fi
  echo "[信息] derper 安装到：${BIN_PATH}"
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

generate_selfsigned_cert() {
  echo "[步骤] 生成基于 IP 的自签临时证书（SAN=IP:${IP_ADDR}）…"
  mkdir -p "${INSTALL_DIR}/certs"

  # 优先使用 -addext；若系统 openssl 太旧则降级到配置文件方式
  if openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
      -keyout "${INSTALL_DIR}/certs/privkey.pem" \
      -out "${INSTALL_DIR}/certs/fullchain.pem" \
      -days "${CERT_DAYS}" \
      -subj "/CN=${IP_ADDR}" \
      -addext "subjectAltName = IP:${IP_ADDR}" >/dev/null 2>&1; then
    :
  else
    cat >"${INSTALL_DIR}/openssl-derper.cnf" <<CONF
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
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
      -keyout "${INSTALL_DIR}/certs/privkey.pem" \
      -out "${INSTALL_DIR}/certs/fullchain.pem" \
      -days "${CERT_DAYS}" \
      -config "${INSTALL_DIR}/openssl-derper.cnf" >/dev/null 2>&1
  fi

  ln -sf fullchain.pem "${INSTALL_DIR}/certs/cert.pem"
  ln -sf privkey.pem  "${INSTALL_DIR}/certs/key.pem"

  # 加固证书目录与私钥权限
  chmod 750 "${INSTALL_DIR}/certs"
  chmod 600 "${INSTALL_DIR}/certs/privkey.pem"
  chmod 644 "${INSTALL_DIR}/certs/fullchain.pem"
  
  # 注意：证书目录权限由 setup_service_user() 统一设置，避免重复

  echo "[信息] 证书文件生成于：${INSTALL_DIR}/certs/{fullchain.pem,privkey.pem}"
  
  # 生成 derper 配置文件（新版 derper 要求必须指定 -c 参数）
  generate_derper_config
}

generate_derper_config() {
  echo "[步骤] 生成 derper 配置文件…"
  
  # 注意：当使用 -verify-clients 时，derper 需要访问 tailscaled 本地 API
  # 来获取节点密钥和验证客户端。配置文件留空让 derper 自动处理。
  # PrivateKeyPath 指的是 derper 自身的节点私钥（非 TLS 证书私钥）。
  cat >"${INSTALL_DIR}/derper.json" <<CONFIG
{}
CONFIG
  
  chmod 644 "${INSTALL_DIR}/derper.json"
  echo "[信息] derper 配置文件生成于：${INSTALL_DIR}/derper.json"
  
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

# 自定义本地 API Socket 路径（通常无需设置）
# TS_LOCAL_API_SOCKET=/var/run/tailscale/tailscaled.sock

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

# 计算证书 DER 原始字节的 SHA256，用于 ACL 的 CertName（sha256-raw:<hex>）
sha256_hex() {
  # 从标准输入读取，返回十六进制 sha256 值
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    openssl dgst -sha256 | awk '{print $2}'
  fi
}

cert_file_sha256_raw() {
  # 计算本地证书（脚本生成的 cert.pem/fullchain.pem）的指纹
  if command -v openssl >/dev/null 2>&1; then
    local pem
    if [[ -f "${INSTALL_DIR}/certs/cert.pem" ]]; then
      pem="${INSTALL_DIR}/certs/cert.pem"
    else
      pem="${INSTALL_DIR}/certs/fullchain.pem"
    fi
    [[ -f "$pem" ]] || return 1
    openssl x509 -in "$pem" -outform DER 2>/dev/null | sha256_hex
  fi
}

live_cert_sha256_raw() {
  # 通过在线握手读取 derper 实际呈现的证书并计算指纹，最为权威
  # 依赖 openssl；添加超时避免卡住
  command -v openssl >/dev/null 2>&1 || return 1
  local pem
  pem=$(timeout 6 openssl s_client -connect "${IP_ADDR}:${DERP_PORT}" -servername "${IP_ADDR}" -showcerts </dev/null 2>/dev/null \
        | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p') || true
  [[ -n "$pem" ]] || return 1
  printf "%s\n" "$pem" | openssl x509 -outform DER 2>/dev/null | sha256_hex
}

journal_certname_raw() {
  # 从 systemd 日志中提取 derper 打印的 CertName（若可用）
  command -v journalctl >/dev/null 2>&1 || return 1
  local fp
  fp=$(journalctl -u derper -n 200 --no-pager 2>/dev/null \
       | grep -oE 'sha256-raw:[0-9a-f]+' 2>/dev/null | tail -n1 | sed 's/^sha256-raw://' || true)
  [[ -n "$fp" ]] && echo "$fp" || return 1
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
    
    # 设置整个安装目录的所有权（包括父目录）
    if [[ -d "${INSTALL_DIR}" ]]; then
      local user_group
      user_group=$(id -g -n "$RUN_USER" 2>/dev/null || echo "$RUN_USER")
      chown -R "$RUN_USER":"$user_group" "${INSTALL_DIR}" || {
        echo "[警告] 无法设置安装目录所有权（用户：$RUN_USER, 组：$user_group）" >&2
        echo "  服务可能无法访问必要文件，建议手动执行：" >&2
        echo "    chown -R $RUN_USER:$user_group ${INSTALL_DIR}" >&2
      }
    fi
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
    echo "[信息] 用户 $RUN_USER 创建成功（shell: $nologin_path）"
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
  
  # 设置整个安装目录的所有权（包括父目录和所有子目录）
  if [[ -d "${INSTALL_DIR}" ]]; then
    local user_group
    user_group=$(id -g -n "$RUN_USER" 2>/dev/null || echo "$RUN_USER")
    echo "[步骤] 设置安装目录权限：${INSTALL_DIR}"
    chown -R "$RUN_USER":"$user_group" "${INSTALL_DIR}" || {
      echo "[警告] 无法设置安装目录所有权，服务启动时可能失败" >&2
    }
  fi
}

write_systemd_service() {
  echo "[步骤] 写入 systemd 服务单元：${SERVICE_PATH}…"
  local stun_flag
  if derper_supports_stun_port; then
    stun_flag="-stun -stun-port ${STUN_PORT}"
  else
    stun_flag="-stun"
    if [[ "${STUN_PORT}" != "3478" ]]; then
      echo "[提示] 检测到 derper 不支持自定义 STUN 端口，将使用默认 3478。" >&2
    fi
  fi

  local listen_flag
  if derper_supports_listen_a; then
    listen_flag="-a :${DERP_PORT}"
  elif derper_supports_https_port; then
    listen_flag="-https-port ${DERP_PORT}"
  else
    # 极端兜底：仍尝试使用 -a
    listen_flag="-a :${DERP_PORT}"
  fi

  # 根据配置决定是否启用客户端校验
  local verify_flag=""
  case "${VERIFY_CLIENTS_MODE}" in
    on) verify_flag="-verify-clients" ;;
    off) verify_flag="" ;;
  esac
  
  # 检测 tailscaled socket 路径和权限（用于 verify-clients）
  local tailscale_socket_group=""
  local socket_needs_permission_fix=0
  local tailscaled_socket_unit_has_override=0
  local tailscaled_socket_override_group=""
  local need_add_user_to_tailscale_group=0
  if [[ "${VERIFY_CLIENTS_MODE}" == "on" ]]; then
    local socket_path=""
    if [[ -S /run/tailscale/tailscaled.sock ]]; then
      socket_path="/run/tailscale/tailscaled.sock"
    elif [[ -S /var/run/tailscale/tailscaled.sock ]]; then
      socket_path="/var/run/tailscale/tailscaled.sock"
    fi
    
    if [[ -n "$socket_path" ]]; then
      # 获取 socket 的所属组和权限
      tailscale_socket_group=$(stat -c '%G' "$socket_path" 2>/dev/null || true)
      local socket_perms=$(stat -c '%a' "$socket_path" 2>/dev/null || true)
      
      if [[ -n "$tailscale_socket_group" && "$tailscale_socket_group" != "$RUN_USER" ]]; then
        echo "[步骤] 配置 tailscaled socket 访问权限（当前组：${tailscale_socket_group}，权限：${socket_perms}）"

        # 若当前组为 root，优先尝试创建/使用 tailscale 组，并重启 tailscaled 让本地 API 以 tailscale 组创建
        if [[ "$tailscale_socket_group" == "root" ]]; then
          if ! getent group tailscale >/dev/null 2>&1; then
            echo "[步骤] 创建 tailscale 组（若已存在将跳过）"
            groupadd -r tailscale 2>/dev/null || true
          fi
          if getent group tailscale >/dev/null 2>&1; then
            echo "[步骤] 重启 tailscaled 尝试应用 tailscale 组到本地 API socket"
            if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet tailscaled 2>/dev/null; then
              systemctl restart tailscaled 2>/dev/null || true
              sleep 1
              # 重读 socket 组与权限
              tailscale_socket_group=$(stat -c '%G' "$socket_path" 2>/dev/null || echo "$tailscale_socket_group")
              socket_perms=$(stat -c '%a' "$socket_path" 2>/dev/null || echo "$socket_perms")
              echo "[信息] tailscaled 本地 API 刷新后：组=${tailscale_socket_group} 权限=${socket_perms}"
            fi
          fi
        fi

        # 将 derper 用户加入 tailscale 组（若存在）
        if getent group tailscale >/dev/null 2>&1; then
          need_add_user_to_tailscale_group=1
          usermod -a -G tailscale "$RUN_USER" 2>/dev/null || true
        fi
        # 优先使用 systemd 覆盖 tailscaled.socket 的组与权限（更安全、持久）
        if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^tailscaled\.socket'; then
          # 选择一个合适的组：优先 tailscale 组，其次 derper 组
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
          if systemctl daemon-reload 2>/dev/null && systemctl restart tailscaled.socket 2>/dev/null; then
            tailscaled_socket_unit_has_override=1
            echo "[信息] 已为 tailscaled.socket 应用覆盖：SocketGroup=${tailscaled_socket_override_group} SocketMode=0660"
            # 同步将 derper 用户加入该组（若为 tailscale 组）
            if [[ "$tailscaled_socket_override_group" == "tailscale" ]]; then
              usermod -a -G tailscale "$RUN_USER" 2>/dev/null || true
            fi
          else
            echo "[警告] tailscaled.socket 覆盖应用失败，将回退到临时权限调整或 ACL。" >&2
          fi
        fi

        # 若无法持久覆盖，尝试 ACL，失败则报错并提示解决方案
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
          
          # 如果 systemd drop-in 和 ACL 都失败，检查是否需要报错
          if [[ "$acl_success" -ne 1 ]]; then
            if [[ "$tailscale_socket_group" == "root" ]] && [[ "$socket_perms" != "666" && "$socket_perms" != "667" && "$socket_perms" != "676" && "$socket_perms" != "777" ]]; then
              # 权限不足且没有成功的解决方案
              if [[ "$RELAX_SOCKET_PERMS" -eq 1 ]]; then
                echo "[警告] 已启用 --relax-socket-perms，临时放宽 socket 权限到 0666（不推荐，重启 tailscaled 后失效）" >&2
                chmod 666 "$socket_path" 2>/dev/null || true
              else
                # 报错并提供三种合规解决方案
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
    bash $0 --use-current-user [其他参数]

方案 4：临时放宽权限（不推荐，仅紧急情况）
  如果你了解风险，可添加 --relax-socket-perms 参数：
    bash $0 --relax-socket-perms [其他参数]
  注意：该方案在 tailscaled 重启后失效，且存在安全风险

EOT
                exit 1
              fi
            fi
          fi
        fi
      fi
    else
      echo "[警告] 未检测到 tailscaled socket，-verify-clients 可能无法正常工作" >&2
    fi
  fi

  # 非 systemd 环境前置拦截并给出手动运行示例
  if ! command -v systemctl >/dev/null 2>&1; then
    # 根据配置文件是否为空，决定是否在示例命令中包含 -c 选项
    local config_flag=""
    if [[ -f "${INSTALL_DIR}/derper.json" ]]; then
      local _cfg_trim
      _cfg_trim=$(tr -d ' \t\r\n' <"${INSTALL_DIR}/derper.json" 2>/dev/null || echo "")
      if [[ -n "${_cfg_trim}" && "${_cfg_trim}" != "{}" ]]; then
        config_flag="-c ${INSTALL_DIR}/derper.json"
      fi
    fi
    cat >&2 <<EOT
[阻断] 未检测到 systemd，无法写入服务单元：${SERVICE_PATH}

你可以手动前台运行 derper（示例）：
  ${BIN_PATH} \\
    ${config_flag} \\
    -hostname ${IP_ADDR} \\
    -certmode manual \\
    -certdir ${INSTALL_DIR}/certs \\
    -http-port -1 \\
    ${listen_flag} \\
    ${stun_flag} \\
    ${verify_flag}

说明：若 derper 旧版本不支持 "-a" 或 "-stun-port"，请改用 "-https-port ${DERP_PORT}"，并去掉 "-stun-port"。
EOT
    exit 1
  fi

  # 设置服务运行用户
  setup_service_user
  # 若需要，将运行用户加入 tailscale 组（再次执行以确保用户已存在）
  if [[ "$need_add_user_to_tailscale_group" -eq 1 ]] && getent group tailscale >/dev/null 2>&1; then
    usermod -a -G tailscale "$RUN_USER" 2>/dev/null || true
  fi
  
  # 获取用户的组名
  local run_group
  run_group=$(id -g -n "$RUN_USER" 2>/dev/null || echo "$RUN_USER")
  
  # 构建 SupplementaryGroups 配置（用于 tailscaled socket 访问）
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

  # 根据配置文件是否为空，决定是否在 ExecStart 中包含 -c 选项
  local config_flag=""
  if [[ -f "${INSTALL_DIR}/derper.json" ]]; then
    local _cfg_trim
    _cfg_trim=$(tr -d ' \t\r\n' <"${INSTALL_DIR}/derper.json" 2>/dev/null || echo "")
    if [[ -n "${_cfg_trim}" && "${_cfg_trim}" != "{}" ]]; then
      config_flag="-c ${INSTALL_DIR}/derper.json"
    fi
  fi

  # 根据 verify-clients 与已探测的 socket 路径，设置本地 API 环境变量
  local localapi_env_line=""
  if [[ "${VERIFY_CLIENTS_MODE}" == "on" ]]; then
    local chosen_socket=""
    if [[ -S /run/tailscale/tailscaled.sock ]]; then
      chosen_socket="/run/tailscale/tailscaled.sock"
    elif [[ -S /var/run/tailscale/tailscaled.sock ]]; then
      chosen_socket="/var/run/tailscale/tailscaled.sock"
    elif [[ -n "$socket_path" ]]; then
      chosen_socket="$socket_path"
    fi
    # 即便未检测到，也写入常见路径，避免 derper 误用默认
    [[ -z "$chosen_socket" ]] && chosen_socket="/run/tailscale/tailscaled.sock"
    localapi_env_line="Environment=TS_LOCAL_API_SOCKET=${chosen_socket}"
  fi

  # 根据安全级别生成加固选项
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

  local hardening_options="$hardening_standard"  # 默认 standard
  case "${SECURITY_LEVEL}" in
    basic)
      hardening_options="$hardening_basic"
      echo "[信息] 使用 basic 安全级别（最大兼容性）"
      ;;
    paranoid)
      hardening_options="$hardening_paranoid"
      echo "[信息] 使用 paranoid 安全级别（最严格加固）"
      ;;
    standard|*)
      hardening_options="$hardening_standard"
      echo "[信息] 使用 standard 安全级别（推荐）"
      ;;
  esac

  cat >"${SERVICE_PATH}" <<SERVICE
[Unit]
Description=Tailscale DERP (derper) with self-signed IP cert
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Type=simple
User=${RUN_USER}
Group=${run_group}
${supplementary_groups_line}

# 环境变量（支持敏感配置）
EnvironmentFile=-/etc/derper/derper.env
${localapi_env_line}

ExecStart=${BIN_PATH} \\
  ${config_flag} \\
  -hostname ${IP_ADDR} \\
  -certmode manual \\
  -certdir ${INSTALL_DIR}/certs \\
  -http-port -1 \\
  ${listen_flag} \\
  ${stun_flag} \\
  ${verify_flag}
Restart=on-failure
RestartSec=2
LimitNOFILE=65535

# 能力边界
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# 安全加固（级别：${SECURITY_LEVEL}）
$hardening_options

# 路径权限
ReadWritePaths=${INSTALL_DIR}

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  
  # 尝试启动服务，如果失败则可能是加固选项不兼容
  if ! systemctl enable --now derper 2>/dev/null; then
    echo "[警告] 服务启动失败，可能是某些安全选项不兼容当前系统" >&2
    
    # 检查是否是 MemoryDenyWriteExecute 导致的问题（Go 程序常见）
    if [[ "${SECURITY_LEVEL}" == "paranoid" ]]; then
      echo "[步骤] 尝试禁用 MemoryDenyWriteExecute 选项重试" >&2
      sed -i '/MemoryDenyWriteExecute/d' "${SERVICE_PATH}"
      systemctl daemon-reload
      
      if systemctl enable --now derper 2>/dev/null; then
        echo "[信息] 服务已成功启动（已禁用 MemoryDenyWriteExecute）"
      else
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
  
  systemctl status derper --no-pager -l || true
  
  # 显示安全评分（如果可用）
  if command -v systemd-analyze >/dev/null 2>&1; then
    echo ""
    echo "[信息] systemd 安全评分："
    systemd-analyze security derper.service 2>/dev/null | head -20 || true
  fi
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
}

runtime_checks() {
  echo "[步骤] 运行时快速自检…"
  echo "- 检查端口监听："
  if command -v ss >/dev/null 2>&1; then
    ss -tulpn | sed -n '1,200p' | grep -E ":(${DERP_PORT}|${STUN_PORT})" || true
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tulpn | sed -n '1,200p' | grep -E ":(${DERP_PORT}|${STUN_PORT})" || true
  fi

  echo "- 测试 HTTPS 握手（自签证书会提示不受信）："
  (command -v openssl >/dev/null 2>&1 && \
    timeout 5 openssl s_client -connect ${IP_ADDR}:${DERP_PORT} -servername ${IP_ADDR} -brief </dev/null || true)

  echo "- 测试 STUN 端口可达性（UDP）："
  if command -v nc >/dev/null 2>&1; then
    (timeout 3 nc -zvu ${IP_ADDR} ${STUN_PORT} || true)
  else
    echo "  [提示] 未找到 nc，跳过 UDP 探测。"
  fi
}

# 在写入 systemd 服务前，预检端口占用，避免启动后才失败
check_port_conflicts() {
  echo "[步骤] 端口占用预检…"
  local conflict=0
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | grep -E ":${DERP_PORT}\\b" >/dev/null; then
      echo "[错误] 检测到 TCP 端口 ${DERP_PORT} 已被占用。请更换 --derp-port 或释放占用进程：" >&2
      ss -ltnp | sed -n '1,200p' | grep -E ":${DERP_PORT}\\b" || true
      conflict=1
    fi
    if ss -lun 2>/dev/null | grep -E ":${STUN_PORT}\\b" >/dev/null; then
      echo "[错误] 检测到 UDP 端口 ${STUN_PORT} 已被占用。请更换 --stun-port 或释放占用进程：" >&2
      ss -lunp | sed -n '1,200p' | grep -E ":${STUN_PORT}\\b" || true
      conflict=1
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if netstat -ltnp 2>/dev/null | grep -E ":${DERP_PORT}\\b" >/dev/null; then
      echo "[错误] 检测到 TCP 端口 ${DERP_PORT} 已被占用。请更换 --derp-port 或释放占用进程：" >&2
      netstat -ltnp | sed -n '1,200p' | grep -E ":${DERP_PORT}\\b" || true
      conflict=1
    fi
    if netstat -lunp 2>/dev/null | grep -E ":${STUN_PORT}\\b" >/dev/null; then
      echo "[错误] 检测到 UDP 端口 ${STUN_PORT} 已被占用。请更换 --stun-port 或释放占用进程：" >&2
      netstat -lunp | sed -n '1,200p' | grep -E ":${STUN_PORT}\\b" || true
      conflict=1
    fi
  fi
  if [[ ${conflict} -eq 1 ]]; then
    echo "[提示] 你也可以使用如下命令进一步排查：" >&2
    echo "  ss -tulpn | grep -E ':${DERP_PORT}|:${STUN_PORT}'" >&2
    echo "  netstat -tulpn | grep -E ':${DERP_PORT}|:${STUN_PORT}'" >&2
    exit 1
  fi
  echo "[信息] 端口未发现占用。"
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

print_acl_snippet_insecure() {
  cat <<'JSON'
==================== 备用方案（不推荐）：使用自签 + InsecureForTests 的 derpMap 片段 ====================
// 注意：仅在无法使用 CertName 指纹时使用该片段，并设置 "InsecureForTests": true
//       HostName 应填写你的公网 IP。
{
  "derpMap": {
    "OmitDefaultRegions": false,
    "Regions": {
      "901": {
        "RegionID": 901,
        "RegionCode": "my-derp",
        "RegionName": "My IP DERP",
        "Nodes": [
          {
            "Name": "901a",
            "RegionID": 901,
            "HostName": "<你的公网IP>",
            "DERPPort": 443,
            "InsecureForTests": true
          }
        ]
      }
    }
  }
}
====================================================================================================================
JSON
}

print_client_verify_steps() {
  cat <<EOF
============================== 客户端验证步骤（在同一 Tailnet 的任意设备上执行） ==============================
1) 更新 ACL：把上面的 derpMap 片段粘贴到管理后台 Access Controls 并保存；
   - 若你修改了端口，请同步更新 "DERPPort"。
   - 保存后等待 10~60 秒，客户端会自动拉取最新 derpMap。

2) 在客户端验证：
   - 查看 DERP 拓扑：
       tailscale netcheck | sed -n '1,160p'
     观察 "DERP latency" / 自定义 Region 是否出现你的自建节点（延迟应较低）。

   - 查看连接状态：
       tailscale status
     某些直连失败的对端会显示 "relay \"my-derp\"" 或你的 Region/Node 名称。

3) UDP STUN 探测（可选）：
   - 在 Linux/macOS 客户端上可运行：
       nc -zvu <你的公网IP> ${STUN_PORT}
     若显示 succeeded / open，一般表示 STUN 端口可达。

4) 常见排查：
   - derper 启动失败：journalctl -u derper -f 查看报错（证书路径/端口占用/参数）。
   - 客户端未走你的 DERP：确认 derpMap 已保存、HostName 为公网 IP、（若未使用 CertName）InsecureForTests 已设置。
   - 端口被拦截：确认云安全组/本机防火墙已放行 ${DERP_PORT}/tcp 与 ${STUN_PORT}/udp。
=========================================================================================================
EOF
}

# 健康检查摘要（适合 cron 调用）
health_check_report() {
  # 检查关键依赖工具
  local missing_tools=()
  command -v timeout >/dev/null 2>&1 || missing_tools+=(timeout)
  command -v openssl >/dev/null 2>&1 || missing_tools+=(openssl)
  if [[ ${#missing_tools[@]} -gt 0 ]]; then
    echo "[提示] 健康检查建议安装以下工具以获得完整功能：${missing_tools[*]}" >&2
  fi
  
  detect_public_ip || true
  validate_settings || true
  check_tailscale_status
  check_derper_status
  check_cert_status
  local days_left
  days_left=$(cert_days_remaining || true)

  echo "[健康检查] DERP 服务健康状态摘要："
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet derper 2>/dev/null; then
      echo "✅ 服务：derper 处于运行中"
    else
      echo "❌ 服务：derper 未在运行"
    fi
  else
    [[ $DERPER_RUNNING -eq 1 ]] && echo "✅ 进程：derper 运行中" || echo "❌ 进程：derper 未运行"
  fi
  [[ $PORT_TLS_OK -eq 1 ]] && echo "✅ 端口：TLS ${DERP_PORT}/tcp 正在监听" || echo "❌ 端口：TLS ${DERP_PORT}/tcp 未监听"
  [[ $PORT_STUN_OK -eq 1 ]] && echo "✅ 端口：STUN ${STUN_PORT}/udp 正在监听" || echo "❌ 端口：STUN ${STUN_PORT}/udp 未监听"

  if [[ -n "$days_left" ]]; then
    if (( days_left >= 30 )); then
      echo "✅ 证书：有效期剩余 ${days_left} 天"
    elif (( days_left >= 0 )); then
      echo "⚠️  证书：有效期仅剩 ${days_left} 天（建议尽快重签）"
    else
      echo "❌ 证书：已过期（请重签）"
    fi
  else
    echo "⚠️  证书：未能计算有效期（可能缺少 openssl 或证书文件）"
  fi

  # 进程内存占用（RSS）
  local rss_kb rss_mb pidlist
  pidlist=$(pgrep -x derper 2>/dev/null | xargs || true)
  if [[ -n "$pidlist" ]]; then
    rss_kb=$(ps -o rss= -p $pidlist 2>/dev/null | awk '{s+=$1} END{print s+0}')
    rss_mb=$(( (rss_kb + 1023) / 1024 ))
    echo "ℹ️  资源：derper 内存 RSS 约 ${rss_mb} MiB"
  else
    echo "ℹ️  资源：未发现 derper 进程，略过内存统计"
  fi

  # 导出 Prometheus 文本（可被 node_exporter textfile collector 收集）
  if [[ -n "${METRICS_TEXTFILE}" ]]; then
    write_prometheus_metrics "${METRICS_TEXTFILE}" "$days_left" "$rss_kb"
    echo "[信息] 已写入 Prometheus 指标：${METRICS_TEXTFILE}"
  fi
}

write_prometheus_metrics() {
  local path="$1" days_left="$2" rss_kb="$3"
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  {
    echo "# HELP derper_up Whether derper service is up (1)"
    echo "# TYPE derper_up gauge"
    [[ $DERPER_RUNNING -eq 1 ]] && echo "derper_up 1" || echo "derper_up 0"

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
    [[ "${VERIFY_CLIENTS_MODE}" == "on" ]] && echo "derper_verify_clients 1" || echo "derper_verify_clients 0"

    echo "# HELP derper_pure_ip_config_ok Whether pure IP mode config is detected"
    echo "# TYPE derper_pure_ip_config_ok gauge"
    [[ $PURE_IP_OK -eq 1 ]] && echo "derper_pure_ip_config_ok 1" || echo "derper_pure_ip_config_ok 0"

    echo "# HELP derper_process_rss_bytes Total RSS of derper process in bytes"
    echo "# TYPE derper_process_rss_bytes gauge"
    if [[ -n "$rss_kb" ]]; then
      echo "derper_process_rss_bytes $((rss_kb*1024))"
    else
      echo "derper_process_rss_bytes 0"
    fi
  } >"$path".tmp
  mv -f "$path".tmp "$path"
}

uninstall_derper() {
  require_root
  echo "[步骤] 停止并卸载 derper systemd 服务…"

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
  echo "[信息] 已卸载 service：${SERVICE_PATH}"

  if [[ ${PURGE} -eq 1 ]]; then
    echo "[步骤] 清理安装目录：${INSTALL_DIR} …"
    rm -rf "${INSTALL_DIR}"
    echo "[信息] 安装目录已清理。"
  fi

  if [[ ${PURGE_ALL} -eq 1 ]]; then
    if [[ -x "${BIN_PATH}" ]]; then
      echo "[步骤] 删除 derper 二进制：${BIN_PATH} …"
      rm -f "${BIN_PATH}" || true
    fi
    # 根据已识别的服务用户给出更准确的清理提示
    if [[ -n "$svc_user" && "$svc_user" != "root" ]]; then
      echo "[提示] 检测到服务运行用户：${svc_user}。如需删除该账户，可执行："
      echo "  userdel ${svc_user}"
    else
      echo "[提示] 未能识别非 root 的服务运行用户；如需删除账户请手动确认后执行 userdel。"
    fi
  fi
  echo "完成：已卸载 derper 服务。"
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

  # 问题1：使用场景
  echo "1. 您的使用场景？"
  echo "   a) 个人测试/学习"
  echo "   b) 小团队（<10人）"
  echo "   c) 生产环境"
  read -p "   请选择 (a/b/c): " scenario
  
  # 问题2：账户偏好
  echo ""
  echo "2. 账户管理偏好？"
  echo "   a) 简单优先（使用当前账户）"
  echo "   b) 安全优先（创建专用账户）"
  read -p "   请选择 (a/b): " account_pref
  
  # 问题3：端口选择
  echo ""
  echo "3. DERP 端口？"
  echo "   a) 443（推荐，防火墙友好）"
  echo "   b) 30399（默认，避免与其他服务冲突）"
  read -p "   请选择 (a/b): " port_choice
  
  # 问题4：客户端验证
  echo ""
  echo "4. 是否启用客户端验证？"
  echo "   a) 是（推荐，更安全）- 需要本地 tailscaled 已登录"
  echo "   b) 否（仅测试环境）"
  read -p "   请选择 (a/b): " verify_choice
  
  # 生成命令（使用模板替换，不用 eval）
  # 注意：每个参数必须是独立的数组元素，以便 exec 正确执行
  local cmd_parts=()
  cmd_parts+=("sudo" "bash" "$0")
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
  
  # 如果是国内，添加代理建议
  if [[ -n "${LANG}" ]] && [[ "${LANG}" =~ zh ]]; then
    cmd_parts+=("--goproxy" "https://goproxy.cn,direct")
    cmd_parts+=("--gosumdb" "sum.golang.google.cn")
  fi
  
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
- 命令已保存到 derper_deploy_cmd.sh，方便后续使用

是否立即执行？(y/n)
EOT
  
  # 保存到文件
  echo "$full_cmd" > derper_deploy_cmd.sh
  chmod +x derper_deploy_cmd.sh
  
  read -p "> " execute
  if [[ "$execute" == "y" || "$execute" == "Y" ]]; then
    echo ""
    read -p "请输入您的公网 IP: " user_ip
    
    # 严格验证 IPv4 格式
    if [[ ! "$user_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "[错误] IP 格式不正确，请手动修改 derper_deploy_cmd.sh 后执行" >&2
      exit 1
    fi
    
    # 验证每个字段范围（0-255）
    IFS='.' read -ra octets <<< "$user_ip"
    for octet in "${octets[@]}"; do
      if [[ "$octet" -gt 255 ]]; then
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
    read -p "确认执行？(yes/no): " final_confirm
    
    if [[ "$final_confirm" == "yes" ]]; then
      # 使用数组安全执行，彻底避免 shell 注入
      exec "${exec_args[@]}"
    else
      echo "[信息] 已取消执行，命令已保存到 derper_deploy_cmd.sh"
    fi
  else
    echo "[信息] 命令已保存到 derper_deploy_cmd.sh"
    echo "       手动执行前请替换 __IP_PLACEHOLDER__ 为实际 IP"
  fi
}

main() {
  # 特殊子命令处理
  if [[ "$1" == "wizard" ]]; then
    deployment_wizard
    exit 0
  fi
  
  parse_args "$@"

  # 非交互 + 直接以 root 运行时的安全默认：切换为专用账户
  # 条件：当前用户为 root，且未通过 sudo 传入真实用户，且未显式选择专用用户
  if [[ "$(id -u)" -eq 0 && -z "${SUDO_USER:-}" && "${NON_INTERACTIVE}" -eq 1 ]]; then
    if [[ "${RUN_USER}" == "root" && "${CREATE_DEDICATED_USER}" -eq 0 ]]; then
      echo "[信息] 检测到非交互 root 运行，默认切换为专用账户（等同 --dedicated-user）。"
      RUN_USER="derper"
      CREATE_DEDICATED_USER=1
      USE_CURRENT_USER=0
    fi
  fi
  
  # 环境检测（优先级最高，除了 --help 和 --uninstall）
  if [[ "${UNINSTALL}" -eq 1 ]]; then
    # 卸载优先处理：不依赖环境检测/公网 IP 探测/参数校验
    uninstall_derper
    exit 0
  fi
  
  # 检查操作系统和运行环境（Linux only）
  check_os_environment

  # 探测 IP 与校验参数（即使非 root 也可做检查）
  # 注意：在 --check/--health-check 模式下容错，允许部分失败继续输出信息
  detect_public_ip || true
  validate_settings || true

  # 收集当前状态
  check_tailscale_status
  check_derper_status
  check_cert_status

  # 健康检查模式（仅输出状态/指标，不变更系统）
  if [[ "${HEALTH_CHECK}" -eq 1 ]]; then
    health_check_report
    # 根据关键项给出退出码：全部健康返回 0，否则 1
    local ok=1
    if [[ $DERPER_RUNNING -eq 1 && $PORT_TLS_OK -eq 1 && $PORT_STUN_OK -eq 1 ]]; then ok=0; fi
    exit $ok
  fi

  if [[ "${DRY_RUN}" -eq 1 || "${CHECK_ONLY}" -eq 1 ]]; then
    echo "[检查] 参数与环境状态总结："
    echo "- 公网 IP：${IP_ADDR}"
    echo "- DERP 端口：${DERP_PORT}/tcp；STUN 端口：${STUN_PORT}/udp"
    echo "- tailscale：安装=${TS_INSTALLED} 运行=${TS_RUNNING} 版本=${TS_VERSION:-<未知>} (>=${REQUIRED_TS_VER}) 满足=${TS_VER_OK}"
    echo "- derper：二进制=${DERPER_BIN} 服务文件=${DERPER_SERVICE_PRESENT} 运行=${DERPER_RUNNING}"
    echo "- 端口监听：TLS=${PORT_TLS_OK} STUN=${PORT_STUN_OK}"
    echo "- 纯 IP 配置判定（基于 unit）：${PURE_IP_OK}"
    echo "- 证书：存在=${CERT_PRESENT} SAN匹配IP=${CERT_SAN_MATCH} 30天内不过期=${CERT_EXPIRY_OK}"
    echo "- 客户端校验模式：${VERIFY_CLIENTS_MODE}"
    # 展示将要使用的运行用户与组（若用户尚未创建则组名以用户名代替）
    local chk_group
    chk_group=$(id -g -n "$RUN_USER" 2>/dev/null || echo "$RUN_USER")
    echo "- 运行用户：${RUN_USER}（组：${chk_group}）"

    local suggest="--repair"
    if [[ $DERPER_BIN -eq 1 && $DERPER_SERVICE_PRESENT -eq 1 && $DERPER_RUNNING -eq 1 && $PURE_IP_OK -eq 1 && $PORT_TLS_OK -eq 1 && $PORT_STUN_OK -eq 1 && $CERT_PRESENT -eq 1 && $CERT_SAN_MATCH -eq 1 && $CERT_EXPIRY_OK -eq 1 ]]; then
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

    echo "[检查结束] 使用 --repair 修复配置，或 --force 全量重装；若一切就绪可直接跳过。"
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

  if [[ "${FORCE}" -eq 1 ]]; then
    install_deps
    install_derper
    generate_selfsigned_cert
    check_port_conflicts
    write_systemd_service
    print_firewall_tips
    runtime_checks
  elif [[ "${REPAIR}" -eq 1 ]]; then
    install_deps
    if [[ $CERT_PRESENT -ne 1 || $CERT_SAN_MATCH -ne 1 || $CERT_EXPIRY_OK -ne 1 ]]; then
      generate_selfsigned_cert
    fi
    check_port_conflicts
    write_systemd_service
    print_firewall_tips
    runtime_checks
  else
    # 默认幂等：按需修复
    local changed=0
    if [[ $DERPER_BIN -ne 1 ]]; then
      install_deps
      install_derper; changed=1
    fi
    if [[ $CERT_PRESENT -ne 1 || $CERT_SAN_MATCH -ne 1 || $CERT_EXPIRY_OK -ne 1 ]]; then
      command -v openssl >/dev/null 2>&1 || install_deps
      generate_selfsigned_cert; changed=1
    fi
    if [[ $DERPER_SERVICE_PRESENT -ne 1 || $PURE_IP_OK -ne 1 ]]; then
      check_port_conflicts
      write_systemd_service; changed=1
    fi
    if [[ $changed -eq 0 && $DERPER_RUNNING -eq 1 && $PORT_TLS_OK -eq 1 && $PORT_STUN_OK -eq 1 ]]; then
      echo "✅ 已就绪：检测到 derper 正在以纯 IP 模式运行，跳过安装。"
      exit 0
    fi
    print_firewall_tips
    runtime_checks
  fi

  local FP
  FP=$(live_cert_sha256_raw || true)
  if [[ -z "$FP" ]]; then FP=$(journal_certname_raw || true); fi
  if [[ -z "$FP" ]]; then FP=$(cert_file_sha256_raw || true); fi
  if [[ -n "$FP" ]]; then
    print_acl_snippet_cert "${IP_ADDR}" "${DERP_PORT}" "$FP"
    echo "[信息] 已基于实际在线证书指纹生成片段：sha256-raw:${FP}"
  else
    print_acl_snippet_insecure | sed "s/<你的公网IP>/${IP_ADDR}/g" | sed "s/\"DERPPort\": 443/\"DERPPort\": ${DERP_PORT}/g"
    echo "[提示] 未能获取证书指纹（可能端口未就绪或缺少 openssl），已回退到 InsecureForTests 片段。"
  fi
  print_client_verify_steps

  cat <<INFO
完成：DERP 服务已部署/修复并尝试运行。
- 服务：systemctl status derper
- 日志：journalctl -u derper -f
- 证书：${INSTALL_DIR}/certs/{fullchain.pem,privkey.pem}（自签临时证书，建议仅测试用途）
- 配置：${INSTALL_DIR}/derper.json

在 Tailscale 后台粘贴 derpMap 后，客户端数十秒内会自动下发。
INFO
}

main "$@"
