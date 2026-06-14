# Session UUID Lifecycle

Each agent has a real Claude session UUID, stored in `agents.json.session_uuid`.

## Round 1 (new agent)

```
Manager: session_uuid = null
  → passes -FreshSession to Send-ClaudeCommand
  → runner: claude -p (no --resume) [or interactive TUI]
  → manager acquires .create-session.lock (serialized)
  → waits 8s for .jsonl file to appear
  → scans ~/.claude/projects/<workspace-hash>/*.jsonl
  → newest file = real UUID
  → writes agents.json.session_uuid

Fallback: if filesystem scan misses, Sync-DoneToManager captures session_id from done.json
```

## Round N (resume)

```
Manager: session_uuid = "c9024af0-..."
  → passes -SessionId to Send-ClaudeCommand (NOT -FreshSession)
  → runner: claude --resume "c9024af0-..." -p
  → Claude resumes with full conversation history
  → done.json.session_id confirms same UUID
```

## Agent-Level Isolation

- Each `agent_id` has its own `session_uuid`
- Multiple agents in the same workspace do NOT share sessions
- Session persistence depends on `~/.claude/projects/<hash>/<uuid>.jsonl` files
- UUID capture via filesystem requires the **global create lock** (`manager/.create-session.lock`) — new agent creation is serialized, resume is fully concurrent
