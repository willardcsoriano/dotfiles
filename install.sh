#!/bin/sh

set -e

REPO_RAW="https://raw.githubusercontent.com/willardcsoriano/dotfiles/main"

# Require Debian/Ubuntu
if ! command -v apt-get > /dev/null 2>&1; then
    echo "Error: requires a Debian/Ubuntu-based distro with apt."
    exit 1
fi

# Drop libinput config so settings persist across login and hibernate
echo "Installing /etc/X11/xorg.conf.d/40-libinput-touchpad.conf..."
sudo mkdir -p /etc/X11/xorg.conf.d
curl -fsSL "$REPO_RAW/xorg.conf.d/40-libinput-touchpad.conf" | sudo tee /etc/X11/xorg.conf.d/40-libinput-touchpad.conf > /dev/null

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
