#!/bin/sh

# Setup script - run this on a fresh machine to apply all dotfiles

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

echo "Installing touchpad settings..."

sudo mkdir -p /etc/X11/xorg.conf.d

sudo cp "$SCRIPT_DIR/xorg.conf.d/40-libinput-touchpad.conf" /etc/X11/xorg.conf.d/

echo "Done. Log out and back in to apply touchpad settings."
