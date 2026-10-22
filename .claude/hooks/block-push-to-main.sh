#!/usr/bin/env bash
# PreToolUse hook on Bash — blocks `git push` targeting main.
# Rationale: CLAUDE.md regola 1. All changes go through a PR; merging is the
# user's prerogative. Tag pushes (vX.Y.Z) are allowed because they don't
# reference main.

set -euo pipefail

cmd=$(jq -r '.tool_input.command // ""')

# Strip leading "cd <dir> && " noise so the regex sees the actual git command.
normalized=$(printf '%s' "$cmd" | tr -s ' ')

# Catch any refspec whose destination is `main`. The previous regex only
# matched `main` after a literal space, leaving the following bypasses:
#   - `develop:main` (push develop commits to main)
#   - `:main` (delete remote main)
#   - `+main` / `--force-with-lease … main` (force-update main)
#   - `refs/heads/main` (explicit refspec)
# Boundary `([[:space:]:+]|^)` admits space, `:`, `+`, or line start before
# the destination. `refs/heads/main` is included explicitly because `/`
# is not in the boundary class.
# Global git options between `git` and `push` (`-C <dir>`, `-c k=v`,
# `--git-dir=…`) are admitted by the optional `(-opt [arg])*` group:
# requiring `git push` adjacency let `git -C /repo push origin main`
# through (bypass found 2026-07-02).
GIT_PUSH='git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+push'

blocked=""
if printf '%s' "$normalized" | grep -qE "${GIT_PUSH}.*([[:space:]:+]|^)(main|HEAD:main|refs/heads/main)([[:space:]]|\$)"; then
  blocked="refspec"
fi

# `--all` e `--mirror` spediscono OGNI branch locale (main compreso) senza mai
# nominarlo, quindi la regex sul refspec non li vede — e `--mirror` puo' anche
# cancellare ref remoti. Il match e' ancorato a un comando `push` per non
# toccare `git fetch --all`, `git log --all`, `git branch --all`
# (bypass trovato 2026-08-03).
if printf '%s' "$normalized" | grep -qE "${GIT_PUSH}([[:space:]].*)?[[:space:]](--all|--mirror)([[:space:]]|=|\$)"; then
  blocked="broadcast"
fi

if [ -n "$blocked" ]; then
  echo "Blocked by .claude/hooks/block-push-to-main.sh:" >&2
  if [ "$blocked" = "broadcast" ]; then
    echo "  \`git push --all/--mirror\` spedisce tutti i branch locali, main incluso" >&2
    echo "  (CLAUDE.md regola 1). Spingi esplicitamente il tuo branch:" >&2
    echo "  git push -u origin <branch-name>" >&2
  else
    echo "  Direct push to main is forbidden (CLAUDE.md regola 1). Always go through a PR." >&2
  fi
  echo "  If this is intentional (release tag, hotfix authorized by the user), bypass via" >&2
  echo "  a manual shell outside Claude, or temporarily disable this hook." >&2
  exit 2
fi

exit 0
