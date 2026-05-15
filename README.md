# dotfiles

Personal Linux config files. Tested on Debian Trixie XFCE. Should work on any Debian/Ubuntu-based distro using libinput.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/dotfiles/main/install.sh | sh
```

No git required. Settings apply immediately — no logout needed.

## Why

Touchpad physical click mechanisms wear out over time. Tap-to-click lets you tap the surface instead of pressing down, which means the hardware lasts much longer. Max speed is also set so the cursor feels snappy from the moment you log in.

## What's included

- Touchpad tap-to-click (no physical clicking needed, saves hardware)
- Touchpad max acceleration speed
- Auto-detects your touchpad device — no hardcoded IDs or property numbers

## Requirements

- Debian/Ubuntu-based distro
- X11
- `curl` (pre-installed on most distros)
- `xinput` (installed automatically if missing)

## How it works

- `install.sh` fetches everything directly from GitHub — no git clone needed
- `/etc/X11/Xsession.d/99-touchpad-tap` runs at X session start before the desktop loads
- `bashrc.append` is appended to `~/.bashrc` as a fallback every time a terminal opens
- Both scripts auto-detect your touchpad so they work across different hardware

## Manual restore

```sh
sudo curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/dotfiles/main/xsession.d/99-touchpad-tap \
    -o /etc/X11/Xsession.d/99-touchpad-tap
sudo chmod +x /etc/X11/Xsession.d/99-touchpad-tap
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/dotfiles/main/bashrc.append >> ~/.bashrc
```
