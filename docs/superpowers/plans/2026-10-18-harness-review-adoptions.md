# Adoptions from a review of three agent harnesses

**Status: built 2026-10-18 (§1-§5).** The brief-side
adoptions are live in the briefs (this repo's and pearl's); this plan is
the package side. The `:max-awake` cap went into the sleeping-members plan
(2026-10-13, §2) because it is part of that build.
Source: a review of paperthin (a skills catalog), pi-cowboy (a pi
extension that spawns background agents) and google-research/harness2
(recursive harness optimisation) against this package and the pearl crew,
2026-10-18.

## Global constraints

- Nothing project-specific in the package; anything a crew may not want
  is a setting, off or permissive by default unless noted.
- `make check` and `make api-check` stay green; no new agent-shell API.
- The MCP program in `bin/` is spawned fresh by every new session, while
  the Elisp runs in the live Emacs. A new verb or argument must work
  against the OLD Elisp until it is reloaded (ignored, or a clear error),
  so a live crew never breaks between the two.

## 1. One nudge per member per turn

**Why.** `--send` puts each nudge into agent-shell's busy queue, and every
queued prompt becomes its own turn. A gate that "claims every ready item
now" spends the 2nd to Nth nudges of a bundle on turns that find nothing,
each re-reading 60k+ tokens; the pearl queue had 22 "idle: crew_mine shows
0 pending" checkpoints by 2026-10-13. (pi-cowboy batches completions in a
200 ms window for the same reason.)

**Behaviour.**
- A nudge for a busy member is held in `agent-shell-crew--pending`, not
  submitted to agent-shell's queue. Urgent nudges still steer as today.
- At turn end (after `run-at-time 0`, so busy has cleared) the held nudges
  go as ONE prompt: "N crew messages:" then each, separated by a blank
  line. One held nudge goes as it is.
- If the member is due a fresh session at that turn end and only the held
  nudges would block it, it is refreshed first and they move across (as
  `--maybe-refresh` already moves them): the new work starts in a fresh
  context instead of the old one.
- Backstop: each watch tick flushes held nudges of a member that is ready,
  idle and has an empty input, so a lost turn-complete cannot strand them.
  `--member-stuck` and `--recover` count held nudges with agent-shell's
  queued prompts.

**Done when:** three nudges to a busy member arrive as one prompt at its
turn end; a due refresh carries them into the new session; a tick
delivers nudges stranded by a missing turn-complete.

## 2. One open item per ref

**Why.** `request_id` catches a retried call, not a second item for the
same work. Package 29 was claimed twice (2026-09-28), and pearl's
AGENTS.md says of duplicate claims "Nothing enforces this". (pi-cowboy
rejects a duplicate task by name before it spawns, naming the live one.)

**Behaviour.** RPC `create` with a `ref` fails when an open item (PENDING,
ACTIVE or PARKED) already has that ref, naming its id and owner, unless
`allow_duplicate_ref` is true, or that item is the new item's `parent`
(a lead splitting work). Hand-offs are unaffected: they close the source
before creating. The MCP tool gains the optional boolean.

**Done when:** a second create for an open ref fails with the first item's
id and owner; the override and a child of that item succeed; a hand-off
still inherits its ref.

## 3. The protocol lives in the package, and the tool holds it

**Why.** The hand-off, checkpoint and reach-members paragraphs are pasted
into all 7 briefs (3 here, 4 in pearl), and the copies have drifted: these
say `DONE|HANDED`, pearl's say `DONE|HANDED|PARKED` plus `| why:`. A rule
the tool enforces costs no prompt tokens and holds when the model drifts;
the error teaches the fix (harness2 validates each stage's output and
retries once with "YOUR PREVIOUS ATTEMPT WAS REJECTED" and the error).

**Behaviour.**
- `briefs/protocol.md`: the one text, pearl's version (the superset).
  `--intro` appends it after the role's brief. A profile's `:protocol`
  replaces it (a file or text), or `none` drops it.
- `agent-shell-crew-handoff-format`: a regexp a hand-off summary to a
  member (never to `human`) must match; nil disables. Default: the
  protocol's line, `ITEM <id> | <STATE> | branch <b> | sha <s> | ...`,
  loose about trailing fields. A mismatch fails the call with the format
  and the summary given, so the agent resends it in shape.
- Then the paragraphs are deleted from every brief, in the same change
  that reloads the package (pearl's members restart fresh per item, so a
  brief without its footer must not meet a package that cannot add it).

**Done when:** a member's intro carries the protocol once; `:protocol
none` drops it; a prose summary to a member is refused with the format; a
summary to `human` is not checked.

## 4. A resume after recovery says the last action may be incomplete

**Why.** Auto-recover interrupts a stuck member and resumes its queue,
but nothing tells it the interrupted step may not have finished; it can
assume a commit or test run completed. (pi-cowboy's status notes say
"output is partial; the task was NOT finished".)

**Behaviour.** When `--recover` interrupts a busy member, it also delivers:
"Your last turn was interrupted by stall recovery; its last action may
not have finished. Check git status and your checkpoint before you carry
on."

**Done when:** an interrupted member receives that line once per recovery.

## 5. What a brief version and model achieved

**Why.** Brief edits and the Sonnet-owner trial are judged by eye.
pearl's `crew_handbacks.py` already counts hand-backs and cost per lane
before and after a date, and from 2026-10-18 the check brief's `fail:`
codes. What it cannot see is which brief text and model did the work
when two changes overlap. (harness2 fingerprints the harness behind every
run and reports per fingerprint.)

**Behaviour.** When a member closes or hands off an item,
`--item-closed` also writes `:BRIEF:` (the first 8 hex digits of the sha1
of the brief text it was started with) and `:MODEL:` (the session's
model), beside `:COST:`. Reporting stays in the project's own scripts.

**Done when:** a closed item carries both properties; a changed brief
changes `:BRIEF:` from the next fresh session on.

## Not adopted

Recorded with reasons in the review (2026-10-18): a global skills catalog
(undoes the lean crew settings), sub-session chains after every edit,
harness self-editing without a grader, best-of-k builds, fire-and-forget
spawning without a watchdog, copy-on-write worktrees (not on ext4 in a
WSL vhdx), panes outside Emacs, and system-prompt replacement.

## Tasks

To be written with `/plan`.
