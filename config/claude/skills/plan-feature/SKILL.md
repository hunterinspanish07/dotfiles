---
name: plan-feature
description: Turn a feature idea into a small set of well-cut lit tickets, each with a machine-verifiable Definition of Done — interview the user to resolve ambiguity, propose the breakdown, and STOP for human approval (Gate 1) before filing anything. Use when the user says "plan a feature", "break this down into tickets", "let's plan X", or "/plan-feature".
---

# Plan Feature → lit tickets (Gate 1)

Convert an idea into a reviewed ticket breakdown. The deliverable of this skill
is **an approved plan**, not filed tickets — filing happens only after the human
approves. This is the front of the supervised flow (see the project's
`AGENTS.md`); `/next` picks up the work afterward, never this skill.

## Init

Run `lit quickstart new` for the authoritative ticket-creation guidance, and
`lit quickstart` if you haven't already this session.

## 1. Understand before you decompose — grill the idea

You cannot cut good parts out of a fuzzy idea. Interview the user the way the
`grill-me` skill does: **one question at a time**, walking each branch of the
decision tree, resolving dependencies between decisions before moving on. For
every question, lead with your recommended answer.

- If a question is answerable from the codebase, **explore the codebase instead
  of asking** — read the relevant files, then state what you found.
- Only surface a question that is genuinely the user's to answer (a preference,
  a product call, a fact only they hold). Basic repo facts you dig out yourself.
- Stop interviewing when you can state, in one paragraph, what the feature is,
  what's in scope, what's explicitly out, and how each piece will be verified.

## 2. Decompose into small, well-cut tickets

`[LAW:decomposition]` Cut at the real joints. Each ticket does **one thing** you
can name in a phrase without "and"; a ticket you can only describe with "and" is
two tickets. Prefer many small tickets over few large ones — small tickets
review cleanly, merge fast, and fail loudly when wrong.

For every ticket, write a **machine-verifiable Definition of Done**
`[LAW:verifiable-goals]`: a concrete criterion a deterministic process can check
(a test that passes, a command that exits 0, an assertion that holds, output
that contains/omits a specific string). "Implement X" is not a DoD; "`pytest
tests/test_x.py` is green and `GET /x` returns 200" is. If you cannot state a
checkable DoD, the ticket is under-specified — sharpen it or split it.

Capture for each ticket: **title**, **one-paragraph description**, **DoD**, and
its **dependencies / parent** (what must land first; what epic it belongs to).

## 3. 🚦 GATE 1 — present the breakdown and STOP

Show the full plan as a single reviewable artifact:

- The one-paragraph feature summary and the in/out-of-scope line.
- The ordered ticket list: title · description · DoD · deps/parent, ranked.
- Open risks or decisions you're flagging for the human.

Then **stop and ask for approval.** Do **not** run `lit new`, `lit import`, or
create any ticket before the human approves the breakdown. `[LAW:no-silent-
failure]` filing tickets the human hasn't seen turns a planning step into
unreviewed work — Gate 1 exists precisely to prevent that. Amend the plan per
their feedback and re-present until they approve.

## 4. After approval — file the tickets

Only now create the tickets, following `lit quickstart new`:

- One ticket per unit, with the title, description, and DoD from the approved
  plan. For a multi-ticket epic, `lit import` a JSON tree in one shot; for a
  few, `lit new` each.
- Wire structure explicitly: `lit parent` / `lit dep` for the dependencies you
  identified, and `lit rank` so the queue reflects the agreed order.
- Echo back the created ticket IDs mapped to the plan so the human can see the
  plan became the backlog faithfully.

## 5. Hand off — do not auto-start

Surface the top ready ticket (`lit ready`) so the next step is obvious, then
**stop**. Starting work is `/next`'s job and, in supervised mode, the human's
call — never auto-start the first ticket from here.
