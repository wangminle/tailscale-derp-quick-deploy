# Maintenance interfaces and check scope

The C-stage implementation keeps the script self-contained. Automatic certificate rotation and control-plane writes remain outside this delivery.

Commands: `deploy`, `check`, `health`, `status`, `repair`, `uninstall`, `recover`, `derpmap`. Existing flags remain supported; conflicting command/flag modes are rejected. Put the command before options. `status --format json` emits one schema-version-1 document; `derpmap` emits this node's Regions fragment using the sampled, verified live certificate. Default status is read-only. health/status exit codes are 0 when the requested scope passes, 1 for a confirmed failure or a failed result write, and 2 for unknown, limited collection, or stale metrics; unknown takes precedence when a confirmed failure is also present. derpmap exits 2 when the local identity is unverified, and 1 when that identity check has failed.

Use explicit `--config FILE` with [the example](../examples/deploy.conf.example). Replace the example IP and settings first. Configuration is versioned `KEY=value` data, never shell code. `CONFIG_VERSION=1` is required. Unknown/duplicate fields, shell syntax, quotes, control/NUL bytes and files over64KiB are rejected. Root requires a root-owned, non-symlink file without group/world write access. Defaults/environment are overridden by the file, then CLI. No credentials or destructive operation modes are accepted. Region names retain the existing ASCII validation. No implicit config-file search or scheduler installation occurs.

```bash
bash scripts/deploy_derper_ip_selfsigned.sh status --format json
sudo bash scripts/deploy_derper_ip_selfsigned.sh deploy --config /etc/derper/deploy.conf
sudo bash scripts/deploy_derper_ip_selfsigned.sh deploy --ip YOUR_PUBLIC_IP \
  --binary /root/artifacts/derper --derper-version v1.104.1 --binary-sha256 TRUSTED_SHA256
```

Local import requires a pinned version. A controlled candidate copy is checked for little-endian64-bit Linux ELF architecture (amd64/arm64), embedded tailscale.com module version, expected capabilities, optional checksum and the existing daemon-revision gate. Import reuses B-stage recovery and does not automatically install Go. Runtime dependencies must already exist. With default verify-clients enabled, resolving daemon/module identity may still need Go metadata; this is not an unconditional offline promise. A locally computed hash does not authenticate the publisher. Obtain expected checksums independently and trust the artifact before importing it. Normal deploy preserves valid certificate/key/node identity.

Process names only locate candidates. All four process UIDs must match the deployment caller. The executable must belong to root or the caller and have no group/other write access or setuid/setgid bits. Its inode is pinned through a file descriptor before version execution. Root never executes an ordinary user's matching process; unsupported custom non-root daemon setups require manual handling.

Rollback restores file content and presence for the unit and ordinary files in the dedicated node-state directory, including hidden and empty files. Symlinks and subdirectories block cleanup rather than being recursively deleted. Cleanup, digest verification or systemd reload failures retain recovery material and the incomplete marker.

An interrupted first installation has no previous binary. Explicit recovery stops the service before removing the candidate and marker. A stop failure retains both for retry.

One core sample feeds text, JSON, metrics and the node fragment. JSON includes layers, target settings, certificate hashes, freshness, timestamps, reason and manual-attention state. Missing values use null. A last-success timestamp covers the requested scope; with H3 not configured it does not prove external relay success.

`--metrics-textfile FILE` and `--state-file FILE` explicitly enable atomic result writes. `--metrics-source FILE --metrics-max-age 900` inspects an old metrics timestamp without rewriting it; stale, unreadable, malformed or future timestamps cannot report green. Input and output metrics paths must differ. Added layer gauges use 1=healthy, 0=failed, -1=unknown, -2=not_checked, 2=not_applicable. Consumers must evaluate timestamp age; an old file cannot update its own stale flag.

`--install-healthcheck-cron` continues to install one scheduler: systemd timer/oneshot where available, explicit Bash invocation of a protected standalone copy, and default state at `/var/lib/derper-deploy/health/status.json`. Explicit external-probe, Region, timeout and private-test-IP permission are carried into generated commands. No repair/restart loop is installed. Inspect `journalctl -u derper-healthcheck.service` and the state file. Journal-directory presence is only a configuration hint, not proof of durable logging or offline notification.

H0 checks collector tools; H1 checks the local service, PID-owned protocol listeners and certificate identity; H2 checks tailscaled/LocalAPI dependencies when verify-clients is enabled; H3 requires independent authorized-client DERP forwarding and STUN evidence. Missing H3 is `not_checked`. `--require-h3` makes missing evidence unknown and blocks release commit. A configured probe's failed/unknown result also blocks commit; failure follows the existing rollback path and retains recovery material when restoration fails.

Probe timeout sends TERM, escalates to KILL after one additional second and cleans remaining children in the same process group. Adapters must not detach background daemons. Missing tools only permit degradation of the unavailable observation; known port/PID failures still block release.

State and metrics outputs require ordinary-file destinations. Root requires protected root-owned ancestor directories without symlinks; a root-owned sticky directory such as `/tmp` may be an upper ancestor, but the final output directory must not be group/other writable. Do not write directly to `/tmp/status.json` or a service-user-controlled directory. State output, metrics output and metrics input must be distinct, including path aliases and existing hard links.

JSON adds `scope_id`, binding the target, Region, verification mode, H3 requirements, probe and freshness settings. Previous `last_success_at` is reused only for that scope. Old state without the identifier or a changed scope resets history until the current check succeeds.

`--external-probe /absolute/executable` is an adapter contract, not a bundled derpprobe deployment. The operator must implement real checks on an independent authorized client, with credentials managed separately. A root-invoked adapter and every parent path must be root-owned, not group/world-writable and not symlinks. Arguments: `--region-id N --ip IP --derp-port TCP --stun-port UDP`. Stdout must contain exactly the whitelist keys `schema=1`, `region_id`, `ip`, `derp_port`, `stun_port`, `checked_at`, `derp`, `stun`; the final two values are `ok` or `failed`. All targets must match. Exit0 means all pass; exit1 must identify a confirmed failed check. Other exit codes, malformed/duplicate/unknown fields, timeout, stale/future or mismatched reports are unknown. Default timeout is15s (1–120), maximum result age60s; `timeout` and synchronized clocks are required. Raw adapter output is not logged.

Isolated tests cover parsing, orchestration and rollback. Real independent-client H3, production migration and control-plane coordination require separate evidence. See [the detailed Chinese guide](MAINTENANCE_CN.md) for the complete key list and examples.
