# provider.ps1 — Hook implementations for the example provider (PowerShell)
#
# Copy this file to providers/provider.<name>/provider.ps1 and implement
# each hook function. The launcher dot-sources this file on Windows and calls
# these functions at the appropriate lifecycle points.
#
# All hooks must be defined even if they are no-ops (see stubs below).
# Optional hooks may be omitted — the launcher checks with Get-Command before
# calling them.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------------------
# REQUIRED HOOKS
# ------------------------------------------------------------------------------

# Invoke-ProviderSetup
#
# Called at image build time. Outputs Dockerfile RUN/COPY/ENV instructions
# that install and configure the agent inside the container image.
#
# Parameters:
#   ImageTag  — the Docker image tag being built (e.g. "agent-sandbox:base")
#
# Output:
#   Lines of valid Dockerfile syntax written to the pipeline. The launcher
#   appends these to the generated Dockerfile after the base image layers.
#
# A real implementation would write something like:
#   "RUN npm install -g my-agent-cli@1.2.3"
#   "ENV MY_AGENT_HOME=/opt/my-agent"
#
function Invoke-ProviderSetup {
  param(
    [Parameter(Mandatory)][string]$ImageTag
  )
  # Stub — emit a no-op comment so the Dockerfile remains valid
  Write-Output "# example provider: no additional setup required"
}

# Invoke-ProviderStart
#
# Called once after the container has started and is healthy, before handing
# control to the user. Use this for agent-specific runtime initialization that
# cannot be baked into the image (e.g. seeding config from env vars, writing
# auth tokens that must not be stored in the image layer).
#
# Parameters:
#   ContainerName  — the running Docker container name
#
# A real implementation might run:
#   docker exec $ContainerName sh -c "my-agent auth login --token $env:MY_AGENT_TOKEN"
#
function Invoke-ProviderStart {
  param(
    [Parameter(Mandatory)][string]$ContainerName
  )
  # Stub — nothing to initialize
}

# Invoke-ProviderConnect
#
# Called when the user runs `sandbox shell`. Attaches an interactive session
# to the running container. Should block until the session ends so that exit
# codes propagate correctly.
#
# Parameters:
#   ContainerName  — the running Docker container name
#
# A real implementation would exec the agent's interactive CLI, e.g.:
#   docker exec -it $ContainerName my-agent
#
function Invoke-ProviderConnect {
  param(
    [Parameter(Mandatory)][string]$ContainerName
  )
  # Stub — open a plain bash shell
  docker exec -it $ContainerName bash
}

# Invoke-ProviderHealthcheck
#
# Called periodically (and after Invoke-ProviderStart) to verify the agent
# process is running and ready. Must exit 0 ($LASTEXITCODE 0) if healthy,
# throw or set $LASTEXITCODE non-zero otherwise.
#
# Parameters:
#   ContainerName  — the running Docker container name
#
# A real implementation might check a pid file or query a local status socket:
#   docker exec $ContainerName my-agent status --quiet
#
function Invoke-ProviderHealthcheck {
  param(
    [Parameter(Mandatory)][string]$ContainerName
  )
  # Stub — container existence is sufficient for the example
  $state = docker inspect --format '{{.State.Running}}' $ContainerName
  if ($state -ne 'true') {
    throw "Container $ContainerName is not running"
  }
}

# ------------------------------------------------------------------------------
# OPTIONAL HOOKS
# ------------------------------------------------------------------------------

# Invoke-ProviderEnv
#
# Outputs additional KEY=VALUE environment variable lines to the pipeline.
# These are injected into the container at startup alongside the base sandbox
# variables.
#
# No parameters.
#
# A real implementation might write:
#   "MY_AGENT_LOG_LEVEL=info"
#   "MY_AGENT_TELEMETRY=false"
#
# Omit this function entirely to inject no extra variables.
#
function Invoke-ProviderEnv {
  # Stub — no extra environment variables
}

# Invoke-ProviderMounts
#
# Outputs additional volume mount strings to the pipeline, one per line, in
# the form:
#   source:destination:mode
#
# where source is a host path or named volume, destination is the container
# path, and mode is "ro" or "rw".
#
# No parameters.
#
# A real implementation might mount a shared cache or credentials directory:
#   "$env:USERPROFILE\.config\my-agent\credentials:/home/agent/.config/my-agent/credentials:ro"
#
# Omit this function entirely to add no extra mounts.
#
function Invoke-ProviderMounts {
  # Stub — no extra mounts
}

# Invoke-ProviderHeadless
#
# Called when the user runs `sandbox headless`. Starts the agent in a
# non-interactive (background/remote) mode, if the agent supports it.
# Should print connection instructions to the host after starting.
#
# Parameters:
#   ContainerName  — the running Docker container name
#
# A real implementation might start a web UI or print a remote URL:
#   docker exec -d $ContainerName my-agent serve --port 8080
#   Write-Host "Connect at http://localhost:$HostPort"
#
# Omit this function to disable headless mode for this provider (the launcher
# will show a "not supported" error automatically).
#
function Invoke-ProviderHeadless {
  param(
    [Parameter(Mandatory)][string]$ContainerName
  )
  Write-Error "headless mode is not supported by the example provider"
}
