# Darwin Evaluation Harness — Design Spec

**Date:** 2026-05-05
**Status:** Draft

---

## Goal

Build a self-evolving evaluation harness that runs Darwin skills headlessly, judges their output against generated hypotheses, records every experiment as a self-contained ADR in the git commit history, and applies targeted Darwin source edits when experiments identify failures with high confidence. The git ledger is both the safety net and the institutional memory — every decision is recoverable, reversible, and queryable.

---

## Architecture

The harness is a TypeScript program in `helpers/eval-harness/`, following the same pattern as `helpers/c4/`. It runs three layers, each using the Claude Code Agent SDK `query()` loop with `permissionMode: "bypassPermissions"`.

```
┌─────────────────────────────────────────────────────────┐
│  Experiment Controller  (Opus — outer loop)              │
│  Reads ADR history → generates hypothesis queue          │
│  Prioritises: untested behaviours, low-confidence ADRs,  │
│  recently changed code                                   │
│  Acts as meta-evaluator after each batch                 │
└──────────────────────┬──────────────────────────────────┘
                       │ one hypothesis at a time
┌──────────────────────▼──────────────────────────────────┐
│  Experiment Runner  (Sonnet — middle loop)               │
│  Creates sparse worktree via WorktreeCreate hook         │
│  Injects fixture CLAUDE.md with scripted Q&A answers     │
│  Runs skill via query() + bypassPermissions              │
│  Collects: debug.log, transcript JSONL, .adoc files,     │
│  git commits from worktree                               │
└──────────────────────┬──────────────────────────────────┘
                       │ structured observation bundle
┌──────────────────────▼──────────────────────────────────┐
│  Eval Judge  (Opus — judgment)                           │
│  Verdict (pass / fail / inconclusive) + confidence 0–100 │
│  If fail + confidence ≥ threshold: propose Darwin edit   │
│  Re-run against patched worktree                         │
│  Commit ADR + DARWIN_META block either way               │
└─────────────────────────────────────────────────────────┘
```

**Safety net:** git is the rollback mechanism. Every Darwin source change the Judge proposes is applied in a fresh worktree and committed only after the re-run passes. The ADR record of what was tried and why persists at every git SHA regardless of where the working tree is reset to.

---

## Experiment Lifecycle

```
1. GENERATE
   Controller reads git log (DarwinCommitLog) and existing ADR history
   Builds hypothesis queue: untested code paths, low-confidence prior results,
   recently changed files in hooks/skills/pairings
   Deduplicates against existing experiment SHAs (no repeated hypotheses)

2. SETUP
   Runner creates a fresh sparse worktree via the WorktreeCreate hook
   Injects fixture CLAUDE.md: scripted Q&A answers for each skill phase
   (This is the mechanism for headless conversational skill driving —
   the inner Claude reads answers from CLAUDE.md, no mid-loop injection needed)

3. RUN
   Runner calls query() with bypassPermissions inside the worktree
   Seed prompt: the skill invocation (e.g. "/darwin:plan-software")
   Inner Claude reads fixture answers from CLAUDE.md and self-answers each phase
   Hard caps: max_turns: 20, max_budget_usd: $1.00 per experiment

4. OBSERVE
   Runner collects:
   - debug.log entries filtered by worktree task_identifier
   - Transcript JSONL (turns, tool calls, token counts)
   - Produced .adoc files
   - Git commits from the worktree (subject lines + diffs)

5. JUDGE
   Judge receives: hypothesis + observation bundle
   Produces: verdict + confidence 0–100 + verbatim evidence quotes
   If fail + confidence ≥ hypothesis.confidence_threshold:
     propose a targeted Darwin source edit (specific file + description)

6. EVOLVE  (fail path only)
   Edit applied to Darwin source in a fresh worktree
   Same experiment re-run against patched Darwin
   If re-run passes: Darwin edit committed to main tree
   If re-run fails or confidence drops: worktree discarded

7. RECORD
   ADR written as a git commit (prose body + DARWIN_META JSON block)
   Commit includes any Darwin source edits as staged file changes
   Controller reads new commit before generating next hypothesis
```

**Termination conditions** (any one stops the outer loop):

| Condition | Threshold |
|-----------|-----------|
| Hypothesis queue exhausted | — |
| Convergence stall | 3 consecutive inconclusive results |
| Per-run budget | max 10 experiments, max $20.00 |
| Deduplication | Hypothesis already present in git ledger |

---

## Hypothesis Format

```typescript
interface Hypothesis {
  title: string;                        // imperative, ≤72 chars (becomes commit subject)
  skill: 'plan-software' | 'worktree' | 'darwin-init';
  inputs: Record<string, string>;       // scripted Q&A fixture answers
  expected_outputs: {
    files?: string[];                   // paths that must exist after run
    debug_log_events?: string[];        // message prefixes that must appear in debug.log
    adoc_content?: Record<string, string>; // filename → regex patterns that must match
    git_trailers?: Record<string, string>; // trailers that must be present on worktree commits
  };
  confidence_threshold: number;         // 0–100; below this = inconclusive, no edit proposed
}
```

---

## Commit Format

Every experiment produces exactly one git commit. The format follows Darwin's existing commit conventions extended with a full ADR body and a `DARWIN_META` JSON block.

### Structure (field order is deliberate — each builds on prior context)

```
<symbol> <imperative subject, ≤72 chars>
                                          ← required blank line (git constraint)
# Status: Accepted | Rejected | Inconclusive | Superseded
# Author: <model-id that acted as Judge>
                                          ← blank line
## Context
<Background: what behaviour was under test, why it matters, scope of the decision.>
                                          ← blank line
## Considered Options
A) <description>
   + <pro>
   - <con>
   Confidence: <0–100>

B) <description> (chosen)
   + <pro>
   - <con>
   Confidence: <0–100>
                                          ← blank line
## Decision
<Which option was chosen and the single-sentence summary of the choice.>
                                          ← blank line
## Rationale
<Why this option over the others. References to Darwin requirements (R-numbers),
spec invariants, or prior ADR SHAs where relevant.>
                                          ← blank line
## Consequences
- <Trade-off or consequence 1>
- <Trade-off or consequence 2>
                                          ← blank line
Notes: <optional free-form text — caveats, conditions, fixture changes, etc.>
                                          ← blank line
Eval-Confidence: <0–100>
Experiment-Status: pass | fail | inconclusive
                                          ← blank line
DARWIN_META_BEGIN
{ ... structured JSON (see schema below) ... }
DARWIN_META_END
```

### Scalar git trailers

Only scalar values that benefit from `git log --grep` or `git log --format='%(trailers:key=X)'`:

| Trailer | Values | Description |
|---------|--------|-------------|
| `Eval-Confidence` | `0–100` | Judge's confidence in the verdict |
| `Experiment-Status` | `pass \| fail \| inconclusive` | Outcome |

All other structured data lives in `DARWIN_META_BEGIN` / `DARWIN_META_END`.

### `DARWIN_META` JSON schema

```typescript
interface DarwinCommitMeta {
  experiment: {
    skill: string;
    inputs: Record<string, string>;
    confidence_threshold: number;
    branch: string;             // full Darwin branch path: agent/<plan>/<task-chain>
    task_asset: string;         // "impl" | "tests" | "bdd" | "detail"
    upstream_tasks: string[];   // branch paths of tasks that completed before this one
  };

  verdict: {
    status: 'pass' | 'fail' | 'inconclusive';
    confidence: number;         // 0–100
    evidence: string[];         // verbatim quotes from artifact (substrings checked by harness)
  };

  adr: {
    status: 'Accepted' | 'Rejected' | 'Inconclusive' | 'Superseded';
    author: string;             // model ID that acted as Judge (e.g. "claude-opus-4-7")
    related_commits?: string[]; // SHAs of related experiment commits in this ledger
    eval_commit?: string;       // SHA of the pairing/fixture/eval-criteria commit in use
    notes?: string;             // free-form caveats not captured in ADR prose
  };

  edit?: {                      // present only on commits that apply a Darwin source change
    file: string;               // path relative to repo root
    description: string;        // what was changed and why
    re_run_verdict: 'pass' | 'fail';
    re_run_confidence: number;
  };

  agent_tokens: { input: number; output: number; thinking: number };
  eval_tokens:  { input: number; output: number; thinking: number };
}
```

**`branch` encodes the full C4 task context.** From `agent/hello-world/greeter/impl`:
- `plan_identifier`: `hello-world`
- `task_identifier chain`: `greeter/impl`
- `parent_task_identifier`: `greeter`

No redundant fields — these are derived on read by `DarwinCommit`.

---

## Complete Commit Example

```
⊗ plan-software nests containers at DSL root without softwareSystem identifier

# Status: Rejected
# Author: claude-opus-4-7

## Context
Tested plan-software with a single-container Payment Service. The softwareSystem
block was present but the identifier confirmation question was skipped in the fixture,
leaving the identifier property unset before the container block was emitted. This
exercises R14.3, which requires every workflow-spawning DSL element to declare an
immutable identifier property.

## Considered Options
A) Accept current behaviour (containers emitted at DSL root)
   + No skill change required
   - Violates R14.3; worktree cannot derive branch path; parse-index.ts halts
   Confidence: 12

B) Enforce identifier collection before container listing (chosen)
   + Correct per R14.3; worktree output becomes parseable end-to-end
   - Fixtures must always include an identifier confirmation turn
   Confidence: 84

## Decision
Option B: guard the "Identify applications & services" phase so the identifier
is confirmed before any container is listed.

## Rationale
R14.3 is non-negotiable: branch-name.ts cannot derive a branch path from an
element with no identifier, causing WorktreeCreate to halt. Option A would
harden a broken invariant into the skill. Option B costs one required fixture
turn and produces correct, parseable output.

## Consequences
- Fixtures must include identifier confirmation for all container-bearing scenarios
- Skills that skip identifier now fail validation earlier — a useful gate
- Considered Option A is permanently rejected by this ADR

Notes: failure only reproduces when fixture skips identifier confirmation; human-
       driven sessions are unaffected as the skill already asks the question.
       Fixture updated to always confirm before proceeding.

Eval-Confidence: 84
Experiment-Status: fail

DARWIN_META_BEGIN
{
  "experiment": {
    "skill": "plan-software",
    "inputs": { "project_name": "Payment Service", "skip_identifier": "true" },
    "confidence_threshold": 70,
    "branch": "agent/hello-world/greeter/impl",
    "task_asset": "impl",
    "upstream_tasks": []
  },
  "verdict": {
    "status": "fail",
    "confidence": 84,
    "evidence": [
      "container \"API\" appears at DSL root level, not nested inside softwareSystem",
      "parse-index.ts: projectIdentifier is empty string — cannot derive branch path"
    ]
  },
  "adr": {
    "status": "Rejected",
    "author": "claude-opus-4-7",
    "related_commits": [],
    "eval_commit": "c7cc568",
    "notes": "fixture updated to always confirm identifier before proceeding"
  },
  "edit": {
    "file": ".claude/plugins/darwin/skills/plan-software/SKILL.md",
    "description": "Added identifier guard before container listing in 'Identify applications & services' phase",
    "re_run_verdict": "pass",
    "re_run_confidence": 91
  },
  "agent_tokens": { "input": 1840, "output": 420, "thinking": 0 },
  "eval_tokens":  { "input": 960,  "output": 180, "thinking": 30 }
}
DARWIN_META_END
```

---

## TypeScript Classes

### `DarwinCommit`

Owns one experiment commit end-to-end. Stateless with respect to the git repo — all git operations are explicit.

```typescript
class DarwinCommit {
  // Construction
  static create(data: CommitInput): DarwinCommit
  static fromSha(sha: string, repoPath: string): Promise<DarwinCommit>

  // Typed accessors (derived from parsed body + DARWIN_META)
  get subject(): string
  get adr(): ADR
  get verdict(): Verdict
  get meta(): DarwinCommitMeta
  get evalConfidence(): number
  get experimentStatus(): ExperimentStatus
  get planIdentifier(): string           // derived from meta.experiment.branch
  get taskIdentifierChain(): string      // derived from meta.experiment.branch
  get parentTaskIdentifier(): string     // derived from meta.experiment.branch

  // Auto-resolves eval_commit SHA by querying git log for the relevant pairing/fixture commit
  async resolveEvalCommit(repoPath: string): Promise<string>

  // Produces a valid git commit message string (subject + blank line + body + trailers + meta)
  toCommitMessage(): string

  // Stages files and commits; returns the new SHA
  async commit(repoPath: string, stagedFiles?: string[]): Promise<string>
}
```

### `DarwinCommitLog`

The queryable ledger. Parses a git range and exposes typed filter/group methods. The Controller calls `contextSummary()` before generating each hypothesis to build situational awareness without re-reading every commit in full.

```typescript
class DarwinCommitLog {
  static fromRange(range: string, repoPath: string): Promise<DarwinCommitLog>

  // Filters
  byStatus(status: ExperimentStatus): DarwinCommit[]
  bySkill(skill: string): DarwinCommit[]
  byPlan(planIdentifier: string): DarwinCommit[]
  byTask(branchPath: string): DarwinCommit[]
  relatedTo(sha: string): DarwinCommit[]
  parallelTo(sha: string): DarwinCommit[]       // same parent task, different branch
  upstreamOf(branchPath: string): DarwinCommit[]

  // Metrics
  confidenceTrend(skill: string): number[]
  lowConfidence(threshold: number): DarwinCommit[]
  untestedPaths(knownPaths: string[]): string[]  // paths with no ADR yet

  // Controller prompt injection
  contextSummary(branchPath?: string): string    // condensed history for Opus prompt
}
```

---

## File Layout

```
helpers/eval-harness/
  src/
    types.ts               — all interfaces: Hypothesis, ADR, DarwinCommitMeta, CommitRecord
    DarwinCommit.ts        — class: one experiment commit; serialise/parse; git write
    DarwinCommitLog.ts     — class: git range → CommitRecord[]; filter/group/summarise
    controller.ts          — Experiment Controller (Opus outer loop)
    runner.ts              — Experiment Runner (Sonnet middle loop)
    judge.ts               — Eval Judge (Opus: verdict, edit proposal, ADR write)
    hypothesis.ts          — Hypothesis type + generator logic
  fixtures/
    plan-software/         — pre-built fixture specs for known scenarios
      single-container.json
      multi-system.json
      resume-mid-phase.json
  tests/
    DarwinCommit.test.ts   — unit tests against fixture commit messages (no git required)
    DarwinCommitLog.test.ts
  package.json
  tsconfig.json

docs/darwin/adrs/          — materialized ADR view rendered from git log (not source of truth)
```

---

## Spec Constraints

- `docs/darwin/adrs/` is a **rendered view** generated from git log. The `DARWIN_META` block in each experiment commit is the source of truth. The two must never diverge; the renderer is the canonical way to write ADR files.
- The `DarwinCommit.toCommitMessage()` method is the **only** place that serialises a commit message. Nothing else constructs commit text.
- `eval_commit` in `adr` is always auto-resolved by `DarwinCommit.resolveEvalCommit()` before calling `commit()` — it is never set manually.
- `evidence` strings in `verdict` are verbatim substrings of the artifact, consistent with Darwin's `evidence_quotes` pattern (R5.9a/R5.9b). The harness substring-checks them before accepting the verdict.
- The outer Controller loop terminates on any circuit breaker condition before budget exhaustion; it never retries a failed hypothesis without modifying either the hypothesis or the Darwin source.
- Darwin source edits proposed by the Judge are applied only to a **fresh worktree**, never to the main working tree directly. The edit reaches the main tree only after the re-run passes.
