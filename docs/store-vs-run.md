# Store vs Run

The project separates persistent data from transient runtime.

| Directory | Purpose | Lifecycle |
|-----------|---------|-----------|
| `manager/agents.json` | Single state file — agent registry | Persistent |
| `prompt_templates/default/` | system.md, header.md — editable worker templates | Persistent |
| `prompt_templates/role/` | Registered role templates | Persistent |
| `store/<agent>/results/` | done.json, result.md | Persistent. Never auto-deleted. |
| `run/<agent>/` | runner.ps1, prompt.txt, system.txt, .<id>.state, .<id>.exit, logs/ | Transient. Safe to delete. `.state` is JSON (v2) with agent_id, command_id, role, state, confirmed, updated_at, summary_message. |
| `.claude/worker-permissions.json` | Pre-approved permissions | Persistent. |

Session UUID lives in `manager/agents.json`. The `.claude-sid.txt` in `store/<agent>/` is a runner-side convenience copy — not the canonical source.
