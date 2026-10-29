# Tailscale DERP Quick Deploy Script

> **Language / 语言**: [English](#english) | [中文](#中文)  
> **Version / 版本**: `0.3.0` · `bash scripts/deploy_derper_ip_selfsigned.sh --version`

维护入口 / Maintenance: [配置、CLI、本地导入、JSON、H0～H3 与证书轮换](docs/MAINTENANCE_CN.md) · [English guide](docs/MAINTENANCE_EN.md)。测试套件分工与命名约定见 [tests/README.md](tests/README.md)；生产迁移、隔离 Tailnet 真写和真实外部客户端验收单独记录。

---

<a id="english"></a>

## English

### 📋 Project Overview

This project provides a **fully automated Tailscale DERP relay service deployment solution**, specifically designed for scenarios with **only a public IP (no domain required)**. It addresses the following pain points:

#### Core Objectives

1. **Zero-Domain Deployment**: Build DERP relay with just a public IP, no domain purchase needed
2. **Security-First**: Auto-generate IP-based self-signed certificates with certificate fingerprint (`CertName`) verification, eliminating the need for insecure `InsecureForTests` flag
3. **Out-of-the-Box**: Complete deployment from dependency installation to service startup with a single command
4. **Hardened Operations**: Built-in security hardening, health checks, and Prometheus metrics export (best for test/home/small-scale; validate thoroughly before critical Tailnets)

#### Use Cases

- 🧪 **Testing Environments**: Quickly set up temporary relay nodes
- 🏠 **Home Networks**: Build private relays using home broadband public IPs
- 👥 **Small Teams**: Low-cost internal Tailscale acceleration nodes
- 🚀 **Rapid Prototyping**: Instant network topology validation without DNS/certificate configuration

---

### 🎯 Core Features

#### 1. Intelligent Deployment

- ✅ **Idempotent Design**: Safe to run multiple times, automatically detects existing configurations. Unspecified run user is inherited from the deployed unit.
- ✅ **Parameter Auto-Adaptation**: Auto-detects new/old derper parameter differences (`-a` vs `-https-port`)
- ✅ **Smart Repair**: `--repair` rewrites config/certs and restarts the service (no derper/Go reinstall, unless the installed binary drifts from the aligned target version). Replacing an existing certificate requires an explicit rotation acknowledgement.

#### 2. Security Hardening

- 🔒 **Tiered Security Policies**: Three-level systemd hardening (basic/standard/paranoid)
- 🔒 **Flexible User Management**: Supports current user/dedicated user/custom user modes
- 🔒 **Client Verification**: Enables `-verify-clients` by default, rejecting unauthorized access
- 🔒 **Privilege Minimization**: Grants `CAP_NET_BIND_SERVICE` capability, no root execution required

#### 3. Operations Tooling

- 📊 **Health Checks**: Built-in `--health-check` outputs service status summary
- 📊 **Prometheus Integration**: Exports textfile format metrics for seamless monitoring integration
- 🔧 **Multi-Mode Operation**: check/repair/force modes for different scenarios
- 🗑️ **Scoped Uninstall**: `--uninstall` supports three-level cleanup for service, install directory, binary, and script-created config

> Note: Health checks cover local service/listener/certificate state and the LocalAPI dependency. `netcheck` only probes regions; `debug derp` uses a temporary identity that `verify-clients` may correctly reject. Full H3 requires an independent authorized client, the specified Region, matching distributed certificate pin, actual relay round trip and a valid STUN response. See [the acceptance guide](docs/ACCEPTANCE_EN.md). Merge the generated node fragment into the existing policy; retain grants, SSH rules and other Regions.

For the operator workflow and Agent handoff, see [installation workflow](docs/INSTALL_WORKFLOW_EN.md) and [Agent installation preparation](docs/AGENT_INSTALL_EN.md). Manual maintenance does not enable periodic checks or external notifications. To opt into automatic certificate renewal later, follow the [OAuth authorization and maintenance setup guide](docs/AUTO_MAINTENANCE_EN.md).

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
  --derp-port 30399 \
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
RUN_USER="${SUDO_USER:-${USER:-$(id -un)}}" # Use current login user
```

#### Core Parameters

##### Network Configuration

| Parameter | Description | Default | Example |
|-----------|-------------|---------|---------|
| `--ip <IPv4>` | Server public IP (must be globally routable) | Auto-detect | `--ip <YOUR_PUBLIC_IP>` |
| `--derp-port <int>` | DERP TLS port | 30399 | `--derp-port 443` |
| `--stun-port <int>` | STUN UDP port (also written to derpMap `STUNPort`) | 3478 | `--stun-port 3478` |
| `--cert-days <int>` | Self-signed certificate validity in days (1–365000) | 365 | `--cert-days 365` |
| `--auto-ufw` | Auto-configure UFW rules | Off | `--auto-ufw` |

> Private/reserved/documentation/multicast addresses are **rejected** in deployment mode; for intranet testing pass `--allow-non-global-ip` explicitly.

**Port Selection Recommendations:**
- **30399** (default): Avoids conflicts with web services, suitable for multi-service servers
- **443**: Best firewall traversal, but check for HTTPS service conflicts

##### Go Build Configuration (Required for China Mainland)

While resolving the same-origin module version and downloading/building derper, the terminal refreshes animated dots and elapsed seconds every second and shows the stage time limit (60 and 900 seconds respectively). The dots mean the task is still running; the first dependency or toolchain download may take a while. The result and total duration are printed when a stage ends, and a build failure prints the error details. Redirected logs, `TERM=dumb`, and JSON mode keep only the static start/end messages; progress output goes to stderr.

Build caches (`GOPATH`, `GOMODCACHE`, and `GOCACHE`) stay in the run's secure temporary directory and are removed on exit. The script does not write to or clean the caller's existing `~/go`; later rebuilds download dependencies again.

| Parameter | Description | Default | Recommended (China) |
|-----------|-------------|---------|---------------------|
| `--goproxy <URL>` | Go module proxy (no automatic third-party fallback) | Inherit env | `https://goproxy.cn,direct` |
| `--gosumdb <VALUE>` | Go checksum database | Inherit env | `sum.golang.google.cn` |
| `--gotoolchain <MODE>` | Toolchain policy | `auto` | `auto` (auto-fetch ≥1.25) |
| `--derper-version <VER>` | Pin derper module version or git commit | `latest` | `--derper-version v1.80.0` |

##### Security & Account Management

| Parameter | Description | Default Behavior | Use Case |
|-----------|-------------|------------------|----------|
| `--use-current-user` | Use current login user (under sudo: `$SUDO_USER`) | ✅ Default (first deploy); explicit flag is never overridden | Personal servers, testing |
| `--dedicated-user` | Create dedicated `derper` user | Off; default only for first-time non-interactive root with no user flag | **Production strongly recommended** |
| `--user <username>` | Specify existing user | - | Integration (e.g., `nobody`) |
| `--allow-non-global-ip` | Allow private/reserved/doc IPs | Off | Intranet testing only |
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
| `--region-id <int>` | ACL derpMap RegionID (must be a JS-safe integer ≤ 2^53-1; 900-999 reserved for user regions) | 900 | Unique identifier for your relay node |
| `--region-code <string>` | RegionCode | `my-derp` | Short code (displayed in `tailscale status`) |
| `--region-name <string>` | RegionName | `My IP DERP` | Human-readable name |
| `--allow-region-id-conflict` | Explicitly share/replace an occupied RegionID | Off; other-node conflicts block | Multi-node or replacement after planning policy merge; existing Nodes must be retained manually |

Deploy and `--check` read `tailscale debug derp-map` with Python 3 for a read-only conflict preflight. The same single target remains idempotent. If the map cannot be read or parsed, the script warns that conflict status is unknown rather than claiming it is clear.

##### Operational Modes

| Parameter | Description | System Impact | When to Use |
|-----------|-------------|---------------|-------------|
| `--check` / `--dry-run` | Check only, no system changes. Prints both target and deployed run user. | ❌ None | Diagnose issues, verify parameters |
| `--repair` | Fix configuration (certs/service); reinstalls derper only if the binary drifts from the aligned version. Inherits deployed `User=` unless a user flag is given. | 🔧 Service restart | Certificate expiry, config drift |
| `--force` | Force complete reinstall | 🔄 Full rebuild | Version upgrade, complete reset |
| `--yes` / `--non-interactive` | Skip ordinary prompts | Does **not** confirm certificate fingerprint rotation | CI / automation |
| `--accept-cert-rotation` | Accept fingerprint change and the ACL cutover window | Required with `--yes`/`--force` when an existing cert would be replaced | Planned cert rotation |

`--accept-cert-rotation` means you accept a possible interruption between updating ACL and restarting DERP. It does **not** update Tailscale ACL for you. Interactive re-sign prompts for `rotate` instead.

##### Operations & Monitoring

| Parameter | Description | Output | Use Case |
|-----------|-------------|--------|----------|
| `--health-check` | Output health status summary. Exit 0 means healthy; any other status is not healthy (1 confirmed fault, 2 reserved for unknown and never reported as healthy). Not combined with `--check`, `--repair`, `--force`, or `--uninstall` | Text + exit code | cron periodic checks, alerting |
| `--metrics-textfile <path>` | Export Prometheus metrics (requires `--health-check` or `--install-healthcheck-cron`) | `.prom` file | With node_exporter monitoring |
| `--install-healthcheck-cron` | Install a 5-minute health check: with systemd a `derper-healthcheck.timer` (oneshot service that calls a root-owned stable copy via `bash`; the old cron is removed), otherwise `/etc/cron.d/derper-healthcheck`. A failed install rolls back and keeps the existing schedule | systemd timer or cron file | Hands-off health + metrics; not with `--health-check`/`--check` |
| `--tls-connlimit <N>` | Cap concurrent DERP TLS connections per source IP (explicit `0` removes installed rules; omit to leave them) | nftables/iptables rule | Soften TLS handshake floods; not with `--health-check`/`--check` |
| `--recover-interrupted` | Explicitly roll back an unfinished upgrade/migration from the saved recovery set; interrupted steps are never resumed automatically | Text + exit code | Recovering after an interrupted change; not with install/repair/check/uninstall |
| `prepare` / `apply` / `cancel` | Prepare a candidate certificate, switch it after `--accept-cert-rotation`, or discard it. `--yes` does not confirm rotation | Candidate files under the deploy-state directory; live service unchanged until apply | Planned fingerprint rotation; see [the maintenance guide](docs/MAINTENANCE_EN.md) |
| `--enable-auto-maintain` / `--disable-auto-maintain` | Record or clear on-host automatic renewal. Credentials stay in `/etc/derper/policy-api.env` (root, mode 0600), never in `deploy.conf` | Independent `derper-cert-maintain` timer, or its removal | Conditional auto-renewal when write scope and a Tailnet target are ready; GET/validate is not write permission |

`--uninstall` also removes the health-check timer/cron, certificate-maintain service/timer, and `--tls-connlimit` rules (the stable copy under `/usr/local/lib/derper-deploy` is kept). Remaining maintain unit files, enabled state, or running state exit non-zero and do not report completion. `--relax-socket-perms` restores the original socket mode when the script exits.

**Prometheus Metrics Example:**

```prometheus
derper_up 1                          # Service running status
derper_healthy 1                     # All health checks pass (0 on any failure or unknown result)
derper_tls_listen 1                  # TLS port listening
derper_stun_listen 1                 # STUN port listening
derper_cert_days_remaining 287       # Certificate remaining days
derper_cert_live_match 1             # Live certificate matches disk certificate
derper_verify_clients 1              # Client verification enabled in deployed unit
derper_pure_ip_config_ok 1           # Deployed unit runs in pure IP mode
derper_desired_config_ok 1           # Deployed unit matches requested parameters
derper_check_unknown 0               # 1 when the result is unknown (no permission / cannot collect) rather than a confirmed fault
derper_metrics_unixtime 1792540800   # Unix time the file was written; a stale value means the exporter is not running
derper_process_rss_bytes 3145728     # Process memory usage (bytes)
```

##### Uninstall & Cleanup

| Parameter | Description | Deleted Content | Retained Content |
|-----------|-------------|-----------------|------------------|
| `--uninstall` | Stop and remove service | systemd unit, health-check timer/cron, cert-maintain timer, `--tls-connlimit` rules | Binary, certificates, health-check stable copy, policy credential file |
| `--uninstall --purge` | + Remove installation directory | + `/opt/derper` | Binary |
| `--uninstall --purge-all` | + Remove binary and script-created config | + `/usr/local/bin/derper`, `/etc/derper/derper.env`, DERP tailscaled socket drop-in, health-check stable program/status, maintenance script copy and `target.conf` | Firewall rules, user/group accounts, unrelated files in the stable program directory |

---

### 🎬 Deployment Workflow Demo

#### Complete Example: Zero to Production

```bash
# 1. Login to server with public IP
ssh user@YOUR_PUBLIC_IP

# 2. Install Tailscale client (if not installed)
curl -fsSL https://tailscale.com/install.sh | sh

# 3. Start and login to Tailnet
sudo systemctl enable --now tailscaled
sudo tailscale up  # Copy login URL to browser

# 4. Download deployment script (tarball; no git required)
curl -fsSL https://github.com/wangminle/tailscale-derp-quick-deploy/archive/refs/heads/main.tar.gz \
  -o tailscale-derp-quick-deploy.tar.gz
tar -xzf tailscale-derp-quick-deploy.tar.gz
cd tailscale-derp-quick-deploy-main

# 5. Pre-check (recommended)
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip YOUR_PUBLIC_IP \
  --check

# 6. Formal deployment (China network)
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip YOUR_PUBLIC_IP \
  --derp-port 30399 \
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

Git users can instead run `git clone https://github.com/wangminle/tailscale-derp-quick-deploy.git` followed by `cd tailscale-derp-quick-deploy`.

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
            "DERPPort": 30399,
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
$ ss -tulpn | grep -E ':30399|:3478'
tcp   LISTEN  0  4096  *:30399   *:*     users:(("derper",pid=1234))
udp   LISTEN  0  4096  *:3478  *:*     users:(("derper",pid=1234))
```

#### 3. Certificate Fingerprint Authentication

**Security Model:**
```
Client → Connect to 203.0.113.10:30399
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
  * my-derp (203.0.113.10:30399) = 15ms  ⭐ Fastest

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
│  TLS Port (30399)      ✅ Listening   │
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

# Second run: Auto-skip when unit, ports, certificate, user, security level, and client verification match
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
| **Personal Learning** | `--ip YOUR_PUBLIC_IP --use-current-user --security-level basic` | 5-min deployment, < 5MB resource usage |
| **Home Network** | `--ip YOUR_PUBLIC_IP --derp-port 443 --auto-ufw --dedicated-user` | High traversal rate, auto-acceleration for family devices |
| **Small Teams** | `--ip YOUR_PUBLIC_IP --dedicated-user --install-healthcheck-cron` | Stable operation with periodic health + metrics |
| **Production pilot** | `--ip YOUR_PUBLIC_IP --dedicated-user --security-level paranoid --install-healthcheck-cron --metrics-textfile /var/lib/node_exporter/textfile_collector/derper.prom` | Stricter systemd hardening + observability (validate compatibility first) |

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

4. **Upstream Limitations of Self-Hosted DERP** (from `cmd/derper/README.md`):
   - Self-hosted DERP **does not support** cross-Tailnet/shared-node scenarios where nodes join multiple Tailnets.
   - Do **not** place the relay behind a generic HTTP reverse proxy or a global load balancer (DERP traffic must terminate directly at derper).
   - For production, prefer a host with **both static IPv4 and static IPv6**; changing the IP breaks the `HostName`/certificate pin.
   - Use `derpprobe` for protocol-level monitoring of your DERP node, in addition to this script's health checks.
   - A self-signed certificate is verified via `CertName` fingerprint pinning only; it is not suitable for browser-facing services.

5. **Host & Tailnet Hardening** (the real risk of a public relay is the host itself):
   - Cloud security group inbound: only `DERP TLS` + `STUN` ports; never open `22/tcp` to `0.0.0.0/0`.
   - Use system OpenSSH (`sshd`) over the Tailnet, or restrict source IPs and disable password authentication; keep the cloud VNC/console as fallback. This script does not enable the separate Tailscale SSH feature (`--ssh`) or invoke `tailscale ssh`.
   - Do **not** restrict egress: tailscaled needs the control plane and official DERP/STUN probes.
   - Single-purpose host: run only derper + tailscaled; enable automatic security updates (`unattended-upgrades` / `dnf-automatic`).
   - Tailscale ACLs are allow-all by default: tag this server (e.g. `tag:derper-server`) and grant it no `src` access, so "relay compromise ≠ tailnet compromise".
   - The script's deploy/check/health-check runs report extra non-loopback listeners and auto-update status; watch `journalctl -u derper` for `-verify-clients` rejections.

---

### 🎓 Summary

This project compresses the originally manual **20+ steps DERP deployment process** into **a single command** through an intelligent **~4100-line script**, while ensuring:

- ✅ **Security**: Tiered systemd hardening + least-privilege execution
- ✅ **Stability**: Idempotent design + automatic fault recovery
- ✅ **Observability**: Health checks + Prometheus metrics
- ✅ **Maintainability**: repair/force/uninstall modes covered

Whether you're an **individual user quickly setting up a testing environment** or a **small team building a private relay**, you can deploy quickly. For critical Tailnets, validate certificates, version alignment, and real client connectivity first.

---

### 📚 Further Reading

- **Detailed Technical Documentation**:
  - [User Guide (English)](docs/REFERENCE_EN.md) | [用户指南（中文）](docs/REFERENCE_CN.md)
  - [Changelog (English)](docs/CHANGELOG_EN.md) | [更新日志（中文）](docs/CHANGELOG_CN.md)

### Documentation Layout

- `docs/`: all product usage documents — the detailed user guides (`REFERENCE_EN.md` / `REFERENCE_CN.md`), maintenance guides, and the bilingual changelogs (`CHANGELOG_EN.md` / `CHANGELOG_CN.md`).
- `design/plans/`: formal requirements, designs, and development plans (local, not versioned).
- `design/checkpoints/`: review, inspection, research, and evaluation reports; execution results, deployment records, and historical snapshots (local, not versioned).
- Repository root: this quickstart `README.md`, `VERSION`, and the task ledger `task-list.md`.

---

<a id="中文"></a>

## 中文

### 📋 项目概述

本项目提供了一个**全自动化的 Tailscale DERP 中继服务部署方案**，专门针对**仅有公网 IP、无域名**的场景设计。主要解决以下痛点：

#### 核心目标

1. **零域名部署**：无需购买域名，仅凭公网 IP 即可搭建 DERP 中继
2. **安全优先**：自动生成基于 IP 的自签证书，使用证书指纹（`CertName`）验证，无需不安全的 `InsecureForTests` 标记
3. **开箱即用**：一条命令完成从依赖安装到服务启动的全流程
4. **运维加固**：内置安全加固、健康检查、监控指标导出（适合测试/家用/小规模；关键 Tailnet 请先完成集成验证）

#### 适用场景

- 🧪 **测试环境**：快速搭建临时中继节点
- 🏠 **家庭网络**：利用家宽公网 IP 搭建私有中继
- 👥 **小团队**：低成本构建内部 Tailscale 加速节点
- 🚀 **快速原型**：无需等待 DNS/证书配置，立即验证网络拓扑

---

### 🎯 核心特性

#### 1. 智能化部署

- ✅ **幂等设计**：可多次安全运行，自动检测已有配置。未指定运行用户时继承已部署 unit 的 `User=`。
- ✅ **参数自适应**：自动检测新旧版本 derper 参数差异（`-a` vs `-https-port`）
- ✅ **智能修复**：`--repair` 仅重写配置/证书并重启服务，不重装 derper/Go（已部署二进制与目标版本不一致时除外）。替换已有证书需要显式轮换确认。

#### 2. 安全加固

- 🔒 **分级安全策略**：basic/standard/paranoid 三级 systemd 加固
- 🔒 **灵活用户管理**：支持当前用户/专用用户/自定义用户三种模式
- 🔒 **客户端校验**：默认启用 `-verify-clients`，拒绝未授权访问
- 🔒 **权限最小化**：通过 `CAP_NET_BIND_SERVICE` 能力授予，无需 root 运行

#### 3. 运维工具

- 📊 **健康检查**：内置 `--health-check` 输出服务状态摘要
- 📊 **Prometheus 集成**：导出 textfile 格式指标，无缝对接监控体系
- 🔧 **多模式运行**：check/repair/force 三种模式满足不同场景
- 🗑️ **分级卸载**：`--uninstall` 支持服务、安装目录、二进制和脚本生成配置的三级清理

> 说明：健康检查覆盖本机服务/监听/证书和 LocalAPI 依赖。`netcheck` 只探测区域；`debug derp` 使用临时身份，可能被 `verify-clients` 正常拒绝。完整 H3 必须由独立合法客户端核对指定 Region、下发指纹、真实中继往返和 STUN 响应，见[公网与中继验收指南](docs/ACCEPTANCE_CN.md)。生成的节点片段必须合并到既有策略，保留 grants、ssh 和其他 Regions。

用户操作与 Agent 交接见[安装业务闭环](docs/INSTALL_WORKFLOW_CN.md)及[Agent 安装准备](docs/AGENT_INSTALL_CN.md)。人工维护不表示已启用周期检查或站外通知。后续选择自动换证时，按[OAuth 授权与维护安装指南](docs/AUTO_MAINTENANCE_CN.md)操作。

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
  --derp-port 30399 \
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
RUN_USER="${SUDO_USER:-${USER:-$(id -un)}}" # 使用当前登录用户
```

#### 核心参数

##### 网络配置

| 参数 | 说明 | 默认值 | 示例 |
|------|------|--------|------|
| `--ip <IPv4>` | 服务器公网 IP（必须全局可路由） | 自动探测 | `--ip <YOUR_PUBLIC_IP>` |
| `--derp-port <int>` | DERP TLS 端口 | 30399 | `--derp-port 443` |
| `--stun-port <int>` | STUN UDP 端口（同时写入 derpMap 的 STUNPort） | 3478 | `--stun-port 3478` |
| `--cert-days <int>` | 自签证书有效期（天，1–365000） | 365 | `--cert-days 365` |
| `--auto-ufw` | 自动配置 UFW 规则 | 关闭 | `--auto-ufw` |

> 部署模式会**拒绝**私有/保留/文档/组播等非公网地址；内网测试请显式添加 `--allow-non-global-ip`。

**端口选择建议：**
- **30399**（默认）：避免与 Web 服务冲突，适合多服务器
- **443**：防火墙穿透性最佳，但需注意是否与 HTTPS 服务冲突

##### Go 构建配置（国内必备）

同源模块版本解析和下载/编译 derper 时，终端每秒刷新跳点与已等待秒数，并显示阶段时限（分别为 60 秒和 900 秒）。跳点表示任务仍在执行；首次下载依赖或工具链可能较慢。结束后显示结果与耗时，构建失败会输出错误详情。重定向日志、`TERM=dumb` 或 JSON 模式只保留静态起止提示，进度信息写入 stderr。

构建缓存（`GOPATH`、`GOMODCACHE`、`GOCACHE`）只放在本次安全临时目录并随退出清理，不写入或删除调用者已有的 `~/go`；后续重建会重新下载依赖。

| 参数 | 说明 | 默认值 | 推荐值（国内） |
|------|------|--------|----------------|
| `--goproxy <URL>` | Go 模块代理（不会自动切换第三方代理） | 继承环境 | `https://goproxy.cn,direct` |
| `--gosumdb <VALUE>` | Go 校验数据库 | 继承环境 | `sum.golang.google.cn` |
| `--gotoolchain <MODE>` | 工具链策略 | `auto` | `auto`（自动获取 ≥1.25）|
| `--derper-version <VER>` | 固定 derper 模块版本或 git commit | `latest` | `--derper-version v1.80.0` |

##### 安全与账户管理

| 参数 | 说明 | 默认行为 | 使用场景 |
|------|------|----------|----------|
| `--use-current-user` | 使用当前登录用户（sudo 下为 `$SUDO_USER`） | ✅ 默认（首次部署）；显式指定后不会被覆盖 | 个人服务器、测试环境 |
| `--dedicated-user` | 创建专用 `derper` 用户 | 关闭；仅首次非交互 root 且未指定用户时作为默认 | **生产环境强烈推荐** |
| `--user <username>` | 指定已有用户 | - | 集成到现有环境（如 `nobody`） |
| `--allow-non-global-ip` | 允许私有/保留/文档等非公网 IP | 关闭 | 仅内网测试 |
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
| `--region-id <int>` | ACL derpMap 的 RegionID（须为 JS 安全整数 ≤ 2^53-1；900-999 保留给用户自建区域） | 900 | 唯一标识你的中继节点 |
| `--region-code <string>` | RegionCode | `my-derp` | 短代码（在 `tailscale status` 中显示） |
| `--region-name <string>` | RegionName | `My IP DERP` | 人类可读名称 |
| `--allow-region-id-conflict` | 显式共用/替换已占用 RegionID | 关闭；其他节点冲突默认阻断 | 规划多节点或替换后使用；既有 Nodes 仍须人工保留 |

部署与 `--check` 会使用 Python 3 只读解析 `tailscale debug derp-map` 做冲突预检；同一唯一目标允许幂等修复。无法读取或解析时会明确报告“无法确认”，不会冒充无冲突。

##### 运行模式

| 参数 | 说明 | 系统影响 | 使用时机 |
|------|------|----------|----------|
| `--check` / `--dry-run` | 仅检查，不修改系统。同时打印目标运行用户与已部署用户。 | ❌ 无 | 诊断问题、验证参数 |
| `--repair` | 修复配置（证书/服务）；仅当已部署二进制与对齐目标版本不一致时才重装 derper。未指定用户时继承已部署 `User=`。 | 🔧 重启服务 | 证书过期、配置漂移 |
| `--force` | 强制全量重装 | 🔄 完全重建 | 版本升级、彻底重置 |
| `--yes` / `--non-interactive` | 跳过普通交互确认 | **不能**代替证书指纹轮换确认 | CI / 自动化 |
| `--accept-cert-rotation` | 确认接受指纹切换及 ACL 更新窗口 | 非交互下替换已有证书时必须附加 | 计划内证书轮换 |

`--accept-cert-rotation` 表示你接受 ACL 更新与服务重启之间可能中断，**并不表示脚本已替你更新 Tailscale ACL**。交互模式重签时改为输入 `rotate`。

##### 运维与监控

| 参数 | 说明 | 输出 | 适用场景 |
|------|------|------|----------|
| `--health-check` | 输出健康状态摘要。退出码 0 为健康，其他值都表示未通过（1 已确认故障，2 保留给未知且不会报健康）。不能与 `--check`、`--repair`、`--force`、`--uninstall` 同用 | 文本 + 退出码 | cron 定时检查、告警脚本 |
| `--metrics-textfile <path>` | 导出 Prometheus 指标（必须与 `--health-check` 或 `--install-healthcheck-cron` 一起使用） | `.prom` 文件 | 配合 node_exporter 监控 |
| `--install-healthcheck-cron` | 安装每 5 分钟的健康检查：有 systemd 时写 `derper-healthcheck.timer`（oneshot 服务以 `bash` 调用 root 管理的稳定副本，并删除旧 cron），否则写 `/etc/cron.d/derper-healthcheck`。安装失败会回滚并保留原调度 | systemd timer 或 cron 文件 | 无人值守健康检查与指标；不能与 `--health-check`/`--check` 同用 |
| `--tls-connlimit <N>` | 限制单 IP 并发 DERP TLS 连接（显式 `0` 移除已装规则；省略则不改动） | nftables/iptables 规则 | 缓解 TLS 握手洪水；不能与 `--health-check`/`--check` 同用 |
| `--recover-interrupted` | 用保存的恢复集显式回退未完成的升级/迁移；不会自动继续中断的步骤 | 文本 + 退出码 | 中断后的显式恢复；不能与安装/修复/检查/卸载同用 |
| `prepare` / `apply` / `cancel` | 生成候选证书、确认后切换，或丢弃候选。`--yes` 不能代替 `--accept-cert-rotation` | 部署状态目录中的候选；apply 前不切换正在运行的服务 | 计划内指纹轮换；详见 [维护指南](docs/MAINTENANCE_CN.md) |
| `--enable-auto-maintain` / `--disable-auto-maintain` | 登记或关闭同机自动换证。凭据只放 `/etc/derper/policy-api.env`（root、0600），不进入 deploy.conf | 独立 `derper-cert-maintain` timer，或将其删除 | 写授权与 Tailnet 目标就绪时的条件式自动维护；GET/validate 成功不能证明可写 |

`--uninstall` 会同时删除健康检查 timer/cron、证书维护 service/timer 与 `--tls-connlimit` 规则（`/usr/local/lib/derper-deploy` 下的稳定副本保留）。维护 unit 文件、启用或运行状态残留时退出非零，不报告完成。`--relax-socket-perms` 在脚本退出时恢复 socket 原权限。

**Prometheus 指标示例：**

```prometheus
derper_up 1                          # 服务是否运行
derper_healthy 1                     # 全部健康检查是否通过（任一失败或结果未知为 0）
derper_tls_listen 1                  # TLS 端口是否监听
derper_stun_listen 1                 # STUN 端口是否监听
derper_cert_days_remaining 287       # 证书剩余天数
derper_cert_live_match 1             # 在线证书与磁盘证书是否一致
derper_verify_clients 1              # 已部署 unit 是否启用客户端校验
derper_pure_ip_config_ok 1           # 已部署 unit 是否为纯 IP 模式
derper_desired_config_ok 1           # 已部署 unit 是否与本次目标参数一致
derper_check_unknown 0               # 结果为未知（无权限/无法采集）而非已确认故障时为 1
derper_metrics_unixtime 1792540800   # 指标文件写入时间；长期不变说明采集没有在跑
derper_process_rss_bytes 3145728     # 进程内存占用（字节）
```

##### 卸载清理

| 参数 | 说明 | 删除内容 | 保留内容 |
|------|------|----------|----------|
| `--uninstall` | 停止并删除服务 | systemd 单元、健康检查 timer/cron、证书维护 timer、`--tls-connlimit` 规则 | 二进制、证书、健康检查稳定副本、策略凭据文件 |
| `--uninstall --purge` | + 删除安装目录 | + `/opt/derper` | 二进制 |
| `--uninstall --purge-all` | + 删除二进制和脚本生成配置 | + `/usr/local/bin/derper`、`/etc/derper/derper.env`、DERP 创建的 tailscaled socket drop-in、健康检查稳定程序及状态、维护脚本副本及 `target.conf` | 防火墙规则、用户/组账户、稳定副本目录中的其他用户文件 |

---

### 🎬 部署流程演示

#### 完整示例：从零到可用

```bash
# 1. 登录服务器，确保有公网 IP
ssh user@YOUR_PUBLIC_IP

# 2. 安装 Tailscale 客户端（如未安装）
curl -fsSL https://tailscale.com/install.sh | sh

# 3. 启动并登录 Tailnet
sudo systemctl enable --now tailscaled
sudo tailscale up  # 复制登录 URL 到浏览器

# 4. 下载部署脚本（tarball，无需 git）
curl -fsSL https://github.com/wangminle/tailscale-derp-quick-deploy/archive/refs/heads/main.tar.gz \
  -o tailscale-derp-quick-deploy.tar.gz
tar -xzf tailscale-derp-quick-deploy.tar.gz
cd tailscale-derp-quick-deploy-main

# 5. 预检查（推荐）
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip YOUR_PUBLIC_IP \
  --check

# 6. 正式部署（国内网络）
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip YOUR_PUBLIC_IP \
  --derp-port 30399 \
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

使用 Git 时也可执行 `git clone https://github.com/wangminle/tailscale-derp-quick-deploy.git`，再进入 `tailscale-derp-quick-deploy` 目录。

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
            "DERPPort": 30399,
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
$ ss -tulpn | grep -E ':30399|:3478'
tcp   LISTEN  0  4096  *:30399   *:*     users:(("derper",pid=1234))
udp   LISTEN  0  4096  *:3478  *:*     users:(("derper",pid=1234))
```

#### 3. 证书指纹认证

**安全模型：**
```
客户端 → 连接 203.0.113.10:30399
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
  * my-derp (203.0.113.10:30399) = 15ms  ⭐ 最快

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
│  TLS 端口（30399）     ✅ 监听        │
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

# 第二次运行：若 unit、端口、证书、运行用户、安全级别和客户端校验均匹配，则自动跳过
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
| **个人学习** | `--ip YOUR_PUBLIC_IP --use-current-user --security-level basic` | 5分钟部署，资源占用 < 5MB |
| **家庭网络** | `--ip YOUR_PUBLIC_IP --derp-port 443 --auto-ufw --dedicated-user` | 穿透率高，家人设备自动加速 |
| **小团队** | `--ip YOUR_PUBLIC_IP --dedicated-user --install-healthcheck-cron` | 稳定运行，周期健康检查与指标 |
| **加固试点** | `--ip YOUR_PUBLIC_IP --dedicated-user --security-level paranoid --install-healthcheck-cron --metrics-textfile /var/lib/node_exporter/textfile_collector/derper.prom` | 更严 systemd 加固 + 可观测（需先验证兼容性） |

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

4. **自建 DERP 的上游限制**（摘自 `cmd/derper/README.md`）：
   - 自建 DERP **不支持**部分跨 Tailnet/节点分享（多 Tailnet 加入）场景。
   - 不要把中继放在普通 HTTP 反向代理或全局负载均衡后面（DERP 流量必须直连 derper）。
   - 生产环境建议使用**同时具备静态 IPv4 与静态 IPv6** 的服务器；更换 IP 会破坏 HostName/证书固定。
   - 除本脚本健康检查外，建议使用 `derpprobe` 做协议级监控。
   - 自签证书仅通过 `CertName` 指纹固定校验，不适用于面向浏览器的服务。

5. **主机与 Tailnet 加固**（公网中继的真正风险在主机本身）：
   - 云安全组入方向只放行 DERP TLS + STUN 两个端口，`22/tcp` 绝不对 `0.0.0.0/0` 开放。
   - 使用系统 OpenSSH（`sshd`）经 Tailnet 传输，或限源 IP + 禁用密码登录，保留云厂商 VNC/控制台兜底。本脚本不启用独立的 Tailscale SSH 功能（`--ssh`），也不调用 `tailscale ssh`。
   - 出方向不要收紧：tailscaled 需要访问控制面与官方 DERP/STUN 探测。
   - 单机单用途：只跑 derper + tailscaled；开启自动安全更新（`unattended-upgrades` / `dnf-automatic`）。
   - Tailscale 默认 ACL 全通：给本服务器打 tag（如 `tag:derper-server`）且不授予任何 `src` 放行，“中继被攻破 ≠ 内网失守”。
   - 脚本的部署/检查/健康检查会自动报告非回环额外监听端口与自动更新状态；定期查看 `journalctl -u derper` 的 `-verify-clients` 拒绝记录。

---

### 🎓 总结

这个项目通过一个 **约 4100 行的智能脚本**，将原本需要手动执行 20+ 步骤的 DERP 部署流程，压缩为**一条命令**，同时保证：

- ✅ **安全性**：分级 systemd 加固 + 最小权限运行
- ✅ **稳定性**：幂等设计 + 自动故障恢复
- ✅ **可观测**：健康检查 + Prometheus 指标
- ✅ **易维护**：repair/force/uninstall 模式齐全

无论你是**个人用户快速搭建测试环境**，还是**小团队构建自建中继**，都能较快完成部署。关键 Tailnet 请先完成证书、版本对齐与真实客户端连通性验证。

---

### 📚 进一步阅读

- **详细技术文档**：
  - [用户指南（中文）](docs/REFERENCE_CN.md) | [User Guide (English)](docs/REFERENCE_EN.md)
  - [更新日志（中文）](docs/CHANGELOG_CN.md) | [Changelog (English)](docs/CHANGELOG_EN.md)
  - 审查记录见仓库根目录 `task-list.md`（CHK-004～CHK-007）

### 文档目录约定

- `docs/`：全部产品使用文档——详细用户指南（`REFERENCE_CN.md` / `REFERENCE_EN.md`）、维护指南（`MAINTENANCE_CN.md` / `MAINTENANCE_EN.md`）与中英文更新日志（`CHANGELOG_CN.md` / `CHANGELOG_EN.md`）。
- `design/plans/`：正式需求、设计和开发实施计划；保留本地，不纳入版本控制。
- `design/checkpoints/`：review、检查、调研和评估报告，以及执行结果、部署记录与历史快照；保留本地，不纳入版本控制。
- 仓库根目录：快速上手 `README.md`、`VERSION` 与实际任务台账 `task-list.md`。

---

## 📄 License

MIT License - See [LICENSE](LICENSE) file for details

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📮 Support

- Issues: [GitHub Issues](../../issues)
- Documentation: [docs/](docs/)
