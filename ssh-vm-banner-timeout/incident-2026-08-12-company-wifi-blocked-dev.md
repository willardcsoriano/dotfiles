# Incident: Company Wi-Fi Selectively Blocked All TCP to `dev` (2026-08-12)

## Overview

On 2026-08-12, VS Code Remote-SSH against `dev` failed even after running `fix-ssh --vscode dev` — a first for that command, since it had reliably fixed every prior connectivity incident. This time the root cause was outside `dev` entirely: a company Wi-Fi network was silently dropping most TCP connections specifically to `dev`'s IP (`178.104.35.30`, a Hetzner VPS), on every port tested, while leaving ICMP and connections to other hosts (GitHub) fully intact. `dev` itself stayed healthy throughout — confirmed out-of-band via `hcloud server metrics` without needing SSH at all. Switching to a mobile hotspot resolved it immediately. Along the way, diagnosis also surfaced a real, separate bug in `fix-ssh --vscode`'s remote kill command — a `pkill -f` self-match that can silently kill its own invoking shell mid-script — which is documented here but not yet patched.

## Table of Contents

- [Overview](#overview)
- [What happened](#what-happened)
- [Diagnosis: two symptoms, two different causes](#diagnosis-two-symptoms-two-different-causes)
- [Root cause: company Wi-Fi egress filtering, not `dev`](#root-cause-company-wi-fi-egress-filtering-not-dev)
- [Related finding, not yet fixed: `fix-ssh --vscode` can self-kill mid-script](#related-finding-not-yet-fixed-fix-ssh---vscode-can-self-kill-mid-script)
- [Fix](#fix)
- [Open items](#open-items)

## What happened

VS Code Remote-SSH against `dev` stopped connecting. Terminal SSH still worked initially. `fix-ssh --vscode dev` was run to clear a suspected stuck session — same remedy that had resolved the two prior VS Code incidents — but the problem persisted afterward, which hadn't happened before.

## Diagnosis: two symptoms, two different causes

**First symptom — a genuinely new failure shape:** the newest `Remote - SSH` log showed the connection succeeding, then hanging forever on `"Waiting for subshell to start"` — the shared `ptyHost` process wedged on spawning a *new* terminal, while existing terminal shells from hours earlier kept working. This is the same family as the 2026-08-05 incident (a long-lived shared process wedging on new work while continuing to serve old work) but in a different subsystem (`ptyHost` vs. the agent host's connection handshake).

Running `fix-ssh --vscode dev` directly and verifying via `pgrep` confirmed the kill actually worked this time (12 matching processes → 0). But the very next VS Code reconnect attempt failed differently: `ssh: connect to host 178.104.35.30 port 22: Connection timed out` — a real TCP-level failure, not an application hang.

**Second symptom — this is where it stopped being a `dev`-side problem.** Repeated plain `ssh dev` attempts failed intermittently (roughly 1-in-5 to 1-in-3, not consistently). Ruling out each layer in order:

- `ping -c 20` to `178.104.35.30`: **0% loss**, clean ~200ms RTT — ICMP was never the problem.
- `hcloud server metrics dev --type cpu` (out-of-band, no SSH needed): only two brief CPU spikes in the prior 15 minutes, both already back to baseline (~7-11%) — the VM itself was not overloaded.
- 10x raw TCP connects to `dev:22`: mostly failed (as few as 1/10 succeeding in one burst).
- 8x raw TCP connects to `dev:443` (same host, different port): **8/8 failed** — ruled out "SSH specifically is blocked."
- 8x raw TCP connects to `github.com:22` (different host, same port): **8/8 succeeded** — ruled out "port 22 is blocked everywhere" and "this network is just generally lossy."

That combination — every port to this one destination failing, everything else fine, ICMP fine — isolates the problem to something actively filtering traffic *to `dev`'s IP specifically*, upstream of both `dev` and the SSH/VS Code stack entirely.

## Root cause: company Wi-Fi egress filtering, not `dev`

The network in use was a company Wi-Fi (`ip route` showed egress via `wlp3s0` through a `10.128.128.128` gateway — a private/enterprise-style address, not a typical home router range).

Best-fit hypothesis: an egress firewall doing IP-reputation/ASN-based filtering. Hetzner (like most budget VPS providers) is commonly flagged in corporate threat-intel feeds as a "hosting provider/VPS" category, and many firewalls block or heavily throttle that category outbound by default — cheap for IT to apply, invisible to almost everyone since so few employees SSH into a personal VPS. GitHub's ranges are near-universally allowlisted (blocking them breaks everyone's workflow immediately), which explains why `github.com:22` sailed through while `dev` on any port did not. ICMP is frequently left unfiltered even when TCP/UDP to the same destination is blocked, since it carries no meaningful payload. The inconsistent (not 0%, not 100%) failure rate is consistent with connection-tracking/rate-limit churn or a DPI system needing a few packets of context before triggering a drop, rather than a hard first-packet block.

A secondary, unconfirmed possibility: SSH's `-D` dynamic port forwarding (which VS Code Remote-SSH's local proxy relies on) is independently a common DLP red flag, since it's a standard way to tunnel out of a locked-down network — plausible as an additional layer on top of the ASN block, though `dev:443` failing too suggests the ASN-level block is the primary mechanism either way.

## Related finding, not yet fixed: `fix-ssh --vscode` can self-kill mid-script

While re-running the kill to verify it actually took effect, found the likely explanation for two separate "it printed nothing / didn't seem to finish" reports (this incident and one weeks earlier): `scripts/fix-ssh.sh`'s remote command is

```bash
pkill -9 -f "\.vscode-server/"
```

`pkill -f` matches against a process's **full command line**. Because the entire remote script (including this literal pattern text) is passed to the remote shell as a single argument over `ssh`, the invoking shell's own command line contains the substring `.vscode-server/` too — so `pkill -f` can match and kill its own parent shell mid-script, before it ever reaches the `find` cleanup or `echo "Done."` lines. That would produce exactly the observed symptom: real target processes get killed (confirmed working via `pgrep` in both incidents), but the script appears to end silently with no completion output.

The standard fix is the same bracket trick used for self-excluding `ps`/`grep`/`pkill` from its own output: change the pattern to `"[.]vscode-server/"`. This preserves identical matching against real target processes (still requires a literal `.` followed by `vscode-server/`) while breaking the literal substring match against the invoking shell's own argv (which now contains `[.]vscode-server/`, not the contiguous `.vscode-server/`). **Not yet applied** — diagnosis was interrupted to focus on the live network outage.

## Fix

None needed on `dev` or in the tooling — switching off the company Wi-Fi to a mobile hotspot resolved the connection immediately, confirming the network was the actual blocker.

## Open items

- **Patch the `fix-ssh --vscode` self-kill bug** described above (`scripts/fix-ssh.sh`, bracket-trick fix identified, not yet applied).
- **The `ptyHost`-wedge symptom** (new terminals hanging on `"Waiting for subshell to start"` while existing ones keep working) was never independently confirmed fixed on its own — the network issue arrived before that could be verified in isolation. If it recurs with `dev` otherwise healthy and the network ruled out first, treat it as the same family as the 2026-08-05 agent-host wedge and reach for `fix-ssh --vscode dev`.
- **No lasting mitigation exists for the company-Wi-Fi filtering itself** — it's a network policy outside this repo's control. If this network is used regularly, a Tailscale/WireGuard tunnel to `dev` would likely route around it (traffic would look like an overlay-network connection rather than a raw connection to a flagged Hetzner IP), but that's a real architectural change, not something to do reactively mid-incident.
