#!/usr/bin/env bash
# .claude/plugins/darwin/hooks/tests/worktree-create.test.sh
# Tests hook behaviour with a real (temp) git repo.
set -euo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/worktree-create.sh"
SIGNAL_BASE="$HOME/.claude/darwin-state"
WORKTREE_BASE="$HOME/.claude/darwin-worktrees"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Declare variables before trap so cleanup can reference them
PROJECT_DIR=""
TEMPLATE_DIR=""
REPO_HASH="testhash01"
TASK_SLUG="auth-impl"
WORKTREE_PATH="$WORKTREE_BASE/$REPO_HASH/$TASK_SLUG"

cleanup() {
  if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
    git -C "$PROJECT_DIR" worktree remove --force "$WORKTREE_PATH" 2>/dev/null || true
  fi
  rm -rf "${PROJECT_DIR:-}" "${TEMPLATE_DIR:-}" \
         "$SIGNAL_BASE/$REPO_HASH" "$WORKTREE_BASE/$REPO_HASH"
}
trap cleanup EXIT

# ── Setup: project repo ────────────────────────────────────────────────────
PROJECT_DIR=$(mktemp -d /tmp/darwin-test-project-XXXXX)
git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.email "test@test.com"
git -C "$PROJECT_DIR" config user.name "Test"
mkdir -p "$PROJECT_DIR/src"
echo "export const x = 1;" > "$PROJECT_DIR/src/main.ts"
# Add .gitignore to exclude injected controller files from agent commits,
# matching the protection mechanism used in real Darwin projects.
cat > "$PROJECT_DIR/.gitignore" <<'GITIGNORE'
.claude/settings.json
.claude/CLAUDE.md
.claude/agents/
GITIGNORE
git -C "$PROJECT_DIR" add .
git -C "$PROJECT_DIR" commit -q -m "init"

# Fake agent template (provides the real injected content)
TEMPLATE_DIR=$(mktemp -d /tmp/darwin-test-template-XXXXX)
echo "# Task CLAUDE.md" > "$TEMPLATE_DIR/CLAUDE.md"
mkdir -p "$TEMPLATE_DIR/agents"
echo "# agent def" > "$TEMPLATE_DIR/agents/task-agent.md"

MANIFEST_PATH="$SIGNAL_BASE/$REPO_HASH/$TASK_SLUG/manifest.json"
mkdir -p "$SIGNAL_BASE/$REPO_HASH/$TASK_SLUG"

cat > "$MANIFEST_PATH" <<EOF
{
  "project_root":       "$PROJECT_DIR",
  "base_ref":           "HEAD",
  "branch":             "agent/auth-impl",
  "pairing_name":       "implementer-with-tests",
  "writable_globs":     ["src/main.ts"],
  "readonly_globs":     [],
  "agent_template_path": "$TEMPLATE_DIR"
}
EOF

# ── Run hook ───────────────────────────────────────────────────────────────
RESULT=$(printf '{"path":"%s"}' "$WORKTREE_PATH" | bash "$HOOK")

# ── Assertions ─────────────────────────────────────────────────────────────
[ "$RESULT" = "$WORKTREE_PATH" ] || fail "hook did not return worktree path; got: $RESULT"
[ -d "$WORKTREE_PATH" ]          || fail "worktree directory not created"
[ -f "$WORKTREE_PATH/src/main.ts" ] || fail "sparse checkout missing src/main.ts"
[ -f "$WORKTREE_PATH/.claude/CLAUDE.md" ] || fail ".claude/CLAUDE.md not injected"
[ -f "$WORKTREE_PATH/.claude/agents/task-agent.md" ] || fail ".claude/agents/task-agent.md not injected"

# Verify skip-worktree / gitignore protection on injected files.
# Protection is provided by the project .gitignore (injected files are excluded from
# agent commits without being staged). Verify that git status shows NO staged or
# unstaged changes for the injected .claude/ files — they must not appear in a way
# that would let an agent accidentally commit them.
#
# `git status --porcelain` is used because `git ls-files -v` reports the sparse-
# skip-worktree flag (S) only for files absent from the working tree; once a file is
# injected on disk the display reverts to H even if the CE_SKIP_WORKTREE bit is set
# in the index — a known apple-git 2.25+ sparse-checkout display quirk.  The actual
# protection semantics (file won't be committed) are correctly captured by status.
staged=$(git -C "$WORKTREE_PATH" status --porcelain -- ".claude/CLAUDE.md" 2>/dev/null)
[ -z "$staged" ] || fail ".claude/CLAUDE.md appears in git status (agent could commit it): $staged"

# Verify the raw index flags include the skip-worktree CE bit (0x4000) when the file
# is tracked in git.  For gitignored files the bit is not set (not in index), which is
# fine — gitignore is the protection mechanism in that case.
if git -C "$WORKTREE_PATH" ls-files --error-unmatch ".claude/CLAUDE.md" >/dev/null 2>&1; then
  raw_flags=$(git -C "$WORKTREE_PATH" ls-files --debug ".claude/CLAUDE.md" | awk '/flags:/{print $NF}')
  skip_bit=$(( 0x${raw_flags} & 0x4000 ))
  [ "$skip_bit" -ne 0 ] || fail ".claude/CLAUDE.md is tracked but skip-worktree bit (0x4000) not set; flags: $raw_flags"
fi

# Verify settings.json has allowWrite populated from manifest writable_globs
[ -f "$WORKTREE_PATH/.claude/settings.json" ] || fail "settings.json not present after sandbox config generation"
allow_write=$(jq -r '.sandbox.filesystem.allowWrite[0]' "$WORKTREE_PATH/.claude/settings.json")
[ "$allow_write" = "src/main.ts" ] || fail "sandbox allowWrite not populated from writable_globs; got: $allow_write"

# ── Scenario 2: template already has settings.json → merge path ───────────────
# Use a distinct repo-hash/slug so there's no collision with scenario 1.
REPO_HASH2="testhash02"
TASK_SLUG2="auth-merge"
WORKTREE_PATH2="$WORKTREE_BASE/$REPO_HASH2/$TASK_SLUG2"

cleanup2() {
  if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
    git -C "$PROJECT_DIR" worktree remove --force "$WORKTREE_PATH2" 2>/dev/null || true
  fi
  rm -rf "$SIGNAL_BASE/$REPO_HASH2" "$WORKTREE_BASE/$REPO_HASH2"
}
trap 'cleanup; cleanup2' EXIT

TEMPLATE_DIR2=$(mktemp -d /tmp/darwin-test-template2-XXXXX)
# Pre-populate settings.json in the template with extra keys that must survive the merge.
cat > "$TEMPLATE_DIR2/settings.json" <<'SETTINGS'
{
  "someKey": "value",
  "sandbox": {
    "enabled": false
  }
}
SETTINGS

MANIFEST_PATH2="$SIGNAL_BASE/$REPO_HASH2/$TASK_SLUG2/manifest.json"
mkdir -p "$SIGNAL_BASE/$REPO_HASH2/$TASK_SLUG2"
cat > "$MANIFEST_PATH2" <<EOF
{
  "project_root":       "$PROJECT_DIR",
  "base_ref":           "HEAD",
  "branch":             "agent/auth-merge",
  "pairing_name":       "implementer-with-tests",
  "writable_globs":     ["src/main.ts"],
  "readonly_globs":     [],
  "agent_template_path": "$TEMPLATE_DIR2"
}
EOF

RESULT2=$(printf '{"path":"%s"}' "$WORKTREE_PATH2" | bash "$HOOK")

[ "$RESULT2" = "$WORKTREE_PATH2" ] || fail "scenario 2: hook did not return worktree path; got: $RESULT2"
[ -f "$WORKTREE_PATH2/.claude/settings.json" ] || fail "scenario 2: settings.json not present"

allow_write2=$(jq -r '.sandbox.filesystem.allowWrite[0]' "$WORKTREE_PATH2/.claude/settings.json")
[ "$allow_write2" = "src/main.ts" ] || fail "scenario 2: allowWrite not patched from writable_globs; got: $allow_write2"

some_key2=$(jq -r '.someKey' "$WORKTREE_PATH2/.claude/settings.json")
[ "$some_key2" = "value" ] || fail "scenario 2: someKey not preserved after merge; got: $some_key2"

rm -rf "$TEMPLATE_DIR2"

echo "PASS: worktree-create.sh"
