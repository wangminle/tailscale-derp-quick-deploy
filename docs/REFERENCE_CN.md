# DERP 基于 IP 的自签名部署指南（技术参考文档）

> 本文是中文的详细技术参考。主仓库首页 `README.md` 为精简版中文快速上手；英文详细参考见同目录的 `REFERENCE_EN.md`。

> **脚本文件**：`deploy_derper_ip_selfsigned.sh`  
> **当前版本**：2.0.3（2026-01-25）

![Linux](https://img.shields.io/badge/OS-Linux-blue?logo=linux&logoColor=white)
![systemd](https://img.shields.io/badge/Service-systemd-orange?logo=systemd&logoColor=white)
![Public IPv4 Required](https://img.shields.io/badge/Network-Public%20IPv4%20Required-red?logo=cloudflare&logoColor=white)
![Bash](https://img.shields.io/badge/Shell-Bash-green?logo=gnu-bash&logoColor=white)

本方案在仅有公网 IP（无域名）的 Linux 服务器上自动部署 Tailscale DERP 中继服务（`derper`），自动生成"基于 IP 的自签证书"，配置 `systemd` 服务，并输出可直接粘贴到 Tailscale 管理后台的 `derpMap` 配置片段（使用证书指纹 `CertName`，更安全可靠）。

**特性**：
- ✅ 幂等可重入，支持检查、修复、强制重装模式
- ✅ 自动探测新旧 derper 参数（`-a` vs `-https-port`）
- ✅ 默认启用 `-verify-clients` 客户端校验（安全优先）
- ✅ 内置健康检查与 Prometheus 指标导出
- ✅ 支持卸载与清理
- 🆕 **向导模式** - 交互式引导配置
- 🆕 **分级安全加固** - basic/standard/paranoid 三级可选
- 🆕 **智能账户管理** - 自动适配当前用户/专用用户/root 警告
- 🆕 **非交互模式** - CI/自动化友好

**适用场景**：测试环境、临时部署、家用小规模中继。生产环境建议使用受信任 CA 证书 + 443 端口。

📖 **详细文档**：
- 账户与安全策略详解（计划中）
- 常见故障处理（计划中）

---

## 前置条件

### 操作系统要求（必须）

> ⚠️ **重要提示**：本脚本**仅支持 Linux 系统**，不支持 macOS 和 WSL 环境

**✅ 支持的部署环境**：
- **云服务器**：阿里云、腾讯云、AWS、DigitalOcean、Vultr 等
- **VPS/专用服务器**：任何具备公网 IPv4 的 Linux 服务器
- **家用 Linux 设备**：树莓派、软路由、NAS（需配置端口转发且有公网 IP）

**❌ 不支持的环境**：
- **macOS**：桌面系统通常位于 NAT 后，缺乏公网可达性，不适合作为 24/7 在线的 DERP 中继节点
- **WSL (Windows Subsystem for Linux)**：位于双重 NAT 后，网络栈不完整，无法稳定提供公网服务
- **无公网 IP 的设备**：DERP 中继服务必须能被互联网上的其他设备访问

**本地开发测试**：
如需在 macOS/WSL 上测试 `derper` 程序本身（非生产部署），可手动前台运行：
```bash
derper -hostname 127.0.0.1 -certmode manual -certdir ./certs \
  -http-port -1 -a :30399 -stun
```
注意：此模式仅供本地功能验证，无法作为 Tailscale 网络的中继节点。

---

### 硬件与网络
- 一台具备**公网 IPv4** 的 Linux 主机（云服务器或能被公网访问的家宽设备）
- 端口可放行：`DERP_PORT/tcp`（默认 30399）、`STUN_PORT/udp`（默认 3478）
- 出站网络可访问 Go 模块代理（国内建议配置 `GOPROXY` 与 `GOSUMDB`）

### 权限与系统
- 需要 **root 权限**执行脚本（或使用 `sudo`）
- 推荐使用 **systemd** 作为服务管理器（脚本会自动检测并在不兼容时提供手动运行示例）

### 安全设置（重要）
- **默认启用 `-verify-clients`**：脚本会在安装前检查本机 `tailscaled` 是否运行且已登录
  - ✅ 若未就绪，脚本会中止并提示登录方法
  - ⚠️ 若确需跳过校验，可使用 `--no-verify-clients`（**仅限测试环境**）
  - 📝 检测逻辑：
    - 若检测到 `tailscale` CLI，通过 `tailscale ip` 判断是否已分配 Tailnet IP
    - 若未检测到 CLI，则仅依据 `tailscaled` 运行状态判断

### 其他说明
- 自动探测公网 IP 依赖 `curl`/`dig` 等工具
- 若系统缺少这些工具，请使用 `--ip <你的公网IP>` 显式指定

---

## 快速开始

### 方式一：向导模式（推荐新手） 🆕

```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh wizard
```

向导会引导你：
1. 选择使用场景（个人/团队/生产）
2. 选择账户策略（当前用户/专用用户）
3. 选择端口和安全选项
4. 自动生成适合你的部署命令

### 方式二：命令行模式（适合熟悉用户）

1) 登陆服务器，拉起 `tailscaled`（推荐）

```bash
sudo systemctl enable --now tailscaled
sudo tailscale up            # 首次会输出一个授权链接，浏览器登录后返回
# 或使用预生成 key：
# sudo tailscale up --authkey tskey-xxxx
```

2) 预检（仅检查，不更改系统）

```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh --ip <你的公网IP> --check
```

说明：预检不会写入系统或打开端口，只输出当前环境与参数检查结果、建议的下一步动作。若提示 tailscaled 未登录、端口冲突或缺少依赖，请先按提示处理。

> 💡 **v2.0.2 改进**：即使公网 IP 探测失败，`--check` 模式也能继续输出完整诊断信息，方便排查环境问题。

3) 运行部署脚本（正式安装/修复；国内网络示例，默认开启 `-verify-clients`）

**生产环境（专用用户 + 高安全级别）** 🆕
```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip <你的公网IP> \
  --dedicated-user \
  --security-level paranoid \
  --derp-port 443 \
  --auto-ufw \
  --goproxy https://goproxy.cn,direct \
  --gosumdb sum.golang.google.cn
```

**默认（个人/小团队）：使用当前用户，简化部署**
```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip <你的公网IP> \
  --use-current-user \
  --security-level basic \
  --auto-ufw
```

**CI/自动化（非交互模式）** 🆕
```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip <你的公网IP> \
  --dedicated-user \
  --yes \
  --non-interactive \
  --auto-ufw
```

**进阶：指定其他用户**
```bash
# 使用已有系统用户（如 nobody、www-data）
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip <你的公网IP> \
  --user nobody \
  --derp-port 30399
```

执行完成后脚本会（已做成幂等，已就绪则直接跳过；依赖“按需安装”，若都已具备则不会访问包仓库）：
- 安装依赖（`git/curl/openssl/golang/netcat` 等）
- 安装/构建 `derper`（使用 `GOTOOLCHAIN=auto` 自动获取匹配版本）
- 生成“基于 IP 的自签证书”到 `/opt/derper/certs/`
- 写入并启动 `systemd` 服务 `/etc/systemd/system/derper.service`
- 打印端口放行提示与运行自检
- 输出带 `CertName`（证书指纹）的 `derpMap` 片段（直接粘贴到 Tailscale ACL 即可）

### 常见中止原因与处理（含登录流程示意）

```text
登录流程（示意）：
  sudo systemctl enable --now tailscaled    # 或其他服务管理器启动 tailscaled
  sudo tailscale up                         # 终端打印登录 URL
        │
        ├──> 浏览器打开 URL 完成授权
        │
        └──> tailscaled 获得登录态（连接 Tailnet）
               │
               └──> 重新运行脚本，前置校验通过（-verify-clients）
```

- 未运行/未登录 tailscaled（最常见）
  - 处理：`sudo systemctl enable --now tailscaled && sudo tailscale up`
  - 非 systemd 环境：OpenRC（`rc-service tailscaled start`）、SysV（`service tailscaled start`）。
- 无法自动探测公网 IP：
  - 处理：手动指定 `--ip <你的公网IP>`；或确认出站网络可用（curl/dig）。极简系统可能缺少 `curl/dig`，请先安装或直接显式传入 `--ip`。
- 端口被占用：
  - 处理：`ss -tulpn | grep -E ':30399|:3478'` 查占用进程，或改用其它端口。脚本在写入服务前会预检端口占用，若发现冲突将中止并提示。
- 缺少依赖/网络受限导致安装失败：
  - 处理：为 Go 配置国内镜像：`--goproxy https://goproxy.cn,direct --gosumdb sum.golang.google.cn`。
- 未检测到 systemd：
  - 处理：脚本无法写入 systemd 服务；可改用其他服务管理器或手动前台运行 `derper`。
- 权限不足：
  - 处理：使用 `sudo` 执行脚本。

提示：上述“预检”步骤也可使用 `--dry-run`，与 `--check` 等价。

---

## 预检结果解读与常见处理

预检会输出若干关键项，含义与处理建议如下（按出现顺序）：

- 公网 IP
  - 为空/不正确：使用 `--ip <你的公网IP>` 显式指定；若检测到内网地址，需为主机绑定公网 IP 或做端口映射（并确认外网可达）。
- DERP 端口 / STUN 端口
  - 端口冲突：用 `ss -tulpn | grep -E ':<DERP_PORT>|:<STUN_PORT>'` 排查占用，释放进程或改 `--derp-port/--stun-port`；同时放行云安全组/UFW/iptables。
- tailscale 状态（安装/运行/版本/是否满足门槛）
  - 安装=0：用发行版包管理器安装 tailscale（或官方一键脚本：`curl -fsSL https://tailscale.com/install.sh | sh`）。
  - 运行=0：`sudo systemctl enable --now tailscaled`。
  - 满足=false：升级到 `REQUIRED_TS_VER` 或更高版本。
  - 未登录：`sudo tailscale up` 完成登录（或使用 `--authkey`）。
- derper 组件（二进制/服务文件/运行）
  - 二进制=0：正式安装阶段会自动构建安装；离线环境可 `go install tailscale.com/cmd/derper@latest`。
  - 服务文件=0：正式安装会自动写入 systemd；无 systemd 见下述“服务管理器”。
  - 运行=0：`journalctl -u derper -f` 看日志，多为端口冲突或证书路径/权限问题。
- 端口监听（TLS / STUN）
  - 为 0：服务未起、被防火墙/安全组拦截，或监听端口与预期不符；放行 `${DERP_PORT}/tcp` 与 `${STUN_PORT}/udp`，UFW 可执行 `ufw allow <端口>/tcp|udp`。
- 纯 IP 配置判定（基于 unit）
  - 为 0：说明当前 unit 非“纯 IP 模式”（如 HostName 非 IP）。执行 `--repair` 重写，或 `--force` 全量重装；若公网 IP 变更，请同步 `--ip`。
- 证书（存在/SAN 匹配 IP/30 天内不过期）
  - 任一为 0：重新运行脚本（或 `--repair`）以重签证书；若 IP 有变化需确保 `--ip` 指向新 IP；缺少 openssl 请先安装。
- 客户端校验模式
  - on：启用 `-verify-clients`，要求本机 tailscaled 已登录（推荐）。如仅测试可 `--no-verify-clients` 暂时跳过（不建议长期）。
- 运行用户（服务执行的用户与组）
  - 显示将以哪个用户/组运行 derper 服务（如 `derper（组：derper）`）
  - 默认使用当前登录用户；生产环境推荐 `--dedicated-user`（也可通过 `--user` 自定义）
  - 若用户尚未创建，组名显示为用户名占位符
- 关键可执行检查
  - 缺少项（如 curl/openssl/git/go）：正式安装会按需补齐；离线/受限网络下请先用包管理器安装。
- 服务管理器
  - 未检测到 systemd：无法写入服务。可手动前台运行（示例）：
    `derper -hostname <你的公网IP> -certmode manual -certdir /opt/derper/certs -http-port -1 -a :30399 -stun -stun-port 3478 -verify-clients`
    说明：老版本不支持 `-a/-stun-port` 时，改用 `-https-port 30399` 并去掉 `-stun-port`。
- 非 systemd 环境将给出手动运行示例，安装流程会中止。
- 建议（建议动作汇总）
  - `<已就绪：可直接跳过>`：无需操作。
  - `安装 derper（缺少二进制）`：执行“快速开始”的正式安装命令。
  - `--repair`：仅修复配置/证书，不中断可用依赖。
  - `--force`：全量重装（二进制/证书/服务）。

常见路线：
- 预检无致命问题 → 直接进入正式安装（或 `--repair`）。
- 预检提示“未登录/端口冲突/缺依赖” → 先按上面处理，再执行正式安装。

---

## 脚本参数说明

```text
--ip <IPv4>               服务器公网 IP（推荐显式传入；缺省自动探测）
--derp-port <int>         DERP TLS 端口，默认 30399/TCP
--stun-port <int>         STUN 端口，默认 3478/UDP
--cert-days <int>         自签证书有效期（天），默认 365
--auto-ufw                若检测到 UFW，自动放行端口

--goproxy <URL>           Go 模块代理，例：https://goproxy.cn,direct
--gosumdb <VALUE>         Go 校验数据库，例：sum.golang.google.cn
--gotoolchain <MODE>      go 工具链策略，默认 auto（可自动拉取 ≥1.25）

--no-verify-clients       关闭客户端校验（默认不开启此项；仅测试）
--force-verify-clients    强制开启客户端校验（默认行为）
--region-id               ACL derpMap 的 RegionID（默认 900）
--region-code             ACL derpMap 的 RegionCode（默认 my-derp）
--region-name             ACL derpMap 的 RegionName（默认 "My IP DERP"）
--user <username>         指定运行 derper 的用户（默认：当前登录用户）
                          可指定现有用户（如 nobody、www-data 等）
--use-current-user        使用当前登录用户运行 derper（等价于 --user $USER）
--check / --dry-run       仅进行状态与参数检查，不执行安装/写服务/放行等
--repair                  仅修复/重写配置（systemd/证书等），不重装 derper
--force                   强制全量重装（重装 derper、重签证书、重写服务）

# 运行与维护
--health-check            仅输出健康检查摘要（不更改系统，可用于 cron/监控）
--metrics-textfile <P>    将健康检查导出为 Prometheus 文本指标到路径 P（结合 node_exporter 使用）
--uninstall               停止并卸载 derper 的 systemd 服务（保留二进制与证书）
--purge                   搭配 --uninstall：额外删除安装目录（/opt/derper）
--purge-all               搭配 --uninstall：在 --purge 基础上同时删除二进制（/usr/local/bin/derper）
```

> 兼容性：脚本优先使用新版 `-a :<PORT>` 指定监听；若不支持则回退到旧参数 `-https-port <PORT>`。

> 幂等说明：若检测到本机已存在“纯 IP 模式”的 derper 且工作正常（端口监听健康、证书匹配 IP 且未临期），默认跳过安装。

---

## 幂等 / 可重入与修复

- 默认行为：先做状态检测，若已满足“纯 IP 模式”要求则跳过；否则按需修复（安装缺失组件、补生成证书、重写服务）。
- 检查模式：
  - 仅检查但不动系统：`bash scripts/deploy_derper_ip_selfsigned.sh --ip <你的公网IP> --check`
  - 输出 tailscale/derper/端口/证书/配置 等状态与建议动作。
- 修复模式（不中断可用的依赖）：
  - `sudo bash scripts/deploy_derper_ip_selfsigned.sh --ip <你的公网IP> --repair`
  - 行为：必要时重签证书、重写 systemd 单元并 enable+restart。
- 强制重装：
  - `sudo bash scripts/deploy_derper_ip_selfsigned.sh --ip <你的公网IP> --force`
  - 行为：重新安装 derper、重签证书、重写并重启服务。
- 版本门槛（可选）：
  - 通过环境变量 `REQUIRED_TS_VER` 指定 tailscale 最低版本（默认 1.66.3），检查在 `--check/--dry-run` 输出中可见。

---

## 在 Tailscale 后台配置 derpMap

脚本会自动计算证书 DER 原始字节的 SHA256，并输出如下 ACL 片段（示例，RegionID 可自定义）：

```json
{
  "derpMap": {
    "OmitDefaultRegions": false,
    "Regions": {
      "900": {
        "RegionID": 900,
        "RegionCode": "my-derp",
        "RegionName": "My IP DERP",
        "Nodes": [
          {
            "Name": "900a",
            "RegionID": 900,
            "HostName": "<你的公网IP>",
            "DERPPort": 30399,
            "CertName": "sha256-raw:<脚本输出的指纹>"
          }
        ]
      }
    }
  }
}
```

将该片段粘贴到 Tailscale 管理后台 → Access Controls（ACL）中保存，等待 10–60 秒即可下发到客户端。

> 说明：使用 `CertName` 固定证书指纹，无需 `InsecureForTests`。若端口改为 443，请把 `DERPPort` 改为 443。

### 如何再次获取证书指纹

```bash
# 从日志获取（服务启动时会打印）
journalctl -u derper --no-pager | grep sha256-raw | tail -1

# 或直接计算文件指纹
openssl x509 -in /opt/derper/certs/fullchain.pem -outform DER | sha256sum | awk '{print $1}'
```

---

## 安全最佳实践

脚本默认实施了多项安全加固措施：

### 灵活的用户配置

**你可以选择谁来运行 derper** - 脚本支持三种模式：

1. **当前用户（默认，简单）**
   - 部署更简单，无需创建用户
   - 适合测试或个人/小团队服务器
   - 仍然通过 systemd 加固保持安全（见下文）

2. **专用 `derper` 用户（`--dedicated-user`）**（生产推荐）
   - 自动创建系统用户，无登录 shell，无家目录
   - 最小权限，与其他系统活动隔离
   - 生产环境最佳实践

3. **指定用户（`--user <username>`）**
   - 使用已有系统用户，如 `nobody`、`www-data` 等
   - 灵活集成到现有环境

**技术细节：**
- **端口 ≥ 1024（默认 30399）**：任何非 root 用户都可以运行 derper，无需特殊能力
- **端口 < 1024（如 443）**：脚本自动通过 systemd 授予 `CAP_NET_BIND_SERVICE` 能力，无论选择哪个用户
- **跨发行版兼容**：自动检测 `nologin` 路径（RHEL/CentOS 使用 `/sbin/nologin`，Debian/Ubuntu 使用 `/usr/sbin/nologin`，兜底使用 `/bin/false`）
- **健壮的用户创建**：创建前后强校验用户/组是否存在，失败时给出明确错误信息
- **非交互 root 默认**：当以 root 且非交互运行（无 `SUDO_USER`）时，为安全起见脚本默认等同 `--dedicated-user`，除非你显式传入 `--use-current-user`/`--user`。

### systemd 安全加固

生成的 systemd 服务包含多层保护：

```ini
# 防止权限提升
NoNewPrivileges=true

# 文件系统保护
ProtectSystem=strict        # /usr, /boot, /efi 只读
ProtectHome=true            # /home, /root, /run/user 不可访问
PrivateTmp=true             # 私有 /tmp 和 /var/tmp
ReadWritePaths=/opt/derper  # 仅允许写入安装目录

# 网络限制
RestrictAddressFamilies=AF_INET AF_INET6  # 仅 IPv4/IPv6

# 系统调用过滤
SystemCallFilter=@system-service  # 仅白名单安全系统调用
SystemCallErrorNumber=EPERM       # 拒绝返回 EPERM 而非杀死进程
```

### 证书安全

- **私钥保护**：`privkey.pem` 设置为 `600`（仅所有者读写）
- **目录隔离**：证书目录（`/opt/derper/certs`）设置为 `750`，所有权为 `derper:derper`
- **SHA256 校验**：Go 工具链下载前进行完整性检查

### 网络安全

- **客户端验证**：默认启用 `-verify-clients`（需要本地 tailscaled 认证）
- **防火墙指导**：脚本提供 UFW、firewalld 和 iptables 的配置说明
- **端口限制**：仅开放必要端口（DERP TLS + STUN UDP）

### 额外建议

生产环境部署建议：

1. **使用受信任的 CA 证书**而非自签证书（通过 Let's Encrypt/ACME 或组织 CA）
2. **部署在 443 端口**以获得更好的防火墙穿透性：`--derp-port 443`
3. **启用自动更新**：derper 二进制和系统包
4. **使用 Prometheus 监控**：使用 `--health-check --metrics-textfile` 进行告警
5. **定期证书轮换**：当前默认有效期为 365 天

---

## 常用验证命令

```bash
# 服务状态与日志
systemctl status derper
journalctl -u derper -f

# 端口监听（TCP 30399、UDP 3478）
ss -tulpn | grep -E ':30399|:3478'

# TLS 握手（自签会提示不受信，属正常）
openssl s_client -connect <你的公网IP>:30399 -servername <你的公网IP>

# STUN 端口可达性（客户端/外部主机）
nc -zvu <你的公网IP> 3478

# 客户端观察 DERP：
tailscale netcheck

# 观察是否“经由 DERP(my-derp)”
tailscale ping -c 5 <对端 Tailscale IP>
```

---

## 防火墙配置（多平台支持）

脚本会自动检测并提供适合你的防火墙解决方案的指令：

### UFW (Ubuntu/Debian)

```bash
# 手动执行
ufw allow 30399/tcp
ufw allow 3478/udp

# 或使用 --auto-ufw 参数自动配置
sudo bash scripts/deploy_derper_ip_selfsigned.sh --ip <你的公网IP> --auto-ufw
```

### firewalld (RHEL/CentOS/Fedora)

```bash
firewall-cmd --permanent --add-port=30399/tcp
firewall-cmd --permanent --add-port=3478/udp
firewall-cmd --reload
```

### iptables (直接规则)

```bash
# 添加规则
iptables -I INPUT -p tcp --dport 30399 -j ACCEPT
iptables -I INPUT -p udp --dport 3478 -j ACCEPT

# 保存规则（Debian/Ubuntu 使用 netfilter-persistent）
netfilter-persistent save

# 或保存规则（RHEL/CentOS 使用 iptables-services）
service iptables save
```

**注意**：别忘了同时在云服务商的安全组中开放这些端口（阿里云、腾讯云、AWS 等）。

---

## 排障

### 获取证书指纹（日志/在线握手速查）

当需要在 ACL 中填写 `CertName`（sha256-raw:<hex>）或怀疑证书不一致时，可用下列两种方式快速获取当前指纹：

1) 从 systemd 日志提取（服务启动时 derper 会打印）

```bash
journalctl -u derper --no-pager | grep -oE 'sha256-raw:[0-9a-f]+' | tail -1
```

2) 在线 TLS 握手抓取当前证书并计算（无需登录服务器文件系统）

Linux（使用 sha256sum）：

```bash
openssl s_client -connect <你的公网IP>:<DERP_PORT> -servername <你的公网IP> -showcerts </dev/null \
  | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
  | openssl x509 -outform DER \
  | sha256sum | awk '{print $1}'
```

macOS（使用 shasum）：

```bash
openssl s_client -connect <你的公网IP>:<DERP_PORT> -servername <你的公网IP> -showcerts </dev/null \
  | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
  | openssl x509 -outform DER \
  | shasum -a 256 | awk '{print $1}'
```

补充：若已在本机上生成证书文件，也可以直接对文件求指纹（与“如何再次获取证书指纹”一致）：

```bash
openssl x509 -in /opt/derper/certs/fullchain.pem -outform DER | sha256sum | awk '{print $1}'
```

提示：将 `<DERP_PORT>` 替换为实际端口（默认为 30399）。若握手失败，请检查云安全组/本机防火墙放行、`derper` 运行状态以及端口占用情况。

---

## 监控与告警（健康检查 + Prometheus）

### 健康检查（适合 cron 周期执行）

```bash
# 仅输出健康摘要（不更改系统）
sudo bash scripts/deploy_derper_ip_selfsigned.sh --ip <你的公网IP> --health-check

# 同时导出 Prometheus 文本指标（供 node_exporter textfile collector 抓取）
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip <你的公网IP> \
  --health-check \
  --metrics-textfile /var/lib/node_exporter/textfile_collector/derper.prom
```

退出码语义（可用于 shell/监控判定）：

```text
0  表示关键健康项正常（服务运行 + TLS/UDP 端口均在监听）
1  表示至少一项关键健康检查失败（服务或端口不健康）
```

> 💡 **v2.0.2 改进**：`--metrics-textfile` 写入失败时不再导致脚本中止，会输出警告并继续执行。

示例（仅在异常时报警）：

```bash
if ! sudo bash scripts/deploy_derper_ip_selfsigned.sh --ip <你的公网IP> --health-check >/tmp/derper_health.txt 2>&1; then
  echo "[ALERT] DERP 健康检查失败" >&2
  tail -n +1 /tmp/derper_health.txt >&2
fi
```

示例输出（节选）：

```text
✅ 服务：derper 处于运行中
✅ 端口：TLS 30399/tcp 正在监听
✅ 端口：STUN 3478/udp 正在监听
✅ 证书：有效期剩余 287 天
ℹ️  资源：derper 内存 RSS 约 3 MiB
```

Prometheus 指标样例（文本文件内容）：

```text
derper_up 1
derper_tls_listen 1
derper_stun_listen 1
derper_cert_days_remaining 287
derper_verify_clients 1
derper_pure_ip_config_ok 1
derper_process_rss_bytes 3145728
```

说明：
- 本脚本内置的是“textfile 导出”方式，推荐与 `node_exporter` 的 `--collector.textfile` 配合；
- 若你已部署 `node_exporter`（默认监听 9100），Prometheus 直接抓取其 9100 端口，同时开启 textfile 收集上述文件；
- 如需更换文件路径，请对应调整 `node_exporter` 的 `--collector.textfile.directory` 参数。

crontab 示例（每 1 分钟刷新指标）：

```cron
* * * * * root bash /路径/scripts/deploy_derper_ip_selfsigned.sh --ip <你的公网IP> --health-check --metrics-textfile /var/lib/node_exporter/textfile_collector/derper.prom >/var/log/derper_health.log 2>&1
```

---

## 运行中的 `tailscaled`（用于客户端校验）

若脚本/服务启用 `-verify-clients`，本机需有 `tailscaled` 在运行并登录 Tailnet：

```bash
sudo systemctl enable --now tailscaled
sudo tailscale up
# 或：sudo tailscale up --authkey tskey-xxxx
```

如暂时无法登录，可在运行脚本时追加 `--no-verify-clients`（仅测试）。

---

## 卸载

```bash
# 停止并卸载 systemd 服务（保留二进制与证书）
sudo bash scripts/deploy_derper_ip_selfsigned.sh --uninstall

# 卸载并清理安装目录（证书等）
sudo bash scripts/deploy_derper_ip_selfsigned.sh --uninstall --purge

# 完全清理（包含二进制 /usr/local/bin/derper）
sudo bash scripts/deploy_derper_ip_selfsigned.sh --uninstall --purge-all
```

注意：卸载不影响 Tailscale 本体（tailscaled、客户端等）。若需一起移除，请按发行版常规方式操作。

---

## 常见问题与排错

- Go 代理超时：
  - 使用国内代理与校验镜像，例如：
    ```bash
    --goproxy https://goproxy.cn,direct --gosumdb sum.golang.google.cn
    ```
- Go 版本不足：
  - 新版 Tailscale 需要 Go ≥ 1.25。脚本默认 `--gotoolchain auto`，会自动拉取更高版本工具链。
- derper 参数不兼容：
  - 新版移除 `-https-port`，使用 `-a :<PORT>`。脚本已自动适配，无需手工更改。
- `-verify-clients` 失败：
  - 确认 `tailscaled` 正常并可见 `/run/tailscale/tailscaled.sock`；或在脚本中使用 `--no-verify-clients` 临时关闭。
- IPv6 健康告警（`ip6tables MARK`）：
  - 尝试：`sudo modprobe xt_mark && sudo systemctl restart tailscaled`
  - 或切换到 legacy 后端：
    ```bash
    sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
    sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
    sudo systemctl restart tailscaled
    ```
- 端口被拦截：
  - 确认“云安全组 + 本机防火墙（如 UFW）”已放行 `DERP_PORT/tcp` 与 `3478/udp`。

---

## 变更端口到 443（可选）

部分网络更友好于 `443/tcp`：

1) 修改服务监听端口：运行脚本时 `--derp-port 443`。
2) 在 ACL 中把 `DERPPort` 改为 `443`。
3) 放行云安全组/本地防火墙的 `443/tcp`。

> 说明：仍然使用“基于 IP 的自签证书 + CertName 指纹”来校验。

---

## 维护与升级

```bash
# 查看/重启服务
systemctl status derper
systemctl restart derper

# 升级 derper 二进制（保留现有服务与证书）
GOTOOLCHAIN=auto go install tailscale.com/cmd/derper@latest
systemctl restart derper

# 备份证书（指纹变化会导致 ACL 需更新）
tar -C /opt/derper -czf derper-certs-backup.tgz certs/
```

卸载（慎用）：

```bash
sudo systemctl disable --now derper
sudo rm -f /etc/systemd/system/derper.service
sudo systemctl daemon-reload
sudo rm -rf /opt/derper
sudo rm -f /usr/local/bin/derper
```

---

## 待办清单（Checklist）

- 服务器放行 `DERP_PORT/tcp` 与 `3478/udp`（云安全组 + 本机防火墙）。
- 运行脚本并记录输出的 `CertName` 指纹。
- 在 Tailscale 后台 ACL 粘贴 `derpMap`（使用 `CertName`）。
- 在客户端运行 `tailscale netcheck`、`tailscale ping` 验证 “via DERP(my-derp)”。
- 备份 `/opt/derper/certs/`，以防证书变化导致指纹变更。
