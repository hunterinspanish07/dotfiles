---
name: wait-for-background-work
description: "TRIGGER, asked of THIS COMMAND — never of the session. Read BEFORE writing any shell command whose job is to wait on work the harness already tracks: a bare `sleep`, an `until`/`while` loop, `for i in $(seq 1 N)`, or a `cat`/`tail`/`grep` against a file a backgrounded Bash call or Agent writes (`tasks/*.output`, a worker's scratchpad, a tee'd log) — and BEFORE telling a worker to print a sentinel (`exit=`, `DONE`, `WAIT:`) so you can grep for it. Also fires on the thought 'I'll just peek at the output file'. EXTERNAL state is exempt — `gh run view`, `gh pr checks`, `curl` health, `railway`/`modal` status — but exempt COMMAND BY COMMAND. Mixed sessions are the normal case and the trap: 'I'm polling the deploy, so this is the external situation' is exactly how `tail -5 …/tasks/bh44yv8f0.output` ran seven times in five minutes on 2026-09-25 with this description already sitting in context. A legitimate poll two commands ago does not launder this one."
---

# Waiting on work you already launched

## One question decides everything

**Did the harness promise to notify you?**

- **Yes** — you launched a Bash call with `run_in_background: true`, or spawned an Agent. The tool
  result said, in those words, *"You will be notified when it completes."* Then waiting is free and
  polling is pure waste. Do nothing. Idle is the correct state.
- **No** — the thing you are watching lives outside this machine's harness: a GitHub Actions run, a
  deploy, a health endpoint, a remote queue. Nothing will ever tell you. Poll, and poll at an
  interval matched to how fast that thing actually changes.

That is the whole rule. Everything below exists because the rule is easy to know and easy to break
in the same session — measured, repeatedly, in exactly that shape.

## The exemption is a passport, not a visa — ask per command

The question above is asked of **one command**. Not of the session, not of the hour, not of "what
I'm currently up to." The external-state exemption is a passport each command carries or doesn't;
it is never a visa stamped on the whole afternoon.

This is the failure that is actually costing you, and it is subtle because the session looks
*consistent*. You are mid-promotion. You are waiting on a Railway deploy, tailing a `gh run`,
checking `modal app list` — all correct, all exempt, all the job. The whole texture of the work is
"I am waiting on external things I have to poll myself." Then a backgrounded worker also needs
checking, and the reflex reaches for the same `tail`, because the frame is already set.

> *"This whole session is external polling — the Railway loop, the `gh run`, the health curl.
> Skip clause. Doesn't apply to me right now."*

**That is the moment, and it is the one this file was rewritten for.** The frame is a property of
the last command, not of this one. Re-ask the question, out loud, about the path in the command you
are about to write: *is `…/tasks/bh44yv8f0.output` written by a worker the harness is tracking?*
Yes → the notification is already scheduled → don't.

Measured, 2026-09-25, 22:30–22:35, one session, five minutes:

```
for i in $(seq 1 60); do railway deployment list …    # 22:30  RIGHT — external, nothing will tell you
tail -6 …/tasks/bifay6via.output                      # 22:30  WRONG — harness-tracked
tail -4 …/tasks/b1cvvf79o.output                      # 22:31  WRONG
railway status                                        # 22:30  RIGHT
sleep 90; tail -5 …/tasks/bh44yv8f0.output            # 22:32  WRONG — and now with a sleep in front
tail -5 …/tasks/bh44yv8f0.output                      # 22:35  WRONG — same file again
```

Interleaved. Same minutes, same agent, same keyboard. Three of those lines are the job and four are
a notification being rebuilt by hand. Nothing about the session tells them apart — only the path
does.

## The rule is the WORKER, not the filename

If a harness-tracked worker will write it, you do not poll it. Not `tasks/X.output`. Not the
scratchpad it scribbles in. Not the build log it tees. Not the JSON it assembles. Same worker, same
notification, same answer: **wait**.

A rule scoped to a filename is a rule with a hole in it, and the hole gets used. An agent that had
been told "don't poll `tasks/*.output`" ran forty iterations against the same worker's *scratchpad*
and believed it had complied.

## What to do instead

| You want | Use |
|---|---|
| To know when it's done | Nothing. End the turn or do unrelated work. You will be re-invoked. |
| To watch it while it streams | `Monitor` |
| Its output, after the notification | `TaskOutput` |
| Exactly one mid-flight glance | One `Read` on the stated path |
| To stop it | `TaskStop` |

## WRONG — measured, verbatim, nine times in eleven minutes

On 2026-09-23 between 14:44 and 14:55, one session ran these against six different task files:

```
F=…/tasks/bw79otc3h.output; until grep -q "exit="       "$F" 2>/dev/null; do sleep 30; done; cat "$F"
F=…/tasks/bw79otc3h.output; until grep -q "exit="       "$F" 2>/dev/null; do sleep 20; done; cat "$F"
F=…/tasks/b69y7d6y3.output; until grep -q "WAIT:"       "$F" 2>/dev/null; do sleep 15; done; cat "$F"
F=…/tasks/bdsa3m1vh.output; until grep -q "UNRESOLVED:" "$F" 2>/dev/null; do sleep 30; done; cat "$F"
F=…/tasks/b0ebsjs5m.output; until grep -q "FETCH:"      "$F" 2>/dev/null; do sleep 20; done; cat "$F"
sleep 90; cat …/tasks/b69y7d6y3.output 2>&1 | tail -10
```

Look at what that session had to build to get there. It could not know what "finished" looks like,
so it **invented a completion protocol** — it instructed each worker to print a magic string
(`exit=`, `WAIT:`, `UNRESOLVED:`, `FETCH:`) and then blocked on `grep -q` for that string. A
notification protocol, hand-rolled, per task, in shell. The harness ships one. It is already
running. It knows.

And note line two. `bw79otc3h` got polled twice — once at `sleep 30`, then again at `sleep 20`.
The first loop did not return an answer; it burned the Bash timeout and came back with nothing.

RIGHT, for every one of those six: launch it, stop, let the notification arrive.

## Disarming the three good objections

**"But `until …; do sleep; done` is *one* tool call — that's cheaper than N peeks."** It is the
best argument against this rule and it is still wrong, on three counts. It was not one call: it was
nine, because loops time out and get re-run with a shorter sleep. It blocks the entire turn — you
can do nothing else and the user cannot interject. And it **cannot detect failure**: if the worker
crashes before printing `exit=`, the sentinel never appears, the loop spins until the Bash timeout,
and you learn nothing. The completion notification fires on the crash too. Hand-rolled waiting
swallows exactly the outcome you most need to see. `[LAW:no-silent-failure]`

**"The notification might not come — I'd rather verify."** Then you have a harness bug worth
reporting, not a reason to build a shadow protocol in shell. Nine polls in eleven minutes is not
verification; it is a second, worse implementation of a mechanism that already works, maintained by
you, in `sh`, forever.

**"I need to see partial progress, not just the end."** Fair, and there is a tool for it: `Monitor`.
Reach for that. What you must not do is approximate it with `sleep 45; tail -15`, because the tail
comes back half-written, which proves nothing, which justifies the next tail. That is the ratchet.

## The moment, scripted

The job is backgrounded. The turn goes quiet. Two minutes in you think:

> *"I'll have it echo `exit=` at the end, then just block until that shows up — one call and I'll
> know."*

**That is the moment.** Name it when you feel it. You are about to write a completion protocol for
a worker that already has one, and the version you write will hang when the worker dies. You
already launched it. The notification is already scheduled. Stop typing and end the turn.

## Knowing this is not immunity

The session above used `Monitor`, `TaskOutput` and `TaskStop` throughout the very same window. The
right tools were loaded, known, and used — and the hand-rolled loops still happened nine times.
This failure is not ignorance. It is the idle-turn reflex, and it fires precisely when there is
nothing else to do. Which is why the answer is *do nothing*, and why that is the hardest instruction
in this file to follow.

And it got worse before it got better, in a way worth staring at. **This file's own description was
injected into that session at 22:27:48** — the full trigger text, naming `tail` against
`tasks/*.output` in so many words. At 22:28 the session used `Monitor`, then `TaskOutput`. At 22:30
it began tailing task files by hand and did it seven times over the next five minutes.

Two minutes. Text on screen. Correct tools in hand. Still polled.

So do not read this file as information you might lack. You have it. The gap is not knowledge, and
no amount of additional explanation closes it — what closes it is asking the one question **about
the specific path you are about to type**, at the moment you type it, every single time, including
the times it feels obviously unnecessary. Especially then.

## Recap

- One question: **did the harness promise to notify you?** Yes → don't poll. No → poll away.
- Ask it **per command**. The external exemption is a passport this command carries or doesn't,
  never a visa stamped on the session. A legitimate `railway`/`gh run` poll one line up launders
  nothing.
- The rule is the **worker**, not the filename — `.output`, scratchpad, tee'd log, all the same.
- Never make a worker print a sentinel so you can `grep -q` for it. That is a notification you
  rebuilt by hand, and it hangs on crash.
- `Monitor` to watch, `TaskOutput` to collect, one `Read` to glance, `TaskStop` to kill.
- External state — CI, deploys, health endpoints — is **exempt**, and polling it is the job.
