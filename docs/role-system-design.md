# Role System Design (v2)

## Directory Structure

```
prompt_templates/
├── default/
│   └── system.md                        ← State system user manual (how to use Update-WorkerState)
│                                         ← NO engineering rules, no safety constraints
│                                         ← Injected to --system-prompt-file (Layer 1)
│
└── role/
    └── <role-name>/                     ← Created by `role register <name>`
        ├── system_prompt/               ← Injected to --system-prompt-file (Layer 1, compression-resistant)
        │   └── (orchestrator manually adds .md files)
        ├── header_prompt/               ← Injected to task prompt header (Layer 3, per-turn)
        │   └── (orchestrator manually adds .md files)
        ├── normal_prompt/               ← Injected to task prompt body (Layer 3, per-turn)
        │   └── (orchestrator manually adds .md files)
        └── legal_state.json             ← {"states": ["exit","running"]}
```

## Injection Rules (fixed, not configurable)

| Folder | Injection Target | Purpose |
|-------|-----------------|---------|
| `system_prompt/` | `--system-prompt-file` (Claude CLI) | Workflow rules, role-specific constraints. Never compressed. |
| `header_prompt/` | Task prompt preamble | Added before the task every turn. Typically contains role persona line. |
| `normal_prompt/` | Task prompt body | Appended to the task prompt content. |

Injection order for `--system-prompt-file`: `default/system.md` first, then all files from `role/<name>/system_prompt/` concatenated.

## `role register` — What It Does

```
role register tdd-coder
```

1. Check for name conflict — if exists, show existing info and refuse (unless `-Force`)
2. Create `prompt_templates/role/tdd-coder/`
3. Create empty `system_prompt/`, `header_prompt/`, `normal_prompt/` subdirectories
4. Write default `legal_state.json`: `{"states": ["exit","running"]}`
5. Record entry in `prompt_templates/roles.json`

**No file copying.** Orchestrator manually places `.md` files into the three folders after registration.

## `legal_state.json` — Hard Safety Gate

```
{"states": ["exit","running","read","implement","test"]}
```

- `"exit"` and `"running"` are **mandatory**. If either is missing, `send` is **rejected before launch**.
- Orchestrator can add any additional states freely.
- `Update-WorkerState.ps1` uses this file at runtime to validate state transitions (warn, not block).

## Update-WorkerState.ps1

```
powershell -File Update-WorkerState.ps1 -AgentName "agent" -CommandId "id" -State "<state>"
```

- Writes `run/<agent>/.<command_id>.state` with content: `state: <state>\ntime: <iso-timestamp>`
- If `-State "exit"`: also writes `.exit` signal for backward compatibility with Sync-KillPending
- Does NOT write result.md or done.json — it is a progress tracker only
- Sets `-State "exit"` blocks and reminds worker: "Did you remember to write result.md?"

## Manager Sync-ReadState

- Runs first in `Sync-All` (before Sync-KillPending, Sync-DoneToManager, Sync-DeadToFailed)
- Reads `run/<agent>/.<command_id>.state` for each running agent
- If state changed → updates `agents.json.current_state` → prints `[STATE] agent: old -> new`
- If state is new and not in legal_state.json → prints WARNING but does NOT block/kill

## Display (`agents` command)

```
Agent ID   Worker State   State          Output State   Session UUID
coder-a    running        implementing   none           ...
coder-b    running        fixing_bug     none           ...
rev-a      finished       exit           ready          ...
```

- `State` column from `agents.json.current_state` (updated by Sync-ReadState)
- `Worker State` and `Output State` columns unchanged from before

## Upgrade Path

| Component | Current (v1) | Target (v2) | Status |
|-----------|-------------|-------------|--------|
| Role templates location | `prompt_templates/role/<name>/` (flat) | `role/<name>/{system_prompt,header_prompt,normal_prompt}/` | Not started |
| `role register` behavior | Copies files from `-Files` parameter | Creates empty structure, no file copy | Not started |
| `legal_state.json` | N/A | New mandatory file | Not started |
| `send` preflight check | None | Rejects if `exit`/`running` missing from legal_state | Not started |
| `default/system.md` content | Worker contract + safety rules | State system manual only | Not started |
| `Update-WorkerState.ps1` | Just `.state` file writer | Add "exit" guard + result reminder | Partial |
| `Build-SystemPrompt` injection | Flat file + inline state tracking | Folder-based (`system_prompt/`, `header_prompt/`, `normal_prompt/`) | Not started |
| `Sync-ReadState` | Implemented | No changes needed | Done |
| `agents` display with State column | Implemented | No changes needed | Done |
