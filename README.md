# agent-shell-crew

A small crew of [agent-shell](https://github.com/xenodium/agent-shell)
sessions sharing a work queue. One agent builds, another checks the work, a
lead can split tasks up — and anything that needs a human decision is parked
for you, with the evidence attached, and answered from Emacs.

Every piece of work has exactly one owner. Hand-offs are recorded. The queue is
an Org file per project, outside the repository, so it shows up in your
agenda. Agents reach it through an MCP tool that knows which session is
calling.

See [docs/design.md](docs/design.md) for the design and the reasoning.

## Requirements

- Emacs 29.1+, agent-shell 0.81.1+
- `python3` (standard library only) for the MCP program
- An Emacs server on a local socket (crew starts one if none is running)
- An agent that accepts MCP servers over ACP (Claude Code does)

## Install

Clone and add to `load-path`, or with `use-package`:

```elisp
(use-package agent-shell-crew
  :load-path "~/src/agent-shell-crew"
  :after agent-shell
  :config
  (require 'agent-shell-crew-list)       ; the health dot
  (agent-shell-crew-mode-line-mode 1)    ; dot + "crew:N" in the mode line
  (agent-shell-crew-watch-mode 1))       ; warn when a member is stuck
```

## Five minutes

1. `M-x agent-shell-crew-start` in a project: pick `owner` and `check`.
   Two sessions open, `owner@PROJECT` and `check@PROJECT`, each briefed.
2. `M-x agent-shell-crew-new`: give `owner@PROJECT` something to do.
3. Watch it claim the item, build, and hand it to `check@PROJECT`.
4. When a member parks a question on you, the mode line shows `crew:1`.
   `M-x agent-shell-crew-decide` opens the evidence and offers the options.
5. `M-x agent-shell-crew-list` shows the whole crew in one buffer: every
   member with its live status (working, blocked, ready, not running), the
   items it owns and their state, and anything waiting on you. `RET` goes to a
   member's session, `d` answers a parked item, `n` creates one, `o` opens the
   queue, `g` refreshes. It updates itself as the crew works.
6. `M-x agent-shell-crew-open` shows the queue file — it is just Org.
7. `M-x agent-shell-crew-board` shows what got done: one row per piece of
   work, its state, whether it merged, and one sentence on where it stands.

## Seeing how the crew is doing

**The dot.** `agent-shell-crew-status-segment` returns one dot for every
running crew's worst state; `agent-shell-crew-mode-line-mode` puts it in the
mode line, or add the function to your own status bar. Hover for the reason,
click for the board.

| Dot | Means |
|---|---|
| green | a member is working and nothing is stuck |
| grey | running, nothing open, nothing waiting at a stage you own |
| amber | something waits on you: a parked decision, an item you own, a member at a permission prompt, or merged work at a stage you own |
| red | stalled: a member is stuck, an open item's owner is not running, or work is open and nobody is working |

**Stuck members.** A turn whose end never reaches its buffer leaves a session
"busy" forever, and every message sent to it waits behind that turn. A member
busy with no activity for `agent-shell-crew-stall-minutes` (10), or idle with
a paused queue, is *stuck*: the dot goes red and `agent-shell-crew-watch-mode`
warns you once, in the echo area, saying what to do. Set
`agent-shell-crew-auto-recover` and it does it for you, only when messages are
waiting: it interrupts the member, then resumes its queue. A member at a
permission prompt is never touched.

**The board.** `M-x agent-shell-crew-board`, or click the dot. Items sharing a
`ref` are one row; the row shows the latest state, whether its `branch`
reached the trunk (`:trunk` in a profile, else `agent-shell-crew-trunk`), and
the one-sentence `status` its members last wrote — members are asked for one
on every hand-off, park and close. Keys: `RET` the item, `e` rewrite the
sentence, `s` record a stage, `b` record a branch, `a` show housekeeping rows,
`g` refresh.

**Stages** are what work passes through after it merges, declared per crew:

```elisp
:stages ((:name "deployed" :owner "human"
          :check "ssh prod cat /srv/app/REVISION")   ; prints the commit it reached
         (:name "accepted" :owner "human"))           ; recorded with s, or crew_stage
```

A check runs in the background and is cached for
`agent-shell-crew-check-minutes`; nothing waits on it. Stages show; they never
act.

## Deciding

`M-x agent-shell-crew-decide` (or `d` in the list) opens a parked item's
evidence and offers the options written at the end of its question —
`(1) ...; (2) ...`. **Type my own decision…** takes free text instead, for an
answer the options do not cover. A member whose situation changes calls
`crew_park` again to replace the question.

## Stopping

`M-x agent-shell-crew-stop` ends a crew's sessions and refuses, naming why,
while a member is working, at a prompt or holding messages, or an item is
ACTIVE (`C-u` to stop anyway). `M-x agent-shell-crew-restart-profile` stops
and starts a profile — for a change members only see at startup: a brief, the
tool schema, a directory. The queue is untouched either way.

## Settings

| Setting | Default |
|---|---|
| `agent-shell-crew-directory` | `~/.emacs.d/agent-shell-crew/` |
| `agent-shell-crew-roles` | `lead`, `owner`, `check`, with the briefs in `briefs/`, on Claude Code |
| `agent-shell-crew-mcp-program` | the bundled `bin/agent-shell-crew-mcp` |
| `agent-shell-crew-python` | `python3` |
| `agent-shell-crew-profiles` | none; see Profiles below |
| `agent-shell-crew-stall-minutes` | `10` |
| `agent-shell-crew-auto-recover` | `nil` |
| `agent-shell-crew-trunk` | `"main"` |
| `agent-shell-crew-stages` | none; or `:stages` in a profile |
| `agent-shell-crew-check-minutes` | `5` |

To show parked items in your agenda:
`(add-to-list 'org-agenda-files agent-shell-crew-directory)`.

For your own status display, use `agent-shell-crew-parked` and
`agent-shell-crew-changed-hook` instead of the mode-line mode.

### Profiles

One crew, one queue, members in several worktrees — for parallel lanes:

```elisp
(setq agent-shell-crew-profiles
      '(("my-app" :root "~/src/my-app/"
         :members ((:role "owner" :name "owner-1" :directory "~/src/my-app-lane-1/")
                   (:role "check" :name "check-1" :directory "~/src/my-app-lane-1/")
                   (:role "gate" :directory "~/src/my-app-gate/" :brief "~/briefs/gate.md")))))
```

`M-x agent-shell-crew-start-profile` starts every member not already running.
The package does not create worktrees; that is your setup.

## Development

`make check` byte-compiles, runs checkdoc and all tests against stub
agent-shell features. `make api-check DEPS="-L …"` checks the real
agent-shell still provides what crew uses.

## License

GPL-3.0-or-later.
