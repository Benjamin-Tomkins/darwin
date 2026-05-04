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
