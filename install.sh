#!/bin/sh

set -e

VERSION="v0.1.0"
REPO_RAW="https://raw.githubusercontent.com/willardcsoriano/dotfiles/$VERSION"

# Require Debian/Ubuntu
if ! command -v apt-get > /dev/null 2>&1; then
    echo "Error: requires a Debian/Ubuntu-based distro with apt."
    exit 1
fi

# Drop libinput config so settings persist across login and hibernate
echo "Installing /etc/X11/xorg.conf.d/40-libinput-touchpad.conf..."
sudo mkdir -p /etc/X11/xorg.conf.d
curl -fsSL "$REPO_RAW/xorg.conf.d/40-libinput-touchpad.conf" | sudo tee /etc/X11/xorg.conf.d/40-libinput-touchpad.conf > /dev/null

# Install systemd sleep hook so the touchpad is re-enabled after lid open.
# The bcm5974 re-enumerates on resume and xfsettingsd can disable it during
# property replay if it has a stale Device_Enabled=0 stored.
echo "Installing systemd sleep hook /etc/systemd/system-sleep/touchpad-resume..."
sudo mkdir -p /etc/systemd/system-sleep
curl -fsSL "$REPO_RAW/etc/systemd/system-sleep/touchpad-resume" | sudo tee /etc/systemd/system-sleep/touchpad-resume > /dev/null
sudo chmod +x /etc/systemd/system-sleep/touchpad-resume

# Fix XFCE storing Device_Enabled=0 for bcm5974, which causes xfsettingsd to
# disable the touchpad every time it reconnects (on resume, on USB re-enum, etc.)
if command -v xfconf-query > /dev/null 2>&1; then
    echo "Fixing XFCE touchpad enable state..."
    xfconf-query -c pointers -p /bcm5974/Properties/Device_Enabled -t int -s 1 2>/dev/null || true
fi

# Merge VS Code Remote-SSH keep-alive settings into the user's settings.json,
# preserving whatever else is already there.
echo "Configuring VS Code Remote-SSH keep-alives..."
VSCODE_SETTINGS="$HOME/.config/Code/User/settings.json"
mkdir -p "$(dirname "$VSCODE_SETTINGS")"
[ -f "$VSCODE_SETTINGS" ] || echo '{}' > "$VSCODE_SETTINGS"
if command -v python3 > /dev/null 2>&1; then
    NEW_SETTINGS=$(curl -fsSL "$REPO_RAW/vscode/settings.json")
    python3 - "$VSCODE_SETTINGS" "$NEW_SETTINGS" <<'PY'
import json, sys
path, new_raw = sys.argv[1], sys.argv[2]
with open(path) as f:
    existing = json.load(f)
existing.update(json.loads(new_raw))
with open(path, "w") as f:
    json.dump(existing, f, indent=4)
    f.write("\n")
PY
    echo "Done. VS Code will use the new Remote-SSH settings next time it connects."
else
    echo "Skipped: python3 not found, could not safely merge VS Code settings.json."
fi

# Install the fix-ssh utility (cleans up stale ControlMaster sockets left
# behind by a bad disconnect; `fix-ssh --vscode [host]` also force-kills
# orphaned vscode-server sessions on a remote host) so it's runnable as a
# bare command.
echo "Installing fix-ssh to \$HOME/.local/bin..."
mkdir -p "$HOME/.local/bin"
curl -fsSL "$REPO_RAW/scripts/fix-ssh.sh" -o "$HOME/.local/bin/fix-ssh"
chmod +x "$HOME/.local/bin/fix-ssh"
if ! command -v fix-ssh > /dev/null 2>&1; then
    echo "Note: \$HOME/.local/bin isn't on your PATH yet — add it to use 'fix-ssh' directly, or run \$HOME/.local/bin/fix-ssh."
fi

# Install the reset-vscode utility (clears the stale singleton lock/sockets
# left behind after a VS Code window hang, so the next launch doesn't wedge
# into the same "Close/Reopen" unresponsive dialog).
echo "Installing reset-vscode to \$HOME/.local/bin..."
curl -fsSL "$REPO_RAW/scripts/reset-vscode.sh" -o "$HOME/.local/bin/reset-vscode"
chmod +x "$HOME/.local/bin/reset-vscode"
if ! command -v reset-vscode > /dev/null 2>&1; then
    echo "Note: \$HOME/.local/bin isn't on your PATH yet — add it to use 'reset-vscode' directly, or run \$HOME/.local/bin/reset-vscode."
fi

# Install the fix-wifi utility (forces a clean wifi reconnect, or power-
# cycles Bluetooth with --bluetooth, without needing a full reboot).
echo "Installing fix-wifi to \$HOME/.local/bin..."
curl -fsSL "$REPO_RAW/scripts/fix-wifi.sh" -o "$HOME/.local/bin/fix-wifi"
chmod +x "$HOME/.local/bin/fix-wifi"
if ! command -v fix-wifi > /dev/null 2>&1; then
    echo "Note: \$HOME/.local/bin isn't on your PATH yet — add it to use 'fix-wifi' directly, or run \$HOME/.local/bin/fix-wifi."
fi

# Install the wifi-watchdog service (auto-detects the wifi driver getting
# stuck refusing every association attempt -- see
# notes/wifi-driver-lockup-2026-08-21.md -- and runs a radio-level reset via
# `fix-wifi --radio` before it needs a reboot to clear).
echo "Installing wifi-watchdog to \$HOME/.local/bin..."
curl -fsSL "$REPO_RAW/scripts/wifi-watchdog.sh" -o "$HOME/.local/bin/wifi-watchdog"
chmod +x "$HOME/.local/bin/wifi-watchdog"
echo "Installing systemd user service wifi-watchdog.service..."
mkdir -p "$HOME/.config/systemd/user"
curl -fsSL "$REPO_RAW/etc/systemd/user/wifi-watchdog.service" -o "$HOME/.config/systemd/user/wifi-watchdog.service"
if command -v systemctl > /dev/null 2>&1; then
    systemctl --user daemon-reload
    systemctl --user enable --now wifi-watchdog.service
fi

# Install the recon utility (runs every local diagnostic -- wifi, SSH
# ControlMaster, VS Code lock -- plus the dev VM check, and prints exactly
# which alias to run for whatever it finds. Advisory only, entirely local;
# see notes/wifi-driver-lockup-2026-08-21.md for why this exists).
echo "Installing recon to \$HOME/.local/bin..."
curl -fsSL "$REPO_RAW/scripts/recon.sh" -o "$HOME/.local/bin/recon"
chmod +x "$HOME/.local/bin/recon"
if ! command -v recon > /dev/null 2>&1; then
    echo "Note: \$HOME/.local/bin isn't on your PATH yet — add it to use 'recon' directly, or run \$HOME/.local/bin/recon."
fi

# Install the ssh-control-reset systemd sleep hook (exits stale SSH
# ControlMaster sockets after resume — suspend freezes the mux process, so
# ServerAliveInterval never gets a chance to notice the connection died
# while asleep, leaving a zombie master that hangs the next real connection).
echo "Installing systemd sleep hook /etc/systemd/system-sleep/ssh-control-reset..."
sudo mkdir -p /etc/systemd/system-sleep
curl -fsSL "$REPO_RAW/etc/systemd/system-sleep/ssh-control-reset" | sudo tee /etc/systemd/system-sleep/ssh-control-reset > /dev/null
sudo chmod +x /etc/systemd/system-sleep/ssh-control-reset

# Install the check-dev utility (advisory-only health check for the dev VM --
# queries docker.service restarts, swap/memory pressure, and load, then tells
# you what to run, if anything; never takes action itself).
echo "Installing check-dev to \$HOME/.local/bin..."
curl -fsSL "$REPO_RAW/scripts/check-dev.sh" -o "$HOME/.local/bin/check-dev"
chmod +x "$HOME/.local/bin/check-dev"
if ! command -v check-dev > /dev/null 2>&1; then
    echo "Note: \$HOME/.local/bin isn't on your PATH yet — add it to use 'check-dev' directly, or run \$HOME/.local/bin/check-dev."
fi

# Install tmux + config. Long-running CLI agent sessions belong in tmux, not
# a raw shell (survives disconnects/vscode-server churn on remote hosts, and
# fixes mouse-wheel scroll landing in a foreground app's own UI instead of
# tmux's scrollback -- see ssh-vm-banner-timeout/self-healing.md item 7).
if ! command -v tmux > /dev/null 2>&1; then
    echo "Installing tmux..."
    sudo apt-get install -y tmux
fi
echo "Installing tmux config to \$HOME/.tmux.conf..."
curl -fsSL "$REPO_RAW/ssh-vm-banner-timeout/tmux.conf" -o "$HOME/.tmux.conf"

# Apply to current session immediately via xinput
if command -v xinput > /dev/null 2>&1; then
    TOUCHPAD_ID=$(xinput list | grep -i -E "touchpad|bcm5974|trackpad" | grep -o 'id=[0-9]*' | grep -o '[0-9]*' | head -1)
    if [ -n "$TOUCHPAD_ID" ]; then
        TAP_PROP=$(xinput list-props "$TOUCHPAD_ID" | grep "Tapping Enabled (" | grep -v Default | grep -o '([0-9]*)' | grep -o '[0-9]*' | head -1)
        SPEED_PROP=$(xinput list-props "$TOUCHPAD_ID" | grep "Accel Speed (" | grep -v Default | grep -o '([0-9]*)' | grep -o '[0-9]*' | head -1)
        [ -n "$TAP_PROP" ] && xinput set-prop "$TOUCHPAD_ID" "$TAP_PROP" 1
        [ -n "$SPEED_PROP" ] && xinput set-prop "$TOUCHPAD_ID" "$SPEED_PROP" 1.0
        echo "Done. Settings applied immediately and will persist across hibernate."
    else
        echo "Done. No touchpad found for immediate apply — settings take effect on next login."
    fi
else
    echo "Done. Settings take effect on next login."
fi
