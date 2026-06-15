# Role System v2 — Preflight-Before-Agent-Entry Repair Report (B6)

> **Author**: role-system-v2-coder-p
> **Date**: 2026-06-15 07:50 UTC+8
> **Verdict**: **FIXED** — All 7 verifications pass

---

## Bug: B6 — Agent entry saved before preflight rejection

| Field | Detail |
|-------|--------|
| **Observed** | Smoke report Phase 0c, 0d |
| **Symptom** | When a role or InjectNormal is rejected during `send`, the agent entry was already created in `agents.json` with `["running"]` status, no PID, no task — a zombie entry |
| **Root cause** | `Invoke-Send` (and `Invoke-SendInternal`) called `New-AgentEntry` + `Save-Agents` first, then called `_DoLaunch` which ran preflight checks. If preflight failed with `exit 1`, the agent entry was already persisted. |
| **Impact** | Zombie agent entries accumulate in `agents.json` on every rejected `send`. Manual cleanup required. |

---

## Fix Design

### Strategy

Move ALL preflight checks to a single reusable helper `Assert-SendPreflight`, called **before any manager mutation** in every `send` code path. The `_DoLaunch` function retains only a defensive side-effect-free assertion.

### Code Paths Protected

| Path | Function | Mutation Prevented | Preflight Call |
|------|----------|-------------------|----------------|
| New agent, CLI | `Invoke-Send` | `New-AgentEntry` + `Save-Agents` | Before entry creation |
| Existing finished/ready, CLI | `Invoke-Send` | `current_task` / `status` change | Before `_DoLaunch` |
| Busy agent queue, CLI | `Invoke-Send` | `pending_task` write | Inside W-branch, before assignment |
| New agent, auto-continue | `Invoke-SendInternal` | `New-AgentEntry` + `Save-Agents` | Before entry creation |
| Existing non-running, auto-continue | `Invoke-SendInternal` | `current_task` / `status` change | Before `_DoLaunch` |
| Busy agent queue, auto-continue | `Invoke-SendInternal` | `pending_task` write | Before assignment |

### Assert-SendPreflight Checks

1. **Role registration**: `legal_state.json` must exist at `prompt_templates/role/<role>/legal_state.json`
2. **Parseable JSON**: The file must be valid JSON
3. **Mandatory `running` state**: Present in `states` array
4. **Mandatory `exit` state**: Present in `states` array
5. **Exit confirmation warning**: Non-fatal warning if `exit_confirmation` is missing
6. **InjectNormal existence**: If `-InjectNormal` is specified, `normal_prompt/<name>.md` must exist and be readable

### Design Rulings Applied

- **Single helper**: One `Assert-SendPreflight` called from all paths; no logic drift between `Invoke-Send` and `Invoke-SendInternal`
- **`throw` not `exit`**: Safe for host-embedded scenarios; top-level CLI produces non-zero exit via `$ErrorActionPreference = "Stop"`
- **No mutation before preflight**: No `New-AgentEntry`, no `Save-Agents`, no run/store directory creation, no create-session lock, no process launch
- **No B7**: Not addressed
- **No resume changes**: Not addressed
- **No remove all / git commit / test/explorer role changes**: Not performed

---

## Files Changed

### `scripts/ClaudeTui.ps1`

| Change | Lines |
|--------|-------|
| **Added** `Assert-SendPreflight` function | +48 lines (before `Invoke-SendInternal`) |
| **Modified** `Invoke-Send` — new agent path: preflight before `New-AgentEntry` | +1 line |
| **Modified** `Invoke-Send` — existing finished/ready path: preflight before `_DoLaunch` | +1 line |
| **Modified** `Invoke-Send` — busy queue W-branch: preflight before `pending_task` | +1 line |
| **Modified** `Invoke-SendInternal` — new agent path: preflight before `New-AgentEntry` | +1 line |
| **Modified** `Invoke-SendInternal` — existing non-running path: preflight before `_DoLaunch` | +1 line |
| **Modified** `Invoke-SendInternal` — busy path: preflight before `pending_task` | +1 line |
| **Replaced** `_DoLaunch` inline preflight (28 lines) with defensive assertion (3 lines) | -25 lines |

### `docs/agents-json-schema.md`

Added preflight gate to lifecycle diagram.

### `SKILL.md`

Updated Rule #1 to clarify that preflight runs before any agent entry creation.

---

## Verification Results

### #1: Parser::ParseFile on ClaudeTui.ps1 — 0 errors ✅

```
PowerShell AST Parser: 0 parse errors
```

### #2: Unique agent ID + unregistered role ✅

```
$ powershell ... send preflight-test-unreg -Role unregistered-xyz -Prompt "test"
ExitCode: 1
Error: Rejected: Role 'unregistered-xyz' has no legal_state.json...
agents.json entry found: False
run/preflight-test-unreg exists: False
store/preflight-test-unreg exists: False
```

**Result**: Non-zero exit, clear error message, no agent entry, no run/store directories.

### #3: Unique agent ID + test role + non-existent InjectNormal ✅

```
$ powershell ... send preflight-test-badnormal -Role test -InjectNormal no-such-template -Prompt "test"
ExitCode: 1
Error: Rejected: Normal prompt template 'no-such-template' not found for role 'test'...
agents.json entry found: False
run/preflight-test-badnormal exists: False
store/preflight-test-badnormal exists: False
```

**Result**: Non-zero exit, clear error message, no agent entry, no run/store directories.

### #4: Valid test role + valid normal — preflight passes ✅

Function-level verification:
- `test` role: `legal_state.json` exists and parseable, states = `running, coding, debugging, reviewing, exit`
- `running` in states: True
- `exit` in states: True
- `exit_confirmation` present: Yes
- `full-cycle.md` exists and readable: Yes
- `strict-json-evidence.md` exists: True
- `powershell-probe.md` exists: True

**Result**: All preflight checks would pass for valid role + valid normal.

### #5: Existing finished/ready fixture + invalid new task — current_task/status unchanged ✅

```
Fixture: preflight-fixture-finished (status: finished,ready)
Send: invalid role (unregistered-xyz)
ExitCode: 1
After: current_task=20260615-000000-000 (unchanged), status=finished,ready (unchanged)
```

**Result**: Failed send to finished/ready agent does not alter `current_task` or `status`.

### #6: Busy fixture + invalid task — pending_task not written ✅

```
Fixture: preflight-fixture-busy (status: running, pending_task: null)
Send: invalid role (unregistered-xyz), non-interactive -> Cancel
After: pending_task=null (unchanged)
```

Code review confirms: the W-branch (queue path) in `Invoke-Send` has `Assert-SendPreflight` before `pending_task` assignment. The `Invoke-SendInternal` busy path similarly has preflight before queue write (line 614).

**Result**: Invalid task does not enter `pending_task`.

### #7: git diff --check ✅

```
No whitespace errors detected (only pre-existing CRLF warnings).
```

---

## Compliance with Controller Rulings

| Ruling | Status |
|--------|--------|
| All preflight before `New-AgentEntry` + `Save-Agents` | ✅ |
| Preflight includes: role registration, parseable JSON, mandatory running/exit, InjectNormal existence | ✅ |
| Failed preflight: no agent entry, no run/store dirs, no lock, no process | ✅ (verified #2, #3) |
| Existing finished/ready: preflight before current_task/status change | ✅ (verified #5) |
| Busy agent queue: preflight before pending_task write | ✅ (verified #6 + code review) |
| Single helper, no logic drift | ✅ `Assert-SendPreflight` used in all paths |
| `throw` not `exit` | ✅ |
| No B7, no resume, no unrelated refactoring | ✅ |
| No remove all, no git commit, no test/explorer role changes | ✅ |

---

## What Was NOT Done

- B7 (Claude --resume crash): out of scope
- Session resume refactoring: out of scope
- Any other refactoring beyond B6 fix: out of scope
- `remove all`: not performed
- `git commit`: not performed
- Modifications to `test` or `explorer` roles: not performed
- Smoke report overwrite: not performed (this is a separate report)

---

## Verdict: FIXED

B6 is resolved. Preflight now happens before any agent entry mutation in all 6 code paths. Zombie agent entries from rejected sends are eliminated.
