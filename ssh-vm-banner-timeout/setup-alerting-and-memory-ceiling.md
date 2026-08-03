## Overview

This is a short, one-time setup checklist for the two pieces of `self-healing.md`'s hardening that need `sudo` and couldn't be applied non-interactively over SSH: `netdata` email alerting for memory pressure, and a host-level memory ceiling for everything running under your login session on `dev` (Docker plus `vscode-server`, which sits outside any container and outside the `mem_limit` protection already applied elsewhere). Every command below runs **on `dev`**, not on `mba15` — SSH in first (`ssh dev`), then work through the steps in order. Two commands need you to fill in a placeholder (your SMTP relay credentials and your email address) before running them; nothing else requires edits. Once done, `self-healing.md` should be updated to mark these as applied rather than pending.

**Status (2026-07-29): step 5 (memory ceiling) applied and verified; step 7 (`vscode-server-reap` timer) applied.** Alerting (steps 1-4) still deferred by choice — left in place below for whenever that gets picked back up.

---

## Table of Contents

- [Overview](#overview)
- [Run these on `dev` (SSH in first: `ssh dev`)](#run-these-on-dev-ssh-in-first-ssh-dev)
  - [1. Install a mail relay client](#1-install-a-mail-relay-client)
  - [2. Configure the mail relay — fill in your own SMTP details first](#2-configure-the-mail-relay-fill-in-your-own-smtp-details-first)
  - [3. Add the netdata memory alarm](#3-add-the-netdata-memory-alarm)
  - [4. Point netdata's alerts at your email — fill in your address first](#4-point-netdatas-alerts-at-your-email-fill-in-your-address-first)
  - [5. Add the host-level memory ceiling](#5-add-the-host-level-memory-ceiling)
  - [6. Apply everything and verify](#6-apply-everything-and-verify)
  - [7. Install the `vscode-server-reap` timer (2026-07-29)](#7-install-the-vscode-server-reap-timer-2026-07-29)

## Run these on `dev` (SSH in first: `ssh dev`)

### 1. Install a mail relay client

`dev` currently has no way to send email at all. `msmtp` is a lightweight relay client `netdata` can shell out to.

```bash
sudo apt-get update && sudo apt-get install -y msmtp msmtp-mta
```

### 2. Configure the mail relay — fill in your own SMTP details first

Use whatever SMTP provider you already trust (Gmail app password, SendGrid, Mailgun, etc.). Edit the four `<...>` placeholders below before running.

```bash
sudo tee /etc/msmtprc > /dev/null << 'EOF'
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        default
host           <YOUR_SMTP_HOST>       # e.g. smtp.gmail.com
port           587
from           <YOUR_FROM_ADDRESS>
user           <YOUR_SMTP_USERNAME>
password       <YOUR_SMTP_PASSWORD_OR_APP_PASSWORD>
EOF
sudo chmod 600 /etc/msmtprc
```

### 3. Add the netdata memory alarm

Warns at 80% RAM used, critical at 90%.

```bash
sudo tee /etc/netdata/health.d/dev-memory.conf > /dev/null << 'EOF'
 template: ram_usage_high
       on: system.ram
    class: Utilization
     type: System
component: Memory
    every: 30s
     warn: $used_percent > 80
     crit: $used_percent > 90
    delay: down 5m multiplier 1.5 max 1h
  summary: RAM usage on dev VM
     info: System memory utilization
EOF
```

### 4. Point netdata's alerts at your email — fill in your address first

```bash
sudo sed -i \
  -e 's/^SEND_EMAIL=.*/SEND_EMAIL="YES"/' \
  -e 's/^DEFAULT_RECIPIENT_EMAIL=.*/DEFAULT_RECIPIENT_EMAIL="<YOUR_EMAIL>"/' \
  /etc/netdata/health_alarm_notify.conf
```

### 5. Add the host-level memory ceiling

Caps your entire login session (Docker + `vscode-server` + everything else) at 14GB, leaving ~2GB headroom for the system itself.

```bash
sudo mkdir -p /etc/systemd/system/user-1000.slice.d
sudo tee /etc/systemd/system/user-1000.slice.d/override.conf > /dev/null << 'EOF'
[Slice]
MemoryMax=14G
MemoryHigh=13G
EOF
```

### 6. Apply everything and verify

```bash
sudo systemctl daemon-reload
sudo systemctl restart netdata
systemctl show user-1000.slice -p MemoryMax,MemoryHigh
```

The last command's output should show `MemoryMax=15032385536` (14GB in bytes) and `MemoryHigh=13958643712` (13GB) — if it prints `infinity` for either, the override didn't apply and it's worth re-checking step 5.

### 7. Install the `vscode-server-reap` timer (2026-07-29)

Already transferred to `/tmp/` on `dev` (via `scp`, no `sudo` needed for that part) — this just moves them into place and enables the timer. See `self-healing.md` item 6 and `configs.md` entry 7 for what this does and why.

```bash
sudo mv /tmp/reap-vscode-server.sh /usr/local/bin/reap-vscode-server.sh
sudo chmod +x /usr/local/bin/reap-vscode-server.sh
sudo mv /tmp/vscode-server-reap.service /etc/systemd/system/vscode-server-reap.service
sudo mv /tmp/vscode-server-reap.timer /etc/systemd/system/vscode-server-reap.timer
sudo systemctl daemon-reload
sudo systemctl enable --now vscode-server-reap.timer
systemctl list-timers vscode-server-reap.timer
```

The last command should show a next-run time roughly 6 hours out.
