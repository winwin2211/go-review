#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
A="$REPO_ROOT/agents"
for a in correctness security architecture performance sdd-tdd verifier; do
  f="$A/go-review-$a.md"
  assert_file "$f" "agent file $a"
  grep -q "^name: go-review-$a\$" "$f" && pass || fail "$a name"
  grep -q '^tools: Read, Grep, Glob, Bash$' "$f" && pass || fail "$a tools are read-only set"
  grep -q '^model: inherit$' "$f" && pass || fail "$a model inherit"
  grep -q 'placeholder' "$f" && fail "$a still placeholder" || pass
  grep -qi 'do not write' "$f" && pass || fail "$a states read-only contract"
  grep -q 'go mod tidy' "$f" && pass || fail "$a forbids go mod tidy"
  grep -q 'JSON array' "$f" && pass || fail "$a returns JSON array"
  if [[ "$a" != "verifier" ]]; then
    grep -q "checklist-$a.md" "$f" && pass || fail "$a reads its checklist"
  else
    grep -q 'Verifier rubric' "$f" && pass || fail "verifier reads rubric"
  fi
done
finish
