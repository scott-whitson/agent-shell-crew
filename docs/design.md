# agent-shell-crew — design

**Status:** design, decisions settled; not yet planned or built
**Date:** 2026-09-30

A small crew of [agent-shell](https://github.com/xenodium/agent-shell) sessions
that share a work queue: one agent builds, another checks it, a lead can split
work up, and anything that needs a human decision is parked for you — with the
evidence attached — and answered from Emacs.

## Why this exists

Running several coding agents at once works until they need to coordinate. The
failure is always the same: work is handed from one session to another in chat,
the hand-off is lost when the conversation moves on, two sessions pick up the
same task, and a question for the human sits unseen in a buffer nobody is
looking at.

Existing tools cover half of this each:

- **Terminal orchestrators** (for example OpenRig) have the right coordination
  model — a durable queue where every piece of work has exactly one owner, is
  handed off transactionally, and can be parked on a human with evidence — but
  they run agents in tmux panes. From Emacs that means agents you cannot see,
  permission prompts you cannot answer, and state you learn about late.
- **meta-agent-shell** keeps agents in agent-shell buffers, which is the right
  place, but coordinates them with free-form messages and notes: no owners, no
  hand-off, no "waiting on the human" state.

agent-shell-crew is the queue model, native to agent-shell. It adds only the
queue and the few commands around it; visibility and permissions stay with
agent-shell and the packages that already do them well.

## What it is not

- Not an agent runner. Sessions are ordinary agent-shell sessions.
- Not a permission system. Permission prompts go through agent-shell (and any
  permission package you use) unchanged.
- Not a dashboard. The queue file is an Org file; Org is the view.
- No reminders, priorities, workflows, or cross-project items. A lead works
  within one project.

## Design rule: nothing personal in the package

Everything site-specific is a setting with a sensible default. The package
depends only on Emacs, agent-shell, and `python3` (for the MCP program). No user
paths, hosts, repositories, theme or tab-bar assumptions. The author's own
configuration is a consumer like any other.

## Concepts

- **Crew member** — an agent-shell session named `ROLE@PROJECT`
  (`owner@my-app`). The name is the identity.
- **Role** — a brief (what this kind of member does) plus which agent-shell
  agent runs it. Defaults: `lead`, `owner`, `check`.
- **Item** — one piece of work with exactly one owner at a time.
- **The human** — the member named `human`. Items parked on `human` are
  decisions waiting for you.

## The queue file

One Org file per project in `agent-shell-crew-directory` (default:
`(locate-user-emacs-file "agent-shell-crew/")`), named after the project root:
`my-app.org`. It lives outside the project, so nothing is written into the
repository.

**Only Emacs writes it.** Agents act through the MCP tool, which calls into
Emacs, and Emacs is single-threaded — two agents cannot interleave a write.
Assumption: a project's crew runs on one machine at a time. (Syncing the
directory between machines is fine; running the same project's crew on two at
once is not supported.)

```org
#+TODO: PENDING ACTIVE PARKED | DONE HANDED CANCELED
* ACTIVE Validate the mapping against the live schema   :crew:
:PROPERTIES:
:CREW_ID:   c-0930-0912-3f2a
:OWNER:     owner@my-app
:FROM:      human
:PARENT:    c-0929-1843-9b1c
:EVIDENCE:  notes/mapping-options.md
:REF:       ISSUE-13
:END:
The brief: what to do, the limits, what counts as done.
** Log
- [2026-09-30 Wed 09:12] created by human for owner@my-app
- [2026-09-30 Wed 09:13] claimed by owner@my-app
```

Rules:

- **The state is the TODO keyword**, so `org-agenda` shows it: `PARKED` items
  are the ones waiting on a human.
- **One owner per item.** A hand-off closes the item as `HANDED` and creates a
  new item for the recipient, linked by `:PARENT:`. History stays linear.
- **Parking** sets `:QUESTION:` (a summary with numbered options inline, e.g.
  `Options: (1) … ; (2) …`) and `:EVIDENCE:`. The human's answer is logged and
  stored in `:DECISION:`, and the item returns to `ACTIVE`.
- **The log is append-only.** Every transition adds a timestamped line with who
  did it. Nothing is rewritten.
- `:REF:` is free text — a ticket or roadmap id — for cross-referencing.

## The MCP tool

`bin/agent-shell-crew-mcp`: Python, standard library only, speaking MCP over
stdio. Each crew session starts its own instance, attached through
agent-shell's per-session `:mcp-servers`, with its environment computed when
the session starts:

- `CREW_AGENT` — this member's identity (`owner@my-app`)
- `CREW_PROJECT` — the project root
- the Emacs server socket to reach

Tools:

| Tool | Effect |
|---|---|
| `crew_mine`, `crew_list` | Items I own / all items in this project |
| `crew_show(id)` | One item: brief, properties, log |
| `crew_create(title, brief, owner, evidence?, ref?)` | New item for any member, or `human` |
| `crew_claim(id)` | `PENDING → ACTIVE` |
| `crew_note(id, text)` | Append a log line |
| `crew_handoff(id, to, summary, brief)` | Close mine as `HANDED`; open a new item for `to` |
| `crew_park(id, question, evidence)` | `→ PARKED` on `human` |
| `crew_done(id, reason)` | `→ DONE` or `CANCELED` |

**Into Emacs.** Each call becomes one `emacsclient` invocation of a single fixed
function, `agent-shell-crew-rpc`, whose one argument is the request as
**base64-encoded JSON**. No Lisp is constructed from text, and nothing needs
escaping. Emacs decodes the request, checks the verb against a fixed table,
and dispatches.

**Enforced in Emacs:**

- The actor is always `CREW_AGENT` from the MCP process environment, never a
  field in the request.
- Only an item's owner may claim, hand off, park or close it.
- `to` must be a member of this project's crew, or `human`.
- Every call is logged in the item.

**Limit, stated plainly:** this prevents mistakes, not a hostile agent. An
agent with shell access can call `emacsclient` itself — as it already can with
agent-shell today.

**Errors** — Emacs unreachable, unknown item, not the owner, bad arguments —
return as MCP tool errors with a plain message, so the agent can see why and
correct itself.

## Sessions

`agent-shell-crew-roles` maps each role to a brief (file or string) and an
agent-shell config maker (default: Claude Code). Any ACP agent that accepts MCP
servers works.

**`agent-shell-crew-start`** — pick a directory (a project root, or a worktree
you made) and roles. For each role it calls `agent-shell-start` with a config
from the role's maker, setting `:buffer-name` to `ROLE@PROJECT` and adding the
crew MCP server to `:mcp-servers`; then sends the role's brief as the first
prompt. The package does not manage git: bring your own worktree.

Project rules (build, test, conventions) come from the repository's own
`AGENTS.md`/`CLAUDE.md`, not from crew. The shipped briefs are generic.

## Nudges

When an item is created for, or handed to, a member, Emacs sends that session
one line: *"New crew item c-… for you: TITLE. Call crew_show."*

- **Busy session:** `agent-shell-busy-submit-queue`, so it arrives when the
  current turn ends. Nothing is typed into a running turn.
- **Idle session with an empty input:** `agent-shell-insert` with `:submit t
  :no-focus t`.
- **Idle session whose input is not empty** (a human is mid-draft): queue it
  instead. `agent-shell-insert` appends at the end of the input and would submit
  the draft with it.
- **No such session:** the item waits `PENDING`; `agent-shell-crew-start` tells
  each member what it already owns when it starts.

## Human commands

| Command | Does |
|---|---|
| `agent-shell-crew-new` | Create an item for a member: title, brief, optional evidence |
| `agent-shell-crew-decide` | Answer a `PARKED` item: evidence opened alongside, the item's numbered options offered as completions, free text allowed |
| `agent-shell-crew-open` | Open the project's queue file |

## Integration points

The package draws nothing by default. It exposes:

- `agent-shell-crew-parked` — the items waiting on a human, across projects
- `agent-shell-crew-changed-hook` — run after every queue change

and ships one optional display, `agent-shell-crew-mode-line-mode` (off by
default), showing `crew:N` in the mode line when N items wait. Users with their
own status display use the function and hook instead. `PARKED` items appear in
`org-agenda` once `agent-shell-crew-directory` is in `org-agenda-files`.

## Settings

| Setting | Default |
|---|---|
| `agent-shell-crew-directory` | `(locate-user-emacs-file "agent-shell-crew/")` |
| `agent-shell-crew-roles` | `lead`, `owner`, `check` with shipped briefs, Claude Code |
| `agent-shell-crew-mcp-program` | the package's `bin/agent-shell-crew-mcp` |
| `agent-shell-crew-python` | `"python3"` |

## Packaging

GPLv3, like agent-shell. Standard package header with `Package-Requires`;
byte-compile-clean and `checkdoc`-clean, as MELPA review expects. `make check`
runs byte-compilation, checkdoc and every test. README with install, a
five-minute walkthrough, and the settings.

## Tests

| Layer | How |
|---|---|
| Queue | ERT on temporary files: create, claim, hand off, park, decide, done. The log only grows; only the owner may act; a hand-off creates a linked item; parking requires a question; unknown ids error clearly |
| RPC | Only known verbs; actor from the environment never the request; malformed base64 or JSON returns a clean error, not a backtrace |
| MCP program | `unittest` with piped JSON and `emacsclient` stubbed: handshake, tool list, each tool's call-through, unreachable Emacs → tool error |
| Sessions and nudges | ERT with agent-shell stubbed: buffer naming, MCP attachment with the right identity, brief sent; busy session queued; non-empty input queued, not submitted |
| agent-shell API | A test that the agent-shell functions crew relies on still exist |
| Acceptance | One real task end to end: create → claim → hand off → park → decide → done |

## Alternatives considered

- **Keep a terminal orchestrator, mirror it into Emacs.** Rejected: the agents
  stay outside Emacs, and state arrives second-hand and late.
- **Patch a terminal orchestrator to run agents as agent-shell buffers** (a
  relay in each tmux pane). Rejected: tmux remains underneath, plus a daemon,
  for a coordination model small enough to write natively.
- **Plain CLI commands instead of MCP.** Rejected: agents follow instructions
  rather than calling typed tools, and a mistyped command fails silently.
- **An MCP server inside Emacs over HTTP.** Rejected: a network listener on
  Emacs's main thread — and on some setups Emacs is the window manager.
- **Queue files inside each repository.** Rejected: tooling that writes into the
  project is the thing users most object to in orchestrators.
- **One global queue file.** Rejected: every agent on every machine writing one
  file is where sync conflicts come from.
