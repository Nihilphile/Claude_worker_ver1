# Role System Design (v2) — Final

> **Status**: Implemented. This document reflects the as-built design.

## Directory Structure

```
prompt_templates/
├── default/
│   ├── system.md                        ← State system user manual (how to use Update-WorkerState)
│   │                                     ← NO engineering rules, no safety constraints
│   │                                     ← Injected to --system-prompt-file (Layer 1)
│   └── header.md                        ← Worker preamble with ~~ROLE~~ placeholder
│
└── role/
    └── <role-name>/                     ← Created by `role register <name>`
        ├── system_prompt/               ← Injected to --system-prompt-file (Layer 2, after default/system.md)
        │   └── *.md                     ← Sorted alphabetically, concatenated
        ├── header_prompt/               ← Injected to task prompt preamble (after default/header.md)
        │   └── *.md                     ← Sorted alphabetically, concatenated
        ├── normal_prompt/               ← NOT auto-injected. Only when -InjectNormal <name> is used.
        │   └── <name>.md                ← Template name = filename without .md extension
        └── legal_state.json             ← {"version":"1","states":["running","exit"],"exit_confirmation":"..."}
```

## Injection Rules (fixed, not configurable)

| Layer | Source | Injection Target | Purpose |
|-------|--------|-----------------|---------|
| 1 | `default/system.md` | `--system-prompt-file` | State system manual (Update-WorkerState usage) |
| 2 | `role/<name>/system_prompt/*.md` (sorted) | `--system-prompt-file` (appended) | Role-specific rules, compression-resistant |
| 3 | Role legal states + Update-WorkerState usage | `--system-prompt-file` (appended) | Current role's legal state list, exit confirmation |
| 4 | `default/header.md` | Task prompt preamble | Worker identity + `~~ROLE~~` substitution |
| 5 | `role/<name>/header_prompt/*.md` (sorted) | Task prompt preamble (appended) | Role persona, stable preamble |
| 6 | `role/<name>/normal_prompt/<name>.md` | Task prompt body (appended) | Only when `-InjectNormal <name>` specified |
| 7 | User Prompt | Task prompt body | The task from the orchestrator |

## `role register` — v2 Behavior

```
role register <name> [-Force]
```

1. Check for name conflict — if exists, show existing info and refuse (unless `-Force`)
2. If `-Force`, delete existing directory and recreate
3. Create `prompt_templates/role/<name>/` with subdirectories:
   - `system_prompt/` (empty)
   - `header_prompt/` (empty)
   - `normal_prompt/` (empty)
4. Write default `legal_state.json`:
   ```json
   {
     "version": "1",
     "states": ["running", "exit"],
     "exit_confirmation": "你确认已经完整执行主控要求的结束流程，并留下主控可验收的结果或证据了吗？",
     "description": "Default legal states for <name>"
   }
   ```
5. Record entry in `prompt_templates/roles.json` with `"structure": "v2"`

**No file copying.** `-Files` is no longer required. Orchestrator manually places `.md` files into the three folders after registration.

## `legal_state.json` — Schema

```jsonc
{
  "version": "1",                    // optional
  "states": ["running", "exit"],     // required: min ["running","exit"]
  "exit_confirmation": "...",        // required: shown to worker on --exit (no Confirm)
  "description": "..."              // optional: human note
}
```

- `"running"` and `"exit"` are **mandatory**. If either is missing, `send` is **rejected** in preflight.
- `legal_state.json` is **mandatory** for all roles. `send` with a role lacking this file is rejected (no flat role compat).
- Orchestrator can manually edit `legal_state.json` to add/remove states.
- `Update-WorkerState.ps1` validates against this file at runtime (hard error on illegal state).

## Update-WorkerState.ps1 — v2 Behavior

The ONLY worker-facing lifecycle/state interface.

```
powershell -File Update-WorkerState.ps1 -AgentName "agent" -CommandId "id" -Role "role" --<legal-state> [-Confirm] [-SummaryMessage "text"]
```

### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-AgentName` | Yes | Agent ID |
| `-CommandId` | Yes | Command ID |
| `-Role` | Yes | Role name (must match task-assigned role) |
| `--<state>` | Yes | Exactly one legal state, e.g. `--running`, `--exit` |
| `-Confirm` | No | Required for `--exit` to confirm and write state |
| `-SummaryMessage` | No | Optional human-readable summary |

### State File Format (JSON)

Written to `run/<agent>/.<command_id>.state`:
```json
{
  "agent_id": "my-agent",
  "command_id": "20260615-...",
  "role": "coder",
  "state": "running",
  "confirmed": false,
  "updated_at": "2026-06-15T...",
  "summary_message": "Optional summary"
}
```

### Exit Confirmation Gate

1. First call `--exit` (without `-Confirm`): Prints the `exit_confirmation` checklist from `legal_state.json`. Does NOT write any state file.
2. Second call `--exit -Confirm`: Writes `state=exit, confirmed=true` in JSON state file. This is the ONLY authoritative exit signal.

### Error Handling

- **Illegal state**: Hard error, lists all legal states from `legal_state.json`, does not write file.
- **Role mismatch**: Hard error if `-Role` does not match the role assigned to the current task.
- **Missing legal_state.json**: Hard error if role has no `legal_state.json`.
- **Missing parameters**: `-AgentName`, `-CommandId`, `-Role` are all mandatory.

## Manager Sync-ReadState (v2)

- Reads `run/<agent>/.<command_id>.state` (JSON) for each running agent
- If state changed → validates against `legal_state.json` (MANDATORY — missing legal_state.json is a protocol error)
- Illegal state → HARD ERROR; does NOT update `current_state`; records `state_error` on agent entry
- **If `state=exit` and `confirmed=true`** → transitions agent status to `["finishing"]`
- Prints `[STATE] agent: old -> new` on change
- No v1 text-format fallback. `.state` files must be valid JSON.

## Manager Sync-KillPending (v2)

- Processes agents in `["finishing"]` status (set by Sync-ReadState on exit+confirmed)
- Enforces 5s grace period then kills process tree
- **Does NOT detect `.exit` files.** The ONLY authoritative exit signal is `.state` JSON.
- **Runtime limitation**: Force-killed TUI sessions are NOT guaranteed resumable.
  Claude does not get a chance to flush session state before `Stop-Process -Force`.
  Use `-p` mode for workflows requiring reliable session resume across rounds.

## Complete-ClaudeTask.ps1 — Deprecated

- Not part of the v2 worker protocol
- No longer required in worker prompt
- No longer writes `.exit` signal
- Kept as an internal convenience stub for writing result/done files in specific scenarios

## Result Command — Convenience Viewer

- `result <agent>` is a convenience viewer, NOT an authority
- Shows state JSON summary (command ID, role, state, summary_message)
- Shows result.md if available
- Missing result.md is NOT an error

## `normal_prompt` CLI — Explicit Selection

- `normal_prompt/` templates are **reusable prompt fragments**, NOT a work mode.
- `send ... -InjectNormal <name>` injects `role/<role>/normal_prompt/<name>.md` into the task body.
- The injection is placed **between the completion contract and the `TASK:` marker** — the contract and task remain intact.
- End-to-end chain (verified by targeted smoke 2026-06-15):
  `CLI -InjectNormal` → `ClaudeTui.ps1` → `_DoLaunch` → `Send-ClaudeCommand.ps1` → `Build-WorkerPrompt` → worker prompt.
- If template does not exist → hard error in preflight (before any manager state mutation).
- Without `-InjectNormal`, `normal_prompt/` content is never auto-injected.
- Templates listed in `role show <name>` output.

## Current Operational Notes

### InjectNormal Fully Wired (2026-06-15)

The boundary between manager (`ClaudeTui.ps1`) and launcher (`Send-ClaudeCommand.ps1`) is now fully connected: `Build-WorkerPrompt` reads the normal template from `prompt_templates/role/<role>/normal_prompt/<name>.md` and injects its content into the worker prompt. Previously, `InjectNormal` was correctly tracked in `pending_task`/`current_task` but silently dropped at the launcher boundary. See [targeted smoke report](worker-reports/role-system-v2-targeted-smoke-report.md) for end-to-end verification with marker `V2_TEST_NORMAL_JSON_D4B7`.

### Sync-DeadToFailed Hard Timeout

`Sync-DeadToFailed` wraps each `Get-Process` call in a PowerShell background job with `Wait-Job -Timeout 3` (3-second hard ceiling). This prevents zombie PIDs from causing multi-minute CLI hangs when `agents.json` contains `"running"` entries whose OS processes have already exited. See [repair report](worker-reports/role-system-v2-sync-dead-timeout-repair-report.md).

### pending_task_error Visibility

When auto-continue of a queued `pending_task` fails, the error message is recorded in `pending_task_error` (top-level agent entry property) and displayed in `agent <id>` detail view. `pending_task` itself is preserved so the task is not lost.

### TUI Observability (Parser Fix)

The TUI runner template in `Send-ClaudeCommand.ps1` was repaired: a nested here-string that caused 13 parser errors was replaced with an array-based transcript-writing block. All observability artifacts (stderr log, done.json fallback, transcript) are intact. See [lifecycle review report](worker-reports/role-system-v2-lifecycle-review-report.md).
