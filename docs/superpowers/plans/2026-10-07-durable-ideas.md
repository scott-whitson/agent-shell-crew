# Durable ideas: fresh context per item, idempotent calls, cancel cascade

**Status: spec, approved in principle by Scott 2026-10-07. Nothing is built.**
Source: a review of `@earendil-works/pi-durable` (README, 2026-10-07) against
this package. Pi's harness commits every step before showing it, resets a
conversation to a handoff note, de-duplicates retried submissions by
`requestId`, and aborts owned work bottom-up. Four of those map onto real
costs or failures here.

## Why: what the crew spent on 2026-10-07

Measured from the pearl crew's Claude transcripts for one day:

| | |
|---|---|
| Model calls | ~3,700 across lead, gate and three lanes (owner + check each) |
| Context re-read (cache read) | ~1.47 billion tokens |
| Output | ~4.6 million tokens (0.3%) |
| Average context per call | 258k to 814k, in sessions five days old |

Every call re-reads the whole session. A member that has done twenty items
carries all twenty into the twenty-first. Shortening what agents *write*
barely matters; shortening what they *carry* is the lever.

Failures seen the same day:
- `crew_create` timed out reaching Emacs (`emacsclient`, 30s) but the item
  was created. A retry would have made a duplicate.
- The lead could not cancel items it had created for a lane, because only an
  item's owner may close it.

## Global constraints

- Nothing project-specific in the package.
- Every new tool argument is optional; a crew that never sends one loses nothing.
- `make check` and `make api-check` stay green.

## 1. A fresh context per item (Pi: `reset(handoff)`, compaction)

**Behaviour.** When a member closes or hands off an item (`crew_done`,
`crew_handoff`) and its turn completes, the crew restarts that member's
session **new** (not resumed) and sends:
1. the role's brief;
2. for each item it still owns, the item's title, brief, `:CHECKPOINT:` (§2)
   and the last 10 log lines, as the handoff note.

The member starts its next item with brief + item, not with every item before
it.

- **Opt-in per profile or member:** `:fresh-per-item t`. Default off, so other
  crews keep today's behaviour.
- **Never while busy or at a permission prompt.** The restart waits for
  `turn-complete`, as nudges already do (design.md "Nudges"), and skips a
  member at a permission prompt, as stuck recovery already does.
- **Never with a human draft in the input.** Same rule as nudges: queue it.
- **Identity is kept.** The new session carries the same config and MCP
  identity. `agent-shell-crew--maybe-adopt` already adopts a restarted session.
- **Long-running roles** (a lead that keeps context across items) set it off.
  For the pearl crew: on for owner, check and gate; off for the lead at first.

**Done when:** a member with `:fresh-per-item t` that closes an item and owns
another starts a new session that has only its brief and that item. A member
that is busy, at a prompt or mid-draft is not restarted. Tests cover all four.

## 2. Checkpoints (Pi: a task saves a checkpoint at every step)

- New tool `crew_checkpoint(id, text)`: replaces the item's `:CHECKPOINT:`
  property (one line: the phase reached and what is next) and appends it to
  the log. Owner only.
- The fresh-start note (§1) and stuck recovery's resume include the
  checkpoint, so a member restarted after a usage limit resumes from the last
  phase instead of re-reading its whole transcript.
- Briefs say: checkpoint at each task boundary, in the terse format (§5).

## 3. Idempotent create and handoff (Pi: `requestId`)

- `crew_create` and `crew_handoff` take an optional `request_id`. Emacs stores
  it as `:REQUEST:` on the new item. A second call with the same `request_id`
  from the same actor returns the existing item's id, sends no second nudge,
  and logs "duplicate request ignored".
- **The MCP program supplies one when the agent does not**: a UUID per call.
  On an `emacsclient` timeout it retries once with the **same** request id.
  A timed-out call that did land is then found, not duplicated. Today's
  timeout becomes invisible to the agent.
- Scope: create and handoff only. claim, note, park and done are already
  idempotent in effect, or harmless to repeat.

## 4. Cancelling owned work (Pi: abort runs bottom-up)

- **The creator may cancel.** `crew_done(id, canceled=true)` is allowed for
  the item's owner (as today), the actor in its `:FROM:`, or `human`.
- **Cascade.** Cancelling an item cancels every open item linked to it by
  `:PARENT:`, children first, each logged "canceled with parent <id>".
  `crew_create` gains optional `parent`, so a lead's slate items can hang off
  the lead's own item and be cancelled together.
- Done and handed items are never touched.

## 5. A terse handoff format (caveman, for agents only)

Agent-to-agent text (handoff summaries, checkpoints, nudges, `crew_done`
reasons) uses one line of fields:

```
ITEM c-1007-1430 | DONE | branch crew/89-fix | sha f59 | tests 74p/0f | next: gate
CKPT c-1007-1430 | phase 2/4 built | next: tests for §3 | blocked: none
```

The human-facing text (park questions, evidence files, the board's status
sentence) stays plain prose. The package documents the format in
`briefs/*.md` and changes no code for it.

## Later, not in this plan

- **Usage per item on the board** (Pi: `pi.usage`): tokens per member and per
  item, from agent-shell's usage events if it exposes them, else from the
  agent's transcripts. It shows which items and roles cost the most.
- **Steer** (Pi: `whenBusy: "steer"`): an urgent message placed after the
  current tool step rather than at turn end. That needs agent-shell support;
  until then, briefs tell members to re-check `crew_mine` and their brief
  before starting each item, which §1 makes automatic.

## Tasks

- [ ] §3 request ids: queue `:REQUEST:` lookup; RPC create/handoff; MCP UUID
      and one same-id retry on timeout. Tests: duplicate returns the same id,
      no second nudge; timeout-then-retry creates one item.
- [ ] §4 creator and human may cancel; cascade over `:PARENT:`; `parent` on
      create. Tests: lead cancels a lane item; cascade order; closed items untouched.
- [ ] §2 `crew_checkpoint` and `:CHECKPOINT:`; included in resume text.
- [ ] §1 `:fresh-per-item`: restart-new after close/handoff at turn end, with
      the handoff note; skip busy, prompt and draft. Tests for each.
- [ ] §5 the format, in `briefs/owner.md`, `check.md`, `lead.md`.
- [ ] design.md: sections for each, and "Alternatives considered" gains pi-durable.
- [ ] Live: one pearl lane with `:fresh-per-item t` for a day; compare its
      average context per call with today's 258k to 814k.
