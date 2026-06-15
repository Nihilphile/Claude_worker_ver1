# Claude Worker v2

File-protocol multi-agent orchestration for Claude Code. Delegate bounded tasks to worker agents in visible PowerShell windows, with session reuse and v2 role-based layered prompt injection.

[![GPLv3 License](https://img.shields.io/badge/license-GPL-blue.svg)](LICENSE)

## Install

```powershell
git clone https://github.com/Nihilphile/Claude_worker_ver1.git
cd Claude_worker_ver1
```

**Prerequisites:** [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and API-configured.

Then set your default workspace (the folder workers operate in):

```powershell
# Option A: Config file (recommended)
echo '{"default_workspace": "F:/path/to/your/project"}' > manager/config.json

# Option B: Environment variable
$env:CLAUDE_WORKER_DEFAULT_WS = "F:/path/to/your/project"
```

## Quick Start

```powershell
$tui = ".\scripts\ClaudeTui.ps1"

# Launch a worker
& $tui send my-coder -Prompt "Explain the project structure" -Role explorer

# Check results
& $tui agents
& $tui result my-coder
```

## Architecture

```
User --> ClaudeTui.ps1 (CLI + Manager)
           |
           +-- manager/agents.json              Single source of truth
           |     status array: ["running"] | ["finished","ready"] | ...
           |     Sync-ReadState:    .state JSON --> current_state; exit+confirmed --> ["finishing"]
           |     Sync-KillPending:  ["finishing"] status --> 5s grace --> kill process tree
           |     Sync-DoneToManager: done.json --> status + session_uuid
           |     Sync-DeadToFailed:  dead PIDs --> ["failed"]
           |
           +-- prompt_templates/               Editable prompt layers (v2)
           |     default/system.md               Layer 1: state system manual (--system-prompt-file)
           |     default/header.md               Layer 4: worker header + ~~ROLE~~ placeholder
           |     role/<name>/                   Registered role templates (v2 structure)
           |       system_prompt/*.md            Layer 2: role rules (--system-prompt-file)
           |       header_prompt/*.md            Layer 5: role persona (task preamble)
           |       normal_prompt/<name>.md       Layer 6: explicit -InjectNormal only
           |       legal_state.json             States + exit confirmation
           |
           +-- Send-ClaudeCommand.ps1 (launcher)
                 |-- Reads prompt templates from disk (layered injection)
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
| System prompt | `prompt_templates/default/system.md` — state system manual (Update-WorkerState usage). Injected via `--system-prompt-file` (compression-resistant). Role `system_prompt/*.md` appended. |
| Worker state | `Update-WorkerState.ps1` — ONLY worker-facing lifecycle interface. JSON .state files. Exit requires confirmation gate. |
| Process cleanup | TUI: Sync-ReadState detects exit+confirmed → finishing → 5s grace → kill process tree. -p: auto-exits. |
| Busy handling | Prompt [W]ait queue / [C]ancel. No kill option. |
| Role system | v2 layered injection: `system_prompt/` → system prompt, `header_prompt/` → task preamble, `normal_prompt/` → explicit `-InjectNormal` only |

## Files

| Path | Purpose |
|------|---------|
| `scripts/ClaudeTui.ps1` | CLI + Manager -- user-facing entry point |
| `scripts/Send-ClaudeCommand.ps1` | Worker launcher -- generates mode-specific runner.ps1. Now receives `-InjectNormal` and injects normal_prompt content via `Build-WorkerPrompt`. |
| `scripts/Complete-ClaudeTask.ps1` | Deprecated (v2): convenience stub for writing result/done files. Not required by worker prompt. |
| `scripts/Update-WorkerState.ps1` | Worker-facing state update (v2): writes JSON .state file. ONLY lifecycle interface. |
| `scripts/Stop-ClaudeRuntime.ps1` | PID-based cleanup utility |
| `manager/agents.json` | Single state file -- agent registry with status arrays. Includes `pending_task_error` for auto-continue diagnostics. |
| `prompt_templates/default/` | system.md (worker contract), header.md (worker preamble) -- editable |
| `prompt_templates/role/` | Registered role templates (via `role register` CLI) |
| `store/<agent>/results/` | done.json, result.md (persistent) |
| `run/<agent>/` | runner.ps1, prompt.txt, logs/ (transient) |
| `.claude/worker-permissions.json` | Pre-approved permissions for worker agents |

## Current State

See [docs/role-system-current-state.md](docs/role-system-current-state.md) for a one-page overview of system status, known risks, and links to verification reports.
