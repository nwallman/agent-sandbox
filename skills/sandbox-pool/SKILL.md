---
name: sandbox-pool
description: Manage persistent sandbox pools. Start/stop/status of warm container pools that stay running between features.
---

<!-- Part of agent-sandbox — https://github.com/agent-sandbox/agent-sandbox -->

# Sandbox Pool

Manage persistent sandbox pools for a project. Pool sandboxes stay warm between features, eliminating container startup time.

## Steps

### 1. Detect Project

Extract the project name from the current working directory path. The working directory follows the pattern `C:\Dev\<project>` or `/c/Dev/<project>`. Extract the `<project>` portion directly from the path without running any bash commands.

If the working directory is not under `C:\Dev\` or the project name is `agent-sandbox`, tell the user: "Run this from inside a project directory (e.g., `C:\Dev\myproject`)."

### 2. Parse Action

The user invokes this as `/sandbox-pool <action> [args]`. Parse the action from the arguments.

If no action is provided, default to `status`.

### 3. Execute Action

#### `start [--count N] [--profile P] [--provider P]`

Run:
```bash
bash "$AGENT_SANDBOX_HOME/sandbox.sh" pool start <project> --count <N> [--profile <P>] [--provider <P>] --dangerous
```

Default `--count` to 1 if not specified. Always pass `--dangerous` (pool sandboxes run autonomously).

Report:
```
Pool started for <project>!

  Sandboxes: <N>
  Status:    All idle

Feed work with:
  /sandbox-execute <plan-file>

Check status:
  /sandbox-pool status
```

#### `stop`

Run:
```bash
bash "$AGENT_SANDBOX_HOME/sandbox.sh" pool stop <project>
```

Report:
```
Pool stopped and cleaned up for <project>.
```

#### `status`

Run:
```bash
bash "$AGENT_SANDBOX_HOME/sandbox.sh" pool status <project>
```

Display the output directly to the user. If any sandboxes are in `reviewing` state, suggest:
```
Sandboxes ready for review — run /sandbox-accept to merge.
```
