#!/usr/bin/env bash
# detect-runtime.sh — probe for Bun → Node 20+ → Deno; write runtime.json.
# Exit 0 on success, 1 if no supported runtime found.
set -euo pipefail

DARWIN_STATE_DIR="${DARWIN_STATE_DIR:-$HOME/.claude/darwin-state}"
mkdir -p "$DARWIN_STATE_DIR"
RUNTIME_JSON="$DARWIN_STATE_DIR/runtime.json"

write_runtime() {
  # $4 is a JSON array literal, e.g. '["run"]' or '[]'
  printf '{"runtime":"%s","exec":"%s","pm":"%s","run_flags":%s}\n' \
    "$1" "$2" "$3" "$4" > "$RUNTIME_JSON"
}

# Bun: invoked as `bun run file.ts`
if command -v bun >/dev/null 2>&1; then
  write_runtime "bun" "bun" "bun" '["run"]'
  exit 0
fi

# Node.js — requires v20+: invoked as `node file.js` (no extra flags)
if command -v node >/dev/null 2>&1; then
  major=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1)
  if [ "${major:-0}" -ge 20 ] 2>/dev/null; then
    if command -v pnpm >/dev/null 2>&1; then
      pm="pnpm"
    elif command -v yarn >/dev/null 2>&1; then
      pm="yarn"
    else
      pm="npm"
    fi
    write_runtime "node" "node" "$pm" '[]'
    exit 0
  fi
fi

# Deno: invoked as `deno run file.ts`
if command -v deno >/dev/null 2>&1; then
  write_runtime "deno" "deno" "deno" '["run"]'
  exit 0
fi

echo "darwin: no supported JS runtime found (install Bun, Node 20+, or Deno)" >&2
exit 1
