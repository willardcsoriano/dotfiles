## Overview

My personal Linux config files for Debian/Ubuntu XFCE. One command to reproduce my setup on any machine — no git required. The configs target the driver level where possible, so settings survive login, hibernate/resume, and device name changes (e.g. bcm5974 → keyd after wake). Currently covers touchpad behaviour; the repo is structured to grow as more configs are added.

```sh
curl -fsSL https://raw.githubusercontent.com/willardcsoriano/dotfiles/master/install.sh | sh
```

Settings take effect on next login.

---

## Table of Contents

- [Overview](#overview)
- [What's included](#whats-included)
  - [Touchpad](#touchpad)
- [Requirements](#requirements)
- [How it works](#how-it-works)
- [Adding more configs](#adding-more-configs)

## What's included

### Touchpad

Default XFCE touchpad settings are painful — slow cursor and no tap-to-click, meaning you have to physically press the pad down every time. This fixes both.

- **Tap-to-click** — tap the surface instead of pressing down, which also saves the click mechanism from wearing out
- **Max acceleration speed** — cursor feels snappy from first login
- Configured at the libinput driver level — persists across hibernate/resume, not just login

---

## Requirements

- Debian/Ubuntu-based distro, X11 with libinput driver
- `curl` (pre-installed on most distros)

## How it works

`install.sh` pulls files directly from GitHub and puts them in the right places:

| File | What it does |
|------|-------------|
| `/etc/X11/xorg.conf.d/40-libinput-touchpad.conf` | Configures libinput at driver level — applies on every X start and survives hibernate |

Settings live at the driver level, not in a login-time script, so there's nothing to re-run after resume.

## Adding more configs

This repo is meant to grow. To add a new config:

1. Drop the file or script in a logical folder
2. Add an install step to `install.sh`
3. Document it here under a new section
