# Teams for Linux — Account Locked on First Sign-In

## Overview

After installing `teams-for-linux` via `scripts/install-teams-for-linux.sh`, signing in can fail with "Your account is temporarily locked to prevent unauthorized use." This is not a bug in the client, not caused by the install script, and not a Debian/Linux-specific issue — it's Microsoft Entra ID's (formerly Azure AD) Smart Lockout feature, enforced entirely server-side against the account, independent of which device or client is used to sign in. It typically follows repeated failed sign-in attempts and clears itself after a short cooldown that lengthens with repeated failures. This note exists so a locked-out sign-in right after a fresh install doesn't get mistaken for an installer problem worth debugging.

## Table of Contents

- [Overview](#overview)
- [What causes it](#what-causes-it)
- [What to do](#what-to-do)

## What causes it

- Entra ID's Smart Lockout counts failed password attempts within a rolling window and temporarily blocks sign-in once a threshold is hit.
- It's account/tenant-level, not device-level — the same lockout would show up signing into Outlook, SharePoint, or Teams on Windows/macOS/web with that account.
- The exact threshold and lockout duration are configurable per-tenant by the org's admin, but the message text itself is Microsoft's unbranded default, not something the org writes.

## What to do

- Wait it out — initial lockouts are usually on the order of a minute, increasing with repeated failed attempts.
- If it persists well past that, it's likely a Conditional Access block or an admin-disabled account rather than Smart Lockout — that requires contacting the org's IT/admin, since only they have visibility into it from the Entra ID side.
- No client-side fix applies here; reinstalling or reconfiguring `teams-for-linux` won't change anything, since authentication happens against Microsoft's identity platform, not the local app.
