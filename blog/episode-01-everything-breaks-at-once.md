# Everything Breaks At Once

## Overview

This is the story of one afternoon where closing a laptop lid triggered four unrelated failures that all looked, from the outside, like a single outage. A wifi mesh network went into a roaming storm. A Bluetooth tether fix attempt failed before it even started. Underneath both of those, a stale SSH connection was quietly lying about being alive. And underneath *that*, a remote dev box was choking on a memory leak that had already been "fixed" twice before, except it hadn't — it had only ever been written down as fixed. Each layer looked like the whole problem until it was cleared, at which point the next one was waiting. This is what it actually looks like to debug a day like that: wrong guesses, real progress disguised as failure, and a lesson about the gap between documenting a fix and shipping one.

## Table of Contents

- [Overview](#overview)
- [Act One: The Network That Couldn't Decide](#act-one-the-network-that-couldnt-decide)
- [Act Two: The Connection That Was Lying](#act-two-the-connection-that-was-lying)
- [Act Three: The Monster That Was Already There](#act-three-the-monster-that-was-already-there)
- [The Real Lesson](#the-real-lesson)

## Act One: The Network That Couldn't Decide

It started with the most boring possible trigger: closing a laptop lid at home, and reopening it somewhere else, on a different network.

Wifi didn't just fail to reconnect — it reconnected constantly, to the wrong thing, over and over. The laptop sat on a mesh network with several access points broadcasting the same network name, and for about six minutes it bounced between at least four of them, every 30 to 90 seconds, dropping the connection for a few seconds on every hop. One of those hops even got rejected outright by the security handshake — one mesh node's beacon didn't quite match what it sent during the handshake, so the client correctly refused and tried again a moment later. Not an attack. Just two radios in the same mesh disagreeing with each other about who they were.

Frustrated, the obvious next move was to skip wifi entirely and tether to a phone instead. That failed too, immediately, with a flat "I/O error" before the tether connection ever came up. So now it looked like *two* networking problems at once: a flaky wifi mesh, and a broken Bluetooth tether as backup.

Then, almost by accident, wifi just... settled. It picked one access point and stayed there. The tether had never been the fix — it had never worked at all. Wifi fixed itself by finally landing on a stable node, a few seconds after the failed tether attempt, for reasons that had nothing to do with anything that had just been tried.

A reboot followed anyway, the classic instinct when nothing else seems to be working. It turned out to be completely unnecessary — wifi was already stable by the time it happened. The reboot didn't fix anything; it just happened to land after the real fix, which was the mesh finally settling on its own.

## Act Two: The Connection That Was Lying

Wifi being stable should have ended the story. It didn't. A terminal SSH session to the dev box hung. The editor's own remote connection hung too. Not an error — just silence, forever.

The network was fine. DNS resolved. Everything about the new connection was healthy. So why would a brand new SSH attempt just sit there?

It wasn't a new attempt. It was reusing an old one.

SSH has a feature called connection multiplexing: the first connection to a host opens a background "control" process, and every subsequent connection quietly reuses it instead of doing a full handshake again. It's a nice performance trick almost all the time. The control process from *before the lid closed* was still sitting there, and asking it directly — "are you still alive?" — got back a cheerful "yes."

That answer was true and completely useless. The check only confirms the local control process itself is running, not that whatever it's connected to still works. And the thing meant to catch a dead connection — a periodic "are you still there?" ping built into SSH — can't fire if the process sending it is frozen, which is exactly what happens during suspend. The control process went to sleep believing the connection was healthy, and woke up still believing it, because nothing ever had the chance to tell it otherwise. The actual connection had been dead for as long as the lid was closed; the control process just had no way to know.

Every real request routed through that zombie hung waiting for a reply that could never arrive, instead of failing fast and trying again.

The fix, once understood, was almost insultingly simple: force every local SSH control socket to exit the moment the machine wakes up, unconditionally, no diagnosis required. Not "check if it's actually dead" — just assume it might be and clear it anyway, every single time. The next real connection then gets a fresh, honest handshake instead of inheriting a zombie's optimism. Wired up as a hook that fires automatically on every resume, so it would never need to be done by hand again.

## Act Three: The Monster That Was Already There

With the zombie cleared, a fresh connection finally went through — and immediately hit a different wall. The remote side spawned successfully, logged that it had started, and then just sat there. Waiting. Indefinitely.

Something was wrong on the *other end* now, independent of anything that had just been fixed.

Every basic check against the dev box stalled or timed out. Disk usage, memory, process list — all of it hung instead of returning. Whatever this was, it was bad enough that the box could barely respond to anything.

There was an obvious guess available: this had happened before, and the fix that time was a full VM reboot. But jumping to that same conclusion without checking would have been exactly the kind of lazy pattern-matching this whole day was built to punish. So instead, five separate signals got compared side by side against the two known culprits — and they didn't match the reboot-requiring one at all. The actual service that caused trouble last time was completely stable, zero restarts, the whole time. What matched instead was a different, previously-diagnosed mechanism: a memory leak from editor sessions that never got cleaned up properly after a bad disconnect, piling up quietly until the box drowned in its own swap.

This mechanism had a known fix that didn't require touching the VM at all — a targeted command that kills only the leaked processes. It had also, embarrassingly, already been "fixed" twice before. Written down, even. And yet a timer check confirmed, for the third time, that the actual automated cleanup had never been installed on the box at all. Only ever described as installed.

The fix ran three times before it fully succeeded — not because it was failing, but because the box was under so much memory pressure that the SSH session carrying the command kept getting dropped mid-execution, twice, before completing cleanly the third time. Checking memory usage directly after each attempt (rather than trusting whether the command's connection survived) showed real progress had happened both times anyway — it just hadn't finished. No reboot. No VM-level recovery. Just three patient attempts and a lot of swap slowly draining back to normal.

## The Real Lesson

The fix that mattered most that day wasn't any of the three individual repairs. It was noticing that "fixed" and "deployed" are not the same claim, and that the gap between them had already quietly swallowed the same fix twice.

The pattern both times: the right commands got written down, handed over, and the status got marked "done" the moment the handoff happened — not after anyone actually checked the live system. Intent got mistaken for completion, twice, two weeks apart, with nothing in between ever verifying otherwise.

So alongside fixing the actual leak a third time, a new habit got built instead of just a new patch: a single command that checks every supposedly-live fix directly against the real system and prints exactly what's missing, instead of trusting a status line in a document ever again.

And one more thing turned up almost by accident while building the fix for the SSH zombie: an entirely unrelated hook, written weeks earlier for a different problem, had a logic bug that meant it had never once actually run — not once, the whole time it was believed to be working. Nobody was looking for it. It just happened to be sitting right next to the code being read for something else entirely, waiting to be noticed.

Four problems, one afternoon, and the real takeaway had nothing to do with wifi, SSH, or memory at all: if nobody checks, "fixed" quietly turns into a guess.
