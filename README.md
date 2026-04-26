# Tailscale DERP Quick Deploy Script

> **Language / 语言**: [English](#english) | [中文](#中文)

---

<a id="english"></a>

## English

### 📋 Project Overview

This project provides a **fully automated Tailscale DERP relay service deployment solution**, specifically designed for scenarios with **only a public IP (no domain required)**. It addresses the following pain points:

#### Core Objectives

1. **Zero-Domain Deployment**: Build DERP relay with just a public IP, no domain purchase needed
2. **Security-First**: Auto-generate IP-based self-signed certificates with certificate fingerprint (`CertName`) verification, eliminating the need for insecure `InsecureForTests` flag
3. **Out-of-the-Box**: Complete deployment from dependency installation to service startup with a single command
4. **Production-Grade**: Built-in security hardening, health checks, and Prometheus metrics export

#### Use Cases

- 🧪 **Testing Environments**: Quickly set up temporary relay nodes
- 🏠 **Home Networks**: Build private relays using home broadband public IPs
- 👥 **Small Teams**: Low-cost internal Tailscale acceleration nodes
- 🚀 **Rapid Prototyping**: Instant network topology validation without DNS/certificate configuration

---

### 🎯 Core Features

#### 1. Intelligent Deployment

- ✅ **Idempotent Design**: Safe to run multiple times, automatically detects existing configurations
- ✅ **Parameter Auto-Adaptation**: Auto-detects new/old derper parameter differences (`-a` vs `-https-port`)
- ✅ **Smart Repair**: `--repair` mode fixes configurations without interrupting service

#### 2. Security Hardening

- 🔒 **Tiered Security Policies**: Three-level systemd hardening (basic/standard/paranoid)
- 🔒 **Flexible User Management**: Supports current user/dedicated user/custom user modes
- 🔒 **Client Verification**: Enables `-verify-clients` by default, rejecting unauthorized access
- 🔒 **Privilege Minimization**: Grants `CAP_NET_BIND_SERVICE` capability, no root execution required

#### 3. Enterprise Operations

- 📊 **Health Checks**: Built-in `--health-check` outputs service status summary
- 📊 **Prometheus Integration**: Exports textfile format metrics for seamless monitoring integration
- 🔧 **Multi-Mode Operation**: check/repair/force modes for different scenarios
- 🗑️ **Complete Uninstall**: `--uninstall` supports three-level options (retain/cleanup/purge-all)

#### 4. Cross-Environment Compatibility

- 🐧 **Multi-Distribution Support**: Debian/Ubuntu/RHEL/CentOS/Fedora, etc.
- 🔥 **Firewall Adaptation**: Auto-detects UFW/firewalld/iptables
- 🌐 **China Network Optimization**: Built-in GOPROXY/GOSUMDB mirror configuration

---

### 🚀 Usage Guide

#### Quick Start (3-Step Deployment)

##### Step 1: Login to Tailscale (Required)

```bash
# Start tailscaled daemon
sudo systemctl enable --now tailscaled

# Login to Tailnet (browser authorization)
sudo tailscale up

# Or use pre-generated Auth Key (for automation)
sudo tailscale up --authkey tskey-xxxxxxxxxxxxxxxxxxxx
```

##### Step 2: Pre-Check (Recommended)

```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip <your-public-ip> \
  --check
```

**Pre-check outputs:**
- Public IP detection result
- Port occupation status
- Tailscale installation and login state
- System dependency integrity
- Repair recommendations

##### Step 3: Formal Deployment

**Option A: Personal/Testing Environment (Use Current User, Simplest)**

```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip <your-public-ip> \
  --use-current-user \
  --security-level basic \
  --auto-ufw
```

**Option B: Production Environment (Dedicated User + High Security)**

```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip <your-public-ip> \
  --dedicated-user \
  --security-level paranoid \
  --derp-port 443 \
  --auto-ufw \
  --goproxy https://goproxy.cn,direct \
  --gosumdb sum.golang.google.cn
```

**Option C: Wizard Mode (Beginner-Friendly)** 🆕

```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh wizard
```

The wizard will interactively ask about:
1. Usage scenario (personal/team/production)
2. Account strategy (current user/dedicated user)
3. Port selection (443/30399)
4. Enable client verification

Then automatically generate the deployment command suitable for your needs.

---

### ⚙️ Parameter Reference

#### Default Parameters (No Explicit Specification Required)

```bash
DERP_PORT="30399"              # DERP TLS port
STUN_PORT="3478"               # STUN UDP port
CERT_DAYS="365"                # Certificate validity (1 year)
INSTALL_DIR="/opt/derper"      # Installation directory
BIN_PATH="/usr/local/bin/derper"
VERIFY_CLIENTS_MODE="on"       # Enable client verification (secure default)
SECURITY_LEVEL="standard"      # Standard security level
RUN_USER="${SUDO_USER:-$USER}" # Use current login user
```

#### Core Parameters

##### Network Configuration

| Parameter | Description | Default | Example |
|-----------|-------------|---------|---------|
| `--ip <IPv4>` | Server public IP | Auto-detect | `--ip 203.0.113.10` |
| `--derp-port <int>` | DERP TLS port | 30399 | `--derp-port 443` |
| `--stun-port <int>` | STUN UDP port | 3478 | `--stun-port 3478` |
| `--auto-ufw` | Auto-configure UFW rules | Off | `--auto-ufw` |

**Port Selection Recommendations:**
- **30399** (default): Avoids conflicts with web services, suitable for multi-service servers
- **443**: Best firewall traversal, but check for HTTPS service conflicts

##### Go Build Configuration (Required for China Mainland)

| Parameter | Description | Default | Recommended (China) |
|-----------|-------------|---------|---------------------|
| `--goproxy <URL>` | Go module proxy | Inherit env | `https://goproxy.cn,direct` |
| `--gosumdb <VALUE>` | Go checksum database | Inherit env | `sum.golang.google.cn` |
| `--gotoolchain <MODE>` | Toolchain policy | `auto` | `auto` (auto-fetch ≥1.25) |

##### Security & Account Management

| Parameter | Description | Default Behavior | Use Case |
|-----------|-------------|------------------|----------|
| `--use-current-user` | Use current login user | ✅ Default | Personal servers, testing |
| `--dedicated-user` | Create dedicated `derper` user | Off | **Production strongly recommended** |
| `--user <username>` | Specify existing user | - | Integration (e.g., `nobody`) |
| `--security-level <level>` | Security hardening level | `standard` | `basic`/`standard`/`paranoid` |

**Security Level Comparison:**

| Level | systemd Protection | Compatibility | Use Case |
|-------|-------------------|---------------|----------|
| **basic** | Minimal (NoNewPrivileges + ProtectSystem) | Best | Old kernels, embedded devices |
| **standard** | Standard hardening (+PrivateTmp +RestrictAddressFamilies) | Good | **Recommended default** |
| **paranoid** | Maximum (+ProtectProc +RestrictNamespaces) | Requires Linux 5.8+, systemd 247+ | High security requirements |

##### Client Verification

| Parameter | Description | Default | Security Impact |
|-----------|-------------|---------|-----------------|
| `--force-verify-clients` | Force enable client verification | ✅ Default | Only allow Tailnet devices |
| `--no-verify-clients` | Disable client verification | Off | ⚠️ Anyone can connect (testing only) |

##### ACL Region Configuration

| Parameter | Description | Default | Purpose |
|-----------|-------------|---------|---------|
| `--region-id <int>` | ACL derpMap RegionID | 900 | Unique identifier for your relay node |
| `--region-code <string>` | RegionCode | `my-derp` | Short code (displayed in `tailscale status`) |
| `--region-name <string>` | RegionName | `My IP DERP` | Human-readable name |

##### Operational Modes

| Parameter | Description | System Impact | When to Use |
|-----------|-------------|---------------|-------------|
| `--check` / `--dry-run` | Check only, no system changes | ❌ None | Diagnose issues, verify parameters |
| `--repair` | Fix configuration (certs/service) | 🔧 Service restart | Certificate expiry, config drift |
| `--force` | Force complete reinstall | 🔄 Full rebuild | Version upgrade, complete reset |

##### Operations & Monitoring

| Parameter | Description | Output | Use Case |
|-----------|-------------|--------|----------|
| `--health-check` | Output health status summary | Text + exit code | cron periodic checks, alerting |
| `--metrics-textfile <path>` | Export Prometheus metrics | `.prom` file | With node_exporter monitoring |

**Prometheus Metrics Example:**

```prometheus
derper_up 1                          # Service running status
derper_tls_listen 1                  # TLS port listening
derper_stun_listen 1                 # STUN port listening
derper_cert_days_remaining 287       # Certificate remaining days
derper_verify_clients 1              # Client verification enabled
derper_process_rss_bytes 3145728     # Process memory usage (bytes)
```

##### Uninstall & Cleanup

| Parameter | Description | Deleted Content | Retained Content |
|-----------|-------------|-----------------|------------------|
| `--uninstall` | Stop and remove service | systemd unit | Binary, certificates |
| `--uninstall --purge` | + Remove installation directory | + `/opt/derper` | Binary |
| `--uninstall --purge-all` | + Remove binary | + `/usr/local/bin/derper` | - |

---

### 🎬 Deployment Workflow Demo

#### Complete Example: Zero to Production

```bash
# 1. Login to server with public IP
ssh user@203.0.113.10

# 2. Install Tailscale client (if not installed)
curl -fsSL https://tailscale.com/install.sh | sh

# 3. Start and login to Tailnet
sudo systemctl enable --now tailscaled
sudo tailscale up  # Copy login URL to browser

# 4. Download deployment script
git clone <repository-url>
cd tailscale-derp-quick-deploy

# 5. Pre-check (recommended)
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip 203.0.113.10 \
  --check

# 6. Formal deployment (China network)
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip 203.0.113.10 \
  --derp-port 443 \
  --dedicated-user \
  --security-level standard \
  --auto-ufw \
  --goproxy https://goproxy.cn,direct \
  --gosumdb sum.golang.google.cn

# 7. Script will automatically:
#    ✅ Install Go, derper, openssl, etc.
#    ✅ Generate self-signed certificate (/opt/derper/certs/)
#    ✅ Create and start systemd service
#    ✅ Output derpMap configuration snippet
```

#### Output Example

After successful deployment, you'll see:

```json
==================== Paste to Tailscale Admin Console derpMap ====================
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
            "HostName": "203.0.113.10",
            "DERPPort": 443,
            "CertName": "sha256-raw:a1b2c3d4e5f6..."
          }
        ]
      }
    }
  }
}
==================================================================================

Complete: DERP service deployed and running.
- Service status: systemctl status derper
- Real-time logs: journalctl -u derper -f
- Certificate location: /opt/derper/certs/
```

---

### 🎯 Expected Results

#### 1. Service Status

After deployment:

```bash
# systemd service running normally
$ systemctl status derper
● derper.service - Tailscale DERP with self-signed IP cert
     Loaded: loaded (/etc/systemd/system/derper.service; enabled)
     Active: active (running) since Mon 2025-01-10 10:00:00 UTC
```

#### 2. Port Listening Verification

```bash
$ ss -tulpn | grep -E ':443|:3478'
tcp   LISTEN  0  4096  *:443   *:*     users:(("derper",pid=1234))
udp   LISTEN  0  4096  *:3478  *:*     users:(("derper",pid=1234))
```

#### 3. Certificate Fingerprint Authentication

**Security Model:**
```
Client → Connect to 203.0.113.10:443
       ↓
       Verify certificate DER SHA256 matches CertName in ACL
       ↓
   ✅ Match → Establish connection
   ❌ Mismatch → Reject connection (prevent MITM attacks)
```

**Comparison with Traditional Solutions:**

| Solution | Security | Configuration Complexity | Cost |
|----------|----------|-------------------------|------|
| **CertName Fingerprint (This Script)** | ⭐⭐⭐⭐⭐ | Low | Free |
| InsecureForTests | ⭐ | Very Low | Free |
| Let's Encrypt + Domain | ⭐⭐⭐⭐⭐ | Medium | Domain purchase required |
| Commercial CA Certificate | ⭐⭐⭐⭐⭐ | High | Paid |

#### 4. Client Experience

On any Tailscale client:

```bash
# View DERP latency
$ tailscale netcheck
  * my-derp (203.0.113.10:443) = 15ms  ⭐ Fastest

# Auto-select fastest relay when connecting to peers
$ tailscale ping peer-device
pong from peer-device (100.x.x.x) via DERP(my-derp) in 18ms
```

#### 5. Monitoring Integration

With Grafana dashboard:

```
┌─────────────────────────────────────┐
│  DERP Service Status                 │
│  ✅ Running  Uptime: 15d 3h 42m     │
├─────────────────────────────────────┤
│  TLS Port (443)      ✅ Listening   │
│  STUN Port (3478)    ✅ Listening   │
│  Certificate Expiry  287 days       │
│  Memory Usage        3.2 MiB        │
└─────────────────────────────────────┘
```

---

### 🔍 Key Technical Highlights

#### 1. Idempotency Design

```bash
# First run: Complete installation
$ sudo bash script.sh --ip X.X.X.X
[Step] Installing dependencies...
[Step] Building derper...
✅ Service started

# Second run: Auto-skip
$ sudo bash script.sh --ip X.X.X.X
✅ Ready: Detected derper running in pure IP mode, skipping installation.
```

#### 2. Intelligent Fault Recovery

The script automatically detects and fixes:
- ✅ Certificate expired → Auto re-sign
- ✅ Config drift → Rewrite systemd unit
- ✅ Port conflicts → Early error with hints
- ✅ Permission issues → Auto-configure tailscaled socket ACL

#### 3. Cross-Version Compatibility

```bash
# Auto-adapt new/old version parameters
if derper_supports_listen_a; then
    listen_flag="-a :${DERP_PORT}"      # New version
elif derper_supports_https_port; then
    listen_flag="-https-port ${DERP_PORT}"  # Old version
fi
```

---

### 📊 Typical Application Scenarios

| Scenario | Recommended Configuration | Expected Results |
|----------|---------------------------|------------------|
| **Personal Learning** | `--use-current-user --security-level basic` | 5-min deployment, < 5MB resource usage |
| **Home Network** | `--derp-port 443 --auto-ufw` | High traversal rate, auto-acceleration for family devices |
| **Small Teams** | `--dedicated-user --health-check` | Stable operation with monitoring alerts |
| **Production** | `--security-level paranoid --metrics-textfile` | Enterprise-grade security, full observability |

---

### ⚠️ Important Notes

#### Must Read

1. **This script generates self-signed certificates**, verified only by fingerprint, not trusted by browsers
   - ✅ Suitable for: Tailscale internal relay (verified via CertName)
   - ❌ Not suitable for: Public web services

2. **Production Environment Recommendations**:
   - Use port 443 to improve traversal rate
   - Enable `--dedicated-user` for permission isolation
   - Configure Prometheus monitoring
   - Regularly backup certificate directory (fingerprint changes require ACL updates)

3. **Certificate Fingerprint Pinning Mechanism**:
   - Once `CertName` is configured in ACL, subsequent certificate replacement (re-signing, rotation) will cause connection failures
   - Solution: Re-run script to get new fingerprint, update ACL

---

### 🎓 Summary

This project compresses the originally manual **20+ steps DERP deployment process** into **a single command** through an intelligent **2100+ line script**, while ensuring:

- ✅ **Security**: Enterprise-grade systemd hardening + least-privilege execution
- ✅ **Stability**: Idempotent design + automatic fault recovery
- ✅ **Observability**: Health checks + Prometheus metrics
- ✅ **Maintainability**: Full coverage of repair/force/uninstall modes

Whether you're an **individual user quickly setting up a testing environment** or an **enterprise team building a production relay network**, you can complete deployment and put it into use within 5 minutes.

---

### 📚 Further Reading

- **Detailed Technical Documentation**:
  - [Changelog (English)](docs/CHANGELOG_EN.md) | [更新日志（中文）](docs/CHANGELOG_CN.md)
  - [Technical Reference (English)](docs/REFERENCE_EN.md) | [技术参考（中文）](docs/REFERENCE_CN.md)

---

<a id="中文"></a>

## 中文

### 📋 项目概述

本项目提供了一个**全自动化的 Tailscale DERP 中继服务部署方案**，专门针对**仅有公网 IP、无域名**的场景设计。主要解决以下痛点：

#### 核心目标

1. **零域名部署**：无需购买域名，仅凭公网 IP 即可搭建 DERP 中继
2. **安全优先**：自动生成基于 IP 的自签证书，使用证书指纹（`CertName`）验证，无需不安全的 `InsecureForTests` 标记
3. **开箱即用**：一条命令完成从依赖安装到服务启动的全流程
4. **生产级质量**：内置安全加固、健康检查、监控指标导出等企业级特性

#### 适用场景

- 🧪 **测试环境**：快速搭建临时中继节点
- 🏠 **家庭网络**：利用家宽公网 IP 搭建私有中继
- 👥 **小团队**：低成本构建内部 Tailscale 加速节点
- 🚀 **快速原型**：无需等待 DNS/证书配置，立即验证网络拓扑

---

### 🎯 核心特性

#### 1. 智能化部署

- ✅ **幂等设计**：多次运行安全，自动识别已有配置
- ✅ **参数自适应**：自动检测新旧版本 derper 参数差异（`-a` vs `-https-port`）
- ✅ **智能修复**：`--repair` 模式仅修复配置，不中断服务

#### 2. 安全加固

- 🔒 **分级安全策略**：basic/standard/paranoid 三级 systemd 加固
- 🔒 **灵活用户管理**：支持当前用户/专用用户/自定义用户三种模式
- 🔒 **客户端校验**：默认启用 `-verify-clients`，拒绝未授权访问
- 🔒 **权限最小化**：通过 `CAP_NET_BIND_SERVICE` 能力授予，无需 root 运行

#### 3. 企业级运维

- 📊 **健康检查**：内置 `--health-check` 输出服务状态摘要
- 📊 **Prometheus 集成**：导出 textfile 格式指标，无缝对接监控体系
- 🔧 **多模式运行**：check/repair/force 三种模式满足不同场景
- 🗑️ **完整卸载**：`--uninstall` 支持保留/清理/彻底删除三级选项

#### 4. 跨环境兼容

- 🐧 **多发行版支持**：Debian/Ubuntu/RHEL/CentOS/Fedora 等
- 🔥 **防火墙适配**：自动识别 UFW/firewalld/iptables
- 🌐 **国内网络优化**：内置 GOPROXY/GOSUMDB 镜像配置

---

### 🚀 使用方法

#### 快速开始（三步部署）

##### 第一步：登录 Tailscale（必需）

```bash
# 启动 tailscaled 守护进程
sudo systemctl enable --now tailscaled

# 登录 Tailnet（浏览器授权）
sudo tailscale up

# 或使用预生成 Auth Key（自动化部署）
sudo tailscale up --authkey tskey-xxxxxxxxxxxxxxxxxxxx
```

##### 第二步：预检查（推荐）

```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip <你的公网IP> \
  --check
```

**预检会输出：**
- 公网 IP 探测结果
- 端口占用情况
- Tailscale 安装与登录状态
- 系统依赖完整性
- 给出修复建议

##### 第三步：正式部署

**方案 A：个人/测试环境（使用当前用户，最简单）**

```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip <你的公网IP> \
  --use-current-user \
  --security-level basic \
  --auto-ufw
```

**方案 B：生产环境（专用用户 + 高安全）**

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

**方案 C：向导模式（新手友好）** 🆕

```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh wizard
```

向导会交互式询问：
1. 使用场景（个人/团队/生产）
2. 账户策略（当前用户/专用用户）
3. 端口选择（443/30399）
4. 是否启用客户端验证

然后自动生成适合你的部署命令。

---

### ⚙️ 参数详解

#### 默认参数（无需显式指定）

```bash
DERP_PORT="30399"              # DERP TLS 端口
STUN_PORT="3478"               # STUN UDP 端口
CERT_DAYS="365"                # 证书有效期（1 年）
INSTALL_DIR="/opt/derper"      # 安装目录
BIN_PATH="/usr/local/bin/derper"
VERIFY_CLIENTS_MODE="on"       # 启用客户端校验（安全默认）
SECURITY_LEVEL="standard"      # 标准安全级别
RUN_USER="${SUDO_USER:-$USER}" # 使用当前登录用户
```

#### 核心参数

##### 网络配置

| 参数 | 说明 | 默认值 | 示例 |
|------|------|--------|------|
| `--ip <IPv4>` | 服务器公网 IP | 自动探测 | `--ip 203.0.113.10` |
| `--derp-port <int>` | DERP TLS 端口 | 30399 | `--derp-port 443` |
| `--stun-port <int>` | STUN UDP 端口 | 3478 | `--stun-port 3478` |
| `--auto-ufw` | 自动配置 UFW 规则 | 关闭 | `--auto-ufw` |

**端口选择建议：**
- **30399**（默认）：避免与 Web 服务冲突，适合多服务器
- **443**：防火墙穿透性最佳，但需注意是否与 HTTPS 服务冲突

##### Go 构建配置（国内必备）

| 参数 | 说明 | 默认值 | 推荐值（国内） |
|------|------|--------|----------------|
| `--goproxy <URL>` | Go 模块代理 | 继承环境 | `https://goproxy.cn,direct` |
| `--gosumdb <VALUE>` | Go 校验数据库 | 继承环境 | `sum.golang.google.cn` |
| `--gotoolchain <MODE>` | 工具链策略 | `auto` | `auto`（自动获取 ≥1.25）|

##### 安全与账户管理

| 参数 | 说明 | 默认行为 | 使用场景 |
|------|------|----------|----------|
| `--use-current-user` | 使用当前登录用户 | ✅ 默认 | 个人服务器、测试环境 |
| `--dedicated-user` | 创建专用 `derper` 用户 | 关闭 | **生产环境强烈推荐** |
| `--user <username>` | 指定已有用户 | - | 集成到现有环境（如 `nobody`） |
| `--security-level <level>` | 安全加固级别 | `standard` | `basic`/`standard`/`paranoid` |

**安全级别对比：**

| 级别 | systemd 保护项 | 兼容性 | 适用场景 |
|------|----------------|--------|----------|
| **basic** | 最小保护（NoNewPrivileges + ProtectSystem） | 最佳 | 旧内核、嵌入式设备 |
| **standard** | 标准加固（+PrivateTmp +RestrictAddressFamilies） | 良好 | **推荐默认** |
| **paranoid** | 最严格（+ProtectProc +RestrictNamespaces） | 需要 Linux 5.8+、systemd 247+ | 高安全要求环境 |

##### 客户端验证

| 参数 | 说明 | 默认 | 安全影响 |
|------|------|------|----------|
| `--force-verify-clients` | 强制启用客户端校验 | ✅ 默认 | 仅允许 Tailnet 内设备连接 |
| `--no-verify-clients` | 禁用客户端校验 | 关闭 | ⚠️ 任何人可连接（仅测试用） |

##### ACL 区域配置

| 参数 | 说明 | 默认值 | 用途 |
|------|------|--------|------|
| `--region-id <int>` | ACL derpMap 的 RegionID | 900 | 唯一标识你的中继节点 |
| `--region-code <string>` | RegionCode | `my-derp` | 短代码（在 `tailscale status` 中显示） |
| `--region-name <string>` | RegionName | `My IP DERP` | 人类可读名称 |

##### 运行模式

| 参数 | 说明 | 系统影响 | 使用时机 |
|------|------|----------|----------|
| `--check` / `--dry-run` | 仅检查，不修改系统 | ❌ 无 | 诊断问题、验证参数 |
| `--repair` | 修复配置（证书/服务） | 🔧 重启服务 | 证书过期、配置漂移 |
| `--force` | 强制全量重装 | 🔄 完全重建 | 版本升级、彻底重置 |

##### 运维与监控

| 参数 | 说明 | 输出 | 适用场景 |
|------|------|------|----------|
| `--health-check` | 输出健康状态摘要 | 文本 + 退出码 | cron 定时检查、告警脚本 |
| `--metrics-textfile <path>` | 导出 Prometheus 指标 | `.prom` 文件 | 配合 node_exporter 监控 |

**Prometheus 指标示例：**

```prometheus
derper_up 1                          # 服务是否运行
derper_tls_listen 1                  # TLS 端口是否监听
derper_stun_listen 1                 # STUN 端口是否监听
derper_cert_days_remaining 287       # 证书剩余天数
derper_verify_clients 1              # 是否启用客户端校验
derper_process_rss_bytes 3145728     # 进程内存占用（字节）
```

##### 卸载清理

| 参数 | 说明 | 删除内容 | 保留内容 |
|------|------|----------|----------|
| `--uninstall` | 停止并删除服务 | systemd 单元 | 二进制、证书 |
| `--uninstall --purge` | + 删除安装目录 | + `/opt/derper` | 二进制 |
| `--uninstall --purge-all` | + 删除二进制 | + `/usr/local/bin/derper` | - |

---

### 🎬 部署流程演示

#### 完整示例：从零到可用

```bash
# 1. 登录服务器，确保有公网 IP
ssh user@203.0.113.10

# 2. 安装 Tailscale 客户端（如未安装）
curl -fsSL https://tailscale.com/install.sh | sh

# 3. 启动并登录 Tailnet
sudo systemctl enable --now tailscaled
sudo tailscale up  # 复制登录 URL 到浏览器

# 4. 下载部署脚本
git clone <repository-url>
cd tailscale-derp-quick-deploy

# 5. 预检查（推荐）
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip 203.0.113.10 \
  --check

# 6. 正式部署（国内网络）
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip 203.0.113.10 \
  --derp-port 443 \
  --dedicated-user \
  --security-level standard \
  --auto-ufw \
  --goproxy https://goproxy.cn,direct \
  --gosumdb sum.golang.google.cn

# 7. 脚本会自动完成：
#    ✅ 安装 Go、derper、openssl 等依赖
#    ✅ 生成自签证书（/opt/derper/certs/）
#    ✅ 创建 systemd 服务并启动
#    ✅ 输出 derpMap 配置片段
```

#### 输出示例

脚本成功后会输出类似内容：

```json
==================== 推荐粘贴到 Tailscale 管理后台的 derpMap 片段 ====================
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
            "HostName": "203.0.113.10",
            "DERPPort": 443,
            "CertName": "sha256-raw:a1b2c3d4e5f6..."
          }
        ]
      }
    }
  }
}
====================================================================================

完成：DERP 服务已部署并运行。
- 服务状态：systemctl status derper
- 实时日志：journalctl -u derper -f
- 证书位置：/opt/derper/certs/
```

---

### 🎯 达成效果

#### 1. 服务状态

部署完成后，你会获得：

```bash
# systemd 服务正常运行
$ systemctl status derper
● derper.service - Tailscale DERP with self-signed IP cert
     Loaded: loaded (/etc/systemd/system/derper.service; enabled)
     Active: active (running) since Mon 2025-01-10 10:00:00 UTC
```

#### 2. 端口监听验证

```bash
$ ss -tulpn | grep -E ':443|:3478'
tcp   LISTEN  0  4096  *:443   *:*     users:(("derper",pid=1234))
udp   LISTEN  0  4096  *:3478  *:*     users:(("derper",pid=1234))
```

#### 3. 证书指纹认证

**安全模型：**
```
客户端 → 连接 203.0.113.10:443
       ↓
       验证证书 DER 的 SHA256 是否匹配 ACL 中的 CertName
       ↓
   ✅ 匹配 → 建立连接
   ❌ 不匹配 → 拒绝连接（防中间人攻击）
```

**对比传统方案：**

| 方案 | 安全性 | 配置复杂度 | 成本 |
|------|--------|------------|------|
| **CertName 指纹（本脚本）** | ⭐⭐⭐⭐⭐ | 低 | 免费 |
| InsecureForTests | ⭐ | 极低 | 免费 |
| Let's Encrypt + 域名 | ⭐⭐⭐⭐⭐ | 中 | 需购买域名 |
| 商业 CA 证书 | ⭐⭐⭐⭐⭐ | 高 | 付费 |

#### 4. 客户端体验

在任意 Tailscale 客户端：

```bash
# 查看 DERP 延迟
$ tailscale netcheck
  * my-derp (203.0.113.10:443) = 15ms  ⭐ 最快

# 连接对端时自动选择最快中继
$ tailscale ping peer-device
pong from peer-device (100.x.x.x) via DERP(my-derp) in 18ms
```

#### 5. 监控集成效果

配合 Grafana 仪表盘：

```
┌─────────────────────────────────────┐
│  DERP 服务状态                       │
│  ✅ 运行中  Uptime: 15d 3h 42m      │
├─────────────────────────────────────┤
│  TLS 端口（443）     ✅ 监听        │
│  STUN 端口（3478）   ✅ 监听        │
│  证书有效期          287 天         │
│  内存占用            3.2 MiB        │
└─────────────────────────────────────┘
```

---

### 🔍 关键技术亮点

#### 1. 幂等性设计

```bash
# 第一次运行：完整安装
$ sudo bash script.sh --ip X.X.X.X
[步骤] 安装依赖...
[步骤] 构建 derper...
✅ 服务已启动

# 第二次运行：自动跳过
$ sudo bash script.sh --ip X.X.X.X
✅ 已就绪：检测到 derper 正在以纯 IP 模式运行，跳过安装。
```

#### 2. 智能故障恢复

脚本会自动检测并修复：
- ✅ 证书过期 → 自动重签
- ✅ 配置漂移 → 重写 systemd 单元
- ✅ 端口冲突 → 提前报错并提示
- ✅ 权限问题 → 自动配置 tailscaled socket ACL

#### 3. 跨版本兼容

```bash
# 自动适配新旧版本参数
if derper_supports_listen_a; then
    listen_flag="-a :${DERP_PORT}"      # 新版
elif derper_supports_https_port; then
    listen_flag="-https-port ${DERP_PORT}"  # 旧版
fi
```

---

### 📊 典型应用场景对比

| 场景 | 推荐配置 | 预期效果 |
|------|----------|----------|
| **个人学习** | `--use-current-user --security-level basic` | 5分钟部署，资源占用 < 5MB |
| **家庭网络** | `--derp-port 443 --auto-ufw` | 穿透率高，家人设备自动加速 |
| **小团队** | `--dedicated-user --health-check` | 稳定运行，配合监控告警 |
| **生产环境** | `--security-level paranoid --metrics-textfile` | 企业级安全，全链路可观测 |

---

### ⚠️ 重要说明

#### 必须阅读

1. **本脚本生成的是自签证书**，仅通过指纹验证，不被浏览器信任
   - ✅ 适合：Tailscale 内部中继（通过 CertName 验证）
   - ❌ 不适合：公开 Web 服务

2. **生产环境建议**：
   - 使用 443 端口提升穿透率
   - 启用 `--dedicated-user` 隔离权限
   - 配置 Prometheus 监控
   - 定期备份证书目录（指纹变化需更新 ACL）

3. **证书指纹固定机制**：
   - 一旦在 ACL 中配置 `CertName`，后续证书更换（如重签、轮换）会导致连接失败
   - 解决方法：重新运行脚本获取新指纹，更新 ACL

---

### 🎓 总结

这个项目通过一个 **2100+ 行的智能脚本**，将原本需要手动执行 20+ 步骤的 DERP 部署流程，压缩为**一条命令**，同时保证：

- ✅ **安全性**：企业级 systemd 加固 + 最小权限运行
- ✅ **稳定性**：幂等设计 + 自动故障恢复
- ✅ **可观测**：健康检查 + Prometheus 指标
- ✅ **易维护**：repair/force/uninstall 模式全覆盖

无论你是**个人用户快速搭建测试环境**，还是**企业团队构建生产级中继网络**，都能在 5 分钟内完成部署并投入使用。

---

### 📚 进一步阅读

- **详细技术文档**：
  - [更新日志（中文）](docs/CHANGELOG_CN.md) | [Changelog (English)](docs/CHANGELOG_EN.md)
  - [技术参考（中文）](docs/REFERENCE_CN.md) | [Technical Reference (English)](docs/REFERENCE_EN.md)

---

## 📄 License

MIT License - See [LICENSE](LICENSE) file for details

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📮 Support

- Issues: [GitHub Issues](../../issues)
- Documentation: [docs/](docs/)
