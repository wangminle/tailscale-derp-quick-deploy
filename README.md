# DERP Deployment Guide with IP-based Self-signed Certificate

> **[中文版 README](README_cn.md) | English**

> **Script File**: `deploy_derper_ip_selfsigned.sh`

![Linux](https://img.shields.io/badge/OS-Linux-blue?logo=linux&logoColor=white)
![systemd](https://img.shields.io/badge/Service-systemd-orange?logo=systemd&logoColor=white)
![Public IPv4 Required](https://img.shields.io/badge/Network-Public%20IPv4%20Required-red?logo=cloudflare&logoColor=white)
![Bash](https://img.shields.io/badge/Shell-Bash-green?logo=gnu-bash&logoColor=white)

This solution automatically deploys Tailscale DERP relay service (`derper`) on Linux servers with only a public IP (no domain required), auto-generates "IP-based self-signed certificates", configures `systemd` service, and outputs a `derpMap` configuration snippet that can be directly pasted into Tailscale admin console (using certificate fingerprint `CertName` for better security).

**Features**:
- ✅ Idempotent and reentrant, supports check, repair, and force reinstall modes
- ✅ Auto-detects new/old derper parameters (`-a` vs `-https-port`)
- ✅ Enables `-verify-clients` by default for client verification (security first)
- ✅ Built-in health check and Prometheus metrics export
- ✅ Supports uninstall and cleanup

**Use Cases**: Testing environments, temporary deployments, home small-scale relay. For production, we recommend using trusted CA certificates + port 443.

---

## Prerequisites

### Operating System Requirements (Mandatory)

> ⚠️ **Important Notice**: This script **ONLY supports Linux systems**, NOT compatible with macOS or WSL environments

**✅ Supported Deployment Environments**:
- **Cloud Servers**: Alibaba Cloud, Tencent Cloud, AWS, DigitalOcean, Vultr, etc.
- **VPS/Dedicated Servers**: Any Linux server with public IPv4 access
- **Home Linux Devices**: Raspberry Pi, soft routers, NAS (with port forwarding and public IP)

**❌ Unsupported Environments**:
- **macOS**: Desktop systems typically behind NAT, lack public accessibility, unsuitable for 24/7 online DERP relay nodes
- **WSL (Windows Subsystem for Linux)**: Behind double NAT, incomplete network stack, cannot provide stable public services
- **Devices without public IP**: DERP relay services must be accessible from other devices on the internet

**Local Development Testing**:
If you need to test the `derper` program itself on macOS/WSL (not for production deployment), you can manually run it in foreground:
```bash
derper -hostname 127.0.0.1 -certmode manual -certdir ./certs \
  -http-port -1 -a :30399 -stun
```
Note: This mode is only for local functional verification and cannot serve as a relay node for Tailscale network.

---

### Hardware & Network
- A Linux host with **public IPv4** (cloud server or home broadband device accessible from the internet)
- Ports must be accessible: `DERP_PORT/tcp` (default 30399), `STUN_PORT/udp` (default 3478)
- Outbound network access to Go module proxy (for China mainland, configure `GOPROXY` and `GOSUMDB`)

### Permissions & System
- Requires **root privileges** to run the script (or use `sudo`)
- Recommended to use **systemd** as service manager (script will auto-detect and provide manual run examples if incompatible)

### Security Settings (Important)
- **`-verify-clients` enabled by default**: Script checks if local `tailscaled` is running and logged in before installation
  - ✅ If not ready, script will abort and show login instructions
  - ⚠️ To skip verification, use `--no-verify-clients` (**testing only**)
  - 📝 Detection logic:
    - If `tailscale` CLI detected, checks via `tailscale ip` whether Tailnet IP is assigned
    - If CLI not detected, only checks `tailscaled` running status

### Additional Notes
- Auto-detection of public IP relies on `curl`/`dig` tools
- If system lacks these tools, use `--ip <your-public-ip>` to specify explicitly

---

## Quick Start

1) Login to server and start `tailscaled` (recommended)

```bash
sudo systemctl enable --now tailscaled
sudo tailscale up            # First run will output authorization link, login via browser
# Or use pre-generated key:
# sudo tailscale up --authkey tskey-xxxx
```

2) Pre-check (check only, no system changes)

```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh --ip <your-public-ip> --check
```

Note: Pre-check won't modify system or open ports, only outputs current environment and parameter check results, plus suggested next actions. If it shows tailscaled not logged in, port conflicts, or missing dependencies, handle them first as instructed.

3) Run deployment script (formal installation/repair; example for China mainland, with `-verify-clients` enabled by default)

```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip <your-public-ip> \
  --derp-port 30399 --stun-port 3478 --auto-ufw \
  --goproxy https://goproxy.cn,direct \
  --gosumdb sum.golang.google.cn \
  --gotoolchain auto
```

After completion, the script will (made idempotent, will skip if already ready; dependencies installed "on-demand", won't access package repositories if all present):
- Install dependencies (`git/curl/openssl/golang/netcat` etc.)
- Install/build `derper` (using `GOTOOLCHAIN=auto` to auto-fetch matching version)
- Generate "IP-based self-signed certificate" to `/opt/derper/certs/`
- Write and start `systemd` service `/etc/systemd/system/derper.service`
- Print port opening instructions and run self-check
- Output `derpMap` snippet with `CertName` (certificate fingerprint) - directly paste to Tailscale ACL

### Common Abort Reasons & Solutions (with Login Flow Diagram)

```text
Login Flow (Diagram):
  sudo systemctl enable --now tailscaled    # Or other service manager to start tailscaled
  sudo tailscale up                         # Terminal prints login URL
        │
        ├──> Open URL in browser to authorize
        │
        └──> tailscaled obtains login state (connects to Tailnet)
               │
               └──> Re-run script, pre-check passes (-verify-clients)
```

- tailscaled not running/not logged in (most common)
  - Solution: `sudo systemctl enable --now tailscaled && sudo tailscale up`
  - Non-systemd environments: OpenRC (`rc-service tailscaled start`), SysV (`service tailscaled start`).
- Cannot auto-detect public IP:
  - Solution: Manually specify `--ip <your-public-ip>`; or confirm outbound network is available (curl/dig). Minimal systems may lack `curl/dig`, install them first or explicitly pass `--ip`.
- Port occupied:
  - Solution: `ss -tulpn | grep -E ':30399|:3478'` to check occupying process, or use different ports. Script will pre-check port conflicts before writing service and abort with prompt if found.
- Missing dependencies/network restrictions causing installation failure:
  - Solution: Configure China mainland mirrors for Go: `--goproxy https://goproxy.cn,direct --gosumdb sum.golang.google.cn`.
- systemd not detected:
  - Solution: Script cannot write systemd service; use other service manager or manually run `derper` in foreground.
- Insufficient permissions:
  - Solution: Use `sudo` to run script.

Tip: The "pre-check" step can also use `--dry-run`, equivalent to `--check`.

---

## Pre-check Results Interpretation & Common Solutions

Pre-check outputs several key items, their meanings and solutions (in order of appearance):

- Public IP
  - Empty/incorrect: Use `--ip <your-public-ip>` to specify; if detecting private IP, need to bind public IP to host or do port forwarding (and confirm external accessibility).
- DERP Port / STUN Port
  - Port conflict: Use `ss -tulpn | grep -E ':<DERP_PORT>|:<STUN_PORT>'` to troubleshoot occupation, release process or change `--derp-port/--stun-port`; also open cloud security groups/UFW/iptables.
- tailscale status (installed/running/version/meets threshold)
  - Installed=0: Install tailscale via distro package manager (or official one-liner: `curl -fsSL https://tailscale.com/install.sh | sh`).
  - Running=0: `sudo systemctl enable --now tailscaled`.
  - Meets=false: Upgrade to `REQUIRED_TS_VER` or higher.
  - Not logged in: `sudo tailscale up` to complete login (or use `--authkey`).
- derper components (binary/service file/running)
  - Binary=0: Formal installation phase will auto-build; for offline environments, use `go install tailscale.com/cmd/derper@latest`.
  - Service file=0: Formal installation will auto-write to systemd; for non-systemd see "Service Manager" below.
  - Running=0: `journalctl -u derper -f` to check logs, mostly port conflicts or cert path/permission issues.
- Port listening (TLS / STUN)
  - Is 0: Service not running, blocked by firewall/security groups, or listening port doesn't match expected; open `${DERP_PORT}/tcp` and `${STUN_PORT}/udp`, for UFW execute `ufw allow <port>/tcp|udp`.
- Pure IP configuration detection (based on unit)
  - Is 0: Current unit is not "pure IP mode" (e.g., HostName is not IP). Execute `--repair` to rewrite, or `--force` for full reinstall; if public IP changed, sync `--ip`.
- Certificate (exists/SAN matches IP/not expiring within 30 days)
  - Any is 0: Re-run script (or `--repair`) to re-sign certificate; if IP changed ensure `--ip` points to new IP; if missing openssl, install first.
- Client verification mode
  - on: Enables `-verify-clients`, requires local tailscaled to be logged in (recommended). For testing only, use `--no-verify-clients` temporarily (not recommended long-term).
- Critical executable checks
  - Missing items (like curl/openssl/git/go): Formal installation will fill on-demand; for offline/restricted networks, install via package manager first.
- Service manager
  - systemd not detected: Cannot write service. Can run manually in foreground (example):
    `derper -hostname <your-public-ip> -certmode manual -certdir /opt/derper/certs -http-port -1 -a :30399 -stun -stun-port 3478 -verify-clients`
    Note: For older versions not supporting `-a/-stun-port`, use `-https-port 30399` and remove `-stun-port`.
- Non-systemd environments will show manual run examples, installation process will abort.
- Suggestions (summary of recommended actions)
  - `<Ready: can skip directly>`: No action needed.
  - `Install derper (missing binary)`: Execute formal installation command from "Quick Start".
  - `--repair`: Only fix config/certificates, don't interrupt available dependencies.
  - `--force`: Full reinstall (binary/certificates/service).

Common paths:
- Pre-check no fatal issues → Directly proceed to formal installation (or `--repair`).
- Pre-check shows "not logged in/port conflict/missing dependencies" → Handle first as above, then execute formal installation.

---

## Script Parameters

```text
--ip <IPv4>               Server public IP (recommended explicit; defaults to auto-detect)
--derp-port <int>         DERP TLS port, default 30399/TCP
--stun-port <int>         STUN port, default 3478/UDP
--cert-days <int>         Self-signed cert validity (days), default 365
--auto-ufw                If UFW detected, auto-open ports

--goproxy <URL>           Go module proxy, e.g.: https://goproxy.cn,direct
--gosumdb <VALUE>         Go checksum database, e.g.: sum.golang.google.cn
--gotoolchain <MODE>      go toolchain policy, default auto (can auto-fetch ≥1.25)

--no-verify-clients       Disable client verification (not enabled by default; testing only)
--force-verify-clients    Force enable client verification (default behavior)
--check / --dry-run       Only perform status and parameter checks, no install/write service/open ports
--repair                  Only fix/rewrite config (systemd/certificates etc.), don't reinstall derper
--force                   Force full reinstall (reinstall derper, re-sign certs, rewrite service)

# Operations & Maintenance
--health-check            Only output health check summary (no system changes, for cron/monitoring)
--metrics-textfile <P>    Export health check as Prometheus text metrics to path P (use with node_exporter)
--uninstall               Stop and uninstall derper systemd service (keep binary and certificates)
--purge                   With --uninstall: additionally delete installation directory (/opt/derper)
--purge-all               With --uninstall: on top of --purge, also delete binary (/usr/local/bin/derper)
```

> Compatibility: Script prioritizes new `-a :<PORT>` for listening; falls back to old parameter `-https-port <PORT>` if unsupported.

> Idempotency note: If detects existing "pure IP mode" derper working properly (port listening healthy, cert matches IP and not expiring soon), defaults to skip installation.

---

## Idempotency / Reentrant & Repair

- Default behavior: First perform status detection, skip if "pure IP mode" requirements met; otherwise repair on-demand (install missing components, regenerate certificates, rewrite service).
- Check mode:
  - Check only, no system changes: `bash scripts/deploy_derper_ip_selfsigned.sh --ip <your-public-ip> --check`
  - Outputs tailscale/derper/ports/certificates/config status and suggested actions.
- Repair mode (don't interrupt available dependencies):
  - `sudo bash scripts/deploy_derper_ip_selfsigned.sh --ip <your-public-ip> --repair`
  - Behavior: Re-sign certificates if needed, rewrite systemd unit and enable+restart.
- Force reinstall:
  - `sudo bash scripts/deploy_derper_ip_selfsigned.sh --ip <your-public-ip> --force`
  - Behavior: Reinstall derper, re-sign certificates, rewrite and restart service.
- Version threshold (optional):
  - Specify tailscale minimum version via environment variable `REQUIRED_TS_VER` (default 1.66.3), visible in `--check/--dry-run` output.

---

## Configure derpMap in Tailscale Admin Console

Script auto-calculates SHA256 of certificate DER raw bytes and outputs ACL snippet like below (example, RegionID customizable):

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
            "HostName": "<your-public-ip>",
            "DERPPort": 30399,
            "CertName": "sha256-raw:<fingerprint-from-script-output>"
          }
        ]
      }
    }
  }
}
```

Paste this snippet to Tailscale admin console → Access Controls (ACL) and save, wait 10–60 seconds to propagate to clients.

> Note: Using `CertName` fixes certificate fingerprint, no need for `InsecureForTests`. If port changed to 443, change `DERPPort` to 443.

### How to Retrieve Certificate Fingerprint Again

```bash
# Get from logs (printed when service starts)
journalctl -u derper --no-pager | grep sha256-raw | tail -1

# Or directly calculate from file fingerprint
openssl x509 -in /opt/derper/certs/fullchain.pem -outform DER | sha256sum | awk '{print $1}'
```

---

## Common Verification Commands

```bash
# Service status and logs
systemctl status derper
journalctl -u derper -f

# Port listening (TCP 30399, UDP 3478)
ss -tulpn | grep -E ':30399|:3478'

# TLS handshake (self-signed will warn untrusted, normal)
openssl s_client -connect <your-public-ip>:30399 -servername <your-public-ip>

# STUN port reachability (client/external host)
nc -zvu <your-public-ip> 3478

# Client observe DERP:
tailscale netcheck

# Check if "via DERP(my-derp)"
tailscale ping -c 5 <peer-tailscale-ip>
```

---

## Troubleshooting

### Get Certificate Fingerprint (logs/online handshake quick reference)

When need to fill `CertName` (sha256-raw:<hex>) in ACL or suspect certificate mismatch, use these two methods to quickly get current fingerprint:

1) Extract from systemd logs (derper prints on service start)

```bash
journalctl -u derper --no-pager | grep -oE 'sha256-raw:[0-9a-f]+' | tail -1
```

2) Online TLS handshake capture current certificate and calculate (no need to login server filesystem)

Linux (using sha256sum):

```bash
openssl s_client -connect <your-public-ip>:<DERP_PORT> -servername <your-public-ip> -showcerts </dev/null \
  | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
  | openssl x509 -outform DER \
  | sha256sum | awk '{print $1}'
```

macOS (using shasum):

```bash
openssl s_client -connect <your-public-ip>:<DERP_PORT> -servername <your-public-ip> -showcerts </dev/null \
  | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
  | openssl x509 -outform DER \
  | shasum -a 256 | awk '{print $1}'
```

Additional: If certificate file generated locally, can also directly calculate from file (same as "How to Retrieve Certificate Fingerprint Again"):

```bash
openssl x509 -in /opt/derper/certs/fullchain.pem -outform DER | sha256sum | awk '{print $1}'
```

Tip: Replace `<DERP_PORT>` with actual port (default 30399). If handshake fails, check cloud security groups/local firewall opening, `derper` running status, and port occupation.

---

## Monitoring & Alerting (Health Check + Prometheus)

### Health Check (for cron periodic execution)

```bash
# Only output health summary (no system changes)
sudo bash scripts/deploy_derper_ip_selfsigned.sh --ip <your-public-ip> --health-check

# Also export Prometheus text metrics (for node_exporter textfile collector to scrape)
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip <your-public-ip> \
  --health-check \
  --metrics-textfile /var/lib/node_exporter/textfile_collector/derper.prom
```

Exit code semantics (for shell/monitoring decision):

```text
0  Key health items normal (service running + TLS/UDP ports both listening)
1  At least one critical health check failed (service or port unhealthy)
```

Example (alert only on anomaly):

```bash
if ! sudo bash scripts/deploy_derper_ip_selfsigned.sh --ip <your-public-ip> --health-check >/tmp/derper_health.txt 2>&1; then
  echo "[ALERT] DERP health check failed" >&2
  tail -n +1 /tmp/derper_health.txt >&2
fi
```

Example output (excerpt):

```text
✅ Service: derper is running
✅ Port: TLS 30399/tcp is listening
✅ Port: STUN 3478/udp is listening
✅ Certificate: 287 days remaining
ℹ️  Resource: derper memory RSS ~3 MiB
```

Prometheus metrics sample (text file content):

```text
derper_up 1
derper_tls_listen 1
derper_stun_listen 1
derper_cert_days_remaining 287
derper_verify_clients 1
derper_pure_ip_config_ok 1
derper_process_rss_bytes 3145728
```

Notes:
- This script's built-in is "textfile export" method, recommended with `node_exporter`'s `--collector.textfile`;
- If you've deployed `node_exporter` (default listens 9100), Prometheus directly scrapes its 9100 port, while enabling textfile collection of above file;
- To change file path, adjust `node_exporter`'s `--collector.textfile.directory` parameter accordingly.

crontab example (refresh metrics every 1 minute):

```cron
* * * * * root bash /path/scripts/deploy_derper_ip_selfsigned.sh --ip <your-public-ip> --health-check --metrics-textfile /var/lib/node_exporter/textfile_collector/derper.prom >/var/log/derper_health.log 2>&1
```

---

## Running `tailscaled` (for client verification)

If script/service enables `-verify-clients`, local machine needs `tailscaled` running and logged into Tailnet:

```bash
sudo systemctl enable --now tailscaled
sudo tailscale up
# Or: sudo tailscale up --authkey tskey-xxxx
```

If temporarily unable to login, can append `--no-verify-clients` when running script (testing only).

---

## Uninstall

```bash
# Stop and uninstall systemd service (keep binary and certificates)
sudo bash scripts/deploy_derper_ip_selfsigned.sh --uninstall

# Uninstall and cleanup installation directory (certificates etc.)
sudo bash scripts/deploy_derper_ip_selfsigned.sh --uninstall --purge

# Complete cleanup (including binary /usr/local/bin/derper)
sudo bash scripts/deploy_derper_ip_selfsigned.sh --uninstall --purge-all
```

Note: Uninstall doesn't affect Tailscale itself (tailscaled, clients etc.). To remove together, use distro's normal method.

---

## Common Issues & Troubleshooting

- Go proxy timeout:
  - Use China mainland proxy and checksum mirror, e.g.:
    ```bash
    --goproxy https://goproxy.cn,direct --gosumdb sum.golang.google.cn
    ```
- Go version insufficient:
  - New Tailscale requires Go ≥ 1.25. Script defaults to `--gotoolchain auto`, will auto-fetch higher version toolchain.
- derper parameter incompatibility:
  - New version removes `-https-port`, uses `-a :<PORT>`. Script auto-adapts, no manual changes needed.
- `-verify-clients` failure:
  - Confirm `tailscaled` normal and `/run/tailscale/tailscaled.sock` visible; or use `--no-verify-clients` in script temporarily.
- IPv6 health warning (`ip6tables MARK`):
  - Try: `sudo modprobe xt_mark && sudo systemctl restart tailscaled`
  - Or switch to legacy backend:
    ```bash
    sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
    sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
    sudo systemctl restart tailscaled
    ```
- Port blocked:
  - Confirm "cloud security groups + local firewall (like UFW)" opened `DERP_PORT/tcp` and `3478/udp`.

---

## Change Port to 443 (Optional)

Some networks are friendlier to `443/tcp`:

1) Modify service listening port: Run script with `--derp-port 443`.
2) In ACL, change `DERPPort` to `443`.
3) Open cloud security groups/local firewall's `443/tcp`.

> Note: Still uses "IP-based self-signed certificate + CertName fingerprint" for verification.

---

## Maintenance & Upgrade

```bash
# View/restart service
systemctl status derper
systemctl restart derper

# Upgrade derper binary (keep existing service and certificates)
GOTOOLCHAIN=auto go install tailscale.com/cmd/derper@latest
systemctl restart derper

# Backup certificates (fingerprint change requires ACL update)
tar -C /opt/derper -czf derper-certs-backup.tgz certs/
```

Uninstall (use with caution):

```bash
sudo systemctl disable --now derper
sudo rm -f /etc/systemd/system/derper.service
sudo systemctl daemon-reload
sudo rm -rf /opt/derper
sudo rm -f /usr/local/bin/derper
```

---

## Checklist

- [ ] Server opens `DERP_PORT/tcp` and `3478/udp` (cloud security groups + local firewall).
- [ ] Run script and record output `CertName` fingerprint.
- [ ] In Tailscale admin console ACL, paste `derpMap` (using `CertName`).
- [ ] On clients, run `tailscale netcheck`, `tailscale ping` to verify "via DERP(my-derp)".
- [ ] Backup `/opt/derper/certs/` to prevent fingerprint change from certificate changes.

