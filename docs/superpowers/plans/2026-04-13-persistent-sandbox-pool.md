# Persistent Sandbox Pool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent sandbox pool system so containers stay warm between features, reducing per-feature startup from minutes to seconds.

**Architecture:** New `sandbox pool` subcommands in `sandbox.sh` manage pool state via simple files in `<project>/.pool/`. Pool sandboxes are normal sandboxes with state tracking. A `SANDBOX_WARM=true` env var gates expensive post-launch init steps. Three skills (`sandbox-pool`, `sandbox-accept`, updated `sandbox-execute`) provide the user-facing workflow.

**Tech Stack:** Bash (sandbox.sh), Markdown (SKILL.md files), Docker Compose, PowerShell (sandbox.ps1 wrapper)

---

### Task 1: Add Pool State Helper Functions to sandbox.sh

**Files:**
- Modify: `sandbox.sh:27-62` (after existing helper section)

This task adds the low-level functions that all pool commands depend on: state directory management, state read/write with flock-based concurrency, and pool sandbox discovery.

- [ ] **Step 1: Add pool directory and state helper functions after the existing helper block**

Insert after `validate_branch_name()` (line 236) and before `validate_env_pair()` (line 238):

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

# Find the first idle pool sandbox for a project
# Usage: pool_find_idle <project>
# Returns: session name (or empty if none idle)
pool_find_idle() {
    local pdir
    pdir="$(pool_dir "$1")"
    [[ -d "$pdir" ]] || return 0
    for state_file in "$pdir"/pool-*.state; do
        [[ -f "$state_file" ]] || continue
        local session
        session=$(basename "${state_file%.state}")
        (
            flock -n 200 || exit 1
            local state
            state=$(cat "$state_file")
            if [[ "$state" == "idle" ]]; then
                echo "$session"
                exit 0
            fi
        ) 200>"${state_file}.lock"
        # If the subshell printed a session name, we found one
        local result
        result=$(
            flock -n "${state_file}.lock" bash -c "cat '$state_file'" 2>/dev/null
        )
        if [[ "$(cat "$state_file" 2>/dev/null)" == "idle" ]]; then
            echo "$session"
            return 0
        fi
    done
}

# List all pool sessions for a project
# Usage: pool_list_sessions <project>
pool_list_sessions() {
    local pdir
    pdir="$(pool_dir "$1")"
    [[ -d "$pdir" ]] || return 0
    for state_file in "$pdir"/pool-*.state; do
        [[ -f "$state_file" ]] || continue
        basename "${state_file%.state}"
    done
}

# Check if a session belongs to a pool
# Usage: is_pool_sandbox <project> <session>
# Returns: 0 if pool sandbox, 1 if not
is_pool_sandbox() {
    local state_file="$(pool_dir "$1")/$2.state"
    [[ -f "$state_file" ]]
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

### Task 2: Add `pool_find_idle` with Proper flock-based Locking

**Files:**
- Modify: `sandbox.sh` (the `pool_find_idle` function from Task 1)

The flock approach in Task 1 is simplified. Replace `pool_find_idle` with a version that does atomic claim — read state and write "claiming" in a single locked block so two concurrent `assign` calls can't both find the same idle sandbox.

- [ ] **Step 1: Replace pool_find_idle with atomic claim version**

Replace the `pool_find_idle` function written in Task 1 with:

```bash
# Find and atomically claim the first idle pool sandbox
# Usage: pool_claim_idle <project>
# Returns: session name (or empty if none idle)
# Side effect: sets claimed sandbox state to "claiming"
pool_claim_idle() {
    local pdir
    pdir="$(pool_dir "$1")"
    [[ -d "$pdir" ]] || return 0
    for state_file in "$pdir"/pool-*.state; do
        [[ -f "$state_file" ]] || continue
        local session
        session=$(basename "${state_file%.state}")
        # Atomic read-and-claim under flock
        local claimed
        claimed=$(
            flock -x 200
            local state
            state=$(cat "$state_file" 2>/dev/null)
            if [[ "$state" == "idle" ]]; then
                echo "claiming" > "$state_file"
                echo "$session"
            fi
        ) 200>"${state_file}.lock"
        if [[ -n "$claimed" ]]; then
            echo "$claimed"
            return 0
        fi
    done
}
```

Also remove the original `pool_find_idle` function.

- [ ] **Step 2: Verify no syntax errors**

Run: `bash -n sandbox.sh`
Expected: No output (clean parse)

- [ ] **Step 3: Commit**

```bash
git add sandbox.sh
git commit -m "feat: replace pool_find_idle with atomic pool_claim_idle"
```

---

### Task 3: Add SANDBOX_WARM Gate to Post-Launch Init

**Files:**
- Modify: `sandbox.sh:770-938` (the post-launch init block in `cmd_start`)

This wraps the expensive initialization steps in a `SANDBOX_WARM` check. The warm restart still runs provider_start, .git pointer rewrite, and .env seeding.

- [ ] **Step 1: Wrap cold-only init steps with SANDBOX_WARM check**

In `cmd_start`, after the `docker compose up -d` line (line 768) and the ownership fixup block (lines 770-777), wrap the cold-only steps. The section starting at line 782 (Gradle cache seeding) through line 837 (dos2unix) needs the gate. Provider start (line 780) must always run.

Find this block (around line 770):

```bash
    # Fix ownership on session-local volumes (created as root by Docker)
    if [[ "$profile" == "java" || "$profile" == "fullstack" ]]; then
        docker exec -u root "${comp_name}-agent" bash -c \
            "chown agent:agent /home/agent/.gradle /build-output || true"
    fi
    # Fix ownership on node_modules volumes (created as root by Docker)
    docker exec -u root "${comp_name}-agent" bash -c \
        'for d in /workspace/node_modules /workspace/*/node_modules; do [ -d "$d" ] && chown agent:agent "$d"; done' 2>/dev/null || true

    # Provider-specific post-start initialization
    provider_start "${comp_name}-agent" "$dangerous"
```

Replace with:

```bash
    # --- Post-launch initialization ---
    # SANDBOX_WARM=true skips expensive cold-start steps (deps, ownership, etc.)
    # Always runs: provider_start, .git pointer rewrite, .env seeding

    if [[ "${SANDBOX_WARM:-false}" != "true" ]]; then
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
```

- [ ] **Step 2: Wrap the Gradle cache seeding, Playwright, dos2unix, and npm install blocks**

Find the Gradle cache seeding block (starts around line 782 with `if [[ "$profile" == "java" ...`) that includes:
- Gradle cache seeding from host
- Gradle performance tuning
- Testcontainers config
- Playwright browser install
- dos2unix

Wrap all of these (from Gradle cache seeding through the dos2unix line) with:

```bash
    if [[ "${SANDBOX_WARM:-false}" != "true" ]]; then
```

And close it just before the `.git` pointer rewrite line (`local worktree_name="${project}--${session}"`):

```bash
    fi  # end SANDBOX_WARM gate
```

The `.git` pointer rewrite, `.env` seeding, and npm install sections must remain OUTSIDE the warm gate (they always run because each new worktree needs them). However, npm install can be skipped on warm restart since volumes persist — wrap only the npm install block:

```bash
    if [[ "${SANDBOX_WARM:-false}" != "true" ]]; then
        # npm install in any directory with package.json but no node_modules
        ...existing npm install block...
    fi
```

The Gradle dependency resolution block should also be inside the warm gate since the cache volume persists.

- [ ] **Step 3: Verify no syntax errors**

Run: `bash -n sandbox.sh`
Expected: No output (clean parse)

- [ ] **Step 4: Test cold start still works**

Run: `bash sandbox.sh start <test-project> test-cold-start --provider claude-code`
Expected: Full init runs (npm install, ownership fixups, etc.)

Run: `bash sandbox.sh stop <test-project> test-cold-start --clean`

- [ ] **Step 5: Commit**

```bash
git add sandbox.sh
git commit -m "feat: add SANDBOX_WARM gate to skip expensive init on warm restart"
```

---

### Task 4: Implement `cmd_pool_start`

**Files:**
- Modify: `sandbox.sh` (add new function before `# --- Main ---` section, around line 1550)

- [ ] **Step 1: Add cmd_pool_start function**

Insert before the `# --- Main ---` comment:

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
                cmd_start "$project" "$session" "${start_args[@]}"
                pool_write_state "$project" "$session" "idle"
            fi
            continue
        fi

        echo "  Starting pool sandbox: $session"
        cmd_start "$project" "$session" "${start_args[@]}"

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

        # Cross-reference: state says busy/idle but container is down
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

This is the core command — claims an idle sandbox, creates a worktree, does a warm restart with the new bind mount, and starts the agent with the plan.

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
        # Strip YYYY-MM-DD- prefix
        branch=$(echo "$plan_basename" | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//')
    fi
    validate_branch_name "$branch"

    # Claim an idle sandbox
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
    printf '%s\n%s\n' "$branch" "$(cat "$pdir/${session}.provider" 2>/dev/null || echo "$SANDBOX_PROVIDER")" \
        > "${worktree_path}.sandbox-meta"

    # Stop the container (fast — agent is idle)
    echo "  Restarting sandbox with new worktree..."
    docker compose -p "$comp_name" down 2>/dev/null || true

    # Warm restart with new bind mount
    export SANDBOX_WARM=true
    local provider_name
    provider_name=$(cat "$pdir/${session}.provider" 2>/dev/null || echo "$SANDBOX_PROVIDER")
    cmd_start "$project" "$session" --provider "$provider_name" --dangerous
    unset SANDBOX_WARM

    # Record task metadata
    echo "$plan" > "$pdir/${session}.plan"
    echo "$branch" > "$pdir/${session}.branch"
    pool_write_state "$project" "$session" "busy"

    echo ""
    echo "Pool sandbox '$session' is now working on branch '$branch'."
    echo ""
    echo "  Check status:  sandbox pool status $project"
    echo "  View logs:     sandbox logs $project $session"
    echo "  Cancel:        sandbox pool cancel $project $session"

    # Start background completion watcher
    _pool_start_watcher "$project" "$session" "$comp_name" &
    disown
}

# Background watcher: polls for agent process exit, flips state to "reviewing"
_pool_start_watcher() {
    local project="$1"
    local session="$2"
    local comp_name="$3"

    # Determine agent process name from provider hook (or default)
    local process_pattern="claude"
    if type provider_process_name &>/dev/null; then
        process_pattern=$(provider_process_name)
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
            return
        fi
        # Check if agent process is still running
        if ! docker exec "${comp_name}-agent" pgrep -f "$process_pattern" &>/dev/null; then
            pool_write_state "$project" "$session" "reviewing"
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

- [ ] **Step 2: Verify no syntax errors**

Run: `bash -n sandbox.sh`
Expected: No output (clean parse)

- [ ] **Step 3: Commit**

```bash
git add sandbox.sh
git commit -m "feat: implement cmd_pool_assign with warm restart and completion watcher"
```

---

### Task 7: Implement `cmd_pool_accept`, `cmd_pool_reject`, and `cmd_pool_cancel`

**Files:**
- Modify: `sandbox.sh` (add after `cmd_pool_assign`)

- [ ] **Step 1: Add cmd_pool_accept function**

Note: We cannot call `cmd_merge` because it calls `cmd_stop` which tears down the container. For pool sandboxes, we need to do the merge logic inline, handling the stop/restart ourselves to keep the container warm.

```bash
cmd_pool_accept() {
    local project="$1"
    local session="$2"

    if [[ -z "$project" || -z "$session" ]]; then
        echo "ERROR: pool accept requires <project> <session>" >&2
        exit 1
    fi

    local state
    state=$(pool_read_state "$project" "$session")
    if [[ "$state" != "reviewing" ]]; then
        echo "ERROR: Pool sandbox '$session' is in state '$state', not 'reviewing'." >&2
        exit 1
    fi

    local pdir
    pdir="$(pool_dir "$project")"
    local project_path="$SANDBOX_BASE_DIR/$project"
    local worktree_path
    worktree_path="$(resolve_worktree "$project" "$session")"
    local comp_name
    comp_name=$(compose_project_name "$project" "$session")

    local branch_name
    branch_name=$(cat "$pdir/${session}.branch" 2>/dev/null || echo "$session")

    echo "Merging pool sandbox '$session' (branch: $branch_name)..."

    # Stop container to restore git pointer for host-side merge
    if docker compose -p "$comp_name" ps --status running 2>/dev/null | grep -q "agent"; then
        cmd_stop "$project" "$session"
    fi

    # Restore .git pointer (same as cmd_merge)
    local worktree_name="${project}--${session}"
    local git_path="$project_path/.git/worktrees/$worktree_name"
    if [[ "$git_path" =~ ^/([a-zA-Z])/ ]]; then
        git_path="${BASH_REMATCH[1]^}:${git_path:2}"
    fi
    echo "gitdir: $git_path" > "$worktree_path/.git"

    # Clean sandbox artifacts (same patterns as cmd_merge)
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

    # Validate: check for uncommitted changes
    local uncommitted
    uncommitted=$(git -C "$worktree_path" status --porcelain 2>/dev/null || true)
    if [[ -n "$uncommitted" ]]; then
        echo "ERROR: Worktree has uncommitted changes:" >&2
        git -C "$worktree_path" status --short >&2
        echo "Reconnect with: sandbox shell $project $session" >&2
        # Restart container so user can shell in
        local provider_name
        provider_name=$(cat "$pdir/${session}.provider" 2>/dev/null || echo "$SANDBOX_PROVIDER")
        export SANDBOX_WARM=true
        cmd_start "$project" "$session" --provider "$provider_name" --dangerous
        unset SANDBOX_WARM
        exit 1
    fi

    # Validate: check for commits
    local current_branch
    current_branch=$(git -C "$project_path" rev-parse --abbrev-ref HEAD)
    local commit_count
    commit_count=$(git -C "$project_path" rev-list --count "${current_branch}..${branch_name}" 2>/dev/null || echo "0")
    if [[ "$commit_count" -eq 0 ]]; then
        echo "ERROR: No commits on branch '$branch_name'." >&2
        # Restart container
        local provider_name
        provider_name=$(cat "$pdir/${session}.provider" 2>/dev/null || echo "$SANDBOX_PROVIDER")
        export SANDBOX_WARM=true
        cmd_start "$project" "$session" --provider "$provider_name" --dangerous
        unset SANDBOX_WARM
        exit 1
    fi

    echo "Merging '$branch_name' into '$current_branch' ($commit_count commits)"
    git --no-pager -C "$project_path" diff --stat "${current_branch}...${branch_name}" 2>/dev/null
    echo ""

    if ! git -C "$project_path" merge "$branch_name" --no-edit; then
        echo "Merge failed (conflicts?). Resolve in: $project_path"
        echo "After resolving, run: sandbox pool accept $project $session"
        # Restart container to keep pool warm
        local provider_name
        provider_name=$(cat "$pdir/${session}.provider" 2>/dev/null || echo "$SANDBOX_PROVIDER")
        export SANDBOX_WARM=true
        cmd_start "$project" "$session" --provider "$provider_name" --dangerous
        unset SANDBOX_WARM
        exit 1
    fi

    echo "Merge complete."

    # Clean up the worktree (but NOT volumes — pool keeps them)
    if [[ -d "$worktree_path" ]]; then
        git -C "$project_path" config core.longpaths true
        git -C "$project_path" worktree remove "$worktree_path" --force 2>/dev/null \
            || rm -rf "$worktree_path"
        rm -f "${worktree_path}.sandbox-meta"
        # Delete the branch since it's merged
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
    export SANDBOX_WARM=true
    cmd_start "$project" "$session" --provider "$provider_name" --dangerous
    unset SANDBOX_WARM

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

    local state
    state=$(pool_read_state "$project" "$session")
    if [[ "$state" != "reviewing" ]]; then
        echo "ERROR: Pool sandbox '$session' is in state '$state', not 'reviewing'." >&2
        exit 1
    fi

    local pdir
    pdir="$(pool_dir "$project")"
    local project_path="$SANDBOX_BASE_DIR/$project"
    local worktree_path
    worktree_path="$(resolve_worktree "$project" "$session")"

    local branch_name
    branch_name=$(cat "$pdir/${session}.branch" 2>/dev/null || echo "$session")

    echo "Rejecting pool sandbox '$session' (discarding branch: $branch_name)..."

    # Stop container, restore git pointer
    local comp_name
    comp_name=$(compose_project_name "$project" "$session")
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
    export SANDBOX_WARM=true
    cmd_start "$project" "$session" --provider "$provider_name" --dangerous
    unset SANDBOX_WARM

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

    # Kill the agent process inside the container
    local process_pattern="claude"
    if type provider_process_name &>/dev/null; then
        process_pattern=$(provider_process_name)
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
        # Read from tty for interactive prompt
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
- Modify: `sandbox.sh:1561-1579` (the main case dispatch)
- Modify: `sandbox.sh:100-148` (the usage function)

- [ ] **Step 1: Add pool subcommand routing to the main case block**

Find the main dispatch block:

```bash
case "$command" in
    start)    cmd_start "$@" ;;
    stop)     cmd_stop "$@" ;;
    ...
```

Add `pool` before the error case:

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

Add pool commands to the usage text (inside the `cat <<'EOF'` block), after the `prune` entry:

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
- Modify: `sandbox.sh:1029-1135` (the `cmd_list` function)

- [ ] **Step 1: Add [pool] tag to pool sandboxes in the list output**

Find the line in `cmd_list` that prints the sandbox entry (around line 1066):

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
- Modify: `providers/claude-code/provider.sh:130-171` (optional hooks section)

- [ ] **Step 1: Add provider_process_name hook**

Insert after the `provider_headless` function (after line 171):

```bash
# provider_process_name
#
# Returns the process name pattern used to detect when the agent is running.
# Used by the pool completion watcher with pgrep -f.
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
- Copy: `skills/sandbox-pool/SKILL.md` → `~/.claude/skills/sandbox-pool/SKILL.md`
- Copy: `skills/sandbox-accept/SKILL.md` → `~/.claude/skills/sandbox-accept/SKILL.md`
- Copy: `skills/sandbox-execute/SKILL.md` → `~/.claude/skills/sandbox-execute/SKILL.md`
- Copy: `skills/sandbox-merge/SKILL.md` → `~/.claude/skills/sandbox-merge/SKILL.md`

- [ ] **Step 1: Copy all skills to user install location**

```bash
mkdir -p ~/.claude/skills/sandbox-pool ~/.claude/skills/sandbox-accept
cp skills/sandbox-pool/SKILL.md ~/.claude/skills/sandbox-pool/SKILL.md
cp skills/sandbox-accept/SKILL.md ~/.claude/skills/sandbox-accept/SKILL.md
cp skills/sandbox-execute/SKILL.md ~/.claude/skills/sandbox-execute/SKILL.md
cp skills/sandbox-merge/SKILL.md ~/.claude/skills/sandbox-merge/SKILL.md
```

- [ ] **Step 2: Commit the repo-side skills (already done in previous tasks — this is just the install step)**

No git commit needed — this is a local install action.

---

### Task 17: Update CLAUDE.md and README.md

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [ ] **Step 1: Add pool commands to CLAUDE.md key files table**

In `CLAUDE.md`, add to the Key Files table:

```markdown
| `<project>/.pool/` | Pool state directory (gitignored) — state files per pool sandbox |
```

- [ ] **Step 2: Add pool section to CLAUDE.md naming conventions**

In the Naming Conventions section, add:

```markdown
- Pool session names: `pool-1`, `pool-2`, etc.
- Pool state dir: `$SANDBOX_BASE_DIR/<project>/.pool/`
- Pool state files: `<session>.state`, `<session>.plan`, `<session>.branch`, `<session>.provider`
```

- [ ] **Step 3: Add pool commands summary to CLAUDE.md**

After the existing `sandbox.sh` description in the Key Files table, update:

```markdown
| `sandbox.sh` | Main launcher (Bash). Commands: start, stop, list, logs, shell, headless, diff, repair, pool (start/stop/status/assign/accept/reject/cancel/list) |
```

- [ ] **Step 4: Add pool skills to CLAUDE.md**

In a skills section (or after the existing skills mention), add:

```markdown
| `skills/sandbox-pool/` | Pool lifecycle management skill |
| `skills/sandbox-accept/` | Review and merge pool sandbox work |
```

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: add pool commands and skills to CLAUDE.md and README.md"
```

---

### Task 18: End-to-End Smoke Test

**Files:** None (manual testing)

- [ ] **Step 1: Start a pool**

Run: `bash sandbox.sh pool start <test-project> --count 1`
Expected: One sandbox starts, state file created at `<test-project>/.pool/pool-1.state` containing "idle"

- [ ] **Step 2: Check pool status**

Run: `bash sandbox.sh pool status <test-project>`
Expected: Shows pool-1 as idle, container running

- [ ] **Step 3: Check pool appears in sandbox list**

Run: `bash sandbox.sh list`
Expected: pool-1 shows with `[pool:idle]` tag

- [ ] **Step 4: Assign a plan**

Run: `bash sandbox.sh pool assign <test-project> <path-to-test-plan>`
Expected: Warm restart (~5-15 seconds), state changes to "busy"

- [ ] **Step 5: Cancel and verify reviewing state**

Run: `bash sandbox.sh pool cancel <test-project> pool-1`
Expected: Agent killed, state changes to "reviewing"

- [ ] **Step 6: Reject and verify idle state**

Run: `bash sandbox.sh pool reject <test-project> pool-1`
Expected: Worktree discarded, container restarted, state back to "idle"

- [ ] **Step 7: Stop the pool**

Run: `bash sandbox.sh pool stop <test-project>`
Expected: Container stopped, volumes cleaned, `.pool/` removed

- [ ] **Step 8: Commit any fixes discovered during testing**

```bash
git add -A
git commit -m "fix: address issues found during pool smoke testing"
```
