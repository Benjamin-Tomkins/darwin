# Darwin Phase 2 Enhancements — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the darwin plugin production-usable: hooks skip gracefully for non-darwin worktrees, built-in pairing templates remove the empty-stub barrier, token tracking is verified end-to-end, and `plan-software` supports session resume.

**Architecture:** Four independent improvements to `.claude/plugins/darwin/`. No new external dependencies. Tests live in `tests/smoke.sh` and `.claude/plugins/darwin/hooks/tests/`. Each task is self-contained and individually committable.

**Tech Stack:** Bash, jq, YAML (pairing configs), Claude Code plugin conventions.

---

### Task 1: Hooks — graceful no-op for non-darwin worktrees

Both `worktree-create.sh` and `subagent-stop.sh` `exit 1` when the path/cwd is not under the darwin base. Since Claude Code fires these hooks for **all** worktrees (not just darwin-managed ones), they must `exit 0` silently for foreign paths.

**Files:**
- Modify: `.claude/plugins/darwin/hooks/worktree-create.sh`
- Modify: `.claude/plugins/darwin/hooks/subagent-stop.sh`
- Modify: `.claude/plugins/darwin/hooks/tests/worktree-create.test.sh`
- Modify: `tests/smoke.sh`

- [ ] **Step 1: Add non-darwin path test to worktree-create.test.sh**

Open `.claude/plugins/darwin/hooks/tests/worktree-create.test.sh`. After the variable declarations and before the `# ── Setup` block, insert:

```bash
# ── Test: non-darwin path exits 0 (silent no-op) ──────────────────────────
echo '{"path":"/tmp/not-a-darwin-worktree-$$"}' | bash "$HOOK" 2>/dev/null
[ $? -eq 0 ] || fail "worktree-create: should exit 0 for non-darwin path, got exit 1"
echo "PASS  non-darwin path exits 0"
```

- [ ] **Step 2: Run test, confirm it currently fails**

```bash
bash .claude/plugins/darwin/hooks/tests/worktree-create.test.sh 2>&1 | head -5
```
Expected output contains: `FAIL` or non-zero exit

- [ ] **Step 3: Fix worktree-create.sh — exit 0 for non-darwin path**

In `.claude/plugins/darwin/hooks/worktree-create.sh`, replace:
```bash
if [[ "$WORKTREE_PATH" != "$WORKTREE_BASE/"* ]]; then
  echo "worktree-create: path is not under expected base ($WORKTREE_BASE): $WORKTREE_PATH" >&2
  exit 1
fi
```
With:
```bash
if [[ "$WORKTREE_PATH" != "$WORKTREE_BASE/"* ]]; then
  exit 0  # Not a darwin-managed worktree — skip silently
fi
```

- [ ] **Step 4: Fix subagent-stop.sh — exit 0 for non-darwin cwd**

In `.claude/plugins/darwin/hooks/subagent-stop.sh`, replace:
```bash
if [ "$RELATIVE" = "$CWD" ]; then
  echo "subagent-stop: cwd '$CWD' is not inside WORKTREE_BASE '$WORKTREE_BASE'" >&2
  exit 1
fi
```
With:
```bash
if [ "$RELATIVE" = "$CWD" ]; then
  exit 0  # Not a darwin-managed worktree — skip silently
fi
```

- [ ] **Step 5: Run worktree-create test suite**

```bash
bash .claude/plugins/darwin/hooks/tests/worktree-create.test.sh
```
Expected: all tests pass, including `PASS  non-darwin path exits 0`

- [ ] **Step 6: Add hook skip checks to smoke.sh**

In `tests/smoke.sh`, add before the `# ── Summary` section:

```bash
# ── 7. hook graceful-skip tests ───────────────────────────────────────────

echo ""
echo "--- 7. hook graceful-skip tests"

if echo '{"cwd":"/tmp/not-darwin-$$","transcript_path":""}' \
     | bash "$PLUGIN/hooks/subagent-stop.sh" 2>/dev/null; then
  ok "subagent-stop: exits 0 for non-darwin cwd"
else
  fail "subagent-stop: exits non-zero for non-darwin cwd"
fi

if echo '{"path":"/tmp/not-darwin-$$"}' \
     | bash "$PLUGIN/hooks/worktree-create.sh" 2>/dev/null; then
  ok "worktree-create: exits 0 for non-darwin path"
else
  fail "worktree-create: exits non-zero for non-darwin path"
fi
```

- [ ] **Step 7: Run full smoke test**

```bash
bash tests/smoke.sh
```
Expected: all existing checks pass plus 2 new hook skip checks

- [ ] **Step 8: Commit**

```bash
git add .claude/plugins/darwin/hooks/worktree-create.sh \
        .claude/plugins/darwin/hooks/subagent-stop.sh \
        .claude/plugins/darwin/hooks/tests/worktree-create.test.sh \
        tests/smoke.sh
git commit -m "fix: hooks exit 0 (no-op) for non-darwin worktrees"
```

---

### Task 2: Built-in pairing templates with plugin-directory fallback

Create three built-in pairings in the plugin source. Update the `darwin:worktree` skill to look in the plugin directory when a project-local pairing is not found.

**Files:**
- Create: `.claude/plugins/darwin/pairings/implementer-with-tests/pairing.yaml`
- Create: `.claude/plugins/darwin/pairings/test-author/pairing.yaml`
- Create: `.claude/plugins/darwin/pairings/doc-writer/pairing.yaml`
- Modify: `.claude/plugins/darwin/skills/worktree/SKILL.md`
- Modify: `tests/smoke.sh`

- [ ] **Step 1: Add built-in pairing existence checks to smoke.sh (they should fail)**

In `tests/smoke.sh`, add after the hook graceful-skip section:

```bash
# ── 8. built-in pairing templates ────────────────────────────────────────

echo ""
echo "--- 8. built-in pairing templates"
for p in implementer-with-tests test-author doc-writer; do
  pf="$PLUGIN/pairings/$p/pairing.yaml"
  if [ -f "$pf" ]; then
    ok "built-in pairing: $p exists"
    for field in name agent evals; do
      if grep -q "^$field:" "$pf"; then
        ok "built-in pairing $p: has $field field"
      else
        fail "built-in pairing $p: missing $field field"
      fi
    done
  else
    fail "built-in pairing: $p missing"
  fi
done
```

- [ ] **Step 2: Run smoke test, confirm new checks fail**

```bash
bash tests/smoke.sh 2>&1 | grep -E "^(PASS|FAIL)" | tail -10
```
Expected: three FAIL lines for the pairing existence checks

- [ ] **Step 3: Create implementer-with-tests pairing**

Create `.claude/plugins/darwin/pairings/implementer-with-tests/pairing.yaml`:

```yaml
name: implementer-with-tests
agent:
  instructions: |
    Implement the task described in your CLAUDE.md under "== Implementation".

    Follow TDD:
    1. Write failing tests first using the project's existing test framework and conventions
    2. Implement just enough code to make the tests pass
    3. Stage all created and modified files: git add <paths>

    Do NOT commit — the controller handles commits.
    Work only within the sandbox-allowed paths.
evals:
  - id: has-staged-changes
    type: command
    command: "[ \"$(git diff --cached --name-only | wc -l | tr -d ' ')\" -gt 0 ]"
    timeout: 10
    on_fail:
      problem: "No files staged after agent run"
      hypothesis: "Agent did not create or modify any files"
      failure_class: validation-fail
```

- [ ] **Step 4: Create test-author pairing**

Create `.claude/plugins/darwin/pairings/test-author/pairing.yaml`:

```yaml
name: test-author
agent:
  instructions: |
    Write tests for the task described in your CLAUDE.md under "== Tests".

    Requirements:
    - Use the project's existing test framework and conventions
    - Tests must be self-contained and runnable with no external setup
    - Stage all test files: git add <paths>

    Do NOT commit — the controller handles commits.
    Work only within the sandbox-allowed paths.
evals:
  - id: has-staged-changes
    type: command
    command: "[ \"$(git diff --cached --name-only | wc -l | tr -d ' ')\" -gt 0 ]"
    timeout: 10
    on_fail:
      problem: "No test files staged after agent run"
      hypothesis: "Agent did not create any test files"
      failure_class: validation-fail
```

- [ ] **Step 5: Create doc-writer pairing**

Create `.claude/plugins/darwin/pairings/doc-writer/pairing.yaml`:

```yaml
name: doc-writer
agent:
  instructions: |
    Write documentation for the task described in your CLAUDE.md under "== Detail".

    Requirements:
    - Be concise, accurate, and audience-appropriate
    - Stage all documentation files: git add <paths>

    Do NOT commit — the controller handles commits.
    Work only within the sandbox-allowed paths.
evals:
  - id: has-staged-changes
    type: command
    command: "[ \"$(git diff --cached --name-only | wc -l | tr -d ' ')\" -gt 0 ]"
    timeout: 10
    on_fail:
      problem: "No documentation files staged after agent run"
      hypothesis: "Agent did not create any documentation files"
      failure_class: validation-fail
```

- [ ] **Step 6: Run smoke test, confirm pairing checks now pass**

```bash
bash tests/smoke.sh 2>&1 | grep -E "^(PASS|FAIL)" | tail -12
```
Expected: PASS for all three pairings × (exists + 3 fields) = 12 passing

- [ ] **Step 7: Update worktree SKILL.md — pairing resolution with plugin fallback**

In `.claude/plugins/darwin/skills/worktree/SKILL.md`, find and replace the pairing resolution paragraph in the **Load asset configurations** section (contains "Resolve the pairing name by reading"):

Old:
```
Resolve the pairing name by reading `.claude/darwin-pairings/<pairing-name>/pairing.yaml` from the repo root. If the file does not exist, halt with: `Pairing '<name>' not found in .claude/darwin-pairings/. Create the pairing file or run /darwin-init.`
```

New:
```
Resolve the pairing by checking these locations in order:
1. `.claude/darwin-pairings/<pairing-name>/pairing.yaml` (project-local override)
2. `.claude/plugins/darwin/pairings/<pairing-name>/pairing.yaml` (plugin built-in)

Built-in names: `implementer-with-tests`, `test-author`, `doc-writer`.

If neither location has the file, halt: `Pairing '<name>' not found. Use a built-in or create .claude/darwin-pairings/<name>/pairing.yaml.`
```

Also update the matching `cat` command in **section 6.1 Load and verify pairing**:

Old:
```bash
cat <project-root>/.claude/darwin-pairings/<pairing-name>/pairing.yaml
```

New:
```bash
# Resolve pairing: project-local takes precedence over plugin built-ins
PAIRING_FILE=""
for candidate in \
  "<project-root>/.claude/darwin-pairings/<pairing-name>/pairing.yaml" \
  "<plugin-root>/pairings/<pairing-name>/pairing.yaml"; do
  [ -f "$candidate" ] && PAIRING_FILE="$candidate" && break
done
[ -n "$PAIRING_FILE" ] || { echo "Pairing not found: <pairing-name>"; exit 1; }
cat "$PAIRING_FILE"
```

- [ ] **Step 8: Run smoke test to confirm no regressions**

```bash
bash tests/smoke.sh
```
Expected: all checks pass

- [ ] **Step 9: Commit**

```bash
git add .claude/plugins/darwin/pairings/ \
        .claude/plugins/darwin/skills/worktree/SKILL.md \
        tests/smoke.sh
git commit -m "feat: built-in pairing templates with plugin-dir fallback resolution"
```

---

### Task 3: Token tracking — fix and verify SubagentStop transcript extraction

The current jq filter in `subagent-stop.sh` checks for `.usage` at the top level of each JSONL line. Claude Code's transcript format wraps usage inside `.message.usage`. Fix the filter to handle both locations, then add a fixture-based test to lock in the behaviour.

**Files:**
- Create: `.claude/plugins/darwin/hooks/tests/fixtures/transcript-sample.jsonl`
- Create: `.claude/plugins/darwin/hooks/tests/subagent-stop.test.sh`
- Modify: `.claude/plugins/darwin/hooks/subagent-stop.sh`
- Modify: `tests/smoke.sh`

- [ ] **Step 1: Create fixture transcript**

Create `.claude/plugins/darwin/hooks/tests/fixtures/transcript-sample.jsonl` with content that exercises both formats:

```
{"type":"user","message":{"role":"user","content":"implement this"}}
{"type":"assistant","message":{"role":"assistant","content":"ok","usage":{"input_tokens":120,"output_tokens":40,"cache_creation_input_tokens":0,"cache_read_input_tokens":800}}}
{"type":"assistant","message":{"role":"assistant","content":"done","usage":{"input_tokens":200,"output_tokens":60,"cache_creation_input_tokens":0,"cache_read_input_tokens":1200}}}
{"usage":{"input_tokens":50,"output_tokens":20,"thinking_tokens":15}}
```

Expected totals: `input=370` (120+200+50), `output=120` (40+60+20), `thinking=15`

- [ ] **Step 2: Create subagent-stop test script**

Create `.claude/plugins/darwin/hooks/tests/subagent-stop.test.sh`:

```bash
#!/usr/bin/env bash
# Tests subagent-stop.sh token extraction with a fixture transcript.
set -euo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/subagent-stop.sh"
FIXTURES="$(cd "$(dirname "$0")" && pwd)/fixtures"
SIGNAL_BASE="$HOME/.claude/darwin-state"
WORKTREE_BASE="$HOME/.claude/darwin-worktrees"

fail() { echo "FAIL: $1" >&2; exit 1; }

REPO_HASH="testhash-tokentest"
TASK_SLUG="token-test"
CWD="$WORKTREE_BASE/$REPO_HASH/$TASK_SLUG"
SIGNAL_DIR="$SIGNAL_BASE/$REPO_HASH/$TASK_SLUG"

cleanup() { rm -rf "$SIGNAL_BASE/$REPO_HASH" "$WORKTREE_BASE/$REPO_HASH"; }
trap cleanup EXIT

mkdir -p "$CWD"

printf '%s' "$(jq -n \
  --arg cwd "$CWD" \
  --arg transcript "$FIXTURES/transcript-sample.jsonl" \
  '{cwd: $cwd, transcript_path: $transcript}')" \
  | bash "$HOOK" 2>/dev/null || fail "hook exited non-zero"

[ -f "$SIGNAL_DIR/signal.json" ] || fail "signal.json not written"

INPUT_TOK=$(jq '.agent_tokens.input'   "$SIGNAL_DIR/signal.json")
OUTPUT_TOK=$(jq '.agent_tokens.output'  "$SIGNAL_DIR/signal.json")
THINK_TOK=$(jq '.agent_tokens.thinking' "$SIGNAL_DIR/signal.json")

[ "$INPUT_TOK"  -eq 370 ] || fail "input tokens: expected 370, got $INPUT_TOK"
[ "$OUTPUT_TOK" -eq 120 ] || fail "output tokens: expected 120, got $OUTPUT_TOK"
[ "$THINK_TOK"  -eq 15  ] || fail "thinking tokens: expected 15, got $THINK_TOK"

echo "PASS  token extraction: input=$INPUT_TOK output=$OUTPUT_TOK thinking=$THINK_TOK"
```

Make it executable:
```bash
chmod +x .claude/plugins/darwin/hooks/tests/subagent-stop.test.sh
```

- [ ] **Step 3: Run the test, confirm it fails**

```bash
bash .claude/plugins/darwin/hooks/tests/subagent-stop.test.sh
```
Expected: FAIL (current filter only matches top-level `.usage`; the first two transcript lines have `.message.usage` and are missed, yielding input=50 not 370)

- [ ] **Step 4: Fix subagent-stop.sh — handle both .usage and .message.usage**

In `.claude/plugins/darwin/hooks/subagent-stop.sh`, replace the jq block:

Old:
```bash
  read -r AGENT_INPUT AGENT_OUTPUT AGENT_THINKING < <(jq -nr '
    reduce inputs as $line (
      {input: 0, output: 0, thinking: 0};
      if ($line | has("usage")) then
        .input    += ($line.usage.input_tokens    // 0 | floor) |
        .output   += ($line.usage.output_tokens   // 0 | floor) |
        .thinking += ($line.usage.thinking_tokens // 0 | floor)
      else . end
    ) | [.input, .output, .thinking] | @tsv
  ' "$TRANSCRIPT_PATH")
```

New:
```bash
  read -r AGENT_INPUT AGENT_OUTPUT AGENT_THINKING < <(jq -nr '
    reduce inputs as $line (
      {input: 0, output: 0, thinking: 0};
      ($line.usage // $line.message.usage // null) as $u |
      if $u != null then
        .input    += ($u.input_tokens    // 0 | floor) |
        .output   += ($u.output_tokens   // 0 | floor) |
        .thinking += ($u.thinking_tokens // 0 | floor)
      else . end
    ) | [.input, .output, .thinking] | @tsv
  ' "$TRANSCRIPT_PATH")
```

- [ ] **Step 5: Run the test, confirm it passes**

```bash
bash .claude/plugins/darwin/hooks/tests/subagent-stop.test.sh
```
Expected: `PASS  token extraction: input=370 output=120 thinking=15`

- [ ] **Step 6: Add to smoke.sh**

In `tests/smoke.sh`, add after the built-in pairing section:

```bash
# ── 9. subagent-stop token extraction ────────────────────────────────────

echo ""
echo "--- 9. subagent-stop token extraction"
if bash "$PLUGIN/hooks/tests/subagent-stop.test.sh" 2>/dev/null; then
  ok "subagent-stop: token extraction from fixture transcript"
else
  fail "subagent-stop: token extraction failed — run hooks/tests/subagent-stop.test.sh for details"
fi
```

- [ ] **Step 7: Run full smoke test**

```bash
bash tests/smoke.sh
```
Expected: all checks pass

- [ ] **Step 8: Commit**

```bash
git add .claude/plugins/darwin/hooks/subagent-stop.sh \
        .claude/plugins/darwin/hooks/tests/subagent-stop.test.sh \
        .claude/plugins/darwin/hooks/tests/fixtures/transcript-sample.jsonl \
        tests/smoke.sh
git commit -m "fix: subagent-stop handles nested .message.usage in transcript; add fixture test"
```

---

### Task 4: plan-software — session resume with explicit state schema

Add a concrete state file schema and save/resume instructions to the `plan-software` skill so a session can be interrupted at any phase boundary and resumed without re-answering questions.

**Files:**
- Modify: `.claude/plugins/darwin/skills/plan-software/SKILL.md`

- [ ] **Step 1: Replace the Stopping and Resuming section**

In `.claude/plugins/darwin/skills/plan-software/SKILL.md`, find and replace the entire `## Stopping and Resuming` section at the bottom of the file.

Old content:
```markdown
## Stopping and Resuming

If the user says "stop" or "save progress" at any phase boundary, write `.plan-software-state.json` to the plan directory capturing all answers so far. Tell the user to run `/darwin:plan-software --resume <plan-dir>` to continue.

If invoked with `--resume <plan-dir>`, read `.plan-software-state.json`, show a one-line summary of what was captured, and continue from the last incomplete phase.
```

New content:
```markdown
## Stopping and Resuming

### Saving state

When the user says "stop", "save", or "save progress" at any phase boundary, write `<plan-dir>/.plan-software-state.json` and respond:

```
Saved. Resume with: /darwin:plan-software --resume <plan-dir>
```

**State file schema** — mirrors the Structurizr DSL hierarchy (`workspace → model → softwareSystem → container → component`). Write all keys collected so far; omit sections not yet reached.

```json
{
  "version": 1,
  "last_completed_phase": "Gather project details",
  "completed_phases": ["Explore existing plans", "Gather project details"],
  "workspace": {
    "name": "Payment Service",
    "identifier": "payment-service",
    "plan_dir": "plans/payment-service",
    "description": "Processes card payments for merchants"
  },
  "model": {
    "persons": [
      { "name": "Merchant", "identifier": "merchant", "description": "Business owner accepting payments" }
    ],
    "softwareSystems": [
      {
        "name": "Payment Service",
        "identifier": "payment-service",
        "description": "Core payment platform",
        "external": false,
        "containers": [
          {
            "name": "API",
            "identifier": "api",
            "technology": "Node.js",
            "description": "REST API",
            "tags": ["service"],
            "components": [
              { "name": "PaymentAdapter", "identifier": "payment-adapter", "description": "Stripe integration" }
            ]
          }
        ]
      },
      {
        "name": "Stripe",
        "identifier": "stripe",
        "description": "Payment processing API",
        "external": true
      }
    ]
  },
  "assets": {
    "api": { "type": "impl+tests", "pairing": "payment-service" },
    "payment-adapter": { "type": "impl", "pairing": "payment-service" }
  }
}
```

Field notes:
- `workspace.identifier` — the DSL workspace identifier used in `workspace "<identifier>"` and Darwin branch names
- `workspace.description` — maps to DSL `description` property
- `model.persons` — DSL `person` elements (users/actors); prose-only, no tasks
- `model.softwareSystems` — DSL `softwareSystem` elements; `external: true` for third-party systems
- `containers[].tags` — DSL `tags` values; Darwin uses `app`, `service`, `worker`, `store`, `gateway` to determine task eligibility
- `containers[].technology` — DSL `technology` property
- `assets` — Darwin-specific; keyed by `identifier`, drives which `.adoc` stubs and pairings are generated

Valid `type` values: `impl`, `impl+tests`, `impl+tests+bdd`, `tests`, `skip`.

### Resuming

When invoked as `/darwin:plan-software --resume <plan-dir>`:

1. Read `<plan-dir>/.plan-software-state.json`
2. If the file does not exist, say: `No saved state at <plan-dir>/.plan-software-state.json — starting fresh.` and begin from phase 1
3. Otherwise, show: `Resuming <workspace.name> — last completed: <last_completed_phase>`
4. Mark all phases in `completed_phases` as done in TaskCreate
5. Continue from the next phase after `last_completed_phase`, treating all saved values as already-answered (skip those questions)
```

- [ ] **Step 2: Verify the replacement landed correctly**

```bash
grep -c "last_completed_phase\|softwareSystems\|workspace.identifier\|Resuming" \
  .claude/plugins/darwin/skills/plan-software/SKILL.md
```
Expected: 4

- [ ] **Step 3: Confirm smoke tests still pass (skill frontmatter unchanged)**

```bash
bash tests/smoke.sh 2>&1 | grep "plan-software"
```
Expected:
```
PASS  skill plan-software: SKILL.md has frontmatter
PASS  skill plan-software: SKILL.md has name field
```

- [ ] **Step 4: Commit**

```bash
git add .claude/plugins/darwin/skills/plan-software/SKILL.md
git commit -m "feat: plan-software --resume with explicit state file schema"
```
