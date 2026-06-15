---
name: claude-worker
description: Delegate bounded tasks to Claude Code worker agents through manager-layer file-protocol orchestration. Dual-mode runners (-p/TUI), v2 role registry, session reuse, JSON state tracking.
---

# Claude Worker v2

File-protocol multi-agent orchestration for Claude Code. Workers run via `claude --resume <uuid>` in visible PowerShell windows. Manager (`manager/agents.json`) is the single state source. v2 role system with layered prompt injection and JSON state tracking.

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

- **`-p`** (default): Non-interactive. Claude exits cleanly after the task. Best for automated pipelines.
  Claude writes JSON output, session files are properly flushed to disk. **Session resume is reliable.**
  Recommended for all multi-turn workflows.
- **`tui`** (`-Mode tui`): Interactive Claude window. Workers signal completion via `Update-WorkerState --exit -Confirm`. Manager detects the confirmed exit state, triggers a 5s grace period, then kills the runner window. Always follow `send -Mode tui` with `wait <id>`.
  **TUI sessions ended by manager force-kill are NOT guaranteed resumable.** The process
  is terminated before Claude can flush session state. Use `-p` mode for workflows that
  need reliable session resume across rounds.

Both modes support `--resume` for session reuse. The system prompt (compression-resistant) is injected via `--system-prompt-file` from `prompt_templates/default/system.md` plus role-specific `system_prompt/*.md` files.

## Quick Start

The minimum v2 path requires a registered role (every `send` preflight validates `legal_state.json`):

```powershell
# 1. Register a role (creates directory structure + legal_state.json)
& $tui role register my-role

# 2. (Optional) Add role prompt files — edit directly on disk:
#    prompt_templates/role/my-role/system_prompt/*.md   <- role rules
#    prompt_templates/role/my-role/header_prompt/*.md   <- role persona
#    prompt_templates/role/my-role/normal_prompt/*.md   <- -InjectNormal templates
#
#    Edit legal_state.json to add custom states if needed.

# 3. Launch a worker with the registered role
& $tui send my-agent -Role my-role -Prompt "Explain the project structure"

# 4. Check results (state summary + optional result.md)
& $tui agents                     # list all
& $tui agent my-agent             # detail
& $tui wait my-agent              # wait for completion
& $tui result my-agent            # convenience viewer: state summary then result.md
& $tui remove my-agent            # soft-delete
```

## CLI Commands

| Command | Description |
|---------|-------------|
| `send <id> -Prompt <p> [-Role r] [-Workspace w] [-FreshSession] [-TimeoutSeconds n] [-Model m] [-Mode tui\|p] [-InjectNormal <name>]` | Launch worker. `-Role` must be a registered v2 role. `-InjectNormal` injects a single `normal_prompt/<name>.md` template into the task body. |
| `agents [--all]` | List with Worker State, Output State, current state, Session UUID. |
| `agent <id>` | Full detail: status, session, PID, tasks. |
| `wait any [<id> ...]` | Any agent (global or in subset). Returns JSON, marks `consumed`. |
| `wait <id> [<id> ...]` | Wait until ALL specified finish. |
| `wait all` | Wait until all running/finishing finish. |
| `result <id>` | Convenience viewer. Prints state summary (from `.state` JSON): command ID, role, state, confirmed, updated_at, summary_message. Then prints `result.md` if available. Missing `result.md` is not an error. |
| `remove <id>` | Soft-delete. Running/finishing rejected. |
| `remove all [-k <id1> [<id2> ...]]` | Soft-delete all non-running/finishing agents. `-k` keeps listed agents. Use `-k` to protect agents you did not create. |
| `role register <name> [-Force]` | Create v2 role: `system_prompt/`, `header_prompt/`, `normal_prompt/`, `legal_state.json`. Detail: [docs/roles.md](docs/roles.md). |
| `role update\|list\|show\|unregister` | Role management. Detail: [docs/roles.md](docs/roles.md). |

### Busy Agent Handling

```
[MANAGER] Agent 'my-coder' is currently BUSY
  Worker   : running (37s elapsed)
  Task     : Fix login page layout
  New Task : Add rate limiting

  [W] Wait   - queue, auto-start after current finishes
  [C] Cancel - abort (default)
```

## Worker State and Completion

Workers report progress via `Update-WorkerState.ps1` — the **only** worker-facing lifecycle/state interface. There is no `.exit` signal, and `Complete-ClaudeTask.ps1` is not part of the worker protocol.

### Calling Update-WorkerState

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<root>/scripts/Update-WorkerState.ps1" -AgentName "<agent>" -CommandId "<id>" -Role "<role>" --<legal-state>
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-AgentName` | Yes | Agent ID provided in the task header |
| `-CommandId` | Yes | Command ID provided in the task header |
| `-Role` | Yes | Must match the role assigned by the orchestrator |
| `--<state>` | Yes | Exactly one legal state, e.g. `--running`, `--exit` |
| `-Confirm` | No | Required only with `--exit` to actually write the exit state |
| `-SummaryMessage` | No | Stored as `summary_message` in the state JSON |

### State File

Each call writes `run/<agent>/.<command_id>.state` as JSON:
```json
{
  "agent_id": "my-agent",
  "command_id": "20260615-...",
  "role": "my-role",
  "state": "running",
  "confirmed": false,
  "updated_at": "2026-06-15T...",
  "summary_message": "Optional summary"
}
```

### Legal States

Default legal states are `running` and `exit`. Each role defines its legal states in `prompt_templates/role/<name>/legal_state.json`. The orchestrator may edit this file to add custom states. `send` preflight enforces that the role has a valid `legal_state.json`; `Update-WorkerState` validates every state transition against it (hard error on illegal state).

### Exit Confirmation Gate

Exiting requires two steps:

1. `--exit` (without `-Confirm`): Prints the `exit_confirmation` checklist from `legal_state.json`. Does **not** write any state file.
2. `--exit -Confirm`: Writes `state=exit, confirmed=true` in `.state` JSON. This is the **only authoritative completion signal**. The manager detects it and begins the cleanup/finishing flow.

### Completion Authority

The `.state` JSON file (`state=exit, confirmed=true`) is the single authority for task completion.

- `result.md` — optional convenience artifact. Workers may write a summary here, but the orchestrator reads `.state` JSON for completion status. Missing `result.md` is not an error.
- `done.json` — runner-generated artifact used internally to capture the Claude session UUID. Not part of the worker-facing protocol.

## Role System (v2)

### Directory Structure

```
prompt_templates/role/<name>/
├── system_prompt/       <- Injected to --system-prompt-file (after default/system.md)
├── header_prompt/       <- Injected to task preamble (after default/header.md)
├── normal_prompt/       <- NOT auto-injected. Only via send -InjectNormal <name>
└── legal_state.json     <- {"states":["running","exit"],"exit_confirmation":"..."}
```

### Key Behaviors

- `role register <name>` creates all four items above. `-Force` overwrites.
- `normal_prompt/` templates are never auto-injected. Use `send ... -InjectNormal <name>` to inject `normal_prompt/<name>.md` into the task body. Non-existent template -> hard error.
- Multiple `.md` files in `system_prompt/` or `header_prompt/` are concatenated alphabetically.
- Legal states are role-specific: orchestrator edits `legal_state.json` to add/remove states.
- `role show <name>` displays legal_state.json content, directory listings, and available `-InjectNormal` templates.

## Core Patterns

### Minimal Send + Wait

```powershell
& $tui role register worker
# Optionally add .md files to prompt_templates/role/worker/{system,header}_prompt/
& $tui send my-agent -Role worker -Prompt "Implement X" -Workspace "F:/myapp"
& $tui wait my-agent
& $tui result my-agent
```

### Multi-Turn with Session Reuse

```powershell
& $tui send my-coder -Role worker -Prompt "Read docs. Write questions." -Workspace "F:/myapp"
# orchestrator reads result, writes decisions to file...
& $tui send my-coder -Role worker -Prompt "Read decisions. Implement." -Workspace "F:/myapp"
```

### Concurrent Multi-Worker

```powershell
& $tui send coder-a -Role worker -Prompt "..." -Workspace "F:/myapp"
& $tui send coder-b -Role worker -Prompt "..." -Workspace "F:/myapp"

while ($true) {
    $done = & $tui wait any | ConvertFrom-Json
    if (-not $done) { break }
    & $tui result $done.agent_id
    & $tui send $done.agent_id -Role worker -Prompt "Next..." -Workspace "F:/myapp"
}
```

### Multi-Orchestrator

```powershell
# Orchestrator A
& $tui send coder-a -Role worker -Prompt "..." -Workspace "F:/myapp"
& $tui wait coder-a

# Orchestrator B
& $tui send coder-b -Role worker -Prompt "..." -Workspace "F:/myapp"
& $tui wait coder-b
```

### Fresh Session / Long Tasks

```powershell
& $tui send new-agent -Role worker -Prompt "Fresh analysis" -FreshSession -Workspace "F:/myapp"
& $tui send heavy -Role worker -Prompt "Full rewrite" -TimeoutSeconds 3600 -Workspace "F:/myapp"
```

## Reference

| Topic | Doc |
|-------|-----|
| Current system state (one-page overview) | [docs/role-system-current-state.md](docs/role-system-current-state.md) |
| Role system design (final, authoritative) | [docs/role-system-design.md](docs/role-system-design.md) |
| Role CLI reference | [docs/roles.md](docs/roles.md) |
| agents.json schema, status lifecycle, Sync functions | [docs/agents-json-schema.md](docs/agents-json-schema.md) |
| Session UUID capture & resume | [docs/session-uuid-lifecycle.md](docs/session-uuid-lifecycle.md) |
| Store vs Run directory layout | [docs/store-vs-run.md](docs/store-vs-run.md) |

## Rules for Orchestrators

1. **Register a role before sending.** Every `send` validates that the role's `legal_state.json` exists and contains at minimum `running` and `exit`. Preflight runs before any agent entry is created or modified — a failed send leaves no trace in `agents.json` and creates no run/store directories.
2. **Do not reuse the same agent_id concurrently.** Prompt confirms. Use different IDs for parallel work.
3. **Prefer `wait any` for concurrency.** Or `wait id1 id2 ...` to scope to your subset.
4. **Read results via CLI, not internal files.** Use `result` (state summary), then `agent` or `agents`.
5. **Session reuse is automatic.** Same agent_id = same session. `-FreshSession` resets.
6. **Prefer `-p` mode for multi-turn session resume.** TUI sessions ended by manager force-kill
   (confirmed exit → 5s grace → kill) are NOT guaranteed resumable — Claude does not get a
   chance to flush session state. UUID existence alone does NOT mean the session is resumable.
   See [docs/session-uuid-lifecycle.md](docs/session-uuid-lifecycle.md).
7. **Write decisions to files.** Workers read them next turn.
8. **Match timeout to task size.** Quick: 300-600s. Implementation: 600-1200s. Heavy: 1800-3600s.
9. **Check Worker State before consuming result.** `failed` or `timeout` means the task did not complete normally.
10. **TUI workers won't auto-close.** Workers must call `Update-WorkerState --exit -Confirm`. Manager detects `state=exit, confirmed=true` in `.state` JSON -> finishing -> 5s grace -> kill. Always follow `send -Mode tui` with `wait <id>`.
11. **`remove all` skips running/finishing agents.** Use `-k` to keep agents you did not create. Do not blindly `remove all` in shared environments — it affects all orchestrators. Soft-delete preserves `store/` data.
12. **`wait` and `Sync-All` are global.** Even when you `wait <specific-agent-id>`, the manager runs a full `Sync-All` cycle (ReadState → KillPending → DoneToManager → DeadToFailed). This means a `wait` for your agent can process state transitions (e.g., exit/finishing) of **other** agents managed by other orchestrators. Plan for this when sharing a manager: prefer scoped `wait <id1> <id2>` over `wait all`, and never `remove all` in shared environments.
