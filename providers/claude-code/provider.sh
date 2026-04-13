#!/usr/bin/env bash
# provider.sh — Hook implementations for the claude-code provider
#
# Reference implementation of the Anthropic Claude Code CLI provider.
# Implements all lifecycle hooks for the agent-sandbox launcher.

set -euo pipefail

# ------------------------------------------------------------------------------
# REQUIRED HOOKS
# ------------------------------------------------------------------------------

# provider_setup <image_tag>
#
# Outputs Dockerfile instructions to install Claude Code CLI into the image.
# The launcher prepends FROM <base-image> and appends these lines.
#
provider_setup() {
    cat << 'DOCKERFILE'
USER agent
ARG AGENT_VERSION=latest
RUN curl -fsSL https://claude.ai/install.sh | bash -s ${AGENT_VERSION}
ENV PATH="/home/agent/.local/bin:${PATH}"
ENV DISABLE_AUTOUPDATER=1
DOCKERFILE
}

# provider_start <container_name> <dangerous>
#
# Called once after the container has started and is healthy. Performs all
# Claude Code-specific runtime initialization:
#   1. Seeds Claude config from the read-only host mount
#   2. Refreshes auth credentials from the host on every start
#   3. Pre-accepts workspace trust dialog for /workspace
#   4. Optionally enables dangerous mode (skip permissions prompt)
#   5. Rewrites Windows plugin paths to Linux paths
#   6. Sets up bash alias for dangerous mode
#   7. Prefills bash history with common claude commands
#
# Args:
#   $1  container_name — the running Docker container name
#   $2  dangerous      — "true" if --dangerous flag was passed, "false" otherwise
#
provider_start() {
    local container="${1:?container_name required}"
    local dangerous="${2:-false}"

    # 1. Seed Claude config from host mount (no-clobber — only copies missing files)
    docker exec -u root "$container" bash -c \
        "cp -rn /home/agent/.claude-host/. /home/agent/.claude/ 2>/dev/null; chown -R agent:agent /home/agent/.claude || true"

    # 2. Refresh auth credentials from host on every start so tokens stay current
    docker exec "$container" bash -c \
        "cp -f /home/agent/.claude-host/.credentials.json /home/agent/.claude/.credentials.json 2>/dev/null; cp -f /home/agent/.claude-host/.credentials /home/agent/.claude/.credentials 2>/dev/null" || true

    # 3. Pre-accept workspace trust dialog for /workspace
    docker exec "$container" node -e "
        const fs = require('fs');
        const f = '/home/agent/.claude.json';
        const j = JSON.parse(fs.readFileSync(f, 'utf8'));
        if (!j.projects) j.projects = {};
        if (!j.projects['/workspace']) j.projects['/workspace'] = {};
        j.projects['/workspace'].hasTrustDialogAccepted = true;
        j.projects['/workspace'].allowedTools = [];
        fs.writeFileSync(f, JSON.stringify(j, null, 2));
    " 2>/dev/null || true

    # 4. If dangerous mode, skip permission prompt and mark the container
    if [[ "$dangerous" == "true" ]]; then
        docker exec "$container" node -e "
            const fs = require('fs');
            const f = '/home/agent/.claude/settings.json';
            let j = {};
            try { j = JSON.parse(fs.readFileSync(f, 'utf8')); } catch(e) {}
            j.skipDangerousModePermissionPrompt = true;
            fs.writeFileSync(f, JSON.stringify(j, null, 2));
        " 2>/dev/null || true
        docker exec "$container" bash -c "touch /home/agent/.dangerous-mode"
    fi

    # 5. Rewrite Windows plugin paths to Linux paths
    docker exec "$container" node -e "
        const f = '/home/agent/.claude/plugins/installed_plugins.json';
        const fs = require('fs');
        if (!fs.existsSync(f)) process.exit(0);
        let d = fs.readFileSync(f, 'utf8');
        d = d.replace(/C:\\\\Users\\\\[^\\\\\"]+ \\\\.claude\\\\/g, '/home/agent/.claude/');
        d = d.replace(/\\\\/g, '/');
        fs.writeFileSync(f, d);
    " 2>/dev/null || true

    # 6. Set up bash alias so 'claude' auto-includes --dangerously-skip-permissions in dangerous mode
    docker exec "$container" bash -c \
        'echo "if [ -f /home/agent/.dangerous-mode ]; then alias claude=\"claude --dangerously-skip-permissions\"; fi" >> /home/agent/.bashrc'

    # 7. Prefill shell history with common claude commands
    docker exec "$container" bash -c 'cat > /home/agent/.bash_history << "HISTORY"
claude
claude --dangerously-skip-permissions
claude --headless
claude --dangerously-skip-permissions --headless
claude --resume
claude --continue
HISTORY'
}

# provider_connect <container_name>
#
# Called when the user runs `sandbox shell`. Attaches an interactive bash
# session. Prints mode information first if running in dangerous mode.
#
provider_connect() {
    local container="${1:?container_name required}"
    if docker exec "$container" bash -c "test -f /home/agent/.dangerous-mode" 2>/dev/null; then
        echo "  Mode: DANGEROUS (skip permissions)"
        echo "  Run 'claude' to start Claude Code with --dangerously-skip-permissions"
    fi
    docker exec -it "$container" bash
}

# provider_healthcheck <container_name>
#
# Verifies Claude Code CLI is installed and functional. Exits 0 if healthy.
#
provider_healthcheck() {
    local container="${1:?container_name required}"
    docker exec "$container" claude --version &>/dev/null
}

# ------------------------------------------------------------------------------
# OPTIONAL HOOKS
# ------------------------------------------------------------------------------

# provider_env
#
# Injects ANTHROPIC_API_KEY into the container environment.
#
provider_env() {
    echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}"
}

# provider_mounts
#
# Mounts the host ~/.claude directory read-only as .claude-host for config
# seeding, and ~/.claude.json for project-level settings.
#
provider_mounts() {
    local claude_config="${SANDBOX_CLAUDE_CONFIG:-$HOME/.claude}"
    echo "${claude_config}:/home/agent/.claude-host:ro"
    echo "${HOME}/.claude.json:/home/agent/.claude.json"
}

# provider_headless <container_name>
#
# Called when the user runs `sandbox headless`. Starts Claude Code in headless
# mode for remote control via claude.ai. Applies --dangerously-skip-permissions
# automatically if the container was started with --dangerous.
#
provider_headless() {
    local container="${1:?container_name required}"
    local claude_args="--headless"
    if docker exec "$container" bash -c "test -f /home/agent/.dangerous-mode" 2>/dev/null; then
        claude_args="--dangerously-skip-permissions --headless"
        echo "Starting Claude Code in headless mode (DANGEROUS)..."
    else
        echo "Starting Claude Code in headless mode..."
    fi
    echo "Connect via claude.ai remote control."
    echo ""
    docker exec -it "$container" claude $claude_args
}

# provider_process_name
#
# Returns the process name pattern used to detect when the agent is running.
# Used by the pool completion watcher with pgrep -f.
# The watcher applies the bracket trick automatically (claude -> [c]laude).
#
provider_process_name() {
    echo "claude"
}
