#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://repo.teamsforlinux.de"
KEYRING_PATH="/etc/apt/keyrings/teams-for-linux.asc"
SOURCE_PATH="/etc/apt/sources.list.d/teams-for-linux-packages.sources"

if command -v teams-for-linux >/dev/null 2>&1; then
    echo "teams-for-linux is already installed at $(command -v teams-for-linux). Nothing to do."
    exit 0
fi

if ! command -v apt >/dev/null 2>&1; then
    echo "Error: apt not found. This script targets Debian/Ubuntu-based systems." >&2
    exit 1
fi

ARCH="$(dpkg --print-architecture)"
echo "Detected architecture: ${ARCH}"

echo "Creating keyring directory..."
sudo mkdir -p /etc/apt/keyrings

echo "Fetching signing key..."
sudo wget -qO "${KEYRING_PATH}" "${REPO_URL}/teams-for-linux.asc"

echo "Registering apt source..."
sudo tee "${SOURCE_PATH}" > /dev/null <<EOF
Types: deb
URIs: ${REPO_URL}/debian/
Suites: stable
Components: main
Signed-By: ${KEYRING_PATH}
Architectures: ${ARCH}
EOF

echo "Updating package lists..."
sudo apt update

echo "Installing teams-for-linux..."
sudo apt install -y teams-for-linux

echo
echo "Done. Launch with: teams-for-linux"
