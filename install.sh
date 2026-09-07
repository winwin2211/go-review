#!/usr/bin/env bash
# Symlink the go-review skill and agents into a Claude Code home.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
CLAUDE_HOME=${CLAUDE_HOME:-$HOME/.claude}
AGENTS="correctness security architecture performance sdd-tdd verifier"

die() { echo "install.sh: $*" >&2; exit 1; }
usage() { die "usage: install.sh [--uninstall]"; }

link() { # target linkpath
  if [[ -L "$2" ]]; then rm "$2"; elif [[ -e "$2" ]]; then
    echo "refusing to replace non-symlink: $2" >&2; exit 1; fi
  ln -s "$1" "$2"
  echo "linked $2 -> $1"
}

unlink_if_ours() { # linkpath
  [[ -L "$1" ]] && rm "$1" && echo "removed $1" || true
}

case "${1:-}" in
  "") ;;
  --uninstall)
    unlink_if_ours "$CLAUDE_HOME/skills/go-review"
    for a in $AGENTS; do unlink_if_ours "$CLAUDE_HOME/agents/go-review-$a.md"; done
    exit 0
    ;;
  *) usage ;;
esac

mkdir -p "$CLAUDE_HOME/skills" "$CLAUDE_HOME/agents"
link "$ROOT/skill" "$CLAUDE_HOME/skills/go-review"
for a in $AGENTS; do
  [[ -f "$ROOT/agents/go-review-$a.md" ]] || die "missing agents/go-review-$a.md; install is incomplete"
  link "$ROOT/agents/go-review-$a.md" "$CLAUDE_HOME/agents/go-review-$a.md"
done
