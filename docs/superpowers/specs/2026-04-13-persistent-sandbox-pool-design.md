# Persistent Sandbox Pool

**Date:** 2026-04-13
**Status:** Draft
**Author:** Nathan Wallman + Claude

## Problem

Every `sandbox start` performs image building, volume creation, dependency installation, provider setup, and post-launch initialization. This takes 2-5 minutes per feature. When working through multiple features sequentially (or in parallel), this startup cost adds up and breaks flow.

## Solution

Introduce a **persistent sandbox pool** — a set of pre-warmed containers that stay running between features. Instead of cold-starting a sandbox per feature, you start a pool once and feed plans to idle sandboxes. Between tasks, the container does a fast restart with a new worktree bind mount (~5-15 seconds), skipping all expensive initialization.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Task handoff model | Mixed/command-driven | Skills and CLI can both push work to warm sandboxes |
| Isolation between tasks | Worktree-per-task | Each plan gets a fresh git worktree — no stale build artifacts |
| Pool sizing | User-controlled | `sandbox pool start <project> --count N` — flexible for sequential or parallel work |
| Completion detection | Hybrid | Agent signals done (process exits), human gates before next task |
| Skill integration | Pool-first with escape hatch | `sandbox-execute` prefers warm sandboxes, `--fresh` forces ephemeral |
| Worktree rotation | Fast container restart with new bind mount | Symlinks cause issues with git worktree paths and provider assumptions |
| State management | Statefile-driven in bash | Simple files in `.pool/` dir, no new runtime dependencies |

## State Model

### State Directory

Located at `<project>/.pool/` (gitignored via the project's `.gitignore`, same mechanism as `.worktrees/`).

Per-sandbox files:

```
<project>/.pool/
  <session>.state      # "idle" | "busy" | "reviewing" | "failed"
  <session>.plan       # Path to current plan file (when busy/reviewing)
  <session>.branch     # Current worktree branch name (when busy/reviewing)
  <session>.provider   # Provider name (set on pool start, reused)
```

### State Transitions

```
idle ──[assign]──→ busy ──[agent exits]──→ reviewing ──[accept]──→ idle
                                                      ──[reject]──→ idle
                     │
                     └──[cancel]──→ reviewing
                     
idle ──[container dies]──→ failed ──[pool start]──→ idle
busy ──[container dies]──→ failed ──[pool start]──→ idle (partial work preserved in worktree)
```

### Concurrency

Two `sandbox pool assign` commands racing for the same idle sandbox are resolved with `flock` on the state file. First writer wins; second finds no idle sandbox and reports accordingly.

## New `sandbox.sh` Subcommands

### `sandbox pool start <project> [--count N] [--profile P] [--provider P]`

Cold-starts N sandboxes (default 1). Creates `.pool/` directory and writes initial state files as "idle". Sessions are named `pool-1`, `pool-2`, etc.

### `sandbox pool stop <project> [--force]`

Stops all pool sandboxes, cleans volumes and worktrees, removes `.pool/` directory. Refuses if any sandbox is in "busy" state unless `--force` is passed. Warns if any sandbox is in "reviewing" state (unmerged work).

### `sandbox pool status <project>`

Lists all pool sandboxes with their current state, branch/plan (if busy or reviewing), container uptime, and Docker health.

### `sandbox pool assign <project> <plan> [--branch B]`

1. Finds first idle sandbox (via `flock` for safe concurrent access)
2. Derives branch name from plan filename (same logic as current `sandbox-execute`: strip date prefix and `.md`)
3. Creates new git worktree on host for the branch
4. `docker compose down` the sandbox (fast — agent is idle)
5. Updates compose environment to point `/workspace` at the new worktree
6. `docker compose up` with `SANDBOX_WARM=true` (skips expensive init)
7. Runs `provider_start` to re-seed auth
8. Generates plan prompt file (same format as `sandbox-execute`), copies into container via `docker cp`
9. Starts the agent process inside the container via `docker exec -d` with the prompt file as input
10. Starts background completion watcher (polls `provider_process_name` via `pgrep`)
11. Writes "busy" to the state file

### `sandbox pool accept <project> <session>`

Validates sandbox is in "reviewing" state. Merges the worktree branch into the project's current branch. Cleans the worktree. Flips state to "idle".

### `sandbox pool reject <project> <session>`

Discards the worktree (no merge). Flips state to "idle".

### `sandbox pool cancel <project> <session>`

Kills the agent process inside the container. Flips state to "reviewing" so partial work can be accepted or rejected.

### `sandbox pool list`

Lists all active pools across all projects (scans for `.pool/` directories).

## Warm Restart: What Gets Skipped

The core performance optimization. The `SANDBOX_WARM=true` env var gates expensive post-launch steps.

### Cold Start (~2-5 minutes)

1. Image build (or cache hit)
2. Worktree creation
3. Docker Compose up (create container, volumes, network)
4. Provider start (auth seeding, config)
5. Ownership fixups
6. `.git` pointer rewrite
7. dos2unix on shell scripts
8. `.env` seeding
9. npm install (parallel)
10. Gradle dependency resolution (parallel)
11. Playwright browser install (if needed)
12. Gradle cache seeding from host

### Warm Restart (~5-15 seconds)

1. Worktree creation on host
2. Docker Compose down + up (new bind mount, same named volumes)
3. Provider start (re-seed auth tokens)
4. `.git` pointer rewrite
5. `.env` seeding

### Skipped on Warm Restart

| Step | Why it's safe to skip |
|------|----------------------|
| Image build | Already built, image cached |
| Volume creation | Named volumes persist across restarts |
| npm install | `node_modules` volumes still populated |
| Gradle deps | `gradle-cache` volume still populated |
| Playwright browsers | Installed in image layer, persists |
| dos2unix | Already done on first start, scripts in image unchanged |
| Ownership fixups | Volumes already have correct ownership |
| Gradle cache seeding | Already seeded from host on first start |

### Implementation

```bash
if [[ "${SANDBOX_WARM:-false}" != "true" ]]; then
    # npm install, gradle deps, playwright, dos2unix, ownership fixups, etc.
fi
# Always run: provider_start, .git rewrite, .env seeding
```

## Completion Detection

### Mechanism

A background watcher process polls for the agent process inside the container.

1. `sandbox pool assign` starts the watcher after injecting the plan
2. Watcher runs `docker exec <container> pgrep -f <agent-process>` every 10 seconds
3. When agent process exits, watcher writes "reviewing" to the state file
4. Optionally sends a Windows desktop notification (PowerShell toast)

### Provider Hook: `provider_process_name`

A new optional provider hook that returns the process name to watch for (e.g., `claude` for Claude Code, `codex` for Codex). The watcher uses this with `pgrep -f` inside the container. If the hook is not implemented, the watcher falls back to checking if any non-init user process is running.

### Why Process Polling (Not Marker Files)

Marker files would require modifying agent behavior or wrapping it in a completion script. Process polling works with any provider via the `provider_process_name` hook — no agent-side changes.

### Edge Cases

| Scenario | Behavior |
|----------|----------|
| Agent crashes | Process exits → state goes to "reviewing" → user sees partial work, can reject |
| Container dies | Docker health check fails → state goes to "failed" → visible in `pool status` |
| User wants to interrupt | `sandbox pool cancel` kills agent process → state goes to "reviewing" |

## Skills

### `sandbox-pool` (New)

**Purpose:** Manage pool lifecycle — start, stop, status.

**Invocation:** `/sandbox-pool <action> [args]`

| Action | Behavior |
|--------|----------|
| `start [--count N] [--profile P] [--provider P]` | Infers project from cwd. Runs `sandbox pool start`. Reports which sandboxes are ready. |
| `stop` | Infers project. Warns if busy/reviewing sandboxes exist. Runs `sandbox pool stop`. |
| `status` | Infers project. Runs `sandbox pool status`. Presents formatted pool overview. |

### `sandbox-execute` (Updated)

**Current behavior:** Always cold-starts a new ephemeral sandbox.

**New behavior:**

1. Check if project has an active pool (`.pool/` dir exists with state files)
2. If pool exists, find first idle sandbox
3. If idle sandbox found → `sandbox pool assign` (warm path)
4. If no idle sandbox → warn "All pool sandboxes are busy", offer:
   - Wait for one to finish
   - Cold-start an ephemeral sandbox (current behavior)
5. If no pool exists → cold-start an ephemeral sandbox (current behavior)
6. `--fresh` flag → always cold-start, ignore pool

Plan detection, prompt generation, and launch script creation remain unchanged.

### `sandbox-accept` (New)

**Purpose:** Human gate between agent completion and next task assignment.

**Invocation:** `/sandbox-accept [session]`

**Flow:**

1. Infer project from cwd
2. Find sandboxes in "reviewing" state
3. If multiple, present interactive picker
4. Show summary: branch name, plan executed, commit count
5. Offer actions:
   - **Accept & merge** → `sandbox pool accept` (merge, clean worktree, flip to idle)
   - **Review first** → show diff (`sandbox diff`) for inspection
   - **Reject** → `sandbox pool reject` (discard worktree, flip to idle)
6. Report result

### `sandbox-merge` (Updated)

When merging a sandbox that belongs to a pool, delegates to `sandbox pool accept` instead of tearing down the container. Non-pool sandboxes work exactly as before.

### Skill File Locations

```
skills/
  sandbox-pool/SKILL.md        # New
  sandbox-accept/SKILL.md      # New
  sandbox-execute/SKILL.md     # Updated
  sandbox-merge/SKILL.md       # Updated
```

## Error Handling

| Scenario | Recovery |
|----------|----------|
| Host reboots mid-task | Containers stop. Pool state files persist on disk. `sandbox pool start` detects existing `.pool/` dir and restarts containers. |
| State says "busy" but container is dead | `sandbox pool status` cross-references Docker state. Reports "stale — container not running" and offers repair. |
| State says "idle" but worktree still exists | `sandbox pool assign` cleans up leftover worktree before creating a new one. |
| `.pool/` dir exists but no containers | `sandbox pool start` restarts containers for existing pool entries. |
| User runs `sandbox stop` on a pool sandbox | Allowed. `sandbox pool status` detects mismatch and warns. State file stays — `sandbox pool start` can recover. |

## Backwards Compatibility

- Non-pool sandboxes (`sandbox start/stop/shell/merge`) work exactly as today. Zero changes to existing behavior.
- Pool sandboxes appear in `sandbox list` with a `[pool]` tag so they don't look like orphans.
- `sandbox-execute` without a pool falls back to current cold-start behavior transparently.
- All new functionality is additive — no existing commands, flags, or behaviors change.

## Typical Workflow

```
# Start of day: warm up a pool
/sandbox-pool start --count 2

# Feed features — each assignment takes ~10 seconds, not minutes
/sandbox-execute docs/superpowers/plans/add-phone-validation.md
/sandbox-execute docs/superpowers/plans/fix-currency-display.md

# Check on progress
/sandbox-pool status

# Agent finishes phone validation
/sandbox-accept
  → review diff, accept & merge
  → sandbox is idle, ready for next plan

# Feed another feature to the now-idle sandbox
/sandbox-execute docs/superpowers/plans/refactor-auth-middleware.md

# End of day: tear down
/sandbox-pool stop
```
