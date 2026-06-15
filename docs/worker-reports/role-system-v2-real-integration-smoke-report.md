# Role System v2 — Real Integration Smoke Report

> **Author**: role-system-v2-integration-smoke-runner
> **Date**: 2026-06-15 06:35–06:50 UTC+8
> **Verdict**: **BLOCKED** (P0 blocking bugs prevent send-based integration test)

---

## Environment

| Item | Value |
|------|-------|
| Target runtime | `F:\AI_project\Claude_worker_ver2` |
| PowerShell | 7.6.2 |
| Claude CLI | Available (WinGet path) |
| Target ver2 commit | `7665419` Switch license from MIT to GPLv3 |
| Working tree | Dirty (11 modified, 4 untracked — expected from prior repair/cleanup sessions) |

### Git status (start & end)

```
 M .gitignore
 M README.md
 M SKILL.md
 M docs/agents-json-schema.md
 M docs/roles.md
 M docs/store-vs-run.md
 M manifest.json
 M prompt_templates/default/system.md
 M scripts/ClaudeTui.ps1
 M scripts/Complete-ClaudeTask.ps1
 M scripts/Send-ClaudeCommand.ps1
?? docs/role-system-design.md
?? docs/worker-reports/
?? scripts/Update-WorkerState.ps1
```

No unexpected source changes detected. All runtime test artifacts cleaned up.

---

## Documents Consulted

| Document | Purpose |
|----------|---------|
| `SKILL.md` (re-read, updated version) | v2 usage reference, minimal send+wait path |
| `docs/role-system-design.md` | Authoritative v2 design |
| `docs/roles.md` | Role CLI reference |
| `docs/agents-json-schema.md` | agents.json schema & lifecycle |
| `docs/worker-reports/role-system-v2-upgrade-repair-1-review-report.md` | Prior review findings |
| `docs/worker-reports/role-system-v2-upgrade-cleanup-1-report.md` | Cleanup session results |

---

## Step-by-Step Results

### Step 1: `role register integration-smoke-v2` — PASS

```
[MANAGER] Role 'integration-smoke-v2' registered (v2 structure)
  Directories: system_prompt/, header_prompt/, normal_prompt/
  legal_state.json: ...\prompt_templates\role\integration-smoke-v2\legal_state.json
  States: running, exit
```

**Verify**: Directory structure created correctly with all four items.

### Step 1b: Verify v2 structure — PASS (with bug note)

```
prompt_templates/role/integration-smoke-v2/
├── system_prompt/       ✓
├── header_prompt/       ✓
├── normal_prompt/       ✓
└── legal_state.json     ✓ (states: running, exit)
```

**Bug note (LOW)**: The `legal_state.json` written by `role register` has a UTF-8 BOM (`EF BB BF`). When read via `git bash cat`, the Chinese `exit_confirmation` text displays garbled. Content is correct when read with proper UTF-8 handling — display artifact only, not data corruption.

### Step 2: Write role prompt files — PASS

Wrote `system_prompt/smoke-rules.md` (683 bytes) and `header_prompt/smoke-header.md` (162 bytes). Verified with `role show` displaying correct file listings.

### Step 3: `role list` and `role show` — PASS

Both display correct information. `role list` shows structure=v2, states=running,exit. `role show` displays legal_state.json, file listings, available templates.

### Step 4: `send` command — **BLOCKED (P0)**

```
[MANAGER] Preflight OK: Role 'integration-smoke-v2' legal states: running, exit
[MANAGER] Acquiring create-session lock...
[MANAGER] Create-session lock acquired
[LAUNCH] v2-lifecycle-smoke-20260615 role=integration-smoke-v2 session= new=True
[MANAGER] Released create-session lock
At ...\Send-ClaudeCommand.ps1:262 char:53
Unexpected token 'exit_confirmation" -and $legalJson.exit_confirmation) {
...
```

**Root cause**: In `Send-ClaudeCommand.ps1`, `Build-SystemPrompt` function, line 261:
```
$sys += "```"
```

The string `"```"` (double-quoted triple backtick) fails PowerShell parsing. In double-quoted strings, `` ` `` is the escape character. `"```"` tokenizes as:
1. `"` — open string
2. `` ` `` + `` ` `` → `` `` `` → escaped backtick (literal `` ` ``)
3. `` ` `` + `"` → escaped double-quote (`"` treated as literal inside string)
4. String is unterminated — no closing `"`

Fix: Use single-quoted `'```'` or double-escape: `"``````"`.

**Severity**: P0 — blocks ALL `send` operations. The system is unusable.

This is the root cause of the 43 parser warnings in re-review finding N-4, which was incorrectly classified as "false-positive, confirmed non-runtime."

### Step 4b: Second P0 bug — `--exit` positional syntax fails

Worker templates instruct workers to use:
```
powershell ... -File Update-WorkerState.ps1 ... --exit
```

This fails:
```
A parameter cannot be found that matches parameter name '-exit'.
```

PowerShell `-File` invocation interprets `--exit` as a named parameter. Correct syntax: `-State "--exit"`.

**Affected files** (3 locations):
1. `prompt_templates/default/system.md` — multiple examples
2. `Send-ClaudeCommand.ps1` Build-WorkerPrompt (lines 332-334)
3. `Update-WorkerState.ps1` exit_confirmation message (line 112)

**Severity**: P0 — if B1 is fixed, workers would still fail at the first Update-WorkerState call.

### Step 5: Update-WorkerState.ps1 direct testing — PASS

Using correct syntax (`-State "--<state>"`), tested all lifecycle phases:

#### 5a: `--running` — PASS
```
[CLAUDE_WORKER_STATE] 20260615-test-001 state=running confirmed=False
```
State file written as valid JSON with all required fields.

#### 5b: `--exit` (without `-Confirm`) — PASS
```
================================================
  EXIT CONFIRMATION REQUIRED
================================================
  你确认已经完整执行主控要求的结束流程，并留下主控可验收的结果或证据了吗？

  To confirm exit and write the exit state, run:
    powershell -File Update-WorkerState.ps1 ... --exit -Confirm
================================================
```
State file UNCHANGED (still `running`). Confirmation correctly displayed. Note: the confirmation prompt itself uses the buggy `--exit` syntax.

#### 5c: `--exit -Confirm -SummaryMessage` — PASS
```
[CLAUDE_WORKER_STATE] 20260615-test-001 state=exit confirmed=True
```
State updated to `exit, confirmed=true` with summary_message.

#### 5d: State JSON validation — PASS
```json
{
    "agent_id": "test-direct-smoke",
    "command_id": "20260615-test-001",
    "role": "integration-smoke-v2",
    "state": "exit",
    "confirmed": true,
    "updated_at": "2026-06-15T06:47:03.6658664+08:00",
    "summary_message": "Smoke test passed: running->exit confirmation gate verified."
}
```
All required fields present. Valid, parseable JSON.

#### 5e: No `.exit` file — PASS
Verified: `.exit` file does NOT exist after `--exit -Confirm`. v2 relies on `.state` JSON only.

#### 5f: Illegal state error — PASS
```
Illegal state 'illegal_state'. Legal states for role 'integration-smoke-v2': running, exit
```
Hard error. No file written.

#### 5g: Role mismatch / missing legal_state.json — PASS
```
Role 'wrong-role' has no legal_state.json at '...'
```
Hard error.

---

## Verification Checklist

| # | Item | Result | Evidence |
|---|------|--------|----------|
| 1 | `role register` creates v2 structure | **PASS** | 4 items created |
| 2 | legal_state.json correct defaults | **PASS** | states=running,exit; exit_confirmation present |
| 3 | role prompt file injection | **PASS** | role show displays file listings |
| 4 | `send` with v2 role + `-Mode p` | **BLOCKED** | P0 parser bug B1 |
| 5a | `--running` writes JSON state | **PASS** | Valid .state JSON |
| 5b | `--exit` no Confirm = confirmation only | **PASS** | State unchanged |
| 5c | `--exit -Confirm` = exit state | **PASS** | state=exit, confirmed=true |
| 5d | No `.exit` file | **PASS** | No .exit created |
| 5e | Illegal state = hard error | **PASS** | Error + legal list |
| 5f | Missing role = hard error | **PASS** | Error |
| 6 | Agent lifecycle (run→finish→ready) | **NOT OBSERVED** | Blocked by B1 |
| 7 | `result` reads .state JSON | **NOT OBSERVED** | Blocked |
| 8 | `wait` / `agent` commands | **NOT OBSERVED** | Blocked |
| 9 | Session UUID capture | **NOT OBSERVED** | Blocked |
| 10 | Session reuse / resume | **NOT OBSERVED** | Blocked |
| 11 | Missing result.md = not error | **NOT OBSERVED** | Blocked (template says "Optional") |
| 12 | `agents` listing | **PARTIAL** | Works clean; crash on zombie entries (B3) |

---

## Bugs Found

### B1 (P0): Send-ClaudeCommand.ps1 L261 — `"```"` parse error

| Field | Detail |
|-------|--------|
| **File** | `scripts/Send-ClaudeCommand.ps1:261` |
| **Code** | `$sys += "```"` |
| **Root cause** | `` ` `` escapes closing `"` → unterminated string |
| **Fix** | `$sys += '```'` (single quotes) or `"``````"` |
| **Impact** | ALL `send` commands fail |
| **Repro** | `[ScriptBlock]::Create('$x = "```"')` |
| **Related** | Root cause of re-review N-4 (43 parser warnings, misclassified as false-positive) |

### B2 (P0): `--exit` positional syntax incompatible with `powershell.exe -File`

| Field | Detail |
|-------|--------|
| **Files** | `system.md`, `Send-ClaudeCommand.ps1:332-334`, `Update-WorkerState.ps1:112` |
| **Root cause** | `--exit` treated as named parameter in `-File` context |
| **Fix** | Use `-State "--exit"` not positional `--exit` |
| **Impact** | Even after B1 is fixed, workers will fail on first Update-WorkerState call |

### B3 (LOW): `agents` listing crashes on missing `current_state`

| Field | Detail |
|-------|--------|
| **File** | `scripts/ClaudeTui.ps1:786` |
| **Code** | `if ($e.current_state)` — no `PSObject.Properties` guard |
| **Fix** | Guard with `$e.PSObject.Properties["current_state"]` |

### B4 (LOW): `agent <id>` crashes on missing `current_state`

| Field | Detail |
|-------|--------|
| **File** | `scripts/ClaudeTui.ps1:815` |
| **Code** | Same pattern as B3 |
| **Fix** | Same as B3 |

### B5 (LOW): Zombie agent entries block operations

Prior test sessions left agents with `["running"]` status, null PID, no state file. These are never auto-cleaned. Required manual `agents.json` editing.

---

## Was result.md Produced?

No. `send` could not be launched.

## Was .exit Produced?

No. Update-WorkerState.ps1 correctly does NOT create `.exit` files (verified via direct test).

## Cleanup Status

| Item | Status |
|------|--------|
| `integration-smoke-v2` role | Unregistered ✓ |
| `manager/config.json` (temp) | Removed ✓ |
| `temp_workspace/` | Removed ✓ |
| Temp test files | Removed ✓ |
| `run/test-direct-smoke/` | Removed ✓ |
| Zombie agents from agents.json | Removed ✓ |
| Pre-existing run/store artifacts | Left (not mine) |

---

## Timeline

| Time (UTC+8) | Event |
|------|-------|
| 06:34 | Start, record git status |
| 06:35 | Read all design docs, reviews |
| 06:35 | `role register integration-smoke-v2` — PASS |
| 06:36 | Verify v2 structure |
| 06:37 | Write role prompt files, role list/show |
| 06:39 | `send` attempt — P0 BLOCKER discovered |
| 06:42 | Isolated B1 root cause (`"```"` parse error) |
| 06:43 | Discovered B2 (`--exit` positional syntax) |
| 06:44 | Discovered B3/B4 (current_state property) |
| 06:45 | Cleaned zombie agents |
| 06:46 | Update-WorkerState --running — PASS |
| 06:47 | Exit gate: --exit (no Confirm) — PASS |
| 06:47 | Exit gate: --exit -Confirm — PASS |
| 06:48 | Illegal state, role mismatch — PASS |
| 06:49 | .state JSON, no .exit — PASS |
| 06:50 | Cleanup + final git status |
| 06:51 | Report writing |

---

## Next Steps

### Immediate (unblock)

1. **Fix B1**: Change `"```"` to `'```'` at `scripts/Send-ClaudeCommand.ps1:261`. One-character fix.
2. **Fix B2**: Update all worker-facing docs/templates to use `-State "--exit"` instead of positional `--exit`. Affects 3 locations.

### After fixes, re-run full smoke

3. `send` → `wait` → `result` with a real Claude worker (`-p` mode)
4. Verify Sync-ReadState detects exit+confirmed → finishing → 5s grace → finished/ready
5. Verify session UUID capture and resume
6. Verify missing result.md is handled correctly

### Medium term

7. Fix B3/B4: `PSObject.Properties` guards for `current_state`
8. Fix B5: Auto-cleanup of zombie agent entries

### Note for re-review

The prior re-review classified N-4 (43 parser warnings) as "false-positive, confirmed non-runtime." This was incorrect — the parse error IS a real runtime blocker. Future reviews should complement `Get-Command` with `[ScriptBlock]::Create()` for script validation.
