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
- [6. Server: `~/repos/wfmctrading/docker-compose.yml` (2026-07-28)](#6-server-reposwfmctradingdocker-composeyml-2026-07-28)
- [7. Server: `vscode-server-reap` timer (2026-07-29)](#7-server-vscode-server-reap-timer-2026-07-29)
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

**Tracked since 2026-10-12:** the `Host *` defaults below live in [`ssh/defaults.conf`](../ssh/defaults.conf). `install.sh` includes that file at the end of `~/.ssh/config`, so host-specific settings in `config.local` still override it. Before that, they existed only in each machine's untracked `~/.ssh/config`, so a new machine silently lost them, including the `ConnectTimeout` that sets VS Code Remote-SSH's connect budget. On mba15 the hand-written block was removed after migrating (backup `~/.ssh/config.bak-pre-dotfiles-defaults`). `ssh -G` output was identical for every configured host before and after.

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
    ConnectTimeout 30
    ConnectionAttempts 5
    IPQoS 0
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 2h
```

Multiplexing was removed once (`timeline.md` attempt 3, after `ControlPath` changed from `~/.ssh/cm-%r@%h:%p` to `~/.ssh/cm-%h` while chasing a stale-socket bug) and then deliberately re-added on 2026-07-29 — see `self-healing.md`. On 2026-10-20 the path went back to `~/.ssh/cm-%r@%h:%p`: with `%h` alone, two users on one host share a socket, so `ssh v@box` silently ran over an open `root@box` master as root. The zombie-master-after-suspend failure it can cause is handled by the `ssh-control-reset` sleep hook. `ConnectionAttempts 5` was added on 2026-08-12 (`incident-2026-08-12-mobile-sim-connectivity-struggle.md`).

`ConnectTimeout` was raised from 5 to 15 on 2026-10-12. VS Code Remote-SSH reads this value, adds 2s, and uses the result as its whole connect budget, overriding `remote.SSH.connectTimeout`. At 5, it gave up after 7s, which a slow mobile link can't meet (`incident-2026-10-12-slow-mobile-link-remote-ssh-timeout.md`). The cost is that a plain `ssh` to a truly dead host now waits up to 15s per attempt before failing.

Raised again, from 15 to 30, on 2026-10-15 (dotfiles#45). Fresh logins to `dev` over lossy mobile data took 3.5–18.3s, and the 18.3s one missed the resulting 17s budget; at 30 the budget is 32s. `ConnectTimeout` covers TCP connect, the banner and key exchange, but not authentication (`man ssh_config`), so a slow login fails Remote-SSH's budget before it ever trips ssh's own timeout. The cost doubles too: a host that silently drops TCP now takes up to 30s per attempt, and `ConnectionAttempts 5` retries a failed TCP connect, so up to about 2.5 minutes before plain `ssh` gives up. A host that refuses the connection outright still fails at once.

`IPQoS` was originally set to `0x00` (invalid syntax — OpenSSH rejects the hex-prefixed form outright, which broke the SSH client entirely, for every host, not just `dev`). Fixed to the valid decimal form `IPQoS 0` on 2026-07-24. See `timeline.md` ("Self-inflicted regression") and `analysis.md` for why the underlying theory behind this line was technically unsound to begin with; it's left in place only because it's harmless, not because it's believed to matter.

## 4. Client: `~/.bashrc`

**Before:** A custom `fix-ssh` alias that aggressively `pkill`ed SSH processes and deleted `~/.ssh/cm-*` control socket files.

**Present:** Alias removed entirely, since there are no more control sockets to clean up. The background `ssh-agent` startup block had been left duplicated (the same `if ! pgrep -u "$USER" ssh-agent ...` guard appeared twice, plus a dangling comment header for the removed alias) from repeated `cat <<EOF >> ~/.bashrc` appends during the troubleshooting session — harmless, but cleaned up (deduplicated) on 2026-07-24.

## 5. Client: removed systemd SSH proxy config

`/etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf` — deleted during attempt 4. No replacement added.

## 6. Server: `~/repos/wfmctrading/docker-compose.yml` (2026-07-28)

Not an SSH/network config — a Docker Compose file on the VM, changed after the 2026-07-28 recurrence traced back to this specific project's containers having no memory ceiling. See `timeline.md`'s "Recurrence (2026-07-28)" section for the full diagnosis.

**Before:** no `mem_limit` on any of the three services (`app`, `nginx`, `postgres`) — unbounded.

**Present:**

```yaml
services:
  app:
    # ...unchanged...
    mem_limit: 2g
    mem_reservation: 512m

  nginx:
    # ...unchanged...
    mem_limit: 256m

  postgres:
    # ...unchanged...
    mem_limit: 1g
```

Applied directly on the VM via SSH and validated with `docker compose config`. **Left uncommitted** — `wfmctrading` is a separate, independently git-tracked repo not managed by this dotfiles repo or session; committing it there is the user's call.

**Also identified but not yet fixed:** `~/repos/wfmctrading/Dockerfile` never sets `pm.max_requests` on the php-fpm pool (disabled by default in the stock `php:8.4-fpm` image), so workers are never recycled — confirmed responsible for the July 28 incident (a worker alive ~53 hours). Recommended fix: add `pm.max_requests = 300` (or similar) to the pool config, e.g. via a second `sed` line in the Dockerfile alongside the existing one that sets `user`/`group` in `www.conf`, or a dedicated pool `.conf` snippet in `/usr/local/etc/php-fpm.d/`.

## 7. Server: `vscode-server-reap` timer (2026-07-29)

Not present before. Added after the 2026-07-29 confirmed incident (see `self-healing.md`'s "Confirmed occurrence" section) where six orphaned `vscode-server` sessions, accumulated over ~19-24 hours across a wifi drop and a client auto-update, exhausted swap and blocked new Remote-SSH connections.

**Present:**

```bash
# /usr/local/bin/reap-vscode-server.sh — see ssh-vm-banner-timeout/reap-vscode-server.sh for full source
```

```ini
# /etc/systemd/system/vscode-server-reap.service
[Unit]
Description=Reap orphaned vscode-server sessions older than 24h

[Service]
Type=oneshot
User=willard
ExecStart=/usr/local/bin/reap-vscode-server.sh
```

```ini
# /etc/systemd/system/vscode-server-reap.timer
[Unit]
Description=Run vscode-server-reap.service every 6 hours

[Timer]
OnBootSec=15min
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=timers.target
```

## Not yet checked (see `runbook.md`)

The `nf_conntrack`/firewall items below were never inspected because the root cause turned out to be memory/process-starvation-based both times this issue was actually diagnosed (2026-07-24 and 2026-07-28) — they remain untested theories, not ruled out, only superseded by a confirmed cause each time:

- `nf_conntrack_max` / current conntrack table usage on the server
- Zombie/defunct `sshd` child processes at the time of failure
- `dmesg` output from the server at the time of failure
- Hetzner Cloud Firewall rules attached to the VM (if any)

Server memory (`free -h`) and disk I/O **have** been checked, both times (see `analysis.md` and `rca.md`) — removed from this list since they're no longer unchecked.
