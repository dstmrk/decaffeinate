#!/usr/bin/env bash
# Tests for .claude/hooks/block-push-to-main.sh
#
# Runs the hook with synthetic Bash tool invocations and asserts the
# expected exit code (2 = block, 0 = pass). Run from repo root:
#   ./.claude/hooks/test-block-push-to-main.sh
#
# This is a defense-in-depth net for CLAUDE.md regola 1: a regex that
# fails to block `develop:main`, `:main`, `+main`, force-push refspec
# or `refs/heads/main` would defeat the whole purpose of the hook.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
HOOK="$SCRIPT_DIR/block-push-to-main.sh"

if [ ! -x "$HOOK" ]; then
  echo "FAIL: hook not executable: $HOOK" >&2
  exit 1
fi

failures=0

# Run the hook in a subshell with the given fake Bash command on stdin.
# Returns the hook's exit code via the global $rc. We can't use `local`
# at the top level so we use a global.
run_hook() {
  local cmd="$1"
  local payload
  payload=$(printf '%s' "$cmd" | python3 -c '
import json, sys
print(json.dumps({"tool_input": {"command": sys.stdin.read()}}))')
  printf '%s' "$payload" | bash "$HOOK" >/dev/null 2>&1
  rc=$?
}

assert_block() {
  local cmd="$1"
  run_hook "$cmd"
  if [ "$rc" -ne 2 ]; then
    echo "FAIL: expected BLOCK (exit 2) but got exit $rc for: $cmd" >&2
    failures=$((failures + 1))
  fi
}

assert_pass() {
  local cmd="$1"
  run_hook "$cmd"
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: expected PASS (exit 0) but got exit $rc for: $cmd" >&2
    failures=$((failures + 1))
  fi
}

# --- PASS cases: legitimate operations that must not be blocked ---
assert_pass "git push origin feature"
assert_pass "git push origin develop"
assert_pass "git push origin HEAD:feature"
assert_pass "git push -u origin claude/code-review-findings-zrLLU"
assert_pass "git tag v1.3.3"
assert_pass "git push origin maintenance"
assert_pass "git push origin domain"
assert_pass "git push origin feature/main-fix"
assert_pass "git status"
assert_pass "git fetch origin main"
assert_pass "git -C /repo push origin feature"
assert_pass "git -C /repo fetch origin main"
assert_pass "git -c protocol.version=2 push origin feature"

# --- BLOCK cases: any refspec whose destination is main ---
assert_block "git push origin main"
assert_block "git push origin HEAD:main"
assert_block "git push origin develop:main"
assert_block "git push origin :main"
assert_block "git push -f origin develop:main"
assert_block "git push --force origin develop:main"
assert_block "git push --force-with-lease origin main"
assert_block "git push origin +main"
assert_block "git push origin refs/heads/main"
assert_block "git push origin main:main"

# --- BLOCK cases: global git options between `git` and `push` (`-C <dir>`,
# `-c k=v`, `--git-dir=…`). A regex anchored on `git push` adjacency lets
# `git -C /repo push origin main` through (bypass found 2026-07-02). ---
assert_block "git -C /repo push origin main"
assert_block "git -C /repo push origin develop:main"
assert_block "git -c protocol.version=2 push origin main"
assert_block "git --git-dir=/repo/.git push origin HEAD:main"

# --- BLOCK cases: push che spediscono main SENZA nominarlo. `--all` e
# `--mirror` includono ogni branch locale, main compreso: una regex che cerca
# il token "main" nel refspec non li vede (bypass trovato 2026-08-03). ---
assert_block "git push --all origin"
assert_block "git push origin --all"
assert_block "git push --mirror origin"
assert_block "git push origin --mirror"
assert_block "git -C /repo push --all origin"

# `--all` su un comando che non e' un push non c'entra nulla.
assert_pass "git fetch --all"
assert_pass "git log --all --oneline"
assert_pass "git branch --all"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed." >&2
  exit 1
fi

echo "All block-push-to-main hook tests passed."
