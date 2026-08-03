# Microsoft Teams Web — Camera and Colleagues' Video/Screen-Share Blank in Firefox

## Overview

On this Debian XFCE MacBook, Microsoft Teams in the browser (`teams.microsoft.com`) can join a call with no pre-join lobby at all and render neither your own camera nor any colleague's camera or screen share — while Zoom, Viber, and the `facetimehd` webcam driver all work fine on the same machine at the same time. This is not a driver, permission, or work-account/tenant-policy problem: the driver, the OpenH264 codec, and site permissions were all confirmed healthy during this investigation, and the failure is specific to Firefox as a browser. The cause is Microsoft's classic Teams web client doing browser sniffing that only fully enables WebRTC media for Chromium-based browsers (tracked upstream as Mozilla bug 1623340) — Firefox gets treated as unsupported for media even though Microsoft's newer Teams client officially added Firefox support. The sustainable fix is running Teams in a Chromium-based browser instead of patching Firefox. This is a different root cause from [`teams-for-linux-camera-not-working.md`](teams-for-linux-camera-not-working.md), which covers a separate, Electron-app-specific problem in the `teams-for-linux` desktop client — that note doesn't apply here, and this one doesn't apply there.

## Table of Contents

- [Overview](#overview)
- [What was ruled out](#what-was-ruled-out)
- [Root cause](#root-cause)
- [Fix 1 — use a Chromium-based browser (recommended, sustainable)](#fix-1-use-a-chromium-based-browser-recommended-sustainable)
- [Fix 2 — Firefox user-agent override (temporary, not sustainable)](#fix-2-firefox-user-agent-override-temporary-not-sustainable)
- [Fix 3 — Debian Chromium doesn't auto-enable Google's staged feature rollouts (e.g. vertical tabs)](#fix-3-debian-chromium-doesnt-auto-enable-googles-staged-feature-rollouts-eg-vertical-tabs)
- [What's still open](#whats-still-open)

## What was ruled out

- **`facetimehd` driver** — module loaded, matches running kernel, camera works fine in Zoom and Viber at the same time the Teams call was broken. Not a driver issue.
- **OpenH264 codec** — the GMP plugin was present in the Firefox profile (`gmp-gmpopenh264`, version 2.6.0, matching hash, no download failures), so Firefox had a working H.264 encoder/decoder available. Not a missing-codec issue.
- **Browser-level camera permission** — not blocked; and a permission block wouldn't explain colleagues' video/screen-share also failing to render, since that's inbound data, not something a local camera permission affects.
- **`privacy.resistFingerprinting` or enterprise policy** — no matching prefs in `prefs.js`/`user.js`, no `policies.json` present anywhere on the system.
- **Work account / Entra ID / tenant policy** — ruled out because the symptom (blank video in *both* directions — your camera and everyone else's) matches a known, generic Firefox compatibility bug that isn't tenant-specific, not something that plausibly requires an org-side meeting policy to explain.

## Root cause

Microsoft's classic Teams web client browser-sniffs and has historically only fully enabled camera/screen-share WebRTC media for Chromium-based browsers. This is tracked as [Mozilla bug 1623340](https://bugzilla.mozilla.org/show_bug.cgi?id=1623340) ("Microsoft Teams: video not supported in Firefox") — closed `WORKSFORME` after Microsoft's newer `teams.microsoft.com/v2/` client added official Firefox video/voice support, but whichever client version or rollout stage this tenant is on is still hitting the old gate. Multiple people confirmed video/screen-share resumed immediately after spoofing Firefox's user-agent to look like Chrome, which is strong evidence for the sniffing theory over an actual codec/negotiation failure. Separately, the legacy personal service `teams.live.com` remains unsupported in Firefox entirely (tracked as a distinct bug, 1904972) — worth knowing if this ever needs re-diagnosing on a personal Microsoft account instead of a work one.

## Fix 1 — use a Chromium-based browser (recommended, sustainable)

`chromium` was already installed on this machine (Debian package, no separate download needed). Open Teams there instead of Firefox:

```sh
chromium https://teams.microsoft.com
```

This is the officially tested and supported combination, so there's nothing to patch or maintain going forward.

**Status: recommended and used during this session — end-to-end confirmation (own camera renders, colleagues' video/screen-share render) is still pending.** Verify on the next real call.

If consolidating to a single daily browser matters, **Microsoft Edge is a stronger candidate than plain Chromium** for that specific goal: same Chromium engine (so Teams works natively), and unlike Chromium it has had native vertical tabs for years without needing the workaround in [Fix 3](#fix-3---debian-chromium-doesnt-auto-enable-googles-staged-feature-rollouts-eg-vertical-tabs) below. That said, the recommendation from this investigation was **not** to abandon Firefox as the daily driver — Firefox already has native vertical tabs (since 2024) and gives engine diversity away from the Chromium/Google monoculture. The conclusion was "use Chromium (or Edge) for Teams specifically," not "switch browsers entirely" — that's a bigger, separate decision this note doesn't make.

## Fix 2 — Firefox user-agent override (temporary, not sustainable)

If you're already mid-call and can't switch browsers, override Firefox's user-agent to identify as Chrome for that session only:

1. `about:config` → search `general.useragent.override` → create it as a **String** preference (it won't exist by default).
2. Set its value to: `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36`
3. Fully close the Teams tab and open a fresh one, rejoin the call.
4. Afterward, go back to `about:config` and **Reset** (or delete) `general.useragent.override` — it's global and affects every site Firefox visits while set, not just Teams, so it shouldn't be left in place.

**Status: unconfirmed whether this actually fixed the live call** — the session moved on to testing Chromium before this was verified end-to-end. Treat as an unverified workaround if this is revisited; Fix 1 is the one actually validated by upstream reports.

## Fix 3 — Debian Chromium doesn't auto-enable Google's staged feature rollouts (e.g. vertical tabs)

Discovered as a side effect of testing Chromium for Teams: Chrome's native vertical tabs (stable since Chrome 146, fully rolled out April 2026) don't appear even though the installed Chromium here is version 150.0.7871.124 — well past that. Reason: Google ships staged UI rollouts via a server-side "Finch" experiment system that only targets officially Google-branded Chrome builds. Debian's `chromium` package is deliberately unbranded, so it has the feature's code compiled in but never receives the remote signal that turns it on by default — even at a matching version number.

Fix: force it manually.

1. `chrome://flags/#vertical-tabs` → set to **Enabled** → relaunch when prompted.
2. Enabling the flag only unlocks the feature, it doesn't switch the layout — explicitly turn it on afterward via right-click on the tab strip → **"Show tabs vertically"**, or `chrome://settings/appearance` → **Tab position** → **Vertical**.

**Status: flag enabled and relaunched; step 2 (explicit toggle) not yet confirmed working** — tabs were still horizontal after the flag+relaunch alone, which is expected since step 2 wasn't done yet. Revisit if `chrome://settings/appearance`'s Tab position dropdown doesn't do it either.

## What's still open

- [ ] Confirm Teams camera **and** colleagues' video/screen-share actually render end-to-end in Chromium on a real call.
- [ ] Confirm vertical tabs actually engage after the explicit right-click/Settings toggle (Fix 3, step 2).
- [ ] Chromium is one patch behind the security channel (150.0.7871.124 installed vs. 150.0.7871.181 available) — apply with `sudo apt-get update && sudo apt-get install --only-upgrade chromium`, not yet run.
- [ ] Open decision, not yet made: consolidate to Edge as a single daily browser, or keep Firefox (daily) + Chromium (Teams-only) split.
