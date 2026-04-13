# Agent Sandbox — Developer Guide

Agent Sandbox is a provider-agnostic Docker sandbox for running AI coding agents in isolated containers. It supports multiple agent providers (Claude Code, Codex, etc.) through a plugin system.

## Key Files

| File | Purpose |
|------|---------|
| `sandbox.sh` | Main launcher (Bash). Commands: start, stop, list, logs, shell, headless, diff, repair, pool (start/stop/status/assign/accept/reject/cancel/list) |
| `sandbox.ps1` | PowerShell wrapper — delegates to `sandbox.sh` via Git Bash |
| `docker-compose.base.yml` | Agent container template, parameterized via env vars |
| `providers/` | Provider plugins — one subdirectory per agent type |
| `images/` | Dockerfiles: `base/`, `proxy/`, `dind/`, `profiles/` |
| `skills/` | Bundled Claude Code skills shipped into containers |
| `<project>/.pool/` | Pool state directory (gitignored) — state files per pool sandbox |
| `skills/sandbox-pool/` | Pool lifecycle management skill |
| `skills/sandbox-accept/` | Review and merge pool sandbox work |
| `.sandbox.env` | Local secrets/config (gitignored) |
| `.sandbox.env.example` | Template for `.sandbox.env` |

## Naming Conventions

- Container user: `agent`
- Image tags: `agent-sandbox:<profile>`
- Container names: `sandbox-<project>-<session>-agent`
- Network names: `sandbox-<project>-<session>-net`
- Volume names: `sandbox-<project>-<session>_<volume>`
- Worktree dirs: `$SANDBOX_BASE_DIR/<project>/.worktrees/<project>--<session>`
- Env var prefix: `SANDBOX_`
- Pool session names: `pool-1`, `pool-2`, etc.
- Pool state dir: `$SANDBOX_BASE_DIR/<project>/.pool/`
- Pool state files: `<session>.state`, `<session>.plan`, `<session>.branch`, `<session>.provider`, `<session>.watcher-pid`

## Provider System

Each provider lives under `providers/<name>/` and implements:

| File | Required | Purpose |
|------|----------|---------|
| `provider.sh` | Yes | Bash hooks (see below) |
| `provider.ps1` | Yes | PowerShell equivalents of all hooks |
| `provider.conf` | Yes | Metadata: name, image, default profile, env vars |

Hooks in `provider.sh`:
- `provider_setup` — echo Dockerfile lines to install the agent (build-time)
- `provider_start` — post-launch initialization (args: container_name, dangerous)
- `provider_connect` — attach interactive session (args: container_name)
- `provider_healthcheck` — return 0 if healthy (args: container_name)
- `provider_env` (optional) — echo KEY=VALUE lines for extra env vars
- `provider_mounts` (optional) — echo volume mount strings (source:dest:mode)
- `provider_headless` (optional) — start non-interactive mode (args: container_name)

Core scripts must not hardcode any provider name. Always delegate to hooks.

## Development Rules

- All shell scripts must start with `set -euo pipefail`
- Every `.sh` script must have a `.ps1` counterpart
- No hardcoded provider references in `sandbox.sh` or `docker-compose.base.yml`
- New Docker images go under `images/`; profiles extend `agent-sandbox:base`
- Keep `.sandbox.env` out of commits — it is gitignored

## Testing

Manual testing via the launcher:

```bash
sandbox.sh start <project> <session> [--profile <name>] [--provider <name>]
sandbox.sh shell <project> <session>
sandbox.sh stop <project> <session> --clean
```

There is no automated test suite yet. Contributions welcome.
