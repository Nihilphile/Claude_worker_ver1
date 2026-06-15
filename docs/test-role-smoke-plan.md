# Test Role Integration Smoke Plan

## Purpose

This plan validates Claude Worker v2 as an integrated system rather than testing only
individual PowerShell functions. The locally registered `test` role is a protocol
probe with deterministic injection markers and observable legal states.

The smoke must not modify runtime source files. Use unique agent IDs and a temporary
workspace outside the repository. Do not run `remove all` in a shared manager.

## Test Role Contract

Expected role structure:

```text
prompt_templates/role/test/
├── system_prompt/
│   ├── 10-injection-marker.md
│   └── 20-state-contract.md
├── header_prompt/
│   ├── 10-injection-marker.md
│   └── 20-evidence-contract.md
├── normal_prompt/
│   ├── full-cycle.md
│   ├── powershell-probe.md
│   └── strict-json-evidence.md
└── legal_state.json
```

Expected legal states:

```text
running, coding, debugging, reviewing, exit
```

There is intentionally no `blocked` state. A genuinely stuck worker generally cannot
reliably report it, so timeout and dead-process detection belong to manager lifecycle
testing rather than worker-driven state testing.

## Markers

| Layer | Expected marker |
|-------|-----------------|
| System file 10 | `V2_TEST_SYSTEM_A_7F31` |
| System file 20 | `V2_TEST_SYSTEM_B_2C84` |
| Header file 10 | `V2_TEST_HEADER_A_5D19` |
| Header file 20 | `V2_TEST_HEADER_B_8A46` |
| Normal full cycle | `V2_TEST_NORMAL_FULL_C6E2` |
| Normal JSON contract | `V2_TEST_NORMAL_JSON_D4B7` |
| Normal PowerShell rules | `V2_TEST_NORMAL_PS_91AF` |

Each task adds a unique task marker. A marker is evidence of a layer only when it is
also present in that command's generated system or task prompt. Model output alone is
not authoritative because a resumed session may remember earlier markers.

## Phase 0: Static Preflight

Run:

```powershell
& $tui role list
& $tui role show test
```

Pass criteria:

- The role is registered as v2.
- All five legal states are listed in the configured order.
- Both system files and both header files are listed alphabetically.
- All three normal fragments are listed.
- An unregistered role is rejected before a worker is launched.
- A nonexistent normal fragment is rejected before a worker is launched.

## Phase 1: Full Lifecycle

Create a unique temporary workspace and agent ID. Use TUI mode so the manager, not
natural CLI exit, performs the confirmed-exit cleanup.

```powershell
$agent = "v2-test-full-<unique>"
$workspace = "<unique-temp-workspace>"

& $tui send $agent `
  -Role test `
  -InjectNormal full-cycle `
  -Workspace $workspace `
  -Mode tui `
  -TimeoutSeconds 900 `
  -Prompt @'
Task marker: V2_TEST_TASK_FULL_E03C

Create smoke-evidence.json in this temporary workspace. Use expected value 42. The
full-cycle normal prompt defines the deliberate defect and repair procedure.

Final JSON must contain:
- task_marker
- observed_markers (array)
- expected
- actual
- state_calls (array in execution order)
- validation_passed (boolean)

Do not write result.md. Do not modify the Claude Worker repository.
'@
```

While the worker runs, poll only this agent every one or two seconds:

```powershell
& $tui agent $agent
```

Record the first observation time for each state. Do not infer an intermediate state
solely from the final artifact.

Expected manager timeline:

```text
running -> coding -> debugging -> reviewing -> finishing -> finished/ready
```

Pass criteria:

- The LLM proactively invokes every state update in order.
- Manager polling observes all four non-exit states.
- Generated system prompt contains both system markers in A-then-B order.
- Generated task prompt contains both header markers in A-then-B order, the full-cycle
  marker, and the task marker.
- Generated task prompt does not contain the other two normal markers.
- `--exit` without confirmation leaves state at `reviewing`.
- Confirmed exit contains `V2_TEST_EXIT_SUMMARY_OK` in `summary_message`.
- Manager enters `finishing`, waits for the grace period, then reaches
  `finished/ready`.
- No `.exit` file and no `result.md` exists.
- `result $agent` succeeds and displays the state summary despite missing result.md.
- `smoke-evidence.json` parses and has `actual=expected=42`.

## Phase 2: Normal Fragment Isolation

Use fresh agents so session memory cannot masquerade as injection.

### No Normal Fragment

Send with `-Role test` and no `-InjectNormal`. The task asks the worker to record all
visible `V2_TEST_*` markers, call `running`, then `reviewing`, then confirmed exit.

Pass criteria:

- System and header markers are present.
- No `V2_TEST_NORMAL_*` marker appears in the generated task prompt.

### JSON Contract Fragment

Use `-InjectNormal strict-json-evidence` with a fresh agent.

Pass criteria:

- Only `V2_TEST_NORMAL_JSON_D4B7` is injected.
- The requested artifact is valid JSON.
- Full-cycle and PowerShell normal markers are absent from the generated task prompt.

### PowerShell Rules Fragment

Use `-InjectNormal powershell-probe` with another fresh agent.

Pass criteria:

- Only `V2_TEST_NORMAL_PS_91AF` is injected.
- Evidence includes a command, exit code, and relevant output.

## Phase 3: State API Negative Matrix

Use a temporary agent/command fixture and invoke `Update-WorkerState.ps1` directly.
Clean the fixture afterward.

| Probe | Expected result |
|-------|-----------------|
| `--unknown` | Non-zero; lists all five legal states |
| `--coding --reviewing` | Non-zero; multiple state arguments |
| `-State "--coding"` | Non-zero; explains dynamic switch syntax |
| Wrong role | Non-zero; role mismatch |
| Missing AgentName, CommandId, or Role | Non-zero; identifies missing argument |
| Unknown option | Non-zero; lists allowed options |
| `--exit` without `-Confirm` | Exit checklist only; prior state unchanged |
| `--exit -Confirm` | Confirmed exit JSON |

Verify that none of these probes creates an `.exit` file.

## Phase 4: Session Resume

**Important**: Phase 1 agents run in TUI mode and are terminated by manager
force-kill after confirmed exit. TUI sessions ended this way are NOT guaranteed
resumable (see `docs/session-uuid-lifecycle.md`). **Do not attempt to resume the
Phase 1 TUI agent.**

Instead, design an independent `-p` mode round1 → resume round2 test:

### Phase 4a: Round 1 (fresh -p session)

```powershell
$agent = "v2-test-resume-p-<unique>"
$workspace = "<unique-temp-workspace>"

& $tui send $agent `
  -Role test `
  -InjectNormal full-cycle `
  -Workspace $workspace `
  -Mode p `
  -TimeoutSeconds 600 `
  -Prompt @'
Task marker: V2_TEST_TASK_RESUME_C1A2
Write evidence-p1.json with {"round":1,"uuid":"<use Update-WorkerState to find it>"}.
Call Update-WorkerState --running, then --reviewing, then --exit -Confirm.
Do not write result.md.
'@
```

Wait for agent to reach `finished/ready`. Record its session UUID.

### Phase 4b: Round 2 (resume same -p session)

```powershell
& $tui send $agent `
  -Role test `
  -InjectNormal strict-json-evidence `
  -Workspace $workspace `
  -Mode p `
  -TimeoutSeconds 600 `
  -Prompt @'
Task marker: V2_TEST_TASK_RESUME_D3B4
Read evidence-p1.json. Write evidence-p2.json with {"round":2,"prior_uuid":"<from p1>"}.
Verify you remember the Phase 1 task. Call running -> reviewing -> exit -Confirm.
Do not write result.md.
'@
```

### Pass criteria (Phase 4a + 4b):

- Session UUID is identical across both rounds.
- Each round gets a new command ID.
- State files are isolated by command ID (old .state unchanged).
- Round 2 generated prompt contains the JSON normal marker, not the full-cycle marker.
- Worker in round 2 demonstrates recall of round 1 context (prior UUID, task content).
- Both rounds complete `running -> reviewing -> exit` independently.
- No session crash (the `-p` mode clean exit avoids the TUI force-kill issue).

### Phase 4c (optional): Verify TUI resume limitation

If desired, attempt to resume the Phase 1 TUI agent after it reaches `finished/ready`.
Expected: Claude `--resume` may crash due to incomplete session state from force-kill.
This is a known limitation, not a protocol defect. Record whether resume succeeds or
crashes for documentation purposes.

## Phase 5: Two-Agent Concurrency

Start two unique agents close together:

- Agent A uses `full-cycle`.
- Agent B uses `strict-json-evidence` and a shorter `running -> reviewing -> exit` task.

Poll the agents by explicit ID; do not use global `wait all` in a shared manager.

Pass criteria:

- Agent and command run/store paths remain isolated.
- Different current states can be observed concurrently.
- One confirmed exit does not change or terminate the other agent.
- Normal markers do not cross generated prompt files.
- Both independently reach `finished/ready`.

## Cleanup

- Remove only the smoke agents created by this plan, after they are no longer running
  or finishing.
- Delete only the unique temporary workspaces.
- Keep the registered `test` role for repeatable regression smoke.
- Never edit `manager/agents.json` unless a separate recovery procedure explicitly
  authorizes it.
- Never run `remove all` in a shared manager.

## Verdict Rules

- **PASS**: Phases 0-4 pass; Phase 5 also passes when concurrency is in scope.
- **PASS WITH RISKS**: Core lifecycle passes, with a clearly bounded observation gap
  that does not hide a failed required state or injection layer.
- **FAIL**: A completed test contradicts an expected behavior but the runtime remains
  usable.
- **BLOCKED**: A runtime defect prevents later phases from being executed.

Write the execution report to:

```text
docs/worker-reports/role-system-v2-test-role-smoke-report.md
```

The report must include command IDs, session UUIDs, generated prompt paths, state
timeline, artifact paths, negative-test exit codes, cleanup status, and every item
marked PASS, FAIL, or NOT OBSERVED.

## Prior Execution Record

- **2026-06-15 Targeted Smoke** (Phases 0–2 subset): ALL PASS. Single-worker real chain
  verified InjectNormal end-to-end (`V2_TEST_NORMAL_JSON_D4B7` marker propagated from
  template → prompt → worker JSON artifact). Missing-template rejection confirmed (no
  zombie agent created). pending_task_error display verified. Sync-DeadToFailed timeout
  verified (3 tests PASS). Temp workspace cleaned, agent soft-deleted. See
  [targeted smoke report](worker-reports/role-system-v2-targeted-smoke-report.md).

