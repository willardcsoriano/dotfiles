## Overview

This is a draft LinkedIn post, a direct sequel to the earlier "why my server kept timing out" post. After fixing the immediate cause, digging into the server's historical memory data turned up something more interesting: the same near-crash had actually happened twice before without ever tipping over, and a flaky home internet connection may have been the missing variable both times. The post covers that discovery and the shift from "fix the one thing" to "build a system that protects itself even when I'm not watching." Written for the same general LinkedIn audience — no jargon, framed around the twist and the lesson, not the implementation. Copy everything below the divider directly into LinkedIn as-is.

---

## Table of Contents

- [Overview](#overview)
- [Post text (copy everything below this line)](#post-text-copy-everything-below-this-line)

## Post text (copy everything below this line)

Remember that server mystery I posted about? I thought it was solved. It wasn't quite.

After fixing the immediate cause, I did something I should have done from the start: I pulled up the server's own historical health data instead of just looking at the moment it crashed.

What I found surprised me. The exact same near-crash — memory climbing dangerously close to the edge — had actually happened twice before in the days leading up to it. Both times, it came back down on its own. No crash, no warning, nothing. I never knew, because nothing was watching for it.

So the real question wasn't "why did it crash this time." It was "why didn't it crash the two times before, and what was different this time."

Digging through the connection logs from right before the crash, I found something: my internet had been dropping in and out around that exact moment. Not a huge outage, just the kind of flaky blip you barely notice. But it turns out that when a connection drops badly instead of closing cleanly, some of my dev tools try to reconnect by spinning up a whole new session instead of resuming the old one — and if that happens a few times in a row during a bad patch of internet, it adds a sudden burst of extra load right when the server had the least room to absorb it.

That was probably the final push that made this particular near-miss different from the two before it.

Here's the part I actually want to talk about, though. Once I understood that, the goal changed. Instead of just fixing what happened, I built a few small safety nets so the server can catch and correct problems on its own, without me needing to notice anything:

- A limit that stops a crashing process from endlessly restarting and grinding the whole machine to a halt.
- A hard ceiling on how much memory certain background processes are allowed to use, so nothing can silently eat the whole machine.
- Cleaner reconnect behavior on my end, so a bad connection doesn't pile up extra sessions in the first place.

None of this guarantees it'll never happen again. But it means that if something does go wrong, the system has a much better chance of catching itself — instead of me finding out the hard way, again.

The lesson I keep relearning: the first fix usually isn't the whole story. The data almost always has more to say than the incident report does, if you actually go look at it.
