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
│  Experiment Controller  (Opus — outer loop)             │
│  Reads ADR history → generates hypothesis queue         │
│  Prioritises: untested behaviours, low-confidence ADRs, │
│  recently changed code                                  │
│  Acts as meta-evaluator after each batch                │
└──────────────────────┬──────────────────────────────────┘
                       │ one hypothesis at a time
┌──────────────────────▼──────────────────────────────────┐
│  Experiment Runner  (Sonnet — middle loop)              │
│  Creates sparse worktree via WorktreeCreate hook        │
│  Injects fixture CLAUDE.md with scripted Q&A answers    │
│  Runs skill via query() + bypassPermissions             │
│  Collects: debug.log, transcript JSONL, .adoc files,    │
│  git commits from worktree                              │
└──────────────────────┬──────────────────────────────────┘
                       │ structured observation bundle
┌──────────────────────▼──────────────────────────────────┐
│  Eval Judge  (Opus — judgment)                          │
│  Verdict (pass / fail / inconclusive) + confidence 0–100│
│  If fail + confidence ≥ threshold: propose Darwin edit  │
│  Re-run against patched worktree                        │
│  Commit ADR + DARWIN_META block either way              │
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
    // All prose fields are source of truth here. The commit body sections are a
    // rendered view generated by toCommitMessage() — fromSha() never parses prose.
    status: 'Accepted' | 'Rejected' | 'Inconclusive' | 'Superseded';
    author: string;             // model ID that acted as Judge (e.g. "claude-opus-4-7")
    context: string;            // background: what behaviour was under test and why
    considered_options: Array<{
      label: string;            // single letter: "A", "B", "C"
      description: string;
      pros: string[];
      cons: string[];
      confidence: number;       // 0–100
      chosen: boolean;          // exactly one option per ADR must be true
    }>;
    decision: string;           // one sentence: which option and the summary choice
    rationale: string;          // why this option over the others
    consequences: string[];     // trade-offs and follow-on effects (bullet items)
    related_commits?: string[]; // SHAs of related experiment commits in this ledger
    eval_commit?: string;       // SHA of the pairing/fixture/eval-criteria commit in use
    notes?: string;             // free-form caveats not captured in prose sections
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
    "context": "Tested plan-software with a single-container Payment Service. The softwareSystem block was present but the identifier confirmation question was skipped in the fixture, leaving the identifier property unset before the container block was emitted. This exercises R14.3, which requires every workflow-spawning DSL element to declare an immutable identifier property.",
    "considered_options": [
      {
        "label": "A",
        "description": "Accept current behaviour (containers emitted at DSL root)",
        "pros": ["No skill change required"],
        "cons": ["Violates R14.3; worktree cannot derive branch path; parse-index.ts halts"],
        "confidence": 12,
        "chosen": false
      },
      {
        "label": "B",
        "description": "Enforce identifier collection before container listing",
        "pros": ["Correct per R14.3; worktree output becomes parseable end-to-end"],
        "cons": ["Fixtures must always include an identifier confirmation turn"],
        "confidence": 84,
        "chosen": true
      }
    ],
    "decision": "Option B: guard the 'Identify applications & services' phase so the identifier is confirmed before any container is listed.",
    "rationale": "R14.3 is non-negotiable: branch-name.ts cannot derive a branch path from an element with no identifier, causing WorktreeCreate to halt. Option A would harden a broken invariant into the skill. Option B costs one required fixture turn and produces correct, parseable output.",
    "consequences": [
      "Fixtures must include identifier confirmation for all container-bearing scenarios",
      "Skills that skip identifier now fail validation earlier — a useful gate",
      "Considered Option A is permanently rejected by this ADR"
    ],
    "related_commits": [],
    "eval_commit": "c7cc568",
    "notes": "failure only reproduces when fixture skips identifier confirmation; human-driven sessions are unaffected as the skill already asks the question. Fixture updated to always confirm before proceeding."
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

## Serialization, Deserialization, and Validation

### Serialization — `toCommitMessage()`

`toCommitMessage()` is the **only** place that constructs a commit message string. It renders prose from the structured `adr` fields and appends trailers and the `DARWIN_META` JSON block.

**Symbol selection** (from `verdict.status`):

| `verdict.status` | Symbol |
|------------------|--------|
| `pass`           | `●`    |
| `fail`           | `⊗`    |
| `inconclusive`   | `◌`    |

**Field → section mapping** (sections rendered in this exact order):

```
<symbol> <hypothesis.title>
                                    ← blank line
# Status: <adr.status>
# Author: <adr.author>
                                    ← blank line
## Context
<adr.context>
                                    ← blank line
## Considered Options
<for each adr.considered_options[i]:>
<label>) <description> [(chosen) if chosen]
   + <pros[0]>
   + <pros[1]>
   - <cons[0]>
   Confidence: <confidence>
   ← blank line between options
## Decision
<adr.decision>
                                    ← blank line
## Rationale
<adr.rationale>
                                    ← blank line
## Consequences
- <consequences[0]>
- <consequences[1]>
                                    ← blank line
[Notes: <adr.notes>]                ← omit line if notes is undefined
                                    ← blank line
Eval-Confidence: <verdict.confidence>
Experiment-Status: <verdict.status>
                                    ← blank line
DARWIN_META_BEGIN
<JSON.stringify(meta, null, 2)>
DARWIN_META_END
```

**Invariants enforced before serializing:**
- Exactly one `considered_options` entry has `chosen: true` — throws if zero or more than one.
- `verdict.confidence === adr.considered_options.find(o => o.chosen).confidence` is NOT required (they measure different things: verdict confidence is the Judge's overall confidence; option confidence is the comparative assessment of that option).
- `hypothesis.title` must be ≤ 72 chars after the symbol prefix — throws if longer.
- `verdict.status` must be one of the three valid values — Zod catches this before serialization.

---

### Deserialization — `fromSha()`

`fromSha()` reads a commit by SHA, extracts **only the `DARWIN_META` JSON block**, parses and validates it, then returns a typed `DarwinCommit`. The prose sections in the body are the rendered view and are never parsed back.

**Algorithm:**

```
1. git show <sha> --format="%B" -s  →  full commit message string
2. Find line "DARWIN_META_BEGIN" and line "DARWIN_META_END"
   → if either is missing: throw DarwinMetaParseError("DARWIN_META block not found in commit <sha>")
3. Extract the JSON substring between the sentinel lines
4. JSON.parse(block)
   → if invalid JSON: throw DarwinMetaParseError("Invalid JSON in DARWIN_META block: <parse error message>")
5. DarwinCommitMetaSchema.parse(result)
   → if Zod validation fails: throw DarwinMetaValidationError with .issues from Zod
6. Extract scalar git trailers from the commit via:
     git log <sha> -1 --format="%(trailers:key=Eval-Confidence,valueonly)"
     git log <sha> -1 --format="%(trailers:key=Experiment-Status,valueonly)"
7. Consistency check — trailers must match DARWIN_META values:
   - Number(trailer["Eval-Confidence"]) === meta.verdict.confidence
     → if mismatch: throw DarwinMetaConsistencyError("Eval-Confidence trailer <x> ≠ meta.verdict.confidence <y>")
   - trailer["Experiment-Status"] === meta.verdict.status
     → if mismatch: throw DarwinMetaConsistencyError("Experiment-Status trailer <x> ≠ meta.verdict.status <y>")
8. Extract subject line (first line of commit message)
9. Construct and return DarwinCommit instance
```

`fromSha()` is read-only — it never mutates git history or disk state.

---

### Validation Schemas (Zod)

All schemas live in `helpers/eval-harness/src/types.ts`. Every external input boundary (fromSha, hypothesis files, signal.json) is Zod-validated before use.

```typescript
import { z } from 'zod';

export const TokenCountSchema = z.object({
  input:    z.number().int().nonnegative(),
  output:   z.number().int().nonnegative(),
  thinking: z.number().int().nonnegative(),
});

export const ConsideredOptionSchema = z.object({
  label:       z.string().min(1).max(1),   // single letter
  description: z.string().min(1),
  pros:        z.array(z.string().min(1)).min(1),
  cons:        z.array(z.string().min(1)).min(1),
  confidence:  z.number().int().min(0).max(100),
  chosen:      z.boolean(),
});

export const AdrSchema = z.object({
  status:             z.enum(['Accepted', 'Rejected', 'Inconclusive', 'Superseded']),
  author:             z.string().min(1),
  context:            z.string().min(1),
  considered_options: z.array(ConsideredOptionSchema).min(2).refine(
    opts => opts.filter(o => o.chosen).length === 1,
    { message: 'Exactly one considered_option must have chosen: true' }
  ),
  decision:           z.string().min(1),
  rationale:          z.string().min(1),
  consequences:       z.array(z.string().min(1)).min(1),
  related_commits:    z.array(z.string()).optional(),
  eval_commit:        z.string().optional(),
  notes:              z.string().optional(),
});

export const VerdictSchema = z.object({
  status:     z.enum(['pass', 'fail', 'inconclusive']),
  confidence: z.number().int().min(0).max(100),
  evidence:   z.array(z.string().min(1)).min(1),
});

export const ExperimentMetaSchema = z.object({
  skill:                z.enum(['plan-software', 'worktree', 'darwin-init']),
  inputs:               z.record(z.string()),
  confidence_threshold: z.number().int().min(0).max(100),
  branch:               z.string().regex(/^agent\/[^/]+\/.+$/, 'branch must match agent/<plan>/<task-chain>'),
  task_asset:           z.enum(['impl', 'tests', 'bdd', 'detail']),
  upstream_tasks:       z.array(z.string()),
});

export const EditSchema = z.object({
  file:               z.string().min(1),
  description:        z.string().min(1),
  re_run_verdict:     z.enum(['pass', 'fail']),
  re_run_confidence:  z.number().int().min(0).max(100),
});

export const DarwinCommitMetaSchema = z.object({
  experiment:   ExperimentMetaSchema,
  verdict:      VerdictSchema,
  adr:          AdrSchema,
  edit:         EditSchema.optional(),
  agent_tokens: TokenCountSchema,
  eval_tokens:  TokenCountSchema,
});

// Derived types — use these throughout the codebase, not the raw interfaces
export type DarwinCommitMeta  = z.infer<typeof DarwinCommitMetaSchema>;
export type ADR               = z.infer<typeof AdrSchema>;
export type Verdict           = z.infer<typeof VerdictSchema>;
export type ExperimentMeta    = z.infer<typeof ExperimentMetaSchema>;
export type ConsideredOption  = z.infer<typeof ConsideredOptionSchema>;
export type Edit              = z.infer<typeof EditSchema>;
export type TokenCount        = z.infer<typeof TokenCountSchema>;

export const HypothesisSchema = z.object({
  title:                z.string().max(72),
  skill:                z.enum(['plan-software', 'worktree', 'darwin-init']),
  inputs:               z.record(z.string()),
  expected_outputs: z.object({
    files:            z.array(z.string()).optional(),
    debug_log_events: z.array(z.string()).optional(),
    adoc_content:     z.record(z.string()).optional(),
    git_trailers:     z.record(z.string()).optional(),
  }),
  confidence_threshold: z.number().int().min(0).max(100),
});
export type Hypothesis = z.infer<typeof HypothesisSchema>;
```

---

### Runtime Assertions

**In `fromSha()`** — throws are the correct response (not `undefined` or `null`). All errors extend `Error` with a `sha` property for traceability.

```typescript
class DarwinMetaParseError extends Error {
  constructor(message: string, public sha: string) { super(message); }
}
class DarwinMetaValidationError extends Error {
  constructor(public issues: z.ZodIssue[], public sha: string) {
    super(`DARWIN_META validation failed in ${sha}: ` +
      issues.map(i => `${i.path.join('.')}: ${i.message}`).join('; '));
  }
}
class DarwinMetaConsistencyError extends Error {
  constructor(message: string, public sha: string) { super(message); }
}
```

Assertion sequence in `fromSha()`:

| Step | Check | Throws |
|------|-------|--------|
| 1 | DARWIN_META_BEGIN and DARWIN_META_END both present | `DarwinMetaParseError` |
| 2 | JSON between sentinels is valid | `DarwinMetaParseError` |
| 3 | Parsed object passes `DarwinCommitMetaSchema` | `DarwinMetaValidationError` |
| 4 | `Eval-Confidence` trailer == `meta.verdict.confidence` | `DarwinMetaConsistencyError` |
| 5 | `Experiment-Status` trailer == `meta.verdict.status` | `DarwinMetaConsistencyError` |
| 6 | `meta.experiment.branch` derivation is self-consistent (plan, task chain, parent all parseable) | `DarwinMetaConsistencyError` |

**In `toCommitMessage()`** — throws before producing any string output:

| Check | Throws |
|-------|--------|
| `DarwinCommitMetaSchema.parse(meta)` — validates entire object before rendering | `DarwinMetaValidationError` (sha = "pending") |
| Exactly one `adr.considered_options[].chosen === true` | `Error('toCommitMessage: exactly one considered_option must be chosen')` |
| Subject `<symbol> <title>` ≤ 72 chars after trimming | `Error('toCommitMessage: subject line exceeds 72 chars')` |

**In hypothesis files** — loaded via `HypothesisSchema.parse()` at Controller startup. Invalid fixtures halt the outer loop with a descriptive error before any experiment runs.

**Evidence substring check** — after Judge returns a verdict, the harness verifies each string in `verdict.evidence` is a verbatim substring of the collected artifact (debug.log + transcript + .adoc files concatenated). Any evidence string that fails the check causes the verdict to be downgraded to `inconclusive` with a note in `adr.notes`.

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

### `PlanGraph`

`PlanGraph` is the unified queryable model of the full project state. It holds two orthogonal axes:

- **Intent tree** — the C4 hierarchy parsed from `index.adoc` and its linked asset `.adoc` files. Each node carries the current understanding of what that part of the system is supposed to do, expressed at progressively finer resolution (softwareSystem → container → component). The tree evolves as the design evolves: nodes are added, detail files deepen, `bdd` specs sharpen. `index.adoc` is genuinely low-resolution — it states the problem space in DSL terms without implementation detail — and depth encodes resolution of understanding.

- **Evidence ledger** — the `DarwinCommit[]` array attached to each node. Each entry is a timestamped, reasoned record of what was tried against that node's intent and what was learned. Nodes accumulate evidence independently of the intent tree's evolution.

The two axes are independent: you can deepen the intent (add a new container to the plan) without running experiments, and you can accumulate evidence without changing the design. The **relationship** between them is what the Controller reads to decide what to do next.

**Convergence criterion:** A leaf node is *resolved* when its evidence ledger contains at least one high-confidence passing `DarwinCommit` that was generated against the node's current intent file content (matched by the `eval_commit` SHA pointing to the asset `.adoc` at the time the experiment ran). A non-leaf node is resolved when all its children are resolved. The design is *stable* when the root node is resolved — every part of the intent tree has been successfully validated by evidence.

**Construction modes.** The graph has an internal `_mode` flag — `'reconstructing'` or `'live'` — that controls side-effect behaviour:

- `PlanGraph.fromRef(ref, repoPath)` sets `_mode = 'reconstructing'`. All parsing and node construction is silent: no debug log entries are emitted, no git writes occur. This is the session-resume path — the graph rebuilds itself from the git ledger without producing duplicate log entries.
- `_mode` flips to `'live'` automatically on the first call to any mutating method. Once live, every state transition emits a debug log entry (via `darwin_debug`) and performs its git operation before returning. The flip is one-way within a session: once live, the graph stays live.
- `PlanGraph.fromRef(ref, repoPath, { debug: true })` reconstructs silently but re-emits all log entries with a `reconstructed:` prefix — used only for validating that `fromRef()` produces an object consistent with what was originally committed.

**The LLM does not interact with git.** All git operations (reading `.adoc` files at a ref, reading the commit log, staging files, committing ADRs, writing `running.json`) are encapsulated inside `PlanGraph` and `DarwinCommit`. The Controller receives a `PlanGraph` instance and calls methods on it; it has no awareness of git commands or file paths.

**In-flight state.** Between an experiment starting and its ADR commit landing, the graph writes a `running.json` to `$SIGNAL_BASE/<repo-hash>/<task-slug>/running.json` on the first live mutating call for that node. This file is deleted when `recordExperiment()` commits the ADR. On `fromRef()`, if `running.json` exists for a node, that node is marked `status: 'running'` in the reconstructed graph — allowing a resumed session to detect and handle experiments that were in progress when the session terminated.

```typescript
// Node types mirror the C4 hierarchy
type PlanNodeType = 'softwareSystem' | 'container' | 'component';
type NodeStatus = 'unstarted' | 'running' | 'resolved' | 'contested' | 'stale';
// resolved   = high-confidence passing ADR against current intent
// contested  = conflicting ADRs (mix of pass/fail at high confidence)
// stale      = passing ADR exists but was run against an older version of the intent file

interface PlanNode {
  identifier: string;          // from DSL identifier property
  displayName: string;         // from DSL quoted name
  type: PlanNodeType;
  description: string;
  assets: Record<string, string>;  // asset key → .adoc filename (impl, tests, bdd, detail)
  pairing?: string;
  children: PlanNode[];        // containers inside softwareSystem, components inside container
  evidence: DarwinCommit[];    // ADR commits for this node, chronological
  status: NodeStatus;          // derived from evidence vs current intent
  intentSha: string;           // git SHA at which this node's asset files were last read
}

class PlanGraph {
  // Construction — silent reconstruction from git; _mode starts as 'reconstructing'
  static fromRef(
    ref: string,
    repoPath: string,
    opts?: { debug?: boolean }
  ): Promise<PlanGraph>

  // Read-only navigation (never trigger mode flip)
  get root(): PlanNode
  node(identifier: string): PlanNode | undefined
  path(branchPath: string): PlanNode[]         // e.g. "greeter/impl" → [softwareSystem, container]
  leaves(): PlanNode[]                         // all nodes with no children
  byStatus(status: NodeStatus): PlanNode[]
  unresolved(): PlanNode[]                     // nodes where evidence doesn't cover current intent
  contested(): PlanNode[]
  stale(): PlanNode[]                          // intent updated after last passing ADR

  // Context generation for Controller prompt (read-only, no mode flip)
  contextSummary(node?: PlanNode): string      // intent + evidence narrative for Opus prompt

  // Mutating methods — each flips _mode to 'live' on first call, then emits debug log + git op
  async markRunning(branchPath: string): Promise<void>
    // writes running.json; emits: { hook: 'plan-graph', message: 'node:running <branchPath>' }

  async recordExperiment(
    branchPath: string,
    commit: DarwinCommit
  ): Promise<void>
    // attaches commit to node.evidence; updates node.status; deletes running.json;
    // emits: { hook: 'plan-graph', message: 'node:evidence-attached <branchPath> status=<status>' }

  async updateIntent(
    branchPath: string,
    newContent: string,
    stagedFiles: string[]
  ): Promise<string>
    // writes updated asset .adoc; commits; marks dependent evidence as stale;
    // returns new SHA; emits: { hook: 'plan-graph', message: 'node:intent-updated <branchPath>' }
}
```

---

## File Layout

```
helpers/eval-harness/
  src/
    types.ts               — Zod schemas + inferred types: Hypothesis, ADR, DarwinCommitMeta,
                             PlanNode, NodeStatus, ExperimentMeta, Verdict, Edit, TokenCount
    DarwinCommit.ts        — class: one experiment commit; serialise/parse; git write
    DarwinCommitLog.ts     — class: git range → DarwinCommit[]; filter/group/summarise
    PlanGraph.ts           — class: intent tree + evidence ledger; construction modes;
                             contextSummary; mutating methods that own all git + log ops
    controller.ts          — Experiment Controller (Opus outer loop); calls PlanGraph only
    runner.ts              — Experiment Runner (Sonnet middle loop)
    judge.ts               — Eval Judge (Opus: verdict, edit proposal, ADR write)
    hypothesis.ts          — Hypothesis type + generator logic (reads PlanGraph.unresolved())
  fixtures/
    plan-software/         — pre-built fixture specs for known scenarios
      single-container.json
      multi-system.json
      resume-mid-phase.json
  tests/
    DarwinCommit.test.ts   — unit tests against fixture commit messages (no git required)
    DarwinCommitLog.test.ts
    PlanGraph.test.ts      — unit tests: fromRef reconstruction, mode transitions,
                             status derivation, contextSummary output shape
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
- **`PlanGraph` owns all git and debug-log operations.** The Controller, Runner, and Judge have no git awareness; they call `PlanGraph` and `DarwinCommit` methods only.
- **`PlanGraph._mode` is one-way.** Once flipped from `'reconstructing'` to `'live'`, it never reverts within a session. Read-only methods (`node()`, `contextSummary()`, `byStatus()`, etc.) never trigger the flip.
- **Debug log entries are emitted exactly once per state transition.** `fromRef()` reconstruction emits nothing (or `reconstructed:`-prefixed entries in debug mode); the live mutating methods emit one entry per call. No LLM tool call is used for logging.
- **`running.json` is the in-flight sentinel.** It is written by `markRunning()` and deleted by `recordExperiment()`. A `running.json` present at `fromRef()` time marks the node `status: 'running'` in the reconstructed graph — the Controller handles this as an interrupted experiment on resume.
- **Node `status` is always derived, never stored.** `NodeStatus` is computed from `evidence[]` vs `intentSha` at read time; it is not persisted to disk or git. `running.json` is the only exception (in-flight signal, not status).
- **Depth encodes resolution of understanding.** The intent tree mirrors the C4 levels: softwareSystem (problem space) → container (deployable units) → component (internal modules). The Controller works from leaves upward: resolving fine-grained uncertainties first and propagating confidence toward the root.
