# Context restart and sleeping members

**Status: design agreed 2026-10-13; not built.**
Source: a review of the pearl crew's recorded cost and laptop load with
Scott, 2026-10-13. Two goals: fewer tokens, and less load on whistle (11 GB,
8 cores, shared with the crew's test runs).

## Why: what the crew spent, 2026-10-07 to 2026-10-13

From the `:COST:` usage lines in the pearl queue and its archive, credited to
the member who closed or handed off:

| Role | Cost | Share | Median context at close |
|---|---|---|---|
| owner | 218.31 | 70% | 119k |
| check | 46.79 | 15% | 75k |
| gate | 25.95 | 8% | 60k |
| lead | 22.35 | 7% | 173k |

Owners close at 119k median, 270k at the 75th percentile, 562k at the 90th
and 866k at the most. Every call re-reads its whole session, so that tail
is where the cost is. `:fresh-per-item` bounds a member between items, not
within one.

From the owners' transcripts, the two costliest sessions (867k, 659k) had
19 and 25 prompts and crossed 200k at prompts 4 and 5: they grew across
many turns after that. Others grew inside one turn (40k to 197k, 48k to
272k).

On the laptop: nine Claude sessions held 2.3 GB (about 250 MB each) while
the gate's pytest workers held another 1.6 GB. Checkers are idle most of
the time: the live queue has 22 "idle: crew_mine shows 0 pending"
checkpoints. Every session also starts at about 38k tokens before any
work (first call, median, every role).

## Global constraints

- Nothing project-specific in the package; the threshold is set in a profile.
- Both behaviours are opt-in. A crew with neither key behaves as today.
- `make check` and `make api-check` stay green; no new agent-shell API.

## 1. A fresh session when context passes a threshold

**Behaviour.**
- **Key:** `:fresh-at-context N`, in tokens, on a member or a whole profile;
  the member's wins, as for `:fresh-per-item`. Off unless set. Independent
  of `:fresh-per-item`, so a lead could use it too. Pearl sets 220000 on
  owners, checkers and the gate.
- **Ask first.** When a turn completes with the session's context
  (`agent-shell--state` `:usage` `:context-used`) over N, and the member
  owns an ACTIVE item, the crew sends one nudge: "Your context is 240k, over
  the crew's limit of 220k. Call crew_checkpoint on each item you are
  working on with exactly where you are and what is next, then end your
  turn. You will continue in a fresh session." It is sent once per session.
- **Then restart.** At the next turn completion the member is due a fresh
  session, and the existing refresh runs with its existing blockers: busy,
  at a permission prompt, a draft in its input, messages queued in
  agent-shell. Blocked, it stays due and the next turn end tries again. The
  new session gets the brief and, from the intro, its items with their
  checkpoints; held nudges move across.
- **Cost is kept.** Before the old session is killed, its spend since the
  member's last close is recorded on its ACTIVE item, as a close records it.
  The usage log line (`usage: X, context 240k`) also marks where each
  restart happened. Without this, a restart would lose that spend.
- **The restart keeps the spec.** `agent-shell-crew--maybe-refresh` today
  passes `:fresh t`; it must pass the member's own `:fresh` and
  `:fresh-at-context`, so a member with only the threshold is not turned
  fresh-per-item by its first restart.

**Why at a turn end only.** A mid-turn steer ("checkpoint and end your
turn") would also catch growth inside one turn, but a declined steer
interrupts the turn, mid-edit. The costliest sessions grew across turns, so
turn ends catch most of the saving at no risk. Revisit with the recorded
cost per item if one-turn growth still dominates.

**Done when:** a member over its threshold at a turn end is asked to
checkpoint, then restarted at the following turn end with its items and
checkpoints; one under it is untouched; a blocked one stays due; the spend
before the restart is on the item.

## 2. Sleeping members

**Behaviour.** For members with `:fresh-per-item`:
- **Sleep.** When a turn completes, nothing blocks a refresh, the member
  owns no PENDING or ACTIVE item, and it holds no nudges, the session is
  killed and the member is recorded asleep: an in-memory list of
  (ROOT MEMBER . SPEC). `agent-shell-crew-session-changed-hook` runs. A
  member that does own open items is refreshed as today. PARKED does not
  keep a member awake: a question can wait hours on the human, and the
  decision is a nudge, which wakes it.
- **Wake.** `agent-shell-crew--notify` finds no buffer for the member, but
  finds it asleep: it removes it from the list, starts it from its spec,
  and the text is delivered after the brief, as for any starting session.
  Every nudge (RPC create and handoff, the human's new and decide) goes
  through `--notify`, so this is the one place.
- **Backstop.** Each tick of `agent-shell-crew-watch-mode` wakes a sleeping
  member that owns a PENDING or ACTIVE item: an item written into the Org
  file by hand, or a wake whose start failed (it stays asleep, and the next
  tick retries).
- **Start.** `agent-shell-crew-start-profile` records a `:fresh-per-item`
  member that owns no PENDING or ACTIVE item as asleep instead of starting
  it, sparing a 38k-token start that would end in sleep.
  `agent-shell-crew-start` (roles, no profile) has no fresh members and is
  unchanged.
- **Stop.** `agent-shell-crew-stop` removes the root's sleeping members, so
  a stopped crew is not woken by a nudge. `restart-profile` is stop then
  start-profile and needs no change.

**Cost of waking:** a session starts in about 15 seconds when work arrives.
Today's refresh pays the same start, just earlier.

**Done when:** a fresh member that closes its last open item sleeps at its
turn end; one with open items is refreshed instead; a nudge wakes a sleeper
and arrives after its brief; start-profile does not start idle fresh
members; stop clears the list; the watch tick wakes a sleeper that owns a
PENDING item.

## 3. What the human sees

- **List.** A member status `asleep`. RET on a sleeping member wakes it and
  shows its buffer; that is the human asking for it.
- **Health.** A sleeping member owning a PARKED item is not "orphaned"
  (today: an open item whose owner is not running is stalled). A crew whose
  members are all asleep still counts among the running roots, so its dot
  says idle instead of vanishing.

**Done when:** the list shows `asleep`; health reports no stall for a
sleeper with a PARKED item; an all-asleep crew keeps its dot.

## Not included

- **Mid-turn steer** to catch growth inside one turn (see §1).
- **Sleep across an Emacs restart.** The list is in memory;
  `start-profile` rebuilds it.
- **Role pooling** (workers switching between build and check). Most of its
  laptop saving comes from §2 without losing independent review, which
  sent back about one hand-off in three (120 of 349).

## Docs

- README "Keeping cost down": `:fresh-at-context`, sleeping members.
- design.md: a section for each, beside "A fresh context per item".

## Tasks

To be written with `/plan`.
