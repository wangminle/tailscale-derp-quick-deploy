# Changelog

## [0.2.6] - 2026-06-15

### 🔧 Bug Fixes

1. **Align derper version with tailscaled (verify-clients)**
   - When `-verify-clients` is enabled and `--derper-version` is not specified, the script now auto-aligns derper to the locally installed tailscale version (installs `derper@v<TS-version>`), ensuring both are built from the same source revision and avoiding local-API protocol incompatibilities that break client verification.
   - Upstream requires derper and tailscaled to be built from the same git revision; override with `--derper-version`; falls back to `latest` with a notice when the tailscale version cannot be detected.

2. **Idempotent deploys missed stale live certificate**
   - The main status-collection step now compares the live (served) certificate fingerprint with the on-disk one and feeds the result into `service_needs_reconcile`: if the disk cert was replaced externally while derper kept serving the old one, a re-run triggers a restart to load the new cert.
   - `--health-check` exit code and summary now reflect live-certificate status.

3. **Config match validates the actual `-socket` path**
   - `unit_matches_desired_config` now verifies that `-socket` not only exists but matches the locally detected tailscaled socket path; a wrong socket path is no longer misreported as "config matches", which previously let verify-clients fail silently.

4. **README doc sync**
   - Fixed the example `RUN_USER="${SUDO_USER:-$USER}"` to `${SUDO_USER:-${USER:-$(id -un)}}`, matching the script (avoids unbound `$USER` under `set -u`).
   - Corrected the `--repair` description: it restarts the derper service (only rewrites config/certs, does not reinstall derper/Go); the previous "without interrupting service" wording was inaccurate.

### 🧪 Tests

- Regression tests expanded to 19, adding coverage for: `-socket` path drift detection, stale live certificate triggering reconcile, and derper version auto-alignment.

---

## [0.2.5] - 2026-06-14

### 🔧 Bug Fixes

1. **Minimal-environment and interactive robustness**
   - Fixed the script failing during load under `set -u` when `USER` is not exported; it now falls back to `id -un`.
   - All interactive `read` calls now handle EOF safely, preventing unbound-variable failures in the wizard, Go installation confirmation, and tailscaled restart confirmation.

2. **derper configuration and client verification correctness**
   - systemd `ExecStart` and manual-run examples now always specify the node-key config with `-c /opt/derper/derper.json`.
   - Legacy empty `{}` configs are removed so derper can generate a valid node private key on first start, while existing valid configs are preserved.
   - `-verify-clients` now uses derper's supported `-socket` flag instead of the ineffective `TS_LOCAL_API_SOCKET` environment variable.
   - Custom STUN ports are rejected when the installed derper lacks `-stun-port`, avoiding mismatches between the actual listener, configuration, and firewall guidance.

3. **Idempotent repair and certificate health checks**
   - Certificate renewal, binary replacement, a stopped service, or missing target listeners now trigger service reconciliation and restart so updated files take effect immediately.
   - Fixed certificate SAN checks treating IPv4 dots as regular-expression wildcards.
   - Health checks now compare the live TLS certificate fingerprint with the on-disk certificate, preventing false positives while derper still serves an old certificate.

4. **Platform compatibility and safe writes**
   - RHEL-family systems now refresh CA state with `update-ca-trust extract`.
   - Prometheus textfile output now uses a secure randomized temporary file in the target directory, avoiding fixed `.tmp` path concurrency and symlink risks.
   - The fallback `InsecureForTests` ACL snippet now uses the requested Region, IP, and DERP port.
   - Added `.gitattributes` to enforce LF line endings for `.sh` files.

### 🧪 Tests

- Expanded the regression suite to 16 tests, covering unset `USER`, runtime reconciliation, `-c`/`-socket` arguments, empty-config migration, unsupported custom STUN ports, ACL parameters, wizard EOF, exact SAN matching, live-certificate consistency, and safe metrics writes.
- `bash -n`, `git diff --check`, and LF line-ending checks pass.

---

## [0.2.4] - 2026-05-19

### 🔧 Bug Fixes

1. **Restore script executability**
   - Restored LF line endings for the deployment script, fixing CRLF failures in `bash -n` and `--help`.

2. **Idempotency and repair logic**
   - The default skip path now verifies that the deployed unit matches the requested IP, DERP/STUN ports, run user, security level, and client verification mode.
   - `--repair` / `--force` allow the current derper service to own the target ports, avoiding false self-conflict failures.
   - Rewritten systemd units now restart an already running service so certificate and ExecStart changes take effect immediately.

3. **Health check and metrics**
   - `--health-check` now treats config drift and certificate problems as non-zero failures.
   - Prometheus output adds `derper_desired_config_ok`; `derper_verify_clients` now reflects the deployed unit instead of only the current CLI default.

4. **Uninstall scope**
   - `--uninstall --purge-all` additionally removes `/etc/derper/derper.env` and the script-created tailscaled socket drop-in.
   - Firewall rules and user/group accounts still require manual confirmation to avoid deleting user-managed state.

### 🧪 Tests

- Added `tests/test_deploy_script.sh` covering LF line endings, sourceable script functions, config drift detection, and current-service port conflict exemption.
- The repository now includes a lightweight regression test script; a full integration test suite has not been added.

---

## [0.2.3] - 2026-01-25

### 🔧 Bug Fixes

1. **Missing Parameter Value Friendly Error**
   - Fixed script crashing with `shift 2` error when parameters like `--ip`, `--derp-port` are used without providing a value
   - Added `require_arg_value()` function to uniformly validate all parameters that require values and print clear error + usage
   - Now outputs friendly `[Error] Parameter --ip requires a value` instead of mysterious shift error

2. **IP Address Octal Parsing Issue**
   - Fixed IP address fields starting with 0 (e.g., `192.168.08.1`) being interpreted as octal by bash arithmetic, causing parsing errors
   - Values like `08` or `09` would be rejected by bash as invalid octal numbers
   - Using `$((10#$octet))` to force decimal parsing, completely avoiding this issue
   - Affected: IP validation logic in `validate_settings()` and `deployment_wizard()`

3. **`--security-level` Invalid Value Handling**
   - Fixed invalid security level (e.g., `--security-level invalid`) silently falling back to `standard`
   - Now explicitly errors: `[Error] Invalid security level: invalid` and lists available options

### 📝 Technical Details

- All changes are **backward compatible**, no changes to existing parameters or usage
- Syntax check `bash -n` passed
- Total script lines: ~2210

---

## [0.2.2] - 2025-12-26

### 🔧 Bug Fixes

1. **`--check/--health-check` Mode Fault Tolerance Improvement**
   - Fixed `detect_public_ip()` and `validate_settings()` using `exit` internally, which prevented subsequent check information from being output
   - Changed to use `return` to let the caller decide whether to exit; `--check` mode can now output complete diagnostic information even if detection fails

2. **Prometheus Metrics Write Error Handling**
   - Fixed `--metrics-textfile` triggering `set -e` and exiting directly when target path is not writable
   - `write_prometheus_metrics()` now returns error code + outputs warning on failure, no longer causes entire script to abort
   - Caller decides whether to print "write success" or "write failed" message based on return value

3. **systemd Unit File Generation Optimization**
   - Fixed empty variables (e.g., `config_flag`, `verify_flag`) causing extra backslash continuations in ExecStart line
   - Uses array to dynamically build command parameters, generating cleaner single-line ExecStart
   - Fixed extra empty lines when `SupplementaryGroups` is empty

4. **Variable Scope Fix**
   - `socket_path` variable promoted to function-level initialization to avoid potential undefined reference issues

### 🎨 User Experience Improvements

1. **`--check` Output Optimization**
   - Displays `<not detected>` instead of blank when public IP is empty, avoiding user confusion

2. **Wizard Mode IP Validation Enhancement**
   - IP field range check changed to `(( octet < 0 || octet > 255 ))` for more complete logic

### 📝 Technical Details

- All changes are **backward compatible**, no changes to existing parameters or usage
- Syntax check `bash -n` passed
- Total script lines: ~2180

---

## [0.2.0] - 2025-11-10

### 🎯 Major Improvements

#### 1. Intelligent Account Management 🆕

**New Parameters**:
- `--dedicated-user`: Force create dedicated derper system account (production recommended)
- `--use-current-user`: Run with current user (personal environment friendly)

**Smart Behavior**:
- Auto-detect execution environment (sudo user vs real root)
- Trigger warning and provide security recommendations when executed directly as root
- Three account modes flexibly adapt to different scenarios

**Permission Handling**:
- Prioritize systemd socket drop-in (most standard)
- Fallback to ACL (setfacl)
- Remove insecure automatic chmod 666 fallback
- Provide clear four solution options when permissions are insufficient

#### 2. Tiered Security Hardening 🆕

**New Parameters**:
- `--security-level {basic|standard|paranoid}`: Three-level security configuration

**Security Level Comparison**:

| Level | Hardening Items | Use Case | Compatibility |
|-------|----------------|----------|---------------|
| **basic** | 3 items | Old systems, embedded | Highest |
| **standard** | 11 items | Production (recommended) | Good |
| **paranoid** | 15 items | High security requirements | Needs verification |

**Automatic Fallback**:
- Auto-disable MemoryDenyWriteExecute when paranoid level startup fails
- Display systemd security score after deployment

#### 3. Configuration Wizard Mode 🆕

**New Subcommand**:
```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh wizard
```

**Features**:
- Interactive Q&A guided configuration
- Auto-generate deployment commands suitable for scenarios
- Safe template replacement (avoid eval injection)
- Command saved to `derper_deploy_cmd.sh`

#### 4. Non-Interactive Mode 🆕

**New Parameters**:
- `--yes`: Auto-confirm all choices
- `--non-interactive`: Disable all interactive prompts

**Use Cases**:
- CI/CD pipelines
- Ansible/Terraform automation tools
- Unattended deployment

#### 5. Environment Variable Configuration Management 🆕

**New Features**:
- Auto-create `/etc/derper/derper.env` template
- systemd service integrates `EnvironmentFile`
- Support third-party verification services like Headscale

**Example Configuration**:
```bash
# /etc/derper/derper.env
TS_AUTHKEY=tskey-auth-xxxxxx
DERP_VERIFY_CLIENT_URL=https://headscale.example.com/verify
```

#### 6. Socket Permission Error Friendly Prompt 🆕

**Before**:
```
[Warning] Temporarily relaxing tailscaled socket permissions to 0666
```

**After**:
```
╔══════════════════════════════════════════════════════════════╗
║          ⚠️  tailscaled socket permission insufficient       ║
╚══════════════════════════════════════════════════════════════╝

Recommended Solutions (prioritized):

Solution 1: Use systemd socket override (safest, persistent) ✅
  mkdir -p /etc/systemd/system/tailscaled.socket.d
  cat > /etc/systemd/system/tailscaled.socket.d/10-derper-localapi.conf <<'EOF'
[Socket]
SocketGroup=tailscale
SocketMode=0660
EOF
  ...

Solution 2: Use ACL (flexible, requires acl package)
  ...

Solution 3: Run derper with current user (simple, for personal environment)
  ...

Solution 4: Temporarily relax permissions (not recommended, emergency only)
  bash $0 --relax-socket-perms [other parameters]
```

### 📚 New Documentation

1. **Account & Security Strategy Guide** (Planned)
   - Three account mode comparison
   - Security level details
   - Common troubleshooting
   - Best practice checklist

### 🔧 Parameter Changes

**New Parameters**:
```bash
--dedicated-user          # Force create dedicated account
--security-level LEVEL    # Security level: basic|standard|paranoid
--relax-socket-perms      # Allow relaxing socket permissions (explicit switch)
--yes, --non-interactive  # Non-interactive mode
wizard                    # Wizard subcommand
```

**Parameter Impact**:
- Removed implicit behavior of automatic `chmod 666`
- `--relax-socket-perms` must be explicitly specified to relax permissions

### 🛡️ Security Improvements

1. **Remove Dangerous Default Behavior**
   - ❌ No longer auto `chmod 666 tailscaled.sock`
   - ✅ Must explicitly use `--relax-socket-perms` to relax

2. **Root Execution Warning**
   - Detect real root vs sudo execution
   - Provide security recommendations and require confirmation
   - Non-interactive mode will error and exit directly

3. **systemd Hardening Enhancement**
   - Three-level optional configuration
   - Automatic compatibility detection and fallback
   - Display security score after deployment

4. **Environment Variable Isolation**
   - Sensitive configuration managed in separate file
   - Permission 600, only root can read/write

### 🧪 Test Coverage

New Test Cases:
- ✅ Parameter validation (IP, port, security level)
- ✅ Three account modes
- ✅ Three security levels
- ✅ Non-interactive mode
- ✅ Socket permission handling
- ✅ Wizard mode entry

### 📖 Documentation Updates

- Updated README_cn.md quick start section
- Added wizard mode documentation
- Added three typical scenario examples
- Links to detailed documentation

### 🔄 Backward Compatibility

**Fully Compatible**:
- All existing parameters remain unchanged
- Default behavior is safer but doesn't affect normal use
- Old commands continue to work

**Behavior Change** (safer):
- No longer auto-relax socket permissions when insufficient (requires explicit `--relax-socket-perms`)
- This is an **intentional security improvement**, old automatic behavior was risky

### 🎯 Usage Recommendations

**Production Environment**:
```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip <public-ip> \
  --dedicated-user \
  --security-level paranoid \
  --derp-port 443 \
  --auto-ufw \
  --yes
```

---

## [0.2.1] - 2025-11-10

This is a "documentation and wording alignment" minor version, focusing on simplifying the homepage, demoting technical references, and synchronizing script usage wording with default policies.

### 📚 Documentation Refactoring (Important)
- New simplified Chinese homepage: `README.md` (focused on objectives, features, three-step deployment and parameter highlights).
- Migrated original technical long texts:
  - Original English README.md → `docs/REFERENCE_EN.md`
  - Original Chinese README_cn.md → `docs/REFERENCE_CN.md`
- Unified wording: Default to "use current user"; production environment recommends `--dedicated-user`.
- Examples and parameter tables aligned with current script state:
  - Added "Plan A (current user) / Plan B (dedicated user) / wizard mode" three paths.
  - Emphasized `--security-level` three-tier hardening and China network mirror parameters.
- Supplemented in reference documentation: "non-interactive root defaults to dedicated account" explanation.

### 🧩 Script and Documentation Consistency (Fine-tuning)
- usage wording: Updated to "`--user` default = current login user; `--use-current-user` is default behavior".
- IPv4 validation: `validate_settings()` added 0–255 segment validation (consistent with wizard).
- Non-interactive root: Defaults to equivalent of `--dedicated-user` when no `SUDO_USER`, consistent with documentation.
- Wizard execution: Removed eval, changed to safe parameter array execution (declared in documentation).

> Note: Above code-level fine-tuning are all backward-compatible updates, do not change 0.2.0 functional boundaries, only correct wording and default policy statements, and strengthen parameter validation.

**Personal Environment**:
```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh wizard
```

**CI/Automation**:
```bash
sudo bash scripts/deploy_derper_ip_selfsigned.sh \
  --ip <public-ip> \
  --dedicated-user \
  --non-interactive \
  --yes
```

---

## [1.x] - 2025-10-xx

### Initial Version Features

- IP-based self-signed certificate
- Automatic derper service deployment
- systemd integration
- Health checks and metrics export
- Idempotent reentrant design
- Client verification support

---

**Comparison Summary**:

| Feature | v1.x | v2.0 |
|---------|------|------|
| Account Management | Fixed derper user creation | Smart adaptation of three modes |
| Security Hardening | Fixed configuration | Three-level optional |
| Socket Permissions | Auto chmod 666 | Standard solution + explicit switch |
| User Experience | Pure command line | Wizard mode + command line |
| Automation | Manual interaction handling | Non-interactive mode |
| Documentation | Basic instructions | Detailed docs + troubleshooting |
| Testing | None | Lightweight regression test script |

---

**Contributors**: Thanks to architects for professional advice

**Update Date**: 2026-06-15

**Version**: 0.2.6
