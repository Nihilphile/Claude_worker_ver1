---
name: claude-worker
description: Delegate bounded tasks to Claude Code worker agents through manager-layer file-protocol orchestration. Workers run via `claude --resume <uuid> -p --output-format json` in visible PowerShell windows. Supports single-worker, concurrent multi-worker, session reuse, and soft-delete agent lifecycle.
---

# Claude Worker v1

File-protocol multi-agent orchestration for Claude Code. Manager (`manager/agents.json`) is the single source of truth. Workers execute in visible PowerShell windows via `-p --output-format json` mode, producing `done.json` with real Claude session UUIDs. Session reuse uses `--resume <real-uuid>` for agent-level isolation.

**Project root:** `F:\AI_project\Claude_worker_ver1`

## Execution Model

Workers run in one of two modes (set with `-Mode`):

**`-p` mode (default)**: Non-interactive. Claude completes the task, writes JSON to stdout, and the process exits cleanly. Best for automated pipelines and when output fidelity matters more than visibility.

**`tui` mode (`-Mode tui`)**: Interactive Claude window. Useful when you want to watch the worker think in real time. After completion, the window stays open until a CLI command triggers cleanup (see Rule 10).

Both modes:
- Capture the real Claude session UUID from filesystem on first run, `done.json` thereafter.
- Use `--resume <uuid>` for agent-level session reuse.
- Write `result.md` + `done.json` (with `session_id`).

## Quick Start

```powershell
$tui = "F:\AI_project\Claude_worker_ver1\scripts\ClaudeTui.ps1"

# Send a task
& $tui send my-coder -Prompt "Implement login validation" -Role worker -Workspace "F:\AI_project\myapp"

# List all agents
& $tui agents

# Agent detail
& $tui agent my-coder

# Read result
& $tui result my-coder

# Soft-delete agent
& $tui remove my-coder
```

## CLI Commands

All commands via `ClaudeTui.ps1`:

| Command | Description |
|---------|-------------|
| `send <agent_id> -Prompt <p> [-Role r] [-Workspace w] [-FreshSession] [-TimeoutSeconds <n>] [-Model <name>] [-Mode tui\|p]` | Launch a worker. Resumes existing session if available. `-Role`: injects registered role templates into prompt. If the role name matches a registry entry, its template files are prepended to the task prompt. Works on both new and resumed sessions. |
| `agents [--all]` | List agents with Worker State, Output State, and Session UUID. `--all` includes soft-deleted agents. |
| `agent <agent_id>` | Show full detail: Worker State, Output State, status tags, session UUID, PID, current/pending task, timestamps. |
| `wait any [<agent_id> ...]` | `wait any` alone: any agent globally. `wait any coder_a reviewer_a`: first of the subset that finishes. Returns JSON, auto-marks `consumed`. |
| `wait <agent_id> [<agent_id> ...]` | Block until ALL specified agents finish. Multiple IDs supported — e.g. `wait coder_a reviewer_a`. |
| `wait all` | Block until all running/finishing agents finish. |
| `result <agent_id>` | Print the agent's `result.md`. |
| `remove <agent_id>` | Soft-delete agent (status → `["deleted"]`). Running/finishing agents cannot be removed. |
| `remove all` | Soft-delete all idle/finished agents. |
| `role register <name> -Files <path> [<path> ...] [-Force]` | Register a role with template files. Name conflict reports existing info; use `-Force` to overwrite. Templates are copied to `prompt_templates/role/<name>/`. |
| `role update <name> -Files <path> [<path> ...]` | Replace a role's template files. |
| `role list` | List all registered roles (name, registered by, updated, templates). |
| `role show <name>` | Show role details including full template contents. |
| `role unregister <name>` | Remove a role and its template directory. |

### Busy Agent Handling

When sending to a running agent, the CLI prompts:

```
[MANAGER] Agent 'my-coder' is currently BUSY
  Agent    : my-coder
  Worker   : running (37s elapsed)
  Task     : Fix login page layout
  New Task : Add rate limiting

  [W] Wait   - queue new task, auto-execute after current finishes
  [C] Cancel - abort this send (default)
```

No kill option — killing mid-API-call can leave orphaned requests on the provider.

## Role System

`-Role` is a free-form label. When used with a **registered role**, manager injects the role's template files into the worker prompt. Without a registered role, it acts as a lightweight tag in the prompt header (`"You are a $Role agent"`).

### Registering a Role

```powershell
# Create prompt template files
# my-workflow.md: workflow instructions
# safety.md: safety rules

& $tui role register coder-tdd -Files ./my-workflow.md, ./safety.md

# Name conflict? Manager reports existing info:
# [MANAGER] Role 'coder-tdd' already exists:
#   Registered by : Dreamjiao
#   Templates     : my-workflow.md, safety.md
#   Use -Force to overwrite, or choose a different name.

& $tui role register coder-tdd -Files ./new-rules.md -Force
```

### Using a Registered Role

```powershell
# On a new agent — role template injected
& $tui send my-coder -Role coder-tdd -Prompt "Implement feature X"

# Mid-session role switch — same agent, different role
& $tui send my-coder -Role reviewer -Prompt "Review the code you wrote"

# No -Role — no injection, plain session resume
& $tui send my-coder -Prompt "Continue working"
```

### Role Lifecycle

```
role register → templates copied to prompt_templates/role/<name>/
role update   → templates replaced
role unregister → templates deleted, registry entry removed
```

Roles are shared across all orchestrators using the same manager. Name conflicts between orchestrators are surfaced (not silently overwritten), so naming conventions like `coder-tdd` vs `coder-explore-first` emerge naturally.

### Editing Default Templates

The default worker prompt is defined in two files under `prompt_templates/default/`. Edit them directly — no CLI needed, changes take effect on the next `send`.

| File | Layer | Injected as | Purpose |
|------|-------|------------|---------|
| `system.md` | Layer 1 | `--system-prompt-file` | Worker runtime contract. Compression-resistant — Claude cannot forget these rules mid-session. Contains: completion script invocation, safety constraints, session reuse notice. |
| `header.md` | Layer 3 | Task prompt preamble | Worker header. `~~ROLE~~` is replaced with the actual role name (e.g. `explorer`, `coder-tdd`). |

**Example**: To add a global "no file editing" rule, append it to `system.md`:

```markdown
# my custom rule
- Never modify files outside the assigned workspace.
```

All workers pick it up immediately.

### Built-in Role Labels

These are just labels — no validation, no built-in prompt templates. Use them as-is or register custom ones.

| Label | Typical Use |
|-------|-------------|
| `explorer` | Investigate workspace, report findings |
| `reviewer` | Review code, produce review report |
| `planner` | Plan implementation approaches |
| `worker` | Implement, edit files within assigned scope |

## Core Patterns

### Pattern 1: Single Worker, Blocking

```powershell
& $tui send coder -Prompt "Implement feature X" -Role worker
# Blocks until done. Read result:
& $tui result coder
```

### Pattern 2: Multi-Turn with Session Reuse

```powershell
# Turn 1: Question pass
& $tui send my-coder -Prompt "Read docs/requirements.md. Write questions to docs/questions.md."

# Orchestrator reads questions.md, writes docs/decisions.md.

# Turn 2: Same agent_id = same session, context preserved
& $tui send my-coder -Prompt "Read docs/decisions.md. Implement within scope."
```

### Pattern 3: Concurrent Multi-Worker

```powershell
& $tui send coder-a -Prompt "Implement module A" -Role worker
& $tui send coder-b -Prompt "Implement module B" -Role worker
& $tui send reviewer-a -Prompt "Review module A diff" -Role reviewer

# Handle whoever finishes first
while ($true) {
    $done = & $tui wait any | ConvertFrom-Json
    if (-not $done) { break }
    Write-Host "$($done.agent_id) finished (command_id: $($done.command_id))"
    $result = & $tui result $done.agent_id
    # Decision logic...
    & $tui send $done.agent_id -Prompt "Next step..."
}
```

### Pattern 4: Fresh Session

```powershell
# Discard previous context, start new Claude session
& $tui send new-coder -Prompt "Analyze this fresh" -Role explorer -FreshSession
```

### Pattern 5: Long-Running Tasks

```powershell
& $tui send heavy-coder -Prompt "Rewrite the entire module" -Role worker -TimeoutSeconds 3600
& $tui send quick-review -Prompt "Scan for obvious bugs" -Role reviewer -Model sonnet
```

### Pattern 6: Multi-Orchestrator Production

When multiple orchestrators share the same manager, each should only wait for its own workers:

```powershell
# Orchestrator A
& $tui send coder-a -Prompt "..." -Role worker
& $tui send reviewer-a -Prompt "..." -Role reviewer
& $tui wait coder-a reviewer-a  # only waits for A's workers

# Orchestrator B (separate terminal/session)
& $tui send coder-b -Prompt "..." -Role worker
& $tui wait coder-b
```

## Manager Layer: agents.json

`manager/agents.json` is the single source of truth. The `status` field is an array that encodes both process state and result state:

### Schema

```jsonc
{
  "054e45d3-...": {                    // internal_id (GUID, system key)
    "internal_id": "054e45d3-...",
    "agent_id": "st_test",              // user-chosen semantic name
    "status": ["finished","ready"],     // process + result state (see below)
    "session_uuid": "b369223d-...",     // real Claude UUID (from done.json)
    "default_mode": "p",
    "pid": null,
    "current_task": {
      "command_id": "20260614-...",
      "prompt": "Say hi in one line.",
      "role": "explorer",
      "launched_at": "2026-06-14T04:05:48"
    },
    "pending_task": null,
    "created_at": "2026-06-14T04:05:48",
    "updated_at": "2026-06-14T04:06:23",
    "deleted_at": null
  }
}
```

### Status tags

The `status` array encodes two dimensions, displayed as separate columns:

| `status` | Worker State | Output State |
|----------|-------------|-------------|
| `["running"]` | running | none |
| `["finishing"]` | finishing | none |
| `["finished","ready"]` | finished | ready |
| `["finished","consumed"]` | finished | consumed |
| `["failed"]` | failed | none |
| `["deleted"]` | deleted | — |

### Lifecycle

```
["running"]  →  ["finishing"]  →  ["finished","ready"]  →  ["finished","consumed"]  →  ["running"] (re-send)
     ↓ task done        ↓ .exit signal       ↓ wait any returns      ↓ user sends new task
                        ↓ 5s grace           ↓ output ready          ↓ status reset
                        ↓ then kill window   ↓ wait any matches
```

### Key properties:
- `internal_id` is the true primary key (GUID). Never changes.
- `agent_id` is user-facing and reusable. Soft-delete frees it immediately.
- `session_uuid` is populated by Sync-DoneToManager reading `done.json`, or by filesystem scan on new sessions.
- `pending_task` enables the [W]ait queue — auto-starts on completion.

## Session UUID Lifecycle

```
Round 1 (new agent):
  Manager: session_uuid = null --> passes -FreshSession to launcher
  Runner: claude -p (no --resume) --> Claude creates new session
  Runner: captures JSON session_id --> writes done.json {session_id: "aaa-bbb"}
  Manager Sync: reads done.json --> agents.json session_uuid = "aaa-bbb"

Round 2 (resume):
  Manager: session_uuid = "aaa-bbb" --> passes -SessionId to launcher
  Runner: claude --resume "aaa-bbb" -p --> Claude resumes with full context
  Runner: same UUID in done.json
  Manager Sync: confirms session_uuid unchanged
```

Agent-level isolation: each agent_id has its own session_uuid. Multiple agents in the same workspace do not share sessions.

## Store vs Run

| Directory | Purpose | Lifecycle |
|-----------|---------|-----------|
| `manager/` | agents.json — single state file | Persistent |
| `prompt_templates/default/` | system.md, header.md — editable worker templates | Persistent |
| `prompt_templates/role/` | Registered role templates | Persistent |
| `store/<agent>/results/` | done.json, result.md | Persistent. Never auto-deleted. |
| `run/<agent>/` | runner.ps1, prompt.txt, logs/ | Transient. Safe to delete. |
| `.claude/` | worker-permissions.json | Persistent. |

Session UUID lives in `manager/agents.json`. The `.claude-sid.txt` in `store/` is a runner-side convenience copy.

## Rules for Orchestrators

1. **Call `remove all` before new batches.** Old idle entries from prior batches remain in `agents.json`. Soft-delete them to start clean.

2. **Do not reuse the same agent_id concurrently.** Sending to a running agent prompts confirmation. Use different agent_ids for parallel work.

3. **Prefer `wait any` for concurrency.** Handle agents as they complete.

4. **Read `result.md`, not internal files.** Worker output is in `result.md`. Do not parse `done.json` or `agents.json` directly — use CLI commands.

5. **Session reuse is automatic.** Same agent_id = same session. Use `-FreshSession` to intentionally reset.

6. **Write decisions to files for workers.** The file protocol is bidirectional: orchestrator writes files, worker reads them in the next turn.

7. **Match timeout to task size.** Quick: 300-600s. Implementation: 600-1200s. Heavy: 1800-3600s.

8. **Check Worker State before consuming result.** If `failed` or `timeout`, result.md may be generic.

9. **Stale running state auto-heals.** Sync-DeadToFailed detects dead PIDs and marks `["failed"]`. Sync-KillPending handles TUI exit signals with 5s grace period.

10. **TUI workers won't auto-close without CLI activity.** After a TUI worker finishes, the runner window stays open until you call any CLI command (`agents`, `wait`, `send`, `agent`). The CLI call triggers `Sync-All` → `Sync-KillPending`, which detects the `.exit` signal and kills the window after 5s. If you just launch a worker and walk away, it will hang indefinitely. **Workaround**: always follow a TUI `send` with `wait <agent_id>`. If you forget and later see `Worker State: finishing`, just call `wait <agent_id>` twice — the first call enters the 5s grace period, the second call (after 5s) completes it.

11. **Soft-delete does not destroy data.** `remove` only marks status=@("deleted") in agents.json. `store/<agent>/results/` is preserved. `agents --all` shows deleted entries.

12. **`remove all` skips running/finishing workers.** Only idle or finished agents are soft-deleted. Workers from other orchestrators are safe.
