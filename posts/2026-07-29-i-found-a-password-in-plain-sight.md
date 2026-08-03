## Overview

This is a draft LinkedIn post about discovering an API key sitting in plaintext in a personal AI coding tool's config file, and fixing it in a way that avoided ever actually looking at the exposed value. Framed for a general audience around a relatable, satisfying idea: sometimes the safest fix is designing around a risk entirely, rather than just reacting to it. No jargon, no tool names beyond generic references, no company/employer references. Copy everything below the divider directly into LinkedIn as-is.

---

## Table of Contents

- [Overview](#overview)
- [Post text (copy everything below this line)](#post-text-copy-everything-below-this-line)

## Post text (copy everything below this line)

I found one of my own passwords sitting in plain text. Here's the fix I'm actually proud of.

I was poking around one of my dev tools' settings for an unrelated reason, and noticed something I really shouldn't have: an API key, sitting in a config file, completely unencrypted. Not a big leak — nobody else had access to that file — but exactly the kind of small oversight that turns into a real problem the moment that file ends up somewhere it shouldn't.

The obvious fix is simple: move it somewhere safer. But there's a subtlety most people skip. If I'm the one who has to look at that key to move it, I've now seen it. It's in my screen history, maybe in a log somewhere, maybe in my own memory of glancing at it. The "fix" still involves exposure.

So I did it a different way: I moved the key from one file to another using a method where the actual value never got displayed to me at any point. It flowed directly from the old location to the new one, like water through a pipe I never opened to look inside. Afterward, I could confirm it worked using only indirect checks — "is a key present, yes or no" and "is it the same length as before" — never the value itself.

End result: the key is now stored properly, and I still don't actually know what it is. Which is exactly the point.

I think this is a genuinely underrated way to think about security in general — not just "handle secrets carefully" but "design the process so you're never actually holding the secret in the first place." The safest secret isn't the one you protect really well. It's the one you never had to see.

Anyone else have a moment where fixing something the "safe way" ended up being the more interesting problem than the fix itself?
