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
SIGNAL_DIR="$SIGNAL_BASE/$RELATIVE"
mkdir -p "$SIGNAL_DIR"

# Sum token usage across all API turns in the transcript.
# Transcript is JSONL; each line is a message/event object.
# Usage lives at .usage.{input_tokens,output_tokens,thinking_tokens}.
AGENT_INPUT=0
AGENT_OUTPUT=0
AGENT_THINKING=0

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  while IFS= read -r line; do
    has_usage=$(printf '%s' "$line" | jq 'has("usage")' 2>/dev/null || echo "false")
    if [ "$has_usage" = "true" ]; then
      inp=$(printf '%s' "$line" | jq '.usage.input_tokens    // 0')
      out=$(printf '%s' "$line" | jq '.usage.output_tokens   // 0')
      think=$(printf '%s' "$line" | jq '.usage.thinking_tokens // 0')
      AGENT_INPUT=$(( AGENT_INPUT   + inp   ))
      AGENT_OUTPUT=$(( AGENT_OUTPUT  + out   ))
      AGENT_THINKING=$(( AGENT_THINKING + think ))
    fi
  done < "$TRANSCRIPT_PATH"
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
