#!/usr/bin/env bash

# 说明：
#  - 面向“仅有公网 IP、无需域名”的轻量 DERP 部署；生成“基于 IP 的自签证书”。
#  - 适合测试/临时/小规模使用；生产建议配合受信任 CA 证书与 443 端口。
#  - 脚本会：安装依赖 -> 安装/构建 derper -> 生成证书 -> 写入 systemd -> 防火墙提示 -> 自检 -> 输出 ACL 片段。
#  - 兼容新版 derper（使用 -a :PORT），旧版则回退到 -https-port；默认启用 -verify-clients。

set -euo pipefail

# 脚本自身版本（与 docs/CHANGELOG_*.md、仓库根目录 VERSION 保持同步）
SCRIPT_VERSION="0.2.9"
SCRIPT_VERSION_DATE="2026-08-14"

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
USE_CURRENT_USER=1       # 默认使用当前用户
CREATE_DEDICATED_USER=0  # 是否强制创建专用用户
RELAX_SOCKET_PERMS=0     # 是否允许放宽 socket 权限（不推荐）
NON_INTERACTIVE=0        # 非交互模式（CI/自动化）
SECURITY_LEVEL="standard" # 安全加固级别：basic|standard|paranoid

IP_ADDR=""
_tmpdir=""               # 安全临时目录（main 中初始化，trap EXIT 自动清理）
AUTO_UFW=0               # 是否自动放行 UFW
DRY_RUN=0                # 只做检查，不执行安装/写入
FORCE=0                  # 强制全量重装
REPAIR=0                 # 仅修复配置（不重装 derper）
CHECK_ONLY=0             # --check 别名（等价于 --dry-run）
ALLOW_NON_GLOBAL_IP=0    # 是否放行私有/保留/文档等非全局可路由 IP（仅内网测试）
DESIRED_CONFIG_OK=0      # 当前 systemd unit 是否与本次目标参数一致
DERPER_VERIFY_CLIENTS_EFFECTIVE=0 # 当前已部署 unit 是否启用了 -verify-clients
CURRENT_DERPER_OWNS_PORTS=0       # 当前监听端口是否来自已运行的 derper 服务

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

脚本版本：${SCRIPT_VERSION}（${SCRIPT_VERSION_DATE}）

选项列表：
用法（向导模式）：sudo bash $0 wizard  [启动交互式配置向导]
用法（命令模式）：sudo bash $0 [--ip 公网IP] [--derp-port 30399] [--stun-port 3478] [--cert-days 365] [--auto-ufw]
               [--goproxy URL] [--gosumdb VALUE] [--gotoolchain auto|local]
               [--no-verify-clients | --force-verify-clients]
               [--region-id 900] [--region-code my-derp] [--region-name "My IP DERP"]
               [--user <username> | --use-current-user]
               [--allow-non-global-ip]
               [--check | --dry-run] [--repair] [--force]
               [--health-check [--metrics-textfile 路径]]
               [--uninstall [--purge | --purge-all]]
               [-V | --version] [-h | --help]

参数说明：
  -V, --version           打印脚本版本并退出。
  -h, --help              显示本帮助并退出。
  --ip                    服务器公网 IPv4（推荐显式指定），缺省自动探测。
                          正式部署必须为全局可路由的公网地址；
                          内网/保留/文档地址默认拒绝，测试需加 --allow-non-global-ip。
  --derp-port             DERP TLS 端口，默认 30399/TCP。
  --stun-port             STUN 端口，默认 3478/UDP（同时写入 derpMap 的 STUNPort）。
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
  --allow-non-global-ip   允许使用私有/保留/文档/组播等非全局可路由 IP（仅内网测试）。
  --security-level LEVEL  安全加固级别：basic|standard|paranoid（默认 standard）。
  --relax-socket-perms    允许临时放宽 tailscaled socket 权限到 0666（不推荐，仅紧急情况）。
  --yes, --non-interactive 非交互模式，自动确认所有选择（适合 CI/自动化脚本）。
  --check, --dry-run      仅进行状态与参数检查，不执行安装/写服务/放行端口等操作。
  --repair                仅修复/重写配置（systemd/证书等），不中断可用的依赖；
                          默认不重装 derper，但若已部署二进制与目标版本不一致，
                          会重新安装以对齐（如 -verify-clients 的版本对齐）。
  --force                 强制全量重装（重新安装 derper、重签证书、重写服务）。
  --derper-version VER    指定 derper 版本（默认 latest），例如 v1.74.1 以确保可复现构建；
                          也接受 Git commit（与 tailscaled 同源对齐时使用）。

  --health-check          输出健康检查摘要（适合 cron 周期探测；不更改系统）。
  --metrics-textfile P    将健康检查结果以 Prometheus 文本格式写入到文件 P。
                          必须与 --health-check 一起使用；
                          建议结合 node_exporter 的 textfile collector 使用。
  --uninstall             停止并卸载 derper systemd 服务（保留二进制与证书）。
  --purge                 必须与 --uninstall 一起使用：额外删除 ${INSTALL_DIR}（证书等）。
  --purge-all             必须与 --uninstall 一起使用：在 --purge 基础上，同时删除 ${BIN_PATH}、
                          /etc/derper/derper.env 和脚本创建的 tailscaled socket drop-in。
                          防火墙规则和用户/组账户需手动确认，不会自动删除。

示例：
  sudo bash $0 --ip 203.0.113.10 --derp-port 30399 --auto-ufw \
    --goproxy https://goproxy.cn,direct --gosumdb sum.golang.google.cn

   # 仅健康检查 + 导出 Prometheus 文本（可配合 cron）
   sudo bash $0 --ip 203.0.113.10 --health-check --metrics-textfile /var/lib/node_exporter/textfile_collector/derper.prom

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
      --ip)
        require_arg_value "$1" "${2-}"
        IP_ADDR="$2"
        shift 2;;
      --derp-port)
        require_arg_value "$1" "${2-}"
        DERP_PORT="$2"
        shift 2;;
      --stun-port)
        require_arg_value "$1" "${2-}"
        STUN_PORT="$2"
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
        shift 1;;
      --force-verify-clients)
        VERIFY_CLIENTS_MODE="on"
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
      --user)
        require_arg_value "$1" "${2-}"
        RUN_USER="$2"
        shift 2;;
      --use-current-user)
        USE_CURRENT_USER=1
        CREATE_DEDICATED_USER=0
        RUN_USER="${SUDO_USER:-${USER:-$(id -un)}}"
        shift 1;;
      --allow-non-global-ip)
        ALLOW_NON_GLOBAL_IP=1
        shift 1;;
      --dedicated-user)
        CREATE_DEDICATED_USER=1
        USE_CURRENT_USER=0
        RUN_USER="derper"
        shift 1;;
      --security-level)
        require_arg_value "$1" "${2-}"
        SECURITY_LEVEL="$2"
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
  if [[ "${PURGE}" -eq 1 || "${PURGE_ALL}" -eq 1 ]]; then
    if [[ "${UNINSTALL}" -ne 1 ]]; then
      echo "[错误] --purge/--purge-all 必须与 --uninstall 一起使用，单独使用不会执行清理。" >&2
      err=1
    fi
  fi
  if [[ -n "${METRICS_TEXTFILE}" && "${HEALTH_CHECK}" -ne 1 ]]; then
    echo "[错误] --metrics-textfile 必须与 --health-check 一起使用（指标由健康检查生成）。" >&2
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

# 读取已安装 derper 二进制的 tailscale.com 模块版本（如 1.80.0）；失败返回空。
get_installed_derper_version() {
  [[ -x "${BIN_PATH}" ]] || { echo ""; return 1; }
  local ver=""
  if command -v go >/dev/null 2>&1; then
    ver=$(go version -m "${BIN_PATH}" 2>/dev/null \
      | awk '/^[[:space:]]*mod[[:space:]]+tailscale\.com([[:space:]]|$)/ {print $3; exit}')
  fi
  if [[ -z "$ver" ]]; then
    # 无 go 时回退：从二进制字符串中抓取常见版本标记
    ver=$(strings "${BIN_PATH}" 2>/dev/null \
      | grep -oE 'tailscale\.com(/cmd/derper)?[[:space:]]+v?[0-9]+\.[0-9]+\.[0-9]+' \
      | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
  fi
  # 不再用裸 semver 回退：Go 工具链版本（go1.22.6）会先被匹配，导致误判已对齐。
  normalize_version_tag "$ver"
}

# 判断是否需要安装/重装 derper：缺失、或目标版本（非 latest）与已安装不一致。
derper_binary_needs_install() {
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
    # 按 Git commit 对齐时，已安装模块版本会记录为伪版本
    # （vX.Y.Z-0.<时间戳>-<commit>）：包含该 commit 即视为同源。
    if [[ "$want" =~ ^[0-9a-f]{7,40}$ ]] && [[ "$have" == *"$want"* ]]; then
      return 1
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

validate_settings() {
  # 端口合法性（10# 强制十进制，避免前导零被当作八进制解析）
  local derp_port_dec stun_port_dec cert_days_dec
  derp_port_dec=0; stun_port_dec=0; cert_days_dec=0
  if [[ "${DERP_PORT}" =~ ^[0-9]+$ ]]; then derp_port_dec=$((10#$DERP_PORT)); fi
  if [[ "${STUN_PORT}" =~ ^[0-9]+$ ]]; then stun_port_dec=$((10#$STUN_PORT)); fi
  if [[ "${CERT_DAYS}" =~ ^[0-9]+$ ]]; then cert_days_dec=$((10#$CERT_DAYS)); fi
  if (( derp_port_dec < 1 || derp_port_dec > 65535 )); then
    echo "[错误] --derp-port 必须为 1-65535 的整数，当前：${DERP_PORT}" >&2
    return 1
  fi
  if (( stun_port_dec < 1 || stun_port_dec > 65535 )); then
    echo "[错误] --stun-port 必须为 1-65535 的整数，当前：${STUN_PORT}" >&2
    return 1
  fi
  if (( cert_days_dec < 1 )); then
    echo "[错误] --cert-days 必须为正整数，当前：${CERT_DAYS}" >&2
    return 1
  fi
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
  # 10# 强制十进制，避免前导零被当作八进制解析
  local region_id_dec=$((10#$REGION_ID))
  if (( region_id_dec < 1 )); then
    echo "[错误] --region-id 必须为正整数：${REGION_ID}" >&2
    return 1
  fi
  # 上游要求 RegionID 能安全放入 JavaScript number（Number.MAX_SAFE_INTEGER = 2^53-1）
  if (( region_id_dec > 9007199254740991 )); then
    echo "[错误] --region-id 超出 JavaScript 安全整数范围（最大 9007199254740991）：${REGION_ID}" >&2
    return 1
  fi
  # 上游约定 900-999 保留给用户自建区域
  if (( region_id_dec < 900 || region_id_dec > 999 )); then
    echo "[警告] --region-id ${REGION_ID} 不在 900-999 范围；上游约定该范围保留给用户自建区域，建议使用 900-999。" >&2
  fi

  # 安全级别前置校验（避免执行完所有安装步骤后才报错）
  case "${SECURITY_LEVEL}" in
    basic|standard|paranoid) ;;
    *) echo "[错误] --security-level 必须为 basic|standard|paranoid，当前：${SECURITY_LEVEL}" >&2; return 1 ;;
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

# 兼容 timeout：优先使用系统 timeout，缺失时用后台进程模拟
_timeout_run() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    "$@" &
    local pid=$!
    ( sleep "$secs" && kill "$pid" 2>/dev/null ) &
    local killer=$!
    wait "$pid" 2>/dev/null
    local rc=$?
    kill "$killer" 2>/dev/null; wait "$killer" 2>/dev/null || true
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

# 当前 SSH 是否走 Tailscale（CGNAT 100.64/10 或 fd7a:115c:a1e0::/48）。
ssh_session_via_tailscale() {
  [[ -n "${SSH_CONNECTION:-}" ]] || return 1
  local src
  src=$(awk '{print $1}' <<<"${SSH_CONNECTION}")
  [[ "$src" == 100.* || "$src" == fd7a:115c:a1e0:* ]]
}

# 重启 tailscaled.socket 以使 drop-in 生效。经由 Tailscale 的 SSH 会话会因此断开，默认跳过。
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
    ss -ltnp 2>/dev/null | grep -E ":${DERP_PORT}([^0-9]|$)" >/dev/null 2>&1 && PORT_TLS_OK=1 || true
    ss -lunp 2>/dev/null | grep -E ":${STUN_PORT}([^0-9]|$)" >/dev/null 2>&1 && PORT_STUN_OK=1 || true
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltnp 2>/dev/null | grep -E ":${DERP_PORT}([^0-9]|$)" >/dev/null 2>&1 && PORT_TLS_OK=1 || true
    netstat -lunp 2>/dev/null | grep -E ":${STUN_PORT}([^0-9]|$)" >/dev/null 2>&1 && PORT_STUN_OK=1 || true
  fi
}

regex_escape() {
  printf '%s' "$1" | sed -e 's/[][\/.^$*+?{}()|]/\\&/g'
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
  config_re=$(regex_escape "${INSTALL_DIR}/derper.json")
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

  echo "$listeners" | grep -E ":${DERP_PORT}([^0-9]|$)" | grep -Eq "(pid[=,]|^|,)${main_pid}([^0-9]|$)|\"derper\"" || return 1
  echo "$listeners" | grep -E ":${STUN_PORT}([^0-9]|$)" | grep -Eq "(pid[=,]|^|,)${main_pid}([^0-9]|$)|\"derper\"" || return 1

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
}

check_cert_status() {
  CERT_PRESENT=0; CERT_SAN_MATCH=0; CERT_EXPIRY_OK=0; CERT_NAMING_OK=0
  local cert_pem key_pem
  cert_pem=$(resolve_disk_cert_pem 2>/dev/null || true)
  key_pem=$(resolve_disk_key_pem 2>/dev/null || true)
  if [[ -n "$cert_pem" && -n "$key_pem" && -f "$cert_pem" && -f "$key_pem" ]]; then
    CERT_PRESENT=1
    # 上游 manual 模式固定读取 <hostname>.crt/.key；旧命名视为需迁移
    if [[ -f "$(derper_manual_cert_file)" && -f "$(derper_manual_key_file)" ]]; then
      CERT_NAMING_OK=1
    fi
    if command -v openssl >/dev/null 2>&1; then
      local ip_re
      ip_re=$(regex_escape "$IP_ADDR")
      if openssl x509 -in "$cert_pem" -noout -text 2>/dev/null | grep -E "IP( Address)?:[[:space:]]*${ip_re}([,[:space:]]|$)" >/dev/null 2>&1; then
        CERT_SAN_MATCH=1
      elif openssl x509 -in "$cert_pem" -noout -ext subjectAltName 2>/dev/null | grep -E "IP(:| Address:)[[:space:]]*${ip_re}([,[:space:]]|$)" >/dev/null 2>&1; then
        CERT_SAN_MATCH=1
      fi
      if openssl x509 -checkend $((30*24*3600)) -in "$cert_pem" -noout >/dev/null 2>&1; then
        CERT_EXPIRY_OK=1
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
  echo "[步骤] 下载安装 Go ${GO_VERSION} (${arch}) 作为基础工具链…"
  curl -fsSL "$url" -o "$tarball"
  
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

install_derper() {
  echo "[步骤] 安装/构建 derper 可执行文件…"
  ensure_go
  # 组装环境：可选 GOPROXY/GOSUMDB，自动工具链（避免被墙/版本不足问题）
  local envs=("GOBIN=/usr/local/bin" "GO111MODULE=on" "GOTOOLCHAIN=${GOTOOLCHAIN_ARG}")
  if [[ -n "${GOPROXY_ARG}" ]]; then envs+=("GOPROXY=${GOPROXY_ARG}"); fi
  if [[ -n "${GOSUMDB_ARG}" ]]; then envs+=("GOSUMDB=${GOSUMDB_ARG}"); fi
  echo "[信息] 安装 derper 版本：${DERPER_VERSION}"
  if ! env "${envs[@]}" go install "tailscale.com/cmd/derper@${DERPER_VERSION}" 2>"${_tmpdir}/derper_install.err"; then
    echo "[错误] go install 失败：" >&2
    sed -n '1,160p' "${_tmpdir}/derper_install.err" >&2 || true
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
  chown root:"$group" "$certs_dir" 2>/dev/null || chown root:root "$certs_dir" 2>/dev/null || true
  chmod 750 "$certs_dir" 2>/dev/null || true

  local cert_file key_file
  cert_file=$(derper_manual_cert_file)
  key_file=$(derper_manual_key_file)
  if [[ -f "$key_file" && ! -L "$key_file" ]]; then
    chown root:"$group" "$key_file" 2>/dev/null || chown root:root "$key_file" 2>/dev/null || true
    chmod 640 "$key_file" 2>/dev/null || true
  fi
  if [[ -f "$cert_file" && ! -L "$cert_file" ]]; then
    chown root:"$group" "$cert_file" 2>/dev/null || chown root:root "$cert_file" 2>/dev/null || true
    chmod 644 "$cert_file" 2>/dev/null || true
  fi
  return 0
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
  local key_tmp cert_tmp cnf_tmp
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

  # 原子替换到最终路径（mv 不沿符号链接写入，并替换残留符号链接本身）
  chmod 600 "$key_tmp" "$cert_tmp" 2>/dev/null || true
  if ! mv -f "$key_tmp" "$key_file" || ! mv -f "$cert_tmp" "$cert_file"; then
    rm -f "$key_tmp" "$cert_tmp" "$cnf_tmp" 2>/dev/null || true
    echo "[错误] 证书文件写入失败：${key_file} / ${cert_file}" >&2
    return 1
  fi
  rm -f "$cnf_tmp" 2>/dev/null || true

  # 兼容旧路径与常见别名（符号链接指向 derper 实际读取的文件）
  ln -sfn "$(basename "$cert_file")" "${INSTALL_DIR}/certs/fullchain.pem"
  ln -sfn "$(basename "$key_file")"  "${INSTALL_DIR}/certs/privkey.pem"
  ln -sfn "$(basename "$cert_file")" "${INSTALL_DIR}/certs/cert.pem"
  ln -sfn "$(basename "$key_file")"  "${INSTALL_DIR}/certs/key.pem"

  # 加固证书目录与私钥权限：root 所有，服务用户仅组内只读
  chmod 600 "${key_file}"
  chmod 644 "${cert_file}"
  harden_cert_dir

  echo "[信息] 证书文件生成于：${cert_file} / ${key_file}"
  echo "[信息] 兼容链接：${INSTALL_DIR}/certs/{fullchain.pem,privkey.pem,cert.pem,key.pem}"
  
  # 生成 derper 配置文件（新版 derper 要求必须指定 -c 参数）
  generate_derper_config
}

# 证书就绪：已兼容则跳过；仅命名过旧则迁移（保留指纹）；否则重签。
# --repair 与默认幂等路径共用，避免 repair 把可迁移证书直接重签导致 ACL 指纹变化。
ensure_compatible_certs() {
  CERTS_CHANGED=0
  if [[ ${CERT_PRESENT:-0} -eq 1 && ${CERT_SAN_MATCH:-0} -eq 1 && ${CERT_EXPIRY_OK:-0} -eq 1 && ${CERT_NAMING_OK:-0} -eq 1 ]]; then
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
      local _mig_cert_tmp _mig_key_tmp
      _mig_cert_tmp=$(mktemp "${INSTALL_DIR}/certs/.derper-cert.XXXXXX") || return 1
      _mig_key_tmp=$(mktemp "${INSTALL_DIR}/certs/.derper-key.XXXXXX") || { rm -f "$_mig_cert_tmp"; return 1; }
      cp -a "$old_cert" "$_mig_cert_tmp" && mv -f "$_mig_cert_tmp" "$new_cert" || { rm -f "$_mig_cert_tmp" "$_mig_key_tmp"; echo "[错误] 证书迁移失败。" >&2; return 1; }
      cp -a "$old_key" "$_mig_key_tmp" && mv -f "$_mig_key_tmp" "$new_key" || { rm -f "$_mig_cert_tmp" "$_mig_key_tmp"; echo "[错误] 密钥迁移失败。" >&2; return 1; }
      ln -sfn "$(basename "$new_cert")" "${INSTALL_DIR}/certs/fullchain.pem"
      ln -sfn "$(basename "$new_key")"  "${INSTALL_DIR}/certs/privkey.pem"
      ln -sfn "$(basename "$new_cert")" "${INSTALL_DIR}/certs/cert.pem"
      ln -sfn "$(basename "$new_key")"  "${INSTALL_DIR}/certs/key.pem"
      chmod 600 "$new_key"
      chmod 644 "$new_cert"
      harden_cert_dir || true
      echo "[信息] 已迁移证书到上游命名：${new_cert} / ${new_key}"
      CERT_NAMING_OK=1
      CERTS_CHANGED=1
      return 0
    fi
  fi
  echo "[警告] 即将重签证书：CertName 指纹会变化，请同步更新 ACL。" >&2
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
  local config_path="${INSTALL_DIR}/derper.json"
  mkdir -p "${INSTALL_DIR}"
  if [[ -f "$config_path" ]]; then
    local config_trim
    config_trim=$(tr -d ' \t\r\n' <"$config_path" 2>/dev/null || true)
    if [[ -z "$config_trim" || "$config_trim" == "{}" ]]; then
      rm -f "$config_path"
      echo "[信息] 已移除旧的空 derper 配置；服务启动时将自动生成节点私钥：${config_path}"
    else
      chmod 600 "$config_path"
      echo "[信息] 保留现有 derper 配置：${config_path}"
    fi
  else
    echo "[信息] derper 将在首次启动时自动生成节点私钥配置：${config_path}"
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

  # 属主匹配
  local owner
  owner=$(stat -c '%U' "$sock" 2>/dev/null || true)
  if [[ "$owner" == "$user" ]]; then
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

  # 实际探测：以目标用户执行 test -r/-w（最权威）
  if command -v runuser >/dev/null 2>&1; then
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
    # 证书目录必须收回 root 所有，服务账户只读（防止符号链接覆盖攻击）
    harden_cert_dir || true
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
  # 证书目录必须收回 root 所有，服务账户只读（防止符号链接覆盖攻击）
  harden_cert_dir || true
}

# 启动后强制健康验证：active 状态、TLS/STUN 端口监听、TLS 握手、进程存活。
# systemctl start/restart 即时返回成功并不代表服务真正可用（可能启动后立即崩溃）。
service_verified_running() {
  command -v systemctl >/dev/null 2>&1 || return 1
  local tries=0
  while (( tries < 15 )); do
    if systemctl is-active --quiet derper 2>/dev/null; then
      break
    fi
    sleep 1
    ((tries++))
  done
  systemctl is-active --quiet derper 2>/dev/null || return 1
  # 防止启动后立即崩溃：短暂等待后复核 active 状态
  sleep 2
  systemctl is-active --quiet derper 2>/dev/null || return 1

  # TLS/STUN 端口确实监听
  check_ports_status
  [[ "${PORT_TLS_OK:-0}" -eq 1 && "${PORT_STUN_OK:-0}" -eq 1 ]] || return 1

  # TLS 握手成功（优先本机回环，避免 NAT hairpin 误报）
  command -v openssl >/dev/null 2>&1 || return 1
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

  # derper 主进程仍在运行（未崩溃退出）
  local main_pid
  main_pid=$(systemctl show -p MainPID --value derper 2>/dev/null || echo "0")
  [[ -n "$main_pid" && "$main_pid" != "0" ]] || return 1
  kill -0 "$main_pid" 2>/dev/null || return 1
  return 0
}

# 失败回滚：恢复备份的旧 unit，并尝试重新启动旧服务（若此前在运行）后验证，
# 保证“自动故障恢复”不只是还原文件、而是真正恢复可用状态。
rollback_previous_unit() {
  local backup="$1" was_running="${2:-0}"
  if [[ -z "$backup" || ! -f "$backup" ]]; then
    if [[ "$was_running" -ne 1 ]]; then
      # 全新安装失败且无备份：停止残留的半启动状态
      systemctl stop derper 2>/dev/null || true
      echo "[信息] 新安装启动失败，服务已停止；请排查后重新运行本脚本。" >&2
    else
      echo "[警告] 无可用备份单元，旧服务可能已停止；请立即检查 systemctl status derper。" >&2
    fi
    return 1
  fi
  echo "[步骤] 正在恢复备份的 systemd 单元：${backup}" >&2
  if ! cp -a "$backup" "${SERVICE_PATH}" 2>/dev/null; then
    echo "[错误] 恢复备份单元失败，旧服务可能处于停止状态。" >&2
    return 1
  fi
  systemctl daemon-reload 2>/dev/null || true
  if [[ "$was_running" -eq 1 ]]; then
    echo "[步骤] 原服务此前在运行，尝试按旧配置重新启动并验证…" >&2
    if systemctl restart derper 2>/dev/null || systemctl start derper 2>/dev/null; then
      if service_verified_running; then
        echo "[信息] 已恢复旧服务并通过健康验证。" >&2
        return 0
      fi
    fi
    echo "[错误] 旧配置未能重新启动并通过验证；服务当前可能处于停止状态。" >&2
    echo "  请立即执行 systemctl status derper 与 journalctl -u derper -n 100 排查。" >&2
    return 1
  fi
  systemctl stop derper 2>/dev/null || true
  echo "[信息] 已恢复旧单元；新配置启动失败，服务保持停止状态。" >&2
  return 1
}

write_systemd_service() {
  echo "[步骤] 写入 systemd 服务单元：${SERVICE_PATH}…"
  prepare_derper_config
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

  # 根据配置决定是否启用客户端校验
  local verify_flag=""
  case "${VERIFY_CLIENTS_MODE}" in
    on) verify_flag="-verify-clients" ;;
    off) verify_flag="" ;;
  esac

  # 先创建/校准运行用户，再处理 socket 权限（避免 usermod 时用户尚不存在）
  setup_service_user
  
  # 检测 tailscaled socket 路径和权限（用于 verify-clients）
  local tailscale_socket_group=""
  local socket_needs_permission_fix=0
  local tailscaled_socket_unit_has_override=0
  local tailscaled_socket_override_group=""
  local need_add_user_to_tailscale_group=0
  local socket_path=""  # 在函数级别初始化，避免后续引用时未定义
  if [[ "${VERIFY_CLIENTS_MODE}" == "on" ]]; then
    if [[ -S /run/tailscale/tailscaled.sock ]]; then
      socket_path="/run/tailscale/tailscaled.sock"
    elif [[ -S /var/run/tailscale/tailscaled.sock ]]; then
      socket_path="/var/run/tailscale/tailscaled.sock"
    fi
    
    if [[ -n "$socket_path" ]]; then
      # 获取 socket 的所属组和权限
      tailscale_socket_group=$(stat -c '%G' "$socket_path" 2>/dev/null || true)
      local socket_perms
      socket_perms=$(stat -c '%a' "$socket_path" 2>/dev/null || true)

      # 若运行用户已能读写 socket（含 0666/world 可写），则跳过侵入式改组/重启
      if user_can_access_socket "$RUN_USER" "$socket_path"; then
        echo "[信息] ${RUN_USER} 已可访问 tailscaled socket（${socket_path}，组=${tailscale_socket_group:-?}，权限=${socket_perms:-?}），跳过权限修复。"
        # 仍记录组名，便于 SupplementaryGroups（若用户已在该组）
      else
        socket_needs_permission_fix=1
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
              local _do_restart=1
              if ssh_session_via_tailscale; then
                echo "[警告] 检测到当前 SSH 连接可能经由 Tailscale（${SSH_CONNECTION%% *}）。" >&2
                echo "  重启 tailscaled 将断开此连接，可能导致脚本中断和服务器不可达。" >&2
                if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
                  echo "[跳过] 非交互模式下跳过 tailscaled 重启，将使用备选方案配置 socket 权限。" >&2
                  _do_restart=0
                else
                  local _ts_restart_confirm=""
                  if ! read -r -p "  是否确认重启 tailscaled？(yes/no): " _ts_restart_confirm; then
                    echo "[跳过] 输入已结束，跳过 tailscaled 重启，将使用备选方案。" >&2
                    _do_restart=0
                  fi
                  if [[ "$_ts_restart_confirm" != "yes" ]]; then
                    echo "[跳过] 已取消 tailscaled 重启，将使用备选方案。" >&2
                    _do_restart=0
                  fi
                fi
              fi

              if [[ "$_do_restart" -eq 1 ]]; then
                systemctl restart tailscaled 2>/dev/null || true
                # 轮询等待 socket 恢复（替代固定 sleep，避免竞态）
                local _wait_count=0
                while [[ ! -S "$socket_path" ]] && ((_wait_count < 10)); do
                  sleep 1
                  ((_wait_count++))
                done
                if [[ ! -S "$socket_path" ]]; then
                  echo "[警告] tailscaled 重启后 socket 未在 10 秒内恢复：$socket_path" >&2
                fi
                # 重读 socket 组与权限
                tailscale_socket_group=$(stat -c '%G' "$socket_path" 2>/dev/null || echo "$tailscale_socket_group")
                socket_perms=$(stat -c '%a' "$socket_path" 2>/dev/null || echo "$socket_perms")
                echo "[信息] tailscaled 本地 API 刷新后：组=${tailscale_socket_group} 权限=${socket_perms}"
                if user_can_access_socket "$RUN_USER" "$socket_path"; then
                  socket_needs_permission_fix=0
                  echo "[信息] 重启后 ${RUN_USER} 已可访问 socket，跳过后续侵入式修复。"
                fi
              fi
            fi
          fi
        fi

        if [[ "$socket_needs_permission_fix" -eq 1 ]]; then
          # 将 derper 用户加入 tailscale 组（若存在）
          if getent group tailscale >/dev/null 2>&1; then
            need_add_user_to_tailscale_group=1
            usermod -a -G tailscale "$RUN_USER" 2>/dev/null || true
          fi
          # 优先使用 systemd 覆盖 tailscaled.socket 的组与权限（更安全、持久）
          if command -v systemctl >/dev/null 2>&1 && systemctl cat tailscaled.socket >/dev/null 2>&1; then
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
            if restart_tailscaled_socket_unit; then
              tailscaled_socket_unit_has_override=1
              echo "[信息] 已为 tailscaled.socket 应用覆盖：SocketGroup=${tailscaled_socket_override_group} SocketMode=0660"
              # 同步将 derper 用户加入该组（若为 tailscale 组）
              if [[ "$tailscaled_socket_override_group" == "tailscale" ]]; then
                usermod -a -G tailscale "$RUN_USER" 2>/dev/null || true
              fi
            else
              echo "[警告] tailscaled.socket 覆盖未能立即生效（重启被跳过或失败），将回退到临时权限调整或 ACL。" >&2
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
              if ! user_can_access_socket "$RUN_USER" "$socket_path"; then
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
      fi
    else
      echo "[警告] 未检测到 tailscaled socket，-verify-clients 可能无法正常工作" >&2
    fi
  fi

  # 非 systemd 环境前置拦截并给出手动运行示例
  if ! command -v systemctl >/dev/null 2>&1; then
    local manual_cmd="${BIN_PATH} -c ${INSTALL_DIR}/derper.json"
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
    exit 1
  fi

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

  # 动态构建 ExecStart 命令参数（每个参数独立为数组元素，避免空格拼接错误）
  local exec_args=("${BIN_PATH}" "-c" "${INSTALL_DIR}/derper.json")
  exec_args+=("-hostname" "${IP_ADDR}")
  exec_args+=("-certmode" "manual")
  exec_args+=("-certdir" "${INSTALL_DIR}/certs")
  exec_args+=("-http-port" "-1")
  exec_args+=("${listen_args[@]}")
  exec_args+=("${stun_args[@]}")
  [[ -n "${verify_flag}" ]] && exec_args+=("${verify_flag}")

  # 根据 verify-clients 与已探测的 socket 路径，传入 derper 实际支持的 -socket 参数。
  if [[ "${VERIFY_CLIENTS_MODE}" == "on" ]]; then
    local chosen_socket=""
    if [[ -S /run/tailscale/tailscaled.sock ]]; then
      chosen_socket="/run/tailscale/tailscaled.sock"
    elif [[ -S /var/run/tailscale/tailscaled.sock ]]; then
      chosen_socket="/var/run/tailscale/tailscaled.sock"
    elif [[ -n "$socket_path" ]]; then
      chosen_socket="$socket_path"
    fi
    # 即便未检测到，也显式使用常见路径。
    [[ -z "$chosen_socket" ]] && chosen_socket="/run/tailscale/tailscaled.sock"
    if derper_supports_socket_flag; then
      exec_args+=("-socket" "${chosen_socket}")
    elif [[ "$chosen_socket" != "/run/tailscale/tailscaled.sock" ]]; then
      echo "[错误] 当前 derper 不支持 -socket，无法使用非默认 tailscaled socket：${chosen_socket}" >&2
      return 1
    fi
  fi

  # 将参数数组转换为单行命令字符串
  local exec_start_line="${exec_args[*]}"

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
    standard)
      hardening_options="$hardening_standard"
      echo "[信息] 使用 standard 安全级别（推荐）"
      ;;
    paranoid)
      hardening_options="$hardening_paranoid"
      echo "[信息] 使用 paranoid 安全级别（最严格加固）"
      ;;
    *)
      echo "[错误] 无效的安全级别：${SECURITY_LEVEL}" >&2
      echo "  可选值：basic | standard | paranoid" >&2
      exit 1
      ;;
  esac

  # 构建 supplementary groups 行（避免空行）
  local supplementary_groups_section=""
  if [[ -n "${supplementary_groups_line}" ]]; then
    supplementary_groups_section="
${supplementary_groups_line}"
  fi

  # 写入前备份旧 unit，便于失败回滚
  local unit_backup=""
  if [[ -f "${SERVICE_PATH}" ]]; then
    unit_backup="${SERVICE_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${SERVICE_PATH}" "$unit_backup" 2>/dev/null || unit_backup=""
    if [[ -n "$unit_backup" ]]; then
      echo "[信息] 已备份旧 systemd 单元：$unit_backup"
    fi
  fi

  cat >"${SERVICE_PATH}" <<SERVICE
[Unit]
Description=Tailscale DERP (derper) with self-signed IP cert
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service
StartLimitBurst=5
StartLimitIntervalSec=60

[Service]
Type=simple
User=${RUN_USER}
Group=${run_group}${supplementary_groups_section}

# 环境变量（支持敏感配置）
EnvironmentFile=-/etc/derper/derper.env

ExecStart=${exec_start_line}
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

  # 尝试启动或重启服务，确保修复/重写后的 unit 和证书立即生效。
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

  # start/restart 即时返回成功 ≠ 服务健康：必须验证 active/端口监听/TLS 握手/进程存活，
  # 否则“启动后立即崩溃”会被误判为部署成功。
  if [[ "${service_started}" -eq 1 ]]; then
    if ! service_verified_running; then
      echo "[警告] 服务启动命令成功，但未通过健康验证（active/端口/TLS/进程）。" >&2
      service_started=0
    fi
  fi

  if [[ "${service_started}" -ne 1 ]]; then
    echo "[警告] 服务启动失败，可能是某些安全选项不兼容当前系统" >&2
    
    # 检查是否是 MemoryDenyWriteExecute 导致的问题（Go 程序常见）
    if [[ "${SECURITY_LEVEL}" == "paranoid" ]]; then
      echo "[步骤] 尝试禁用 MemoryDenyWriteExecute 选项重试" >&2
      # 删除加固项，并更新注释标记，避免漂移检测把“已降级”误判为完整 paranoid
      sed -i.bak \
        -e '/^MemoryDenyWriteExecute=/d' \
        -e 's/# 安全加固（级别：paranoid）/# 安全加固（级别：paranoid；已禁用 MemoryDenyWriteExecute）/' \
        "${SERVICE_PATH}" && rm -f "${SERVICE_PATH}.bak"
      systemctl daemon-reload
      
      systemctl enable derper >/dev/null 2>&1 || true
      local degraded_ok=0
      if systemctl restart derper 2>/dev/null || systemctl start derper 2>/dev/null; then
        if service_verified_running; then
          degraded_ok=1
          echo "[信息] 服务已成功启动（已禁用 MemoryDenyWriteExecute；unit 已标记为 paranoid 降级）"
        fi
      fi
      if [[ "$degraded_ok" -ne 1 ]]; then
        echo "[警告] 降级后服务仍未通过健康验证，开始回滚。" >&2
        rollback_previous_unit "$unit_backup" "$was_running" || true
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
      rollback_previous_unit "$unit_backup" "$was_running" || true
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

  # 主机与云层面加固建议（公网中继的关键风险不在 DERP 协议，而在主机本身）
  echo ""
  echo "[建议] 主机加固（公网中继关键项）："
  echo "  - 云安全组入方向只放行 ${DERP_PORT}/tcp 与 ${STUN_PORT}/udp；其余端口（尤其 22/tcp）不要对 0.0.0.0/0 开放。"
  echo "  - SSH 优先走 Tailscale（sshd 只监听 tailscale IP），并保留云厂商 VNC/控制台兜底；"
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

  echo "- DERP/STUN 协议级诊断（若工具可用）："
  local derp_probe_done=0
  if command -v tailscale >/dev/null 2>&1; then
    if tailscale debug derp 2>/dev/null | head -n 40; then
      derp_probe_done=1
    elif tailscale netcheck 2>/dev/null | sed -n '1,40p'; then
      derp_probe_done=1
    fi
  fi
  if [[ "$derp_probe_done" -ne 1 ]]; then
    echo "  [提示] 本检查仅覆盖端口监听与 TLS 握手，不等于完整 DERP/STUN/Tailnet 连通性验证。"
    echo "         建议在客户端执行：tailscale debug derp / tailscale netcheck / derpprobe"
  fi
}

# 判断 ss/netstat 输出中某端口是否由 derper 占用（旧部署可能只听 TLS、没有 STUN）。
port_listening_owned_by_derper() {
  local listening="$1" port="$2" main_pid="${3:-}"
  local lines
  lines=$(printf '%s\n' "$listening" | grep -E ":${port}([^0-9]|$)" || true)
  [[ -n "$lines" ]] || return 1
  printf '%s\n' "$lines" | grep -Fq '"derper"' && return 0
  if [[ -n "$main_pid" && "$main_pid" != "0" ]] &&
     printf '%s\n' "$lines" | grep -Eq "(pid[=,]|^|,)${main_pid}([^0-9]|$)"; then
    return 0
  fi
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
  local derp_lines stun_lines
  derp_lines=$(printf '%s\n' "$listening" | grep -E ":${DERP_PORT}([^0-9]|$)" || true)
  stun_lines=$(printf '%s\n' "$listening" | grep -E ":${STUN_PORT}([^0-9]|$)" || true)

  if [[ -n "$derp_lines" ]]; then
    if port_listening_owned_by_derper "$listening" "${DERP_PORT}" "$main_pid"; then
      echo "[信息] TCP 端口 ${DERP_PORT} 当前由 derper 占用，允许修复/重启流程继续。"
    else
      echo "[错误] 检测到 TCP 端口 ${DERP_PORT} 已被占用。请更换 --derp-port 或释放占用进程：" >&2
      printf '%s\n' "$derp_lines" | sed -n '1,200p' >&2 || true
      conflict=1
    fi
  fi
  if [[ -n "$stun_lines" ]]; then
    if port_listening_owned_by_derper "$listening" "${STUN_PORT}" "$main_pid"; then
      echo "[信息] UDP 端口 ${STUN_PORT} 当前由 derper 占用，允许修复/重启流程继续。"
    else
      echo "[错误] 检测到 UDP 端口 ${STUN_PORT} 已被占用。请更换 --stun-port 或释放占用进程：" >&2
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
  if command -v ss >/dev/null 2>&1; then
    listening=$(ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' \
      | grep -E ':[0-9]+$' \
      | grep -vE '^127\.0\.0\.1:|^\[::1\]:|^::1:' \
      | grep -vE ":${DERP_PORT}$" || true)
  elif command -v netstat >/dev/null 2>&1; then
    listening=$(netstat -ltn 2>/dev/null | awk 'NR>2 && $1 ~ /^tcp6?/ {print $4}' \
      | grep -E ':[0-9]+$' \
      | grep -vE '^127\.0\.0\.1:|^\[::1\]:|^::1:' \
      | grep -vE ":${DERP_PORT}$" || true)
  fi
  EXTRA_LISTENERS=$(printf '%s\n' "$listening" | sort -u | grep -v '^$' || true)
  if [[ -n "$EXTRA_LISTENERS" ]]; then
    echo "[警告] 检测到除 DERP 端口外，仍有面向非回环地址的 TCP 监听端口：" >&2
    printf '%s\n' "$EXTRA_LISTENERS" | sed 's/^/  - /' >&2
    echo "  公网 DERP 服务器建议单机单用途；每个额外端口都会扩大暴露面。" >&2
    if printf '%s\n' "$EXTRA_LISTENERS" | grep -qE '(^|:)22$|^\[::\]:22$'; then
      echo "  尤其注意 22/tcp（SSH）：建议云安全组不要对 0.0.0.0/0 放行，SSH 优先走 Tailscale 或限源 IP。" >&2
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
1) 更新 ACL：把上面的 derpMap 片段粘贴到管理后台 Access Controls 并保存；
   - 若你修改了端口，请同步更新 "DERPPort" 与 "STUNPort"。
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
     若显示 succeeded / open，一般表示 STUN 端口可达（注意：nc -zvu 可能假阳性）。
   - 更可靠：使用上游工具 stunc / derpprobe，或：
       tailscale debug derp
       tailscale netcheck

4) 常见排查：
   - derper 启动失败：journalctl -u derper -f 查看报错（证书路径/端口占用/参数）。
   - 证书文件名：derper manual 模式读取 /opt/derper/certs/<公网IP>.crt 与 .key。
   - 客户端未走你的 DERP：确认 derpMap 已保存、HostName 为公网 IP、CertName 指纹与在线证书一致。
   - 自动重签会改变 CertName：请先更新 ACL 再重启服务，或接受短暂中断后粘贴新指纹。
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

1) 在本机执行（或在管理后台 Machines 页给该节点打 tag）：
     sudo tailscale set --tags=tag:derper-server

2) 在管理后台 Access Controls 中声明 tag 所有者：
     "tagOwners": {
       "tag:derper-server": ["autogroup:admin"]
     }

3) 不要在任何放行规则里把 "tag:derper-server" 写成 "src"；
   确需从服务器访问内网资源时，再加最小规则（如仅允许访问特定设备/端口）。
====================================================================================
EOF
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
  return 0
}

health_check_report() {
  # 检查关键依赖工具
  local missing_tools=()
  command -v timeout >/dev/null 2>&1 || missing_tools+=(timeout)
  command -v openssl >/dev/null 2>&1 || missing_tools+=(openssl)
  if [[ ${#missing_tools[@]} -gt 0 ]]; then
    echo "[提示] 健康检查建议安装以下工具以获得完整功能：${missing_tools[*]}" >&2
  fi

  infer_ip_from_existing_deployment || true
  validate_settings || true
  check_tailscale_status
  check_derper_status
  check_cert_status
  check_live_cert_status
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
  [[ $PURE_IP_OK -eq 1 ]] && echo "✅ 配置：当前 unit 为纯 IP 模式" || echo "❌ 配置：当前 unit 不是纯 IP 模式"
  [[ $DESIRED_CONFIG_OK -eq 1 ]] && echo "✅ 配置：当前 unit 与本次目标参数一致" || echo "❌ 配置：当前 unit 与本次目标参数不一致，建议执行 --repair"
  [[ $CERT_LIVE_MATCH -eq 1 ]] && echo "✅ 证书：在线服务与磁盘证书一致" || echo "❌ 证书：在线服务未提供当前磁盘证书（或握手失败）"
  [[ ${CERT_NAMING_OK:-0} -eq 1 ]] && echo "✅ 证书：命名兼容 derper manual（<hostname>.crt/.key）" || echo "❌ 证书：命名不兼容（缺少 <IP>.crt/.key，derper 可能自签另一套）"
  if [[ $DERPER_VERIFY_CLIENTS_EFFECTIVE -eq 1 ]]; then
    echo "ℹ️  客户端校验：当前 unit 已启用 -verify-clients"
  else
    echo "ℹ️  客户端校验：当前 unit 未启用 -verify-clients"
  fi

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
  rss_kb=0
  pidlist=$(pgrep -x derper 2>/dev/null | xargs || true)
  if [[ -n "$pidlist" ]]; then
    rss_kb=$(ps -o rss= -p $pidlist 2>/dev/null | awk '{s+=$1} END{print s+0}')
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

  # 导出 Prometheus 文本（可被 node_exporter textfile collector 收集）
  if [[ -n "${METRICS_TEXTFILE}" ]]; then
    if write_prometheus_metrics "${METRICS_TEXTFILE}" "$days_left" "$rss_kb"; then
      echo "[信息] 已写入 Prometheus 指标：${METRICS_TEXTFILE}"
    else
      echo "[警告] Prometheus 指标写入失败：${METRICS_TEXTFILE}（建议使用 sudo 或选择可写路径）" >&2
    fi
  fi
}

write_prometheus_metrics() {
  local path="$1" days_left="$2" rss_kb="$3"
  local dir base tmp
  dir=$(dirname "$path")
  base=$(basename "$path")
  mkdir -p "$dir" 2>/dev/null || true
  if ! tmp=$(mktemp "${dir}/.${base}.tmp.XXXXXX" 2>/dev/null); then
    echo "[警告] 无法在指标目录创建安全临时文件：${dir}" >&2
    return 1
  fi
  local overall=0 cert_live=0
  if health_is_ok; then overall=1; fi
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

    echo "# HELP derper_process_rss_bytes Total RSS of derper process in bytes"
    echo "# TYPE derper_process_rss_bytes gauge"
    if [[ -n "$rss_kb" ]]; then
      echo "derper_process_rss_bytes $((rss_kb*1024))"
    else
      echo "derper_process_rss_bytes 0"
    fi
  } >"$tmp"; then
    echo "[警告] Prometheus 指标写入临时文件失败：$tmp（权限或路径问题）" >&2
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  chmod 644 "$tmp" 2>/dev/null || true
  if ! mv -f "$tmp" "$path" 2>/dev/null; then
    echo "[警告] Prometheus 指标写入成功但无法移动到目标路径：$path" >&2
    echo "  可能原因：跨文件系统、目录权限不足。请确保路径可写。" >&2
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
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

  local scenario="" account_pref="" port_choice="" verify_choice="" region_choice=""
  local execute="" user_ip="" final_confirm=""

  # 问题1：使用场景
  echo "1. 您的使用场景？"
  echo "   a) 个人测试/学习"
  echo "   b) 小团队（<10人）"
  echo "   c) 生产环境"
  read -r -p "   请选择 (a/b/c): " scenario || { echo "[中止] 输入已结束，退出向导。" >&2; return 1; }
  
  # 问题2：账户偏好
  echo ""
  echo "2. 账户管理偏好？"
  echo "   a) 简单优先（使用当前账户）"
  echo "   b) 安全优先（创建专用账户）"
  read -r -p "   请选择 (a/b): " account_pref || { echo "[中止] 输入已结束，退出向导。" >&2; return 1; }
  
  # 问题3：端口选择
  echo ""
  echo "3. DERP 端口？"
  echo "   a) 443（推荐，防火墙友好）"
  echo "   b) 30399（默认，避免与其他服务冲突）"
  read -r -p "   请选择 (a/b): " port_choice || { echo "[中止] 输入已结束，退出向导。" >&2; return 1; }
  
  # 问题4：客户端验证
  echo ""
  echo "4. 是否启用客户端验证？"
  echo "   a) 是（推荐，更安全）- 需要本地 tailscaled 已登录"
  echo "   b) 否（仅测试环境）"
  read -r -p "   请选择 (a/b): " verify_choice || { echo "[中止] 输入已结束，退出向导。" >&2; return 1; }
  
  # 问题5：网络环境
  echo ""
  echo "5. 服务器是否位于中国大陆？（用于 Go 代理加速）"
  echo "   a) 是（推荐，配置 goproxy.cn）"
  echo "   b) 否（全球环境）"
  read -r -p "   请选择 (a/b): " region_choice || { echo "[中止] 输入已结束，退出向导。" >&2; return 1; }
  
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
    rm -rf "${_tmpdir}"
  fi
  trap - EXIT
  _tmpdir=""
}

main() {
  # 创建安全临时目录（防止 /tmp 可预测路径符号链接攻击，CWE-377）
  _tmpdir=$(mktemp -d /tmp/derper-deploy.XXXXXXXXXX)
  trap 'rm -rf "$_tmpdir"' EXIT

  # 特殊子命令处理：先记录 wizard，再解析其后的通用参数。
  local wizard_mode=0
  if [[ "${1:-}" == "wizard" ]]; then
    wizard_mode=1
    shift
  fi
  
  parse_args "$@"

  # 参数组合校验：--purge 需配合 --uninstall、--metrics-textfile 需配合 --health-check、
  # --force/--repair/--uninstall/--check 等互斥组合直接报错，避免静默取分支或选项被忽略。
  if ! validate_arg_combos; then
    echo "[错误] 参数组合不合法，请检查选项组合。" >&2
    exit 1
  fi

  if [[ "${wizard_mode}" -eq 1 ]]; then
    deployment_wizard
    exit 0
  fi

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
  # --health-check（cron）：不打外网，优先从已部署 unit 推断 IP
  # --check/--dry-run：IP 探测可容错；但参数校验失败时最终必须非 0 退出
  local check_validate_failed=0
  if [[ "${HEALTH_CHECK}" -eq 1 ]]; then
    infer_ip_from_existing_deployment || true
  else
    detect_public_ip || true
  fi
  if ! validate_settings; then
    check_validate_failed=1
    if [[ "${DRY_RUN}" -ne 1 && "${CHECK_ONLY}" -ne 1 && "${HEALTH_CHECK}" -ne 1 ]]; then
      echo "[错误] 参数校验失败，请检查 IP、端口等配置" >&2
      exit 1
    fi
    echo "[警告] 参数校验失败；检查模式将继续输出状态，但最终退出码为失败。" >&2
  fi

  # 收集当前状态
  check_tailscale_status
  check_derper_status
  check_cert_status
  check_live_cert_status

  # 健康检查模式（仅输出状态/指标，不变更系统）
  if [[ "${HEALTH_CHECK}" -eq 1 ]]; then
    health_check_report
    # 根据关键项给出退出码：全部健康返回 0，否则 1
    local ok=1
    if [[ "$check_validate_failed" -eq 0 ]] && health_is_ok; then ok=0; fi
    exit $ok
  fi

  if [[ "${DRY_RUN}" -eq 1 || "${CHECK_ONLY}" -eq 1 ]]; then
    local ip_show="<未探测到>"
    [[ -n "${IP_ADDR}" ]] && ip_show="${IP_ADDR}"
    echo "[检查] 参数与环境状态总结："
    echo "- 公网 IP：${ip_show}"
    echo "- DERP 端口：${DERP_PORT}/tcp；STUN 端口：${STUN_PORT}/udp"
    echo "- tailscale：安装=${TS_INSTALLED} 运行=${TS_RUNNING} 版本=${TS_VERSION:-<未知>} (>=${REQUIRED_TS_VER}) 满足=${TS_VER_OK}"
    echo "- derper：二进制=${DERPER_BIN} 服务文件=${DERPER_SERVICE_PRESENT} 运行=${DERPER_RUNNING}"
    local derper_installed_ver=""
    derper_installed_ver=$(get_installed_derper_version 2>/dev/null || true)
    echo "- derper 版本：已安装=${derper_installed_ver:-<未知>} 目标=${DERPER_VERSION}"
    echo "- 端口监听：TLS=${PORT_TLS_OK} STUN=${PORT_STUN_OK}"
    echo "- 纯 IP 配置判定（基于 unit）：${PURE_IP_OK}"
    echo "- 目标配置匹配（基于 unit）：${DESIRED_CONFIG_OK}"
    echo "- 证书：存在=${CERT_PRESENT} 命名兼容=${CERT_NAMING_OK:-0} SAN匹配IP=${CERT_SAN_MATCH} 30天内不过期=${CERT_EXPIRY_OK}"
    echo "- 客户端校验模式：目标=${VERIFY_CLIENTS_MODE} 已部署=${DERPER_VERIFY_CLIENTS_EFFECTIVE}"
    # 展示将要使用的运行用户与组（若用户尚未创建则组名以用户名代替）
    local chk_group
    chk_group=$(id -g -n "$RUN_USER" 2>/dev/null || echo "$RUN_USER")
    echo "- 运行用户：${RUN_USER}（组：${chk_group}）"

    local suggest="--repair"
    if [[ "$check_validate_failed" -eq 0 ]] && health_is_ok; then
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
    install_deps
    install_derper
    generate_selfsigned_cert
    check_port_conflicts
    write_systemd_service
    print_firewall_tips
    runtime_checks
  elif [[ "${REPAIR}" -eq 1 ]]; then
    install_deps
    if [[ "$need_derper_install" -eq 1 ]]; then
      install_derper
    fi
    ensure_compatible_certs || exit 1
    check_port_conflicts
    write_systemd_service
    print_firewall_tips
    runtime_checks
  else
    # 默认幂等：按需修复
    local changed=0
    local service_reload_needed=0
    if [[ "$need_derper_install" -eq 1 || $DERPER_BIN -ne 1 ]]; then
      install_deps
      install_derper; changed=1; service_reload_needed=1
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
      echo "✅ 已就绪：检测到 derper 正在以纯 IP 模式运行，跳过安装。"
      exit 0
    fi
    print_firewall_tips
    runtime_checks
  fi

  finalize_deployment_report || exit 1
}

# 部署收尾：输出基于 CertName 的安全 derpMap 与验证步骤。
# 若无法取得证书指纹，宁可失败并要求排查 TLS，也不输出 InsecureForTests 配置：
# 上游明确说明该字段仅用于单元测试，用户不应在生产配置中设置。
finalize_deployment_report() {
  local FP
  FP=$(live_cert_sha256_raw || true)
  if [[ -z "$FP" ]]; then FP=$(journal_certname_raw || true); fi
  if [[ -z "$FP" ]]; then FP=$(cert_file_sha256_raw || true); fi
  if [[ -n "$FP" ]]; then
    print_acl_snippet_cert "${IP_ADDR}" "${DERP_PORT}" "$FP"
    echo "[信息] 已基于实际在线证书指纹生成片段：sha256-raw:${FP}"
    print_client_verify_steps
    print_server_node_acl_advice

    cat <<INFO
完成：DERP 服务已部署/修复并尝试运行。
- 服务：systemctl status derper
- 日志：journalctl -u derper -f
- 证书：$(derper_manual_cert_file) / $(derper_manual_key_file)（上游 derper manual 模式读取；兼容链接 fullchain.pem/privkey.pem）
- 配置：${INSTALL_DIR}/derper.json

在 Tailscale 后台粘贴 derpMap 后，客户端数十秒内会自动下发。
若本次重签了证书，请立即用新的 CertName 更新 ACL，避免短暂中断后无法接入。
INFO
    return 0
  fi

  cat >&2 <<EOT
[错误] 部署步骤已执行，但无法获取证书指纹，无法生成基于 CertName 的安全 derpMap。

为安全起见，脚本不会输出 InsecureForTests 配置：
上游明确说明该字段仅用于单元测试，用户不应设置（设置后将关闭 TLS 证书校验，
等同于明文传输，参考 https://github.com/tailscale/tailscale/blob/main/tailcfg/derpmap.go）。

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
