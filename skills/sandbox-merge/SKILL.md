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

### 2. Pre-Merge Validation

**Pool sandbox check:** Before proceeding with the standard merge, check if this session belongs to a pool:

```bash
# Check if .pool/<session>.state exists for the project
ls "$SANDBOX_BASE_DIR/<project>/.pool/<session>.state" 2>/dev/null
```

If the session is a pool sandbox, delegate to pool accept instead:

```bash
bash "$AGENT_SANDBOX_HOME/sandbox.sh" pool accept <project> <session>
```

Report:
```
Pool sandbox merged! Sandbox is idle for next task.
```

**Stop here** — do not proceed to the standard merge/cleanup steps (the pool accept command handles everything and keeps the container warm).

If not a pool sandbox, proceed with the standard merge flow below.

Before merging, the `sandbox.sh merge` command validates that work was actually committed. It will **abort with an error** if:

- **Uncommitted changes exist** in the worktree — the agent may not have finished. The error will suggest `sandbox shell` to reconnect or `sandbox diff` to review.
- **Zero commits** on the session branch beyond the base — there's nothing to merge. The error will suggest `sandbox shell`, `sandbox logs`, or `sandbox diff`.

If the merge command exits with an error, **relay the error to the user and do NOT proceed to cleanup**. The sandbox is preserved so no work is lost.

### 3. Merge

Run:
```bash
bash "$AGENT_SANDBOX_HOME/sandbox.sh" merge <project> <session>
```

This command:
- Stops the sandbox if running
- Restores the host git pointer
- Validates uncommitted changes and commit count (see step 2)
- Merges the session branch into the project's current branch

**If the merge fails** (conflicts), print the error and tell the user:
```
Merge conflict detected. Resolve conflicts in C:\Dev\<project>, then:
  git add .
  git commit
  & "$env:AGENT_SANDBOX_HOME/sandbox.ps1" stop <project> <session> --clean
```

Do NOT proceed to cleanup if the merge failed.

### 4. Clean Up

Only if the merge succeeded, run:
```bash
bash "$AGENT_SANDBOX_HOME/sandbox.sh" stop <project> <session> --clean
```

This removes:
- Docker containers and volumes
- Git worktree
- Session branch (if fully merged)

### 5. Report

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
