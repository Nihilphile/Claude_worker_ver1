# Worker Runtime Contract (v2)

You are running in an automated pipeline as a worker agent. No interactive confirmation needed.

## State Tracking — Your Primary Lifecycle Interface

The ONLY worker-facing lifecycle/state interface is `Update-WorkerState.ps1`. This is how you report progress and signal completion to the orchestrator.

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skillRoot>/scripts/Update-WorkerState.ps1" -AgentName "<your-agent>" -CommandId "<command-id>" -Role "<your-role>" --<legal-state>
```

### Required Parameters

| Parameter | Description |
|-----------|-------------|
| `-AgentName` | Your agent ID (provided in task header) |
| `-CommandId` | Your command ID (provided in task header) |
| `-Role` | Your assigned role name (provided in task header). Must match the role assigned by the orchestrator. |

### State Argument

States are specified as `--<state>`, e.g., `--running`, `--implementing`, `--exit`. Exactly one state must be provided.

### Optional Parameters

| Parameter | Description |
|-----------|-------------|
| `-SummaryMessage "<text>"` | Human-readable summary stored in state JSON as `summary_message` |

### Exit Confirmation Gate

Setting `--exit` requires two steps:

1. **First call** `--exit` (without `-Confirm`): Prints the exit confirmation checklist from your role's `legal_state.json`. Does NOT write any state. Use this to verify you have completed everything.

2. **Second call** `--exit -Confirm`: Writes `state=exit, confirmed=true` in the JSON state file. This signals to the orchestrator that you are truly done and ready for cleanup.

**Important**: After `--exit -Confirm`, the orchestrator will begin the cleanup/finishing flow. The worker process will be terminated after a grace period. Ensure all results are written before confirming exit.

### Error Handling

- **Role mismatch**: If `-Role` does not match the role assigned to your task, the command will hard error.
- **Illegal state**: If you specify a state not in your role's `legal_state.json`, the command will hard error and list all legal states.
- **Missing parameters**: AgentName, CommandId, and Role are all mandatory.

### Usage Examples

```powershell
# Report that you are running
powershell ... -AgentName "my-coder" -CommandId "20260615-..." -Role "coder" --running

# Report implementation phase with summary
powershell ... -AgentName "my-coder" -CommandId "20260615-..." -Role "coder" --implementing -SummaryMessage "Phase 2: tests passing"

# First exit call — prints checklist, no state change
powershell ... -AgentName "my-coder" -CommandId "20260615-..." -Role "coder" --exit

# Second exit call — confirms and writes exit state
powershell ... -AgentName "my-coder" -CommandId "20260615-..." -Role "coder" --exit -Confirm -SummaryMessage "All tasks complete, results in store/"
```

## Rules

- Do NOT run broad process-kill commands.
- Do NOT expose credentials or API keys in your output.
- Your session context is preserved between tasks. The orchestrator will resume you with the same context.
- No exploring beyond the assigned task.
- Update your state frequently to keep the orchestrator informed.
