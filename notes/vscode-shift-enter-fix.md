# Fix: Shift+Enter newline broken in VS Code integrated terminal

## Overview

Shift+Enter used to insert a newline in Claude Code (and other terminal-based agent CLIs like Deep Code and Antigravity) when run inside VS Code's integrated terminal panel, but stopped working after a clean VS Code reinstall. The cause is that VS Code doesn't natively distinguish Shift+Enter from plain Enter in its terminal — Claude Code relies on a specific local `keybindings.json` entry to make that distinction, and a clean reinstall wipes that file along with the rest of `~/.config/Code`. This note has the exact fix: either re-run Claude Code's built-in `/terminal-setup`, or add the keybinding manually. It must be done on the machine running the VS Code UI itself (the local machine), not on a remote host reached via Remote-SSH.

## Table of Contents

- [Overview](#overview)
- [Root cause](#root-cause)
- [Fix](#fix)
- [Verify](#verify)

## Root cause

VS Code's integrated terminal sends the same raw byte (`\r`) for both Enter and Shift+Enter unless a keybinding explicitly tells it to send something different when Shift is held. Claude Code's `chat:newline` handling looks for an ESC-prefixed sequence to recognize "insert newline" (the same convention Terminal.app uses for Option+Enter). That distinguishing keybinding lives in VS Code's local `keybindings.json` — not synced from the remote server side, and not restored automatically after a clean reinstall.

## Fix

**Preferred — let Claude Code do it:** run this directly in a local terminal (must NOT be a Remote-SSH terminal — Claude Code explicitly refuses to write VS Code keybindings from a remote session):

```
/terminal-setup
```

Accept the prompt ("Yes, use recommended settings"). It detects VS Code, backs up the existing `keybindings.json`, and installs the binding automatically.

**Manual fallback**, if `/terminal-setup` isn't available or doesn't pick VS Code:

1. Open VS Code on the local machine (not a Remote-SSH window)
2. `Ctrl+Shift+P` → "Preferences: Open Keyboard Shortcuts (JSON)"
3. Add this object into the `keybindings.json` array (comma-separated with whatever's already there — don't replace the whole file):

```json
{
  "key": "shift+enter",
  "command": "workbench.action.terminal.sendSequence",
  "args": { "text": "\r" },
  "when": "terminalFocus"
}
```

4. Save, then reload the window (or just open a fresh terminal tab)

Do **not** touch or rebind `ctrl+j` — that's a separate, unrelated VS Code default (`workbench.action.togglePanel`) and should be left alone.

## Verify

Open the VS Code integrated terminal, launch `claude`, and press Shift+Enter in the chat input — it should insert a newline instead of submitting.
