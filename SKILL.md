---
name: claude-worker
description: Delegate bounded tasks to Claude Code worker agents through manager-layer file-protocol orchestration. Dual-mode runners (-p/TUI), role registry, session reuse.
---

# Claude Worker v1

File-protocol multi-agent orchestration for Claude Code. Workers run via `claude --resume <uuid>` in visible PowerShell windows. Manager (`manager/agents.json`) is the single state source.

## Setup

1. Install [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and configure API access.
2. Clone this repo.
3. Set default workspace (pick one):
   - Create `manager/config.json`: `{"default_workspace": "F:/path/to/your/project"}`
   - Env var: `$env:CLAUDE_WORKER_DEFAULT_WS = "F:/path/to/your/project"`
   - Or pass `-Workspace` on every `send`.
4. Run from project root:
   ```powershell
   $tui = "./scripts/ClaudeTui.ps1"
   ```

## Execution Model

Two runner modes (set with `-Mode`):

- **`-p`** (default): Non-interactive. Claude exits cleanly. Best for automated pipelines.
- **`tui`** (`-Mode tui`): Interactive Claude window. After completion, window stays open until CLI triggers cleanup (see Rule 9).

Both capture real Claude session UUIDs, support `--resume`, and write `result.md` + `done.json`. System prompt (`--system-prompt-file`) injects the worker runtime contract from `prompt_templates/default/system.md`.

## Quick Start

```powershell
& $tui send my-coder -Prompt "Implement login" -Role worker -Workspace "F:/path/to/myapp"
& $tui agents                                   # list all
& $tui agent my-coder                           # detail
& $tui wait my-coder                            # wait
& $tui result my-coder                          # read output
& $tui remove my-coder                          # soft-delete
```

## CLI Commands

| Command | Description |
|---------|-------------|
| `send <id> -Prompt <p> [-Role r] [-Workspace w] [-FreshSession] [-Timeout n] [-Model m] [-Mode tui\|p]` | Launch worker. `-Role` injects templates from registry. |
| `agents [--all]` | List with Worker State, Output State, Session UUID. |
| `agent <id>` | Full detail: status, session, PID, tasks. |
| `wait any [<id> ...]` | Any agent (global or in subset). Returns JSON, marks `consumed`. |
| `wait <id> [<id> ...]` | Wait until ALL specified finish. |
| `wait all` | Wait until all running/finishing finish. |
| `result <id>` | Print `result.md`. |
| `remove <id>` | Soft-delete. Running/finishing rejected. |
| `remove all [-k <id> ...]` | Soft-delete all. `-k` keeps listed agents. |
| `role register\|update\|list\|show\|unregister` | Role registry. Detail: [docs/roles.md](docs/roles.md). |

### Busy Agent Handling

```
[MANAGER] Agent 'my-coder' is currently BUSY
  Worker   : running (37s elapsed)
  Task     : Fix login page layout
  New Task : Add rate limiting

  [W] Wait   - queue, auto-start after current finishes
  [C] Cancel - abort (default)
```

## Core Patterns

### Single Worker

```powershell
& $tui send coder -Prompt "Implement X" -Role worker -Workspace "F:/myapp"
& $tui result coder
```

### Multi-Turn with Session Reuse

```powershell
& $tui send my-coder -Prompt "Read docs. Write questions." -Workspace "F:/myapp"
# orchestrator writes decisions...
& $tui send my-coder -Prompt "Read decisions. Implement." -Workspace "F:/myapp"
```

### Concurrent Multi-Worker

```powershell
& $tui send coder-a -Prompt "..." -Role worker -Workspace "F:/myapp"
& $tui send coder-b -Prompt "..." -Role worker -Workspace "F:/myapp"

while ($true) {
    $done = & $tui wait any | ConvertFrom-Json
    if (-not $done) { break }
    & $tui result $done.agent_id
    & $tui send $done.agent_id -Prompt "Next..." -Workspace "F:/myapp"
}
```

### Multi-Orchestrator

```powershell
# Orchestrator A
& $tui send coder-a -Prompt "..." -Workspace "F:/myapp"
& $tui wait coder-a

# Orchestrator B
& $tui send coder-b -Prompt "..." -Workspace "F:/myapp"
& $tui wait coder-b
```

### Fresh Session / Long Tasks

```powershell
& $tui send new --Prompt "Fresh analysis" -FreshSession -Workspace "F:/myapp"
& $tui send heavy --Prompt "Full rewrite" -TimeoutSeconds 3600 -Workspace "F:/myapp"
```

## Reference

| Topic | Doc |
|-------|-----|
| agents.json schema, status tags, lifecycle, Sync functions | [docs/agents-json-schema.md](docs/agents-json-schema.md) |
| Session UUID capture & resume | [docs/session-uuid-lifecycle.md](docs/session-uuid-lifecycle.md) |
| Role system (registration, usage, default templates) | [docs/roles.md](docs/roles.md) |
| Store vs Run directory layout | [docs/store-vs-run.md](docs/store-vs-run.md) |

## Rules for Orchestrators

1. **Call `remove all -k <your agents>` before new batches.** Keep your workers, soft-delete the rest.
2. **Do not reuse the same agent_id concurrently.** Prompt confirms. Use different IDs for parallel work.
3. **Prefer `wait any` for concurrency.** Or `wait id1 id2 ...` to scope to your subset.
4. **Read results via CLI, not internal files.** Use `result`, `agent`, `agents`.
5. **Session reuse is automatic.** Same agent_id = same session. `-FreshSession` resets.
6. **Write decisions to files.** Workers read them next turn.
7. **Match timeout to task size.** Quick: 300-600s. Implementation: 600-1200s. Heavy: 1800-3600s.
8. **Check Worker State before consuming result.** `failed` or `timeout` means result.md may be generic.
9. **TUI workers won't auto-close.** Always follow `send -Mode tui` with `wait <id>`. If you see `finishing`, call `wait <id>` twice (5s grace period).
10. **`remove all` skips running/finishing.** Use `-k` to keep your agents. Soft-delete preserves `store/` data.
