# Darwin Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Darwin Claude Code plugin — the hooks, `token-delta` helper, and skill files that turn a Claude Code session into the Ralph loop controller.

**Architecture:** The plugin lives at `~/.claude/plugins/darwin/`. Shell hooks (WorktreeCreate, SubagentStop) handle worktree creation and signal writing. The `token-delta` TypeScript helper computes token deltas between snapshots. Two markdown skill files (`darwin-init.md`, `darwin-worktree.md`) contain the natural-language instructions Claude Code follows as the controller. No daemon, no SDK loop — Claude Code is the controller.

**Tech Stack:** Bash (hooks, scripts), TypeScript/ESM (token-delta helper; compiled by the same build config as the C4 adapter), vitest 2.x for TS tests, plain shell assertions for hook tests. macOS: Seatbelt sandbox. Linux/WSL2: bubblewrap.

**Prerequisite:** The C4 adapter plan (`docs/darwin/plans/2026-05-03-r14-c4-adapter.md`) must be completed first. It creates `package.json`, `tsconfig.json`, `vitest.config.ts`, `scripts/detect-runtime.sh`, `scripts/rt.sh`, and the five TypeScript helpers. Before starting this plan, verify:

```bash
ls ~/.claude/plugins/darwin/bin/parse-index.js   # C4 adapter output
ls ~/.claude/darwin-state/runtime.json            # detect-runtime.sh output
```

Note: the C4 adapter plan puts runtime scripts in `scripts/`; the design spec places them in `helpers/c4/`. Either location works as long as the `darwin-worktree.md` skill references the correct paths. This plan uses `helpers/c4/` per the design spec; adjust if you kept `scripts/`.

---

## File Map

| File | Status | Responsibility |
|------|--------|----------------|
| `~/.claude/plugins/darwin/hooks/hooks.json` | Create | Registers WorktreeCreate + SubagentStop hooks |
| `~/.claude/plugins/darwin/hooks/worktree-create.sh` | Create | Reads manifest; creates sparse worktree; injects `.claude/`; marks skip-worktree |
| `~/.claude/plugins/darwin/hooks/subagent-stop.sh` | Create | Reads transcript; extracts token usage; writes signal.json |
| `~/.claude/plugins/darwin/hooks/tests/worktree-create.test.sh` | Create | Shell assertions for worktree-create.sh |
| `~/.claude/plugins/darwin/hooks/tests/subagent-stop.test.sh` | Create | Shell assertions for subagent-stop.sh |
| `~/.claude/plugins/darwin/helpers/c4/src/token-delta.ts` | Create | Pure delta function + CLI entry point |
| `~/.claude/plugins/darwin/helpers/c4/tests/token-delta.test.ts` | Create | vitest unit tests |
| `~/.claude/plugins/darwin/helpers/c4/bin/token-delta.js` | Compiled | Output of `tsc` build |
| `~/.claude/plugins/darwin/skills/darwin-init.md` | Create | `/darwin-init` skill — runtime detection, gitignore, pairing validation |
| `~/.claude/plugins/darwin/skills/darwin-worktree.md` | Create | `/darwin-worktree` skill — full Ralph loop controller |

---

## Task 0: Plugin directory structure and hooks manifest

Creates the `hooks/`, `skills/`, and `helpers/c4/` directories and registers the two hooks.

**Files:**
- Create: `~/.claude/plugins/darwin/hooks/hooks.json`
- Create: `~/.claude/plugins/darwin/hooks/tests/` (directory)
- Create: `~/.claude/plugins/darwin/skills/` (directory)

- [ ] **Step 1: Create directory tree**

```bash
PLUGIN="$HOME/.claude/plugins/darwin"
mkdir -p "$PLUGIN/hooks/tests"
mkdir -p "$PLUGIN/skills"
mkdir -p "$PLUGIN/helpers/c4/src"
mkdir -p "$PLUGIN/helpers/c4/bin"
mkdir -p "$PLUGIN/helpers/c4/tests"
```

Run: `ls ~/.claude/plugins/darwin/`
Expected: `hooks/  helpers/  skills/` directories present.

- [ ] **Step 2: Create `hooks/hooks.json`**

```json
{
  "hooks": {
    "WorktreeCreate": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/worktree-create.sh\"",
            "async": false
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/subagent-stop.sh\"",
            "async": false
          }
        ]
      }
    ]
  }
}
```

Run: `cat ~/.claude/plugins/darwin/hooks/hooks.json | jq .`
Expected: Valid JSON with WorktreeCreate and SubagentStop keys.

- [ ] **Step 3: Commit**

```bash
cd ~/.claude/plugins/darwin
git add hooks/hooks.json
git commit -m "feat(darwin): plugin directory structure and hook manifest"
```

---

## Task 1: token-delta TypeScript helper

A pure-function CLI that computes the difference between two token snapshots. Used by the controller to quantify the cost of each attempt node.

**Files:**
- Create: `~/.claude/plugins/darwin/helpers/c4/src/token-delta.ts`
- Create: `~/.claude/plugins/darwin/helpers/c4/tests/token-delta.test.ts`
- Compiled: `~/.claude/plugins/darwin/helpers/c4/bin/token-delta.js`

- [ ] **Step 1: Write the failing tests**

```typescript
// ~/.claude/plugins/darwin/helpers/c4/tests/token-delta.test.ts
import { describe, it, expect } from 'vitest';
import { computeDelta } from '../src/token-delta.js';

describe('computeDelta', () => {
  it('computes positive deltas for a thinking-model attempt', () => {
    const before = { input: 1000, output: 200, thinking: 0 };
    const after  = { input: 3500, output: 800, thinking: 500 };
    expect(computeDelta(before, after)).toEqual({
      input_delta:   2500,
      output_delta:  600,
      thinking_delta: 500,
    });
  });

  it('returns zero deltas for identical snapshots', () => {
    const snap = { input: 1000, output: 200, thinking: 100 };
    expect(computeDelta(snap, snap)).toEqual({
      input_delta: 0, output_delta: 0, thinking_delta: 0,
    });
  });

  it('thinking_delta is 0 for non-thinking model', () => {
    const before = { input: 500,  output: 100, thinking: 0 };
    const after  = { input: 2000, output: 400, thinking: 0 };
    expect(computeDelta(before, after)).toEqual({
      input_delta: 1500, output_delta: 300, thinking_delta: 0,
    });
  });

  it('handles a later attempt with larger input from growing experience brief', () => {
    const before = { input: 38000, output: 5000, thinking: 0 };
    const after  = { input: 44800, output: 6200, thinking: 0 };
    expect(computeDelta(before, after)).toEqual({
      input_delta: 6800, output_delta: 1200, thinking_delta: 0,
    });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd ~/.claude/plugins/darwin
./helpers/c4/rt.sh test helpers/c4/tests/token-delta.test.ts
```

Expected: FAIL — `Cannot find module '../src/token-delta.js'`

- [ ] **Step 3: Write the implementation**

```typescript
// ~/.claude/plugins/darwin/helpers/c4/src/token-delta.ts
export interface TokenSnapshot {
  input: number;
  output: number;
  thinking: number;
}

export interface TokenDelta {
  input_delta: number;
  output_delta: number;
  thinking_delta: number;
}

export function computeDelta(before: TokenSnapshot, after: TokenSnapshot): TokenDelta {
  return {
    input_delta:   after.input   - before.input,
    output_delta:  after.output  - before.output,
    thinking_delta: after.thinking - before.thinking,
  };
}

// CLI entry point: reads JSON array [before, after] from stdin, writes delta to stdout
const chunks: Buffer[] = [];
process.stdin.on('data', (c: Buffer) => chunks.push(c));
process.stdin.on('end', () => {
  const [before, after] = JSON.parse(
    Buffer.concat(chunks).toString('utf8')
  ) as [TokenSnapshot, TokenSnapshot];
  process.stdout.write(JSON.stringify(computeDelta(before, after)) + '\n');
});
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd ~/.claude/plugins/darwin
./helpers/c4/rt.sh test helpers/c4/tests/token-delta.test.ts
```

Expected: PASS — 4 tests passing.

- [ ] **Step 5: Verify the CLI works end-to-end**

```bash
cd ~/.claude/plugins/darwin
./helpers/c4/rt.sh run build   # compiles all src/ to bin/
echo '[{"input":1000,"output":200,"thinking":0},{"input":3500,"output":800,"thinking":500}]' \
  | node helpers/c4/bin/token-delta.js
```

Expected: `{"input_delta":2500,"output_delta":600,"thinking_delta":500}`

- [ ] **Step 6: Commit**

```bash
cd ~/.claude/plugins/darwin
git add helpers/c4/src/token-delta.ts helpers/c4/tests/token-delta.test.ts helpers/c4/bin/token-delta.js
git commit -m "feat(darwin): token-delta helper — compute per-attempt token cost delta"
```

---

## Task 2: SubagentStop hook

Reads the subagent's transcript, sums token usage across all API turns, and writes `signal.json` so the controller can read agent token counts after the subagent completes.

**Files:**
- Create: `~/.claude/plugins/darwin/hooks/subagent-stop.sh`
- Create: `~/.claude/plugins/darwin/hooks/tests/subagent-stop.test.sh`

**Context:** Claude Code calls this hook when a subagent session ends. It receives JSON on stdin including `cwd` (the worktree path) and `transcript_path` (path to the session transcript JSONL). The transcript format is JSONL — each line is a JSON object; API response turns carry a `usage` key with `input_tokens`, `output_tokens`, and optionally `thinking_tokens`.

- [ ] **Step 1: Create `hooks/subagent-stop.sh`**

```bash
#!/usr/bin/env bash
# SubagentStop hook: extracts token usage from transcript; writes signal.json.
set -euo pipefail

INPUT=$(cat)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')

if [ -z "$CWD" ]; then
  echo "subagent-stop: missing cwd in hook input" >&2
  exit 1
fi

WORKTREE_BASE="$HOME/.claude/darwin-worktrees"
SIGNAL_BASE="$HOME/.claude/darwin-state"

# Derive <repo-hash>/<task-slug> from cwd
RELATIVE="${CWD#"$WORKTREE_BASE/"}"
SIGNAL_DIR="$SIGNAL_BASE/$RELATIVE"
mkdir -p "$SIGNAL_DIR"

# Sum token usage across all API turns in the transcript.
# Transcript is JSONL; each line is a message/event object.
# Usage lives at .usage.{input_tokens,output_tokens,thinking_tokens}.
AGENT_INPUT=0
AGENT_OUTPUT=0
AGENT_THINKING=0

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  while IFS= read -r line; do
    has_usage=$(printf '%s' "$line" | jq 'has("usage")' 2>/dev/null || echo "false")
    if [ "$has_usage" = "true" ]; then
      inp=$(printf '%s' "$line" | jq '.usage.input_tokens    // 0')
      out=$(printf '%s' "$line" | jq '.usage.output_tokens   // 0')
      think=$(printf '%s' "$line" | jq '.usage.thinking_tokens // 0')
      AGENT_INPUT=$(( AGENT_INPUT   + inp   ))
      AGENT_OUTPUT=$(( AGENT_OUTPUT  + out   ))
      AGENT_THINKING=$(( AGENT_THINKING + think ))
    fi
  done < "$TRANSCRIPT_PATH"
fi

# Write signal.json — controller reads this after SubagentStop fires.
jq -n \
  --arg cwd            "$CWD" \
  --arg transcript     "${TRANSCRIPT_PATH:-}" \
  --argjson inp        "$AGENT_INPUT" \
  --argjson out        "$AGENT_OUTPUT" \
  --argjson thinking   "$AGENT_THINKING" \
  '{
    cwd:             $cwd,
    transcript_path: $transcript,
    agent_tokens: {
      input:    $inp,
      output:   $out,
      thinking: $thinking
    }
  }' > "$SIGNAL_DIR/signal.json"

echo "subagent-stop: signal written to $SIGNAL_DIR/signal.json" >&2
```

```bash
chmod +x ~/.claude/plugins/darwin/hooks/subagent-stop.sh
```

- [ ] **Step 2: Create shell test with a mock transcript**

```bash
#!/usr/bin/env bash
# ~/.claude/plugins/darwin/hooks/tests/subagent-stop.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/subagent-stop.sh"
WORKTREE_BASE="$HOME/.claude/darwin-worktrees"
SIGNAL_BASE="$HOME/.claude/darwin-state"
TEST_REPO="testrepo123"
TEST_SLUG="auth-rs256"

# ── Setup ──────────────────────────────────────────────────────────────────
WORKTREE_PATH="$WORKTREE_BASE/$TEST_REPO/$TEST_SLUG"
TRANSCRIPT_FILE="$(mktemp /tmp/transcript-XXXXX.jsonl)"
SIGNAL_PATH="$SIGNAL_BASE/$TEST_REPO/$TEST_SLUG/signal.json"

mkdir -p "$WORKTREE_PATH"

# Write a mock transcript with three API turns carrying usage
cat > "$TRANSCRIPT_FILE" <<'EOF'
{"type":"message","role":"user","content":"start"}
{"type":"message","role":"assistant","content":"ok","usage":{"input_tokens":1000,"output_tokens":200,"thinking_tokens":0}}
{"type":"message","role":"user","content":"continue"}
{"type":"message","role":"assistant","content":"done","usage":{"input_tokens":1200,"output_tokens":300,"thinking_tokens":150}}
{"type":"message","role":"assistant","content":"final","usage":{"input_tokens":100,"output_tokens":50,"thinking_tokens":0}}
EOF

# ── Run hook ───────────────────────────────────────────────────────────────
INPUT=$(jq -n \
  --arg cwd "$WORKTREE_PATH" \
  --arg transcript "$TRANSCRIPT_FILE" \
  '{cwd: $cwd, transcript_path: $transcript}')

printf '%s' "$INPUT" | bash "$HOOK"

# ── Assertions ─────────────────────────────────────────────────────────────
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$SIGNAL_PATH" ] || fail "signal.json not created at $SIGNAL_PATH"

agent_input=$(jq '.agent_tokens.input' "$SIGNAL_PATH")
agent_output=$(jq '.agent_tokens.output' "$SIGNAL_PATH")
agent_thinking=$(jq '.agent_tokens.thinking' "$SIGNAL_PATH")

[ "$agent_input"   = "2300" ] || fail "input tokens: expected 2300, got $agent_input"
[ "$agent_output"  = "550"  ] || fail "output tokens: expected 550, got $agent_output"
[ "$agent_thinking" = "150" ] || fail "thinking tokens: expected 150, got $agent_thinking"

cwd_in_signal=$(jq -r '.cwd' "$SIGNAL_PATH")
[ "$cwd_in_signal" = "$WORKTREE_PATH" ] || fail "cwd mismatch in signal.json"

# ── Cleanup ────────────────────────────────────────────────────────────────
rm -f "$TRANSCRIPT_FILE"
rm -rf "$SIGNAL_BASE/$TEST_REPO"
rmdir "$WORKTREE_PATH" 2>/dev/null || true

echo "PASS: subagent-stop.sh"
```

```bash
chmod +x ~/.claude/plugins/darwin/hooks/tests/subagent-stop.test.sh
```

- [ ] **Step 3: Run the test**

```bash
bash ~/.claude/plugins/darwin/hooks/tests/subagent-stop.test.sh
```

Expected: `PASS: subagent-stop.sh`

- [ ] **Step 4: Test missing transcript (graceful handling)**

```bash
INPUT=$(jq -n --arg cwd "$HOME/.claude/darwin-worktrees/norepo/notask" '{cwd: $cwd}')
mkdir -p "$HOME/.claude/darwin-worktrees/norepo/notask"
printf '%s' "$INPUT" | bash ~/.claude/plugins/darwin/hooks/subagent-stop.sh
cat "$HOME/.claude/darwin-state/norepo/notask/signal.json"
```

Expected: signal.json created with `agent_tokens: {input:0, output:0, thinking:0}`.

Clean up:
```bash
rm -rf "$HOME/.claude/darwin-state/norepo" "$HOME/.claude/darwin-worktrees/norepo"
```

- [ ] **Step 5: Commit**

```bash
cd ~/.claude/plugins/darwin
git add hooks/subagent-stop.sh hooks/tests/subagent-stop.test.sh
git commit -m "feat(darwin): SubagentStop hook — transcript token extraction + signal.json"
```

---

## Task 3: WorktreeCreate hook

Creates the sparse worktree, injects `.claude/` contents from the pairing's agent template, and marks injected files as `skip-worktree`. Reads a manifest written by the controller before the hook fires.

**Files:**
- Create: `~/.claude/plugins/darwin/hooks/worktree-create.sh`
- Create: `~/.claude/plugins/darwin/hooks/tests/worktree-create.test.sh`

**Context:** The controller writes `~/.claude/darwin-state/<repo-hash>/<task-slug>/manifest.json` before calling the Agent tool (which triggers WorktreeCreate). The hook receives JSON on stdin from Claude Code — at minimum a `path` field containing the planned worktree path. Implementation note: verify the exact stdin field name at implementation time against the Claude Code hook documentation; adjust `jq` path if it differs (e.g., `.worktree_path`, `.name`).

- [ ] **Step 1: Create `hooks/worktree-create.sh`**

```bash
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
SIGNAL_BASE="$HOME/.claude/darwin-state"
RELATIVE="${WORKTREE_PATH#"$WORKTREE_BASE/"}"
REPO_HASH="${RELATIVE%%/*}"
TASK_SLUG="${RELATIVE#*/}"
MANIFEST_PATH="$SIGNAL_BASE/$REPO_HASH/$TASK_SLUG/manifest.json"

if [ ! -f "$MANIFEST_PATH" ]; then
  echo "worktree-create: manifest not found at $MANIFEST_PATH" >&2
  exit 1
fi

PROJECT_ROOT=$(jq -r '.project_root' "$MANIFEST_PATH")
BASE_REF=$(jq -r '.base_ref // "HEAD"' "$MANIFEST_PATH")
BRANCH=$(jq -r '.branch' "$MANIFEST_PATH")
AGENT_TEMPLATE_PATH=$(jq -r '.agent_template_path // empty' "$MANIFEST_PATH")

# Create worktree with a new branch, no checkout yet
mkdir -p "$(dirname "$WORKTREE_PATH")"
git -C "$PROJECT_ROOT" worktree add --no-checkout -b "$BRANCH" "$WORKTREE_PATH" "$BASE_REF"

# Configure sparse checkout (non-cone mode for glob support)
git -C "$WORKTREE_PATH" sparse-checkout init --no-cone

# Populate patterns from manifest (writable_globs + readonly_globs)
{
  jq -r '.writable_globs // [] | .[]' "$MANIFEST_PATH"
  jq -r '.readonly_globs  // [] | .[]' "$MANIFEST_PATH"
} | git -C "$WORKTREE_PATH" sparse-checkout set --stdin

git -C "$WORKTREE_PATH" checkout

# Inject .claude/ from agent template if provided
mkdir -p "$WORKTREE_PATH/.claude/agents"
if [ -n "$AGENT_TEMPLATE_PATH" ] && [ -d "$AGENT_TEMPLATE_PATH" ]; then
  cp -r "$AGENT_TEMPLATE_PATH/." "$WORKTREE_PATH/.claude/"
fi

# Populate sandbox.filesystem.allowWrite from manifest writable_globs.
# The agent template may already have a settings.json with pairing-level permissions.allow/deny;
# we only override the allowWrite list so those pairing-specific rules are preserved.
WRITABLE=$(jq '.writable_globs // []' "$MANIFEST_PATH")
if [ -f "$WORKTREE_PATH/.claude/settings.json" ]; then
  # Merge: patch just allowWrite into the existing template config
  jq --argjson w "$WRITABLE" \
    '.sandbox.filesystem.allowWrite = $w' \
    "$WORKTREE_PATH/.claude/settings.json" > /tmp/darwin-settings-tmp.json
  mv /tmp/darwin-settings-tmp.json "$WORKTREE_PATH/.claude/settings.json"
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
  }' > "$WORKTREE_PATH/.claude/settings.json"
fi

# Mark injected files skip-worktree so agent edits don't propagate to other branches
for fname in "settings.json" "CLAUDE.md"; do
  fpath="$WORKTREE_PATH/.claude/$fname"
  if [ -f "$fpath" ]; then
    git -C "$WORKTREE_PATH" update-index --skip-worktree ".claude/$fname"
  fi
done
if [ -d "$WORKTREE_PATH/.claude/agents" ]; then
  for fpath in "$WORKTREE_PATH/.claude/agents/"*; do
    [ -f "$fpath" ] || continue
    git -C "$WORKTREE_PATH" update-index --skip-worktree ".claude/agents/$(basename "$fpath")"
  done
fi

# Return absolute worktree path to Claude Code on stdout
echo "$WORKTREE_PATH"
```

```bash
chmod +x ~/.claude/plugins/darwin/hooks/worktree-create.sh
```

- [ ] **Step 2: Create shell test**

```bash
#!/usr/bin/env bash
# ~/.claude/plugins/darwin/hooks/tests/worktree-create.test.sh
# Tests hook behaviour with a real (temp) git repo.
set -euo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/worktree-create.sh"
SIGNAL_BASE="$HOME/.claude/darwin-state"
WORKTREE_BASE="$HOME/.claude/darwin-worktrees"

fail() { echo "FAIL: $1" >&2; exit 1; }

# ── Setup: bare project repo ───────────────────────────────────────────────
PROJECT_DIR=$(mktemp -d /tmp/darwin-test-project-XXXXX)
git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.email "test@test.com"
git -C "$PROJECT_DIR" config user.name  "Test"
echo "hello" > "$PROJECT_DIR/src/main.ts"
mkdir -p "$PROJECT_DIR/src"
echo "export const x = 1;" > "$PROJECT_DIR/src/main.ts"
git -C "$PROJECT_DIR" add .
git -C "$PROJECT_DIR" commit -q -m "init"

# Fake agent template
TEMPLATE_DIR=$(mktemp -d /tmp/darwin-test-template-XXXXX)
echo "# Task CLAUDE.md" > "$TEMPLATE_DIR/CLAUDE.md"
mkdir -p "$TEMPLATE_DIR/agents"
echo "# agent def" > "$TEMPLATE_DIR/agents/task-agent.md"

REPO_HASH="testhash01"
TASK_SLUG="auth-impl"
WORKTREE_PATH="$WORKTREE_BASE/$REPO_HASH/$TASK_SLUG"
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

# Verify skip-worktree bit is set on injected files
skip=$(git -C "$WORKTREE_PATH" ls-files -v .claude/CLAUDE.md | cut -c1)
[ "$skip" = "S" ] || fail ".claude/CLAUDE.md skip-worktree not set (got: $skip)"

# Verify settings.json has allowWrite populated from manifest writable_globs
[ -f "$WORKTREE_PATH/.claude/settings.json" ] || fail "settings.json not present after sandbox config generation"
allow_write=$(jq -r '.sandbox.filesystem.allowWrite[0]' "$WORKTREE_PATH/.claude/settings.json")
[ "$allow_write" = "src/main.ts" ] || fail "sandbox allowWrite not populated from writable_globs; got: $allow_write"

# ── Cleanup ────────────────────────────────────────────────────────────────
git -C "$PROJECT_DIR" worktree remove --force "$WORKTREE_PATH" 2>/dev/null || true
rm -rf "$PROJECT_DIR" "$TEMPLATE_DIR" \
       "$SIGNAL_BASE/$REPO_HASH" "$WORKTREE_BASE/$REPO_HASH"

echo "PASS: worktree-create.sh"
```

```bash
chmod +x ~/.claude/plugins/darwin/hooks/tests/worktree-create.test.sh
```

- [ ] **Step 3: Run the test**

```bash
bash ~/.claude/plugins/darwin/hooks/tests/worktree-create.test.sh
```

Expected: `PASS: worktree-create.sh`

- [ ] **Step 4: Commit**

```bash
cd ~/.claude/plugins/darwin
git add hooks/worktree-create.sh hooks/tests/worktree-create.test.sh
git commit -m "feat(darwin): WorktreeCreate hook — sparse worktree + .claude/ injection"
```

---

## Task 4: darwin-init skill file

The `/darwin-init` skill runs once per project. It detects the JS runtime, seeds `.gitignore`, validates pairings, and checks the escalation ladder.

**Files:**
- Create: `~/.claude/plugins/darwin/skills/darwin-init.md`

- [ ] **Step 1: Write `skills/darwin-init.md`**

```markdown
# /darwin-init

Initialize a project for use with Darwin. Follow these steps in order. Stop and report any error before proceeding to the next step.

---

## Step 1: Detect JS runtime

Run:
```bash
bash ~/.claude/plugins/darwin/helpers/c4/detect-runtime.sh
```

If the script fails or exits non-zero, stop and report: "No supported JS runtime found. Install Bun, Node.js 20+, or Deno before running /darwin-init."

Verify the result:
```bash
cat ~/.claude/darwin-state/runtime.json
```

Expected: a JSON object with keys `runtime`, `exec`, `pm`, `run_flags`.

---

## Step 2: Update .gitignore

Read the project `.gitignore`. For each of the following lines that is NOT already present, append it:

```
.claude/settings.json
.claude/agents/
.claude/CLAUDE.md
.claude/escalation-ladder.json
```

Use the Edit tool to make any additions. Do not remove existing content.

---

## Step 3: Validate pairings

List all pairing files:
```bash
ls .claude/darwin-pairings/*/pairing.yaml 2>/dev/null || echo "(none)"
```

For each `pairing.yaml` found:

**3a. Required fields.** Parse the YAML using `cat`. Verify these keys are present at the top level: `name`, `agent`, `evals`. If any are missing, record: "Pairing <filename>: missing required field(s): <list>."

**3b. Judge-model separation.** For each eval entry with `type: rubric`:
- Read its `judge_model` value.
- Read `~/.claude/escalation-ladder.json` and collect all `ladder[].model` values.
- If `judge_model` matches any ladder model, record: "Pairing <name>: judge-model separation violation — judge_model '<model>' appears in escalation ladder."

**3c. Slug uniqueness.** Collect all `name` values across all pairings. If any value appears more than once, record: "Duplicate pairing name: '<name>'."

If any errors were recorded, print them all and stop with: "Pairing validation failed. Fix the errors above before running /darwin-worktree."

If no errors: "All pairings valid."

---

## Step 4: Verify escalation ladder

```bash
ls -l ~/.claude/escalation-ladder.json
```

If the file does not exist, stop with: "Escalation ladder not found. Create ~/.claude/escalation-ladder.json before running /darwin-worktree."

If it exists, read the `ladder_id` field:
```bash
jq -r '.ladder_id' ~/.claude/escalation-ladder.json
```

The value is an ISO-8601 timestamp. Compute the age in days. If age > 30, warn: "Escalation ladder may be stale (ladder_id: <id>, <N> days old). Consider regenerating."

---

## Step 5: Report summary

Print:
```
Darwin initialized.
  Runtime:  <runtime> <version>
  Pairings: <N> valid pairing(s) from .claude/darwin-pairings/
  Ladder:   <ladder_id> (<N> days old)
  Status:   Ready
```

Where `<version>` comes from `<exec> --version` using the detected runtime.
```

- [ ] **Step 2: Verify against spec checklist**

Read `docs/darwin/specs/2026-05-04-darwin-plugin-design.md` Section 2 (`/darwin-init` bullet points). Confirm each point is covered:
- [ ] Runtime detection with `detect-runtime.sh` ✓
- [ ] `.claude/settings.json`, `.claude/agents/`, `.claude/CLAUDE.md` added to `.gitignore` ✓
- [ ] `darwin-pairings/*/pairing.yaml` validated: schema, judge-model separation, slug uniqueness ✓
- [ ] `escalation-ladder.json` existence + staleness check ✓
- [ ] Summary report ✓

- [ ] **Step 3: Commit**

```bash
cd ~/.claude/plugins/darwin
git add skills/darwin-init.md
git commit -m "feat(darwin): darwin-init skill — runtime detection, pairing validation"
```

---

## Task 5: darwin-worktree skill — entry, parsing, task queue, state reconstruction

The `/darwin-worktree` skill is the main Ralph loop controller. This task writes its first half: argument parsing, plan parsing, asset loading, co-evolving pair detection, task queue construction, and per-task state reconstruction from Git.

**Files:**
- Create: `~/.claude/plugins/darwin/skills/darwin-worktree.md` (this task: preamble through state reconstruction)

- [ ] **Step 1: Write the preamble and entry section of `skills/darwin-worktree.md`**

```markdown
# /darwin-worktree

You are the Darwin parent controller — a Claude Code session following these instructions. Drive the Ralph loop to completion for all tasks in the plan. Do not delegate decisions to the agent or to evaluators. You own the loop.

---

## Prerequisites

Before running any loop steps, verify:
```bash
cat ~/.claude/darwin-state/runtime.json
```
If this fails, tell the user to run `/darwin-init` first.

---

## Usage

```
/darwin-worktree <plan.adoc> [--base <ref>] [--resume <slug>]
/darwin-worktree --c4 <plan-dir> [--base <ref>] [--resume <slug>]
```

- `<plan.adoc>` — path to an AsciiDoc plan file, or a directory containing `index.adoc`.
- `--base <ref>` — base git ref for new agent branches. Defaults to `HEAD`.
- `--resume <slug>` — re-enter the loop for a specific task slug (after a HANDOFF or context-limit stop).
- `--c4 <plan-dir>` — parse the plan in C4 format (embedded Structurizr DSL in `index.adoc`).

---

## Step 1: Parse the plan

Set shell variables:
```bash
EXEC=$(jq -r '.exec' ~/.claude/darwin-state/runtime.json)
FLAGS=$(jq -r '.run_flags // [] | join(" ")' ~/.claude/darwin-state/runtime.json)
PLUGIN="$HOME/.claude/plugins/darwin"
```

Parse `index.adoc` into an element tree:
```bash
$EXEC $FLAGS $PLUGIN/helpers/c4/bin/parse-index.js --file <plan.adoc>
```

Store the JSON result as ELEMENT_TREE. Each element has: `slug`, `type`, `properties` (object of key → filename or inline value), `children` (array of child elements).

If `--c4` was passed, the DSL block is embedded in `index.adoc`; `parse-index` handles this automatically.

---

## Step 2: Load asset configurations

For each element in ELEMENT_TREE that has at least one **asset-reference property** (`impl`, `tests`, `bdd`, `detail`):

For each such property:
1. Read the sibling `.adoc` file whose name is the property value (e.g., `impl: auth-impl.adoc` → read `auth-impl.adoc`).
2. Extract the `[task]` block — YAML content between the line `[task]` and the next AsciiDoc block delimiter or section title.
3. Parse: `pairing` (string, optional), `writable_globs` (list), `stop_criteria` (optional).

If `pairing` is absent from the `[task]` block, infer it:
| Element type | Property key | Default pairing |
|---|---|---|
| SoftwareSystem, Container, Component | `impl` | `implementer-with-tests` |
| any | `tests` | `test-author-with-meta-rubric` |
| any | `bdd` | `test-author-with-meta-rubric` |
| SoftwareSystem | `detail` | `doc-writer-with-checks` |

---

## Step 3: Detect co-evolving pairs

For each element: if it has BOTH a `tests:` property AND an `impl:` property, mark it as a **co-evolving pair**.

Co-evolving pairs run as concurrent Ralph loops. The tests gate (Step 10) is enforced before `impl` can pass.

---

## Step 4: Build task queue

Construct a queue of (element, property-key) task tuples:
- Elements in **unordered** AsciiDoc list (`*`) → add to parallel pool (fan out concurrently).
- Elements in **ordered** AsciiDoc list (`.`) → add to serial queue (sequence on upstream `●`).
- If an element has `depends_on:` in its `[task]` block, do not start it until all named upstream slugs are `●`.

Skip any task whose asset branch already has `Try-Status: pass` as its latest non-rollback commit.

If `--resume <slug>` was passed, only include the named task and its dependents.

---

## Step 5: Reconstruct per-task state

For each task, read Git trailer history from the task's branch:

```bash
git log agent/<slug> --format='%(trailers:only)' 2>/dev/null \
  | grep -E '^(Try-Status|Tier|Attempt|Pairing-Hash|Failure-Class|Eval-Id):'
```

Derive:
- `status` — latest `Try-Status` value (`pass`, `fail`, `rollback`, etc.), or `◌` if branch does not exist.
- `attempt_count` — number of commits where `Try-Status: fail`.
- `current_tier` — `Tier` value from the latest `fail` commit.
- `pairing_hash` — `Pairing-Hash` from the latest commit.
- `experience_brief` — ordered list of all `fail` trailer sets (problem, hypothesis, evidence); excludes rollback, infra-fail, widen commits.

Also read `[task-state]` from the plan `.adoc` file for crash-recovery fields (`signal_path`, `worktree_path`, `agent_name`).
```

- [ ] **Step 2: Verify this section against the spec**

Read `docs/darwin/specs/2026-05-04-darwin-plugin-design.md` Section 5 (Ralph Loop Data Flow), steps 1–3 of the loop kernel and the State Reconstruction block. Confirm every item is addressed. Fix any gaps before committing.

- [ ] **Step 3: Commit checkpoint**

```bash
cd ~/.claude/plugins/darwin
git add skills/darwin-worktree.md
git commit -m "feat(darwin): darwin-worktree skill — entry, plan parsing, task queue, state reconstruction"
```

---

## Task 6: darwin-worktree skill — loop kernel, eval pipeline, commit, crash recovery, context checkpoint

Appends the Ralph loop's inner mechanics to `darwin-worktree.md`: the 12-step kernel, token tracking, how to commit ⊗/● with trailers, crash/resume recovery, the 80% context checkpoint, and co-evolving pair logic.

**Files:**
- Modify: `~/.claude/plugins/darwin/skills/darwin-worktree.md` (append remaining sections)

- [ ] **Step 1: Append the loop kernel section**

Append to `skills/darwin-worktree.md`:

```markdown
---

## Step 6: Ralph loop kernel

Run the following 12-step kernel for each task. For parallel tasks, fan them out using concurrent Agent tool calls. For serial tasks, execute one at a time.

### 6.1 Load and verify pairing

```bash
cat <project-root>/.claude/darwin-pairings/<pairing-name>/pairing.yaml
```

Compute SHA-256 of the canonicalized pairing YAML (keys sorted, whitespace normalized):
```bash
python3 -c "
import json, hashlib, sys, yaml
data = yaml.safe_load(sys.stdin)
canon = json.dumps(data, sort_keys=True, separators=(',',':'))
print('sha256:' + hashlib.sha256(canon.encode()).hexdigest())
"
```

If the computed hash differs from `pairing_hash` in the task's state (and `pairing_hash` is not empty → this is not the first attempt), halt: "Pairing hash drift on task <slug> — pairing was edited mid-run. Restore the pinned version or migrate to a new branch. (R7.18)"

### 6.2 Build experience brief

From the `experience_brief` list derived in Step 5, format:

```
Prior attempts on this task (<slug>):

⊗ Attempt 1 [eval: <eval-id>]:
  <problem>
  hypothesis: <hypothesis>
  evidence: <evidence>

⊗ Attempt 2 [eval: <eval-id>]:
  ...
```

This brief is included in the agent's CLAUDE.md template (injected by WorktreeCreate).

### 6.3 Compute pre-spawn values deterministically

```bash
REPO_HASH=$(git -C <project-root> rev-parse --show-toplevel | md5sum | cut -c1-7)
WORKTREE_PATH="$HOME/.claude/darwin-worktrees/$REPO_HASH/<task-slug>"
SIGNAL_PATH="$HOME/.claude/darwin-state/$REPO_HASH/<task-slug>/signal.json"
AGENT_NAME="<task-slug>-attempt-<N>"   # N = attempt_count + 1
```

### 6.4 Write [task-state] — crash recovery commit point

Update the `[task-state]` block in the plan `.adoc`:

```
[task-state]
status: running
agent_name: <agent-name>
worktree_path: <worktree-path>
signal_path: <signal-path>
```

Commit this change to the plan file NOW, before calling the Agent tool. This is the crash recovery anchor — on resume, these paths allow the controller to locate the worktree and signal without re-deriving them.

```bash
git add <plan.adoc>
git commit -m "chore: task <slug> status → running (attempt <N>)"
```

### 6.5 Write manifest for WorktreeCreate hook

```bash
mkdir -p "$HOME/.claude/darwin-state/$REPO_HASH/<task-slug>"
cat > "$HOME/.claude/darwin-state/$REPO_HASH/<task-slug>/manifest.json" <<EOF
{
  "project_root":        "<absolute-path-to-project>",
  "base_ref":            "<base-ref>",
  "branch":              "agent/<slug>",
  "pairing_name":        "<pairing-name>",
  "writable_globs":      <from pairing.scope.writable_globs>,
  "readonly_globs":      <from pairing.scope.readonly_globs>,
  "agent_template_path": "<project>/.claude/darwin-pairings/<pairing>/agent-template"
}
EOF
```

### 6.6 Spawn subagent

Use the Agent tool with:
- `name:` set to `<agent-name>` (for transcript/log observability)
- `model:` set to the current tier's model ID from `~/.claude/escalation-ladder.json`
- Prompt derived from the pairing's agent template, with the experience brief inserted

The Agent tool blocks until the subagent stops. WorktreeCreate fires automatically. SubagentStop fires when the agent finishes.

### 6.7 Read signal and agent token counts

```bash
cat "$SIGNAL_PATH"
```

Extract: `agent_tokens.input`, `agent_tokens.output`, `agent_tokens.thinking`.

If no signal file exists and the worktree has staged changes, proceed to eval on the staged diff (crash-recovery path — see Step 7). If no signal and no staged changes, discard and retry.

### 6.8 Snapshot staged diff

```bash
git -C "$WORKTREE_PATH" diff --staged
```

This is the agent's proposed output. Pass it to the eval pipeline.

### 6.9 Run eval pipeline

For each eval in `pairing.evals` (in declared order, cheapest-first — do NOT reorder):

**Command eval:**
```bash
<eval.command> [args...]   # run in eval sandbox, timeout per eval config
# capture: exit_code, stdout, stderr
```
Result envelope: `{verdict: pass/fail, failure_class: validation-fail/infra-fail, consumes_attempt: true, problem: ..., hypothesis: ..., evidence: ...}`

**Rubric eval:**
Construct judge prompt: rubric text + artifact content. Call `judge_model` (from eval config). Parse response as JSON result envelope. Verify `evidence_quotes`: each quote string must appear verbatim as a substring of the artifact. If any quote fails the substring check, reject the verdict as potentially injected (R5.9a/R5.9b).

On **first failure**, short-circuit — do not run remaining evals.

Accumulate token counts from each eval's API response:
```
eval_input   += response.usage.input_tokens
eval_output  += response.usage.output_tokens
eval_thinking += response.usage.thinking_tokens   # 0 for non-thinking judges
```

### 6.10 Commit result with token trailers

**Pass (●):**
```bash
git -C "$WORKTREE_PATH" commit --allow-empty -m \
  "● <task-description> ◈ <model-short> (#<slug>)" \
  --trailer "Try-Status: pass" \
  --trailer "Task: <slug>" \
  --trailer "Pairing: <pairing-name>" \
  --trailer "Pairing-Hash: sha256:<hash>" \
  --trailer "Tier: <N>" \
  --trailer "Attempt: <N>" \
  --trailer "Model: <model-id>" \
  --trailer "Ladder-Id: <ladder-id>" \
  --trailer "Author-Type: agent" \
  --trailer "Evals-Passed: <comma-separated-eval-ids>" \
  --trailer "Agent-Input-Tokens: <agent_input>" \
  --trailer "Agent-Output-Tokens: <agent_output>" \
  --trailer "Agent-Thinking-Tokens: <agent_thinking>" \
  --trailer "Eval-Input-Tokens: <eval_input>" \
  --trailer "Eval-Output-Tokens: <eval_output>" \
  --trailer "Eval-Thinking-Tokens: <eval_thinking>"
```

Update `[task-state]` to `status: ●`. Task is done.

**Fail (⊗ then ↺):**
```bash
# Failure commit
git -C "$WORKTREE_PATH" commit --allow-empty -m \
  "⊗ <reason> ◈ <model-short> (<slug>)" \
  --trailer "Try-Status: fail" \
  --trailer "Task: <slug>" \
  --trailer "Pairing: <pairing-name>" \
  --trailer "Pairing-Hash: sha256:<hash>" \
  --trailer "Tier: <N>" \
  --trailer "Attempt: <N>" \
  --trailer "Attempt-At-Tier: <N>" \
  --trailer "Max-At-Tier: <from pairing circuit breakers>" \
  --trailer "Model: <model-id>" \
  --trailer "Ladder-Id: <ladder-id>" \
  --trailer "Author-Type: agent" \
  --trailer "Eval-Id: <failing-eval-id>" \
  --trailer "Eval-Type: <command|rubric|...>" \
  --trailer "Judge-Model: <judge-model or empty>" \
  --trailer "Failure-Class: <class>" \
  --trailer "Problem: <problem>" \
  --trailer "Hypothesis: <hypothesis>" \
  --trailer "Agent-Input-Tokens: <agent_input>" \
  --trailer "Agent-Output-Tokens: <agent_output>" \
  --trailer "Agent-Thinking-Tokens: <agent_thinking>" \
  --trailer "Eval-Input-Tokens: <eval_input>" \
  --trailer "Eval-Output-Tokens: <eval_output>" \
  --trailer "Eval-Thinking-Tokens: <eval_thinking>"

# Immediately follow with rollback (real inverse-diff commit, never empty)
git -C "$WORKTREE_PATH" revert --no-edit HEAD
ROLLBACK_SHA=$(git -C "$WORKTREE_PATH" rev-parse HEAD)
git -C "$WORKTREE_PATH" commit --amend --no-edit \
  --trailer "Try-Status: rollback" \
  --trailer "Task: <slug>" \
  --trailer "Reset-From: <fail-sha>" \
  --trailer "Reset-To: <base-sha>"
```

### 6.11 Check circuit breakers

After each ⊗: check pairing's circuit breaker limits:
- `max_attempts_at_tier` — if attempts at current tier ≥ limit, escalate to next tier.
- `max_attempts_total` — if total attempts ≥ limit, emit HANDOFF and stop.

On escalation: update `[task-state]` tier field. Loop back to Step 6.1 at new tier.

On `deps-missing` failure class: do NOT count the attempt; do NOT escalate. Wait for upstream dependency.

On `needs-human` or `infra-fail`: emit ⚠ commit (no rollback, no attempt count) and surface to user.
```

- [ ] **Step 2: Append crash recovery and context checkpoint**

```markdown
---

## Step 7: Crash and resume recovery

On startup (or with `--resume`), for each task with `status: running` in `[task-state]`:

| Signal at `signal_path`? | Staged changes in `worktree_path`? | Recovery action |
|---|---|---|
| Yes | — | Do NOT re-spawn. Read signal; snapshot staged diff; run eval pipeline; commit result. |
| No | Yes | Run eval pipeline on staged diff; commit result. |
| No | No | Discard worktree (`git worktree remove --force`); reset `[task-state]` to `status: ◌`; schedule retry at same tier. |

For tasks with `status: ⊗` and no `↺` commit: complete the rollback commit before retrying.

---

## Step 8: Context limit checkpoint

After completing each task, estimate current context token usage. If usage is at or above 80% of the session limit:

1. For every task still `status: running`, flush `[task-state]` to the plan `.adoc` and commit.
2. Print:
   ```
   Context limit approaching. Re-invoke /darwin-worktree to continue.
   Completed tasks: <list of ● slugs>
   Remaining tasks: <list of pending slugs>
   ```
3. Stop. The next session will reconstruct state from Git + `[task-state]`.

---

## Step 9: Concurrency

For parallel (unordered) tasks, fan out using concurrent Agent tool calls. All ref-mutating Git operations (commit, branch update, worktree add/remove) are serialized by you — do not commit to two branches simultaneously.

For serial (ordered) tasks, check upstream dependency status before starting each task:
```bash
git log agent/<upstream-slug> --format='%(trailers:only,key=Try-Status)' | head -1
```
Proceed only if `Try-Status: pass`.

---

## Step 10: Co-evolving pairs (tests + impl on the same element)

For each co-evolving pair, run `tests` and `impl` as independent concurrent Ralph loops. Before committing `●` on the `impl` branch, perform the **tests gate check** (pure Git — no external state):

```bash
TESTS_PASS=$(git log agent/<slug>/tests --format='%ct %(trailers:only,key=Try-Status)' \
  | awk '/Try-Status: pass/{print $1; exit}')
IMPL_FAIL=$(git log agent/<slug>/impl  --format='%ct %(trailers:only,key=Try-Status)' \
  | awk '/Try-Status: fail/{print $1; exit}')
```

- Gate **open**: `$TESTS_PASS` exists AND `$TESTS_PASS > $IMPL_FAIL` (tests have seen the latest failure).
- Gate **closed**: tests not yet `●`, OR `$IMPL_FAIL > $TESTS_PASS` (gate stale).

Gate closed → set `failure_class: deps-missing`, `consumes_attempt: false`. Do not commit ⊗. Wait.

**Gate staleness (impl ⊗ after tests ●):** Trigger tests re-evaluation. Append the impl's `⊗` trailer corpus to every rubric judge prompt in the tests eval pipeline:

```
## Implementation failure history — assess test coverage of these scenarios:
Attempt <N>: <problem>
  hypothesis: <hypothesis>
  evidence: <evidence>
```

Re-evaluation model tier: tests agent starts one tier ABOVE entry (not entry). Cross-task rubric judge is always `judge_model: top` (highest ladder tier), regardless of the tests agent's tier.

Top-tier judge findings propagate bidirectionally:
- **Tests experience brief** receives: coverage gaps identified.
- **Impl experience brief** receives: structural/architectural issues surfaced.

Re-evaluation attempts are classified `cross-task-reeval` and do NOT count against `max_attempts_total`. A separate `max_reeval_attempts: 3` limit applies; exhausting it generates HANDOFF on the tests task.

---

## Step 11: Summary report

When all tasks are `●`:

```
Darwin complete.

Tasks completed:
  ● <slug> — <N> attempt(s) — tier <T> — <agent_input + eval_input> total input tokens
  ...

Total tokens (this session):
  Agent:  input=<sum>  output=<sum>  thinking=<sum>
  Eval:   input=<sum>  output=<sum>  thinking=<sum>
```

If any task is `⊖` (HANDOFF):
1. Write `HANDOFF.md` in the project root with: task slug, attempt count, final failure class, problem, hypothesis, evidence, suggested next steps.
2. Print: "HANDOFF generated for <slug>. Review HANDOFF.md. Re-invoke /darwin-worktree --resume <slug> after addressing the issue."
3. Stop.
```

- [ ] **Step 3: Verify the complete darwin-worktree.md against the spec**

Read `docs/darwin/specs/2026-05-04-darwin-plugin-design.md` Section 5 in full. Check each item in the loop kernel table and the crash/resume recovery table. Confirm:
- [ ] 12 loop kernel steps covered ✓
- [ ] Token trailers on ⊗ and ● commits ✓
- [ ] Crash recovery — all four table rows ✓
- [ ] Context limit checkpoint at 80% ✓
- [ ] Co-evolving pairs: tests gate formula ✓
- [ ] Gate staleness trigger and re-evaluation ✓
- [ ] Cross-task experience injection block format ✓
- [ ] Cross-task rubric judge always top-tier ✓
- [ ] Bidirectional experience brief propagation ✓
- [ ] `cross-task-reeval` classification, `max_reeval_attempts: 3` ✓
- [ ] Summary report / HANDOFF.md generation ✓

Fix any gaps found. Commit only when all boxes pass.

- [ ] **Step 4: Commit**

```bash
cd ~/.claude/plugins/darwin
git add skills/darwin-worktree.md
git commit -m "feat(darwin): darwin-worktree skill — loop kernel, eval, commit, recovery, co-evolving pairs"
```

---

## Task 7: Integration smoke test

Verifies the full plugin assembles correctly: hooks.json is valid, all shell scripts are executable, all TS helpers compile, and both skill files reference correct paths.

**Files:** None created — read-only verification.

- [ ] **Step 1: Validate hooks.json**

```bash
cat ~/.claude/plugins/darwin/hooks/hooks.json | jq .
```

Expected: valid JSON with `hooks.WorktreeCreate` and `hooks.SubagentStop` arrays.

- [ ] **Step 2: Verify shell scripts are executable**

```bash
ls -la ~/.claude/plugins/darwin/hooks/worktree-create.sh \
        ~/.claude/plugins/darwin/hooks/subagent-stop.sh
```

Expected: both show `-rwxr-xr-x` (or similar with execute bit set).

- [ ] **Step 3: Run all shell tests**

```bash
bash ~/.claude/plugins/darwin/hooks/tests/subagent-stop.test.sh
bash ~/.claude/plugins/darwin/hooks/tests/worktree-create.test.sh
```

Expected: both print `PASS`.

- [ ] **Step 4: Run TypeScript tests**

```bash
cd ~/.claude/plugins/darwin
./helpers/c4/rt.sh test
```

Expected: all tests pass (C4 adapter tests + token-delta tests).

- [ ] **Step 5: Verify compiled helpers**

```bash
ls ~/.claude/plugins/darwin/helpers/c4/bin/*.js
```

Expected: `parse-index.js  branch-name.js  format-trailers.js  validate-property.js  resolve-phase-transition.js  token-delta.js`

- [ ] **Step 6: Spot-check skill file paths**

```bash
grep "darwin-state/runtime.json"  ~/.claude/plugins/darwin/skills/darwin-init.md
grep "detect-runtime.sh"          ~/.claude/plugins/darwin/skills/darwin-init.md
grep "darwin-state/runtime.json"  ~/.claude/plugins/darwin/skills/darwin-worktree.md
grep "token-delta"                ~/.claude/plugins/darwin/helpers/c4/bin/token-delta.js
```

Expected: each grep returns at least one match. If `helpers/c4/` paths are wrong (e.g., `scripts/` from the C4 adapter plan), update the skill files to match the actual installed location.

- [ ] **Step 7: Final commit**

```bash
cd ~/.claude/plugins/darwin
git add -A
git status   # confirm nothing unexpected is staged
git commit -m "chore(darwin): integration smoke test pass — plugin complete"
```

---
