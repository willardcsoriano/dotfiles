#!/bin/sh

# Setup script - run this on a fresh machine to apply all dotfiles

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

echo "Installing touchpad settings..."
sudo mkdir -p /etc/X11/xorg.conf.d
sudo cp "$SCRIPT_DIR/xorg.conf.d/40-libinput-touchpad.conf" /etc/X11/xorg.conf.d/

# Install systemd sleep hook so the touchpad is re-enabled after lid open.
# The bcm5974 re-enumerates on resume and xfsettingsd can disable it during
# property replay if it has a stale Device_Enabled=0 stored.
echo "Installing systemd sleep hook..."
sudo mkdir -p /etc/systemd/system-sleep
sudo cp "$SCRIPT_DIR/etc/systemd/system-sleep/touchpad-resume" /etc/systemd/system-sleep/
sudo chmod +x /etc/systemd/system-sleep/touchpad-resume

# Fix XFCE storing Device_Enabled=0 for bcm5974, which causes xfsettingsd to
# disable the touchpad every time it reconnects.
if command -v xfconf-query > /dev/null 2>&1; then
    echo "Fixing XFCE touchpad enable state..."
    xfconf-query -c pointers -p /bcm5974/Properties/Device_Enabled -t int -s 1 2>/dev/null || true
fi

echo "Done. Log out and back in to apply touchpad settings."
