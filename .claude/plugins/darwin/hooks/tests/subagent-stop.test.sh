#!/usr/bin/env bash
# .claude/plugins/darwin/hooks/tests/subagent-stop.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/subagent-stop.sh"
WORKTREE_BASE="$HOME/.claude/darwin-worktrees"
SIGNAL_BASE="$HOME/.claude/darwin-state"
TEST_REPO="testrepo123"
TEST_SLUG="auth-rs256"

# ── Setup ──────────────────────────────────────────────────────────────────
WORKTREE_PATH="$WORKTREE_BASE/$TEST_REPO/$TEST_SLUG"
TRANSCRIPT_FILE="$(mktemp /tmp/transcript-XXXXX.jsonl)"
SIGNAL_PATH="$SIGNAL_BASE/$TEST_REPO/$TEST_SLUG/signal.json"

cleanup() {
  rm -f "$TRANSCRIPT_FILE"
  rm -rf "$SIGNAL_BASE/$TEST_REPO" "$WORKTREE_BASE/$TEST_REPO"
}
trap cleanup EXIT

mkdir -p "$WORKTREE_PATH"

# Write a mock transcript with three API turns carrying usage
cat > "$TRANSCRIPT_FILE" <<'EOF'
{"type":"message","role":"user","content":"start"}
{"type":"message","role":"assistant","content":"ok","usage":{"input_tokens":1000,"output_tokens":200,"thinking_tokens":0}}
{"type":"message","role":"user","content":"continue"}
{"type":"message","role":"assistant","content":"done","usage":{"input_tokens":1200,"output_tokens":300,"thinking_tokens":150}}
{"type":"message","role":"assistant","content":"final","usage":{"input_tokens":100,"output_tokens":50,"thinking_tokens":0}}
EOF

# ── Run hook ───────────────────────────────────────────────────────────────
INPUT=$(jq -n \
  --arg cwd "$WORKTREE_PATH" \
  --arg transcript "$TRANSCRIPT_FILE" \
  '{cwd: $cwd, transcript_path: $transcript}')

printf '%s' "$INPUT" | bash "$HOOK"

# ── Assertions ─────────────────────────────────────────────────────────────
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$SIGNAL_PATH" ] || fail "signal.json not created at $SIGNAL_PATH"

agent_input=$(jq '.agent_tokens.input' "$SIGNAL_PATH")
agent_output=$(jq '.agent_tokens.output' "$SIGNAL_PATH")
agent_thinking=$(jq '.agent_tokens.thinking' "$SIGNAL_PATH")

[ "$agent_input"   = "2300" ] || fail "input tokens: expected 2300, got $agent_input"
[ "$agent_output"  = "550"  ] || fail "output tokens: expected 550, got $agent_output"
[ "$agent_thinking" = "150" ] || fail "thinking tokens: expected 150, got $agent_thinking"

cwd_in_signal=$(jq -r '.cwd' "$SIGNAL_PATH")
[ "$cwd_in_signal" = "$WORKTREE_PATH" ] || fail "cwd mismatch in signal.json"

echo "PASS: subagent-stop.sh"
