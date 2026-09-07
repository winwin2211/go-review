#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

home=$(tmpdir)
mkdir -p "$home/skills" "$home/agents"

CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" >/dev/null
assert_link "$home/skills/go-review" "skill symlink created"
assert_eq "$REPO_ROOT/skill" "$(readlink "$home/skills/go-review")" "skill symlink target"
for a in correctness security architecture performance sdd-tdd verifier; do
  assert_link "$home/agents/go-review-$a.md" "agent symlink $a"
done

# idempotent
CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" >/dev/null
assert_link "$home/skills/go-review" "skill symlink survives reinstall"

CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" --uninstall >/dev/null
[[ -e "$home/skills/go-review" ]] && fail "skill symlink removed" || pass
[[ -e "$home/agents/go-review-verifier.md" ]] && fail "agent symlink removed" || pass

# unknown arguments are rejected, not silently treated as "install"
assert_exit 1 env CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" uninstall
[[ -e "$home/skills/go-review" ]] && fail "bare 'uninstall' arg must not install" || pass

finish
