# Skills

Skills are Claude Code automation scripts that extend the AI assistant with reusable, named workflows. When you invoke a skill (e.g., `/sandbox-execute`), Claude Code reads the corresponding `SKILL.md` and follows the instructions as if they were inline prompts — automating multi-step tasks that would otherwise require manual coordination.

## Available Skills

| Skill | Purpose |
|-------|---------|
| `sandbox-execute` | Launch a sandbox session to execute an implementation plan |
| `sandbox-merge` | Merge a completed sandbox session branch and clean up resources |

These two skills automate the full sandbox lifecycle: spin up an isolated container with an AI agent working on a plan, then merge the results back when done.

## Installation

Copy the skill directories into your Claude Code skills folder:

```
~/.claude/skills/sandbox-execute/
~/.claude/skills/sandbox-merge/
```

On Windows (Git Bash):
```bash
cp -r skills/sandbox-execute ~/.claude/skills/
cp -r skills/sandbox-merge ~/.claude/skills/
```

On Linux/macOS:
```bash
cp -r skills/sandbox-execute ~/.claude/skills/
cp -r skills/sandbox-merge ~/.claude/skills/
```

## Configuration

The skills reference your agent-sandbox installation via the `AGENT_SANDBOX_HOME` environment variable. Set it to the directory where you cloned this repo:

```bash
# In ~/.bashrc, ~/.zshrc, or your shell profile
export AGENT_SANDBOX_HOME="$HOME/agent-sandbox"
```

On Windows, set it as a user environment variable or add it to your PowerShell profile:
```powershell
$env:AGENT_SANDBOX_HOME = "C:\Dev\agent-sandbox"
```

If you prefer not to use the env var, edit the path references in each `SKILL.md` directly.

## Usage

From inside a project directory:

```
/sandbox-execute                    # find the most recent plan and launch
/sandbox-execute docs/plans/my-plan.md   # launch with a specific plan
/sandbox-merge                      # merge the completed session
/sandbox-merge myproject my-session # merge a specific session
```

## Note: Claude Code Only

These skills use Claude Code's skill system (`SKILL.md` files read by the Claude Code CLI). Other AI agent providers may have their own automation systems — these files are specific to Claude Code and will not work with other agents out of the box.

For agent-sandbox itself (the sandbox launcher), all providers are supported via the `--provider` flag. The skills here are a convenience layer on top for Claude Code users.
