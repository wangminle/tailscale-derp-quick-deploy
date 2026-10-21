# Changelog

## [0.2.15] - 2026-10-21

### ✨ Features

1. **Single-step release rollback and install-tree permissions (local part of BUG-036, BUG-037, DEV-006)**
    - Upgrade, rollback, migration, rotation, and uninstall share one flock. Builds land in a candidate directory and replace the live binary only after checks pass.
    - A root-owned recovery set is staged on the destination filesystem. Unverified staging cannot replace the only backup. An incomplete marker blocks ordinary overwrite; `--recover-interrupted` is the explicit recovery path. Records are whitelist key/value files, never sourced or eval'd, and an interrupted step is not resumed automatically.
    - A bad candidate or a failed write is not reported as success. A failed first install does not invent a previous version. A service that was stopped stays stopped after restore. If the running tailscaled daemon revision cannot be confirmed, the script does not switch derper and does not upgrade or downgrade tailscaled.
    - The install tree stays root-owned. The node private key moves to the state directory without changing its bytes. A symlink certificate directory is refused. systemd write access is limited to the node state directory.
    - Restoring config and state does not follow a destination symlink. If the state directory itself is a symlink, restore is refused. While root is writing, that directory is temporarily owned by root and then returned to the service user.
    - With verify-clients left at its default, a candidate module version is compared with the running tailscaled commit by the pseudo-version's trailing 12 hex digits, or by the release tag from `go list -m`. A mismatch or an unresolved identity does not switch derper and does not upgrade or downgrade tailscaled.
    - Rollback stops derper and checks that it is inactive before writing the previous files back, then starts only when that was the previous intent. A failed stop, start, or recheck keeps the incomplete marker.
    - A migration that does not rebuild the binary records a recovery set and a migrate marker before stopping the service. A failure after the stop tries to resume the previous intent and keeps the marker for explicit recovery. The migrated node config is owned by the service user at mode 0600. As root, the script checks that this user can read it.
    - Parses the complete standard `tailscale commit: <hash>` field instead of rejecting same-origin candidates by reading the wrong column. Missing, malformed, and mismatched identities remain rejected (BUG-055).
    - Migration within an upgrade reuses the original recovery set. Repeated migration cannot replace the only previous binary with the candidate or clear the outer marker before final service verification (BUG-059).
    - Rollback restores state-directory ownership and certificate group access for the saved unit user. The old user can read node identity and the previous IP private key without changing the caller's target user or IP (BUG-060).

### 🔧 Bug fixes

1. **Full uninstall removes the health-check stable copy (BUG-053)**
    - `--uninstall --purge-all` removes the stable program and status, then empty directories. Ordinary uninstall and `--purge` keep them. Only script-created files are removed; unrelated user files remain. A symlink directory is refused and failed deletion returns non-zero.

### 🧪 Tests

- Adds eight behavior regressions in `tests/test_s2_fixes.sh`, observed failing before the fixes and passing afterwards, covering standard daemon output, upgrade/migration composition, failure markers, saved-user rollback, and full uninstall including failed file and empty-directory deletion; the suite is wired into CI. `tests/test_s2_evidence.sh` also verifies real two-user rollback access to node config and private keys in a disposable Ubuntu container.
- `tests/test_review_regressions.sh` grows from 46 to 65 cases: new B1/B2/B3 rollback and migration cases (two-process lock, bad candidate never replaces the live binary, stopped intent is not started, failed first install invents no previous version, rollback restoring config and state, failed reverification keeping the recovery set, build timeout leaving the live binary alone, failed migration reverification, install-tree symlink refusal), plus targeted BUG-054–BUG-058 cases (restore not following a state symlink, symlinked state directory refused, a same-origin candidate passing the daemon gate, rollback reloading the previous process with stop failures keeping the marker, a pure migration failure keeping its marker, migrated config handed to the service user). Permission assertions that root cannot simulate are skipped as root; the main suite (104 cases) and the review regressions pass on both macOS Bash 3.2 and Linux Bash 5.2.

This release covers the S2/phase-B working-tree changes committed after 0.2.14 (Build0280); see `task-list.md` in the repository root for the ledger (BUG-036, BUG-037, BUG-053–BUG-060, the local part of DEV-006, TST-013–TST-016, CHK-020–CHK-023). The phase-B VM fault injection remains `tests/test_systemd_integration.sh` and was not run on this machine.

---

## [0.2.14] - 2026-10-21

### 🔧 Bug fixes

1. **Port conflicts are judged per protocol, and ownership matches PID fields only (BUG-040, BUG-043, BUG-044, BUG-048)**
   - DERP checks TCP only (including tcp6); STUN checks UDP only (including udp6). A UDP listener on the same number is no longer reported as a TCP conflict, and a TCP listener does not block STUN.
   - Ownership compares protocol and process together: the fallback that matched by process name alone is removed, and when MainPID is known the listener PID must match it strictly. derper on the other protocol cannot excuse a foreign listener.
   - `port_listening_owned_by_derper` and `current_derper_owns_ports` accept only ss `pid=<PID>` or netstat `<PID>/program`. When MainPID happens to equal Send-Q or Recv-Q (for example 128), a foreign nginx/unbound listener is reported as a conflict.

2. **Contradictory primary modes are rejected before side effects (BUG-041)**
   - `--health-check` is mutually exclusive with `--check`/`--dry-run`/`--repair`/`--force`/`--uninstall`. `--health-check --uninstall` no longer uninstalls.
   - Health check, repair, and uninstall alone still work, as does a deploy that also passes `--install-healthcheck-cron`.

3. **Numeric arguments are canonical after validation**
   - Ports, certificate lifetime, RegionID, and the connection limit drop leading zeros once they pass the range check, so derpMap output does not keep values such as `0443` or `0900`.

4. **Health-check exit codes and the verify-clients dependency (BUG-038)**
   - Exit 0 healthy, 1 confirmed fault, 2 unknown. Any non-zero status means not healthy, so existing cron jobs and `if ! --health-check` callers are unaffected.
   - Actively probes the tailscaled LocalAPI HTTP status. With verify-clients enabled, a stopped tailscaled or a 403/401 forbidden response sets `TS_LOCALAPI_OK=0`, exit code 1, and `derper_healthy 0`. Inability to connect, or insufficient caller permission, is reported as unknown with exit code 2.

5. **A failed connection-limit install is no longer reported as success (BUG-035)**
   - nft flush and rule insertion go through one `nft -f` transaction. If it fails, existing rules stay in place and the command returns non-zero.
   - iptables installs the new rule on a temporary chain first. A temporary-chain failure leaves the live chain alone; if replacing the live chain fails, the previous rules are restored. If that restore also fails, the command says protection is incomplete and does not claim success.
   - Failure to read the existing chain snapshot halts the operation without flushing the live chain and without a false recovery message.

6. **Firewall rule deletion failure propagates error on mixed-backend lingering rules (BUG-046)**
   - Under `--tls-connlimit 0`, if every backend fails or any backend (such as nft) fails to delete and leaves lingering rules, the command warns about the residue and returns non-zero.

7. **A mismatched certificate and key blocks restart (BUG-039)**
   - RSA and EC pairs are compared by public key. A mismatch does not restart the service; an existing backup is restored first, otherwise an explicit `--accept-cert-rotation` is required before re-signing.

8. **Unsearchable certificate directory reported as unknown instead of fault (DOC-008)**
   - When the certificate directory lacks read or search permissions, it is explicitly classified as unknown (`CERT_CHECK_UNKNOWN=1`, exit code 2) instead of a missing or misnamed certificate.

9. **The health task no longer depends on the source script being executable (BUG-034)**
   - Installs a root-managed stable copy and invokes it explicitly via `bash`. A 0644 source script, or a source directory that is later moved away, no longer breaks the task.

10. **Strict verification for the healthcheck timer install, keeping the old scheduler and rolling back completely on failure (BUG-042, BUG-047, BUG-049, BUG-050, BUG-051)**
    - Verifies unit path directory conflicts, temporary file writes, atomic mv replacement, daemon-reload, and enable. Any failure cleans up and preserves the legacy cron, returning non-zero.
    - Transactional rollback (`rollback_healthcheck_transaction`) snapshots the existing stable program, service/timer units, cron, and status before the update, fully restores them if the reinstall fails, and reloads systemd so existing schedules stay intact.
    - Existing stable program, service, timer, cron, and status files must be snapshotted first. Any required backup failure stops the update and leaves originals untouched. Snapshots are verified with cmp (or size); rollback distinguishes `.bak` (original existed) from `.missing` (original was absent), so a later install failure cannot delete a still-healthy scheduler.
    - After migrating cron to timer, a remaining cron file (read-only mount, immutable flag) is treated as migration failure: the new timer and status are rolled back and the installer returns non-zero. Falling back to cron likewise checks leftover timer/service files and revokes the new cron, so two five-minute schedules cannot both remain.
    - The timer's active/enabled states are recorded before updating an existing timer or migrating schedules. Rollback restores the two states independently: a previously stopped timer is not started, and a previously disabled timer is not enabled.
    - A failed restore copy, permission change, cleanup, or systemd operation returns an error and keeps the snapshot directory instead of claiming the previous scheduler is intact. The timer is not started if file restoration is incomplete.

11. **systemd ExecStart path quoting standardized (BUG-045)**
    - ExecStart arguments are quoted and escaped according to systemd unit rules instead of reusing Bash `printf %q`, eliminating unknown escape sequence warnings.

12. **Single health status collection cycle and large function refactoring (DEV-009)**
    - Eliminates redundant status collection between `main` and `health_check_report`; summary text, metrics, and exit code all reuse one collection pass.
    - Preserves single-file self-contained delivery while cleanly decoupling responsibilities in core functions:
      - `write_systemd_service`: decoupled into argument preparation, user/socket permissions, pure unit rendering, and deployment/verification/rollback.
      - `install_healthcheck_cron`: decoupled into command generation, unit/cron rendering, and transaction rollback.
      - `health_check_report`: decoupled into status collection, summary text rendering, and Prometheus metrics writing.

### 📖 Docs

- Tagging now points at the admin console or `tailscale up --advertise-tags`, and states that verify-clients needs the server to see legitimate clients.
- Mode 0666 on the tailscaled socket is no longer called an emergency state. Addresses in 127.0.0.0/8, including 127.0.0.53, are not reported as non-loopback.
- README and both REFERENCE documents now match this release: `--install-healthcheck-cron` prefers a systemd timer that calls a stable copy via bash, rolls back on failure, and is idempotent; `--uninstall` also removes the timer/cron (the stable copy under `/usr/local/lib/derper-deploy` is kept); the return semantics of a failed `--tls-connlimit` install or removal; health-check exit codes 0/1/2 and exit code 1 when the metrics file cannot be written; the sample output uses the current wording and the Prometheus example lists every emitted metric, including `derper_healthy`, `derper_check_unknown`, and `derper_metrics_unixtime`.

### 🧪 Tests

- `tests/test_review_regressions.sh` grows from 28 to 46 cases: protocol-specific conflicts and ownership, contradictory-mode side effects, leading-zero canonicalization, health exit codes, nft/iptables failures keeping old rules and snapshot read failure, LocalAPI 403, mismatched certificate pairs and unsearchable directories, backup-copy failure keeping original units, Send-Q/Recv-Q never treated as a PID, cron/timer deletion failures revoking the new scheduler, timer runtime restored on rollback, and a failed restore copy keeping the snapshot. Permission assertions that root cannot simulate are skipped as root; the LocalAPI 403 case is skipped when python3 is missing or Unix sockets are blocked. The main suite's LocalAPI probe uses a separate socket path and connects only after a ready marker, with timeouts on accept and wait and child cleanup on exit. A deliberately delayed server startup is also covered. The main suite (104 cases) passes both when Unix sockets are blocked and when they are allowed.

This release folds together the working-tree versions 0.2.14–0.2.17 produced during development on 2026-10-20/21 (none of which shipped separately); see `task-list.md` in the repository root for the ledger (BUG-034–BUG-052, DOC-007–DOC-008, ADJ-015–ADJ-020).

---

## [0.2.13] - 2026-10-20

### 📖 Docs & Repository Structure

1. **Bilingual changelogs moved to the repository root**
   - `docs/CHANGELOG_CN.md` / `docs/CHANGELOG_EN.md` are now root-level `CHANGELOG_CN.md` / `CHANGELOG_EN.md`; README links (CN/EN), the deployment-script header comment, and test assertions updated accordingly.
   - README (CN/EN) gains a "Documentation Layout" section and CLAUDE.md documents the same convention: `docs/` holds product guides, `plans/` requirements and designs, `checkpoints/` review/research/execution records (the latter two not version-controlled); changelogs and the task ledger live at the repository root.

2. **`.gitignore` aligned with the directory layout**
   - Adds the `checkpoints/` rule (legacy `records/` kept for local history); `.claude/` stays fully ignored as local session configuration.

### 🧪 Tests

- The main suite asserts both changelogs exist at the repository root and that docs no longer link to the old `docs/CHANGELOG_*` paths or missing review files.

This release contains no deployment-script functional changes; BUG-034–BUG-041 remain open. Review and planning records from 2026-10-20: root `task-list.md` (CHK-011–CHK-015, ADJ-010–ADJ-013).

---

## [0.2.12] - 2026-09-20

### 🔧 Bug Fixes

1. **Command substitution no longer blocks for the full timeout on hosts without `timeout(1)`**
   - The `_timeout_run` fallback killer subshell now redirects stdout/stderr, so an orphaned `sleep` can no longer hold the `$( )` pipe write end; previously every module query on a timeout-less host stalled 60s and the install path left a 15-minute `sleep 900` orphan.

### 📖 Docs

2. **`--cert-days` range documented; changelog history link fixed**
   - usage and both REFERENCE docs state the `--cert-days` range 1–365000; usage examples use a public-IP placeholder.
   - The stale review link in the 0.2.10 changelog history now points at `task-list.md` (CHK-004–CHK-009).

### 🧪 Tests

- Main suite gains 2 cases: command substitution must not wait the full timeout without timeout(1), and main must commit certificates before post-deploy extras; `resolve_run_user` runs as a plain statement under an ERR trap, so reverting the fix turns tests red.
- Main suite `tests/test_deploy_script.sh` (86 cases) plus `tests/test_review_regressions.sh` (14 cases); the harness prints `not ok` with the function name on failure.
- GitHub Actions `.github/workflows/tests.yml` runs both suites on Ubuntu (Bash 5).
- Review notes live in repo-root `task-list.md` (CHK-004–CHK-009).

---

## [0.2.11] - 2026-09-20

### 🔧 Bug Fixes

1. **Certificate SAN matching is exact; extras failure no longer rolls back a verified deploy**
   - SAN IPs are compared item-by-item, so `3.4.5.6` no longer matches `13.4.5.6`.
   - `commit_cert_update` runs immediately after service verification; `--tls-connlimit`/cron failures are reported without reverting certificates.
   - Uninstall removes `.certs-rollback`; unit files are written atomically and refuse symlinks; missing ss/openssl no longer looks like a start failure.

2. **Range checks no longer use overflowing Bash 64-bit arithmetic**
   - Ports, certificate days, RegionID, and `--tls-connlimit` are compared as normalized decimal strings, so values like `2^64+443` are no longer accepted as small legal numbers.

3. **Empty-array crash without `timeout`; GOPROXY `direct` precheck was too strict**
   - Missing `timeout` now uses `_timeout_run`, so Bash 3.2–4.3 with `set -u` no longer crashes on an empty `"${runner[@]}"`.
   - If GOPROXY includes `direct` and every HTTP proxy is unreachable, the precheck warns and lets Go fall back to direct.

4. **Argument mutexes and cron/connlimit behavior match the implementation**
   - `--install-healthcheck-cron` conflicts with `--health-check`; explicit `--tls-connlimit` cannot be used in read-only modes; explicit `0` removes installed rules.
   - Cron pins the full deploy profile and quotes paths with `printf %q`; nftables uses a script-owned table `inet derper_tls_connlimit`.

### 📖 Docs

5. **README/REFERENCE aligned with the script**
   - Document `--cert-days`/`--derper-version`; formal examples use a public-IP placeholder; dedicated-user samples, cert-directory ownership, broken review links, and `--metrics-textfile` wording are corrected.

### 🧪 Tests

- Main suite `tests/test_deploy_script.sh` (84 cases) plus `tests/test_review_regressions.sh` (14 cases).
- GitHub Actions `.github/workflows/tests.yml` runs both suites on Ubuntu (Bash 5).
- Review notes live in repo-root `task-list.md` (CHK-004–CHK-007).

---

## [0.2.10] - 2026-09-20

### 🔧 Bug Fixes

1. **Self-signed cert generation crashed under Bash 5 + `set -u`**
   - `cnf_tmp` was only assigned in the openssl `-addext` fallback. On modern openssl the success path hit `rm -f "$cnf_tmp"` with an unbound variable. `key_tmp`/`cert_tmp`/`cnf_tmp` are now initialized. macOS Bash 3.2 cannot reproduce this.

2. **Certificate replacement left a half-written layout with no rollback**
   - After `mv` replaced key/cert, a later failure of links, permissions, or config left new certs with old aliases. Updates now use an on-disk transaction; `--repair` resumes an interrupted rollback. Valid certs still get permission/alias repair instead of returning early.

3. **verify-clients commit alignment recompiled derper on every repair**
   - Installed module versions are often a canonical tag (`v1.102.4`) or a 12-character pseudo-version, so a 40-character commit never substring-matched. The script now compares the trailing revision and resolves the commit with `go list -m`.

4. **Explicit `--use-current-user` was overwritten by the non-interactive root default**
   - When no user flag is given, the deployed unit `User=` is inherited. Only a first-time, unspecified, non-interactive root deploy defaults to the dedicated account. `--check` prints both target and deployed user.

### ⚠️ Behavior Changes

5. **Certificate fingerprint rotation requires an explicit acknowledgement**
   - Replacing an existing cert previews the new ACL. Interactive mode types `rotate`; non-interactive mode requires `--accept-cert-rotation`. `--yes` does not stand in for that acknowledgement. The flag accepts the cutover window; it does not update ACL for you.

6. **Socket permission repair no longer restarts `tailscaled` as a probe**
   - Persistent socket unit / ACL come first; `--relax-socket-perms` remains an explicit emergency switch. A 0666 file mode is not proof that LocalAPI is unauthenticated.

7. **Bounded timeouts and a proxy precheck on restricted networks**
   - curl now has connect/total timeouts and retries; when `timeout` exists, module queries are capped at 60s and builds at 900s. Before a build the script probes GOPROXY (and `go.dev/dl` when a toolchain download is needed) for 5 seconds and fails fast with a `--goproxy` hint. It does not auto-switch a third-party proxy or disable GOSUMDB.

8. **`--relax-socket-perms` restores the original socket mode on exit**
   - The original mode is recorded before chmod 666 and restored on EXIT. Health checks and the deploy report warn if the socket is still 0666.

### ✨ Features

9. **Optional TLS connection cap `--tls-connlimit N`**
   - nftables or iptables `connlimit` limits concurrent DERP TLS connections per source IP. `0` disables the cap. `--uninstall` removes the rules.

10. **One-shot health-check cron `--install-healthcheck-cron`**
    - Writes `/etc/cron.d/derper-healthcheck` (every 5 minutes `--health-check --ip … --metrics-textfile …`). Incompatible with `--uninstall`/`--check`; uninstall deletes the cron file.

### 🧪 Tests

- Main suite `tests/test_deploy_script.sh` (64 cases) plus `tests/test_review_regressions.sh` (13 cases).
- GitHub Actions `.github/workflows/tests.yml` runs both suites on Ubuntu (Bash 5).
- Review notes live in repo-root `task-list.md` (CHK-004–CHK-009); planning drafts stay in local `plans/` (not versioned).

---

## [0.2.9] - 2026-08-14

### 🔧 Bug Fixes

1. **`ensure_go` accepted distro Go that is too old**
   - Ubuntu 22.04 / Debian 12 apt `golang-go` is often 1.18, which cannot use `GOTOOLCHAIN=auto`. The script now requires Go `>= 1.21` and installs the official toolchain otherwise.

2. **`get_installed_derper_version` could pick up the Go toolchain version**
   - The third-level bare semver fallback matched `go1.22.6` inside the binary and treated it as the derper module version. That fallback is removed.

3. **`--force`/`--repair` deadlocked on the service's own port when STUN was missing**
   - Port preflight now decides ownership per port. An old derper that only listens on TLS is no longer treated as a foreign occupant of its own DERP port. A STUN port held by another process is still a conflict.

4. **`--repair` re-signed certs instead of reusing name migration**
   - When only the filename is legacy (`fullchain.pem` → `<IP>.crt`), `--repair` now migrates and keeps the fingerprint, same as the default idempotent path.

5. **Drop-in restart of `tailscaled.socket` lacked SSH protection**
   - Same guard as restarting `tailscaled`: if the current SSH session is over Tailscale (`100.x` / `fd7a:115c:a1e0:`), non-interactive mode skips the socket restart and tells the operator to run it from a non-Tailscale session.

6. **Wizard `exec` leaked the temp directory**
   - `exec` replaces the process so the EXIT trap never runs; the wizard now calls `release_tmpdir` first.

7. **Health checks probed public IP on the internet every time**
   - `--health-check` (cron) no longer hits external IP APIs; it prefers `-hostname` from the deployed unit, and skips probing when `--ip` is already set.

8. **Wizard artifact `derper_deploy_cmd.sh` was untracked**
   - Added to `.gitignore`.

- Regression suite expanded to 46 cases.

## [0.2.8] - 2026-08-14

### 🔒 Security Fixes

1. **Symlink overwrite risk in certificate generation (P1)**
   - The certs directory and `<IP>.crt`/`<IP>.key` stay root-owned; the service user gets group read-only access. Node key state (`derper.json`) remains in the service-writable install directory.
   - The certs dir is tightened before re-sign/migration; symlinked paths are refused; all writes go through random temp files in the same directory plus atomic `mv` (which replaces a symlink itself rather than following it). The `openssl-derper.cnf` fallback no longer lands in the install directory.
   - `setup_service_user` re-asserts root ownership of the certs dir after every `chown -R`.

2. **No more `InsecureForTests` fallback (P1)**
   - When the fingerprint cannot be obtained, the script no longer prints an `InsecureForTests: true` derpMap; it fails the deployment and asks to debug TLS. Upstream says that field is for unit tests only.

3. **Complete public-IP classification**
   - New IPv4 classifier covers private, CGNAT 100.64.0.0/10, loopback, link-local, TEST-NET documentation ranges, multicast, and reserved ranges. Deployment mode rejects non-globally-routable addresses; intranet testing requires explicit `--allow-non-global-ip`.

4. **RegionID bounded to JS safe integers**
   - Upper bound is now 2^53-1; values outside 900-999 (the upstream user-reserved range) get a warning.

### 🔧 Bug Fixes

5. **derpMap now includes STUNPort (P1)**
   - The CertName ACL snippet prints `STUNPort`, making custom `--stun-port` actually usable.

6. **Startup verification and complete rollback (P1)**
   - After start/restart the script verifies active state, TLS/STUN listeners, a successful TLS handshake, and process liveness. On failure it restores the backed-up unit, restarts the old service, and re-verifies it — not just restores the file.

7. **`--repair` docs match behavior**
   - Help/docs now state that `--repair` normally skips derper reinstall, except when the installed binary drifts from the aligned target version.

8. **verify-clients alignment now uses the actual Git revision**
   - Prefers the `tailscale commit` from `tailscale version` and aligns derper to that commit; falls back to a semver tag with a warning otherwise. Installed pseudo-versions containing the target commit count as aligned.

9. **Argument combination validation**
   - `--purge/--purge-all` require `--uninstall`, `--metrics-textfile` requires `--health-check`, and `--force`/`--repair`/`--uninstall`/`--check` conflicts are hard errors instead of silently picking a branch.

10. **Prometheus metrics completed**
    - Added `derper_healthy` (overall health) and `derper_cert_live_match` (live/disk certificate consistency), so cert mismatches are no longer invisible while `derper_up` still reads 1.

11. **Minimal-environment dependency**
    - Dependency check now ensures `tar` (needed by the Go tarball fallback).

### 📚 Docs

- README adds upstream self-hosted DERP limitations: no support for some cross-Tailnet/shared-node scenarios, don't place behind generic HTTP reverse proxies or global load balancers, prefer static IPv4+IPv6 in production, and use `derpprobe` for protocol-level monitoring.

### 🛡️ Host & Tailnet Attack-Surface Auditing (public-relay risk lives mostly on the host itself)

- Deploy/check/health-check now run an **attack-surface check**: lists non-loopback TCP listeners other than the DERP port (with a specific hint for 0.0.0.0:22 SSH), recommending single-purpose hosts.
- New **automatic security updates detection** (unattended-upgrades / dnf-automatic) with warning and enablement guidance.
- Firewall tips add host-hardening advice: security group inbound only for DERP TLS + STUN, SSH preferably via Tailscale or source-restricted, don't restrict egress (tailscaled needs the control plane and official relay probes), and watch `-verify-clients` rejection logs.
- Deployment output now includes **server-node ACL restriction advice**: tag the node `tag:derper-server` and grant minimal access so "relay compromise ≠ tailnet compromise".

### 🧪 Tests

- Regression suite expanded to 36 cases (now exercising real `tailscale version` output parsing for commit alignment): STUNPort ACL output, safe failure on missing fingerprint, non-global IP rejection, RegionID safe-integer range, argument-combination validation, cert symlink refusal, commit alignment / pseudo-version matching, the new Prometheus metrics, attack-surface detection, auto-updates detection, and server-node ACL advice.

---

## [0.2.7] - 2026-07-11

### 🔧 Bug Fixes

1. **Certificate names match upstream derper manual mode**
   - Self-signed certs are now written as `<public-ip>.crt` / `<public-ip>.key` (matching upstream `cmd/derper/cert.go`), so derper no longer ignores script certs and auto-mints another pair.
   - Keeps `fullchain.pem`/`privkey.pem`/`cert.pem`/`key.pem` compatibility symlinks; legacy names are migrated in place during idempotent repair when possible to preserve CertName.
   - Health checks and fingerprinting prefer upstream names; incompatible naming is treated as unhealthy.

2. **Version alignment actually reinstalls the binary**
   - After aligning the target version, the script reads the installed derper module version via `go version -m` (with fallbacks) and re-runs `go install` on mismatch—no extra `--force` required.
   - Explicit `--derper-version` similarly triggers reinstall on drift.

3. **Less invasive socket permission handling**
   - Creates the run user first, then checks whether that user can already read/write the socket (including world-writable); skips group changes / tailscaled restarts / drop-ins when access already works.

4. **systemd / config-drift / health-check reliability**
   - Moves `StartLimitBurst`/`StartLimitIntervalSec` into `[Unit]`.
   - When paranoid mode drops `MemoryDenyWriteExecute`, the unit comment is marked degraded; drift detection distinguishes full vs degraded.
   - Backs up the unit before overwrite and attempts rollback on failed start.
   - Port ownership checks MainPID; TLS/health probes prefer loopback to reduce NAT hairpin false failures.
   - `--check`/`--health-check` return non-zero when parameter validation fails.
   - Runtime checks add protocol-level diagnostics hints and document `nc -zvu` limitations.

### 📚 Docs

- Softened “production-grade / enterprise / full coverage” wording to match the test/home/small-scale positioning.
- Certificate paths, version alignment, CertName rotation, and health-check boundaries updated.
- Formalized script versioning: `SCRIPT_VERSION`, root `VERSION` file, and `-V/--version`; REFERENCE/CHANGELOG now consistently report 0.2.7.

### 🧪 Tests

- Regression suite expanded to 26 cases covering upstream cert names, version-drift reinstall, paranoid degraded matching, StartLimit section placement, world-writable socket skip, naming-aware health checks, and `--version`/`VERSION` consistency.

---

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

**Update Date**: 2026-10-21

**Version**: 0.2.15
