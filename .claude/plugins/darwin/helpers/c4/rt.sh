#!/usr/bin/env bash
# rt.sh — thin wrapper: delegates build/test/run to detected runtime
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_JSON="${HOME}/.claude/darwin-state/runtime.json"

if [ ! -f "$RUNTIME_JSON" ]; then
  bash "$SCRIPT_DIR/detect-runtime.sh"
fi
EXEC=$(jq -r '.exec' "$RUNTIME_JSON")
PM=$(jq -r '.pm' "$RUNTIME_JSON")

CMD="${1:-}"
shift || true

case "$CMD" in
  install)  cd "$SCRIPT_DIR" && "$PM" install "$@" ;;
  build)    cd "$SCRIPT_DIR" && "$PM" run build "$@" ;;
  test)     cd "$SCRIPT_DIR" && "$PM" run test -- "$@" ;;
  run)      cd "$SCRIPT_DIR" && "$PM" run "$@" ;;
  *)        echo "Usage: rt.sh install|build|test|run [args...]" >&2; exit 1 ;;
esac
