# Timeline of Attempts

## Overview

This is the chronological record of every fix attempted for the SSH banner-exchange timeout on the `dev` VM, in the order they happened, before this documentation existed. Each entry lists the theory that motivated it, the exact change made, and the result. All four attempts failed to fix the underlying issue. They are recorded in detail specifically so they are not repeated — each looked plausible at the time, and without this record the same dead ends would likely get re-tried after the next Wi-Fi drop. The common thread across all four: every one of them modified SSH-layer behavior (application config, client config, systemd unit choice), and none of them addressed the system resource layer underneath `sshd`, which is where the evidence now points (see [`analysis.md`](analysis.md)).

## Table of Contents

- [Overview](#overview)
- [Attempt 1 — Mitigate VS Code multiplexing storms](#attempt-1-mitigate-vs-code-multiplexing-storms)
- [Attempt 2 — Systemd socket activation deadlock](#attempt-2-systemd-socket-activation-deadlock)
- [Attempt 3 — Complete removal of client multiplexing](#attempt-3-complete-removal-of-client-multiplexing)
- [Attempt 4 — Client proxy and MTU blackholing](#attempt-4-client-proxy-and-mtu-blackholing)
- [Diagnostic that reframed the problem](#diagnostic-that-reframed-the-problem)

## Attempt 1 — Mitigate VS Code multiplexing storms

- **Theory:** VS Code Remote-SSH opens 10-20 multiplexed connections per window. A network drop leaves dead TCP sockets behind; on reconnect, the burst of new VS Code connections exhausts the server's connection queue.
- **Action (server, `/etc/ssh/sshd_config`):** increased `MaxStartups`, disabled `TCPKeepAlive`, increased `LoginGraceTime`.
- **Result:** Failed. Still timed out on the next drop.

## Attempt 2 — Systemd socket activation deadlock

- **Theory:** Debian 13 defaults to `ssh.socket` activation. Under a sudden drop with many active connections, systemd's socket wrapper deadlocks and stops handing connections to `sshd`.
- **Action (server):** disabled `ssh.socket`, enabled and started the persistent `ssh.service` (classic standalone daemon). Confirmed running on a stable PID.
- **Result:** Failed. Still timed out on network drops with the classic daemon running.

## Attempt 3 — Complete removal of client multiplexing

- **Theory:** Client-side `ControlMaster` sockets were becoming corrupted on a drop, causing ghost hangs on the next connection attempt.
- **Action (client, `~/.ssh/config`):** removed `ControlMaster`, `ControlPath`, `ControlPersist` entirely. Removed the local `fix-ssh` cleanup alias that used to `pkill` SSH and delete `~/.ssh/cm-*` control sockets.
- **Result:** Failed. `ssh -v` showed the client completing TCP establishment cleanly, then hanging waiting for the server's banner string — i.e. the hang was confirmed to be server-side, not a client control-socket artifact.

## Attempt 4 — Client proxy and MTU blackholing

- **Theory:** A systemd SSH proxy unit on the client, or Path MTU fragmentation over Wi-Fi, was silently dropping the banner packet in transit.
- **Action (client):** deleted `/etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf`. Added `IPQoS 0x00` to the client config.
- **Result:** Failed.

## Diagnostic that reframed the problem

After attempt 4, running two plain `nc` tests (not SSH at all) established the actual failure point:

```
nc -zv -w 3 178.104.35.30 22   →  succeeds, port 22 is open (TCP handshake completes)
nc 178.104.35.30 22            →  hangs indefinitely, zero bytes returned
```

Because `nc` is a completely different client than either OpenSSH or VS Code's SSH implementation, and it fails identically, this ruled out every client-side theory (attempts 3 and 4) and reframed the problem as: the TCP handshake is being completed by the kernel, but nothing is ever sending application data back — which points below the SSH application layer entirely. See [`analysis.md`](analysis.md) for what that implies and the ranked hypotheses for the actual cause.
