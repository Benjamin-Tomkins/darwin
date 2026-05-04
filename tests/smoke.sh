#!/usr/bin/env bash
# smoke.sh — headless infrastructure tests for the Darwin plugin.
# Tests everything below the Claude controller layer: hooks, TS helpers.
# Does NOT require Claude API access.
#
# Usage: bash tests/smoke.sh
# Expected: all checks print PASS; script exits 0 on success, 1 on any failure.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PLUGIN="$REPO_ROOT/.claude/plugins/darwin"
HELPERS="$PLUGIN/helpers/c4"
FIXTURE="$HELPERS/tests/fixtures/hello-world/index.adoc"
PASS=0
FAIL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

ok()   { echo -e "${GREEN}PASS${NC}  $1"; ((PASS++)) || true; }
fail() { echo -e "${RED}FAIL${NC}  $1"; ((FAIL++)) || true; }

# Detect runtime exec from runtime.json (or fall back to bun/node)
if [ -f "$HOME/.claude/darwin-state/runtime.json" ]; then
  EXEC=$(jq -r '.exec' "$HOME/.claude/darwin-state/runtime.json")
  FLAGS=$(jq -r '.run_flags // [] | join(" ")' "$HOME/.claude/darwin-state/runtime.json")
else
  EXEC="bun"
  FLAGS=""
fi

echo "=== Darwin plugin smoke tests ==="
echo "Repo:    $REPO_ROOT"
echo "Runtime: $EXEC"
echo ""

# ── 1. detect-runtime.sh ───────────────────────────────────────────────────

echo "--- 1. detect-runtime.sh"
if bash "$HELPERS/detect-runtime.sh" 2>/dev/null; then
  RUNTIME_JSON="$HOME/.claude/darwin-state/runtime.json"
  if [ -f "$RUNTIME_JSON" ]; then
    ok "runtime.json created at $RUNTIME_JSON"
    for field in runtime exec pm; do
      val=$(jq -r ".$field // empty" "$RUNTIME_JSON")
      if [ -n "$val" ]; then ok "runtime.json.$field = $val"
      else fail "runtime.json.$field is missing"; fi
    done
  else
    fail "runtime.json not created"
  fi
else
  fail "detect-runtime.sh exited non-zero"
fi

# ── 2. session-start.sh ───────────────────────────────────────────────────

echo ""
echo "--- 2. session-start.sh"
OUTPUT=$(CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$PLUGIN/hooks/session-start.sh" 2>/dev/null)
if echo "$OUTPUT" | jq . >/dev/null 2>&1; then
  ok "session-start.sh output is valid JSON"
  CONTINUE=$(echo "$OUTPUT" | jq -r '.continue')
  MSG=$(echo "$OUTPUT" | jq -r '.systemMessage // empty')
  if [ "$CONTINUE" = "true" ]; then ok "continue=true"; else fail "continue != true"; fi
  if [ -n "$MSG" ]; then ok "systemMessage: $MSG"; else fail "systemMessage is empty"; fi
else
  fail "session-start.sh output is not valid JSON: $OUTPUT"
fi

if [ -f "$HOME/.claude/escalation-ladder.json" ]; then
  ok "escalation-ladder.json exists"
  TIERS=$(jq '.ladder | length' "$HOME/.claude/escalation-ladder.json")
  if [ "$TIERS" -gt 0 ]; then ok "escalation ladder has $TIERS tiers"
  else fail "escalation ladder is empty"; fi
else
  fail "escalation-ladder.json not created"
fi

GITIGNORE="$REPO_ROOT/.gitignore"
for entry in ".claude/agents/" ".claude/CLAUDE.md" ".claude/escalation-ladder.json"; do
  if grep -qxF "$entry" "$GITIGNORE" 2>/dev/null; then
    ok ".gitignore contains $entry"
  else
    fail ".gitignore missing $entry"
  fi
done

# ── 3. parse-index.js ─────────────────────────────────────────────────────

echo ""
echo "--- 3. parse-index.js"
PARSE_OUT=$($EXEC $FLAGS "$HELPERS/bin/parse-index.js" --file "$FIXTURE" 2>&1)
if echo "$PARSE_OUT" | jq . >/dev/null 2>&1; then
  ok "parse-index.js output is valid JSON"
  PROJECT_SLUG=$(echo "$PARSE_OUT" | jq -r '.projectSlug')
  if [ "$PROJECT_SLUG" = "hello-world" ]; then ok "projectSlug = hello-world"
  else fail "projectSlug = $PROJECT_SLUG (expected hello-world)"; fi

  ELEM_COUNT=$(echo "$PARSE_OUT" | jq '.elements | length')
  if [ "$ELEM_COUNT" -eq 1 ]; then ok "found 1 top-level element"
  else fail "found $ELEM_COUNT top-level elements (expected 1)"; fi

  ELEM_SLUG=$(echo "$PARSE_OUT" | jq -r '.elements[0].slug')
  if [ "$ELEM_SLUG" = "greeter" ]; then ok "element slug = greeter"
  else fail "element slug = $ELEM_SLUG (expected greeter)"; fi

  IMPL=$(echo "$PARSE_OUT" | jq -r '.elements[0].properties.impl')
  if [ "$IMPL" = "greeter-impl.adoc" ]; then ok "impl property = greeter-impl.adoc"
  else fail "impl property = $IMPL"; fi

  CHILD_COUNT=$(echo "$PARSE_OUT" | jq '.elements[0].children | length')
  if [ "$CHILD_COUNT" -eq 1 ]; then ok "found 1 child element"
  else fail "found $CHILD_COUNT children (expected 1)"; fi

  CHILD_SLUG=$(echo "$PARSE_OUT" | jq -r '.elements[0].children[0].slug')
  if [ "$CHILD_SLUG" = "api" ]; then ok "child slug = api"
  else fail "child slug = $CHILD_SLUG (expected api)"; fi
else
  fail "parse-index.js failed: $PARSE_OUT"
fi

# ── 4. branch-name.js ─────────────────────────────────────────────────────

echo ""
echo "--- 4. branch-name.js"
check_branch() {
  local desc="$1" expected="$2"; shift 2
  local actual
  actual=$($EXEC $FLAGS "$HELPERS/bin/branch-name.js" "$@" 2>&1)
  if [ "$actual" = "$expected" ]; then ok "$desc → $actual"
  else fail "$desc → $actual (expected $expected)"; fi
}

check_branch "single slug"          "agent/hello-world"              '["hello-world"]'
check_branch "single slug + asset"  "agent/hello-world/greeter/impl" '["hello-world","greeter"]' --asset impl
check_branch "three-level chain"    "agent/a/b/c/tests"              '["a","b","c"]' --asset tests

# ── 5. vitest unit tests ──────────────────────────────────────────────────

echo ""
echo "--- 5. vitest unit tests"
if (cd "$HELPERS" && npm test 2>&1 >/dev/null); then
  ok "all vitest tests passed"
else
  fail "vitest tests failed — run 'npm test' in .claude/plugins/darwin/helpers/c4 for details"
fi

# ── 6. skill file validation ─────────────────────────────────────────────

echo ""
echo "--- 6. skill file validation"
for skill_dir in "$PLUGIN/skills"/*/; do
  skill_name=$(basename "$skill_dir")
  skill_file="$skill_dir/SKILL.md"
  if [ ! -f "$skill_file" ]; then
    fail "skill $skill_name: SKILL.md missing"
    continue
  fi
  # Frontmatter must open with --- and contain name:
  if head -1 "$skill_file" | grep -q '^---$'; then
    ok "skill $skill_name: SKILL.md has frontmatter"
  else
    fail "skill $skill_name: SKILL.md missing YAML frontmatter"
  fi
  if grep -q '^name:' "$skill_file"; then
    ok "skill $skill_name: SKILL.md has name field"
  else
    fail "skill $skill_name: SKILL.md missing name field"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
