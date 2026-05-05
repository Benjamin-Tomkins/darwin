#!/usr/bin/env bash
# WorktreeCreate hook: creates sparse worktree from controller manifest.
set -euo pipefail

INPUT=$(cat)

# Claude Code provides the planned worktree path.
# Verify the exact field name against Claude Code hook docs at implementation time.
WORKTREE_PATH=$(printf '%s' "$INPUT" | jq -r '.path // .worktree_path // empty')

if [ -z "$WORKTREE_PATH" ]; then
  echo "worktree-create: missing path in hook input: $INPUT" >&2
  exit 1
fi

WORKTREE_BASE="$HOME/.claude/darwin-worktrees"

if [[ "$WORKTREE_PATH" != "$WORKTREE_BASE/"* ]]; then
  exit 0  # Not a darwin-managed worktree — skip silently
fi

SIGNAL_BASE="$HOME/.claude/darwin-state"
RELATIVE="${WORKTREE_PATH#"$WORKTREE_BASE/"}"
REPO_HASH="${RELATIVE%%/*}"
TASK_SLUG="${RELATIVE#*/}"
MANIFEST_PATH="$SIGNAL_BASE/$REPO_HASH/$TASK_SLUG/manifest.json"

if [ ! -f "$MANIFEST_PATH" ]; then
  echo "worktree-create: manifest not found at $MANIFEST_PATH" >&2
  exit 1
fi

PROJECT_ROOT=$(jq -r '.project_root // empty' "$MANIFEST_PATH")
BASE_REF=$(jq -r '.base_ref // "HEAD"' "$MANIFEST_PATH")
BRANCH=$(jq -r '.branch // empty' "$MANIFEST_PATH")
if [ -z "$PROJECT_ROOT" ] || [ -z "$BRANCH" ]; then
  echo "worktree-create: manifest missing required field project_root or branch" >&2
  exit 1
fi

AGENT_TEMPLATE_PATH=$(jq -r '.agent_template_path // empty' "$MANIFEST_PATH")

# Create worktree with a new branch, no checkout yet.
# If anything below fails, _cleanup_worktree removes the half-built worktree.
mkdir -p "$(dirname "$WORKTREE_PATH")"
git -C "$PROJECT_ROOT" worktree add --no-checkout -b "$BRANCH" "$WORKTREE_PATH" "$BASE_REF"
WORKTREE_NEEDS_CLEANUP=1
TMPFILE=""
_cleanup_worktree() {
  [ "${WORKTREE_NEEDS_CLEANUP:-0}" = "1" ] || return 0
  git -C "$PROJECT_ROOT" worktree remove --force "$WORKTREE_PATH" 2>/dev/null || true
  [ -n "$TMPFILE" ] && rm -f "$TMPFILE"
}
trap '_cleanup_worktree' EXIT

# Configure sparse checkout (non-cone mode for glob support).
# Always include .claude/** so injected configs are visible to the agent in the worktree.
git -C "$WORKTREE_PATH" sparse-checkout init --no-cone

# Populate patterns from manifest (writable_globs + readonly_globs) plus .claude/**
{
  jq -r '.writable_globs // [] | .[]' "$MANIFEST_PATH"
  jq -r '.readonly_globs  // [] | .[]' "$MANIFEST_PATH"
  printf '.claude/**\n'
} | git -C "$WORKTREE_PATH" sparse-checkout set --stdin

git -C "$WORKTREE_PATH" checkout

# Inject .claude/ from agent template if provided.
# mkdir -p ensures the directory exists even when .claude/ isn't yet in the working tree.
mkdir -p "$WORKTREE_PATH/.claude/agents"
if [ -n "$AGENT_TEMPLATE_PATH" ] && [ -d "$AGENT_TEMPLATE_PATH" ]; then
  cp -r "$AGENT_TEMPLATE_PATH/." "$WORKTREE_PATH/.claude/"
fi

# Populate sandbox.filesystem.allowWrite from manifest writable_globs.
# The agent template may already have a settings.json with pairing-level permissions.allow/deny;
# we only override the allowWrite list so those pairing-specific rules are preserved.
WRITABLE=$(jq '.writable_globs // []' "$MANIFEST_PATH")
SETTINGS="$WORKTREE_PATH/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  # Merge: patch just allowWrite into the existing template config
  TMPFILE=$(mktemp)
  jq --argjson w "$WRITABLE" \
    '.sandbox.filesystem.allowWrite = $w' \
    "$SETTINGS" > "$TMPFILE"
  mv "$TMPFILE" "$SETTINGS"
  TMPFILE=""
else
  # No template — emit minimal sandbox config
  jq -n --argjson w "$WRITABLE" '{
    sandbox: {
      enabled: true,
      allowUnsandboxedCommands: false,
      failIfUnavailable: true,
      filesystem: {
        allowWrite: $w,
        denyWrite: ["."],
        denyRead: [
          ".git", "~/.ssh", "~/.aws", "~/.gnupg",
          ".env", ".env.local", ".env.production", ".env.test", "secrets"
        ]
      }
    }
  }' > "$SETTINGS"
fi

# Mark injected files skip-worktree so agent edits don't get accidentally committed.
#
# Protection strategy (belt-and-suspenders):
#   1. Gitignore (primary) — real Darwin projects gitignore .claude/settings.json,
#      .claude/CLAUDE.md, and .claude/agents/, so `git add` won't pick them up.
#   2. Skip-worktree bit (secondary) — for files that ARE tracked in git (e.g. projects
#      that commit .claude/ stubs), we force-add the injected content and mark
#      skip-worktree so `git commit` won't include them.
#
# Note: in sparse-checkout worktrees on Apple git 2.25+, `git ls-files -v` reports
# the S flag only for files absent from the working tree.  Once a file is injected
# on disk the display reverts to H even when the CE_SKIP_WORKTREE bit (0x4000) is
# set in the index — a display quirk, not a semantic failure.  Use
# `git ls-files --debug` and inspect the flags field to confirm the bit is set.
mark_skip_worktree_if_tracked() {
  local rel="$1"
  if git -C "$WORKTREE_PATH" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
    git -C "$WORKTREE_PATH" add --force "$rel"
    git -C "$WORKTREE_PATH" update-index --skip-worktree "$rel"
  fi
  # If untracked/gitignored: no action needed; gitignore prevents accidental staging.
}

for fname in "settings.json" "CLAUDE.md"; do
  [ -f "$WORKTREE_PATH/.claude/$fname" ] && mark_skip_worktree_if_tracked ".claude/$fname"
done
if [ -d "$WORKTREE_PATH/.claude/agents" ]; then
  for fpath in "$WORKTREE_PATH/.claude/agents/"*; do
    [ -f "$fpath" ] && mark_skip_worktree_if_tracked ".claude/agents/$(basename "$fpath")"
  done
fi

# Return absolute worktree path to Claude Code on stdout
WORKTREE_NEEDS_CLEANUP=0
printf '%s\n' "$WORKTREE_PATH"
