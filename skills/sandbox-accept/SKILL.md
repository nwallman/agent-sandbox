---
name: sandbox-accept
description: Review and merge completed pool sandbox work. Human gate between agent completion and next task assignment.
---

<!-- Part of agent-sandbox — https://github.com/agent-sandbox/agent-sandbox -->

# Sandbox Accept

Review completed sandbox work and merge it, or reject it to discard.

## Steps

### 1. Detect Project

Extract the project name from the current working directory path. The working directory follows the pattern `C:\Dev\<project>` or `/c/Dev/<project>`. Extract the `<project>` portion directly from the path without running any bash commands.

If the working directory is not under `C:\Dev\` or the project name is `agent-sandbox`, tell the user: "Run this from inside a project directory (e.g., `C:\Dev\myproject`)."

### 2. Find Reviewing Sandboxes

Run:
```bash
bash "$AGENT_SANDBOX_HOME/sandbox.sh" pool status <project>
```

Parse the output for sandboxes in `reviewing` or `busy` state. Both are eligible for accept — there is no background watcher that flips busy→reviewing, so the user decides when the agent is done.

If none found in either state, tell the user: "No sandboxes are ready for review."

### 3. Select Sandbox

If the user provided a session name as argument, use it. If multiple sandboxes are eligible, list them and ask the user to choose:

```
Sandboxes ready for review:
  1. pool-1 — branch: add-phone-validation (plan: 2026-04-13-add-phone-validation.md)
  2. pool-3 — branch: fix-currency-display (plan: 2026-04-13-fix-currency-display.md)

Which one? [1/2]
```

### 4. Show Summary

Run:
```bash
bash "$AGENT_SANDBOX_HOME/sandbox.sh" diff <project> <session> --stat
```

Display the diff summary and ask:

```
Branch: <branch>
Plan:   <plan-file>
Changes: <diff stat summary>

Actions:
  [a] Accept & merge
  [d] Show full diff first
  [r] Reject (discard work)

What do you want to do?
```

### 5. Execute Action

**Accept:**
```bash
bash "$AGENT_SANDBOX_HOME/sandbox.sh" pool accept <project> <session> --force
```

Report:
```
Merged '<branch>' and sandbox is idle for next task.
```

**Show diff:**
```bash
bash "$AGENT_SANDBOX_HOME/sandbox.sh" diff <project> <session>
```

Then ask again: Accept or Reject?

**Reject:**
```bash
bash "$AGENT_SANDBOX_HOME/sandbox.sh" pool reject <project> <session>
```

Report:
```
Work discarded. Sandbox is idle for next task.
```
