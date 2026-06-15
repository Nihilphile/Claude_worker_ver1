# Role System v2 Upgrade Planning Report

> **Author**: role-system-v2-planner-tui (read-only explorer)
> **Date**: 2026-06-15
> **Scope**: Explorer Claude_worker_ver2 workspace against design document. No code changes made.

---

## Based On

| File | Lines | Purpose |
|------|-------|---------|
| docs/role-system-design.md | full(1-100) | v2 design baseline |
| README.md | full(1-89) | Architecture overview |
| SKILL.md | full(1-141) | CLI command reference |
| docs/agents-json-schema.md | full(1-62) | agents.json schema, Sync ordering |
| docs/roles.md | full(1-57) | v1 role system docs |
| docs/store-vs-run.md | full(1-15) | Persistent vs transient paths |
| scripts/ClaudeTui.ps1 | full(1-1162) | Manager CLI, role commands, Sync-ReadState |
| scripts/Send-ClaudeCommand.ps1 | full(1-662) | Worker launcher, Build-SystemPrompt, Build-WorkerPrompt |
| scripts/Update-WorkerState.ps1 | full(1-42) | State file writer |
| scripts/Complete-ClaudeTask.ps1 | full(1-183) | TUI completion handler, .exit writer |
| prompt_templates/default/system.md | full(1-14) | v1 worker contract |
| prompt_templates/default/header.md | full(1-3) | v1 header template |
| prompt_templates/roles.json | full | Current role registry (1 role: test-v2) |
| prompt_templates/role/ | dir scan | 3 roles: tdd-coder, test-r, test-v2 (all flat) |
| manager/agents.json | query | 3 agents: st_test, code_test, chain_test |

---

## Confirmed Current Implementation

### 1. role register - v1 flat file copy (conflicts with v2 direction)

**Evidence**: ClaudeTui.ps1 L976-L1032 (Invoke-RoleRegister)

- **Forces -Files parameter** (L980): `if (-not $Files -or $Files.Count -eq 0) { throw "Missing -Files." }` - v2 requires register with no -Files.
- **Copies files to flat directory** (L1003-L1008): Remove-Item then Copy-Item per file; does NOT create system_prompt/ header_prompt/ normal_prompt/ subdirectories.
- **State source = -StateFile** (L1011-L1018): Reads StateFile lines as state list. No legal_state.json.
- **State storage = roles.json states array** (L1026): Not legal_state.json file.
- **Default state = exit only** (L1011): $states = @("exit"). v2 requires at minimum running + exit.
- **-Force overwrites** (L984-L993): Retention-compatible with v2.

### 2. role update - same flat copy pattern

**Evidence**: ClaudeTui.ps1 L1034-L1072 (Invoke-RoleUpdate)

- Same -Files enforcement, flat copy, -StateFile approach.
- v2 design does not explicitly define role update behavior; inference: needs adaptation.

### 3. role show - reads states from roles.json

**Evidence**: ClaudeTui.ps1 L1088-L1116

- L1100: reads `$r.states` from roles.json, not from legal_state.json.

### 4. role unregister - deletes flat dir + roles.json entry

**Evidence**: ClaudeTui.ps1 L1118-L1128

- L1126: Remove-Item whole flat role directory. Path calculation compatible with v2 subdir structure.

### 5. Prompt injection on send - all into user prompt body

**Evidence**: ClaudeTui.ps1 L519-L529 (inside _DoLaunch)

- L520: $roleTmpl = Get-RoleTemplateContent -RoleName $Role
- L522: ALL role templates concatenated into user prompt body, NOT layered into system/header/normal.
- L527: RoleStates passed to Send-ClaudeCommand for state tracking paragraph only.

**Get-RoleTemplateContent** (L279-L294): Reads all templates from flat dir, concatenates single string. No system/header/normal distinction.

### 6. Build-SystemPrompt - only default/system.md + state tracking

**Evidence**: Send-ClaudeCommand.ps1 L225-L242

- L226-L228: Reads only prompt_templates/default/system.md.
- L233-L238: If $RoleStates non-empty, appends State Tracking section with Update-WorkerState example.
- Does NOT inject any role-specific system_prompt/ files.
- --system-prompt-file = default/system.md + state tracking only, not v2 concatenation order.

### 7. Build-WorkerPrompt - only default/header.md

**Evidence**: Send-ClaudeCommand.ps1 L244-L265

- L246-L253: Reads only prompt_templates/default/header.md, replaces ~~ROLE~~.
- Does NOT inject role-specific header_prompt/ files.

### 8. send preflight - does not exist

- ClaudeTui.ps1 _DoLaunch (L497-L602): No legal_state.json check whatsoever.
- v2 design requires preflight: reject if exit/running missing from legal_state (design L53).

### 9. Update-WorkerState.ps1 - missing Role param, no state validation

**Evidence**: scripts/Update-WorkerState.ps1 L1-L42

- L2-L9: Parameters only AgentName, CommandId, State - missing Role (v2 design L8).
- L29-L31: Writes .state file - correct.
- L36-L40: if ($State -eq "exit") writes .exit signal - THIS IS THE LIFECYCLE CONFLICT with Complete-ClaudeTask.
- No validation of $State against legal_state.json. No --prefix enforcement, no hard error on invalid (v2 design L10-L11).

### 10. Sync-ReadState - validation framework exists but incomplete

**Evidence**: ClaudeTui.ps1 L364-L398

- L375: Reads .state file.
- L378: Parses state: <value>.
- L382-L384: Updates agents.json.current_state.
- L387-L391: If parsedState not in roles.json states, prints [STATE] WARNING.
  - Has warning framework [check]
  - Reads states from roles.json, not legal_state.json [x]
  - Only warns, does not block (v2 design L11 requires hard error) [x]

### 11. Agents display - State column already exists

**Evidence**: ClaudeTui.ps1 L693-L704

- L693-L694: Columns: Agent ID, Worker State, State, Output State, Session UUID.
- L698: Reads from agents.json.current_state.
- State column already implemented, consistent with v2 design L77-L85 [check]

### 12. Complete-ClaudeTask.ps1 - unconditionally writes .exit

**Evidence**: Complete-ClaudeTask.ps1 L177-L180

- L179-L180: Writes .exit signal on every call, independent of Update-WorkerState.
- Creates double-write conflict with Update-WorkerState.ps1 L36-L40.

### 13. Existing prompt_templates/role/ - all flat structure

**Evidence**: Directory scan
```
role/tdd-coder/tdd-rules.md         (1 flat file)
role/test-r/x.md                    (1 flat file)
role/test-v2/x.md + tdd-states.txt  (2 flat files)
```
- Zero system_prompt/, header_prompt/, normal_prompt/ subdirectories.
- Zero legal_state.json files.

### 14. roles.json current entry - test-v2

**Evidence**: prompt_templates/roles.json
- states: ["read","test_fail","implement","exit"] - missing "running" (v2 mandatory).
- No legal_state_version or exit_confirmation fields.

---

## Gaps Against Accepted Direction

### P0 - Blockers (v2 core functionality non-functional without fix)

| # | Gap | Design Ref | Current Evidence |
|---|-----|-----------|------------------|
| P0-1 | role register still copies files, does not create 3-subdirectory structure | design L39-L44 | ClaudeTui.ps1 L1003-L1010 |
| P0-2 | legal_state.json completely absent | design L48-L55 | Directory scan: 0 legal_state.json files |
| P0-3 | send has no preflight check for exit/running in legal_state | design L53 | ClaudeTui.ps1 _DoLaunch L497-L602, no check |
| P0-4 | Update-WorkerState.ps1 does not validate state legality, no hard error | design L11 | Update-WorkerState.ps1 L29-L31, no validation |
| P0-5 | Update-WorkerState.ps1 missing -Role parameter | design L8 | Update-WorkerState.ps1 L2-L9, no Role param |
| P0-6 | role/<name>/system_prompt/ not injected to --system-prompt-file | design L1-L2 | Send-ClaudeCommand.ps1 L225-L242: only default/system.md |
| P0-7 | role/<name>/header_prompt/ not injected to task header | design L3 | Send-ClaudeCommand.ps1 L244-L265: only default/header.md |
| P0-8 | --system-prompt-file injection order wrong (missing system_prompt/ concat) | design "Injection order" | Send-ClaudeCommand.ps1 L225-L238 |

### P1 - Critical (behavior severely deviates from design)

| # | Gap | Design Ref | Current Evidence |
|---|-----|-----------|------------------|
| P1-1 | default/system.md is still worker contract, not State system manual | design L8-L9 | prompt_templates/default/system.md L1-L14 |
| P1-2 | role register forces -Files parameter | design L6 | ClaudeTui.ps1 L980 |
| P1-3 | Role directory flat, not 3 subdirectories | design L14-L19 | Directory scan: all roles flat |
| P1-4 | legal_state.json missing exit_confirmation field | design L6 | legal_state.json does not exist |
| P1-5 | Update-WorkerState accepts arbitrary strings, not --<legal-state> | design L10 | Update-WorkerState.ps1 L8: plain [string] |
| P1-6 | --exit has no confirmation gate (first-call checklist + second confirm) | design L12 | Update-WorkerState.ps1 L36-L40: directly writes .exit |
| P1-7 | Default states only exit, missing running | design L5 | ClaudeTui.ps1 L1011: $states = @("exit") |
| P1-8 | Sync-ReadState uses roles.json not legal_state.json | design L55 | ClaudeTui.ps1 L387-L391 |

### P2 - Polish (improvement, not blocking launch)

| # | Gap | Design Ref | Current Evidence |
|---|-----|-----------|------------------|
| P2-1 | normal_prompt/ has no CLI explicit selection mechanism | design L4 | Entire codebase: no related implementation |
| P2-2 | roles.json and legal_state.json dual-storage for states | design L48-L55 | ClaudeTui.ps1 L387+L1026 |
| P2-3 | role update behavior not explicitly defined in v2 design | - | ClaudeTui.ps1 L1034-L1072 |
| P2-4 | v2 design Injection Rules table lacks normal_prompt/ trigger condition | design L25-L29 | Table has normal_prompt/ but vague purpose |

---

## Recommended Implementation Phases

### Phase 1: Core Structure (no runtime behavior change)

**Purpose**: Establish legal_state.json and subdirectory structure. Fix role register to create correct directories. Add Role param + validation to Update-WorkerState. Do NOT change actual prompt injection paths.

**Files allowed to modify**:
- scripts/ClaudeTui.ps1 - Invoke-RoleRegister, Invoke-RoleUpdate, Invoke-RoleShow
- scripts/Update-WorkerState.ps1 - add -Role param, add legal_state.json validation
- prompt_templates/role/ - new roles create correct directory structure

**Do NOT modify**:
- Send-ClaudeCommand.ps1 (injection paths unchanged)
- Build-SystemPrompt, Build-WorkerPrompt
- Existing flat role directories (no migration)

**Compatibility strategy**:
- Invoke-RoleRegister: -Files becomes optional; omitted = create 3 empty subdirs + legal_state.json; provided = deprecation warning but still v1 behavior.
- legal_state.json default: {"states":["running","exit"],"exit_confirmation":"You confirm you have fully executed the exit procedure required by the orchestrator and left verifiable results or evidence?"}
- Update-WorkerState.ps1: prefer role/<name>/legal_state.json, fallback to roles.json states (compat period).

**Test points**:
1. role register test-phase1 (no -Files) -> creates 3 empty subdirs + legal_state.json
2. Update-WorkerState -AgentName x -CommandId y -Role test-phase1 -State --running -> writes .state, no error
3. Update-WorkerState -State --invalid_state -> hard error, lists legal states
4. role show test-phase1 -> displays legal_state.json content

**Stop condition**: All 4 tests pass, existing send unaffected.

### Phase 2: Prompt Injection Path (runtime behavior change)

**Purpose**: On send, correctly inject system_prompt/ to --system-prompt-file, header_prompt/ to task header. Add send preflight check.

**Files allowed to modify**:
- scripts/Send-ClaudeCommand.ps1 - Build-SystemPrompt: concat default/system.md + role/<name>/system_prompt/*.md
- scripts/Send-ClaudeCommand.ps1 - Build-WorkerPrompt: inject role/<name>/header_prompt/*.md before header
- scripts/ClaudeTui.ps1 - _DoLaunch add preflight check
- prompt_templates/default/system.md - rewrite to State system manual (see Phase 3)

**Do NOT modify**: normal_prompt/ auto-injection (v2 design L4: do not auto-inject)

**Compatibility strategy**:
- Build-SystemPrompt: read default/system.md first, then scan role/<name>/system_prompt/ for all .md files, concat in filename sort order.
- Build-WorkerPrompt: insert role/<name>/header_prompt/**/*.md before header.
- Preflight: only check when role dir has legal_state.json; skip when absent (compat with old flat roles).
- Get-RoleTemplateContent retained with deprecation comment.

**Test points**:
1. send with v2 role -> --system-prompt-file contains default/system.md + system_prompt/ files
2. send with role lacking legal_state.json -> no preflight error (compat)
3. send with role missing exit or running in legal_state -> preflight rejects
4. Header prompt injection: Build-WorkerPrompt output includes role header

**Stop condition**: 4 tests pass, existing workers still functional.

### Phase 3: State System Hardening (safety gates)

**Purpose**: Rewrite default/system.md. Implement state validation hard error, --exit confirmation gate, exit_confirmation.

**Files allowed to modify**:
- prompt_templates/default/system.md - full rewrite to State system manual
- scripts/Update-WorkerState.ps1 - hard exit gate, --prefix requirement, hard error on invalid
- scripts/ClaudeTui.ps1 - Sync-ReadState switch to legal_state.json validation
- prompt_templates/role/<name>/legal_state.json - new fields

**Do NOT modify**: Complete-ClaudeTask.ps1 .exit writing (deferred to Phase 4 decision)

**Compatibility strategy**:
- --exit first call: outputs exit_confirmation checklist, does NOT switch state
- --exit --Confirm second call: switches to exit, writes .exit
- Invalid state: hard error, outputs all legal states, does not write file
- Sync-ReadState: detect illegal state per legal_state.json -> HARD ERROR display (manager-side only)

**Test points**:
1. Update-WorkerState -State --exit (first, no Confirm) -> outputs exit_confirmation, no .exit
2. Update-WorkerState -State --exit --Confirm (second) -> switches to exit, writes .exit
3. Update-WorkerState -State --invalid -> hard error + legal states list
4. Sync-ReadState detects illegal state -> prints HARD ERROR
5. New system.md clearly documents Update-WorkerState usage and role legal state list

**Stop condition**: All 5 tests pass.

### Phase 4: Migration & Cleanup

**Purpose**: Migrate old flat roles, clean up roles.json, finalize .exit lifecycle, normal_prompt mechanism.

**Files allowed to modify**:
- scripts/ClaudeTui.ps1 - migration command, normal_prompt injection parameter
- scripts/Complete-ClaudeTask.ps1 - adjust .exit behavior per D2 decision
- prompt_templates/ - migrate old roles
- prompt_templates/roles.json - clean up states field

**Test points**:
1. Migration command converts flat role to v2 structure
2. normal_prompt injection parameter works correctly
3. .exit lifecycle has no conflicts

**Stop condition**: All tests pass, full regression green.

---

## Decision Inputs For Orchestrator

### D1: normal_prompt CLI parameter design

**Background**: v2 design L4 explicitly states normal_prompt/ is NOT auto-injected. Orchestrator must decide CLI form.

**Options**:

| Option | CLI Form | Pros | Cons |
|--------|----------|------|------|
| A | send -Role coder -InjectNormal <name> | Explicit, single template | Needs extra param parsing |
| B | send -Role coder --load-normal | Flag, injects ALL normal_prompt/ files | Simple, less flexible |
| C | Worker reads normal_prompt/<name>.md with Read tool | Zero CLI change | Depends on worker compliance |
| D | send -Role coder -PromptFile normal_prompt/... | Reuses existing param | Breaks layering semantics |

**Recommendation**: Option A. Rationale: explicit selection preserves layering semantics (normal_prompt injected into task body), does not pollute user prompt. Example: send my-coder -Role coder -InjectNormal tdd-coder-review injects role/coder/normal_prompt/tdd-coder-review.md.

---

### D2: Whether --exit --Confirm writes .exit signal

**Background**: v2 design L13 marks this as open question.

**Current conflict**:
- Complete-ClaudeTask.ps1 L179-L180: writes .exit on every call
- Update-WorkerState.ps1 L36-L40: -State "exit" also writes .exit
- Manager Sync-KillPending depends on .exit to trigger finishing -> 5s grace -> kill

**Options**:

| Option | Behavior | Pros | Cons |
|--------|----------|------|------|
| A | Only Complete-ClaudeTask writes .exit | Single write point | --exit confirm gate cannot trigger cleanup |
| B | Only Update-WorkerState --exit --Confirm writes .exit | Confirm gate + cleanup unified | Complete-ClaudeTask needs dedup |
| C | Both write .exit, Manager deduplicates | Best compat | Semantically muddy |

**Recommendation**: Option B, simultaneously modify Complete-ClaudeTask.ps1 to remove .exit writing. Rationale:
1. .exit semantics = worker confirms completion and is ready for manager to kill
2. This confirmation belongs to --exit --Confirm flow
3. Complete-ClaudeTask responsibility is write result/done, NOT process lifecycle

**Risk**: If worker calls Complete-ClaudeTask but not Update-WorkerState --exit --Confirm, manager never receives .exit. Mitigate by documenting both calls required in default/system.md.

---

### D3: Old flat role migration strategy

**Background**: 3 existing flat roles (tdd-coder, test-r, test-v2). roles.json has states.

**Options**:

| Option | Strategy | Pros | Cons |
|--------|----------|------|------|
| A | role migrate <name> auto-move to system_prompt/ | Automated | Inference may be wrong (system vs header?) |
| B | Manual migration by orchestrator | Zero dev, explicit | Manual, needs docs |
| C | Compat mode: detect flat -> inject to header_prompt/ | Smooth transition | Tech debt, code branching |

**Recommendation**: Option B (manual) + Option C (temporary compat with deprecation warning). Only 3 old roles, manual cost low. Auto-migration cannot infer file roles. Compat mode gives buffer. Remove compat in Phase 4.

**Deprecation warning**: [MANAGER] Role 'tdd-coder' uses legacy flat structure. Migrate with: role migrate tdd-coder. Flat templates injected as header_prompt until migration.

---

### D4: Role mismatch with current task role - hard error or warning

**Background**: v2 design L8 requires Update-WorkerState -Role param. What if worker passes mismatched Role vs agents.json.current_task.role?

**Scenario**: Agent sent with -Role tdd-coder, worker calls Update-WorkerState -Role explorer.

**Options**:

| Option | Behavior | Pros | Cons |
|--------|----------|------|------|
| A | Hard error, refuse write | Strict | May break valid role-switch relay |
| B | Warning, still write | Flexible | Defeats Role param purpose |
| C | Hard error on unknown; Warning on mismatch | Compromise | Complexity |

**Recommendation**: Option A (Hard error). Rationale:
1. Purpose of -Role is binding state validation to role legal_state.json
2. Wrong Role = confused worker or injection issue
3. Genuine role switch should be new send by orchestrator

**Implementation**: Read current task role from status.json or agents.json, compare with -Role. Mismatch -> error.

---

### D5: legal_state.json minimum schema fields

**Recommended schema**:
```jsonc
{
  "version": "1",
  "states": ["running", "exit"],
  "exit_confirmation": "You confirm you have fully executed the exit procedure required by the orchestrator and left verifiable results or evidence?",
  "description": "optional human note"
}
```

**Required**: states (min running+exit), exit_confirmation
**Optional**: version, description

---

## Test Matrix

### T1: role register v2 behavior

```powershell
# T1.1 Register without -Files (new default)
& $tui role register tester-v2
# Expected: creates role/tester-v2/{system_prompt/,header_prompt/,normal_prompt/,legal_state.json}

# T1.2 Register with conflict (no -Force)
& $tui role register test-v2
# Expected: "already exists" message, exit 1

# T1.3 Register with -Force (overwrite)
& $tui role register test-v2 -Force
# Expected: overwrites, creates v2 structure

# T1.4 Register with -Files (deprecation path)
& $tui role register old-style -Files some/path.md -StateFile some/states.txt
# Expected: WARNING "deprecated -Files", still creates flat
```

### T2: Update-WorkerState v2 behavior

```powershell
# T2.1 Valid state with --prefix
powershell -File Update-WorkerState.ps1 -AgentName test -CommandId 20260615-000001-000 -Role tester-v2 -State --running
# Expected: writes .state, no error

# T2.2 Invalid state -> hard error
powershell -File Update-WorkerState.ps1 -AgentName test -CommandId 20260615-000001-000 -Role tester-v2 -State --invalid_state
# Expected: hard error, lists legal states, exit 1

# T2.3 --exit first call -> checklist, no state change
powershell -File Update-WorkerState.ps1 -AgentName test -CommandId 20260615-000001-000 -Role tester-v2 -State --exit
# Expected: exit_confirmation displayed, no .exit signal

# T2.4 --exit --Confirm -> exit state + .exit signal
powershell -File Update-WorkerState.ps1 -AgentName test -CommandId 20260615-000001-000 -Role tester-v2 -State --exit -Confirm
# Expected: .state="state: exit", .exit written

# T2.5 Missing -Role parameter -> error
powershell -File Update-WorkerState.ps1 -AgentName test -CommandId 20260615-000001-000 -State --running
# Expected: error "Missing -Role"

# T2.6 Role mismatch with current task
powershell -File Update-WorkerState.ps1 -AgentName test -CommandId ... -Role tdd-coder -State --running
# Expected: hard error "Role mismatch: task=explorer, called=tdd-coder"
```

### T3: send preflight

```powershell
# T3.1 Role with valid legal_state.json -> pass
& $tui send tester -Role tester-v2 -Prompt "test"
# Expected: launches normally

# T3.2 Role missing "running" -> rejected
& $tui send tester -Role bad-role -Prompt "test"
# Expected: "[MANAGER] Rejected: Role 'bad-role' missing mandatory states: running"

# T3.3 Role missing legal_state.json entirely -> compatible skip
& $tui send tester -Role tdd-coder -Prompt "test"
# Expected: "[MANAGER] Role 'tdd-coder' uses legacy flat structure. Consider migration.", launches
```

### T4: Prompt injection verification

```powershell
# T4.1 System prompt contains system_prompt/ files
# Inspect run/<agent>/run-command-*.system.txt
# Expected: default/system.md + [role system_prompt/ files alphabetically]

# T4.2 Header prompt contains header_prompt/ files
# Inspect run/<agent>/run-command-*.prompt.txt
# Expected: role header_prompt/ files + then [worker] line

# T4.3 Normal prompt NOT auto-injected
# Expected: No normal_prompt/ content unless -InjectNormal specified
```

### T5: Sync-ReadState hardening

```powershell
# T5.1 Valid state change -> display
# Expected: "[STATE] agent: running -> implementing"

# T5.2 State not in legal_state.json -> hard error display
# Expected: "[STATE] HARD ERROR: agent set illegal state 'invalid'"

# T5.3 agents display after state change
# Expected: State column shows new state
```

### T6: Regression

```powershell
# T6.1 send without -Role -> works (auto role=explorer)
# T6.2 send with old flat role -> works (backward compat)
# T6.3 wait any -> works
# T6.4 result -> works
# T6.5 remove -> works
# T6.6 agents display -> all columns correct
```

---

## Blockers / Open Questions

### B1: .exit signal lifecycle conflict (requires orchestrator decision)

**Current state**:
- Complete-ClaudeTask.ps1 L179-L180: writes .exit on every call
- Update-WorkerState.ps1 L36-L40: -State "exit" also writes .exit
- Manager Sync-KillPending (ClaudeTui.ps1 L401-L448): detects .exit -> finishing -> 5s grace -> kill

**Conflict**: If worker calls Complete-ClaudeTask (auto-writes .exit), Manager starts 5s grace, potentially killing window before Update-WorkerState --exit --Confirm. But v2 design requires --exit confirmation gate.

**Recommendation**: D2 Option B - only Update-WorkerState --exit --Confirm writes .exit, Complete-ClaudeTask removes .exit writing.

**Decision needed**: Adopt D2 Option B?

---

### B2: Where does worker contract go after default/system.md split?

**Current**: default/system.md (L1-L14) = worker contract + rules.

**v2 requirement** (design L8-L9): default/system.md -> State system manual only.

**Options**:
- (a) Move to role/<name>/system_prompt/ orchestrator-maintained files
- (b) Keep in default/system.md (violates v2 design)
- (c) New prompt_templates/shared/worker-contract.md injected fixed in Build-SystemPrompt

**Unresolved**: v2 design does not specify where original contract goes.

---

### B3: Deprecate or co-exist roles.json states field?

**Current**: roles.json states array used by Sync-ReadState (L387-L391) and Send-ClaudeCommand.

**v2 requirement**: State legality from legal_state.json.

**Question**: Remove states from roles.json? Or co-exist (legal_state.json authority, roles.json cache)?

**Recommendation**: Phase 1 co-exist, Phase 4 deprecate. Add legal_state_version field to roles.json.

---

### B4: role update behavior definition for v2

v2 design does not explicitly describe role update under v2 structure. Current Invoke-RoleUpdate (L1034-L1072) deletes and recreates entire directory.

Should it: (a) not delete, only replace specified subdirectories? or (b) continue full rebuild?

**Recommendation**: role update should not delete, should do incremental operations. Exact semantics deferred to Phase 4.

---

### B5: Multiple .md files in subdirectory - injection ordering

v2 design says "filename sort order concatenation" but sort rule unspecified: alphabetical? creation time? prefix?

**Recommendation**: Alphabetical (Get-ChildItem | Sort-Object Name). Orchestrator controls order via filenames (e.g., 00-hard-rules.md, 01-soft-guidelines.md).

---

## No-Code Confirmation

**CONFIRMED**: This report is the sole output artifact. Except for docs/worker-reports/role-system-v2-upgrade-planning-report.md, NO files were created, modified, or deleted.

- prompt_templates/ - unmodified
- scripts/ - unmodified
- manager/ - unmodified
- run/ - unmodified
- store/ - unmodified
- Git working tree state matches task start

---

## Summary Statistics

| Metric | Value |
|--------|-------|
| Files read | 15 |
| Confirmed implementation items | 14 |
| Gaps identified | 16 (8 P0 + 8 P1 + 4 P2) |
| Recommended phases | 4 |
| Decision inputs | 5 |
| Test cases | 24 |
| Blockers/open questions | 5 |
| Lines of evidence cited | 50+ |
