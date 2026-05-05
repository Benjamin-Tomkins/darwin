#!/usr/bin/env bash
# darwin_debug — append one JSONL entry to ~/.claude/darwin-state/debug.log
# Identifies source by hook name, repo hash, and task identifier so parallel
# worktrees can be distinguished in a shared log.
# Usage: darwin_debug <hook> <repo_hash> <task_identifier> <message>
darwin_debug() {
  local log_dir="$HOME/.claude/darwin-state"
  local log_file="$log_dir/debug.log"
  mkdir -p "$log_dir"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '%s\n' "$(jq -cn \
    --arg ts   "$ts" \
    --arg hook "$1" \
    --arg repo "$2" \
    --arg task "$3" \
    --arg msg  "$4" \
    '{timestamp: $ts, hook: $hook, repo_hash: $repo, task_identifier: $task, message: $msg}')" \
    >> "$log_file"
  # Trim to last 5000 lines to bound log growth across many worktree runs
  local count
  count=$(wc -l < "$log_file")
  if [ "$count" -gt 5000 ]; then
    tail -n 5000 "$log_file" > "${log_file}.tmp" && mv "${log_file}.tmp" "$log_file"
  fi
}
