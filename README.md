# Claude Worker v1

File-protocol multi-agent orchestration for Claude Code. Delegate bounded tasks to worker agents in visible PowerShell windows, with session reuse and role-based prompt injection.

[![MIT License](https://img.shields.io/badge/license-GPL-blue.svg)](LICENSE)

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
