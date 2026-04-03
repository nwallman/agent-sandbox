# Agent Sandbox

Run AI coding agents in isolated, reproducible Docker containers. ![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)

## What is this?

Agent Sandbox gives each AI coding session its own Docker container, git worktree, and network environment. Agents work on isolated branches with full tool access, and you merge or discard the results when done. Multiple sessions run in parallel without interfering with each other or with your main working copy.

The system is provider-agnostic: a small plugin in `providers/` teaches the launcher how to start and connect to a specific agent (Claude Code, Codex, Gemini CLI, or your own). Everything else — networking, isolation, profiles, worktrees — is shared infrastructure.

## Features

- **Provider plugins** — swap or add agent backends via a four-function hook interface
- **Worktree isolation** — every session gets its own git branch and working directory; no conflicts between parallel sessions
- **Network filtering** — outbound HTTP/HTTPS routed through Squid proxy with a domain allowlist; containers cannot reach the internet directly
- **Resource limits** — CPU, memory, and PID caps enforced at the container level
- **Build profiles** — base, java, node, and fullstack image variants; auto-detected from project files
- **Docker-in-Docker** — optional DinD sidecar for projects that use Testcontainers
- **Cross-platform** — `sandbox.sh` for Linux/macOS/Git Bash; `sandbox.ps1` wrapper for Windows PowerShell
- **Devcontainer support** — attach VS Code directly to any running sandbox container

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/agent-sandbox/agent-sandbox
cd agent-sandbox

# 2. Copy and fill in the env file
cp .sandbox.env.example .sandbox.env
# Edit .sandbox.env — set ANTHROPIC_API_KEY and SANDBOX_BASE_DIR at minimum

# 3. Start a sandbox for your project
./sandbox.sh start myproject my-session

# 4. Open a shell and run the agent
./sandbox.sh shell myproject my-session
```

On Windows, use `sandbox.ps1` instead:

```powershell
.\sandbox.ps1 start myproject my-session
.\sandbox.ps1 shell myproject my-session
```

## Requirements

- **Docker Desktop** (or Docker Engine on Linux)
- **Git** 2.28+
- **Bash** — Git Bash on Windows, system bash on Linux/macOS
- **PowerShell** 5.1+ (Windows only, for `sandbox.ps1`)
- **WSL2** (Windows only) — required by Docker Desktop; no additional configuration needed

## Configuration

### .sandbox.env

Copy `.sandbox.env.example` to `.sandbox.env` and set your values. This file is gitignored and must never be committed.

| Variable | Default | Description |
|----------|---------|-------------|
| `ANTHROPIC_API_KEY` | — | API key for Claude Code (required by the claude-code provider) |
| `SANDBOX_BASE_DIR` | Parent of agent-sandbox dir | Parent directory where projects live |
| `SANDBOX_WORKTREE_DIR` | `$SANDBOX_BASE_DIR/.worktrees` | Where git worktrees are created |
| `SANDBOX_PROVIDER` | `claude-code` | Default provider plugin |
| `SANDBOX_CPU_LIMIT` | `8` | CPU limit for containers |
| `SANDBOX_MEMORY_LIMIT` | `16g` | Memory limit for containers |
| `SANDBOX_PID_LIMIT` | `2048` | PID limit for containers |

### .sandbox.conf (per-project)

Checked into the project repo. Declares sandbox defaults so all team members get the same behavior without needing to pass flags every time.

```ini
# .sandbox.conf — lives in the project root
profile=java
docker=true
```

Supported keys: `docker`, `profile`, `dangerous`, `open-network`, `cpu-limit`, `memory-limit`, `pid-limit`. CLI flags override file values.

## Usage Reference

### start

```bash
sandbox.sh start <project> <session> [options]
```

Creates a git worktree at `$SANDBOX_WORKTREE_DIR/<project>--<session>`, builds the Docker image if needed, and starts the sandbox containers.

| Option | Description |
|--------|-------------|
| `--profile <name>` | Image profile: `base`, `java`, `node`, `fullstack` (auto-detected if omitted) |
| `--branch <name>` | Git branch name (defaults to session name; supports slashes) |
| `--provider <name>` | Agent provider plugin (default: `claude-code`) |
| `--env KEY=VAL` | Inject additional environment variable into the container |
| `--dangerous` | Skip agent permission prompts |
| `--read-only` | Mount workspace read-only (for review/analysis tasks) |
| `--open-network` | Bypass the proxy; allow unrestricted internet access |
| `--docker` | Start a Docker-in-Docker sidecar for Testcontainers |

### stop

```bash
sandbox.sh stop <project> <session> [--clean]
```

Stops the sandbox containers. `--clean` also removes Docker volumes, the git worktree, and the session branch (if fully merged).

### list

```bash
sandbox.sh list
```

Shows all running sandboxes with their project, session, profile, port mappings, and uptime.

### logs

```bash
sandbox.sh logs <project> <session> [service]
```

Tails logs for the sandbox. Omit `service` for the agent container; use `proxy` to see blocked network requests.

### shell

```bash
sandbox.sh shell <project> <session>
```

Opens an interactive shell in the agent container via the provider's `provider_connect` hook. For claude-code this drops you into the Claude Code CLI.

### headless

```bash
sandbox.sh headless <project> <session>
```

Starts the agent in headless/remote mode (provider-dependent). For claude-code, this connects via claude.ai.

### diff

```bash
sandbox.sh diff <project> <session> [--stat]
```

Shows all uncommitted changes in the sandbox worktree. `--stat` shows a summary instead of the full diff.

### merge

```bash
sandbox.sh merge <project> <session>
```

Stops the sandbox, restores the host git pointer, and merges the session branch into the project's current branch. Does not clean up volumes or worktree — run `stop --clean` afterward.

### repair

```bash
sandbox.sh repair <project> <session>
```

Fixes the `.git` file pointer in the worktree if the container crashed without a clean shutdown. Run this if `git` commands in the worktree directory fail with "not a git repository".

### update

```bash
sandbox.sh update
```

Rebuilds all sandbox images, pulling the latest base image and agent CLI version. Run this to pick up agent updates without changing any config.

## Providers

A provider is a plugin that teaches the sandbox how to launch a specific AI coding agent. The launcher calls a small set of hook functions at lifecycle points; the provider implements them in Bash (`.sh`) and PowerShell (`.ps1`).

### How it works

1. The sandbox reads `providers/<name>/provider.conf` for metadata and required env vars.
2. It sources `providers/<name>/provider.sh` and calls the hooks in order.
3. At image build time: `provider_setup` emits Dockerfile instructions to install the agent.
4. At container start: `provider_start` initializes runtime state (auth tokens, config seeding).
5. At `shell`: `provider_connect` attaches the interactive session.
6. At `headless`: `provider_headless` starts the agent in background/remote mode.

### Hook interface

| Hook | Required | Description |
|------|----------|-------------|
| `provider_setup <image_tag>` | Yes | Emits Dockerfile lines to stdout; installs the agent CLI |
| `provider_start <container>` | Yes | Called after container start; seeds runtime config |
| `provider_connect <container>` | Yes | Called by `shell`; must `exec` into the container |
| `provider_healthcheck <container>` | Yes | Exits 0 if the agent is healthy |
| `provider_env` | No | Prints `KEY=VALUE` lines to inject into the container |
| `provider_mounts` | No | Prints `source:dest:mode` volume lines |
| `provider_headless <container>` | No | Starts background/remote mode |

### Bundled providers

| Provider | Directory | Agent |
|----------|-----------|-------|
| `claude-code` | `providers/claude-code/` | Anthropic Claude Code CLI |

### Creating a provider

Use `providers/provider.example/` as a template:

```bash
cp -r providers/provider.example providers/my-agent
# Edit providers/my-agent/provider.conf — set name, description, required_env
# Edit providers/my-agent/provider.sh — implement the hooks
# Edit providers/my-agent/provider.ps1 — PowerShell equivalents
```

Start a sandbox with your new provider:
```bash
./sandbox.sh start myproject my-session --provider my-agent
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for full details.

## Profiles

Profiles are Docker image variants that extend the base image with language runtimes. The launcher auto-detects the right profile from project files, or you can specify one with `--profile`.

| Profile | Trigger files | Adds |
|---------|--------------|------|
| `base` | (default) | Debian bookworm-slim, Node 22, Git, common tools |
| `java` | `build.gradle`, `pom.xml` | JDK 21 (Temurin) |
| `node` | `package.json` | pnpm, Chromium (Puppeteer) |
| `fullstack` | both Java and Node files | JDK 21 + pnpm + Chromium |

Images are tagged `agent-sandbox:<profile>` and cached locally. Run `sandbox.sh update` to rebuild.

## Network Filtering

By default, all sandbox containers run on an internal Docker network with no direct internet access. A Squid proxy sidecar allows only domains in the whitelist.

### Whitelist format

One domain per line. Lines starting with `.` match all subdomains. `#` comments are ignored.

```
# Allow the Anthropic API
.anthropic.com

# Allow npm registry
registry.npmjs.org
```

### Whitelist files

- `network-whitelist.txt` in this repo — always loaded (package registries, docs, Anthropic API)
- `network-whitelist.txt` in the project root — merged if present (add project-specific domains)

### Viewing blocked requests

```bash
sandbox.sh logs myproject my-session proxy
```

### Bypass

```bash
sandbox.sh start myproject my-session --open-network
```

Disables the proxy and gives unrestricted internet access. Logged as a warning in `sessions.log`.

## Security

- **Resource limits** — containers capped at 8 CPU / 16 GB memory / 2048 PIDs by default; override via `.sandbox.env` or `.sandbox.conf`
- **Internal networks** — the sandbox network has `internal: true`; containers cannot reach the internet except through the Squid proxy
- **Env validation** — `--env` rejects dangerous variables (`PATH`, `NODE_OPTIONS`, `LD_PRELOAD`, `SANDBOX_*`, `COMPOSE_*`); `.sandbox.env` is validated as `KEY=VALUE` before sourcing
- **No Docker socket** — containers cannot manage other containers or the host daemon; the optional DinD sidecar runs an isolated daemon with no workspace mount or API key access
- **Config isolation** — host `~/.claude` is mounted read-only; each session gets a writable config volume seeded from the host on first start; changes after that are not propagated
- **Audit logging** — all start/stop events logged to `sessions.log` (gitignored)

## Skills (Claude Code)

The `skills/` directory contains Claude Code automation scripts for the full sandbox workflow.

### sandbox-execute

Finds an implementation plan in `docs/superpowers/plans/`, starts a sandbox, and launches the agent in a new terminal window to execute the plan automatically.

```
/sandbox-execute                          # use most recent plan
/sandbox-execute docs/plans/my-plan.md   # use specific plan
```

### sandbox-merge

Merges the completed session branch into the project and cleans up all resources.

```
/sandbox-merge                             # auto-detect running session
/sandbox-merge myproject my-session        # specify explicitly
```

### Installation

```bash
cp -r skills/sandbox-execute ~/.claude/skills/
cp -r skills/sandbox-merge ~/.claude/skills/
```

Set `AGENT_SANDBOX_HOME` to your agent-sandbox directory so the skills can find `sandbox.ps1`:

```powershell
$env:AGENT_SANDBOX_HOME = "C:\Dev\agent-sandbox"
```

See [skills/README.md](skills/README.md) for full details.

## Per-Project Setup

### App services (docker-compose.sandbox.yml)

Projects that need services (PostgreSQL, Redis, etc.) add a `docker-compose.sandbox.yml` in the project root. It must reference `sandbox-net` to share networking with the agent container.

```yaml
services:
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: myapp
      POSTGRES_USER: myapp
      POSTGRES_PASSWORD: myapp
    networks:
      - sandbox-net

networks:
  sandbox-net:   # declare without attributes — do not add internal: or name:
```

### Project defaults (.sandbox.conf)

```ini
# Checked into the project repo
profile=java
docker=true
memory-limit=8g
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on adding providers, profiles, and pull request requirements.

## License

MIT — see [LICENSE](LICENSE).
