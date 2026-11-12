# Agent installation preparation

[中文](AGENT_INSTALL_CN.md) | English

Confirm the target using the [installation workflow](INSTALL_WORKFLOW_EN.md). Ordinary-user preflight and build work can happen first. When sudo is required and cannot run noninteractively, prepare a reviewable entry point and have the user authenticate in their own terminal. Do not request passwords, private keys or OAuth secrets in chat, or configure global passwordless sudo for convenience.

Use the system OpenSSH client and server sshd for management; the transport may use a tailnet 100.x address. Do not use the separate Tailscale SSH feature, invoke `tailscale ssh`, or add `tailscale up/set --ssh` for deployment. Read the RunSSH field in `tailscale debug prefs` to determine whether the server feature is enabled; do not log the complete preferences. If RunSSH is already true, report the existing configuration and do not disable it without authorization, as other users may depend on that management path.

## Go toolchain and hashes

Read official metadata from `https://go.dev/dl/?mode=json&include=all`. Select exactly one archive for the explicit version, OS and architecture, then use its filename, size and sha256. Do not assume that `goVERSION.OS-ARCH.tar.gz.sha256` is a valid checksum endpoint; it may return HTML.

Recommended sequence:

1. Pin the required Go version, download and retain the official JSON, and validate a unique entry, a filename without path separators and a 64-digit hexadecimal SHA256.
2. Download that filename from `https://go.dev/dl/` with bounded connection and total timeouts. Retain failure logs and do not treat partial files as complete.
3. Verify size and SHA256 before unpacking or executing. Verify previously downloaded files too.
4. If the server cannot access official metadata, retrieve it over HTTPS on a trusted local machine and transfer the verified hash/archive, recording the source. Do not substitute an unknown mirror or disable integrity checks.
5. Build a pinned derper module version and retain GOPROXY/GOSUMDB and build information. Actually resolve commits to module versions. If the version display contains `ERR-BuildInfo`, inspect the module source with `go version -m`; do not infer a matching source revision from the display string.

The product script already verifies fixed hashes for fallback Go archives. This section governs separate Agent toolchain preparation and does not change the product's source-verification requirements.

## Reuse one target for every command

Use `examples/deploy.conf.example` to save a secret-free configuration at an explicit location. It is an allowlisted data file, not a shell script; do not `source` it or put tokens in it. Pin Region, names, IP, TCP/UDP ports, RUN_USER, VERIFY_CLIENTS_MODE, version and security level, then pass the same `--config` to every command.

```bash
# Fill target.conf for the actual resources; record its real location.
target=/root/derper-install/target.conf
script=/root/derper-install/repo/scripts/deploy_derper_ip_selfsigned.sh
common=(--config "$target")
bash "$script" check "${common[@]}"
# Verify binary provenance/hash first; verify again after root copies it privately.
bash "$script" deploy "${common[@]}" --binary /root/derper-install/derper \
  --binary-sha256 EXPECTED_SHA256 --non-interactive
bash "$script" status "${common[@]}" --format json
bash "$script" derpmap "${common[@]}"
```

A helper entry point may also reuse one Bash argument array, but it must cover the complete target. Do not pass the Region name during deployment and omit it during status queries, which would display default my-derp metadata. If GOPROXY/GOSUMDB are outside the config allowlist, supply them separately in the environment needed for build/import; do not disable GOSUMDB.

Use a fixed source archive and hash for each run. Do not execute unverified root programs directly from user-writable locations. Verify in a root-private directory before extracting and running. Do not reuse a first-install-only entry point for daily status checks. New helpers and reports must not overwrite original historical evidence.

## Completion and next actions

Use the final target summary as the installation reference; an upstream Region900 example does not override actual parameters. Merge the node fragment into the latest policy, preserve other rules and Regions, verify distribution, then test. Record public TLS/STUN and authorized-client H3 separately. If H3 or automatic-maintenance authorization is missing, hand off the unverified scope and manual responsibilities explicitly. Do not fabricate success or change live networking without authorization.

See the [authorization and activation guide](AUTO_MAINTENANCE_EN.md) for administrator renewal setup. An Agent must not report local enrollment, token issuance or ready maintenance status as full cloud-renewal acceptance. Distinguish four evidence sets: admin authorization, server activation, the first real rotation and client propagation.
