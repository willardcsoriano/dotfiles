# Configuration Snapshots

## Overview

This captures the before/present state of every configuration file and service that was changed while chasing this issue, so the exact starting point can be restored or referenced if a future fix needs to be compared against the original baseline. Nothing here has been verified to be the actual cause — these are the changes made during attempts 1-4 (see [`timeline.md`](timeline.md)), none of which resolved the issue. Keep this file updated any time one of these configs is touched again, including during the diagnostic steps in [`runbook.md`](runbook.md), so there's always an accurate record of what the system currently looks like versus what it looked like when the issue first appeared.

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
    IPQoS 0x00
```

Multiplexing (`ControlMaster`/`ControlPath`/`ControlPersist`) has been completely removed, not just disabled.

## 4. Client: `~/.bashrc`

**Before:** A custom `fix-ssh` alias that aggressively `pkill`ed SSH processes and deleted `~/.ssh/cm-*` control socket files.

**Present:** Alias removed entirely, since there are no more control sockets to clean up. The background `ssh-agent` startup script is unchanged and still present.

## 5. Client: removed systemd SSH proxy config

`/etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf` — deleted during attempt 4. No replacement added.

## Not yet checked (see `runbook.md`)

None of the following have been inspected yet, and any of them could be the actual root cause per [`analysis.md`](analysis.md):

- `nf_conntrack_max` / current conntrack table usage on the server
- Server memory (`free -h`) and disk (`df -h`) at the time of failure
- Zombie/defunct `sshd` child processes at the time of failure
- `dmesg` output from the server at the time of failure
- Hetzner Cloud Firewall rules attached to the VM (if any)
