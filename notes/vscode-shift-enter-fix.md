# VS Code Shift+Enter Newline Fix (Integrated Terminal)

## Overview

By default, VS Code's integrated terminal treats Shift+Enter the same as plain Enter when a shell has focus, so there's no built-in way to type a multi-line command without submitting each line. The fix is a single user keybinding that intercepts Shift+Enter and sends the raw byte sequence `ESC` + `CR` (`\u001b\r`) to the terminal instead of a plain carriage return. Bash's default readline (emacs) keymap interprets `ESC` immediately followed by `Enter` as `Alt+Enter`, which is bound to `insert-newline` — inserting a literal newline into the current line buffer without executing it. This note also documents the failed intermediate attempts, because the failure modes (control-character validation errors, silent no-op edits, double-escaped backslashes) are easy to reproduce by accident and worth recognizing quickly next time.

## Table of Contents

- [Overview](#overview)
- [Working fix](#working-fix)
- [How it was found](#how-it-was-found)
- [Failed attempts (in order)](#failed-attempts-in-order)
  - [1. Referenced note didn't exist](#1-referenced-note-didnt-exist)
  - [2. Plain `\r` instead of `\u001b\r`](#2-plain-r-instead-of-r)
  - [3. No-op `Edit` calls](#3-no-op-edit-calls)
  - [4. `\u001b\r` decoded into a raw control byte, tripping a safety check](#4-r-decoded-into-a-raw-control-byte-tripping-a-safety-check)
  - [5. Double-escaping produced literal double backslashes](#5-double-escaping-produced-literal-double-backslashes)
  - [6. Fix: build the backslash programmatically, sidestep the ambiguity entirely](#6-fix-build-the-backslash-programmatically-sidestep-the-ambiguity-entirely)
- [Verification](#verification)
- [Caveats](#caveats)

## Working fix

`~/.config/Code/User/keybindings.json`:

```json
[
    {
        "key": "shift+enter",
        "command": "workbench.action.terminal.sendSequence",
        "args": {
            "text": "\u001b\r"
        },
        "when": "terminalFocus"
    }
]
```

- `"text"` is the literal 8-character JSON escape sequence `\u001b\r` — i.e. the two characters `\`, `u`, `0`, `0`, `1`, `b` followed by `\`, `r` — **not** a raw control byte typed directly into the file. VS Code's JSON parser decodes this at load time into actual bytes `0x1B` (ESC) followed by `0x0D` (CR).
- `"when": "terminalFocus"` scopes the rebind to the terminal only, so it doesn't affect Shift+Enter in the editor or elsewhere.
- No other keybindings (including Ctrl+J) were added, removed, or modified — the file did not exist before this fix, so this entry is the only content.
- Requires a VS Code window reload (or restart) to take effect after editing.

## How it was found

The binding wasn't invented fresh — it was recovered from `~/.config/Code.bak/User/keybindings.json`, a leftover backup of a previous VS Code profile (predating some profile reset). That backup had the identical binding, confirming it was a previously-working configuration that had simply been lost — the live `~/.config/Code/User/keybindings.json` didn't exist at all when this investigation started.

## Failed attempts (in order)

These are recorded because each one is a plausible-looking dead end.

### 1. Referenced note didn't exist

The initial ask was to read and follow `notes/vscode-shift-enter-fix.md` in this repo. It didn't exist — this repo's `notes/` directory didn't exist at all, and no file with "shift-enter" in the name existed anywhere on the machine (checked via filesystem-wide `find`, `git log --all` in this repo, and a scan of every other repo under `~/projects`). Root cause was never established (never written, or written somewhere never committed/synced); the practical fix was to diagnose and solve the underlying VS Code problem directly, then write this note retroactively.

### 2. Plain `\r` instead of `\u001b\r`

First working file written was:

```json
"text": "\r"
```

Result: Shift+Enter behaved exactly like plain Enter — it submitted the command instead of inserting a newline.

**Why it failed:** `\r` (carriage return) is *exactly* the byte a normal Enter key sends to a terminal. Swapping in `\r` alone doesn't create a "soft newline" — from the shell's point of view it's indistinguishable from pressing Enter normally, because it is the same byte. The `ESC` prefix is what changes the shell's interpretation (via readline's Meta-Enter binding); without it, `\r` is just Enter.

### 3. No-op `Edit` calls

After identifying that `\u001b\r` was needed, two `Edit` tool calls were made to change the text field — but both specified the same string for `old_string` and `new_string` (a copy-paste mistake), so neither actually modified the file. The second `Edit` call additionally failed outright with "String to replace not found," because by that point the file content didn't textually match what was assumed (see next item).

### 4. `\u001b\r` decoded into a raw control byte, tripping a safety check

An attempt to rewrite the file via a `cat <<'EOF' ... EOF` heredoc, typing `\u001b\r` directly in the command text, was rejected outright:

```
InputValidationError: command contains control characters that would be hidden in
the approval dialog
```

**Why it failed:** the tool-call pipeline decoded the `\u001b` JSON-style escape into an actual raw ESC (`0x1B`) control byte before the shell command was even constructed. A safety classifier then correctly refused to run a command containing a hidden/invisible control character, since that could obscure what the command actually does from a human reviewing the approval dialog.

A `Read` of the file at one point *did* show a raw ESC byte followed by literal `\r` text (i.e. `ESC` + `\` + `r`, three characters) sitting in the JSON — a broken hybrid of "decoded ESC" and "not-decoded backslash-r" — confirming the decoding was happening inconsistently depending on how the escape was typed.

### 5. Double-escaping produced literal double backslashes

Next attempt escaped the backslash (`\\u001b\\r`) to try to prevent the decoder from touching it. This avoided the control-character rejection, but produced a file containing the literal 10 characters `\\u001b\\r` (two backslashes in front of both `u001b` and `r`), confirmed via `od -c`. That's invalid — VS Code would read `\\` as an escaped literal backslash character followed by plain text `u001b`, not the intended ESC control code.

**Why it failed:** the escaping behavior of the tool-call parameter pipeline is not consistently "one level of JSON decoding" — the same visual escape sequence can decode differently between calls depending on how it's expressed, making direct hand-typed backslash sequences in tool-call text unreliable for producing exact control-character-adjacent output.

### 6. Fix: build the backslash programmatically, sidestep the ambiguity entirely

The reliable approach was to stop typing backslashes into any tool-call parameter at all. A short Python script (passed to `python3` via a quoted heredoc, so bash performed zero substitution) constructed the target string using `chr(92)` (the backslash character) concatenated with the literal text `u001b` and `r`, then wrote the file directly:

```python
bs = chr(92)
text_value = bs + "u001b" + bs + "r"
```

Because the command text sent to the tool never contained a literal backslash or control character — only the printable digits `92`, and plain letters — there was nothing for any escape-decoding layer to misinterpret. The resulting file was verified byte-for-byte against the known-good backup with `od -c`, and further verified by loading it with Python's `json` module and confirming `data[0]["args"]["text"] == "\x1b\r"` (i.e., decodes to actual ESC + CR at parse time, the same as VS Code's own JSON parser would produce).

## Verification

```sh
# Confirm exact bytes match the escape-sequence form (not raw control bytes):
od -c ~/.config/Code/User/keybindings.json

# Confirm it parses as valid JSON and decodes to ESC (0x1b) + CR (0x0d):
python3 -c "
import json
data = json.load(open('$HOME/.config/Code/User/keybindings.json'))
print(repr(data[0]['args']['text']))
"
# Expected: '\x1b\r'
```

Functional test: reload the VS Code window, focus an integrated terminal running bash, press Shift+Enter. Expected: the terminal drops to a new line without executing whatever was typed so far.

## Caveats

- This relies on bash's **default emacs-mode readline keymap**, where `Alt+Enter` (equivalently, `ESC` then `Enter`) is bound to `insert-newline`. If the shell's readline keymap has been changed (e.g. `set -o vi` in bash, or a customized `.inputrc`), this binding may not exist and Shift+Enter could do something else or nothing.
- Other shells (zsh, fish) are not guaranteed to have the same default binding for `ESC`+`Enter`. Zsh's default `emacs`-based bindkey table generally behaves the same way, but this hasn't been verified here. Fish does not use readline and may need a different sequence or a fish-specific binding.
- This is a per-machine VS Code user setting (`~/.config/Code/User/keybindings.json`), not something synced by this dotfiles repo's `install.sh`. If dotfiles-managed sync of VS Code settings is ever added, this file should be included.
