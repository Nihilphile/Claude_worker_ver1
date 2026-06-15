# Role System v2 — Smoke Blocker Repair Report

> **Author**: role-system-v2-coder-tui
> **Date**: 2026-06-15
> **Scope**: Repair P0 blocking bugs (B1, B2) and LOW bugs (B3, B4) from real integration smoke.

---

## Based On

| Source | Purpose |
|--------|---------|
| `docs/worker-reports/role-system-v2-real-integration-smoke-report.md` | Smoke findings: B1, B2, B3, B4, B5 |
| `docs/role-system-design.md` | Master design (authoritative) |
| `SKILL.md` | v2 usage reference |
| `scripts/Send-ClaudeCommand.ps1` | B1 location + prompt builder |
| `scripts/Update-WorkerState.ps1` | B2 location — rewritten |
| `scripts/ClaudeTui.ps1` | B3/B4 location |
| `prompt_templates/default/system.md` | Worker-facing state API documentation |

---

## Files Changed

| File | Bug | Change |
|------|-----|--------|
| `scripts/Send-ClaudeCommand.ps1` L261 | **B1** | `$sys += "``` ` "` → `$sys += '``` '` (single quotes). Eliminates PowerShell escape-chain parse error. |
| `scripts/Update-WorkerState.ps1` | **B2** | Complete rewrite (141 → 193 lines). Removed formal `param()` block. Manual `$args` parsing supporting `--<legal-state>` syntax through `powershell.exe -File`. |
| `scripts/ClaudeTui.ps1` L786 | **B3** | Added `$e.PSObject.Properties["current_state"] -and` guard before `$e.current_state` in `Invoke-Agents` display. |
| `scripts/ClaudeTui.ps1` L815 | **B4** | Same guard pattern added to `Invoke-AgentDetail` display. |

### Documents NOT modified

All active docs/templates (system.md, SKILL.md, role-system-design.md, roles.md, role-creation-guide.md, Build-WorkerPrompt, Build-SystemPrompt) already use `--<state>` syntax. No changes needed.

---

## B1 Closure — `"```"` parse error

**Root cause**: In `Build-SystemPrompt`, line 261: `$sys += "``` " ` — in a double-quoted string, the backtick is PowerShell's escape character, so `"```"`  tokenizes as:
1. `"` — open string
2. `` ` `` + `` ` `` → escaped backtick (literal `` ` ``)
3. `` ` `` + `"` → escaped double-quote (literal `"` in string)
4. String unterminated — no closing `"`

**Fix**: `$sys += '```'` — single-quoted string. Backticks are literal in single quotes.

**Verification**:
- `[Parser]::ParseFile` on Send-ClaudeCommand.ps1: **0 errors** (was 43 errors before)
- `Get-Command`: PASS

---

## B2 Closure — `--exit` positional syntax

**Root cause**: PowerShell's `-File` invocation treats leading dashes as named parameters. `--exit` gets parsed as `-exit` which doesn't match any declared parameter.

**Master design**: Orchestrator ruled to keep `--<legal-state>` as the only worker-facing syntax. The fix must allow `--running --exit` to pass through `powershell.exe -File` without PowerShell binding interference.

**Fix**: Removed the formal `param()` block entirely. The script parses `$args` manually:

| Feature | Implementation |
|---------|---------------|
| `-AgentName <v>` | Consumes next token as value (case-insensitive) |
| `-CommandId <v>` | Consumes next token as value |
| `-Role <v>` | Consumes next token as value |
| `-Confirm` | Boolean flag |
| `-SummaryMessage <v>` | Consumes next token as value (even if dash-prefixed) |
| `--<state>` | Strips `--` prefix, stored as state name |
| `-State <v>` | Hard error with `--<legal-state>` usage message |
| Unknown params | Hard error listing allowed params |
| Duplicate/missing params | Hard error with specific message |

All existing semantics preserved: role mismatch check, legal_state.json validation, exit confirmation gate, JSON state write, no `.exit` signal.

**Verification** (all via `powershell.exe -File`):

| # | Test | Result | Exit |
|---|------|--------|------|
| 1 | `--running` | JSON state written, confirmed=false | 0 |
| 2 | `-State --running` | "v2 does not use -State. Use --<legal-state>" | 1 |
| 3 | `--invalid_state` | "Illegal state 'invalid_state'. Legal: running, exit" | 1 |
| 4 | No state | "Missing state argument" | 1 |
| 5 | Two `--state` | "Multiple state arguments" | 1 |
| 6 | Unknown `-Flag` | "Unknown parameter(s)" | 1 |
| 7 | Missing `-Role` value | "-Role requires a value" | 1 |
| 8 | `--exit` (no Confirm) | EXIT CONFIRMATION REQUIRED checklist | 0 |
| 9 | `--exit -Confirm` | state=exit, confirmed=true | 0 |
| 10 | `.exit` after `--exit -Confirm` | Not created | — |
| 11 | Role mismatch | "Role mismatch: task=integration-smoke-v2, called=wrong-role" | 1 |
| 12 | `-SummaryMessage --dash-text` | Stored as "`--dash-text`" in JSON | 0 |

---

## B3/B4 Closure — `current_state` property guard

**Root cause**: Old agent entries in `agents.json` lack the `current_state` property. Accessing `$e.current_state` on a PSObject without this property works in some contexts (returns `$null`) but can trigger `PropertyNotFoundException` in strict mode or on certain PowerShell versions.

**Fix**: Guard pattern: `$e.PSObject.Properties["current_state"] -and $e.current_state`

| Case | `PSObject.Properties["current_state"]` | `-and $e.current_state` | Result |
|------|---------------------------------------|------------------------|--------|
| Property missing | `$null` (falsy) | short-circuits | `"-"` |
| Property present, value `$null` | truthy | `$null` (falsy) | `"-"` |
| Property present, value "running" | truthy | "running" (truthy) | "running" |

Applied at: `Invoke-Agents` L786 (B3) and `Invoke-AgentDetail` L815 (B4).

---

## B5 — Zombie agents (NOT FIXED, documented residual)

Agents with `["running"]` status, `null` PID, and no `.state` file are never auto-cleaned. Per master directive, no auto-cleanup timeout strategy is added in this repair. The smoker manually edited `agents.json` to remove zombies.

**Residual risk**: After a crash or kill, stale `["running"]` entries persist and block `remove`/re-send for that agent_id. Orchestrators must manually clean `agents.json` or use a different agent_id.

---

## Parser Verification

| Script | Parser::ParseFile | Get-Command |
|--------|------------------|-------------|
| `Update-WorkerState.ps1` | **0 errors** | PASS |
| `Send-ClaudeCommand.ps1` | **0 errors** | PASS |
| `ClaudeTui.ps1` | **0 errors** | PASS |

---

## Syntax Consistency Check

All active docs/templates verified to use `--<state>` syntax (NOT `-State`):

- `prompt_templates/default/system.md` — `--running`, `--exit`, `--exit -Confirm` ✓
- `scripts/Send-ClaudeCommand.ps1` Build-WorkerPrompt L332-335 — `--exit`, `--exit -Confirm` ✓
- `scripts/Send-ClaudeCommand.ps1` Build-SystemPrompt L258-261 — `--<state>` ✓
- `scripts/Update-WorkerState.ps1` exit confirmation L109-110 — `--exit -Confirm` ✓
- `SKILL.md` — `--running`, `--exit`, `--exit -Confirm` ✓
- `docs/role-system-design.md` — `--running`, `--exit`, `--exit -Confirm` ✓
- `docs/roles.md` — no direct Update-WorkerState examples ✓
- `docs/role-creation-guide.md` — `--exit`, `--exit -Confirm` ✓
- Historical worker-reports — contain `-State` but are excluded per task boundary ✓

---

## Git diff --check

Clean. Only pre-existing LF→CRLF normalization warnings (SKILL.md, docs/roles.md, scripts/ClaudeTui.ps1).

---

## Next Steps for Smoker

After this repair, re-run the blocked integration tests:

1. **`send` with v2 role** — should now launch without B1 parse error
2. **Worker calls `Update-WorkerState --running`** — should write JSON via `powershell.exe -File` (without B2 positional failure)
3. **`--exit` → `--exit -Confirm` gate** — re-verify end-to-end
4. **`wait` → `result`** — verify Sync-ReadState detects exit+confirmed
5. **`agents`/`agent`** — verify no crash on old entries without `current_state`
6. **Session UUID capture + resume** — verify full lifecycle
7. **Missing result.md handling** — verify `result` command shows state summary gracefully

### Items NOT yet observed

The smoker report listed items 6-12 as NOT OBSERVED. B1 and B2 were the blockers. After this repair, all items should be testable.
