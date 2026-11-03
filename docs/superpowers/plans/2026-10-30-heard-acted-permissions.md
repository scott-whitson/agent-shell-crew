# Heard from, acted on, permissions logged, loops capped

**Status: built 2026-10-30, not yet run live.**
Source: a review of HKUDS/AutoSwarm, CopilotKit/OpenDuet and
opendatalab/MinerU against this package, 2026-10-30. MinerU gave nothing
(a document parser, not coordination); the other two gave three ideas.

## Global constraints

As in the 2026-10-18 plan: nothing project-specific; `make check` and
`make api-check` green; the MCP program must work against the OLD Elisp
until it is reloaded. The new `hello` verb gets "Unknown verb" from an old
Emacs, and the program ignores it.

## 1. A member whose crew tools never answered is stuck

**Why.** AutoSwarm probes each agent before trusting it ("do not ... use an
interactive slash command as proof a stdio child can run it"). Crew waited
for `init-finished` but never confirmed the crew MCP server came up: a
member without its tools looked like a member with nothing to do.

**Behaviour.** The MCP program sends `hello` once, off its main thread, after
its first `tools/list` reply. Every request (hello or any `crew_*`) runs
`agent-shell-crew-rpc-heard-function` before dispatch. `--adopt` clears
`agent-shell-crew--heard`; a ready, idle member with at least one finished
turn and no request heard is stuck: "its crew tools never answered". The
default is heard, so sessions from before the reload are never flagged.

**Done when:** a stub member ends a turn unheard and reads stuck; a hello
clears it; listing tools twice sends one hello.

## 2. A member that leaves told-about work untouched is stuck

**Why.** AutoSwarm separates submitted, delivered and answered. Crew knew
whether it had sent a nudge, not whether the member did anything with it.

**Behaviour.** `create`, `handoff` and the human's decision call
`agent-shell-crew-rpc-expect-function` BEFORE the nudge goes, so the nudge's
own `input-submitted` starts the count. Each turn end adds one to every
started count. A request naming the item clears it. Past
`agent-shell-crew-ack-turns` (2), an idle member with nothing held and no
other `ACTIVE` item is stuck: "has not touched item X in N turns". Entries
whose item closed or changed owner are dropped when checked. The queue is
read only when some count is past the limit.

**Done when:** two counted turns without a call naming the item read stuck;
a held nudge does not count until submitted; another `ACTIVE` item
suppresses it; a closed item is forgotten.

## 3. Answered permissions are logged on the working item

**Why.** OpenDuet writes an audit record for every gated action. Crew already
subscribed to `permission-response` but only to redraw.

**Behaviour.** On `permission-response`, when
`agent-shell-crew-log-permissions` is on, the member's `ACTIVE` item touched
last gets `permission for <member>: <tool title or kind> -> <option id |
cancelled>`. No `ACTIVE` item, no line. `make api-check` guards the event's
data keys and the tool call's `:title`.

**Done when:** an allowed and a cancelled permission each log a line; a
PENDING-only member or the setting off logs nothing.

## 4. A loop goes to the human (added 2026-11-02)

**Why.** A review of CopilotKit/OpenBot, which caps bot hand-off chains
(`BOT_HANDOFF_MAX_DEPTH`, `BOT_HANDOFF_MAX_PER_RUN`) and reports a capped
chain plainly. Pearl's queue and archive: 8 of 459 branches went back to
their owner 5+ times; `crew/215-build-receive-a-transfer` 11 times (33
hand-offs).

**Behaviour.** `crew_handoff` to a member fails when that member already
held the branch (the hand-off's `branch`, else the item's) more than
`agent-shell-crew-max-returns` (4) times, counting items created after the
latest human decision on any item on the branch. The refusal names the
count and tells the sender to `crew_park` the item. Nothing is handed; the
item stays ACTIVE with the sender. Not checked: to the human, no branch,
the archive. No new MCP argument, so old MCP programs are unaffected.

**Done when:** four returns pass and the fifth is refused; a decision lets
the next hand-off through; the human, no branch and nil are never checked.
Replay on the live pearl queue (read-only, 2026-11-02): limit 4 trips on one
branch, `crew/195-a-meeting-becomes-a-workflow` (owner-2 held it 7 times).

## Not done

- A `:capabilities` note per role for the lead to route by: wait until a
  non-Claude member runs again (pearl-pi is idle since 2026-10-11).
- Pushing decide items to Teams: private wiring if ever, not package code.
- pi: if the pi crew extension never lists tools through the MCP program
  and a pi member ends its first turn without a crew call, (1) flags it
  falsely. Check before running a pi member again.
