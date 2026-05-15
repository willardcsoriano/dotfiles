# dotfiles

My personal Linux config files for Debian/Ubuntu XFCE. One command to reproduce my setup on any machine.

```sh
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/dotfiles/main/install.sh | sh
```

No git required. Changes apply immediately — no logout needed.

---

## What's included

### Touchpad

Default XFCE touchpad settings are painful — slow cursor and no tap-to-click, meaning you have to physically press the pad down every time. This fixes both.

- **Tap-to-click** — tap the surface instead of pressing down, which also saves the click mechanism from wearing out
- **Max acceleration speed** — cursor feels snappy from first login
- Auto-detects your touchpad — no hardcoded device IDs, works across hardware

---

## Requirements

- Debian/Ubuntu-based distro, X11
- `curl` (pre-installed on most distros)
- `xinput` (installed automatically if missing)

## How it works

`install.sh` pulls files directly from GitHub and puts them in the right places:

| File | What it does |
|------|-------------|
| `/etc/X11/Xsession.d/99-touchpad-tap` | Runs at every X login, before the desktop loads |
| `~/.bashrc` append | Fallback — reapplies settings on every new terminal |

Both are auto-detecting scripts — they find your touchpad by name, not by ID, so they work regardless of distro or touchpad brand.

## Adding more configs

This repo is meant to grow. To add a new config:

1. Drop the file or script in a logical folder
2. Add an install step to `install.sh`
3. Document it here under a new section
