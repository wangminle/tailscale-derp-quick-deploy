# Public-network and relay acceptance guide

[中文](ACCEPTANCE_CN.md) | English

This is the operator-facing acceptance entry point. Local installation, public protocol reachability, control-plane distribution and an actual relay round trip through the requested Region are separate conclusions.

## 1. Preparation

- Pin the public IP, TCP/UDP ports, Region, service user, derper and tailscaled versions.
- Use system OpenSSH with host-key verification. Do not read node private keys or place OAuth secrets in commands or logs.
- Merge the node fragment into the latest policy, preserving `grants`, `ssh` and other Regions. Never replace the entire policy with a single-node fragment.
- Keep `verify-clients` enabled. `debug derp` uses a temporary random identity and cannot substitute for authorized-client evidence.

## 2. Local state and distributed configuration

```bash
systemctl is-active derper
systemctl show derper -p MainPID -p NRestarts -p User
tailscale debug derp-map
```

Confirm the intended process owns the target listeners and the Region has one target node. HostName/explicit IP, DERPPort, STUNPort and CertName must match. `netcheck` is region discovery, not proof of a relay round trip.

## 3. Public TLS and STUN

From a network outside the server:

- TLS: read the served DER certificate and compare its SHA256 with both the control-plane `sha256-raw:` pin and the on-disk certificate.
- STUN: send a Binding request with `tailnode` SOFTWARE and FINGERPRINT, then validate the response type, transaction ID, length and mapped address.

`nc -zvu` can produce false positives and is not STUN acceptance evidence. See `scripts/h3_probe.py` and the [maintenance guide](MAINTENANCE_EN.md) for the probe implementation.

## 4. Authorized-client round trip through the requested Region

On an independent authorized Linux client, target another authorized peer:

```bash
sudo python3 /opt/derper-probe/h3_probe.py \
  --region-id 901 --ip 114.67.236.43 \
  --derp-port 30399 --stun-port 3478 \
  --peer-ip 100.107.224.117 --timeout 10
```

Replace all example targets. Success requires a matching distributed target and certificate pin, a real disco round trip whose DERPRegionID is the requested Region, the intended peer, and valid STUN. The adapter must print its eight-line report and exit 0.

A normal `tailscale ping` reporting `via DERP(<target Region>)` is also relay evidence. `direct connection not established` only means P2P was not established; it does not negate DERP pongs already received. Direct paths, other Regions, peer relay, ambiguous nodes or unconfirmed certificate propagation remain unverified rather than proof of target-DERP failure.

Do not globally block UDP, force routing or disable client verification to manufacture success. Controlled network conditions require recoverable test resources and a documented change/restoration plan.

## 5. Health-scheduler acceptance

After installation, verify all of the following:

1. The timer is enabled and active, with no duplicate cron and timer schedules.
2. A manual oneshot reports `Result=success` and `ExecMainStatus=0`.
3. A separate natural trigger also succeeds and refreshes the state-file timestamp.
4. The state file retains the intended config path, IP, ports and Region.
5. derper MainPID, certificates and automatic-maintenance state do not change unexpectedly.

With configuration, the scheduler reads a root-managed stable copy. Edit that copy to change later checks; duplicate IP, port or Region arguments are not needed. Moving the original configuration does not remove this stable copy.

## 6. Evidence and scope

Record the time, target, script and binary hashes, actual commands, exit codes, certificate pins, journal entries, state timestamps and authorized-client output. Cloud API writes, rotation propagation, failure injection, cross-platform adapters and long-lived certificate compatibility require separate acceptance and cannot be inferred from one installation or check.
