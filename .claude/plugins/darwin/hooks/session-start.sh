#!/usr/bin/env bash
# session-start.sh — Darwin SessionStart hook.
# Runs once per Claude Code session. Detects JS runtime and seeds a default
# escalation ladder if none exists. Errors are non-fatal (printed to stderr).
set -uo pipefail

PLUGIN="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
DARWIN_STATE_DIR="$HOME/.claude/darwin-state"
LADDER_FILE="$HOME/.claude/escalation-ladder.json"

mkdir -p "$DARWIN_STATE_DIR"

# Detect (or re-detect) JS runtime
if ! bash "$PLUGIN/helpers/c4/detect-runtime.sh" 2>/dev/null; then
  echo "darwin: no supported JS runtime found — install Bun, Node 20+, or Deno" >&2
fi

# Seed a default escalation ladder only if none exists yet.
# Users can edit this file to customise model tiers; this hook will not overwrite it.
if [ ! -f "$LADDER_FILE" ]; then
  ladder_id="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat > "$LADDER_FILE" <<EOF
{
  "ladder_id": "$ladder_id",
  "ladder": [
    { "model": "claude-haiku-4-5-20251001", "tier": 1 },
    { "model": "claude-sonnet-4-6",         "tier": 2 },
    { "model": "claude-opus-4-7",           "tier": 3 }
  ]
}
EOF
fi

exit 0
