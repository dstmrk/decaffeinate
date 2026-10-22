#!/usr/bin/env bash
# PreToolUse hook on Bash — blocks `git commit` while the current branch is main.
# Rationale: CLAUDE.md regola 1. block-push-to-main.sh alone leaves a dirty
# state: a commit created on main can't be pushed and has to be surgically
# moved to a branch afterwards. Blocking at commit time keeps main clean.

set -euo pipefail

cmd=$(jq -r '.tool_input.command // ""')

# Strip repeated whitespace so the regex sees the actual git command.
normalized=$(printf '%s' "$cmd" | tr -s ' ')

# Detect a `commit` git subcommand, tolerating global options between `git`
# and the subcommand (`-C <dir>`, `-c k=v`, `--git-dir=…`) — same pattern as
# block-push-to-main.sh (bypass class found 2026-07-02).
if printf '%s' "$normalized" | grep -qE 'git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+commit([[:space:]]|$)'; then
  # Empty output = detached HEAD (rebase, bisect) → not "on main", allow.
  branch=$(git branch --show-current 2>/dev/null || true)
  if [ "$branch" = "main" ]; then
    echo "Blocked by .claude/hooks/block-commit-on-main.sh:" >&2
    echo "  Committing directly on main is forbidden (CLAUDE.md regola 1)." >&2
    echo "  Create a feature branch first: git checkout -b <branch-name>" >&2
    exit 2
  fi
fi

exit 0
