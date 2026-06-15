---
name: claude-worker
description: Delegate bounded tasks to Claude Code worker agents through manager-layer file-protocol orchestration. Dual-mode runners (-p/TUI), v2 role registry, session reuse, JSON state tracking.
---

# Claude Worker v2

Claude Worker v2 is a file-protocol multi-agent manager for launching Claude Code
workers with registered roles, reusable prompt fragments, session reuse, and JSON
lifecycle state.

This file is the quick-start map. Detailed behavior lives in the linked docs below.

## Quick Start

```powershell
$tui = "F:\AI_project\Claude_worker_ver2\scripts\ClaudeTui.ps1"

# Inspect available roles.
& $tui role list
& $tui role show coder

# Launch a worker. Prefer -p mode for automated orchestration.
& $tui send my-coder `
  -Role coder `
  -Mode p `
  -Workspace "F:\path\to\project" `
  -Prompt "Implement the bounded change described here."

# For multi-project isolation, use -Group to scope workers:
& $tui send my-coder -Role coder -Group "my-project" -Mode p `
  -Workspace "F:\path\to\project" -Prompt "..."
# Equivalent shorthand: & $tui send my-project::my-coder ...

# Wait, inspect, and read results.
& $tui wait my-coder
& $tui agent my-coder
& $tui result my-coder
# Or wait for an entire group:
& $tui wait group "my-project"
```

Use `-InjectNormal <name>` only when you explicitly want a reusable normal prompt
fragment:

```powershell
& $tui send my-coder `
  -Role coder `
  -InjectNormal question-pass `
  -Mode p `
  -Prompt "Read the plan and surface hidden implementation decisions. Do not edit files."
```

## Essential Commands

| Command | Use |
|---------|-----|
| `send <id> -Role <role> -Prompt <text> [-Group <g>] [-Workspace <path>] [-Mode p\|tui] [-FreshSession] [-InjectNormal <name>]` | Launch or resume a worker. `-Group` scopes the agent for multi-project isolation. |
| `wait <id> [<id> ...] [-Group <g>]` | Wait for specific workers. STATE messages only for listed IDs. |
| `wait any [<id> ...] [-Group <g>]` | Wait for the first among listed (or group-scoped) workers. |
| `wait group <group_name>` | Wait for every worker in a group to finish. |
| `wait all [-Group <g>]` | Wait for all workers in scope. |
| `agent <id> [-Group <g>]` | Inspect one worker, including current task and state. |
| `agents [--all] [-Group <g>]` | List workers, optionally filtered by group. |
| `result <id> [-Group <g>]` | Show state summary and optional `result.md`. |
| `remove <id> [-Group <g>]` | Soft-delete one finished/failed worker. |
| `remove all [-Group <g>] [-k <id1> ...]` | Soft-delete all finished/failed in scope. |
| `role list/show/register/update/unregister` | Manage local roles. |

## Agent Groups (Multi-Project Isolation)

Groups solve the problem of running multiple projects from a single skill directory
without log noise or `wait any` cross-contamination.

```powershell
# Terminal 1 — project A
& $tui send my-coder -Role coder -Group "project-a" -Prompt "..."
& $tui wait any -Group "project-a"      # only project-a STATE messages

# Terminal 2 — project B
& $tui send my-coder -Role coder -Group "project-b" -Prompt "..."
# Both terminals can use the same short name "my-coder" —
# internally they become "project-a::my-coder" and "project-b::my-coder"
```

**Agent ID prefix**: When `-Group` is passed, the agent ID internally becomes
`"<group>::<name>"`. This means:

- `send my-coder -Group "noname"` and `send noname::my-coder` are equivalent.
- In `agent`, `result`, `wait`, `remove`, either short name + `-Group` or
  the full `group::name` can be used.
- Existing agents without a `group` field are unaffected (backward-compatible).

**Manager internals**: The manager still manages all agents globally — Sync
functions maintain full data integrity. Group filtering is a CLI-layer
gate: `-Group` silences STATE/EXIT messages from other groups, and `wait`
only considers group-matched workers.

**Wait precision**: When `wait` lists specific agent IDs, Sync-All prints
STATE/EXIT messages *only* for those IDs (not the whole group).

## Role System At A Glance

Roles are local, registered prompt/state contracts under:

```text
prompt_templates/role/<role>/
├── system_prompt/       # durable role rules
├── header_prompt/       # short task preamble
├── normal_prompt/       # explicit -InjectNormal fragments only
└── legal_state.json     # allowed states + exit confirmation
```

Current role profiles for orchestrators:

| Role | Profile |
|------|---------|
| `coder` | [docs/role-profiles/coder/README.md](docs/role-profiles/coder/README.md) |
| `explorer` | [docs/role-profiles/explorer/README.md](docs/role-profiles/explorer/README.md) |
| `test` | [docs/role-profiles/test/README.md](docs/role-profiles/test/README.md) |

Role profiles are human-facing usage notes. Prompt source files remain under
`prompt_templates/role/` and are gitignored local runtime configuration.

## Lifecycle In One Paragraph

Workers report lifecycle state with `scripts/Update-WorkerState.ps1`. The authoritative
completion signal is `.state` JSON with `state=exit` and `confirmed=true`. `result.md`
is optional convenience output. `.exit` is not part of the v2 worker protocol. See the
state and schema docs for exact fields and transitions.

## Recommended Orchestrator Pattern

1. Choose the role from [docs/role-profiles/](docs/role-profiles/).
2. Use `-p` mode unless you explicitly need an interactive TUI window.
3. Put concrete project paths, scope, accepted facts, and acceptance criteria in the
   task prompt.
4. Use `-InjectNormal` only for a known reusable fragment such as `question-pass`.
5. After completion, read `result <id>` and the relevant report/artifact.
6. Use an independent reviewer for lifecycle, protocol, persistence, or shared-contract
   changes.

## Important Safety Rules

- Do not use `remove all` in a shared manager unless you are deliberately cleaning a
  known isolated environment.
- Even `wait <specific-id>` runs global `Sync-All` internally, but with `-Group`
  active, messages are now scoped to the target group or listed IDs.
  Use `-Group` for reliable isolation and avoid `wait all` without a group filter.
- Prefer `-p` for reliable session reuse. TUI sessions killed by the manager after
  confirmed exit are not guaranteed resumable.
- Register roles before sending. `send` preflight validates `legal_state.json` and
  `-InjectNormal` existence before creating or mutating agent entries.
- Do not treat `result.md` as completion authority; use `.state`/`result <id>` state
  summary.

## Documentation Map

Start here:

| Need | Doc |
|------|-----|
| Current status, verified features, known risks | [docs/role-system-current-state.md](docs/role-system-current-state.md) |
| Pick an existing role | [docs/role-profiles/README.md](docs/role-profiles/README.md) |
| Create a new role | [docs/role-creation-guide.md](docs/role-creation-guide.md) |
| Understand role prompt layers and state model | [docs/role-system-design.md](docs/role-system-design.md) |
| Role CLI reference | [docs/roles.md](docs/roles.md) |
| `agents.json`, status tags, queue rules, Sync functions | [docs/agents-json-schema.md](docs/agents-json-schema.md) |
| Session UUID capture and resume behavior | [docs/session-uuid-lifecycle.md](docs/session-uuid-lifecycle.md) |
| Store vs run directory layout | [docs/store-vs-run.md](docs/store-vs-run.md) |
| Role-system smoke plan and prior execution | [docs/test-role-smoke-plan.md](docs/test-role-smoke-plan.md) |
| Verification and worker reports | [docs/worker-reports/](docs/worker-reports/) |

## Creating Roles

Short version:

```powershell
& $tui role register reviewer
& $tui role show reviewer
```

Then add prompt files and a profile:

```text
prompt_templates/role/reviewer/system_prompt/*.md
prompt_templates/role/reviewer/header_prompt/*.md
prompt_templates/role/reviewer/normal_prompt/*.md
prompt_templates/role/reviewer/legal_state.json
docs/role-profiles/reviewer/README.md
```

Default roles should be project-independent collaboration abstractions. Project-specific
facts belong in task prompts or, when truly reusable, explicit normal templates. If a
role is intentionally project-private, mark that clearly in its profile and description.

See [docs/role-creation-guide.md](docs/role-creation-guide.md) for the full checklist.
