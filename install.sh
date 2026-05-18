#!/bin/sh

set -e

REPO_RAW="https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/dotfiles/main"

# Require Debian/Ubuntu
if ! command -v apt-get > /dev/null 2>&1; then
    echo "Error: requires a Debian/Ubuntu-based distro with apt."
    exit 1
fi

# Drop libinput config so settings persist across login and hibernate
echo "Installing /etc/X11/xorg.conf.d/40-libinput-touchpad.conf..."
sudo mkdir -p /etc/X11/xorg.conf.d
curl -fsSL "$REPO_RAW/xorg.conf.d/40-libinput-touchpad.conf" | sudo tee /etc/X11/xorg.conf.d/40-libinput-touchpad.conf > /dev/null

echo "Done. Log out and back in to apply touchpad settings."
