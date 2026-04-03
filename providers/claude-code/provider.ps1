# provider.ps1 — Hook implementations for the claude-code provider (PowerShell)
#
# Reference implementation of the Anthropic Claude Code CLI provider for the
# PowerShell launcher. Mirrors provider.sh — update both files together.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------------------
# REQUIRED HOOKS
# ------------------------------------------------------------------------------

# Invoke-ProviderSetup
#
# Outputs Dockerfile instructions to install Claude Code CLI into the image.
# The launcher prepends FROM <base-image> and appends these lines.
#
function Invoke-ProviderSetup {
    param(
        [Parameter(Mandatory)][string]$ImageTag
    )
    Write-Output "USER agent"
    Write-Output "ARG AGENT_VERSION=latest"
    Write-Output "RUN curl -fsSL https://claude.ai/install.sh | bash -s `${AGENT_VERSION}"
    Write-Output 'ENV PATH="/home/agent/.local/bin:${PATH}"'
    Write-Output "ENV DISABLE_AUTOUPDATER=1"
}

# Invoke-ProviderStart
#
# Called once after the container has started and is healthy. Performs all
# Claude Code-specific runtime initialization — mirrors provider_start() in
# provider.sh. See that file for step-by-step documentation.
#
# Parameters:
#   ContainerName  — the running Docker container name
#   Dangerous      — $true if --dangerous flag was passed
#
function Invoke-ProviderStart {
    param(
        [Parameter(Mandatory)][string]$ContainerName,
        [bool]$Dangerous = $false
    )

    # 1. Seed Claude config from host mount (no-clobber)
    docker exec -u root $ContainerName bash -c `
        "cp -rn /home/agent/.claude-host/. /home/agent/.claude/ 2>/dev/null; chown -R agent:agent /home/agent/.claude || true"

    # 2. Refresh auth credentials from host on every start
    docker exec $ContainerName bash -c `
        "cp -f /home/agent/.claude-host/.credentials.json /home/agent/.claude/.credentials.json 2>/dev/null; cp -f /home/agent/.claude-host/.credentials /home/agent/.claude/.credentials 2>/dev/null"

    # 3. Pre-accept workspace trust dialog for /workspace
    $trustScript = @'
        const fs = require('fs');
        const f = '/home/agent/.claude.json';
        const j = JSON.parse(fs.readFileSync(f, 'utf8'));
        if (!j.projects) j.projects = {};
        if (!j.projects['/workspace']) j.projects['/workspace'] = {};
        j.projects['/workspace'].hasTrustDialogAccepted = true;
        j.projects['/workspace'].allowedTools = [];
        fs.writeFileSync(f, JSON.stringify(j, null, 2));
'@
    docker exec $ContainerName node -e $trustScript 2>$null

    # 4. If dangerous mode, skip permission prompt and mark the container
    if ($Dangerous) {
        $dangerScript = @'
            const fs = require('fs');
            const f = '/home/agent/.claude/settings.json';
            let j = {};
            try { j = JSON.parse(fs.readFileSync(f, 'utf8')); } catch(e) {}
            j.skipDangerousModePermissionPrompt = true;
            fs.writeFileSync(f, JSON.stringify(j, null, 2));
'@
        docker exec $ContainerName node -e $dangerScript 2>$null
        docker exec $ContainerName bash -c "touch /home/agent/.dangerous-mode"
    }

    # 5. Rewrite Windows plugin paths to Linux paths
    $pluginScript = @'
        const f = '/home/agent/.claude/plugins/installed_plugins.json';
        const fs = require('fs');
        if (!fs.existsSync(f)) process.exit(0);
        let d = fs.readFileSync(f, 'utf8');
        d = d.replace(/C:\\Users\\[^\\"]+\\.claude\\/g, '/home/agent/.claude/');
        d = d.replace(/\\/g, '/');
        fs.writeFileSync(f, d);
'@
    docker exec $ContainerName node -e $pluginScript 2>$null

    # 6. Set up bash alias for dangerous mode
    docker exec $ContainerName bash -c `
        'echo "if [ -f /home/agent/.dangerous-mode ]; then alias claude=\"claude --dangerously-skip-permissions\"; fi" >> /home/agent/.bashrc'

    # 7. Prefill shell history with common claude commands
    $historyContent = @'
claude
claude --dangerously-skip-permissions
claude --headless
claude --dangerously-skip-permissions --headless
claude --resume
claude --continue
'@
    docker exec $ContainerName bash -c "cat > /home/agent/.bash_history << 'HISTORY'`n$historyContent`nHISTORY"
}

# Invoke-ProviderConnect
#
# Called when the user runs `sandbox shell`. Attaches an interactive bash
# session. Prints mode information first if running in dangerous mode.
#
function Invoke-ProviderConnect {
    param(
        [Parameter(Mandatory)][string]$ContainerName
    )
    $dangerCheck = docker exec $ContainerName bash -c "test -f /home/agent/.dangerous-mode && echo true || echo false" 2>$null
    if ($dangerCheck -eq 'true') {
        Write-Host "  Mode: DANGEROUS (skip permissions)"
        Write-Host "  Run 'claude' to start Claude Code with --dangerously-skip-permissions"
    }
    docker exec -it $ContainerName bash
}

# Invoke-ProviderHealthcheck
#
# Verifies Claude Code CLI is installed and functional. Throws on failure.
#
function Invoke-ProviderHealthcheck {
    param(
        [Parameter(Mandatory)][string]$ContainerName
    )
    $output = docker exec $ContainerName claude --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Claude Code healthcheck failed in container $ContainerName"
    }
}

# ------------------------------------------------------------------------------
# OPTIONAL HOOKS
# ------------------------------------------------------------------------------

# Invoke-ProviderEnv
#
# Injects ANTHROPIC_API_KEY into the container environment.
#
function Invoke-ProviderEnv {
    $key = if ($env:ANTHROPIC_API_KEY) { $env:ANTHROPIC_API_KEY } else { "" }
    Write-Output "ANTHROPIC_API_KEY=$key"
}

# Invoke-ProviderMounts
#
# Mounts the host ~/.claude directory read-only as .claude-host for config
# seeding, and ~/.claude.json for project-level settings.
#
function Invoke-ProviderMounts {
    $claudeConfig = if ($env:SANDBOX_CLAUDE_CONFIG) {
        $env:SANDBOX_CLAUDE_CONFIG
    } else {
        "$env:USERPROFILE\.claude"
    }
    # Normalize Windows paths to Docker-compatible forward slashes
    $claudeConfig = $claudeConfig -replace '\\', '/'
    $home = $env:USERPROFILE -replace '\\', '/'
    Write-Output "${claudeConfig}:/home/agent/.claude-host:ro"
    Write-Output "${home}/.claude.json:/home/agent/.claude.json"
}

# Invoke-ProviderHeadless
#
# Called when the user runs `sandbox headless`. Starts Claude Code in headless
# mode for remote control via claude.ai.
#
function Invoke-ProviderHeadless {
    param(
        [Parameter(Mandatory)][string]$ContainerName
    )
    $dangerCheck = docker exec $ContainerName bash -c "test -f /home/agent/.dangerous-mode && echo true || echo false" 2>$null
    if ($dangerCheck -eq 'true') {
        Write-Host "Starting Claude Code in headless mode (DANGEROUS)..."
        Write-Host "Connect via claude.ai remote control."
        Write-Host ""
        docker exec -it $ContainerName claude --dangerously-skip-permissions --headless
    } else {
        Write-Host "Starting Claude Code in headless mode..."
        Write-Host "Connect via claude.ai remote control."
        Write-Host ""
        docker exec -it $ContainerName claude --headless
    }
}
