#!/bin/sh

set -e

REPO_RAW="https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/dotfiles/main"

# Require Debian/Ubuntu
if ! command -v apt-get > /dev/null 2>&1; then
    echo "Error: requires a Debian/Ubuntu-based distro with apt."
    exit 1
fi

# Install xinput if missing
if ! command -v xinput > /dev/null 2>&1; then
    echo "Installing xinput..."
    sudo apt-get install -y xinput
fi

# Drop Xsession hook so settings apply on every login
echo "Installing /etc/X11/Xsession.d/99-touchpad-tap..."
curl -fsSL "$REPO_RAW/xsession.d/99-touchpad-tap" | sudo tee /etc/X11/Xsession.d/99-touchpad-tap > /dev/null
sudo chmod +x /etc/X11/Xsession.d/99-touchpad-tap

# Append to ~/.bashrc as fallback (skip if already present)
if ! grep -q "touchpad tap-to-click" ~/.bashrc; then
    echo "Updating ~/.bashrc..."
    curl -fsSL "$REPO_RAW/bashrc.append" >> ~/.bashrc
fi

# Apply immediately — no logout needed
echo "Applying touchpad settings now..."
sh /etc/X11/Xsession.d/99-touchpad-tap

echo "Done. Tap-to-click and max speed are active."
