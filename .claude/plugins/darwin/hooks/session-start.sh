#!/usr/bin/env bash
# session-start.sh — Darwin SessionStart hook.
# Runs once per Claude Code session. Detects JS runtime, seeds a default
# escalation ladder if none exists, then outputs a systemMessage so Claude
# surfaces the result to the user immediately on session open.
set -uo pipefail

PLUGIN="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
DARWIN_STATE_DIR="$HOME/.claude/darwin-state"
RUNTIME_JSON="$DARWIN_STATE_DIR/runtime.json"
LADDER_FILE="$HOME/.claude/escalation-ladder.json"

mkdir -p "$DARWIN_STATE_DIR"

# ── Runtime detection ────────────────────────────────────────────────────────
runtime_label="no JS runtime found — install Bun, Node 20+, or Deno"
if bash "$PLUGIN/helpers/c4/detect-runtime.sh" 2>/dev/null; then
  runtime_name=$(jq -r '.runtime' "$RUNTIME_JSON" 2>/dev/null || echo "unknown")
  runtime_exec=$(jq -r '.exec'    "$RUNTIME_JSON" 2>/dev/null || echo "unknown")
  runtime_ver=$("$runtime_exec" --version 2>/dev/null | head -1 | sed 's/^v//' || echo "")
  runtime_label="${runtime_name} ${runtime_ver}"
fi

# ── Escalation ladder ────────────────────────────────────────────────────────
ladder_note="loaded"
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
  ladder_note="seeded defaults"
fi

tier_count=$(jq '.ladder | length' "$LADDER_FILE" 2>/dev/null || echo "?")

# ── .gitignore seeding ───────────────────────────────────────────────────────
# Idempotent: appends only lines not already present.
# .claude/settings.json is intentionally excluded — it is committed project config.
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "${PROJECT_ROOT:-}" ]; then
  GITIGNORE="$PROJECT_ROOT/.gitignore"
  touch "$GITIGNORE"
  for entry in \
    ".claude/darwin-state/" \
    ".claude/darwin-worktrees/" \
    ".claude/CLAUDE.md" \
    ".claude/agents/" \
    ".claude/escalation-ladder.json" \
    ".claude/darwin-pairings/"; do
    grep -qxF "$entry" "$GITIGNORE" 2>/dev/null || printf '%s\n' "$entry" >> "$GITIGNORE"
  done
fi

# ── Surface result to user via systemMessage ─────────────────────────────────
printf '{"continue":true,"systemMessage":"Darwin plugin ready — runtime: %s | escalation ladder: %s tier(s) (%s)"}\n' \
  "$runtime_label" "$tier_count" "$ladder_note"
