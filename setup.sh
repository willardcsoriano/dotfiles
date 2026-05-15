#!/bin/sh

# Setup script - run this on a fresh machine to apply all dotfiles

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

echo "Installing touchpad settings..."

sudo cp "$SCRIPT_DIR/xsession.d/99-touchpad-tap" /etc/X11/Xsession.d/

sudo chmod +x /etc/X11/Xsession.d/99-touchpad-tap

echo "Applying bashrc additions..."

if ! grep -q "touchpad tap-to-click" ~/.bashrc; then

    cat "$SCRIPT_DIR/bashrc.append" >> ~/.bashrc

fi

echo "Done. Log out and back in to apply all settings."
