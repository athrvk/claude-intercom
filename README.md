# claude-intercom

Let independent **Claude Code** sessions running in separate **WezTerm** panes
message each other **by role** — so one agent can hand work to another and the
peer acts on it. Example: a frontend session tells the backend session
*"expose `POST /api/users` returning `{id, email, name}`"* and the backend
session picks it up automatically.

Pure `bash` + the `wezterm cli` binary — **everything it needs ships in the
box.** Driven by Claude Code hooks, so the capability is always present and
ready the moment a session starts.

## How it works

```
frontend pane                                   backend pane
─────────────                                   ────────────
intercom send backend  ──┐
                            │  writes message → ~/.claude/claude-intercom/inbox/<backend-pane>/
                            └─ rings doorbell  → wezterm cli send-text (sentinel + Enter)
                                                       │
                                                       ▼
                                              UserPromptSubmit hook fires,
                                              drains inbox, injects:
                                              "[peer:frontend] expose POST /api/users …"
                                                       │
                                                       ▼
                                              backend agent acts, then replies:
                                              intercom send frontend …
```

- **Discovery** — `wezterm cli list` maps live panes; roles come from a small
  filesystem registry (`~/.claude/claude-intercom/`).
- **Delivery** — the full message goes to the peer's inbox file; only a tiny
  *doorbell* sentinel is injected into the peer's REPL (`send-text --no-paste` +
  a carriage return). The peer's `UserPromptSubmit` hook expands the inbox into
  clean, tagged context. This keeps arbitrary message content (quotes,
  backticks, `$vars`, newlines, code) out of the terminal entirely.
- **Receiving is effortless** — an injected prompt is consumed as a normal user
  turn, handled entirely by the existing hook.

## Install

**Prerequisites:** [WezTerm](https://wezterm.org) and
[Claude Code](https://docs.claude.com/en/docs/claude-code). All peer sessions
must run on the same machine.

In any Claude Code session, run:

```text
/plugin marketplace add https://github.com/athrvk/claude-intercom
/plugin install claude-intercom
```

Hooks and the `intercom` command load at **session start**, so they activate
in sessions launched *after* install. To enable it in an already-running
session, run `/reload-plugins` (or just start a new one).

Installation is fully self-contained — the plugin wires everything up for you:

- **`intercom` is on `PATH` automatically** — it ships in the plugin's `bin/`,
  which Claude Code adds to the session `PATH`.
- **Permission prompts are handled for you** — a bundled `PreToolUse` hook
  auto-approves the plugin's own `intercom` commands (gated by
  `if: "Bash(intercom *)"`, which uses Claude Code's matcher and rejects
  command chaining). An explicit `deny`/`ask` rule or managed policy still wins.

> Locked-down setup (managed policy or an explicit `ask` rule)? Add
> `"Bash(intercom:*)"` to your `permissions.allow` manually.

## Usage

### 1. Give each session a role

Just tell each agent who it is — it registers itself:

> **You →** "You're the **backend** agent for this project."

(or run `intercom register backend` yourself). Do the same in the other pane
with `frontend`. Roles are how peers address each other, so pick stable names
(`backend`, `frontend`, `infra`, …).

### 2. Hand work across panes

From one session, just ask the agent to message its peer:

> **You →** "Tell the backend agent we need `POST /api/users` returning
> `{id, email, name}`."

The agent runs:

```text
intercom send backend <<'MSG'
Please expose POST /api/users returning {id, email, name}
MSG
```

The backend session receives it automatically — delivered into its prompt tagged
`[peer:frontend] …` — acts on it, and can reply the same way. Work flows
straight from one pane to the other.

### Command reference

| Command | What it does |
| --- | --- |
| `intercom register <role>` | Declare this session's role |
| `intercom unregister` | Clear this session's role |
| `intercom list` | Show live peer sessions |
| `intercom send <role>` | Send the message on **STDIN** to a peer |
| `intercom inbox` | Manually view / drain pending messages |
| `intercom whoami` | Show this session's role and pane id |

The message for `send` is always read from **STDIN**, never an argument — so
quotes, backticks, `$vars`, and multi-line code pass through untouched. Use a
quoted heredoc (`<<'MSG' … MSG`) or pipe it in (`printf '…' | intercom send backend`).

## Scope & limitations (v1)

- **Same machine only.** All peer sessions share the local
  `~/.claude/claude-intercom/` state dir. Remote/SSH-domain panes are out of
  scope: the doorbell would reach them but the inbox file is local.
- **Permission prompts.** A doorbell that lands while a peer is sitting at a
  permission prompt can misfire. Minimized by the tiny sentinel and the
  recommended allowlist; not fully solved.
- **Roles are explicit and sticky.** A session is addressable only after
  `register`. Once set, a role stays bound to its WezTerm pane across
  resume / compact / `/reload-plugins` / restart — only `unregister` (or the
  pane closing) clears it.
- **Trust model.** Anything that can write the inbox and call `wezterm cli` can
  inject prompts. This is single-user/local by design — incoming peer messages
  are framed as *suggestions the receiving agent evaluates*, not commands to
  obey blindly.

## Development

```
bash tests/run.sh      # runs against tests/mock-wezterm (no real wezterm needed)
```

The mock `wezterm` records `send-text` calls and returns canned `list` JSON, so
the full CLI (register/list/send/drain/reconcile/guards) is testable anywhere.
