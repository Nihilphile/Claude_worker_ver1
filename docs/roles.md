# Role System (v2)

`-Role` selects a registered v2 role. Every `send` validates that the role has a parseable `legal_state.json` containing the mandatory `running` and `exit` states. Unregistered and flat roles are rejected.

For guidance on designing a project-independent role contract, prompt layers, custom states, and smoke coverage, see [Creating Roles (v2)](role-creation-guide.md).

## CLI Commands

| Command | Description |
|---------|-------------|
| `role register <name> [-Force]` | Register with v2 directory structure. Creates `system_prompt/`, `header_prompt/`, `normal_prompt/`, and `legal_state.json`. No `-Files` required. `-Force` overwrites. |
| `role update <name> [-StateFile <path>]` | Update legal_state.json states from a file. Also ensures v2 structure exists. |
| `role list` | List all registered roles with structure type and legal states. |
| `role show <name>` | Show role details: legal_state.json, file lists per directory, normal_prompt templates. |
| `role unregister <name>` | Remove a role and its template directory. |

## v2 Role Structure

```
prompt_templates/role/<name>/
├── system_prompt/       ← Injected to --system-prompt-file (after default/system.md)
├── header_prompt/       ← Injected to task preamble (after default/header.md)
├── normal_prompt/       ← NOT auto-injected. Use send -InjectNormal <name>
└── legal_state.json     ← {"states":["running","exit"],"exit_confirmation":"..."}
```

## Using a Role

```powershell
# New agent — v2 role template layers injected
& $tui send my-explorer -Role explorer -Prompt "Investigate the assigned unknowns"

# With normal_prompt fragment (injected between contract and TASK: marker)
& $tui send my-explorer -Role explorer -Prompt "Trace the assigned subsystem" -InjectNormal architecture-trace

# Mid-session role switch — same agent, different role, session preserved
& $tui send my-explorer -Role reviewer -Prompt "Review the prior evidence"

# Every send still supplies a registered role, including session resume
& $tui send my-explorer -Role explorer -Prompt "Continue the investigation"
```

`-InjectNormal` is fully wired end-to-end: the normal prompt template content flows from `ClaudeTui.ps1` → `Send-ClaudeCommand.ps1` → `Build-WorkerPrompt` → worker prompt. Verified by targeted smoke (2026-06-15).

## Worker State Tracking

Workers use `Update-WorkerState.ps1` to report progress. The orchestrator reads state from `run/<agent>/.<command_id>.state` (JSON format). See `docs/role-system-design.md` for full details.

## Editing Default Templates

The default worker prompt is defined in `prompt_templates/default/`. Edit directly — no CLI needed.

| File | Injected as | Purpose |
|------|------------|---------|
| `system.md` | `--system-prompt-file` (Layer 1) | State system manual — Update-WorkerState usage and rules |
| `header.md` | Task prompt preamble (Layer 4) | `~~ROLE~~` replaced with actual role name |

## Role Storage and Git

Role directories under `prompt_templates/role/` are gitignored by default. They are **local configuration** — each orchestrator/user maintains their own roles via `role register`. If you need to share roles across collaborators or machines, use an explicit documentation or repository strategy (e.g., a separate shared-role repo, or commit the desired role directories by overriding `.gitignore`).
