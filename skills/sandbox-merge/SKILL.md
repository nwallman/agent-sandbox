---
name: sandbox-merge
description: Merge a sandbox session branch into the project and clean up. Stops the sandbox, merges the branch, removes worktree and volumes.
---

<!-- Part of agent-sandbox — https://github.com/agent-sandbox/agent-sandbox -->

# Sandbox Merge

Merge a completed sandbox session and clean up all resources.

## Steps

### 1. Identify Session

Use this priority order:

1. **If the user provided arguments** (e.g., `/sandbox-merge myproject my-session`), parse them as `<project> <session>`.

2. **Detect project from cwd** — extract the project name from the current working directory path. The working directory follows the pattern `C:\Dev\<project>` or `/c/Dev/<project>`. Extract the `<project>` portion directly from the path without running any bash commands.

3. **Find running sessions for this project** — run:
   ```bash
   docker ps --filter "name=sandbox-<project>" --format "{{.Names}}" | grep -oE 'sandbox-<project>-[^-]+-agent' | sed 's/-agent$//' | sort -u
   ```

   Alternative approach — parse `sandbox.sh list` output:
   ```bash
   bash "$AGENT_SANDBOX_HOME/sandbox.sh" list
   ```

   Look for entries matching `sandbox-<project>-*`.

4. **If one session found**, use it. **If multiple**, list them and ask the user to choose. **If none**, tell the user no running sandbox was found for this project.

### 2. Merge

Run:
```bash
bash "$AGENT_SANDBOX_HOME/sandbox.sh" merge <project> <session>
```

This command:
- Stops the sandbox if running
- Restores the host git pointer
- Merges the session branch into the project's current branch

**If the merge fails** (conflicts), print the error and tell the user:
```
Merge conflict detected. Resolve conflicts in C:\Dev\<project>, then:
  git add .
  git commit
  & "$env:AGENT_SANDBOX_HOME/sandbox.ps1" stop <project> <session> --clean
```

Do NOT proceed to cleanup if the merge failed.

### 3. Clean Up

Only if the merge succeeded, run:
```bash
bash "$AGENT_SANDBOX_HOME/sandbox.sh" stop <project> <session> --clean
```

This removes:
- Docker containers and volumes
- Git worktree
- Session branch (if fully merged)

### 4. Report

Print the result:

**On success:**
```
Sandbox merged and cleaned up!

  Project:  <project>
  Session:  <session>
  Status:   Merged into <current-branch>

All sandbox resources have been removed.
```

**On merge conflict:**
```
Merge conflict — manual resolution needed.

  Project:  <project>
  Session:  <session>
  Resolve:  C:\Dev\<project>

After resolving:
  & "$env:AGENT_SANDBOX_HOME/sandbox.ps1" stop <project> <session> --clean
```
