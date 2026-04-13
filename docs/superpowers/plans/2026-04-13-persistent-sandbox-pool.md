# Persistent Sandbox Pool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent sandbox pool system so containers stay warm between features, reducing per-feature startup from minutes to seconds.

**Architecture:** New `sandbox pool` subcommands in `sandbox.sh` manage pool state via simple files in `<project>/.pool/`. Pool sandboxes are normal sandboxes with state tracking. A `--warm` flag on `cmd_start` skips expensive post-launch init. Merge logic is extracted into a shared `_do_merge` helper used by both `cmd_merge` and `cmd_pool_accept`. Three skills (`sandbox-pool`, `sandbox-accept`, updated `sandbox-execute`) provide the user-facing workflow.

**Tech Stack:** Bash (sandbox.sh), Markdown (SKILL.md files), Docker Compose, PowerShell (sandbox.ps1 wrapper)

**Architectural decisions from review:**
- `--warm` flag on `cmd_start` instead of `SANDBOX_WARM` env var (avoids export leak, EXIT trap collision, "already running" early exit)
- No intermediate "claiming" state — write "busy" directly under flock (simpler, no orphan states)
- Shared `_do_merge` helper instead of duplicating merge logic (single source of truth for artifact cleanup)
- Watcher PIDs tracked in state dir and killed on cancel/stop/reassign (prevents stale watchers)
- `pgrep -f "[c]laude"` bracket trick to exclude pgrep itself from matching

---

### Task 1: Add Pool State Helper Functions to sandbox.sh

**Files:**
- Modify: `sandbox.sh` (insert after `validate_branch_name()` ~line 236, before `validate_env_pair()`)

- [ ] **Step 1: Add pool state helpers**

```bash
# --- Pool state helpers ---

# Pool directory for a project
# Usage: pool_dir <project>
pool_dir() {
    echo "$SANDBOX_BASE_DIR/$1/.pool"
}

# Read a pool sandbox state file safely
# Usage: pool_read_state <project> <session>
# Returns: idle | busy | reviewing | failed (or empty if missing)
pool_read_state() {
    local state_file="$(pool_dir "$1")/$2.state"
    [[ -f "$state_file" ]] && cat "$state_file" || echo ""
}

# Write a pool sandbox state file with flock for concurrency safety
# Usage: pool_write_state <project> <session> <state>
pool_write_state() {
    local state_file="$(pool_dir "$1")/$2.state"
    (
        flock -x 200
        echo "$3" > "$state_file"
    ) 200>"${state_file}.lock"
}

# Atomically find and claim the first idle pool sandbox by writing "busy" under flock.
# Usage: pool_claim_idle <project>
# Returns: session name (or empty if none idle)
# Side effect: sets claimed sandbox state to "busy"
pool_claim_idle() {
    local pdir
    pdir="$(pool_dir "$1")"
    [[ -d "$pdir" ]] || return 0
    for state_file in "$pdir"/pool-*.state; do
        [[ -f "$state_file" ]] || continue
        local session
        session=$(basename "${state_file%.state}")
        # Atomic read-and-claim under exclusive flock
        local claimed
        claimed=$(
            flock -x 200
            local state
            state=$(cat "$state_file" 2>/dev/null)
            if [[ "$state" == "idle" ]]; then
                echo "busy" > "$state_file"
                echo "$session"
            fi
        ) 200>"${state_file}.lock"
        if [[ -n "$claimed" ]]; then
            echo "$claimed"
            return 0
        fi
    done
}

# Check if a session belongs to a pool
# Usage: is_pool_sandbox <project> <session>
# Returns: 0 if pool sandbox, 1 if not
is_pool_sandbox() {
    local state_file="$(pool_dir "$1")/$2.state"
    [[ -f "$state_file" ]]
}

# Kill a running watcher process for a pool sandbox
# Usage: pool_kill_watcher <project> <session>
pool_kill_watcher() {
    local pid_file="$(pool_dir "$1")/$2.watcher-pid"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        kill "$pid" 2>/dev/null || true
        rm -f "$pid_file"
    fi
}
```

- [ ] **Step 2: Verify no syntax errors**

Run: `bash -n sandbox.sh`
Expected: No output (clean parse)

- [ ] **Step 3: Commit**

```bash
git add sandbox.sh
git commit -m "feat: add pool state helper functions to sandbox.sh"
```

---

### Task 2: Add `--warm` Flag to `cmd_start`

**Files:**
- Modify: `sandbox.sh` (the `cmd_start` function, lines 378-956)

The `--warm` flag makes `cmd_start` safe for pool usage by:
1. Skipping the "already running → exit 0" early return
2. Skipping worktree creation (caller already created it)
3. Skipping image builds (already built on cold start)
4. Skipping expensive post-launch init (deps, ownership, dos2unix, playwright, gradle cache)
5. Always running: provider_start, .git pointer rewrite, .env seeding

- [ ] **Step 1: Add `--warm` flag to arg parsing**

Find the arg parsing block in `cmd_start` (around line 396):

```bash
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile) profile="$2"; shift 2 ;;
            --branch) branch="$2"; shift 2 ;;
            --provider) provider="$2"; shift 2 ;;
            --env) extra_env+=("$2"); shift 2 ;;
            --dangerous) dangerous=true; shift ;;
            --read-only) read_only=true; shift ;;
            --open-network) open_network=true; shift ;;
            --docker) docker=true; shift ;;
```

Add `--warm` to the case block:

```bash
            --warm) warm=true; shift ;;
```

And add the variable initialization before the while loop (alongside the other `local` declarations around line 384):

```bash
    local warm=false
```

- [ ] **Step 2: Make the "already running" check respect --warm**

Find the early exit check (around line 507):

```bash
    # Check if already running
    if docker compose -p "$comp_name" ps --status running 2>/dev/null | grep -q "agent"; then
        echo "Sandbox '$comp_name' is already running."
        echo "Use 'sandbox shell $project $session' to connect."
        exit 0
    fi
```

Replace with:

```bash
    # Check if already running (--warm skips this — pool restarts intentionally)
    if [[ "$warm" == "false" ]]; then
        if docker compose -p "$comp_name" ps --status running 2>/dev/null | grep -q "agent"; then
            echo "Sandbox '$comp_name' is already running."
            echo "Use 'sandbox shell $project $session' to connect."
            exit 0
        fi
    fi
```

- [ ] **Step 3: Skip worktree creation when --warm**

Find the worktree creation block (around line 472):

```bash
    # Create or reuse git worktree for session isolation
    local wt_dir
    wt_dir="$(worktree_dir "$project")"
    mkdir -p "$wt_dir"
```

Wrap the entire worktree block (through line 493) with:

```bash
    if [[ "$warm" == "false" ]]; then
        # Create or reuse git worktree for session isolation
        local wt_dir
        wt_dir="$(worktree_dir "$project")"
        ...existing worktree creation code...
    fi
```

The `.sandbox-meta` write and profile detection that follow the worktree block must still run. The worktree_path variable is needed later, so compute it outside the warm gate:

```bash
    local worktree_path
    worktree_path="$(resolve_worktree "$project" "$session")"

    if [[ "$warm" == "false" ]]; then
        # Create or reuse git worktree...
        ...
    fi

    # Store branch name and provider (always, in case --warm changed branch)
    printf '%s\n%s\n' "$branch" "$provider" > "${worktree_path}.sandbox-meta"
```

- [ ] **Step 4: Skip image builds when --warm**

Find the image build section (around line 514). Wrap everything from "Build base image if needed" through "Build dind image if needed" (through line 552) with:

```bash
    if [[ "$warm" == "false" ]]; then
        # Build base image if needed
        ...existing image build code...
    fi
```

- [ ] **Step 5: Gate expensive post-launch init with --warm**

After `docker compose up -d` (line 768), the init sequence begins. Wrap the cold-only blocks:

```bash
    if [[ "$warm" == "false" ]]; then
        # Fix ownership on session-local volumes (created as root by Docker)
        if [[ "$profile" == "java" || "$profile" == "fullstack" ]]; then
            docker exec -u root "${comp_name}-agent" bash -c \
                "chown agent:agent /home/agent/.gradle /build-output || true"
        fi
        # Fix ownership on node_modules volumes (created as root by Docker)
        docker exec -u root "${comp_name}-agent" bash -c \
            'for d in /workspace/node_modules /workspace/*/node_modules; do [ -d "$d" ] && chown agent:agent "$d"; done' 2>/dev/null || true
    fi

    # Provider-specific post-start initialization (always runs — re-seeds auth)
    provider_start "${comp_name}-agent" "$dangerous"

    if [[ "$warm" == "false" ]]; then
        # Gradle cache seeding from host
        ...existing gradle cache seeding block...

        # Gradle performance tuning
        ...existing gradle performance block...

        # Testcontainers config
        ...existing testcontainers block...

        # Playwright browser install
        ...existing playwright block...

        # dos2unix
        ...existing dos2unix block...
    fi
```

The `.git` pointer rewrite and `.env` seeding must ALWAYS run (outside the gate) since each new worktree needs them.

For the npm install and Gradle dependency resolution blocks, wrap them with the warm gate. **Important:** Guard the `wait` calls to avoid referencing undefined PID variables:

```bash
    if [[ "$warm" == "false" && "$read_only" == "false" ]]; then
        # npm install
        docker exec "${comp_name}-agent" bash -c '...' &
        local npm_pid=$!

        # Gradle build output symlinks
        docker exec "${comp_name}-agent" bash -c '...'

        # Gradle dependency resolution
        docker exec "${comp_name}-agent" bash -c '...' &
        local gradle_pid=$!

        # Wait for npm
        wait $npm_pid 2>/dev/null || true
    fi
```

Remove the old standalone `wait $npm_pid` line that's outside the block.

- [ ] **Step 6: Verify no syntax errors**

Run: `bash -n sandbox.sh`
Expected: No output (clean parse)

- [ ] **Step 7: Test cold start still works**

Run: `bash sandbox.sh start <test-project> test-cold --provider claude-code`
Expected: Full init runs (npm install, ownership fixups, etc.)
Run: `bash sandbox.sh stop <test-project> test-cold --clean`

- [ ] **Step 8: Commit**

```bash
git add sandbox.sh
git commit -m "feat: add --warm flag to cmd_start for pool warm restarts"
```

---

### Task 3: Extract `_do_merge` Helper from `cmd_merge`

**Files:**
- Modify: `sandbox.sh` (refactor `cmd_merge` at lines 1273-1415)

Extract the core merge logic (artifact cleanup, validation, merge) into a shared function. Both `cmd_merge` and the later `cmd_pool_accept` will call this.

- [ ] **Step 1: Create `_do_merge` function**

Insert before `cmd_merge`:

```bash
# Shared merge logic: clean artifacts, validate, merge branch.
# Does NOT stop containers or remove worktrees — callers handle lifecycle.
# Usage: _do_merge <project_path> <worktree_path> <branch_name>
# Returns: 0 on success, 1 on failure (uncommitted changes, no commits, conflicts)
_do_merge() {
    local project_path="$1"
    local worktree_path="$2"
    local branch_name="$3"

    # Restore .git pointer
    local worktree_name
    worktree_name=$(basename "$worktree_path")
    local git_path="$project_path/.git/worktrees/$worktree_name"
    if [[ "$git_path" =~ ^/([a-zA-Z])/ ]]; then
        git_path="${BASH_REMATCH[1]^}:${git_path:2}"
    fi
    echo "gitdir: $git_path" > "$worktree_path/.git"

    # Clean sandbox artifacts
    echo "Cleaning sandbox artifacts..."
    local artifact_patterns=(
        '*.sh' 'gradlew' 'gradlew.bat'
        'openapi.json' '*/openapi.json'
        'package-lock.json' '*/package-lock.json'
        'pnpm-lock.yaml' '*/pnpm-lock.yaml'
        'yarn.lock' '*/yarn.lock'
    )
    git -C "$worktree_path" diff --name-only 2>/dev/null | while IFS= read -r f; do
        local is_artifact=false
        if git -C "$worktree_path" diff --ignore-cr-at-eol --quiet -- "$f" 2>/dev/null; then
            is_artifact=true
        fi
        for pat in "${artifact_patterns[@]}"; do
            # shellcheck disable=SC2254
            case "$f" in $pat) is_artifact=true ;; esac
        done
        if [[ "$is_artifact" == "true" ]]; then
            git -C "$worktree_path" checkout -- "$f" 2>/dev/null
        fi
    done

    find "$worktree_path" -maxdepth 3 -type d \( -name 'build' -o -name '.gradle' \) \
        -exec rm -rf {} + 2>/dev/null || true
    find "$worktree_path" -maxdepth 2 -name 'package-lock.json' -newer "$worktree_path/.git" \
        -exec rm -f {} + 2>/dev/null || true

    # Validate: uncommitted changes
    local uncommitted
    uncommitted=$(git -C "$worktree_path" status --porcelain 2>/dev/null || true)
    if [[ -n "$uncommitted" ]]; then
        echo "ERROR: Worktree has uncommitted changes:" >&2
        git -C "$worktree_path" status --short >&2
        return 1
    fi

    # Validate: commits exist
    local current_branch
    current_branch=$(git -C "$project_path" rev-parse --abbrev-ref HEAD)
    local commit_count
    commit_count=$(git -C "$project_path" rev-list --count "${current_branch}..${branch_name}" 2>/dev/null || echo "0")
    if [[ "$commit_count" -eq 0 ]]; then
        echo "ERROR: No commits found on branch '$branch_name' beyond '$current_branch'." >&2
        return 1
    fi

    echo "Merging '$branch_name' into '$current_branch' ($commit_count commits)"
    echo ""
    git --no-pager -C "$project_path" diff --stat "${current_branch}...${branch_name}" 2>/dev/null
    echo ""

    # Perform the merge
    if ! git -C "$project_path" merge "$branch_name" --no-edit; then
        echo "Merge failed (conflicts?). Resolve in: $project_path"
        return 1
    fi

    echo "Merge complete. Branch '$branch_name' merged into '$current_branch'."
    return 0
}
```

- [ ] **Step 2: Refactor `cmd_merge` to use `_do_merge`**

Replace the body of `cmd_merge` (from the "Stop the sandbox" section through the merge) with calls to `_do_merge`. Keep the existing arg parsing, worktree/branch resolution, and the stop/cleanup logic:

```bash
cmd_merge() {
    local project="$1"
    local session="$2"
    shift 2

    validate_session_name "$session"

    local clean=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --clean) clean=true ;;
        esac
        shift
    done

    local worktree_path
    worktree_path="$(resolve_worktree "$project" "$session")"
    local project_path="$SANDBOX_BASE_DIR/$project"
    local comp_name
    comp_name=$(compose_project_name "$project" "$session")

    if [[ ! -d "$worktree_path" ]]; then
        echo "ERROR: No worktree found at $worktree_path" >&2
        exit 1
    fi

    local branch_name="$session"
    if [[ -f "${worktree_path}.sandbox-meta" ]]; then
        branch_name=$(sed -n '1p' "${worktree_path}.sandbox-meta")
    fi

    # Stop the sandbox if running
    if docker compose -p "$comp_name" ps --status running 2>/dev/null | grep -q "agent"; then
        echo "Stopping sandbox first..."
        cmd_stop "$project" "$session"
        echo ""
    fi

    # Run shared merge logic
    if ! _do_merge "$project_path" "$worktree_path" "$branch_name"; then
        echo ""
        echo "Options:"
        echo "  sandbox shell $project $session   # Reconnect"
        echo "  sandbox diff $project $session     # Review changes"
        exit 1
    fi

    if [[ "$clean" == "true" ]]; then
        echo ""
        echo "Cleaning up sandbox..."
        cmd_stop "$project" "$session" --clean
    else
        echo ""
        echo "Next steps:"
        echo "  sandbox stop $project $session --clean   # Remove worktree, volumes, and branch"
    fi
}
```

- [ ] **Step 3: Verify no syntax errors**

Run: `bash -n sandbox.sh`
Expected: No output (clean parse)

- [ ] **Step 4: Test that existing merge still works**

Start a sandbox, make a commit inside it, then merge:
```bash
bash sandbox.sh start <test-project> test-merge
# ... make a change and commit inside the sandbox ...
bash sandbox.sh merge <test-project> test-merge --clean
```
Expected: Merges successfully, cleans up

- [ ] **Step 5: Commit**

```bash
git add sandbox.sh
git commit -m "refactor: extract _do_merge helper from cmd_merge"
```

---

### Task 4: Implement `cmd_pool_start`

**Files:**
- Modify: `sandbox.sh` (add before `# --- Main ---` section)

- [ ] **Step 1: Add cmd_pool_start function**

```bash
# --- Pool commands ---

cmd_pool_start() {
    local project=""
    local count=1
    local profile=""
    local provider=""
    local dangerous=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --count) count="$2"; shift 2 ;;
            --profile) profile="$2"; shift 2 ;;
            --provider) provider="$2"; shift 2 ;;
            --dangerous) dangerous=true; shift ;;
            *)
                if [[ -z "$project" ]]; then
                    project="$1"
                else
                    echo "ERROR: Unexpected argument: $1" >&2
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$project" ]]; then
        echo "ERROR: pool start requires <project>" >&2
        exit 1
    fi

    local project_path="$SANDBOX_BASE_DIR/$project"
    if [[ ! -d "$project_path" ]]; then
        echo "ERROR: Project directory not found: $project_path" >&2
        exit 1
    fi

    # Create pool directory and gitignore it
    local pdir
    pdir="$(pool_dir "$project")"
    mkdir -p "$pdir"
    if ! grep -qxF '/.pool' "$project_path/.gitignore" 2>/dev/null; then
        echo '/.pool' >> "$project_path/.gitignore"
    fi

    echo "Starting pool for '$project' with $count sandbox(es)..."
    echo ""

    local start_args=()
    [[ -n "$profile" ]] && start_args+=(--profile "$profile")
    [[ -n "$provider" ]] && start_args+=(--provider "$provider")
    [[ "$dangerous" == "true" ]] && start_args+=(--dangerous)

    for i in $(seq 1 "$count"); do
        local session="pool-${i}"

        # Check if this pool sandbox already exists
        if [[ -f "$pdir/${session}.state" ]]; then
            local existing_state
            existing_state=$(pool_read_state "$project" "$session")
            echo "  Pool sandbox '$session' already exists (state: $existing_state)"

            # If container is down, restart it
            local comp_name
            comp_name=$(compose_project_name "$project" "$session")
            if ! docker compose -p "$comp_name" ps --status running 2>/dev/null | grep -q "agent"; then
                echo "  Restarting container for '$session'..."
                # Run in subshell to isolate cmd_start EXIT trap
                ( cmd_start "$project" "$session" "${start_args[@]}" )
                pool_write_state "$project" "$session" "idle"
            fi
            continue
        fi

        echo "  Starting pool sandbox: $session"
        # Run in subshell to isolate cmd_start EXIT trap (M1 fix)
        ( cmd_start "$project" "$session" "${start_args[@]}" )

        # Write initial pool state
        pool_write_state "$project" "$session" "idle"

        # Record provider for later reconnection
        local used_provider="${provider:-$SANDBOX_PROVIDER}"
        echo "$used_provider" > "$pdir/${session}.provider"

        echo "  Pool sandbox '$session' is idle and ready."
        echo ""
    done

    echo "Pool ready. $count sandbox(es) idle for '$project'."
    echo ""
    echo "  Assign work:  sandbox pool assign $project <plan-file>"
    echo "  Check status:  sandbox pool status $project"
}
```

- [ ] **Step 2: Verify no syntax errors**

Run: `bash -n sandbox.sh`
Expected: No output (clean parse)

- [ ] **Step 3: Commit**

```bash
git add sandbox.sh
git commit -m "feat: implement cmd_pool_start for persistent sandbox pools"
```

---

### Task 5: Implement `cmd_pool_status`

**Files:**
- Modify: `sandbox.sh` (add after `cmd_pool_start`)

- [ ] **Step 1: Add cmd_pool_status function**

```bash
cmd_pool_status() {
    local project="$1"

    if [[ -z "$project" ]]; then
        echo "ERROR: pool status requires <project>" >&2
        exit 1
    fi

    local pdir
    pdir="$(pool_dir "$project")"

    if [[ ! -d "$pdir" ]]; then
        echo "No pool found for '$project'."
        return
    fi

    echo "Pool status for '$project':"
    echo ""

    local total=0
    local idle_count=0
    local busy_count=0
    local reviewing_count=0

    for state_file in "$pdir"/pool-*.state; do
        [[ -f "$state_file" ]] || continue
        local session
        session=$(basename "${state_file%.state}")
        local state
        state=$(cat "$state_file")
        total=$((total + 1))

        local comp_name
        comp_name=$(compose_project_name "$project" "$session")
        local container_status="unknown"
        if docker compose -p "$comp_name" ps --status running 2>/dev/null | grep -q "agent"; then
            container_status="running"
        else
            container_status="stopped"
        fi

        # Cross-reference: state says busy but container is down
        local flag=""
        if [[ "$container_status" == "stopped" && "$state" == "busy" ]]; then
            state="failed"
            pool_write_state "$project" "$session" "failed"
            flag=" (was busy, container died)"
        elif [[ "$container_status" == "stopped" && "$state" == "idle" ]]; then
            flag=" (container not running)"
        fi

        printf "  %-12s  state=%-10s  container=%-8s" "$session" "$state" "$container_status"

        case "$state" in
            idle) idle_count=$((idle_count + 1)) ;;
            busy) busy_count=$((busy_count + 1)) ;;
            reviewing) reviewing_count=$((reviewing_count + 1)) ;;
        esac

        # Show branch and plan if busy or reviewing
        if [[ "$state" == "busy" || "$state" == "reviewing" ]]; then
            local branch=""
            local plan=""
            [[ -f "$pdir/${session}.branch" ]] && branch=$(cat "$pdir/${session}.branch")
            [[ -f "$pdir/${session}.plan" ]] && plan=$(cat "$pdir/${session}.plan")
            [[ -n "$branch" ]] && printf "  branch=%s" "$branch"
            [[ -n "$plan" ]] && printf "  plan=%s" "$(basename "$plan")"
        fi

        echo "$flag"
    done

    echo ""
    echo "  Total: $total  Idle: $idle_count  Busy: $busy_count  Reviewing: $reviewing_count"
}
```

- [ ] **Step 2: Verify no syntax errors**

Run: `bash -n sandbox.sh`
Expected: No output (clean parse)

- [ ] **Step 3: Commit**

```bash
git add sandbox.sh
git commit -m "feat: implement cmd_pool_status"
```

---

### Task 6: Implement `cmd_pool_assign`

**Files:**
- Modify: `sandbox.sh` (add after `cmd_pool_status`)

This is the core command — claims an idle sandbox (atomically via `pool_claim_idle`), creates a worktree, does a warm restart with `cmd_start --warm`, and starts a background completion watcher with tracked PID.

- [ ] **Step 1: Add cmd_pool_assign function**

```bash
cmd_pool_assign() {
    local project=""
    local plan=""
    local branch=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --branch) branch="$2"; shift 2 ;;
            *)
                if [[ -z "$project" ]]; then
                    project="$1"
                elif [[ -z "$plan" ]]; then
                    plan="$1"
                else
                    echo "ERROR: Unexpected argument: $1" >&2
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$project" || -z "$plan" ]]; then
        echo "ERROR: pool assign requires <project> <plan-file>" >&2
        exit 1
    fi

    local project_path="$SANDBOX_BASE_DIR/$project"
    if [[ ! -d "$project_path" ]]; then
        echo "ERROR: Project directory not found: $project_path" >&2
        exit 1
    fi

    if [[ ! -f "$plan" && ! -f "$project_path/$plan" ]]; then
        echo "ERROR: Plan file not found: $plan" >&2
        exit 1
    fi

    # Resolve plan to absolute path
    if [[ -f "$project_path/$plan" ]]; then
        plan="$project_path/$plan"
    fi

    # Derive branch name from plan filename if not specified
    if [[ -z "$branch" ]]; then
        local plan_basename
        plan_basename=$(basename "$plan" .md)
        branch=$(echo "$plan_basename" | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//')
    fi
    validate_branch_name "$branch"

    # Atomically claim an idle sandbox (writes "busy" under flock)
    local session
    session=$(pool_claim_idle "$project")

    if [[ -z "$session" ]]; then
        echo "ERROR: No idle pool sandbox available for '$project'." >&2
        echo "Check status: sandbox pool status $project" >&2
        exit 1
    fi

    local pdir
    pdir="$(pool_dir "$project")"
    local comp_name
    comp_name=$(compose_project_name "$project" "$session")

    echo "Assigning plan to pool sandbox '$session'..."
    echo "  Plan:   $(basename "$plan")"
    echo "  Branch: $branch"
    echo ""

    # Kill any stale watcher from a previous assignment
    pool_kill_watcher "$project" "$session"

    # Create worktree for this task
    local wt_dir
    wt_dir="$(worktree_dir "$project")"
    mkdir -p "$wt_dir"
    local worktree_path="$wt_dir/${project}--${session}"

    # Clean up old worktree if leftover from a previous task
    if [[ -d "$worktree_path" ]]; then
        echo "  Cleaning up previous worktree..."
        git -C "$project_path" config core.longpaths true
        git -C "$project_path" worktree remove "$worktree_path" --force 2>/dev/null \
            || rm -rf "$worktree_path"
    fi

    # Create fresh worktree
    if ! git -C "$project_path" rev-parse --verify "$branch" &>/dev/null; then
        git -C "$project_path" branch "$branch"
    fi
    git -C "$project_path" worktree add "$worktree_path" "$branch"

    # Stop the container (fast — agent is idle)
    echo "  Restarting sandbox with new worktree..."
    docker compose -p "$comp_name" down 2>/dev/null
    # Wait for container to fully stop before warm restart
    while docker compose -p "$comp_name" ps --status running 2>/dev/null | grep -q "agent"; do
        sleep 1
    done

    # Warm restart with new bind mount — passes --branch so metadata is correct
    local provider_name
    provider_name=$(cat "$pdir/${session}.provider" 2>/dev/null || echo "$SANDBOX_PROVIDER")
    ( cmd_start "$project" "$session" --warm --branch "$branch" --provider "$provider_name" --dangerous )

    # Record task metadata
    echo "$plan" > "$pdir/${session}.plan"
    echo "$branch" > "$pdir/${session}.branch"
    # State is already "busy" from pool_claim_idle

    echo ""
    echo "Pool sandbox '$session' is now working on branch '$branch'."
    echo ""
    echo "  Check status:  sandbox pool status $project"
    echo "  View logs:     sandbox logs $project $session"
    echo "  Cancel:        sandbox pool cancel $project $session"

    # Start background completion watcher with PID tracking
    _pool_start_watcher "$project" "$session" "$comp_name" &
    local watcher_pid=$!
    echo "$watcher_pid" > "$pdir/${session}.watcher-pid"
    disown "$watcher_pid"
}
```

- [ ] **Step 2: Add the background watcher function**

```bash
# Background watcher: polls for agent process exit, flips state to "reviewing"
_pool_start_watcher() {
    local project="$1"
    local session="$2"
    local comp_name="$3"

    # Determine agent process name from provider hook (or default)
    local process_pattern="[c]laude"
    if type provider_process_name &>/dev/null; then
        local raw_pattern
        raw_pattern=$(provider_process_name)
        # Apply bracket trick: "claude" -> "[c]laude" to exclude pgrep itself
        process_pattern="[${raw_pattern:0:1}]${raw_pattern:1}"
    fi

    # Wait for the agent process to appear (max 60 seconds)
    local waited=0
    while [[ $waited -lt 60 ]]; do
        if docker exec "${comp_name}-agent" pgrep -f "$process_pattern" &>/dev/null; then
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done

    # Poll until agent process exits
    while true; do
        sleep 10
        # Check container is still running
        if ! docker compose -p "$comp_name" ps --status running 2>/dev/null | grep -q "agent"; then
            pool_write_state "$project" "$session" "failed"
            rm -f "$(pool_dir "$project")/${session}.watcher-pid"
            return
        fi
        # Check if agent process is still running
        if ! docker exec "${comp_name}-agent" pgrep -f "$process_pattern" &>/dev/null; then
            pool_write_state "$project" "$session" "reviewing"
            rm -f "$(pool_dir "$project")/${session}.watcher-pid"
            # Send Windows desktop notification
            powershell.exe -Command "
                [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
                \$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(0)
                \$xml.GetElementsByTagName('text')[0].AppendChild(\$xml.CreateTextNode('Sandbox $session finished work on $project')) | Out-Null
                [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Agent Sandbox').Show([Windows.UI.Notifications.ToastNotification]::new(\$xml))
            " 2>/dev/null &
            return
        fi
    done
}
```

- [ ] **Step 3: Verify no syntax errors**

Run: `bash -n sandbox.sh`
Expected: No output (clean parse)

- [ ] **Step 4: Commit**

```bash
git add sandbox.sh
git commit -m "feat: implement cmd_pool_assign with warm restart and completion watcher"
```

---

### Task 7: Implement `cmd_pool_accept`, `cmd_pool_reject`, and `cmd_pool_cancel`

**Files:**
- Modify: `sandbox.sh` (add after `cmd_pool_assign`)

`cmd_pool_accept` uses `_do_merge` (from Task 3) for the merge logic, and wraps state read+write under flock to prevent race conditions.

- [ ] **Step 1: Add cmd_pool_accept function**

```bash
cmd_pool_accept() {
    local project="$1"
    local session="$2"

    if [[ -z "$project" || -z "$session" ]]; then
        echo "ERROR: pool accept requires <project> <session>" >&2
        exit 1
    fi

    # Atomic state check under flock (M2 fix)
    local pdir
    pdir="$(pool_dir "$project")"
    local state_file="$pdir/${session}.state"
    local verified
    verified=$(
        flock -x 200
        local state
        state=$(cat "$state_file" 2>/dev/null)
        if [[ "$state" == "reviewing" ]]; then
            echo "accepting" > "$state_file"
            echo "yes"
        fi
    ) 200>"${state_file}.lock"

    if [[ "$verified" != "yes" ]]; then
        local state
        state=$(pool_read_state "$project" "$session")
        echo "ERROR: Pool sandbox '$session' is in state '$state', not 'reviewing'." >&2
        exit 1
    fi

    local project_path="$SANDBOX_BASE_DIR/$project"
    local worktree_path
    worktree_path="$(resolve_worktree "$project" "$session")"
    local comp_name
    comp_name=$(compose_project_name "$project" "$session")

    local branch_name
    branch_name=$(cat "$pdir/${session}.branch" 2>/dev/null || echo "$session")

    echo "Merging pool sandbox '$session' (branch: $branch_name)..."

    # Kill watcher if still running
    pool_kill_watcher "$project" "$session"

    # Stop container to restore git pointer for host-side merge
    if docker compose -p "$comp_name" ps --status running 2>/dev/null | grep -q "agent"; then
        cmd_stop "$project" "$session"
    fi

    # Use shared merge logic
    if ! _do_merge "$project_path" "$worktree_path" "$branch_name"; then
        echo ""
        echo "Reconnect with: sandbox shell $project $session"
        # Restart container so user can fix
        local provider_name
        provider_name=$(cat "$pdir/${session}.provider" 2>/dev/null || echo "$SANDBOX_PROVIDER")
        ( cmd_start "$project" "$session" --warm --branch "$branch_name" --provider "$provider_name" --dangerous )
        pool_write_state "$project" "$session" "reviewing"
        exit 1
    fi

    # Clean up the worktree (but NOT volumes — pool keeps them)
    if [[ -d "$worktree_path" ]]; then
        git -C "$project_path" config core.longpaths true
        git -C "$project_path" worktree remove "$worktree_path" --force 2>/dev/null \
            || rm -rf "$worktree_path"
        rm -f "${worktree_path}.sandbox-meta"
        git -C "$project_path" branch -d "$branch_name" 2>/dev/null || true
    fi

    # Clean up task metadata and set idle
    rm -f "$pdir/${session}.plan" "$pdir/${session}.branch"
    pool_write_state "$project" "$session" "idle"

    # Restart the container so it's warm for next task
    echo ""
    echo "Restarting pool sandbox '$session' for next task..."
    local provider_name
    provider_name=$(cat "$pdir/${session}.provider" 2>/dev/null || echo "$SANDBOX_PROVIDER")
    ( cmd_start "$project" "$session" --warm --provider "$provider_name" --dangerous )

    echo ""
    echo "Pool sandbox '$session' is idle and ready for next task."
}
```

- [ ] **Step 2: Add cmd_pool_reject function**

```bash
cmd_pool_reject() {
    local project="$1"
    local session="$2"

    if [[ -z "$project" || -z "$session" ]]; then
        echo "ERROR: pool reject requires <project> <session>" >&2
        exit 1
    fi

    # Atomic state check under flock (M2 fix)
    local pdir
    pdir="$(pool_dir "$project")"
    local state_file="$pdir/${session}.state"
    local verified
    verified=$(
        flock -x 200
        local state
        state=$(cat "$state_file" 2>/dev/null)
        if [[ "$state" == "reviewing" ]]; then
            echo "rejecting" > "$state_file"
            echo "yes"
        fi
    ) 200>"${state_file}.lock"

    if [[ "$verified" != "yes" ]]; then
        local state
        state=$(pool_read_state "$project" "$session")
        echo "ERROR: Pool sandbox '$session' is in state '$state', not 'reviewing'." >&2
        exit 1
    fi

    local project_path="$SANDBOX_BASE_DIR/$project"
    local worktree_path
    worktree_path="$(resolve_worktree "$project" "$session")")
    local comp_name
    comp_name=$(compose_project_name "$project" "$session")

    local branch_name
    branch_name=$(cat "$pdir/${session}.branch" 2>/dev/null || echo "$session")

    echo "Rejecting pool sandbox '$session' (discarding branch: $branch_name)..."

    # Kill watcher if still running
    pool_kill_watcher "$project" "$session"

    # Stop container, restore git pointer
    if docker compose -p "$comp_name" ps --status running 2>/dev/null | grep -q "agent"; then
        cmd_stop "$project" "$session"
    fi

    # Remove worktree and branch
    if [[ -d "$worktree_path" ]]; then
        git -C "$project_path" config core.longpaths true
        git -C "$project_path" worktree remove "$worktree_path" --force 2>/dev/null \
            || rm -rf "$worktree_path"
        rm -f "${worktree_path}.sandbox-meta"
        git -C "$project_path" branch -D "$branch_name" 2>/dev/null || true
    fi

    # Clean up task metadata and set idle
    rm -f "$pdir/${session}.plan" "$pdir/${session}.branch"
    pool_write_state "$project" "$session" "idle"

    # Restart the container
    echo "Restarting pool sandbox '$session'..."
    local provider_name
    provider_name=$(cat "$pdir/${session}.provider" 2>/dev/null || echo "$SANDBOX_PROVIDER")
    ( cmd_start "$project" "$session" --warm --provider "$provider_name" --dangerous )

    echo "Pool sandbox '$session' is idle and ready for next task."
}
```

- [ ] **Step 3: Add cmd_pool_cancel function**

```bash
cmd_pool_cancel() {
    local project="$1"
    local session="$2"

    if [[ -z "$project" || -z "$session" ]]; then
        echo "ERROR: pool cancel requires <project> <session>" >&2
        exit 1
    fi

    local state
    state=$(pool_read_state "$project" "$session")
    if [[ "$state" != "busy" ]]; then
        echo "ERROR: Pool sandbox '$session' is in state '$state', not 'busy'." >&2
        exit 1
    fi

    local comp_name
    comp_name=$(compose_project_name "$project" "$session")

    echo "Cancelling agent in pool sandbox '$session'..."

    # Kill watcher first so it doesn't race
    pool_kill_watcher "$project" "$session"

    # Kill the agent process inside the container
    local process_pattern="[c]laude"
    if type provider_process_name &>/dev/null; then
        local raw_pattern
        raw_pattern=$(provider_process_name)
        process_pattern="[${raw_pattern:0:1}]${raw_pattern:1}"
    fi
    docker exec "${comp_name}-agent" pkill -f "$process_pattern" 2>/dev/null || true

    pool_write_state "$project" "$session" "reviewing"

    echo "Agent stopped. Sandbox '$session' is now in 'reviewing' state."
    echo "Partial work may be available."
    echo ""
    echo "  Accept:  sandbox pool accept $project $session"
    echo "  Reject:  sandbox pool reject $project $session"
    echo "  Diff:    sandbox diff $project $session"
}
```

- [ ] **Step 4: Verify no syntax errors**

Run: `bash -n sandbox.sh`
Expected: No output (clean parse)

- [ ] **Step 5: Commit**

```bash
git add sandbox.sh
git commit -m "feat: implement pool accept, reject, and cancel commands"
```

---

### Task 8: Implement `cmd_pool_stop` and `cmd_pool_list`

**Files:**
- Modify: `sandbox.sh` (add after the previous pool commands)

- [ ] **Step 1: Add cmd_pool_stop function**

```bash
cmd_pool_stop() {
    local project=""
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            *)
                if [[ -z "$project" ]]; then
                    project="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$project" ]]; then
        echo "ERROR: pool stop requires <project>" >&2
        exit 1
    fi

    local pdir
    pdir="$(pool_dir "$project")"

    if [[ ! -d "$pdir" ]]; then
        echo "No pool found for '$project'."
        return
    fi

    # Check for busy/reviewing sandboxes
    local has_busy=false
    local has_reviewing=false
    for state_file in "$pdir"/pool-*.state; do
        [[ -f "$state_file" ]] || continue
        local state
        state=$(cat "$state_file")
        [[ "$state" == "busy" ]] && has_busy=true
        [[ "$state" == "reviewing" ]] && has_reviewing=true
    done

    if [[ "$has_busy" == "true" && "$force" != "true" ]]; then
        echo "ERROR: Pool has busy sandboxes. Use --force to stop anyway." >&2
        exit 1
    fi

    if [[ "$has_reviewing" == "true" && "$force" != "true" ]]; then
        echo "WARNING: Pool has sandboxes with unmerged work."
        echo "Accept or reject them first, or use --force to discard."
        local tty_in=/dev/stdin
        [[ -t 0 ]] || { [[ -e /dev/tty ]] && tty_in=/dev/tty; }
        local confirm
        read -rp "Stop anyway? [y/N] " confirm < "$tty_in"
        if [[ "$confirm" != [yY] ]]; then
            echo "Aborted."
            return
        fi
    fi

    echo "Stopping pool for '$project'..."
    echo ""

    for state_file in "$pdir"/pool-*.state; do
        [[ -f "$state_file" ]] || continue
        local session
        session=$(basename "${state_file%.state}")
        echo "  Stopping $session..."
        pool_kill_watcher "$project" "$session"
        cmd_stop "$project" "$session" --clean 2>/dev/null || true
    done

    # Remove pool directory
    rm -rf "$pdir"

    echo ""
    echo "Pool stopped and cleaned up for '$project'."
}
```

- [ ] **Step 2: Add cmd_pool_list function**

```bash
cmd_pool_list() {
    local found=false
    for pdir in "$SANDBOX_BASE_DIR"/*/.pool; do
        [[ -d "$pdir" ]] || continue
        found=true
        local project
        project=$(basename "$(dirname "$pdir")")
        echo "Pool: $project"
        for state_file in "$pdir"/pool-*.state; do
            [[ -f "$state_file" ]] || continue
            local session
            session=$(basename "${state_file%.state}")
            local state
            state=$(cat "$state_file")
            printf "  %-12s  %s\n" "$session" "$state"
        done
        echo ""
    done

    if [[ "$found" == "false" ]]; then
        echo "No active pools found."
    fi
}
```

- [ ] **Step 3: Verify no syntax errors**

Run: `bash -n sandbox.sh`
Expected: No output (clean parse)

- [ ] **Step 4: Commit**

```bash
git add sandbox.sh
git commit -m "feat: implement pool stop and pool list commands"
```

---

### Task 9: Wire Pool Commands into Main Dispatch

**Files:**
- Modify: `sandbox.sh` (main case dispatch and usage function)

- [ ] **Step 1: Add pool subcommand routing to the main case block**

Find the main dispatch `case "$command" in` block. Add `pool)` before the error case:

```bash
    pool)
        local pool_cmd="${1:-}"
        shift 2>/dev/null || true
        case "$pool_cmd" in
            start)  cmd_pool_start "$@" ;;
            stop)   cmd_pool_stop "$@" ;;
            status) cmd_pool_status "$@" ;;
            assign) cmd_pool_assign "$@" ;;
            accept) cmd_pool_accept "$@" ;;
            reject) cmd_pool_reject "$@" ;;
            cancel) cmd_pool_cancel "$@" ;;
            list)   cmd_pool_list ;;
            *)
                echo "ERROR: Unknown pool command: $pool_cmd" >&2
                echo "Available: start, stop, status, assign, accept, reject, cancel, list" >&2
                exit 1
                ;;
        esac
        ;;
```

- [ ] **Step 2: Update the usage function**

Add pool commands to the usage text after the `prune` entry:

```
  pool start <project> [--count N] [--profile <name>] [--provider <name>] [--dangerous]
      Start a persistent sandbox pool (N containers, default 1)

  pool stop <project> [--force]
      Stop all pool sandboxes and clean up

  pool status <project>
      Show pool sandbox states

  pool assign <project> <plan-file> [--branch <name>]
      Assign a plan to an idle pool sandbox (warm restart)

  pool accept <project> <session>
      Merge completed work and return sandbox to idle

  pool reject <project> <session>
      Discard work and return sandbox to idle

  pool cancel <project> <session>
      Kill running agent and move to reviewing state

  pool list
      Show all active pools across projects
```

- [ ] **Step 3: Verify no syntax errors**

Run: `bash -n sandbox.sh`
Expected: No output (clean parse)

- [ ] **Step 4: Commit**

```bash
git add sandbox.sh
git commit -m "feat: wire pool commands into main dispatch and usage"
```

---

### Task 10: Update `cmd_list` to Tag Pool Sandboxes

**Files:**
- Modify: `sandbox.sh` (the `cmd_list` function)

- [ ] **Step 1: Add [pool] tag to pool sandboxes in the list output**

Find the line in `cmd_list` that prints the sandbox entry:

```bash
                echo "  [$idx] $project / $session"
```

Replace with:

```bash
                local pool_tag=""
                if is_pool_sandbox "$project" "$session"; then
                    local pool_state
                    pool_state=$(pool_read_state "$project" "$session")
                    pool_tag=" [pool:$pool_state]"
                fi
                echo "  [$idx] $project / $session${pool_tag}"
```

- [ ] **Step 2: Verify no syntax errors**

Run: `bash -n sandbox.sh`
Expected: No output (clean parse)

- [ ] **Step 3: Commit**

```bash
git add sandbox.sh
git commit -m "feat: show [pool] tag in sandbox list for pool sandboxes"
```

---

### Task 11: Add `provider_process_name` Hook to Claude Code Provider

**Files:**
- Modify: `providers/claude-code/provider.sh` (optional hooks section)

- [ ] **Step 1: Add provider_process_name hook**

Insert after the `provider_headless` function:

```bash
# provider_process_name
#
# Returns the process name pattern used to detect when the agent is running.
# Used by the pool completion watcher with pgrep -f.
# The watcher applies the bracket trick automatically (claude -> [c]laude).
#
provider_process_name() {
    echo "claude"
}
```

- [ ] **Step 2: Commit**

```bash
git add providers/claude-code/provider.sh
git commit -m "feat: add provider_process_name hook for pool completion detection"
```

---

### Task 12: Create `sandbox-pool` Skill

**Files:**
- Create: `skills/sandbox-pool/SKILL.md`

- [ ] **Step 1: Write the skill file**

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add skills/sandbox-pool/SKILL.md
git commit -m "feat: create sandbox-pool skill for pool lifecycle management"
```

---

### Task 13: Create `sandbox-accept` Skill

**Files:**
- Create: `skills/sandbox-accept/SKILL.md`

- [ ] **Step 1: Write the skill file**

```markdown
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

Parse the output for sandboxes in `reviewing` state. If none found, tell the user: "No sandboxes are ready for review."

### 3. Select Sandbox

If the user provided a session name as argument, use it. If multiple sandboxes are in `reviewing` state, list them and ask the user to choose:

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
bash "$AGENT_SANDBOX_HOME/sandbox.sh" pool accept <project> <session>
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
```

- [ ] **Step 2: Commit**

```bash
git add skills/sandbox-accept/SKILL.md
git commit -m "feat: create sandbox-accept skill for reviewing pool sandbox work"
```

---

### Task 14: Update `sandbox-execute` Skill for Pool Awareness

**Files:**
- Modify: `skills/sandbox-execute/SKILL.md`

- [ ] **Step 1: Add pool detection logic between Step 3 and Step 4**

Insert a new step after "### 3. Verify Plan Is Committed" and before the current Step 4. Renumber subsequent steps.

Add this as the new **Step 4: Check for Pool Sandbox**:

```markdown
### 4. Check for Pool Sandbox

Unless the user passed `--fresh`, check if the project has an active pool:

```bash
bash "$AGENT_SANDBOX_HOME/sandbox.sh" pool status <project> 2>/dev/null
```

If pool status returns sandboxes (the `.pool/` directory exists for the project):

1. **If an idle sandbox is found** — use the pool path. Run:
   ```bash
   bash "$AGENT_SANDBOX_HOME/sandbox.sh" pool assign <project> <plan-file-path>
   ```

   Report to user:
   ```
   Assigned to pool sandbox!

     Project:  <project>
     Sandbox:  <session>
     Plan:     <plan-file>
     Branch:   <branch>

   The sandbox is working. Check progress:
     /sandbox-pool status
   
   When done:
     /sandbox-accept
   ```

   **Stop here** — do not proceed to Step 5 (the cold-start path).

2. **If no idle sandbox is available** — tell the user:
   ```
   All pool sandboxes are busy. Options:
     - Wait for one to finish (check /sandbox-pool status)
     - Force a fresh ephemeral sandbox: /sandbox-execute --fresh <plan-file>
   ```
   
   **Stop here** unless the user chooses `--fresh`.

If no pool exists or `--fresh` was passed, proceed to Step 5 (original cold-start behavior).
```

- [ ] **Step 2: Renumber the original Step 4 to Step 5 and Step 5 to Step 6**

The original "### 4. Derive Session Name and Launch" becomes "### 5. Derive Session Name and Launch".

The original "### 5. Report to User" becomes "### 6. Report to User".

- [ ] **Step 3: Commit**

```bash
git add skills/sandbox-execute/SKILL.md
git commit -m "feat: update sandbox-execute skill to prefer pool sandboxes"
```

---

### Task 15: Update `sandbox-merge` Skill for Pool Awareness

**Files:**
- Modify: `skills/sandbox-merge/SKILL.md`

- [ ] **Step 1: Add pool detection in Step 2**

After the session is identified in Step 1, add a pool check at the beginning of Step 2:

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add skills/sandbox-merge/SKILL.md
git commit -m "feat: update sandbox-merge skill to delegate to pool accept for pool sandboxes"
```

---

### Task 16: Copy Updated Skills to User Install Location

**Files:**
- Copy skills to `~/.claude/skills/`

- [ ] **Step 1: Copy all skills to user install location**

```bash
mkdir -p ~/.claude/skills/sandbox-pool ~/.claude/skills/sandbox-accept
cp skills/sandbox-pool/SKILL.md ~/.claude/skills/sandbox-pool/SKILL.md
cp skills/sandbox-accept/SKILL.md ~/.claude/skills/sandbox-accept/SKILL.md
cp skills/sandbox-execute/SKILL.md ~/.claude/skills/sandbox-execute/SKILL.md
cp skills/sandbox-merge/SKILL.md ~/.claude/skills/sandbox-merge/SKILL.md
```

No git commit needed — this is a local install action.

---

### Task 17: Update CLAUDE.md and README.md

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [ ] **Step 1: Update sandbox.sh description in Key Files table**

```markdown
| `sandbox.sh` | Main launcher (Bash). Commands: start, stop, list, logs, shell, headless, diff, repair, pool (start/stop/status/assign/accept/reject/cancel/list) |
```

- [ ] **Step 2: Add pool entries to Key Files table**

```markdown
| `<project>/.pool/` | Pool state directory (gitignored) — state files per pool sandbox |
| `skills/sandbox-pool/` | Pool lifecycle management skill |
| `skills/sandbox-accept/` | Review and merge pool sandbox work |
```

- [ ] **Step 3: Add pool naming conventions**

In the Naming Conventions section, add:

```markdown
- Pool session names: `pool-1`, `pool-2`, etc.
- Pool state dir: `$SANDBOX_BASE_DIR/<project>/.pool/`
- Pool state files: `<session>.state`, `<session>.plan`, `<session>.branch`, `<session>.provider`, `<session>.watcher-pid`
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: add pool commands and skills to CLAUDE.md and README.md"
```

---

### Task 18: End-to-End Smoke Test

**Files:** None (manual testing)

- [ ] **Step 1: Start a pool**

Run: `bash sandbox.sh pool start <test-project> --count 1`
Expected: One sandbox starts, state file at `<test-project>/.pool/pool-1.state` containing "idle"

- [ ] **Step 2: Check pool status**

Run: `bash sandbox.sh pool status <test-project>`
Expected: Shows pool-1 as idle, container running

- [ ] **Step 3: Check pool appears in sandbox list**

Run: `bash sandbox.sh list`
Expected: pool-1 shows with `[pool:idle]` tag

- [ ] **Step 4: Assign a plan**

Run: `bash sandbox.sh pool assign <test-project> <path-to-test-plan>`
Expected: Warm restart (~5-15 seconds), state changes to "busy", watcher PID file created

- [ ] **Step 5: Cancel and verify reviewing state**

Run: `bash sandbox.sh pool cancel <test-project> pool-1`
Expected: Agent killed, watcher killed, state changes to "reviewing"

- [ ] **Step 6: Reject and verify idle state**

Run: `bash sandbox.sh pool reject <test-project> pool-1`
Expected: Worktree discarded, container restarted warm, state back to "idle"

- [ ] **Step 7: Stop the pool**

Run: `bash sandbox.sh pool stop <test-project>`
Expected: Container stopped, volumes cleaned, `.pool/` removed

- [ ] **Step 8: Commit any fixes discovered during testing**

```bash
git add -A
git commit -m "fix: address issues found during pool smoke testing"
```
