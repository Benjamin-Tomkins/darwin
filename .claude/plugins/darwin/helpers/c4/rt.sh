#!/usr/bin/env bash
# rt.sh — thin wrapper: delegates install/build/test/run to the detected package manager.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_JSON="${HOME}/.claude/darwin-state/runtime.json"

if [ ! -f "$RUNTIME_JSON" ]; then
  bash "$SCRIPT_DIR/detect-runtime.sh"
fi
PM=$(jq -r '.pm' "$RUNTIME_JSON")

CMD="${1:-}"
shift || true

cd "$SCRIPT_DIR"
case "$CMD" in
  install) "$PM" install "$@" ;;
  build)   "$PM" run build "$@" ;;
  test)    "$PM" run test -- "$@" ;;
  run)     "$PM" run "$@" ;;
  *)       echo "Usage: rt.sh install|build|test|run [args...]" >&2; exit 1 ;;
esac
