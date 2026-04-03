# Agent Sandbox — Developer Guide

Agent Sandbox is a provider-agnostic Docker sandbox for running AI coding agents in isolated containers. It supports multiple agent providers (Claude Code, Codex, etc.) through a plugin system.

## Key Files

| File | Purpose |
|------|---------|
| `sandbox.sh` | Main launcher (Bash). Commands: start, stop, list, logs, shell, headless, diff, repair |
| `sandbox.ps1` | PowerShell wrapper — delegates to `sandbox.sh` via Git Bash |
| `docker-compose.base.yml` | Claude container template, parameterized via env vars |
| `providers/` | Provider plugins — one subdirectory per agent type |
| `images/` | Dockerfiles: `base/`, `proxy/`, `dind/`, `profiles/` |
| `skills/` | Bundled Claude Code skills shipped into containers |
| `.sandbox.env` | Local secrets/config (gitignored) |
| `.sandbox.env.example` | Template for `.sandbox.env` |

## Naming Conventions

- Container user: `agent`
- Image tags: `agent-sandbox:<profile>`
- Container names: `sandbox-<project>-<session>-agent`
- Network names: `sandbox-<project>-<session>-net`
- Volume names: `sandbox-<project>-<session>_<volume>`
- Worktree dirs: `$SANDBOX_WORKTREE_DIR/<project>--<session>`
- Env var prefix: `SANDBOX_`

## Provider System

Each provider lives under `providers/<name>/` and implements:

| File | Required | Purpose |
|------|----------|---------|
| `provider.sh` | Yes | Bash hooks (see below) |
| `provider.ps1` | Yes | PowerShell equivalents of all hooks |
| `provider.conf` | Yes | Metadata: name, image, default profile, env vars |

Hooks in `provider.sh`:
- `provider_build_args` — echo extra `docker build` args
- `provider_env_vars` — echo `KEY=VALUE` lines to inject into the container
- `provider_start_pre` / `provider_start_post` — lifecycle hooks
- `provider_container_cmd` — echo the command to run inside the container

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
