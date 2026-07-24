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
