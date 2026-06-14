# agents.json Schema & Status Lifecycle

`manager/agents.json` is the single source of truth for all agent state.

## Schema

```jsonc
{
  "054e45d3-...": {                    // internal_id (GUID, system key)
    "internal_id": "054e45d3-...",
    "agent_id": "st_test",              // user-chosen semantic name
    "status": ["finished","ready"],     // process + result state (see below)
    "session_uuid": "b369223d-...",     // real Claude UUID
    "default_mode": "p",                // "p" | "tui"
    "pid": null,                        // runner process ID (null when idle)
    "current_task": {
      "command_id": "20260614-...",
      "prompt": "Say hi in one line.",
      "role": "explorer",
      "model": null,
      "launched_at": "2026-06-14T04:05:48"
    },
    "pending_task": null,               // queued via [W]ait on busy agent
    "created_at": "2026-06-14T04:05:48",
    "updated_at": "2026-06-14T04:06:23",
    "deleted_at": null                  // set on soft-delete
  }
}
```

## Status Tags

The `status` array encodes two display columns: Worker State and Output State.

| `status` | Worker State | Output State |
|----------|-------------|-------------|
| `["running"]` | running | none |
| `["finishing"]` | finishing | none |
| `["finished","ready"]` | finished | ready |
| `["finished","consumed"]` | finished | consumed |
| `["failed"]` | failed | none |
| `["deleted"]` | deleted | — |

## Lifecycle

```
["running"]  →  ["finishing"]  →  ["finished","ready"]  →  ["finished","consumed"]  →  ["running"] (re-send)
     ↓ task done        ↓ .exit signal       ↓ wait any returns      ↓ re-send
                        ↓ 5s grace           ↓ output ready
                        ↓ then kill window
```

### Sync Functions (manager internal)

| Order | Function | Reads | Writes |
|-------|----------|--------|--------|
| 1 | Sync-KillPending | `run/<agent>/.<id>.exit` | state → finishing → (5s grace) → finished,ready; kills process tree |
| 2 | Sync-DoneToManager | `store/<agent>/results/<id>.done.json` | state → finished,ready; captures session_uuid |
| 3 | Sync-DeadToFailed | OS process table | state → failed (PID dead, no done.json) |

All Sync functions are triggered by any CLI command — there is no background daemon.
