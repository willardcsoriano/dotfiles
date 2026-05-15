# dotfiles

Personal Linux config files. Tested on Debian Trixie XFCE. Should work on any Debian/Ubuntu-based distro using libinput.

## Why

Touchpad physical click mechanisms wear out over time. Tap-to-click lets you tap the surface instead of pressing down, which means the hardware lasts much longer. Max speed is also set so the cursor feels snappy from the moment you log in.

## What's included

- Touchpad tap-to-click (no physical clicking needed, saves hardware)

- Touchpad max acceleration speed

- Auto-detects your touchpad device — no hardcoded IDs or property numbers

## Requirements

- X11

- xinput (`sudo apt install xinput`)

- libinput driver (default on most modern distros)

## Install on a fresh machine

```sh
git clone YOUR_REPO_URL ~/dotfiles
cd ~/dotfiles
sudo apt install xinput
./setup.sh
```

Log out and back in. Done.

## How it works

- `/etc/X11/Xsession.d/99-touchpad-tap` runs at X session start before the desktop loads

- `bashrc.append` is appended to `~/.bashrc` as a fallback every time a terminal opens

- Both auto-detect your touchpad so they work across different hardware and distros

## Manual restore

```sh
sudo cp xsession.d/99-touchpad-tap /etc/X11/Xsession.d/
sudo chmod +x /etc/X11/Xsession.d/99-touchpad-tap
cat bashrc.append >> ~/.bashrc
```
