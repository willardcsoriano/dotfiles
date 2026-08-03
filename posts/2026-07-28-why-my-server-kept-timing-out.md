## Overview

This is a draft LinkedIn post telling the non-technical version of the 2026-07-28 server incident documented in `ssh-vm-banner-timeout/` (this repo) and `docs/learnings/03-php-fpm-worker-lifetime-and-memory-limits.md` (the wfmctrading repo). The story: a server kept failing to connect with what looked like a network error, but the real cause was a background process that had been running non-stop for over two days, slowly using more memory until it crashed the whole machine. Written for a general LinkedIn audience — no jargon, no product/domain names, framed around the relatable lesson rather than the technical mechanism. Copy everything below the divider directly into LinkedIn as-is.

---

## Table of Contents

- [Overview](#overview)
- [Post text (copy everything below this line)](#post-text-copy-everything-below-this-line)

## Post text (copy everything below this line)

My server kept "timing out" — it took two tries to figure out why.

Some context: I run a small cloud server for my own development work. My laptop only has 8GB of RAM, which isn't enough to comfortably run more than two or three code editor windows at once — so I lean on a beefier remote machine to actually get things done. It's just me using it, nobody else.

For a few days, I couldn't reliably connect to it. Every attempt gave me the same frustrating message: connection timed out. My first instinct was to blame the network — bad wifi, a flaky connection, maybe my internet provider having a bad day.

I was wrong. The internet was fine. My laptop was fine. The real problem was hiding two layers deeper, inside the server itself.

Here's what was actually happening: one small piece of software — a background worker that handles requests for an app I'm building — had been running non-stop for over 50 hours straight without ever taking a break. Over those two days, it slowly picked up more and more memory, kind of like a browser tab you never close that gets heavier the longer it stays open. Eventually it got so heavy the server ran out of memory entirely, and in trying to recover, it crashed the very system that lets anything connect to it in the first place. That's why it looked like a connection problem — the server was too overwhelmed to even say hello.

The fix itself turned out to be refreshingly simple. It came down to two small settings:

1. Give that background worker a scheduled break — retire it periodically instead of letting it run forever.
2. Put a ceiling on how much memory any single piece of software is allowed to use, so one greedy process can never take the whole server down with it.

Nobody writes a case study titled "we set a memory limit" — but getting there was genuinely one of the more exciting, educational debugging sessions I've had in a while. This is honestly most of what keeps real systems reliable — not clever code, just sensible boundaries that stop small problems from becoming big ones.

The lesson that stuck with me: when something's been running for a long time without incident, that's not proof it's healthy. Sometimes it's just proof nobody's checked on it yet.

Anyone else have a story where the fix turned out to be dead simple, but getting there taught you way more than you expected?
