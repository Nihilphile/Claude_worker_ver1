# InjectNormal Boundary Repair Report

**Date:** 2026-06-15
**Agent:** role-system-v2-injectnormal-coder-p
**Scope:** Narrow — two specific issues from queue final review, no refactoring.

---

## Issue 1 (Medium): Send-ClaudeCommand.ps1 missing InjectNormal parameter and injection logic

### Root Cause

`ClaudeTui.ps1` already saved and passed `-InjectNormal` to `Send-ClaudeCommand.ps1` (via `$sendArgs['InjectNormal']`), but `Send-ClaudeCommand.ps1` did not declare the parameter at its top-level `param()` block. Consequently, PowerShell silently discarded the argument, and `Build-WorkerPrompt` never had access to the `$InjectNormal` value or attempted to load/inject the normal prompt content. The feature was silently dropped — no error, no injection.

### Changes Applied

**File:** `scripts/Send-ClaudeCommand.ps1`

#### A. Parameter Declaration (line 15)

Added `[string]$InjectNormal = ""` to the top-level `param()` block, immediately after `$Mode`:

```powershell
    [ValidateSet("p", "tui")]
    [string]$Mode = "p",
    [string]$InjectNormal = ""
)
```

This matches the parameter passed by `ClaudeTui.ps1` line ~678: `$sendArgs['InjectNormal'] = $InjectNormal`.

#### B. Build-WorkerPrompt Injection Logic (lines 243–262)

Added an `$injectBlock` computation that:
1. Gates on `if ($InjectNormal)` — zero impact when empty.
2. Constructs the path: `prompt_templates/role/$Role/normal_prompt/$InjectNormal.md`
3. **Throws** on missing file (no silent ignore): `throw "InjectNormal error: Normal prompt template '$InjectNormal' not found for role '$Role'. Expected at: $normalFile"`
4. Reads and trims the content; throws on read failure.
5. Produces a labeled injection block: `INJECTED NORMAL PROMPT: $InjectNormal (role: $Role)` followed by the raw content.

The block is placed **before** the `TASK:` line and **after** the `MANDATORY COMPLETION` block, inside the `$injectBlock` variable interpolated into the here-string. When `$InjectNormal` is empty, `$injectBlock` is an empty string and the output is identical to the pre-fix behavior.

---

## Issue 2 (Low): Agent detail does not display pending_task_error

### Root Cause

`Sync-DoneToManager` records `pending_task_error` on the agent entry when auto-continue fails (lines ~381–385 in the catch block), but `Invoke-AgentDetail` never displayed this field. The diagnostic was silently lost to operators.

### Changes Applied

**File:** `scripts/ClaudeTui.ps1`

#### A. Normalize-AgentEntry (line 219)

Added normalization of `pending_task_error`:

```powershell
    Ensure-EntryProp $Entry "pending_task_error" $null
```

Ensures the property always exists on agent entries (consistent with other fields like `current_task`, `pending_task`).

#### B. Invoke-AgentDetail Display (lines 902–906)

Added a read-only display block immediately after the `pending_task` block:

```powershell
    if ($e.PSObject.Properties["pending_task_error"] -and $e.pending_task_error) {
        Write-Host "  --- Pending Task Error ---"
        Write-Host "  $($e.pending_task_error)"
        Write-Host ""
    }
```

- **Read-only:** does not modify state.
- **No change** to `Sync-DeadToFailed`, TUI stderr logic, queue transaction paths, or role templates.
- Output only appears when a `pending_task_error` was previously recorded by the auto-continue catch handler.

---

## Test Updates

**File:** `tests/Mock-SendFixture.ps1`

Added 5 new source-invariant verification tests (Tests 15–19):

| Test | Checks |
|------|--------|
| 15 | `Send-ClaudeCommand.ps1` has top-level `[string]$InjectNormal = ""` parameter |
| 16 | `Build-WorkerPrompt` contains `INJECTED NORMAL PROMPT:` marker, constructs correct path, throws on missing file, uses `$injectBlock` |
| 17 | `Build-WorkerPrompt` gates injection behind `if ($InjectNormal)` — empty → no injection |
| 18 | `Invoke-AgentDetail` has `--- Pending Task Error ---` section header and `Write-Host` output |
| 19 | `Normalize-AgentEntry` normalizes `pending_task_error` |

All 19 tests pass (0 failures).

---

## Verification Results

### 1. Parser.ParseFile — Zero Errors

```
Send-ClaudeCommand.ps1: errors=0
ClaudeTui.ps1: errors=0
```

### 2. InjectNormal non-empty → normal prompt content injected

Verified via source-invariant test 16: marker `INJECTED NORMAL PROMPT:` is present, path constructed from `$skillRoot`, `$Role`, and `$InjectNormal`.

### 3. InjectNormal empty → no injection

Verified via source-invariant test 17: all injection logic gated behind `if ($InjectNormal)`.

### 4. Missing normal prompt → throws with clear error

Verified via source-invariant test 16: `throw "InjectNormal error: ..."` pattern present for both missing-file and read-failure cases. Preflight in `ClaudeTui.ps1` also catches this before manager mutation.

### 5. Agent detail shows pending_task_error

Verified via source-invariant test 18: `--- Pending Task Error ---` section header present in `Invoke-AgentDetail`, with `Write-Host` display of the error value.

### 6. Mock-SendFixture.ps1 — ALL PASS (19/19)

---

## Files Modified

| File | Changes |
|------|---------|
| `scripts/Send-ClaudeCommand.ps1` | +1 parameter (`InjectNormal`), +20 lines injection logic in `Build-WorkerPrompt` |
| `scripts/ClaudeTui.ps1` | +1 normalization line, +5 lines `pending_task_error` display in `Invoke-AgentDetail` |
| `tests/Mock-SendFixture.ps1` | +5 tests (15–19) for boundary repair coverage |
| `docs/worker-reports/role-system-v2-injectnormal-boundary-repair-report.md` | This report |

## Files Not Modified (per restrictions)

- `Sync-DeadToFailed` logic
- TUI stderr logic
- Queue transaction other paths
- Role templates (`prompt_templates/role/*`)
- `docs/` other reports
- `manifest.json`, `schema.json`
- No git commit performed
