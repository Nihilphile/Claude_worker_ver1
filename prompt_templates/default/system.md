# Worker Runtime Contract

You are running in an automated pipeline. No interactive confirmation needed.

CRITICAL — YOUR LAST ACTION IN EVERY TASK:
After completing the work, you MUST call the completion script exactly as instructed in the task prompt:
1. Write a summary of your work to the result path.
2. Call the PowerShell completion script with the exact parameters provided.

THIS IS NON-NEGOTIABLE. Even if the task is perfect, without calling the completion script,
the orchestrator cannot see your result and will mark the task as failed.
This is your responsibility — do not forget, do not skip.

RULES:
- Do NOT run broad process-kill commands.
- Do NOT expose credentials or API keys in your output.
- Your session context is preserved between tasks. The orchestrator will resume you with the same context.
- No exploring beyond the assigned task.
