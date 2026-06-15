# Role System v2 — Queue Transaction Repair Report (B6 M1/M2)

> **Author**: role-system-v2-queue-transaction-coder-p
> **Date**: 2026-06-15 08:10 UTC+8
> **Verdict**: **FIXED** — All 10 fixture verifications pass; AST 0 errors; git diff --check clean

---

## Context

This repair addresses two categories of reviewer findings against the B6 preflight repair:

- **M1 — InjectNormal queue preservation**: `InjectNormal` was not carried through the queuing and auto-continue chain.
- **M2 — Launch transaction / zombie reduction**: The new-agent code path still saved `agents.json` before `_DoLaunch` succeeded, allowing zombie entries if launch failed. Additionally, `_DoLaunch` used `exit` instead of `throw` for error handling.

### Scope (per controller ruling)

| Item | Status |
|------|--------|
| InjectNormal explicit across all send paths | Done |
| pending_task schema includes inject_normal | Done |
| Sync-DoneToManager auto-continue preserves InjectNormal | Done |
| _DoLaunch explicit InjectNormal param (no global read) | Done |
| current_task records inject_normal for diagnostics | Done |
| Assert-SendPreflight validates real InjectNormal for queued/auto-continue | Done |
| New agent path: no Save-Agents before launch success | Done |
| Existing entry: no mutation before launch success | Done |
| _DoLaunch: throw instead of exit | Done |
| Atomic Save-Agents on success | Done |
| No B7/TUI runner changes | Complied |
| No remove all, no git commit, no test/explorer role mods | Complied |
| No real Claude launched | Static + fixture only |

---

## A. InjectNormal Queue Preservation (M1)

### A1. Invoke-SendInternal gains explicit -InjectNormal parameter

Before:
```powershell
function Invoke-SendInternal {
    param(
        [string]$AgentId,
        [string]$Prompt,
        [string]$Role = "explorer",
        [string]$Model = ""
    )
```

After:
```powershell
function Invoke-SendInternal {
    param(
        [string]$AgentId,
        [string]$Prompt,
        [string]$Role = "explorer",
        [string]$Model = "",
        [string]$InjectNormal = ""
    )
```

Default value "" ensures backward compatibility.

### A2. pending_task schema gains inject_normal field

Invoke-SendInternal busy path and Invoke-Send W-branch both now include:
```powershell
inject_normal = if ($InjectNormal) { $InjectNormal } else { "" }
```

### A3. Sync-DoneToManager reads inject_normal from pending_task

```powershell
$pendingInjectNormal = if ($pending.PSObject.Properties["inject_normal"] -and $pending.inject_normal) { $pending.inject_normal } else { "" }
Invoke-SendInternal -AgentId $as.entry.agent_id -Prompt $pending.prompt -Role $pending.role -Model $pending.model -InjectNormal $pendingInjectNormal
```

Uses PSObject.Properties check for backward compatibility.

### A4. _DoLaunch gains explicit $InjectNormal parameter

Parameter list changed from `param($AgentId, $Entry, $Prompt, $Role, $Model)` to `param($AgentId, $Entry, $Prompt, $Role, $Model, $InjectNormal)`. No longer reads the script-level global.

### A5. All _DoLaunch call sites pass -InjectNormal explicitly

4 call sites, all confirmed via static verification.

### A6. current_task records inject_normal for diagnostics

```powershell
inject_normal = if ($InjectNormal) { $InjectNormal } else { "" }
```

### A7. Preflight validates real InjectNormal

Invoke-SendInternal passes `$InjectNormal` (not hardcoded "") to Assert-SendPreflight.

---

## B. Launch Transaction / Zombie Reduction (M2)

### B1. New agent path: no persistence before launch success

Removed `Save-Agents` from before `_DoLaunch` in both Invoke-Send and Invoke-SendInternal new-agent paths. Entry held in-memory only; persisted atomically inside _DoLaunch after successful launch summary parse.

### B2. Existing entry: no mutation before launch success

Existing-entry paths do not call Save-Agents before _DoLaunch. current_task and status are only set after launch success.

### B3. _DoLaunch: throw instead of exit

- Send-ClaudeCommand non-zero exit: `throw "Send-ClaudeCommand failed with exit code $LASTEXITCODE"`
- JSON parse failure: `throw "Failed to parse launch JSON from Send-ClaudeCommand output"`

### B4. Atomic save on success

status, pid, current_task, session_uuid all set in one block, then single Save-Agents.

### B5. Orphan window (documented)

If Send-ClaudeCommand starts a process but launch JSON is unparseable, the process is orphaned. Minimal window; no big refactoring.

---

## Files Changed

| File | Change Summary |
|------|---------------|
| scripts/ClaudeTui.ps1 | 11 targeted edits |
| docs/agents-json-schema.md | Schema + Transaction Rules + InjectNormal Queue Preservation |
| tests/Mock-SendFixture.ps1 | New: 10 static verification tests |
| tests/mock-fail-nonzero.ps1 | New: mock Send-ClaudeCommand exit 1 |
| tests/mock-fail-parse.ps1 | New: mock Send-ClaudeCommand non-JSON output |
| tests/mock-success.ps1 | New: mock Send-ClaudeCommand valid JSON |

---

## Verification Results

### #1: PowerShell AST Parser — 0 errors

### #2: git diff --check — clean (CRLF warnings only, pre-existing)

### #3-#10: Static/Fixture Verification — ALL PASS

| # | Test | Result |
|---|------|--------|
| 1 | Invoke-Send new agent: no Save-Agents before _DoLaunch | PASS |
| 2 | Invoke-SendInternal new agent: no Save-Agents before _DoLaunch | PASS |
| 3 | _DoLaunch uses throw (not exit) for failures | PASS |
| 4 | _DoLaunch single atomic Save-Agents | PASS |
| 5 | pending_task preserves inject_normal | PASS |
| 6 | Sync-DoneToManager reads/passes inject_normal | PASS |
| 7 | No-normal pending task backward compat | PASS |
| 8 | Explicit InjectNormal parameter flow (4 _DoLaunch calls) | PASS |
| 9 | current_task records inject_normal | PASS |
| 10 | agents-json-schema.md synchronized | PASS |

---

## Compliance with Acceptance Criteria

| # | Criterion | Status |
|---|-----------|--------|
| 1 | AST 0 errors; git diff --check | PASS |
| 2 | New agent launch failure: no entry persisted | PASS |
| 3 | Existing entry launch failure: current_task/status unchanged | PASS |
| 4 | Busy W path pending_task preserves inject_normal | PASS |
| 5 | Auto-continue: inject_normal flows preflight to _DoLaunch | PASS |
| 6 | No-normal pending task still works | PASS |
| 7 | Docs schema/flow synchronized | PASS |
| 8 | No real Claude; mock isolated | PASS |

---

## What Was NOT Done

- B7 (Claude --resume crash): out of scope
- TUI runner changes: out of scope
- remove all: not performed
- git commit: not performed
- test/explorer role modifications: not performed
- Big refactoring of orphan process: documented only

---

## Verdict: FIXED

M1 (InjectNormal queue preservation) and M2 (launch transaction / zombie reduction) are resolved. All 10 fixture verifications pass. Zero AST parse errors. Git diff clean.