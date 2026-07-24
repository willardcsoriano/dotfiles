# Configuration Snapshots

## Overview

This captures the before/present state of every configuration file and service that was changed while chasing this issue, so the exact starting point can be restored or referenced if a future fix needs to be compared against the original baseline. Nothing here has been verified to be the actual cause — these are the changes made across the attempts recorded in [`timeline.md`](timeline.md), none of which resolved the underlying issue (one, the `IPQoS` line, turned out to be a syntax bug that broke the client outright, fixed separately from the VM problem). Keep this file updated any time one of these configs is touched again, including during the diagnostic steps in [`runbook.md`](runbook.md), so there's always an accurate record of what the system currently looks like versus what it looked like when the issue first appeared.

## Table of Contents

- [Overview](#overview)
- [1. Server: `/etc/ssh/sshd_config`](#1-server-etcsshsshd_config)
- [2. Server: SSH daemon service management](#2-server-ssh-daemon-service-management)
- [3. Client: `~/.ssh/config`](#3-client-sshconfig)
- [4. Client: `~/.bashrc`](#4-client-bashrc)
- [5. Client: removed systemd SSH proxy config](#5-client-removed-systemd-ssh-proxy-config)
- [Not yet checked (see `runbook.md`)](#not-yet-checked-see-runbookmd)

## 1. Server: `/etc/ssh/sshd_config`

**Before (original baseline):**

```sshconfig
LoginGraceTime 15
MaxSessions 50
TCPKeepAlive yes
ClientAliveInterval 5
ClientAliveCountMax 3
MaxStartups 50:30:100
```

**Present:**

```sshconfig
LoginGraceTime 30
MaxSessions 50
TCPKeepAlive no
ClientAliveInterval 5
ClientAliveCountMax 3
MaxStartups 100:30:150
```

## 2. Server: SSH daemon service management

**Before:** Managed by systemd socket activation (`ssh.socket` active, `sshd` started on-demand per connection).

**Present:** Socket activation disabled; running as a persistent standalone daemon.

```bash
sudo systemctl stop ssh.socket
sudo systemctl disable ssh.socket
sudo systemctl enable ssh.service
sudo systemctl start ssh.service
```

## 3. Client: `~/.ssh/config`

**Before:**

```sshconfig
Host *
    ServerAliveInterval 15
    ServerAliveCountMax 4
    ConnectTimeout 5
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 2h
```

**Present:**

```sshconfig
Host *
    AddKeysToAgent yes
    ServerAliveInterval 10
    ServerAliveCountMax 3
    ConnectTimeout 5
    IPQoS 0
```

Multiplexing (`ControlMaster`/`ControlPath`/`ControlPersist`) has been completely removed, not just disabled. In between the original baseline and this present state, `ControlPath` was actually changed twice more first (`~/.ssh/cm-%r@%h:%p` → `~/.ssh/cm-%h`) while multiplexing was still enabled, chasing a stale-socket bug, before the decision was made to drop multiplexing entirely — see `timeline.md` attempt 3.

`IPQoS` was originally set to `0x00` (invalid syntax — OpenSSH rejects the hex-prefixed form outright, which broke the SSH client entirely, for every host, not just `dev`). Fixed to the valid decimal form `IPQoS 0` on 2026-07-24. See `timeline.md` ("Self-inflicted regression") and `analysis.md` for why the underlying theory behind this line was technically unsound to begin with; it's left in place only because it's harmless, not because it's believed to matter.

## 4. Client: `~/.bashrc`

**Before:** A custom `fix-ssh` alias that aggressively `pkill`ed SSH processes and deleted `~/.ssh/cm-*` control socket files.

**Present:** Alias removed entirely, since there are no more control sockets to clean up. The background `ssh-agent` startup block had been left duplicated (the same `if ! pgrep -u "$USER" ssh-agent ...` guard appeared twice, plus a dangling comment header for the removed alias) from repeated `cat <<EOF >> ~/.bashrc` appends during the troubleshooting session — harmless, but cleaned up (deduplicated) on 2026-07-24.

## 5. Client: removed systemd SSH proxy config

`/etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf` — deleted during attempt 4. No replacement added.

## Not yet checked (see `runbook.md`)

None of the following have been inspected yet, and any of them could be the actual root cause per [`analysis.md`](analysis.md):

- `nf_conntrack_max` / current conntrack table usage on the server
- Server memory (`free -h`) and disk (`df -h`) at the time of failure
- Zombie/defunct `sshd` child processes at the time of failure
- `dmesg` output from the server at the time of failure
- Hetzner Cloud Firewall rules attached to the VM (if any)
