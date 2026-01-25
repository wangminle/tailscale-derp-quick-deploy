# Changelog

## [2.0.3] - 2026-01-25

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

## [2.0.2] - 2025-12-26

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

## [2.0.0] - 2025-11-10

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

1. **[Account & Security Strategy Guide](docs/ACCOUNT_AND_SECURITY.md)**
   - Three account mode comparison
   - Security level details
   - Common troubleshooting
   - Best practice checklist

2. **[Test Suite](tests/README.md)**
   - Integration test scripts
   - 10+ test cases
   - CI integration examples

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

## [2.0.1] - 2025-11-10

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

> Note: Above code-level fine-tuning are all backward-compatible updates, do not change 2.0.0 functional boundaries, only correct wording and default policy statements, and strengthen parameter validation.

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
| Testing | None | Integration test suite |

---

**Contributors**: Thanks to architects for professional advice  
**Update Date**: 2026-01-25  
**Version**: 2.0.3

