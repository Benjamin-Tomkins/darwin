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
PLUGIN="$(git rev-parse --show-toplevel)/.claude/plugins/darwin"
```

Parse `index.adoc` into an element tree. If `--c4 <plan-dir>` was passed, the file argument is `<plan-dir>/index.adoc`; otherwise it is the literal `<plan.adoc>` argument:
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
3. Parse: `pairing` (string, optional), `writable_globs` (list), `readonly_globs` (list, optional), `stop_criteria` (optional).

If `pairing` is absent from the `[task]` block, infer it:
| Element type | Property key | Default pairing |
|---|---|---|
| SoftwareSystem, Container, Component | `impl` | `implementer-with-tests` |
| any | `tests` | `test-author-with-meta-rubric` |
| any | `bdd` | `test-author-with-meta-rubric` |
| any | `detail` | `doc-writer-with-checks` |

Resolve the pairing name by reading `.claude/darwin-pairings/<pairing-name>/pairing.yaml` from the repo root. If the file does not exist, halt with: `Pairing '<name>' not found in .claude/darwin-pairings/. Create the pairing file or run /darwin-init.`

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

If `--resume <slug>` was passed, verify the slug exists in ELEMENT_TREE. If not found, halt with: `Resume slug '<slug>' not found in plan. Check for slug renames or typos.` If found, include only the named task and its dependents.

If the queue is empty after applying all filters, report `No tasks to run — all tasks are already ●` and stop.

---

## Step 5: Reconstruct per-task state

For each task, derive the canonical branch name using the `branch-name` helper:

```bash
$EXEC $FLAGS $PLUGIN/helpers/c4/bin/branch-name.js <slug-chain-json>
# e.g. branch-name.js '["project","container","auth"]' --asset impl
# → agent/project/container/auth/impl
```

Then read Git trailer history from the task's branch:

```bash
BRANCH=$(... branch-name output ...)
git log "$BRANCH" \
  --format='%H%n%(trailers:key=Try-Status,key=Tier,key=Pairing-Hash,key=Eval-Id,key=Failure-Class,key=Attempt,key=Problem,key=Hypothesis,key=Evidence)' \
  2>/dev/null
```

Derive:
- `status` — latest `Try-Status` value (`pass`, `fail`, `rollback`, etc.), or `◌` if branch does not exist.
- `attempt_count` — number of commits where `Try-Status: fail`.
- `current_tier` — `Tier` value from the latest `fail` commit.
- `pairing_hash` — `Pairing-Hash` from the latest commit.
- `experience_brief` — ordered list of all `fail` trailer sets (problem, hypothesis, evidence); excludes rollback, infra-fail, widen commits.

**Pairing-Hash verification (R7.18):** After loading the resolved pairing YAML (from Step 2), compute SHA-256 of the pairing YAML with keys sorted alphabetically and whitespace normalised (per R0.10 — sorted keys, normalised whitespace) and compare against `pairing_hash`. If they differ and no `Phase-Transition: true` is present on the latest commit, halt with: "Pairing-hash drift detected on `<branch>`. Pairing may have changed mid-run. Resolve manually before resuming."

Also read `[task-state]` from the asset `.adoc` file for this task (the same file read in Step 2 for this element/property-key pair) for crash-recovery fields (`signal_path`, `worktree_path`, `agent_name`).

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

If the computed hash differs from `pairing_hash` in the task's state (and `pairing_hash` is not empty → this is not the first attempt), AND the latest commit on the branch does NOT have `Phase-Transition: true` as a trailer, halt: "Pairing hash drift on task <slug> — pairing was edited mid-run. Restore the pinned version or migrate to a new branch. (R7.18)"

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
REPO_HASH=$(git -C <project-root> rev-parse --show-toplevel | shasum | cut -c1-7)
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
  --trailer "Evidence: <evidence-from-eval-envelope>" \
  --trailer "Agent-Input-Tokens: <agent_input>" \
  --trailer "Agent-Output-Tokens: <agent_output>" \
  --trailer "Agent-Thinking-Tokens: <agent_thinking>" \
  --trailer "Eval-Input-Tokens: <eval_input>" \
  --trailer "Eval-Output-Tokens: <eval_output>" \
  --trailer "Eval-Thinking-Tokens: <eval_thinking>"

# Immediately follow with rollback (real inverse-diff commit, never empty)
git -C "$WORKTREE_PATH" revert --no-edit HEAD
git -C "$WORKTREE_PATH" commit --amend --no-edit \
  --trailer "Try-Status: rollback" \
  --trailer "Task: <slug>" \
  --trailer "Reset-From: <fail-sha>" \
  --trailer "Reset-To: <base-sha>"
ROLLBACK_SHA=$(git -C "$WORKTREE_PATH" rev-parse HEAD)
```

### 6.11 Check circuit breakers

After each ⊗: check pairing's circuit breaker limits:
- `max_attempts_at_tier` — if attempts at current tier ≥ limit, escalate to next tier.
- `max_attempts_total` — if total attempts ≥ limit, emit HANDOFF and stop.

On escalation: update `[task-state]` tier field. Loop back to Step 6.1 at new tier.

On `deps-missing` failure class: do NOT count the attempt; do NOT escalate. Wait for upstream dependency.

On `needs-human` or `infra-fail`: emit ⚠ commit (no rollback, no attempt count) and surface to user.

---

## Step 7: Crash and resume recovery

On startup (or with `--resume`), for each task with `status: running` in `[task-state]`:

| Signal at `signal_path`? | Staged changes in `worktree_path`? | Recovery action |
|---|---|---|
| Yes | — | Do NOT re-spawn. Read signal; snapshot staged diff; run eval pipeline; commit result. |
| No | Yes | Run eval pipeline on staged diff; commit result. |
| No | No | Discard worktree (`git worktree remove --force`); reset `[task-state]` to `status: ◌`; schedule retry at same tier. |
| `⊖` / dirty at `↺` | — | Block. Require manual repair. Do not auto-resolve. Surface: "Worktree dirty at rollback commit on `<branch>`. Manual intervention required (R8.3)." |

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

Re-evaluation model tier: for cross-task re-eval attempts only, the tests agent starts one tier ABOVE its configured entry tier. This does NOT apply to the tests task's own initial attempts, which start at entry tier and escalate on failure per the standard circuit breaker logic. Cross-task rubric judge is always `judge_model: top` (highest ladder tier), regardless of the tests agent's tier.

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
1. Write `HANDOFF.md` in the agent's worktree path (from `[task-state].worktree_path`) with the following sections:
   - **Header:** task slug, pairing name, branch, last commit SHA, models used across all attempts
   - **Trigger:** trigger reason (one of: circuit-breaker exhausted / ladder exhausted / needs-human / upstream-constraint with upstream slug)
   - **What this task was trying to do:** the original task description from the asset `.adoc`
   - **Attempts summary table:** for each attempt — attempt #, tier, model, triggering eval ID, eval type, failure class, problem
   - **Current hypothesis:** the hypothesis from the final `⊗` commit
   - **Evidence:** the evidence from the final `⊗` commit
   - **Unblocking options:** ordered list of concrete next steps for a human to try
   - **Resume command:** `/darwin-worktree <plan.adoc> --resume <slug>`
2. Print: "HANDOFF generated for <slug>. Review HANDOFF.md. Re-invoke /darwin-worktree --resume <slug> after addressing the issue."
3. Stop.
