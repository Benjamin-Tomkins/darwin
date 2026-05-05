#!/usr/bin/env bash
# SubagentStop hook: extracts token usage from transcript; writes signal.json.
set -euo pipefail
# shellcheck source=lib/debug.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/debug.sh"

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
  darwin_debug "subagent-stop" "" "" "non-darwin cwd, skipping: $CWD"
  exit 0
fi
REPO_HASH="${RELATIVE%%/*}"
TASK_SLUG="${RELATIVE#*/}"
SIGNAL_DIR="$SIGNAL_BASE/$RELATIVE"
mkdir -p "$SIGNAL_DIR"
darwin_debug "subagent-stop" "$REPO_HASH" "$RELATIVE" "entered: cwd=$CWD"

# Sum token usage across all API turns in the transcript.
# Transcript is JSONL; each line is a message/event object.
# Usage lives at .usage (bare) or .message.usage (wrapped assistant turns).
AGENT_INPUT=0
AGENT_OUTPUT=0
AGENT_THINKING=0

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  # Use reduce + inputs rather than -s to avoid slurping the entire transcript into memory.
  # Emit the three totals as a single tab-separated line so we parse once.
  read -r AGENT_INPUT AGENT_OUTPUT AGENT_THINKING < <(jq -nr '
    reduce inputs as $line (
      {input: 0, output: 0, thinking: 0};
      ($line.usage // $line.message.usage // null) as $u |
      if $u != null then
        .input    += ($u.input_tokens    // 0 | floor) |
        .output   += ($u.output_tokens   // 0 | floor) |
        .thinking += ($u.thinking_tokens // 0 | floor)
      else . end
    ) | [.input, .output, .thinking] | @tsv
  ' "$TRANSCRIPT_PATH")
  darwin_debug "subagent-stop" "$REPO_HASH" "$RELATIVE" "tokens extracted: input=$AGENT_INPUT output=$AGENT_OUTPUT thinking=$AGENT_THINKING"
else
  darwin_debug "subagent-stop" "$REPO_HASH" "$RELATIVE" "no transcript, tokens default to 0"
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

darwin_debug "subagent-stop" "$REPO_HASH" "$RELATIVE" "signal written: $SIGNAL_DIR/signal.json"
echo "subagent-stop: signal written to $SIGNAL_DIR/signal.json" >&2
