---
name: sandbox-execute
description: Launch a sandbox session to execute an implementation plan. Finds the plan, starts the sandbox, opens a PowerShell window with the agent working on it.
---

<!-- Part of agent-sandbox — https://github.com/agent-sandbox/agent-sandbox -->

# Sandbox Execute

Launch a sandbox to execute an implementation plan automatically.

## Steps

### 1. Detect Project

Extract the project name from the current working directory path. The working directory follows the pattern `C:\Dev\<project>` or `/c/Dev/<project>`. Extract the `<project>` portion directly from the path without running any bash commands.

If the working directory is not under `C:\Dev\` or the project name is `agent-sandbox`, tell the user: "Run this from inside a project directory (e.g., `C:\Dev\myproject`)."

### 2. Find Plan File

Use this priority order:

1. **If the user provided an argument** to `/sandbox-execute`, use it as the plan file path.

2. **Check conversation context** — look for any plan file path mentioned earlier in the conversation (e.g., from the writing-plans skill). Common patterns: `docs/superpowers/plans/YYYY-MM-DD-*.md`.

3. **Glob for the most recent plan** — use the Glob tool to find `docs/superpowers/plans/*.md` in the project directory. Pick the most recently modified file.

4. **If ambiguous** (multiple files, none clearly recent, none from conversation context), list them and ask the user to choose.

### 3. Verify Plan Is Committed

The sandbox creates a git worktree from the current branch. If the plan file isn't committed, it won't exist in the worktree and the agent will start confused.

Run `git status -- docs/superpowers/plans/<plan-file>` using the Bash tool. If the plan file shows as untracked or has uncommitted changes:

1. **Auto-commit the plan** — stage and commit it with message `docs: add implementation plan <plan-file>`.
2. Confirm to the user: "Committed the plan file so the sandbox worktree will include it."

If `git status` shows the file is clean (committed and unmodified), proceed.

### 4. Derive Session Name and Launch

Derive the session name by stripping the date prefix (`YYYY-MM-DD-`) and `.md` extension from the plan filename. For example: `2026-04-01-feature-name.md` becomes `feature-name`.

Then run **one single Bash command** that creates all temp files and launches the PowerShell window. Replace `<project>`, `<session>`, and `<plan-file>` with actual values:

```bash
WINTMP="$HOME/AppData/Local/Temp"
cat > "$WINTMP/sandbox-prompt.txt" << 'PROMPT'
You are working in sandbox session <session> for project <project>. Execute the implementation plan at docs/superpowers/plans/<plan-file> using the superpowers:subagent-driven-development skill. Work through each task, commit after each one. When all tasks are complete, run the full test suite to verify, commit any remaining changes, and tell the user the work is ready for merge.
PROMPT
cat > "$WINTMP/sandbox-start-agent.sh" << 'BASHSCRIPT'
#!/bin/bash
prompt=$(cat /home/agent/sandbox-prompt.txt)
exec claude --dangerously-skip-permissions "$prompt"
BASHSCRIPT
cat > "$WINTMP/sandbox-launch.ps1" << 'SCRIPT'
& "$env:AGENT_SANDBOX_HOME/sandbox.ps1" start <project> <session> --provider claude-code --dangerous
docker cp $env:TEMP/sandbox-prompt.txt sandbox-<project>-<session>-agent:/home/agent/sandbox-prompt.txt
docker cp $env:TEMP/sandbox-start-agent.sh sandbox-<project>-<session>-agent:/home/agent/sandbox-start-agent.sh
docker exec -u root sandbox-<project>-<session>-agent chmod +x /home/agent/sandbox-start-agent.sh
docker exec -it sandbox-<project>-<session>-agent /home/agent/sandbox-start-agent.sh
SCRIPT
powershell.exe -Command 'Start-Process powershell -ArgumentList "-NoExit", "-File", "$env:TEMP\sandbox-launch.ps1"'
```

**If the sandbox is already running** (check with `docker ps --filter "name=sandbox-<project>-<session>" -q`), use a simpler launcher that skips the start step — replace the `sandbox-launch.ps1` content above with:

```powershell
docker cp \$env:TEMP/sandbox-prompt.txt sandbox-<project>-<session>-agent:/home/agent/sandbox-prompt.txt
docker cp \$env:TEMP/sandbox-start-agent.sh sandbox-<project>-<session>-agent:/home/agent/sandbox-start-agent.sh
docker exec -u root sandbox-<project>-<session>-agent chmod +x /home/agent/sandbox-start-agent.sh
docker exec -it sandbox-<project>-<session>-agent /home/agent/sandbox-start-agent.sh
```

### 5. Report to User

Print immediately after launching the window (don't wait for the sandbox to finish starting):

```
Sandbox launching in new window!

  Project:  <project>
  Session:  <session>
  Plan:     <plan-file>

Monitor progress in the PowerShell window.

When the work is ready to merge:
  /sandbox-merge
Or manually:
  & "$env:AGENT_SANDBOX_HOME/sandbox.ps1" merge <project> <session>
  & "$env:AGENT_SANDBOX_HOME/sandbox.ps1" stop <project> <session> --clean
```
