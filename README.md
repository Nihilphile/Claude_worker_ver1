# Claude Worker v1

File-protocol multi-agent orchestration for Claude Code. Manager-layer persistent state (`manager/agents.json`), dual-mode runners (`-p` and TUI), agent-level session reuse via real Claude UUIDs.

## Quick Start

```powershell
$tui = ".\scripts\ClaudeTui.ps1"

# Single task
& $tui send my-coder -Prompt "Implement X" -Role worker -Workspace "F:\AI_project\myapp"

# List all agents (Worker State + Output State columns)
& $tui agents

# Agent detail
& $tui agent my-coder

# Read result
& $tui result my-coder

# Soft-delete (frees agent_id)
& $tui remove my-coder
```

## Architecture

```
User --> ClaudeTui.ps1 (CLI + Manager)
           |
           +-- manager/agents.json              Single source of truth
           |     status array: ["running"] | ["finished","ready"] | ...
           |     Sync-KillPending:  .exit signal --> 5s grace --> kill process tree
           |     Sync-DoneToManager: done.json --> status + session_uuid
           |     Sync-DeadToFailed:  dead PIDs --> ["failed"]
           |
           +-- prompt_templates/               Editable prompt layers
           |     default/system.md               Layer 1: worker contract (--system-prompt-file)
           |     default/header.md               Layer 3: worker header + ~~ROLE~~ placeholder
           |     role/<name>/                   Registered role templates (Layer 2)
           |
           +-- Send-ClaudeCommand.ps1 (launcher)
                 |-- Reads prompt templates from disk
                 |-- -p mode:  claude --system-prompt-file ... -p --output-format json
                 |-- TUI mode: claude --system-prompt-file ... (interactive window)
                 +-- Runner process lifecycle managed by manager
```

## Key Design

| Concept | Implementation |
|---------|---------------|
| Manager layer | `manager/agents.json` -- single persistence file |
| Dual-key identity | `internal_id` (GUID, system-assigned) + `agent_id` (user-chosen, semantic) |
| Status array | `@("running")\|@("finished","ready")\|@("finished","consumed")\|@("failed")\|@("deleted")\|@("finishing")` |
| Session UUID | Filesystem scan (new) or done.json (subsequent) --> agents.json --> --resume |
| System prompt | `prompt_templates/default/system.md` — worker runtime contract, injected via `--system-prompt-file` (compression-resistant) |
| Process cleanup | TUI: .exit signal --> 5s grace --> kill process tree. -p: auto-exits. |
| Busy handling | Prompt [W]ait queue / [C]ancel. No kill option. |
| Role system | `prompt_templates/role/<name>/` — registered role templates injected into prompts |

## Files

| Path | Purpose |
|------|---------|
| `scripts/ClaudeTui.ps1` | CLI + Manager -- user-facing entry point |
| `scripts/Send-ClaudeCommand.ps1` | Worker launcher -- generates mode-specific runner.ps1 |
| `scripts/Complete-ClaudeTask.ps1` | TUI-mode completion handler (writes done.json + .exit signal) |
| `scripts/Stop-ClaudeRuntime.ps1` | PID-based cleanup utility |
| `manager/agents.json` | Single state file -- agent registry with status arrays |
| `prompt_templates/default/` | system.md (worker contract), header.md (worker preamble) -- editable |
| `prompt_templates/role/` | Registered role templates (via `role register` CLI) |
| `store/<agent>/results/` | done.json, result.md (persistent) |
| `run/<agent>/` | runner.ps1, prompt.txt, logs/ (transient) |
| `.claude/worker-permissions.json` | Pre-approved permissions for worker agents |
