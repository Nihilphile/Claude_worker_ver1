# Session UUID Lifecycle

Each agent has a real Claude session UUID, stored in `agents.json.session_uuid`.

**IMPORTANT**: UUID existence does NOT guarantee the session is resumable.
See [Strong-Kill Limitation](#strong-kill-limitation) below.

## Round 1 (new agent) — both modes

```
Manager: session_uuid = null
  → passes -FreshSession to Send-ClaudeCommand
  → runner: claude -p [or TUI] (no --resume)
  → manager acquires .create-session.lock (serialized)
  → waits 8s for .jsonl file to appear
  → scans ~/.claude/projects/<workspace-hash>/*.jsonl
  → newest file = real UUID
  → writes agents.json.session_uuid
  → writes store/<agent>/.claude-sid.txt (manager-side, for runner reference)

Fallback: if filesystem scan misses, Sync-DoneToManager captures session_id from done.json
```

## Round N (resume) — per-mode semantics

### -p mode (recommended for resume)

```
Manager: session_uuid = "c9024af0-..."
  → passes -SessionId to Send-ClaudeCommand (NOT -FreshSession)
  → runner: claude --resume "c9024af0-..." -p --output-format json
  → Claude resumes with full conversation history
  → Natural exit after task completion
  → done.json.session_id confirms same UUID
  → Session is resumable for further rounds (Claude clean-exited)
```

`-p` mode is the **preferred choice** for multi-turn workflows requiring reliable session resume.
Claude exits cleanly via `--output-format json`, producing a well-formed session file that is
immediately resumable in a subsequent round.

### TUI mode

```
Manager: session_uuid = "c9024af0-..."
  → passes -SessionId to Send-ClaudeCommand
  → runner: claude --resume "c9024af0-..." (interactive TUI window)
  → Worker signals exit via Update-WorkerState --exit -Confirm
  → Manager detects state=exit,confirmed=true in .state JSON
  → Manager enters finishing → 5s grace → force-kill process tree
  → done.json.session_id confirms same UUID
```

**TUI resume is NOT guaranteed reliable** after a confirmed-exit / manager-force-kill cycle.
See [Strong-Kill Limitation](#strong-kill-limitation).

## Strong-Kill Limitation

When a TUI-mode session completes via the confirmed exit → 5s grace → manager force-kill path,
the Claude process is terminated by `Stop-Process -Force`. Claude does NOT get an opportunity
to gracefully flush its session state to disk (`~/.claude/projects/<hash>/<uuid>.jsonl`).

**Consequences**:

- The session UUID remains in `agents.json` and `.claude-sid.txt`
- The `.jsonl` session file may exist but is potentially incomplete/corrupt
- A subsequent `claude --resume <uuid>` **may crash immediately** (observed in smoke testing:
  Claude process exits with no output when resuming a completed TUI session)
- **UUID exists ≠ session is resumable**

**Recommendations**:

1. Use **`-p` mode** for any workflow that requires session resume across rounds
2. Use **TUI mode** for interactive inspection/debugging where session resume is not needed
3. If you need a TUI session to be resumable, close the Claude window naturally (Ctrl+C
   or the `/exit` command) instead of relying on the Update-WorkerState --exit flow —
   but note that the manager won't detect natural TUI exits

## How the Runner Resolves Session ID (TUI mode)

The TUI runner template prioritizes session ID as follows:

1. `.claude-sid.txt` (`store/<agent>/.claude-sid.txt`) — written by manager after fsevents scan
2. `$curSessionId` — orchestrator-provided UUID (from `-SessionId` or agent's stored UUID)
3. Empty string — if neither source is available

The done.json fallback (when Claude exits without calling Complete-ClaudeTask) uses the same
priority. The stderr log path is also recorded in done.json for failure diagnosis.

## Agent-Level Isolation

- Each `agent_id` has its own `session_uuid`
- Multiple agents in the same workspace do NOT share sessions
- Session persistence depends on `~/.claude/projects/<hash>/<uuid>.jsonl` files
- UUID capture via filesystem requires the **global create lock** (`manager/.create-session.lock`) — new agent creation is serialized, resume is fully concurrent

## Verified Behavior

- **`-p` mode clean exit**: Targeted smoke (2026-06-15, agent `v2-targeted-20260615-001`) confirmed `-p` mode completes cleanly with `state=exit, confirmed=true` in `.state` JSON. The session is resumable for subsequent rounds.
- **TUI force-kill limitation**: Confirmed — TUI sessions terminated via the `finishing` → 5s grace → kill path may produce incomplete session files. `claude --resume` on such sessions can crash. Use `-p` mode for multi-turn workflows.
