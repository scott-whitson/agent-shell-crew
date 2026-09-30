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
  :config (agent-shell-crew-mode-line-mode 1))
```

## Five minutes

1. `M-x agent-shell-crew-start` in a project: pick `owner` and `check`.
   Two sessions open, `owner@PROJECT` and `check@PROJECT`, each briefed.
2. `M-x agent-shell-crew-new`: give `owner@PROJECT` something to do.
3. Watch it claim the item, build, and hand it to `check@PROJECT`.
4. When a member parks a question on you, the mode line shows `crew:1`.
   `M-x agent-shell-crew-decide` opens the evidence and offers the options.
5. `M-x agent-shell-crew-open` shows the queue — it is just Org.

## Settings

| Setting | Default |
|---|---|
| `agent-shell-crew-directory` | `~/.emacs.d/agent-shell-crew/` |
| `agent-shell-crew-roles` | `lead`, `owner`, `check`, with the briefs in `briefs/`, on Claude Code |
| `agent-shell-crew-mcp-program` | the bundled `bin/agent-shell-crew-mcp` |
| `agent-shell-crew-python` | `python3` |

To show parked items in your agenda:
`(add-to-list 'org-agenda-files agent-shell-crew-directory)`.

For your own status display, use `agent-shell-crew-parked` and
`agent-shell-crew-changed-hook` instead of the mode-line mode.

## Development

`make check` byte-compiles, runs checkdoc and all tests against stub
agent-shell features. `make api-check DEPS="-L …"` checks the real
agent-shell still provides what crew uses.

## License

GPL-3.0-or-later.
