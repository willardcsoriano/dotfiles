## Overview

This is a draft LinkedIn post about a webcam that worked perfectly in Zoom but refused to connect specifically during Microsoft Teams calls, on a 10-year-old repurposed MacBook running Linux. Framed as a relatable troubleshooting mystery with a satisfying, simple-sounding resolution, written for a general audience with the technical specifics translated into plain language. No company/employer references. Copy everything below the divider directly into LinkedIn as-is.

---

## Table of Contents

- [Overview](#overview)
- [Post text (copy everything below this line)](#post-text-copy-everything-below-this-line)

## Post text (copy everything below this line)

My camera worked perfectly on Zoom. It worked in every other app I tried. It just would not connect on Microsoft Teams. Here's what was actually going on.

Quick bit of context: I'm running a 10-year-old MacBook on Linux instead of macOS, because Apple stopped supporting it and the old operating system was eating most of the machine's memory just sitting there doing nothing. Linux runs great on it — but the trade-off is that some of the original Apple hardware needs community-built drivers to work at all, since Apple never officially supported this combination.

So naturally, when my camera stopped working right as I needed it for a work call, my first assumption was "of course, it's the weird hardware, it's finally broken."

Except it wasn't. I tested it in a completely different video call app: worked instantly, crystal clear. Tested it in a simple built-in camera viewer: also worked fine. So the hardware was fine. The driver was fine. Something very specific to Microsoft Teams was the problem.

Here's what was actually happening: when a video call starts, the app asks the camera for footage at a very specific resolution and frame rate. Most modern webcams can flexibly adjust to whatever's requested. This particular driver, being a community-made workaround for hardware Apple never opened up publicly, only supports a small, fixed set of resolutions. Teams was asking for something slightly outside that set. Every other app I tried happened to ask for something the camera could actually provide. Teams didn't, and just silently failed instead of falling back gracefully.

The fix, once I knew that, was almost anticlimactic: one line of configuration telling Teams "don't request a specific resolution, just take whatever the camera gives you."

What stuck with me: for a while I was debugging the wrong layer entirely. I assumed hardware problem, when it was actually a very specific negotiation mismatch between two pieces of software that mostly agree with each other, except in one detail. The fastest thing that actually moved the investigation forward wasn't more digging — it was testing the same hardware through a second app entirely, which instantly proved the hardware itself was innocent.

Sometimes the fastest way to find where a bug actually lives is to change one variable and see what still breaks.
