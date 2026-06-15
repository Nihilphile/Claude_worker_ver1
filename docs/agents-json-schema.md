# agents.json Schema & Status Lifecycle

`manager/agents.json` is the single source of truth for all agent state.

## Schema

```jsonc
{
  "054e45d3-...": {                    // internal_id (GUID, system key)
    "internal_id": "054e45d3-...",
    "agent_id": "st_test",              // user-chosen semantic name (group:: prefix for scoped agents)
    "status": ["finished","ready"],     // process + result state (see below)
    "session_uuid": "b369223d-...",     // real Claude UUID
    "default_mode": "p",                // "p" | "tui"
    "group": "smoke",                   // optional — scopes agent for multi-project isolation (null when not set)
    "pid": null,                        // runner process ID (null when idle)
    "current_task": {
      "command_id": "20260614-...",
      "prompt": "Say hi in one line.",
      "role": "explorer",
      "model": null,
      "inject_normal": "",              // normal_prompt template name (empty string if none)
      "launched_at": "2026-06-14T04:05:48"
    },
    "pending_task": {                   // queued via [W]ait on busy agent; null when none
      "prompt": "...",
      "role": "explorer",
      "model": null,
      "inject_normal": ""               // preserved for auto-continue
    },
    "pending_task_error": null,         // error message if auto-continue of pending_task failed (null when none)
    "created_at": "2026-06-14T04:05:48",
    "updated_at": "2026-06-14T04:06:23",
    "deleted_at": null                  // set on soft-delete
  }
}
```

## Status Tags

The `status` array encodes two display columns: Worker State and Output State.

| `status` | Worker State | Output State |
|----------|-------------|-------------|
| `["running"]` | running | none |
| `["finishing"]` | finishing | none |
| `["finished","ready"]` | finished | ready |
| `["finished","consumed"]` | finished | consumed |
| `["failed"]` | failed | none |
| `["deleted"]` | deleted | — |

## Lifecycle

```
  send preflight
  (role + InjectNormal
   validation — fails
   before any mutation)
        ↓
["running"]  →  ["finishing"]  →  ["finished","ready"]  →  ["finished","consumed"]  →  ["running"] (re-send)
     ↓ task done        ↓ .state exit        ↓ wait any returns      ↓ re-send
     ↓ Sync-Done        ↓ confirmed          ↓ output ready
     ↓ reads done.json  ↓ 5s grace → kill
     ↓
     ↓ auto-continue: reads pending_task.inject_normal, passes to Invoke-SendInternal
     ↓ pending_task cleared before launch; inject_normal flows through _DoLaunch → current_task
```

### Transaction Rules (anti-zombie)

1. **Preflight before any mutation**: `Assert-SendPreflight` called before `New-AgentEntry` / `Save-Agents` / `pending_task` write.
2. **No persistence before launch success**: New agent entry is held in-memory only; `Save-Agents` only after `_DoLaunch` successfully parses the launch summary JSON.
3. **Existing entry mutation deferred**: `current_task` / `status` / `pid` only written after launch success.
4. **Atomic save on success**: `status`, `pid`, `current_task`, `session_uuid` all set in one block then `Save-Agents` once.
5. **Throw on launch failure**: `Send-ClaudeCommand` non-zero exit and launch JSON parse failure both use `throw` (not `exit`). This ensures callers can handle the error and no partial entry persists.
6. **Orphan window**: If `Send-ClaudeCommand` starts a process but the launch summary cannot be parsed, the process may be orphaned (minimal window, no refactoring beyond noting in docs).

### InjectNormal Queue Preservation

When a busy agent receives a new task via `[W]ait`:
- `pending_task.inject_normal` stores the `-InjectNormal` value from the queued send.
- `Sync-DoneToManager` reads `pending_task.inject_normal` and passes it to `Invoke-SendInternal -InjectNormal`.
- `Invoke-SendInternal` validates it via `Assert-SendPreflight` and passes it to `_DoLaunch`.
- `_DoLaunch` records it in `current_task.inject_normal` for diagnostic traceability.
- A pending task with no normal (`inject_normal: ""`) works correctly — validation is skipped, no injection occurs.
- **End-to-end**: `InjectNormal` is now fully wired through `Send-ClaudeCommand.ps1` → `Build-WorkerPrompt`. The normal prompt template content is injected into the worker prompt between the completion contract and the `TASK:` marker. Verified by targeted smoke (2026-06-15) with marker `V2_TEST_NORMAL_JSON_D4B7` propagating from template → prompt → worker artifact.

### Auto-Continue Failure Recovery

When `Sync-DoneToManager` auto-continue fails (launch or preflight throw):
- `pending_task` is **preserved** (not cleared).
- `pending_task_error` is written to the agent entry with timestamp and error message.
- Agent status is **not** overwritten — only `pending_task_error` and `updated_at` are set.
- `pending_task_error` is displayed in `agent <id>` detail view for diagnostics.

**Residual risk**: A narrow crash window exists between `_DoLaunch`'s `Save-Agents` and `Sync-DoneToManager`'s `pending_task` clear. If the process crashes during this window, on restart the agent will have `status=["running"]` with `pending_task` still set, potentially causing duplicate execution on the next `Sync-DoneToManager` cycle.

### Sync Functions (manager internal)

| Order | Function | Reads | Writes |
|-------|----------|--------|--------|
| 0 | Sync-ReadState | `run/<agent>/.<id>.state` (JSON) | `current_state`; if state=exit+confirmed → status → `["finishing"]` |
| 1 | Sync-KillPending | `agents.json` status (finishing) + legacy `.exit` files | 5s grace → kill process tree → `["finished","ready"]` |
| 2 | Sync-DoneToManager | `store/<agent>/results/<id>.done.json` | state → finished,ready; captures session_uuid; auto-continue with inject_normal |
| 3 | Sync-DeadToFailed | OS process table | state → failed (PID dead, no done.json). Uses `Start-Job`/`Wait-Job -Timeout 3` hard timeout to prevent zombie-PID hangs. |

In v2, Sync-ReadState is the primary exit detection mechanism (reading `.state` JSON for `state=exit, confirmed=true`). The `.exit` file is a legacy fallback still supported by Sync-KillPending.

All Sync functions are triggered by any CLI command — there is no background daemon.

## Group Filtering (v2.1)

The optional `group` field enables multi-project isolation without file-level
separation. All agents remain in a single `agents.json`, but the CLI gates
output and operations by group.

### Query scope

| Scenario | `agents` / `agent` / `result` / `remove` | `wait` / `wait any` / `wait all` |
|----------|--------------------------------------------|----------------------------------|
| No `-Group` | All agents (backward-compatible) | All agents |
| `-Group "g"` | Only agents with `group="g"` | Only agents with `group="g"` |
| `wait group "g"` | (N/A — separate command) | All agents with `group="g"` |

### Agent ID prefix

When `-Group "x"` is passed, `agent_id` is internally resolved to `"x::<name>"`:

```
send my-coder -Group "noname"     → agent_id="noname::my-coder"
send noname::my-coder             → equivalent (group auto-extracted)
```

This prevents ID collisions: two users can both use `my-coder` in different groups.

### Sync-All message gating

`Sync-All` still processes all agents globally (data integrity). But
`Write-Host` calls for STATE/EXIT messages are gated through
`Test-GroupFilter`, which checks both `$ActiveGroup` and `$ActiveWaitTargets`:

| Variable | Set by | Effect |
|----------|--------|--------|
| `$ActiveGroup` | All commands via `-Group` | Only agents in this group pass |
| `$ActiveWaitTargets` | `Invoke-Wait` only | Only explicitly listed agent IDs pass (AND with group gate) |
| Both unset | No filter | All agents pass (default) |

Precision example: `wait any A B` sets `$ActiveWaitTargets` to `@("A","B")`.
`Sync-All` prints STATE/EXIT only for A and B, even if C and D are in the
same group and also running.

