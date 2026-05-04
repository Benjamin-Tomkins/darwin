#!/usr/bin/env bash
# SubagentStop hook: extracts token usage from transcript; writes signal.json.
set -euo pipefail

INPUT=$(cat)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')

if [ -z "$CWD" ]; then
  echo "subagent-stop: missing cwd in hook input" >&2
  exit 1
fi

WORKTREE_BASE="$HOME/.claude/darwin-worktrees"
SIGNAL_BASE="$HOME/.claude/darwin-state"

# Derive <repo-hash>/<task-slug> from cwd
RELATIVE="${CWD#"$WORKTREE_BASE/"}"
if [ "$RELATIVE" = "$CWD" ]; then
  echo "subagent-stop: cwd '$CWD' is not inside WORKTREE_BASE '$WORKTREE_BASE'" >&2
  exit 1
fi
SIGNAL_DIR="$SIGNAL_BASE/$RELATIVE"
mkdir -p "$SIGNAL_DIR"

# Sum token usage across all API turns in the transcript.
# Transcript is JSONL; each line is a message/event object.
# Usage lives at .usage.{input_tokens,output_tokens,thinking_tokens}.
AGENT_INPUT=0
AGENT_OUTPUT=0
AGENT_THINKING=0

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  TOTALS=$(jq -s '{
    input:    ([.[] | select(has("usage")) | .usage.input_tokens    // 0 | floor] | add // 0),
    output:   ([.[] | select(has("usage")) | .usage.output_tokens   // 0 | floor] | add // 0),
    thinking: ([.[] | select(has("usage")) | .usage.thinking_tokens // 0 | floor] | add // 0)
  }' "$TRANSCRIPT_PATH")
  AGENT_INPUT=$(printf '%s' "$TOTALS" | jq '.input')
  AGENT_OUTPUT=$(printf '%s' "$TOTALS" | jq '.output')
  AGENT_THINKING=$(printf '%s' "$TOTALS" | jq '.thinking')
fi

# Write signal.json — controller reads this after SubagentStop fires.
jq -n \
  --arg cwd            "$CWD" \
  --arg transcript     "${TRANSCRIPT_PATH:-}" \
  --argjson inp        "$AGENT_INPUT" \
  --argjson out        "$AGENT_OUTPUT" \
  --argjson thinking   "$AGENT_THINKING" \
  '{
    cwd:             $cwd,
    transcript_path: $transcript,
    agent_tokens: {
      input:    $inp,
      output:   $out,
      thinking: $thinking
    }
  }' > "$SIGNAL_DIR/signal.json"

echo "subagent-stop: signal written to $SIGNAL_DIR/signal.json" >&2
