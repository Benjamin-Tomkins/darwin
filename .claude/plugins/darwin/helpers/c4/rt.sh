#!/usr/bin/env bash
# rt.sh — thin wrapper: delegates build/test/run to detected runtime
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_JSON="${HOME}/.claude/darwin-state/runtime.json"

if [ ! -f "$RUNTIME_JSON" ]; then
  # Fallback: detect inline if runtime.json not yet written
  if command -v bun &>/dev/null; then
    EXEC="bun"
    PM="bun"
  elif command -v node &>/dev/null && node --version 2>/dev/null | grep -qE '^v(2[0-9]|[3-9][0-9])'; then
    EXEC="node"
    PM="npm"
  else
    echo "No supported runtime found. Run /darwin-init first." >&2
    exit 1
  fi
else
  EXEC=$(jq -r '.exec' "$RUNTIME_JSON")
  PM=$(jq -r '.pm' "$RUNTIME_JSON")
fi

CMD="${1:-}"
shift || true

case "$CMD" in
  install)  cd "$SCRIPT_DIR" && "$PM" install "$@" ;;
  build)    cd "$SCRIPT_DIR" && "$PM" run build "$@" ;;
  test)     cd "$SCRIPT_DIR" && "$PM" run test "$@" ;;
  run)      cd "$SCRIPT_DIR" && "$PM" run "$@" ;;
  *)        echo "Usage: rt.sh install|build|test|run [args...]" >&2; exit 1 ;;
esac
