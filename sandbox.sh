#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load defaults from .sandbox.env if it exists
if [[ -f "$SCRIPT_DIR/.sandbox.env" ]]; then
    # Validate .sandbox.env contains only KEY=VALUE lines and comments
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip Windows carriage returns
        line="${line//$'\r'/}"
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Must be KEY=VALUE
        if [[ ! "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_]*= ]]; then
            echo "ERROR: Invalid line in .sandbox.env: '$line'" >&2
            echo "Only KEY=VALUE lines and comments are allowed." >&2
            exit 1
        fi
    done < "$SCRIPT_DIR/.sandbox.env"
    set -a
    source "$SCRIPT_DIR/.sandbox.env"
    set +a
fi

# Defaults — SANDBOX_BASE_DIR defaults to the parent of this repo
SANDBOX_BASE_DIR="${SANDBOX_BASE_DIR:-$(dirname "$SCRIPT_DIR")}"
SANDBOX_LOG="$SCRIPT_DIR/sessions.log"

# Worktree directory: per-project (.worktrees inside each project)
# Usage: worktree_dir <project>
worktree_dir() {
    echo "$SANDBOX_BASE_DIR/$1/.worktrees"
}

# Resolve existing worktree path, checking current and legacy locations
# Usage: resolve_worktree <project> <session>
resolve_worktree() {
    local project="$1" session="$2"
    local new_path="$(worktree_dir "$project")/${project}--${session}"
    if [[ -d "$new_path" || -f "${new_path}.sandbox-meta" ]]; then
        echo "$new_path"
        return
    fi
    # Legacy: global .worktrees directory
    local legacy_path="$SANDBOX_BASE_DIR/.worktrees/${project}--${session}"
    if [[ -d "$legacy_path" || -f "${legacy_path}.sandbox-meta" ]]; then
        echo "$legacy_path"
        return
    fi
    # Default to new path (caller handles missing)
    echo "$new_path"
}

# Provider (can be overridden by --provider flag, .sandbox.conf, or env)
SANDBOX_PROVIDER="${SANDBOX_PROVIDER:-claude-code}"

log_event() {
    local event="$1"
    shift
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $event $*" >> "$SANDBOX_LOG"
}

# --- Provider loading ---

load_provider() {
    local provider="$1"
    local provider_dir="$SCRIPT_DIR/providers/$provider"
    if [[ ! -d "$provider_dir" ]]; then
        echo "ERROR: Provider not found: $provider" >&2
        exit 1
    fi
    # Read provider.conf, validate required_env vars
    local conf="$provider_dir/provider.conf"
    if [[ -f "$conf" ]]; then
        local required_env=""
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line//$'\r'/}"
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            local key="${line%%=*}"
            local val="${line#*=}"
            [[ "$key" == "required_env" ]] && required_env="$val"
        done < "$conf"
        if [[ -n "$required_env" ]]; then
            IFS=',' read -ra env_vars <<< "$required_env"
            for var in "${env_vars[@]}"; do
                var=$(echo "$var" | tr -d ' ')
                if [[ -z "${!var:-}" ]]; then
                    echo "ERROR: Provider '$provider' requires $var to be set" >&2
                    exit 1
                fi
            done
        fi
    fi
    source "$provider_dir/provider.sh"
}

# --- Helper functions ---

usage() {
    cat <<'EOF'
Usage: sandbox <command> [args]

Commands:
  start <project> <session> [--profile <name>] [--branch <name>] [--provider <name>] [--env KEY=VAL] [--dangerous] [--read-only] [--open-network] [--docker]
      Start a sandbox with an isolated git worktree
      --branch: git branch name (defaults to session name)
      --provider: agent provider plugin (default: claude-code)
      --dangerous: skip agent permission prompts
      --read-only: mount workspace as read-only (for review/analysis)
      --open-network: bypass proxy, allow unrestricted internet access
      --docker: enable Docker-in-Docker sidecar for Testcontainers

  stop <project> <session> [--clean]
      Stop a sandbox (--clean removes volumes and worktree)

  list
      Show all running sandboxes with port mappings

  logs <project> <session> [service]
      Tail logs for a sandbox (optionally a specific service)

  shell <project> <session>
      Open a shell in the agent container

  headless <project> <session>
      Start the agent in headless mode for remote control

  diff <project> <session> [--stat]
      Show all uncommitted changes in the sandbox worktree

  merge <project> <session> [--clean]
      Stop sandbox, merge session branch into project's current branch
      --clean: remove volumes, worktree, and branch after successful merge

  repair <project> <session>
      Fix .git pointer if container died without clean shutdown

  prune [--force]
      Remove orphaned sandbox volumes from stopped sessions
      --force: skip confirmation prompt

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

  update
      Rebuild all sandbox images with latest agent CLI

Profiles: base, java, node, fullstack (auto-detected if not specified)
EOF
}

compute_port_base() {
    local key="$1"
    local hash
    hash=$(printf '%s' "$key" | cksum | awk '{print $1}')
    local slot=$(( hash % 500 ))
    echo $(( 5000 + slot * 10 ))
}

find_free_port_base() {
    local base="$1"
    local max_attempts=50
    for (( i=0; i<max_attempts; i++ )); do
        local port=$(( base + i * 10 ))
        # Check if any port in the range is in use
        local in_use=false
        for offset in 0 1 2 3 4; do
            if ss -tln 2>/dev/null | grep -q ":$(( port + offset )) " || \
               netstat -an 2>/dev/null | grep -q ":$(( port + offset )) "; then
                in_use=true
                break
            fi
        done
        if [[ "$in_use" == "false" ]]; then
            echo "$port"
            return 0
        fi
    done
    echo "ERROR: Could not find free port range starting from $base" >&2
    return 1
}

detect_profile() {
    local project_path="$1"
    local has_java=false
    local has_node=false

    [[ -f "$project_path/build.gradle" || -f "$project_path/build.gradle.kts" || -f "$project_path/pom.xml" ]] && has_java=true
    # Check subdirectories too (e.g., myproject/api/build.gradle)
    if [[ "$has_java" == "false" ]]; then
        for f in "$project_path"/*/build.gradle "$project_path"/*/build.gradle.kts "$project_path"/*/pom.xml; do
            [[ -f "$f" ]] && has_java=true && break
        done
    fi

    [[ -f "$project_path/package.json" || -f "$project_path/pnpm-workspace.yaml" ]] && has_node=true
    if [[ "$has_node" == "false" ]]; then
        for f in "$project_path"/*/package.json; do
            [[ -f "$f" ]] && has_node=true && break
        done
    fi

    if [[ "$has_java" == "true" && "$has_node" == "true" ]]; then
        echo "fullstack"
    elif [[ "$has_java" == "true" ]]; then
        echo "java"
    elif [[ "$has_node" == "true" ]]; then
        echo "node"
    else
        echo "base"
    fi
}

compose_project_name() {
    local project="$1"
    local session="$2"
    echo "sandbox-${project}-${session}"
}

validate_session_name() {
    local name="$1"
    if [[ "$name" =~ [^a-zA-Z0-9_-] ]]; then
        echo "ERROR: session name must contain only letters, digits, hyphens, and underscores" >&2
        exit 1
    fi
}

validate_branch_name() {
    local name="$1"
    if [[ "$name" =~ [^a-zA-Z0-9/_.-] ]]; then
        echo "ERROR: branch name contains invalid characters (allowed: letters, digits, / _ . -)" >&2
        exit 1
    fi
    if [[ "$name" == *..* ]]; then
        echo "ERROR: branch name cannot contain '..'" >&2
        exit 1
    fi
}

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

# Write a pool sandbox state file with mkdir-based locking for concurrency safety
# Usage: pool_write_state <project> <session> <state>
pool_write_state() {
    local state_file="$(pool_dir "$1")/$2.state"
    local lock_dir="${state_file}.lock"
    # mkdir-based lock: atomic on all platforms (flock not available in Git Bash)
    local max_wait=10
    local waited=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
        sleep 0.1
        waited=$((waited + 1))
        if [[ $waited -ge $((max_wait * 10)) ]]; then
            echo "WARNING: Could not acquire lock on $state_file after ${max_wait}s, proceeding" >&2
            break
        fi
    done
    echo "$3" > "$state_file"
    rmdir "$lock_dir" 2>/dev/null || true
}

# Atomically find and claim the first idle pool sandbox by writing "busy" under mkdir lock.
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
        local lock_dir="${state_file}.lock"
        # Atomic claim: mkdir lock, read state, write busy if idle, unlock
        if mkdir "$lock_dir" 2>/dev/null; then
            local state
            state=$(cat "$state_file" 2>/dev/null)
            if [[ "$state" == "idle" ]]; then
                echo "busy" > "$state_file"
                rmdir "$lock_dir" 2>/dev/null || true
                echo "$session"
                return 0
            fi
            rmdir "$lock_dir" 2>/dev/null || true
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

validate_env_pair() {
    local pair="$1"
    # Must be KEY=VALUE format
    if [[ ! "$pair" =~ ^[a-zA-Z_][a-zA-Z0-9_]*= ]]; then
        echo "ERROR: Invalid --env format: '$pair' (must be KEY=VALUE)" >&2
        return 1
    fi
    # Block dangerous env var names
    local key="${pair%%=*}"
    local blocked="PATH|LD_PRELOAD|LD_LIBRARY_PATH|HOME|SHELL|USER|BASH_ENV|ENV|CDPATH|GLOBIGNORE|IFS|NODE_OPTIONS|NODE_PATH|GIT_SSH_COMMAND|GIT_SSH|JAVA_TOOL_OPTIONS|JAVA_OPTS|JDK_JAVA_OPTIONS"
    if [[ "$key" =~ ^($blocked)$ ]]; then
        echo "ERROR: --env cannot set reserved variable: $key" >&2
        return 1
    fi
    # Block variables used in compose interpolation
    if [[ "$key" =~ ^(SANDBOX_|COMPOSE_) ]]; then
        echo "ERROR: --env cannot set internal variable: $key" >&2
        return 1
    fi
}

# --- Gradle sparse cache ---

# Build a minimal Gradle cache containing only dependencies needed by the project.
# Parses lockfiles or runs `gradlew dependencies` to discover GAV coordinates, then
# copies only matching jars from the host cache.
# Args: $1 = project workspace path, $2 = output directory
# Returns: 0 on success (output_dir populated), 1 on skip/failure
build_sparse_gradle_cache() {
    local project_path="$1"
    local output_dir="$2"
    local host_cache="$HOME/.gradle"
    local files_dir=""

    # Find the host cache files directory
    for d in "$host_cache"/caches/modules-*/files-*; do
        [[ -d "$d" ]] && files_dir="$d" && break
    done
    [[ -z "$files_dir" ]] && return 1

    local modules_parent
    modules_parent=$(dirname "$files_dir")
    local modules_name
    modules_name=$(basename "$modules_parent")
    local files_name
    files_name=$(basename "$files_dir")

    # Find gradlew in the project
    local gradlew=""
    for gw in "$project_path/gradlew" "$project_path"/*/gradlew; do
        [[ -f "$gw" ]] && gradlew="$gw" && break
    done
    [[ -z "$gradlew" ]] && return 1
    local project_dir
    project_dir=$(dirname "$gradlew")

    # Collect GAV coordinates from the project
    local gavs=""

    # Strategy 1: Parse gradle.lockfile (instant, includes transitives)
    for lockfile in "$project_dir"/gradle.lockfile "$project_dir"/*/gradle.lockfile; do
        [[ -f "$lockfile" ]] || continue
        # Format: group:artifact:version=configuration(s)
        local parsed
        parsed=$(grep -E '^[a-zA-Z]' "$lockfile" 2>/dev/null | sed 's/=.*//' | sort -u)
        [[ -n "$parsed" ]] && gavs="$parsed"
    done

    # Strategy 2: Parse buildscript-locks (Gradle dependency locking via lockfile-per-config)
    if [[ -z "$gavs" ]]; then
        for lockdir in "$project_dir"/gradle/dependency-locks "$project_dir"/*/gradle/dependency-locks; do
            [[ -d "$lockdir" ]] || continue
            local parsed
            parsed=$(grep -E '^[a-zA-Z]' "$lockdir"/*.lockfile 2>/dev/null | sed 's/.*://' | sed 's/=.*//' | sort -u)
            [[ -n "$parsed" ]] && gavs="$parsed"
        done
    fi

    # Strategy 3: Run gradlew dependencies (slow but complete, ~10-20s)
    if [[ -z "$gavs" ]]; then
        echo "  Resolving Gradle dependency tree (one-time)..."
        local deps_output
        if deps_output=$(cd "$project_dir" && ./gradlew dependencies -q 2>/dev/null); then
            gavs=$(echo "$deps_output" | grep -oE '[a-zA-Z0-9._-]+:[a-zA-Z0-9._-]+:[a-zA-Z0-9._-]+' | sort -u)
        fi
    fi

    [[ -z "$gavs" ]] && return 1

    # Create output structure
    local target_files="$output_dir/caches/$modules_name/$files_name"
    mkdir -p "$target_files"

    # Copy metadata entirely (small, ~6MB, needed for Gradle resolution)
    for meta_dir in "$modules_parent"/metadata-*; do
        [[ -d "$meta_dir" ]] && cp -a "$meta_dir" "$output_dir/caches/$modules_name/" 2>/dev/null || true
    done
    # Copy resources cache (small, needed for POM resolution)
    for res_dir in "$modules_parent"/resources-*; do
        [[ -d "$res_dir" ]] && cp -a "$res_dir" "$output_dir/caches/$modules_name/" 2>/dev/null || true
    done

    # Copy only matching artifacts from files cache
    local copied=0
    while IFS= read -r gav; do
        [[ -z "$gav" ]] && continue
        local group artifact version
        group=$(echo "$gav" | cut -d: -f1)
        artifact=$(echo "$gav" | cut -d: -f2)
        version=$(echo "$gav" | cut -d: -f3)

        local src="$files_dir/$group/$artifact/$version"
        if [[ -d "$src" ]]; then
            mkdir -p "$target_files/$group/$artifact"
            cp -a "$src" "$target_files/$group/$artifact/" 2>/dev/null || true
            ((copied++)) || true
        fi
    done <<< "$gavs"

    # Copy matching Gradle wrapper distribution
    local wrapper_props="$project_dir/gradle/wrapper/gradle-wrapper.properties"
    if [[ -f "$wrapper_props" && -d "$host_cache/wrapper/dists" ]]; then
        local dist_url
        dist_url=$(grep 'distributionUrl' "$wrapper_props" | sed 's/.*=//' | sed 's/\\//g')
        local dist_name
        dist_name=$(basename "$dist_url" .zip)
        mkdir -p "$output_dir/wrapper/dists"
        for d in "$host_cache/wrapper/dists/$dist_name"*; do
            [[ -d "$d" ]] && cp -a "$d" "$output_dir/wrapper/dists/" 2>/dev/null || true
        done
    fi

    local total
    total=$(echo "$gavs" | wc -l | tr -d ' ')
    echo "  Sparse Gradle cache: $copied/$total dependencies copied from host"
    return 0
}

# --- Commands ---

cmd_start() {
    local _tmpfiles=()
    local _tmpdirs=()
    cleanup_tmpfiles() { rm -f "${_tmpfiles[@]}"; rm -rf "${_tmpdirs[@]}"; }
    trap cleanup_tmpfiles EXIT

    local project=""
    local session=""
    local profile=""
    local branch=""
    local provider=""
    local dangerous=false
    local read_only=false
    local open_network=false
    local docker=false
    local warm=false
    local extra_env=()

    # Parse args
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
            --warm) warm=true; shift ;;
            *)
                if [[ -z "$project" ]]; then
                    project="$1"
                elif [[ -z "$session" ]]; then
                    session="$1"
                else
                    echo "ERROR: Unexpected argument: $1" >&2
                    usage
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$project" || -z "$session" ]]; then
        echo "ERROR: start requires <project> and <session-name>" >&2
        usage
        exit 1
    fi

    validate_session_name "$session"

    # Default branch name to session name if not specified
    if [[ -z "$branch" ]]; then
        branch="$session"
    fi
    validate_branch_name "$branch"

    local project_path="$SANDBOX_BASE_DIR/$project"
    if [[ ! -d "$project_path" ]]; then
        echo "ERROR: Project directory not found: $project_path" >&2
        exit 1
    fi

    # Read project defaults from .sandbox.conf (CLI flags override)
    local conf_file="$project_path/.sandbox.conf"
    if [[ -f "$conf_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line//$'\r'/}"
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            if [[ ! "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*= ]]; then
                echo "WARNING: Ignoring invalid line in .sandbox.conf: '$line'" >&2
                continue
            fi
            local conf_key="${line%%=*}"
            local conf_val="${line#*=}"
            case "$conf_key" in
                docker)       [[ "$docker" == "false" && "$conf_val" == "true" ]] && docker=true ;;
                profile)      [[ -z "$profile" ]] && profile="$conf_val" ;;
                provider)     [[ -z "$provider" ]] && provider="$conf_val" ;;
                dangerous)    [[ "$dangerous" == "false" && "$conf_val" == "true" ]] && dangerous=true ;;
                open-network) [[ "$open_network" == "false" && "$conf_val" == "true" ]] && open_network=true ;;
                cpu-limit)    export SANDBOX_CPU_LIMIT="$conf_val" ;;
                memory-limit) export SANDBOX_MEMORY_LIMIT="$conf_val" ;;
                pid-limit)    export SANDBOX_PID_LIMIT="$conf_val" ;;
            esac
        done < "$conf_file"
    fi

    # Load provider (CLI > .sandbox.conf > env > default)
    if [[ -z "$provider" ]]; then
        provider="$SANDBOX_PROVIDER"
    fi
    load_provider "$provider"

    # Create or reuse git worktree for session isolation
    local worktree_path
    worktree_path="$(resolve_worktree "$project" "$session")"

    if [[ "$warm" == "false" ]]; then
        local wt_dir
        wt_dir="$(worktree_dir "$project")"
        mkdir -p "$wt_dir"
        # Ensure .worktrees is gitignored in the project
        if ! grep -qxF '/.worktrees' "$project_path/.gitignore" 2>/dev/null; then
            echo '/.worktrees' >> "$project_path/.gitignore"
        fi
        worktree_path="$wt_dir/${project}--${session}"
        if [[ -d "$worktree_path" ]]; then
            if [[ "$branch" != "$session" ]]; then
                echo "WARNING: --branch ignored; worktree already exists at $worktree_path"
            fi
            echo "Reusing existing worktree: $worktree_path"
        else
            echo "Creating worktree: $worktree_path (branch: $branch)"
            # Create branch from current HEAD if it doesn't exist
            if ! git -C "$project_path" rev-parse --verify "$branch" &>/dev/null; then
                git -C "$project_path" branch "$branch"
            fi
            git -C "$project_path" worktree add "$worktree_path" "$branch"
        fi
    fi

    # Store branch name and provider for cleanup and reconnection
    printf '%s\n%s\n' "$branch" "$provider" > "${worktree_path}.sandbox-meta"

    # Detect or use specified profile (from worktree)
    if [[ -z "$profile" ]]; then
        profile="${SANDBOX_DEFAULT_PROFILE:-$(detect_profile "$worktree_path")}"
    fi

    local comp_name
    comp_name=$(compose_project_name "$project" "$session")

    # Check if already running (skip when --warm; pool restarts expect re-entry)
    if [[ "$warm" == "false" ]]; then
        if docker compose -p "$comp_name" ps --status running 2>/dev/null | grep -q "agent"; then
            echo "Sandbox '$comp_name' is already running."
            echo "Use 'sandbox shell $project $session' to connect."
            exit 0
        fi
    fi

    # Build images (skip when --warm; images are already built on cold start)
    if [[ "$warm" == "false" ]]; then
        # Build base image if needed
        local image_tag="agent-sandbox:${profile}"
        if ! docker image inspect "$image_tag" &>/dev/null; then
            echo "Building image: $image_tag ..."
            if [[ "$profile" == "base" ]]; then
                docker build -f "$SCRIPT_DIR/images/base/Dockerfile" \
                    -t "$image_tag" "$SCRIPT_DIR/images/base"
            else
                # Build base first if needed
                if ! docker image inspect "agent-sandbox:base" &>/dev/null; then
                    docker build -f "$SCRIPT_DIR/images/base/Dockerfile" \
                        -t "agent-sandbox:base" "$SCRIPT_DIR/images/base"
                fi
                docker build -f "$SCRIPT_DIR/images/profiles/${profile}.Dockerfile" \
                    -t "$image_tag" "$SCRIPT_DIR/images/profiles"
            fi
        fi

        # Build provider layer on top of profile image
        local final_tag="agent-sandbox:${profile}"
        local provider_dockerfile
        provider_dockerfile=$(mktemp)
        _tmpfiles+=("$provider_dockerfile")
        echo "FROM agent-sandbox:${profile}" > "$provider_dockerfile"
        provider_setup "$image_tag" >> "$provider_dockerfile"
        docker build -f "$provider_dockerfile" \
            ${AGENT_VERSION:+--build-arg AGENT_VERSION="$AGENT_VERSION"} \
            -t "$final_tag" "$SCRIPT_DIR"

        # Build proxy image if needed
        if [[ "$open_network" == "false" ]] && ! docker image inspect "agent-sandbox:proxy" &>/dev/null; then
            echo "Building image: agent-sandbox:proxy ..."
            docker build -f "$SCRIPT_DIR/images/proxy/Dockerfile" -t "agent-sandbox:proxy" "$SCRIPT_DIR/images/proxy"
        fi

        # Build dind image if needed
        if [[ "$docker" == "true" ]] && ! docker image inspect "agent-sandbox:dind" &>/dev/null; then
            echo "Building image: agent-sandbox:dind ..."
            docker build -f "$SCRIPT_DIR/images/dind/Dockerfile" -t "agent-sandbox:dind" "$SCRIPT_DIR/images/dind"
        fi
    fi

    # Port allocation
    local port_base
    port_base=$(compute_port_base "${project}-${session}")
    port_base=$(find_free_port_base "$port_base")

    local port_frontend=$(( port_base + 0 ))
    local port_api=$(( port_base + 1 ))
    local port_db=$(( port_base + 2 ))
    local port_preview=$(( port_base + 3 ))
    local port_storybook=$(( port_base + 4 ))

    # Build compose file list
    local compose_files=("-f" "$SCRIPT_DIR/docker-compose.base.yml")
    if [[ "$profile" == "java" || "$profile" == "fullstack" ]]; then
        compose_files+=("-f" "$SCRIPT_DIR/docker-compose.java.yml")
    fi
    if [[ -f "$worktree_path/docker-compose.sandbox.yml" ]]; then
        compose_files+=("-f" "$worktree_path/docker-compose.sandbox.yml")
    fi

    # Export env vars for compose
    export COMPOSE_PROJECT_NAME="$comp_name"
    export SANDBOX_PROFILE="$profile"
    export SANDBOX_PROJECT_PATH="$worktree_path"
    export SANDBOX_PROJECT_GIT="$project_path/.git"
    # Pass host git identity into containers (honours user's global git config)
    export SANDBOX_GIT_USER_NAME="${SANDBOX_GIT_USER_NAME:-$(git config --global user.name 2>/dev/null || echo 'Agent Sandbox')}"
    export SANDBOX_GIT_USER_EMAIL="${SANDBOX_GIT_USER_EMAIL:-$(git config --global user.email 2>/dev/null || echo 'sandbox@localhost')}"
    # Mount host Gradle cache if it exists (Java/fullstack only)
    # Uses a sparse cache containing only the project's dependencies instead of
    # the entire ~/.gradle directory (saves GBs of unrelated artifacts).
    if [[ "$profile" == "java" || "$profile" == "fullstack" ]]; then
        if [[ -d "$HOME/.gradle/caches" ]]; then
            local sparse_cache_dir
            sparse_cache_dir=$(mktemp -d "${TMPDIR:-/tmp}/sandbox-gradle-XXXXXX")
            _tmpdirs+=("$sparse_cache_dir")
            if build_sparse_gradle_cache "$project_path" "$sparse_cache_dir"; then
                export SANDBOX_GRADLE_HOST="$sparse_cache_dir"
            else
                echo "  Warning: sparse cache failed, falling back to full ~/.gradle"
                export SANDBOX_GRADLE_HOST="$HOME/.gradle"
            fi
        else
            export SANDBOX_GRADLE_HOST="/dev/null"
        fi
    fi
    export SANDBOX_PORT_FRONTEND="$port_frontend"
    export SANDBOX_PORT_API="$port_api"
    export SANDBOX_PORT_DB="$port_db"
    export SANDBOX_PORT_PREVIEW="$port_preview"
    export SANDBOX_PORT_STORYBOOK="$port_storybook"

    if [[ "$read_only" == "true" ]]; then
        export SANDBOX_WORKSPACE_MODE="ro"
    else
        export SANDBOX_WORKSPACE_MODE="rw"
    fi

    # Network proxy setup
    if [[ "$open_network" == "true" ]]; then
        export SANDBOX_NET_INTERNAL="false"
        export SANDBOX_HTTP_PROXY=""
        export SANDBOX_HTTPS_PROXY=""
        export SANDBOX_NO_PROXY=""
        export SANDBOX_JAVA_PROXY_OPTS=""
        # Provide values for compose (proxy service won't start but vars must exist)
        export SANDBOX_WHITELIST_FILE="$SCRIPT_DIR/network-whitelist.txt"
        export SANDBOX_SQUID_CONF="$SCRIPT_DIR/images/proxy/squid.conf"
    else
        export SANDBOX_NET_INTERNAL="true"
        export SANDBOX_HTTP_PROXY="http://proxy:3128"
        export SANDBOX_HTTPS_PROXY="http://proxy:3128"
        export SANDBOX_NO_PROXY="localhost,127.0.0.1,db,proxy,dind"
        export SANDBOX_JAVA_PROXY_OPTS="-Dhttp.proxyHost=proxy -Dhttp.proxyPort=3128 -Dhttps.proxyHost=proxy -Dhttps.proxyPort=3128 -Dhttp.nonProxyHosts=localhost|127.0.0.1|db|dind"

        # Merge base + project whitelists
        local merged_whitelist
        merged_whitelist=$(mktemp)
        _tmpfiles+=("$merged_whitelist")
        cat "$SCRIPT_DIR/network-whitelist.txt" > "$merged_whitelist"
        if [[ -f "$worktree_path/network-whitelist.txt" ]]; then
            echo "" >> "$merged_whitelist"
            echo "# Project-specific whitelist entries" >> "$merged_whitelist"
            cat "$worktree_path/network-whitelist.txt" >> "$merged_whitelist"
        fi
        export SANDBOX_WHITELIST_FILE="$merged_whitelist"
        export SANDBOX_SQUID_CONF="$SCRIPT_DIR/images/proxy/squid.conf"
    fi

    # Docker-in-Docker setup
    if [[ "$docker" == "true" ]]; then
        export SANDBOX_DOCKER_HOST="tcp://dind:2375"
        export SANDBOX_TESTCONTAINERS_HOST="dind"
        export SANDBOX_RYUK_DISABLED="false"
    else
        export SANDBOX_DOCKER_HOST=""
        export SANDBOX_TESTCONTAINERS_HOST=""
        export SANDBOX_RYUK_DISABLED=""
    fi

    # Pass through extra env vars (validated)
    for env_pair in "${extra_env[@]+"${extra_env[@]}"}"; do
        validate_env_pair "$env_pair" || exit 1
        export "$env_pair"
    done

    echo "Starting sandbox: $comp_name"
    echo "  Provider: $provider"
    echo "  Profile:  $profile"
    echo "  Branch:   $branch (worktree: $worktree_path)"
    echo "  Network:  ${comp_name}-net"
    if [[ "$dangerous" == "true" ]]; then
        echo "  Mode:     DANGEROUS (skip permissions)"
    fi
    if [[ "$read_only" == "true" ]]; then
        echo "  Workspace: READ-ONLY"
    fi
    if [[ "$open_network" == "true" ]]; then
        echo "  Network:  OPEN (no proxy, unrestricted internet)"
    else
        echo "  Network:  FILTERED (proxy whitelist active)"
    fi
    if [[ "$docker" == "true" ]]; then
        echo "  Docker:   ENABLED (DinD sidecar)"
    fi
    echo ""

    # Generate dynamic compose override for node_modules volume mounts
    # Scans worktree for package.json files and creates volume overlays so
    # node_modules lives on a fast Docker volume instead of the slow bind mount
    local node_override
    node_override=$(mktemp)
    _tmpfiles+=("$node_override")
    cat > "$node_override" << 'NODEEOF'
services:
  agent:
    volumes:
NODEEOF
    local has_node_modules=false
    for pkg in "$worktree_path/package.json" "$worktree_path"/*/package.json; do
        [ -f "$pkg" ] || continue
        local pkg_dir
        pkg_dir=$(dirname "$pkg")
        local rel_dir="${pkg_dir#"$worktree_path"}"
        rel_dir="${rel_dir#/}"
        local vol_name="node_modules"
        if [[ -n "$rel_dir" ]]; then
            # Replace / and - with _ for valid volume names
            vol_name="node_modules_${rel_dir//[\/\-]/_}"
        fi
        echo "      - ${vol_name}:/workspace/${rel_dir:+${rel_dir}/}node_modules" >> "$node_override"
        has_node_modules=true
    done

    if [[ "$has_node_modules" == "true" ]]; then
        # Add volume declarations
        echo "" >> "$node_override"
        echo "volumes:" >> "$node_override"
        for pkg in "$worktree_path/package.json" "$worktree_path"/*/package.json; do
            [ -f "$pkg" ] || continue
            local pkg_dir
            pkg_dir=$(dirname "$pkg")
            local rel_dir="${pkg_dir#"$worktree_path"}"
            rel_dir="${rel_dir#/}"
            local vol_name="node_modules"
            if [[ -n "$rel_dir" ]]; then
                vol_name="node_modules_${rel_dir//[\/\-]/_}"
            fi
            echo "  ${vol_name}:" >> "$node_override"
        done
        compose_files+=("-f" "$node_override")
    fi

    # Generate provider compose override (env vars and mounts from provider hooks)
    local provider_override
    provider_override=$(mktemp)
    _tmpfiles+=("$provider_override")

    local env_lines=""
    if type provider_env &>/dev/null; then
        env_lines=$(provider_env | grep -v '^$' || true)
    fi

    local mount_lines=""
    if type provider_mounts &>/dev/null; then
        mount_lines=$(provider_mounts | grep -v '^$' || true)
    fi

    echo "services:" > "$provider_override"
    echo "  agent:" >> "$provider_override"

    if [[ -n "$env_lines" ]]; then
        echo "    environment:" >> "$provider_override"
        while IFS= read -r env_line; do
            echo "      - ${env_line}" >> "$provider_override"
        done <<< "$env_lines"
    fi

    if [[ -n "$mount_lines" ]]; then
        echo "    volumes:" >> "$provider_override"
        while IFS= read -r mount_line; do
            echo "      - ${mount_line}" >> "$provider_override"
        done <<< "$mount_lines"
    fi

    compose_files+=("-f" "$provider_override")

    local compose_up_args=()
    if [[ "$open_network" == "false" ]]; then
        compose_up_args+=(--profile proxy)
    fi
    if [[ "$docker" == "true" ]]; then
        compose_up_args+=(--profile docker)
    fi
    docker compose -p "$comp_name" "${compose_files[@]}" "${compose_up_args[@]}" up -d

    # Fix ownership on session-local volumes (skip when --warm; already done on cold start)
    if [[ "$warm" == "false" ]]; then
        if [[ "$profile" == "java" || "$profile" == "fullstack" ]]; then
            docker exec -u root "${comp_name}-agent" bash -c \
                "chown agent:agent /home/agent/.gradle /build-output || true"
        fi
        # Fix ownership on node_modules volumes (created as root by Docker)
        docker exec -u root "${comp_name}-agent" bash -c \
            'for d in /workspace/node_modules /workspace/*/node_modules; do [ -d "$d" ] && chown agent:agent "$d"; done' 2>/dev/null || true
    fi

    # Provider-specific post-start initialization (always runs — refreshes auth, etc.)
    provider_start "${comp_name}-agent" "$dangerous"

    # Expensive post-launch init (skip when --warm; already done on cold start)
    if [[ "$warm" == "false" ]]; then
        if [[ "$profile" == "java" || "$profile" == "fullstack" ]]; then
            # Seed Gradle cache from host (first start only)
            # Only copy dependency jars (modules-*) and wrapper — NOT transforms, groovy-dsl,
            # or version-specific immutable workspaces, which contain platform-specific metadata
            # that causes "immutable workspace does not contain metadata" errors on Linux.
            docker exec "${comp_name}-agent" bash -c '
                if [ -d /home/agent/.gradle-host/caches ] && [ ! -d /home/agent/.gradle/caches ]; then
                    echo "  Seeding Gradle cache from host..."
                    mkdir -p /home/agent/.gradle/caches
                    for d in /home/agent/.gradle-host/caches/modules-*; do
                        [ -d "$d" ] && cp -a "$d" /home/agent/.gradle/caches/ 2>/dev/null || true
                    done
                    cp -a /home/agent/.gradle-host/wrapper /home/agent/.gradle/wrapper 2>/dev/null || true
                    echo "  Gradle cache seeded."
                fi
            '

            # Gradle performance tuning (persists across sessions via gradle-cache volume)
            docker exec "${comp_name}-agent" bash -c '
                props="$HOME/.gradle/gradle.properties"
                if [ ! -f "$props" ]; then
                    cat > "$props" << "GRADLE_EOF"
# Sandbox Gradle performance tuning
org.gradle.daemon=true
org.gradle.daemon.idletimeout=1800000
org.gradle.jvmargs=-Xmx4g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -Dfile.encoding=UTF-8
org.gradle.parallel=true
org.gradle.caching=true
org.gradle.configuration-cache=true
org.gradle.configuration-cache.problems=warn
org.gradle.workers.max=4
GRADLE_EOF
                fi
            '
        fi

        # Enable Testcontainers reusable containers when Docker is enabled
        if [[ "$docker" == "true" ]]; then
            docker exec "${comp_name}-agent" bash -c \
                "echo 'testcontainers.reuse.enable=true' > /home/agent/.testcontainers.properties"
        fi

        # Auto-install Playwright browsers if the project depends on Playwright (node/fullstack only)
        if [[ "$profile" == "node" || "$profile" == "fullstack" ]]; then
            docker exec "${comp_name}-agent" bash -c '
                if grep -rq "@playwright" /workspace/packages/*/package.json /workspace/package.json 2>/dev/null; then
                    echo "  Installing Playwright browsers and system dependencies..."
                    sudo npx playwright install-deps chromium 2>&1 | tail -3
                    npx playwright install chromium 2>&1 | tail -1
                fi
            ' || true
        fi

        # Fix CRLF line endings on shell scripts (Windows host -> Linux container)
        docker exec -u root "${comp_name}-agent" bash -c \
            "find /workspace -maxdepth 4 -type f \( -name '*.sh' -o -name 'gradlew' \) -exec dos2unix -q {} + 2>/dev/null" || true
    fi

    # Fix git worktree pointer inside container (always runs — needed after bind mount change)
    # The .git file in the worktree points to the main repo's .git directory using host paths.
    # We overwrite it with container-compatible paths. This means host-side git on the worktree
    # won't work while the container is running, but that's expected — use the container.
    # cmd_stop restores the host paths before worktree removal.
    local worktree_name="${project}--${session}"
    docker exec "${comp_name}-agent" bash -c \
        "echo 'gitdir: /project-git/worktrees/$worktree_name' > /workspace/.git"

    # Seed .env in worktree from project's .env (always runs — worktree may be fresh)
    # Gitignored files don't exist in worktrees, and we don't want secrets in sandboxes.
    # Only LOCAL_ vars are safe for sandbox use (e.g., LOCAL_AUTH=true, LOCAL_DB_URL=...).
    for env_src in "$project_path"/.env "$project_path"/*/.env; do
        [[ -f "$env_src" ]] || continue
        local env_dir
        env_dir=$(dirname "$env_src")
        local rel_dir="${env_dir#"$project_path"}"
        local target_env="$worktree_path${rel_dir}/.env"
        if [[ ! -f "$target_env" ]]; then
            echo "  Seeding ${rel_dir:-.}/.env (LOCAL_* vars only)..."
            grep -E '^(LOCAL_|#|$)' "$env_src" > "$target_env" 2>/dev/null || true
        fi
    done

    # Seed .env.local in worktree from project's .env.local (VITE_ and LOCAL_ vars only)
    # .env.local is the standard Vite pattern for local overrides (gitignored).
    # VITE_ vars are build-time only (baked into frontend bundle), so inherently non-secret.
    for env_src in "$project_path"/.env.local "$project_path"/*/.env.local; do
        [[ -f "$env_src" ]] || continue
        local env_dir
        env_dir=$(dirname "$env_src")
        local rel_dir="${env_dir#"$project_path"}"
        local target_env="$worktree_path${rel_dir}/.env.local"
        if [[ ! -f "$target_env" ]]; then
            echo "  Seeding ${rel_dir:-.}/.env.local (VITE_* and LOCAL_* vars only)..."
            grep -E '^(VITE_|LOCAL_|#|$)' "$env_src" > "$target_env" 2>/dev/null || true
        fi
    done

    # Auto-install dependencies if missing (skip when --warm; already installed on cold start)
    if [[ "$warm" == "false" && "$read_only" == "false" ]]; then
        # npm install in any directory with package.json but no node_modules
        # node_modules dirs are Docker volume overlays (fast Linux-native I/O)
        docker exec "${comp_name}-agent" bash -c '
            for pkg in /workspace/package.json /workspace/*/package.json; do
                [ -f "$pkg" ] || continue
                dir=$(dirname "$pkg")
                if [ ! -d "$dir/node_modules" ] || [ -z "$(ls -A "$dir/node_modules" 2>/dev/null)" ]; then
                    echo "  Installing npm dependencies in ${dir#/workspace/}..."
                    (cd "$dir" && npm install --no-audit --no-fund --prefer-offline) 2>&1 | tail -1
                fi
            done
        ' &
        local npm_pid=$!

        # Gradle build output on fast volume (avoids slow bind-mount I/O)
        # Strategy: build/ and .gradle/ (project-level) go on /build-output volume, symlinked from workspace
        docker exec "${comp_name}-agent" bash -c '
            for gw in /workspace/gradlew /workspace/*/gradlew; do
                [ -f "$gw" ] || continue
                dir=$(dirname "$gw")
                # Find all subprojects with a build.gradle (includes root)
                for bg in "$dir"/build.gradle "$dir"/build.gradle.kts "$dir"/*/build.gradle "$dir"/*/build.gradle.kts; do
                    [ -f "$bg" ] || continue
                    sub=$(dirname "$bg")
                    rel=${sub#/workspace/}
                    for target in build .gradle; do
                        cache_dir="/build-output/$rel/$target"
                        ws_dir="$sub/$target"
                        if [ -L "$ws_dir" ]; then
                            continue  # already symlinked
                        fi
                        mkdir -p "$cache_dir"
                        if [ -d "$ws_dir" ]; then
                            # Move existing contents to volume
                            cp -a "$ws_dir/." "$cache_dir/" 2>/dev/null || true
                            rm -rf "$ws_dir"
                        fi
                        ln -s "$cache_dir" "$ws_dir"
                    done
                done
            done
        '

        # Gradle dependency resolution (warm cache if not present)
        docker exec "${comp_name}-agent" bash -c '
            for gw in /workspace/gradlew /workspace/*/gradlew; do
                [ -f "$gw" ] || continue
                dir=$(dirname "$gw")
                if [ ! -d "/home/agent/.gradle/caches" ]; then
                    echo "  Resolving Gradle dependencies in ${dir#/workspace/}..."
                    (cd "$dir" && ./gradlew dependencies --quiet) 2>&1 | tail -1
                fi
            done
        ' &
        local gradle_pid=$!

        # Wait for npm (fast) — let Gradle resolve in background (slow, non-blocking)
        wait $npm_pid 2>/dev/null || true
    fi

    log_event "START" "project=$project session=$session provider=$provider profile=$profile branch=$branch dangerous=$dangerous read_only=$read_only open_network=$open_network docker=$docker warm=$warm"

    echo ""
    echo "Sandbox '$comp_name' is running."
    echo ""
    echo "  Ports:"
    echo "    Frontend (3000):   localhost:$port_frontend"
    echo "    API (8080):        localhost:$port_api"
    echo "    DB (5432):         localhost:$port_db"
    echo "    Vite (5173):       localhost:$port_preview"
    echo "    Storybook (6006):  localhost:$port_storybook"
    echo ""
    echo "  Connect:"
    echo "    sandbox shell $project $session       # Open shell"
    echo "    sandbox headless $project $session    # Start headless for remote control"
    echo "    VS Code: Attach to container '${comp_name}-agent'"
}

cmd_stop() {
    local project="$1"
    local session="$2"
    validate_session_name "$session"
    local clean=false

    if [[ "${3:-}" == "--clean" ]]; then
        clean=true
    fi

    local comp_name
    comp_name=$(compose_project_name "$project" "$session")

    echo "Stopping sandbox: $comp_name"

    # Restore host .git pointer (cmd_start overwrites it with container-internal paths)
    # This must happen before stop so host-side git works on the worktree afterward.
    local worktree_path
    worktree_path="$(resolve_worktree "$project" "$session")"
    local project_path="$SANDBOX_BASE_DIR/$project"
    if [[ -d "$worktree_path" ]]; then
        local worktree_name="${project}--${session}"
        local git_path="$project_path/.git/worktrees/$worktree_name"
        # Git on Windows uses C:/Drive/... format, convert from /c/Drive/... if needed
        if [[ "$git_path" =~ ^/([a-zA-Z])/ ]]; then
            git_path="${BASH_REMATCH[1]^}:${git_path:2}"
        fi
        echo "gitdir: $git_path" > "$worktree_path/.git"
    fi

    if [[ "$clean" == "true" ]]; then
        docker compose -p "$comp_name" down -v
        echo "Sandbox stopped and volumes removed."

        # Remove git worktree if it exists
        if [[ -d "$worktree_path" ]]; then
            echo "Removing worktree: $worktree_path"
            # Read the actual branch name (stored outside worktree to avoid polluting git)
            local branch_name="$session"
            if [[ -f "${worktree_path}.sandbox-meta" ]]; then
                branch_name=$(sed -n '1p' "${worktree_path}.sandbox-meta")
            fi
            # Enable long paths to handle deeply nested files (node_modules, Gradle caches)
            git -C "$project_path" config core.longpaths true
            git -C "$project_path" worktree remove "$worktree_path" --force 2>/dev/null \
                || rm -rf "$worktree_path"
            rm -f "${worktree_path}.sandbox-meta"
            echo "Worktree removed."
            if git -C "$project_path" branch --merged | grep -qE "^\s*${branch_name}$"; then
                # Check if branch had any unique commits
                local parent_branch
                parent_branch=$(git -C "$project_path" rev-parse HEAD 2>/dev/null)
                local branch_tip
                branch_tip=$(git -C "$project_path" rev-parse "$branch_name" 2>/dev/null)
                if [[ "$parent_branch" == "$branch_tip" ]]; then
                    git -C "$project_path" branch -d "$branch_name" 2>/dev/null && \
                        echo "Branch '$branch_name' deleted (no changes)." || true
                else
                    git -C "$project_path" branch -d "$branch_name" 2>/dev/null && \
                        echo "Branch '$branch_name' deleted (was fully merged)." || true
                fi
            fi
        fi
    else
        docker compose -p "$comp_name" down
        echo "Sandbox stopped. Worktree and volumes preserved (use --clean to remove)."
    fi

    log_event "STOP" "project=$project session=$session clean=$clean"
}

cmd_list() {
    echo "Running sandboxes:"
    echo ""

    local found=false
    local -a projects=()
    local -a sessions=()
    local idx=0

    for container in $(docker ps --filter "label=com.docker.compose.project" --format '{{.Labels}}' 2>/dev/null | grep -o 'com.docker.compose.project=[^ ,]*' | sed 's/com.docker.compose.project=//' | sort -u); do
        if [[ "$container" == sandbox-* ]]; then
            found=true
            # Parse project and session from compose project name: sandbox-<project>-<session>
            local remainder="${container#sandbox-}"
            # Find the session by looking for worktree meta files
            local project=""
            local session=""
            # Search per-project .worktrees/ (current) and legacy global .worktrees/ (backwards compat)
            for meta in "$SANDBOX_BASE_DIR"/*/.worktrees/*--*.sandbox-meta "$SANDBOX_BASE_DIR"/.worktrees/*--*.sandbox-meta; do
                [ -f "$meta" ] || continue
                local wt_name
                wt_name=$(basename "${meta%.sandbox-meta}")
                local p="${wt_name%%--*}"
                local s="${wt_name#*--}"
                if [[ "sandbox-${p}-${s}" == "$container" ]]; then
                    project="$p"
                    session="$s"
                    break
                fi
            done

            if [[ -n "$project" && -n "$session" ]]; then
                idx=$((idx + 1))
                projects+=("$project")
                sessions+=("$session")
                local uptime
                uptime=$(docker ps --filter "name=${container}-agent" --format '{{.Status}}' 2>/dev/null | head -1)
                local pool_tag=""
                if is_pool_sandbox "$project" "$session"; then
                    local pool_state
                    pool_state=$(pool_read_state "$project" "$session")
                    pool_tag=" [pool:$pool_state]"
                fi
                echo "  [$idx] $project / $session${pool_tag}"
                echo "      Status: $uptime"
                echo ""
            else
                echo "  $container"
                docker compose -p "$container" ps --format "    {{.Name}}\t{{.Status}}" 2>/dev/null
                echo ""
            fi
        fi
    done

    if [[ "$found" == "false" ]]; then
        echo "  (none)"
        return
    fi

    # Interactive menu — read from /dev/tty so it works whether invoked
    # directly in bash, through the PowerShell wrapper, or via pipes.
    # /dev/tty is available on Linux and Git Bash on Windows.
    if [[ -t 0 ]]; then
        local tty_in=/dev/stdin
    elif [[ -e /dev/tty ]]; then
        local tty_in=/dev/tty
    else
        return
    fi

    echo "Actions: [s]hell  [l]ogs  [d]iff  [m]erge  [x]stop  [q]uit"
    echo ""

    local pick
    read -rp "Pick sandbox number: " pick < "$tty_in"
    [[ -z "$pick" || "$pick" == "q" ]] && return

    if ! [[ "$pick" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > idx )); then
        echo "Invalid selection." >&2
        return
    fi

    local sel_project="${projects[$((pick - 1))]}"
    local sel_session="${sessions[$((pick - 1))]}"

    local action
    read -rp "Action for $sel_project/$sel_session [s/l/d/m/x/q]: " action < "$tty_in"
    case "$action" in
        s) cmd_shell "$sel_project" "$sel_session" ;;
        l) cmd_logs "$sel_project" "$sel_session" ;;
        d) cmd_diff "$sel_project" "$sel_session" ;;
        m)
            local do_clean
            read -rp "Clean up after merge? [y/N]: " do_clean < "$tty_in"
            if [[ "$do_clean" == [yY] ]]; then
                cmd_merge "$sel_project" "$sel_session" --clean
            else
                cmd_merge "$sel_project" "$sel_session"
            fi
            ;;
        x)
            local do_clean
            read -rp "Remove volumes and worktree (--clean)? [y/N]: " do_clean < "$tty_in"
            if [[ "$do_clean" == [yY] ]]; then
                cmd_stop "$sel_project" "$sel_session" --clean
            else
                cmd_stop "$sel_project" "$sel_session"
            fi
            ;;
        q|"") return ;;
        *) echo "Unknown action: $action" >&2 ;;
    esac
}

cmd_logs() {
    local project="$1"
    local session="$2"
    validate_session_name "$session"
    local service="${3:-}"

    local comp_name
    comp_name=$(compose_project_name "$project" "$session")

    if [[ -n "$service" ]]; then
        docker compose -p "$comp_name" logs -f "$service"
    else
        docker compose -p "$comp_name" logs -f
    fi
}

cmd_shell() {
    local project="$1"
    local session="$2"
    validate_session_name "$session"

    # Resolve provider from session metadata (persisted at start time)
    local meta_file="$(resolve_worktree "$project" "$session").sandbox-meta"
    local resolved_provider="$SANDBOX_PROVIDER"
    if [[ -f "$meta_file" ]]; then
        local meta_provider
        meta_provider=$(sed -n '2p' "$meta_file")
        [[ -n "$meta_provider" ]] && resolved_provider="$meta_provider"
    fi
    load_provider "$resolved_provider"

    local comp_name
    comp_name=$(compose_project_name "$project" "$session")

    echo "Connecting to agent container in sandbox: $comp_name"
    provider_connect "${comp_name}-agent"
}

cmd_headless() {
    local project="$1"
    local session="$2"
    validate_session_name "$session"

    # Resolve provider from session metadata (persisted at start time)
    local meta_file="$(resolve_worktree "$project" "$session").sandbox-meta"
    local resolved_provider="$SANDBOX_PROVIDER"
    if [[ -f "$meta_file" ]]; then
        local meta_provider
        meta_provider=$(sed -n '2p' "$meta_file")
        [[ -n "$meta_provider" ]] && resolved_provider="$meta_provider"
    fi
    load_provider "$resolved_provider"

    local comp_name
    comp_name=$(compose_project_name "$project" "$session")

    if type provider_headless &>/dev/null; then
        provider_headless "${comp_name}-agent"
    else
        echo "ERROR: Provider '$SANDBOX_PROVIDER' does not support headless mode" >&2
        exit 1
    fi
}

cmd_diff() {
    local project="$1"
    local session="$2"
    validate_session_name "$session"
    local stat_only=false

    if [[ "${3:-}" == "--stat" ]]; then
        stat_only=true
    fi

    local comp_name
    comp_name=$(compose_project_name "$project" "$session")

    # Check if container is running — use it for git. Otherwise use worktree directly.
    local git_cmd=()
    if docker compose -p "$comp_name" ps --status running 2>/dev/null | grep -q "agent"; then
        git_cmd=(docker exec "${comp_name}-agent" git)
    else
        local worktree_path
        worktree_path="$(resolve_worktree "$project" "$session")"
        if [[ ! -d "$worktree_path" ]]; then
            echo "ERROR: No worktree found at $worktree_path" >&2
            exit 1
        fi
        git_cmd=(git -C "$worktree_path")
    fi

    echo "Changes in sandbox: ${project}/${session}"
    echo "================================================"
    echo ""

    if [[ "$stat_only" == "true" ]]; then
        "${git_cmd[@]}" diff --stat
    else
        # Show staged + unstaged diff
        "${git_cmd[@]}" diff HEAD
    fi

    # Show untracked files
    local untracked
    untracked=$("${git_cmd[@]}" ls-files --others --exclude-standard)
    if [[ -n "$untracked" ]]; then
        echo ""
        echo "Untracked files:"
        echo "$untracked" | sed 's/^/  /'
    fi
}

cmd_repair() {
    local project="$1"
    local session="$2"

    validate_session_name "$session"

    local worktree_path
    worktree_path="$(resolve_worktree "$project" "$session")"
    local project_path="$SANDBOX_BASE_DIR/$project"

    if [[ ! -d "$worktree_path" ]]; then
        echo "ERROR: No worktree found at $worktree_path" >&2
        exit 1
    fi

    local worktree_name="${project}--${session}"
    local git_path="$project_path/.git/worktrees/$worktree_name"
    if [[ "$git_path" =~ ^/([a-zA-Z])/ ]]; then
        git_path="${BASH_REMATCH[1]^}:${git_path:2}"
    fi
    echo "gitdir: $git_path" > "$worktree_path/.git"
    echo "Repaired .git pointer in $worktree_path"
}

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

    # Clean up sandbox runtime artifacts before checking for uncommitted changes.
    # The sandbox startup process modifies files (dos2unix on scripts, npm install
    # creating lockfiles, Gradle build output) that are not real agent work.
    echo "Cleaning sandbox artifacts..."

    # Reset modified tracked files that are sandbox artifacts (line-ending changes,
    # generated files from builds, lockfiles modified by dependency installs)
    local artifact_patterns=(
        '*.sh' 'gradlew' 'gradlew.bat'           # dos2unix line-ending changes
        'openapi.json' '*/openapi.json'           # generated API specs from builds
        'package-lock.json' '*/package-lock.json'  # npm install side-effects
        'pnpm-lock.yaml' '*/pnpm-lock.yaml'       # pnpm install side-effects
        'yarn.lock' '*/yarn.lock'                  # yarn install side-effects
    )
    git -C "$worktree_path" diff --name-only 2>/dev/null | while IFS= read -r f; do
        local is_artifact=false
        # Check line-ending-only changes
        if git -C "$worktree_path" diff --ignore-cr-at-eol --quiet -- "$f" 2>/dev/null; then
            is_artifact=true
        fi
        # Check known artifact patterns
        for pat in "${artifact_patterns[@]}"; do
            # shellcheck disable=SC2254
            case "$f" in $pat) is_artifact=true ;; esac
        done
        if [[ "$is_artifact" == "true" ]]; then
            git -C "$worktree_path" checkout -- "$f" 2>/dev/null
        fi
    done

    # Remove untracked build artifacts that the sandbox created
    find "$worktree_path" -maxdepth 3 -type d \( -name 'build' -o -name '.gradle' \) \
        -exec rm -rf {} + 2>/dev/null || true
    find "$worktree_path" -maxdepth 2 -name 'package-lock.json' -newer "$worktree_path/.git" \
        -exec rm -f {} + 2>/dev/null || true

    # Report any remaining uncommitted changes (don't fail — caller decides)
    local uncommitted
    uncommitted=$(git -C "$worktree_path" status --porcelain 2>/dev/null || true)
    if [[ -n "$uncommitted" ]]; then
        local file_count
        file_count=$(echo "$uncommitted" | wc -l | tr -d ' ')
        echo ""
        echo "  Uncommitted changes ($file_count files):"
        git -C "$worktree_path" status --short 2>/dev/null | sed 's/^/    /'
        echo ""
        echo "  These were NOT included in the merge."
        echo "  Worktree preserved at: $worktree_path"
        echo ""
    fi

    # Validate: commits exist on the branch
    local current_branch
    current_branch=$(git -C "$project_path" rev-parse --abbrev-ref HEAD)
    local commit_count
    commit_count=$(git -C "$project_path" rev-list --count "${current_branch}..${branch_name}" 2>/dev/null || echo "0")
    if [[ "$commit_count" -eq 0 ]]; then
        # Check if there are uncommitted changes that the agent forgot to commit
        local has_changes
        has_changes=$(git -C "$worktree_path" status --porcelain 2>/dev/null || true)
        if [[ -n "$has_changes" ]]; then
            echo "WARNING: Agent did not commit, but there are changes in the worktree." >&2
            echo "Auto-committing agent work..." >&2
            git -C "$worktree_path" add -A
            git -C "$worktree_path" commit -m "feat: auto-commit uncommitted agent work" 2>/dev/null || true
            commit_count=$(git -C "$project_path" rev-list --count "${current_branch}..${branch_name}" 2>/dev/null || echo "0")
        fi
        if [[ "$commit_count" -eq 0 ]]; then
            echo "ERROR: No commits found on branch '$branch_name' beyond '$current_branch'." >&2
            echo "The sandbox produced no changes." >&2
            return 1
        fi
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

cmd_prune() {
    local force=false
    if [[ "${1:-}" == "--force" ]]; then
        force=true
    fi

    # Collect all sandbox-* volumes
    local all_volumes
    all_volumes=$(docker volume ls --format '{{.Name}}' | grep '^sandbox-' || true)

    if [[ -z "$all_volumes" ]]; then
        echo "No sandbox volumes found."
        return
    fi

    # Collect volumes that belong to currently running compose projects
    local active_volumes=""
    for container in $(docker ps --filter "label=com.docker.compose.project" --format '{{.Labels}}' 2>/dev/null \
        | grep -o 'com.docker.compose.project=[^ ,]*' | sed 's/com.docker.compose.project=//' | sort -u); do
        if [[ "$container" == sandbox-* ]]; then
            # List volumes owned by this running project
            local project_vols
            project_vols=$(docker compose -p "$container" config --volumes 2>/dev/null \
                | sed "s/^/${container}_/" || true)
            active_volumes="$active_volumes"$'\n'"$project_vols"
        fi
    done

    # Filter to orphaned volumes (not owned by any running project)
    local orphaned=""
    local orphan_count=0
    while IFS= read -r vol; do
        [[ -z "$vol" ]] && continue
        if ! echo "$active_volumes" | grep -qxF "$vol"; then
            orphaned="$orphaned"$'\n'"$vol"
            orphan_count=$((orphan_count + 1))
        fi
    done <<< "$all_volumes"

    if [[ $orphan_count -eq 0 ]]; then
        echo "No orphaned sandbox volumes found."
        return
    fi

    # Group by session for readable output
    echo "Orphaned sandbox volumes ($orphan_count):"
    echo ""
    local current_session=""
    while IFS= read -r vol; do
        [[ -z "$vol" ]] && continue
        # Extract session prefix (everything before the last _suffix)
        local session_prefix="${vol%_*}"
        if [[ "$session_prefix" != "$current_session" ]]; then
            current_session="$session_prefix"
            echo "  $session_prefix"
        fi
        echo "    - ${vol##*_}"
    done <<< "$orphaned"
    echo ""

    if [[ "$force" != "true" ]]; then
        # Read from /dev/tty for cross-platform interactive prompt support
        local tty_in=/dev/stdin
        [[ -t 0 ]] || { [[ -e /dev/tty ]] && tty_in=/dev/tty; }
        local confirm
        read -rp "Remove all $orphan_count orphaned volumes? [y/N] " confirm < "$tty_in"
        if [[ "$confirm" != [yY] ]]; then
            echo "Aborted."
            return
        fi
    fi

    local removed=0
    local failed=0
    while IFS= read -r vol; do
        [[ -z "$vol" ]] && continue
        if docker volume rm "$vol" &>/dev/null; then
            removed=$((removed + 1))
        else
            echo "  WARNING: Could not remove $vol (in use?)" >&2
            failed=$((failed + 1))
        fi
    done <<< "$orphaned"

    echo "Removed $removed volumes."
    [[ $failed -gt 0 ]] && echo "$failed volumes could not be removed."

    log_event "PRUNE" "removed=$removed failed=$failed"
}

cmd_update() {
    echo "Updating sandbox images..."
    echo ""

    # Remove old images to force rebuild
    local profiles=("base" "java" "node" "fullstack" "proxy" "dind")
    for p in "${profiles[@]}"; do
        if docker image inspect "agent-sandbox:$p" &>/dev/null; then
            echo "Removing old image: agent-sandbox:$p"
            docker rmi "agent-sandbox:$p" 2>/dev/null || true
        fi
    done

    echo ""
    echo "Building base image..."
    docker build -f "$SCRIPT_DIR/images/base/Dockerfile" \
        --no-cache \
        -t "agent-sandbox:base" "$SCRIPT_DIR/images/base"

    echo ""
    echo "Building proxy image..."
    docker build -f "$SCRIPT_DIR/images/proxy/Dockerfile" \
        -t "agent-sandbox:proxy" "$SCRIPT_DIR/images/proxy"

    echo ""
    echo "Building dind image..."
    docker build -f "$SCRIPT_DIR/images/dind/Dockerfile" \
        -t "agent-sandbox:dind" "$SCRIPT_DIR/images/dind"

    # Rebuild any profile images that were previously built
    for p in java node fullstack; do
        if [[ -f "$SCRIPT_DIR/images/profiles/${p}.Dockerfile" ]]; then
            echo ""
            echo "Building $p image..."
            docker build -f "$SCRIPT_DIR/images/profiles/${p}.Dockerfile" \
                -t "agent-sandbox:$p" "$SCRIPT_DIR/images/profiles"
        fi
    done

    echo ""
    echo "All images updated."
    echo "Running sandboxes will use old images until restarted."
}

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
                ( cmd_start "$project" "$session" "${start_args[@]}" )
                pool_write_state "$project" "$session" "idle"
            fi
            continue
        fi

        echo "  Starting pool sandbox: $session"
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

    # Atomically claim an idle sandbox (writes "busy" under mkdir lock)
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

    echo "Pool sandbox '$session' container is ready on branch '$branch'."
    echo "The sandbox-execute skill will launch the agent."
    echo ""
    echo "  Check status:  sandbox pool status $project"
    echo "  Cancel:        sandbox pool cancel $project $session"
}

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

cmd_pool_accept() {
    local project=""
    local session=""
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            *)
                if [[ -z "$project" ]]; then
                    project="$1"
                elif [[ -z "$session" ]]; then
                    session="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$project" || -z "$session" ]]; then
        echo "ERROR: pool accept requires <project> <session>" >&2
        exit 1
    fi

    # Atomic state check with mkdir lock
    local pdir
    pdir="$(pool_dir "$project")"
    local state_file="$pdir/${session}.state"
    local lock_dir="${state_file}.lock"
    local verified="no"
    if mkdir "$lock_dir" 2>/dev/null; then
        local state
        state=$(cat "$state_file" 2>/dev/null)
        if [[ "$state" == "reviewing" ]]; then
            echo "accepting" > "$state_file"
            verified="yes"
        fi
        rmdir "$lock_dir" 2>/dev/null || true
    else
        echo "ERROR: Could not acquire lock on pool sandbox '$session'." >&2
        exit 1
    fi

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

    # Check for uncommitted changes before cleanup — prompt user to confirm discard
    local leftover
    leftover=$(git -C "$worktree_path" status --porcelain 2>/dev/null || true)
    if [[ -n "$leftover" ]]; then
        local file_count
        file_count=$(echo "$leftover" | wc -l | tr -d ' ')
        echo ""
        echo "Uncommitted changes in worktree ($file_count files):"
        git -C "$worktree_path" status --short 2>/dev/null | sed 's/^/  /'
        echo ""
        echo "These were NOT included in the merge."

        if [[ "$force" == "true" ]]; then
            echo "  --force: discarding uncommitted changes."
        else
            local tty_in=/dev/stdin
            [[ -t 0 ]] || { [[ -e /dev/tty ]] && tty_in=/dev/tty; }
            local confirm
            read -rp "Discard these changes and clean up? [y/N] " confirm < "$tty_in"
            if [[ "$confirm" != [yY] ]]; then
                echo ""
                echo "Worktree preserved: $worktree_path"
                echo "Commit anything you need, then run:"
                echo "  sandbox pool accept $project $session"
                pool_write_state "$project" "$session" "reviewing"
                return
            fi
        fi
    fi

    # Clean up worktree and branch
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

    echo ""
    echo "Pool sandbox '$session' is idle. Next pool assign will warm-restart it."
}

cmd_pool_reject() {
    local project="$1"
    local session="$2"

    if [[ -z "$project" || -z "$session" ]]; then
        echo "ERROR: pool reject requires <project> <session>" >&2
        exit 1
    fi

    # Atomic state check with mkdir lock
    local pdir
    pdir="$(pool_dir "$project")"
    local state_file="$pdir/${session}.state"
    local lock_dir="${state_file}.lock"
    local verified="no"
    if mkdir "$lock_dir" 2>/dev/null; then
        local state
        state=$(cat "$state_file" 2>/dev/null)
        if [[ "$state" == "reviewing" ]]; then
            echo "rejecting" > "$state_file"
            verified="yes"
        fi
        rmdir "$lock_dir" 2>/dev/null || true
    else
        echo "ERROR: Could not acquire lock on pool sandbox '$session'." >&2
        exit 1
    fi

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

    echo "Pool sandbox '$session' is idle. Next pool assign will warm-restart it."
}

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

# --- Main ---

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

command="$1"
shift

case "$command" in
    start)    cmd_start "$@" ;;
    stop)     cmd_stop "$@" ;;
    list)     cmd_list ;;
    logs)     cmd_logs "$@" ;;
    shell)    cmd_shell "$@" ;;
    headless) cmd_headless "$@" ;;
    diff)     cmd_diff "$@" ;;
    merge)    cmd_merge "$@" ;;
    repair)   cmd_repair "$@" ;;
    prune)    cmd_prune "$@" ;;
    pool)
        pool_cmd="${1:-}"
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
    update)   cmd_update ;;
    -h|--help|help) usage ;;
    *)
        echo "ERROR: Unknown command: $command" >&2
        usage
        exit 1
        ;;
esac
