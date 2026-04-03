# Claude Code Provider

Reference provider implementation for [Anthropic Claude Code](https://claude.ai/code) — an AI coding agent that operates autonomously inside the sandbox container.

## What is Claude Code?

Claude Code is Anthropic's AI-powered coding CLI. Inside the sandbox it runs as the `claude` command and can read/write files, run tests, execute shell commands, and iterate on code with full access to the workspace. The provider handles installing the CLI, seeding configuration, and wiring up auth credentials at runtime.

## Prerequisites

An Anthropic API key is required. The launcher will refuse to start if `ANTHROPIC_API_KEY` is not set.

1. Get an API key at [console.anthropic.com](https://console.anthropic.com)
2. Add it to `.sandbox.env` in the agent-sandbox root:

```ini
ANTHROPIC_API_KEY=sk-ant-...
```

## Usage

Claude Code is the default provider. No `--provider` flag is needed unless overriding.

### Start a session

```bash
# Basic start (creates worktree, builds image if needed, starts container)
sandbox.sh start myproject session1

# Explicit provider (equivalent — claude-code is the default)
sandbox.sh start myproject session1 --provider claude-code

# With a specific base image profile
sandbox.sh start myproject session1 --profile java

# With Docker-in-Docker for Testcontainers
sandbox.sh start myproject session1 --docker
```

### Connect and run Claude Code

```bash
# Open an interactive shell in the container
sandbox.sh shell myproject session1
# Then inside the container:
claude
```

### Headless / remote mode

Headless mode starts Claude Code connected to the claude.ai remote control interface. You can then drive the session from claude.ai on any device.

```bash
sandbox.sh headless myproject session1
# Follow the URL printed to connect remotely
```

### Dangerous mode

Dangerous mode skips Claude Code's interactive permission prompts. Use when you trust the task and want fully autonomous operation.

```bash
sandbox.sh start myproject session1 --dangerous
```

Inside the container, the `claude` alias automatically includes `--dangerously-skip-permissions`. You can also run:

```bash
claude --dangerously-skip-permissions
```

### Stop a session

```bash
# Stop containers (preserves worktree and volumes for fast restart)
sandbox.sh stop myproject session1

# Full cleanup — removes containers, volumes, worktree, and branch
sandbox.sh stop myproject session1 --clean
```

## Version Pinning

By default the latest Claude Code CLI release is installed. To pin a version, set the `AGENT_VERSION` build argument or environment variable:

```bash
# In .sandbox.env
AGENT_VERSION=1.2.3
```

The launcher passes this as a build arg when building the provider layer on top of the base image. You can also force a rebuild with a specific version:

```bash
sandbox.sh update  # rebuilds all images with latest
```

Valid values are any version tag published to the Claude Code install channel, or `latest` (default).

## How the Provider Works

The claude-code provider implements all standard lifecycle hooks:

| Hook | What it does |
|------|-------------|
| `provider_setup` | Emits Dockerfile lines to install Claude Code via the official install script |
| `provider_env` | Injects `ANTHROPIC_API_KEY` into the container |
| `provider_mounts` | Mounts `~/.claude` read-only as `.claude-host` and `~/.claude.json` for settings |
| `provider_start` | Seeds config, refreshes credentials, accepts workspace trust, sets up aliases |
| `provider_connect` | Opens an interactive bash shell (prints mode info if dangerous) |
| `provider_headless` | Runs `claude --headless` (or with `--dangerously-skip-permissions`) |
| `provider_healthcheck` | Runs `claude --version` to confirm the CLI is installed and reachable |

### Config seeding

Host `~/.claude` is mounted read-only inside the container at `/home/agent/.claude-host`. On every `start`, the provider copies it into the writable session-local config volume (`/home/agent/.claude`). Auth credentials are refreshed on every start so OAuth tokens stay current.

Changes made inside the container to Claude Code settings persist in the session volume but do not write back to the host. Use `stop --clean` and restart to reseed from the host.

### Windows plugin path rewriting

If the host `~/.claude` contains plugin paths with Windows backslashes (e.g. `C:\Users\...\claude\`), the provider automatically rewrites them to Linux paths on start so plugins load correctly inside the container.
