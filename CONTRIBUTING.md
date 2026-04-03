# Contributing to Agent Sandbox

Thank you for your interest in contributing. This document covers the most common contribution paths.

## Adding a Provider

A provider is a plugin that teaches Agent Sandbox how to launch a specific AI coding agent (e.g., Claude Code, Codex, Gemini CLI).

1. Create a directory: `providers/<your-provider>/`
2. Add the required files:

   **`provider.conf`** — metadata in `KEY=value` format:
   ```ini
   name=my-provider
   image=my-provider-image
   default_profile=base
   ```

   **`provider.sh`** — Bash hook implementations:
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail

   provider_build_args() { :; }
   provider_env_vars() { echo "MY_PROVIDER_API_KEY=${MY_PROVIDER_API_KEY:-}"; }
   provider_start_pre() { :; }
   provider_start_post() { :; }
   provider_container_cmd() { echo "my-agent --workspace /workspace"; }
   ```

   **`provider.ps1`** — PowerShell equivalents of all hooks above.

3. If your provider needs a custom base image, add a Dockerfile under `images/` and reference it in `provider.conf`.
4. Update `network-whitelist.txt` if the provider needs additional outbound domains.
5. Open a PR with a brief description of the agent and any new env vars required.

## Adding a Profile

Profiles are Docker image variants that extend the base image with language runtimes or tools (e.g., Java, Node, fullstack).

1. Add a Dockerfile at `images/profiles/<profile-name>.Dockerfile`.
2. The file must start with `FROM agent-sandbox:base`.
3. Install only what the profile needs — keep images lean.
4. Test with:
   ```bash
   sandbox.sh start <project> <session> --profile <profile-name>
   ```
5. Document the profile in the main README.

## Pull Request Guidelines

- Keep PRs focused — one feature or fix per PR.
- All shell scripts must start with `set -euo pipefail`.
- Every `.sh` file must have a matching `.ps1` file. Both must be functionally equivalent.
- No hardcoded provider names or API keys in core scripts (`sandbox.sh`, `docker-compose.base.yml`).
- New env vars must use the `SANDBOX_` prefix and be documented in `.sandbox.env.example`.
- Test your changes manually using `sandbox.sh start/stop/shell` before submitting.

## Code Style

- Bash: `set -euo pipefail`, 2-space indent, double-quote all variable expansions.
- PowerShell: `Set-StrictMode -Version Latest`, 4-space indent, use approved verbs for functions.
- Keep scripts cross-platform: avoid Unix-only tools (`jq`, `brew`, `xdg-open`) in `.ps1` files; avoid Windows-only assumptions in `.sh` files.
- Comments for non-obvious logic; no inline comments restating what the code does.

## Cross-Platform Requirement

Every user-facing feature must work on both Windows (PowerShell + Git Bash) and Linux/macOS (Bash). If a platform gap is unavoidable, document it clearly in the PR.
