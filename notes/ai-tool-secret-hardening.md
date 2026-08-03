# Hardening AI Coding Tools Against Accidentally Viewing Secrets

## Overview

While investigating an unrelated VM incident, a routine check of `~/.deepcode/settings.json` (config for the DeepCode CLI) turned up a plaintext API key sitting in a config file. That prompted two things: migrating the key out to a proper env file without ever having its value pass through anything read or printed, and then hardening the three AI coding tools in active use on this machine — Claude Code, Antigravity, and DeepCode — so none of them run a command that would display a secret value going forward, always handing such commands to the user to run themselves instead. The three tools turned out to have meaningfully different permission architectures, so the actual protection level differs per tool; this note records what was done and where each one's real limits are, so the gap isn't mistaken for full coverage.

## Table of Contents

- [Overview](#overview)
- [The DeepCode API key migration (done blind)](#the-deepcode-api-key-migration-done-blind)
- [Per-tool hardening](#per-tool-hardening)
  - [Claude Code — `CLAUDE.md` instruction](#claude-code-claudemd-instruction)
  - [Antigravity — enforced permission rules](#antigravity-enforced-permission-rules)
  - [DeepCode — coarse scope-based permissions only](#deepcode-coarse-scope-based-permissions-only)
- [What "done blind" actually means, if this pattern is reused](#what-done-blind-actually-means-if-this-pattern-is-reused)

## The DeepCode API key migration (done blind)

`~/.deepcode/settings.json`'s `env.API_KEY` field held the key in plaintext. DeepCode's own `docs/configuration.md` confirms a real environment variable (`DEEPCODE_API_KEY`) takes priority over this field, so the fix was: move the value out to a private file, delete it from the tracked-adjacent settings file, and never actually look at the value while doing it.

Executed via shell redirection only — the value flowed directly from one file to another without ever being printed to anything read:

```bash
{
  printf 'export DEEPCODE_API_KEY="%s"\n' "$(jq -r '.env.API_KEY' ~/.deepcode/settings.json)"
} > ~/.config/deepcode/deepcode.env
chmod 600 ~/.config/deepcode/deepcode.env
jq 'del(.env.API_KEY)' ~/.deepcode/settings.json > ~/.deepcode/settings.json.tmp
mv ~/.deepcode/settings.json.tmp ~/.deepcode/settings.json
```

Sourced from `.bashrc`:

```bash
if [ -f ~/.config/deepcode/deepcode.env ]; then
    . ~/.config/deepcode/deepcode.env
fi
```

Verified success using only booleans and lengths — `jq '.env | has("API_KEY")'` (confirmed `false`) and `${#DEEPCODE_API_KEY}` (confirmed `35`, matching the original) — never the actual value. No rotation was needed afterward, since the key was never exposed at any point.

## Per-tool hardening

### Claude Code — `CLAUDE.md` instruction

Extended the existing "Secrets hygiene" section in the global `CLAUDE.md` (lives in the `claude-config` repo, symlinked to `~/.claude/CLAUDE.md`) to cover execution, not just storage: never run a command whose output would display a secret (`cat`/`echo`/`grep` on a credentials file, printing an env var known to hold a key, dumping a config field that stores one) — hand it to the user to run themselves instead. Also documents the blind-migration pattern above as the standard technique when a secret genuinely needs to move between two places.

This is a behavioral instruction, not an enforced mechanism — it depends on the model actually following it, same as every other CLAUDE.md rule.

### Antigravity — enforced permission rules

`~/.gemini/antigravity-cli/settings.json` supports a `permissions.rules` array with regex-matched commands and an `action` (`ask`/`deny`/etc.) — genuinely enforced by the harness itself, not just a followed instruction. Added three rules, all forcing `"ask"`:

- Reading typical secret files: `.env`, `.pem`, `id_rsa`/`id_ed25519`, `credentials.json`, `secrets.*`, `.netrc`, `.npmrc`, `.pgpass`, `msmtprc`.
- Echoing an environment variable whose name looks like a secret (`KEY`/`SECRET`/`TOKEN`/`PASSWORD`).
- `printenv` (dumps everything).

**Caveat:** no runnable `antigravity` binary or version marker was found on this machine to test against live, and the schema found via Context7 docs didn't exactly match what was already in this file. Added non-destructively (new key alongside the existing `allow` list, not replacing anything), but this should get a live spot-check next time Antigravity is actually used.

### DeepCode — coarse scope-based permissions only

DeepCode's `permissions` field (documented in its own `docs/permission.md`) only supports 10 broad scopes (`read-in-cwd`, `read-out-cwd`, `write-in-cwd`, `write-out-cwd`, `delete-in-cwd`, `delete-out-cwd`, `query-git-log`, `mutate-git-log`, `network`, `mcp`) — **no command-pattern or regex matching exists at all.** There is no way to target "commands that would display a secret" specifically.

Set the bluntest available approximation in `~/.deepcode/settings.json`:

```json
"permissions": {
  "ask": ["read-out-cwd", "network"],
  "defaultMode": "allowAll"
}
```

This will prompt for plenty of legitimate reads/network calls that have nothing to do with secrets — accepted as a known tradeoff, not a mistake, since it's the only lever this tool has.

## What "done blind" actually means, if this pattern is reused

The core technique, worth reusing whenever a secret needs to move between two places:

1. Move it with shell redirection (`>`, `>>`, pipes) so the value only ever flows file-to-file or through a subshell — never through a command whose output gets printed/read.
2. Verify success with booleans, lengths, or hashes (`has("KEY")`, `${#VAR}`, `sha256sum`) — never by printing the value itself.
3. If a step genuinely requires seeing the value (there wasn't one here), get explicit, informed consent first, and treat rotation afterward as the default, not optional.
