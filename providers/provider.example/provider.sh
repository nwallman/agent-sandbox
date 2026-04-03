#!/usr/bin/env bash
# provider.sh — Hook implementations for the example provider
#
# Copy this file to providers/provider.<name>/provider.sh and implement
# each hook function. The launcher sources this file and calls these
# functions at the appropriate lifecycle points.
#
# All hooks must be defined even if they are no-ops (see stubs below).
# Optional hooks may be omitted — the launcher checks with `declare -f`
# before calling them.

set -euo pipefail

# ------------------------------------------------------------------------------
# REQUIRED HOOKS
# ------------------------------------------------------------------------------

# provider_setup <image_tag>
#
# Called at image build time. Outputs Dockerfile RUN/COPY/ENV instructions
# that install and configure the agent inside the container image.
#
# Args:
#   $1  image_tag — the Docker image tag being built (e.g. "agent-sandbox:base")
#
# Output:
#   Lines of valid Dockerfile syntax, written to stdout. The launcher appends
#   these to the generated Dockerfile after the base image layers.
#
# A real implementation would emit something like:
#   RUN npm install -g my-agent-cli@1.2.3
#   ENV MY_AGENT_HOME=/opt/my-agent
#   COPY --chown=agent:agent config/ /home/agent/.config/my-agent/
#
provider_setup() {
  local image_tag="${1:?image_tag required}"
  # Stub — emit a no-op comment so the Dockerfile remains valid
  echo "# example provider: no additional setup required"
}

# provider_start <container_name>
#
# Called once after the container has started and is healthy, before handing
# control to the user. Use this for agent-specific runtime initialization that
# cannot be baked into the image (e.g. seeding config from env vars, writing
# auth tokens that must not be stored in the image layer).
#
# Args:
#   $1  container_name — the running Docker container name
#
# A real implementation might run:
#   docker exec "$container_name" sh -c "my-agent auth login --token $MY_AGENT_TOKEN"
#
provider_start() {
  local container_name="${1:?container_name required}"
  # Stub — nothing to initialize
  :
}

# provider_connect <container_name>
#
# Called when the user runs `sandbox shell`. Attaches an interactive session
# to the running container. This function must exec (or otherwise replace the
# current process) so that exit codes and terminal signals propagate correctly.
#
# Args:
#   $1  container_name — the running Docker container name
#
# A real implementation would exec the agent's interactive CLI, e.g.:
#   exec docker exec -it "$container_name" my-agent
#
provider_connect() {
  local container_name="${1:?container_name required}"
  # Stub — open a plain bash shell
  exec docker exec -it "$container_name" bash
}

# provider_healthcheck <container_name>
#
# Called periodically (and after provider_start) to verify the agent process
# is running and ready. Must exit 0 if healthy, non-zero otherwise.
#
# Args:
#   $1  container_name — the running Docker container name
#
# A real implementation might check a pid file or query a local status socket:
#   docker exec "$container_name" my-agent status --quiet
#
provider_healthcheck() {
  local container_name="${1:?container_name required}"
  # Stub — container existence is sufficient for the example
  docker inspect --format '{{.State.Running}}' "$container_name" | grep -q '^true$'
}

# ------------------------------------------------------------------------------
# OPTIONAL HOOKS
# ------------------------------------------------------------------------------

# provider_env
#
# Prints additional KEY=VALUE environment variable lines to stdout. These are
# injected into the container at startup alongside the base sandbox variables.
#
# No args.
#
# A real implementation might emit:
#   MY_AGENT_LOG_LEVEL=info
#   MY_AGENT_TELEMETRY=false
#
# Omit this function entirely to inject no extra variables.
#
provider_env() {
  # Stub — no extra environment variables
  :
}

# provider_mounts
#
# Prints additional volume mount strings to stdout, one per line, in the form:
#   source:destination:mode
#
# where source is a host path or named volume, destination is the container
# path, and mode is "ro" or "rw".
#
# No args.
#
# A real implementation might mount a shared cache or credentials directory:
#   "${HOME}/.config/my-agent/credentials:/home/agent/.config/my-agent/credentials:ro"
#
# Omit this function entirely to add no extra mounts.
#
provider_mounts() {
  # Stub — no extra mounts
  :
}

# provider_headless <container_name>
#
# Called when the user runs `sandbox headless`. Starts the agent in a
# non-interactive (background/remote) mode, if the agent supports it.
# Should print connection instructions to stdout after starting.
#
# Args:
#   $1  container_name — the running Docker container name
#
# A real implementation might start a web UI or print a remote URL:
#   docker exec -d "$container_name" my-agent serve --port 8080
#   echo "Connect at http://localhost:${HOST_PORT}"
#
# Omit this function to disable headless mode for this provider (the launcher
# will show a "not supported" error automatically).
#
provider_headless() {
  local container_name="${1:?container_name required}"
  echo "error: headless mode is not supported by the example provider" >&2
  return 1
}
