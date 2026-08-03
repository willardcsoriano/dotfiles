## Overview

This is a draft LinkedIn post, a direct sequel to "the mystery wasn't actually over" — the one where safety nets got built so a flaky-internet reconnect storm couldn't quietly eat all the server's memory again. Days later, it happened again, in exactly the way that fix was supposed to prevent. The twist: the fix had only ever been written down, never actually switched on. The post covers that gap — the difference between documenting a fix and shipping one — plus a smaller, stranger discovery: even the emergency terminal access briefly failed during the most intense moment of cleanup, something the earlier post had assumed was bulletproof. Written for the same general LinkedIn audience — no jargon, no product names, framed around the humbling lesson rather than the implementation. Copy everything below the divider directly into LinkedIn as-is.

---

## Table of Contents

- [Overview](#overview)
- [Post text (copy everything below this line)](#post-text-copy-everything-below-this-line)

## Post text (copy everything below this line)

I thought I'd already fixed this. I hadn't. I'd just written down that I would.

A few days after building safety nets for that reconnect-storm problem I posted about, I hit the exact same wall again. Couldn't connect. Memory maxed out. Same root cause, almost to the letter.

My first thought was: how? I built a scheduled cleanup job specifically so this couldn't happen unattended. I even wrote it up as done.

Except when I actually went and checked the server itself — not my notes, the actual machine — the cleanup job wasn't running. It had never been running. I'd written the script, described exactly how it would work, and then just... never flipped the switch that turns "a script that exists" into "a script that runs." Somewhere between writing it and calling it finished, I'd quietly swapped "I described the fix" for "I shipped the fix," and those are not the same sentence.

That's the actual lesson here, more than any of the technical details: a fix that lives only in a document is not a fix. It's a plan for a fix. Easy to conflate, especially when the writing itself feels like real progress — because it is real progress, just not the last step.

One more small thing I learned while cleaning up the mess: even my "this always works no matter what" emergency access briefly failed too, right in the middle of the busiest moment of cleanup. Not because it's unreliable — because I'd never actually tested it under real pressure, I'd just assumed it. Another quiet gap between "should work" and "verified to work."

Fixed it again. This time I checked the machine itself before calling it done, not just my own notes.

Anyone else caught themselves treating "I wrote it down" as the same thing as "I actually did it"?
