## Overview

This is a draft LinkedIn post, and chronologically the origin story that precedes the earlier "why my server kept timing out" post and its sequel — those describe problems that only exist because of the setup described here. The story: a laptop with only 8GB of RAM could barely run two code editor windows before grinding to a halt, so development work moved to a small cloud server instead, immediately unlocking five windows running comfortably at once. Framed as the setup/motivation post that kicks off the series about running a personal dev server, written for a general LinkedIn audience — no jargon, no product names, no company/employer references. Copy everything below the divider directly into LinkedIn as-is.

---

## Table of Contents

- [Overview](#overview)
- [Post text (copy everything below this line)](#post-text-copy-everything-below-this-line)

## Post text (copy everything below this line)

My laptop has 8GB of RAM. For months, I just lived with it.

Two code editor windows open at once was the ceiling. A third would slow everything down until I closed one. I told myself this was just how it was — some limitation I'd have to work around forever.

Then I tried something almost embarrassingly obvious: what if the code didn't have to run *on* the laptop at all?

I rented a small, cheap cloud server — the kind that costs less per month than a couple of coffees — and pointed my editor at it instead. The laptop just displays things now; the actual heavy lifting happens somewhere else entirely.

The difference wasn't subtle. Two windows, straining, became five windows, comfortable. Instantly. No upgrade, no new hardware, no compromise — just moving the work to a machine actually built for it.

What got me thinking, though, was how long I'd assumed the constraint was permanent. It wasn't a hardware problem. It was a "where does this actually need to run" problem, and I'd never stopped to ask it.

Of course, moving your dev environment onto a server you're now responsible for comes with its own lessons — some of them expensive ones. That's a story for another post.

Anyone else have a limitation you just accepted for way too long before realizing it wasn't actually broken, just misplaced?
