#!/usr/bin/env bash
# Tests subagent-stop.sh token extraction with a fixture transcript.
set -euo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/subagent-stop.sh"
FIXTURES="$(cd "$(dirname "$0")" && pwd)/fixtures"
SIGNAL_BASE="$HOME/.claude/darwin-state"
WORKTREE_BASE="$HOME/.claude/darwin-worktrees"

fail() { echo "FAIL: $1" >&2; exit 1; }

REPO_HASH="testhash-tokentest"
TASK_SLUG="token-test"
CWD="$WORKTREE_BASE/$REPO_HASH/$TASK_SLUG"
SIGNAL_DIR="$SIGNAL_BASE/$REPO_HASH/$TASK_SLUG"

cleanup() { rm -rf "$SIGNAL_BASE/$REPO_HASH" "$WORKTREE_BASE/$REPO_HASH"; }
trap cleanup EXIT

mkdir -p "$CWD"

printf '%s' "$(jq -n \
  --arg cwd "$CWD" \
  --arg transcript "$FIXTURES/transcript-sample.jsonl" \
  '{cwd: $cwd, transcript_path: $transcript}')" \
  | bash "$HOOK" 2>/dev/null || fail "hook exited non-zero"

[ -f "$SIGNAL_DIR/signal.json" ] || fail "signal.json not written"

INPUT_TOK=$(jq '.agent_tokens.input'   "$SIGNAL_DIR/signal.json")
OUTPUT_TOK=$(jq '.agent_tokens.output'  "$SIGNAL_DIR/signal.json")
THINK_TOK=$(jq '.agent_tokens.thinking' "$SIGNAL_DIR/signal.json")

[ "$INPUT_TOK"  -eq 370 ] || fail "input tokens: expected 370, got $INPUT_TOK"
[ "$OUTPUT_TOK" -eq 120 ] || fail "output tokens: expected 120, got $OUTPUT_TOK"
[ "$THINK_TOK"  -eq 15  ] || fail "thinking tokens: expected 15, got $THINK_TOK"

echo "PASS  token extraction: input=$INPUT_TOK output=$OUTPUT_TOK thinking=$THINK_TOK"
