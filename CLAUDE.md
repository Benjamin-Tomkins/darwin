# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Shape

This repo is a **design specification project**, not an implementation. Two specs live here:

- `sparse-workflow.md` (~1850 lines) — the **controller spec**. The self-healing state machine for AI agent + evaluator pairs. Defines the `(agent, eval) → controller` Ralph loop, the eval contract, sandbox isolation, the trust model, and the full Requirements set (R0–R14).
- `docs/darwin/specs/2026-05-03-c4-plan-format.adoc` (~700 lines) — the **plan-format spec**. The on-disk encoding the controller orchestrates: a single `index.adoc` with an embedded Structurizr DSL block holding the canonical C4 model, plus flat sibling `.adoc` files for human-readable detail (BDD, pseudo-code, implementation plans). C4 hierarchy lives in Git branch names, not folders.

The two specs are **tightly coupled** by design: the controller spec includes a dedicated **R14 — C4 plan format adapter** section codifying the controller's obligations when operating on the C4 format (DSL parsing, slug-based branch naming, `_index` suffix, single canonical index branch, property lifecycle, phase-transition mechanics, etc.). The plan-format spec defines the on-disk shape; R14 in the controller spec defines what the controller does with it. Coupling rather than plugin-style decoupling was a deliberate decision to keep the workflow anchored to the C4 model and prevent drift from business requirements.

There is no source code, no build, no tests, no package manager, and no CI. Treat tasks here as **spec editing**, not software engineering. Don't propose adding tooling (linters, CI, package.json) unless explicitly asked.

## The Core Abstraction

`sparse-workflow.md` specifies **(agent, eval) → controller**: a task-agnostic parent controller that drives a Ralph loop where any agent template paired with any eval pipeline produces a self-healing system. Understanding this triad is the prerequisite for any meaningful edit:

- **Agent** — does the work. Has no test access, no git, no Bash unless explicitly granted by its pairing. Each retry is a FRESH subagent invocation (resumption forbidden).
- **Eval** — judges the work. Returns a fixed result envelope (`verdict`, `failure_class`, `consumes_attempt`, `problem`, `hypothesis`, `evidence`). Seven standard types: `command`, `schema`, `rubric`, `comparative`, `metric-threshold`, `human-in-the-loop`, `composite`.
- **Controller** — owns the loop. Reads the plan, spawns agents, runs evals in an isolated sandbox, commits ⊗/↺/●/⚠/↻/⊖, enforces circuit breakers, generates HANDOFF on exhaustion. The state machine lives here, NOT in the `SubagentStop` hook.

**Every commit is the result of an evaluation, not an implementation.** The branch is an evaluation corpus.

## Invariants That Must Hold When Editing

These are load-bearing across the controller spec — changes to one almost always require corresponding changes elsewhere:

1. **Recursive separation of concerns** — agent ≠ judge; controller ≠ what-it-judges; plan author ≠ agent; eval LLM ≠ agent's models. If an edit lets any of these collapse, it's wrong.
2. **Judge-model separation** — for any `rubric` eval, the resolved judge model must NOT appear in the agent's escalation ladder. Validated at pairing-load.
3. **Commit pairing** — every `⊗` is immediately followed by exactly one `↺` (real inverse-diff commit, not empty); `●` is terminal; `⚠`, `↻`, and `⊖` are standalone and do NOT consume an attempt.
4. **Git is authoritative** — plan/state on disk is a rendered view, regenerable from Git trailers. Never describe plan files as the source of truth.
5. **Trailer vocabulary** — machine-readable fields go in Git trailers (`Try-Status`, `Pairing`, `Pairing-Hash`, `Eval-Id`, `Eval-Type`, `Judge-Model`, `Tier`, `Attempt`, `Model`, `Ladder-Id`, `Evals-Passed`, `Upstream-Task`, `Failure-Class`, plus the C4 adapter additions `Phase`, `Dsl-Element`, `Dsl-Tag`, `Phase-Transition`, plus the token-cost tracking additions `Agent-Input-Tokens`, `Agent-Output-Tokens`, `Agent-Thinking-Tokens`, `Eval-Input-Tokens`, `Eval-Output-Tokens`, `Eval-Thinking-Tokens`). Subject lines carry the symbol + short reason for humans only. Don't introduce new metadata as bracket-tags or subject-line fields.
6. **Eval contract is fixed** — the JSON envelope schema (`verdict`, `failure_class`, `consumes_attempt`, `problem`, `hypothesis`, `evidence`, plus `upstream_task` for `upstream-constraint`, plus `evidence_quotes` on rubric results) is the stable interface. Adding a new eval type means defining how it produces this envelope, not extending the envelope.
7. **Symbol vocabulary is fixed** — `◌◎⊗●⊖⊘` (status), `◈◉` (provenance), `↺↻⚠` (loop action). Don't invent new symbols; reuse existing ones.
8. **Pairings are immutable per task instance** — pinned via `Pairing-Hash` (SHA-256 of canonicalised pairing YAML) on every commit. Mid-run hash drift halts with `needs-human` (R7.17/R7.18).
9. **Rubric evals must include verifiable evidence** — `evidence_quotes` (verbatim spans from the artifact) on every rubric result; controller substring-checks them before accepting the verdict (R5.9a/R5.9b). Defends against well-formed but injected `{verdict: pass}` outputs.
10. **Eval pipeline order is static** — declared cheapest-first; the controller may not reorder dynamically (R5.5).
11. **Controller serializes Git ref-mutating operations** across worktrees of the same repo (R7.15). Per-worktree index files allow concurrent staging; ref writes do not.
12. **Cascade rollback is out of scope** — when a leaf flags a parent's `●` artifact as impossible, the controller emits `failure_class: upstream-constraint` and surfaces a HANDOFF naming the upstream slug; it never auto-reverts the upstream task (R12.6/R12.7).

## Plan-Format-Specific Invariants

When editing `docs/darwin/specs/2026-05-03-c4-plan-format.adoc`:

- **Two layers, one mechanism.** The format defines `index.adoc` (parsable Structurizr DSL embedded; the C4 model) and flat sibling task `.adoc`s (human-readable detail). Both run on the same sparse-workflow Ralph loop. Don't introduce a third layer or split the mechanism.
- **Folder is flat; hierarchy is in Git branches.** Branches are slash-nested mirroring the chain of DSL `"slug"` properties walking up from the element to the project root.
- **Every workflow-spawning DSL element MUST declare an immutable `"slug"` property** (R14.3). Slug uniqueness is validated within parent's children at parse time. Branch paths and filenames derive from slugs, not from DSL identifiers or display names — this means renaming the display name or DSL identifier doesn't break branches.
- **`_index` suffix on index-evolution branches** (R14.6). Git's loose-ref storage cannot have a branch ref that is both a leaf and a prefix of another. Index branches end in `/_index` to keep every branch a leaf.
- **Single canonical index branch** (R14.7). All `index.adoc` evolution serialises on `agent/<project-slug>/_index`. Concurrent index editing is forbidden — sub-branches edit asset `.adoc` files only, never the index itself.
- **`index.adoc` always `:phase: spec`.** The index encodes design, never implementation. Asset `.adoc`s may transition `spec → impl` (only `impl`-keyed ones do).
- **Phase transitions are first-class controller operations** (R14.10). A `:phase: spec → impl` transition commit may carry a different `Pairing-Hash` than the prior commit on the branch (designer pairing → implementer pairing) without tripping R7.18's pairing-hash drift halt, provided the transition commit also carries `Phase-Transition: true`.
- **`impl` assets MUST carry a `[task]` block declaring `writable_globs`** (R14.12). This is what gives the implementation agent its sandbox allowlist; without it the agent cannot write code.
- **Property keys come in two categories.** Asset-reference keys (`detail`, `bdd`, `tests`, `impl`) point at sibling `.adoc` filenames and spawn workflows. Metadata keys (`slug`, `skills`) carry inline values without spawning a workflow. Don't conflate them.
- **No two properties with the same standard asset key per element** (R14.13). One `bdd` per component; if you need more, decompose the element or use distinct custom keys.
- **`:pairing:` is optional and asset-local.** The `:pairing:` on `index.adoc` governs only index-evolution; asset pairings are independent (R14.15).
- **Tagged-region extraction uses `include::`, not `xref:`** (R14.14). `xref:index.adoc#anchor[]` is for human navigation to the DSL element's anchor; `include::index.adoc[tag=name]` is for content extraction. The two are distinct AsciiDoc mechanisms; don't conflate them.
- **Out-of-scope items stay out.** No `HANDOFF.adoc` files (the controller's worktree-local `HANDOFF.md` per R13.1 remains normative; this format adds no separate handoff artifact). No per-element folders. No multiple assets of the same role per element. No concurrent index branches.

## Document Structure (mental map)

**`sparse-workflow.md`**: Problem → Core Abstraction → Separation of Concerns → Symbol Vocabulary → Goals → Project Init → Architecture (roles, state sources, Ralph loop, controller pseudo-code) → Eval Contract → Pairings → Source Conventions → AsciiDoc Plan Structure → Commit Format → Querying → Experience Brief → HANDOFF → Recursive Composition → Crash Recovery → Trust Model → Worktree Contents → Hooks → Sub-Agent Definition → Sandbox → Eval Sandbox Isolation → **Requirements (R0–R14)** → Constraints → Open Questions.

The Requirements section (R0–R14) is the normative core — every "Must"/"Should" lives there. **R14 is the C4 plan format adapter** — codifies all controller obligations specific to the C4 format (DSL parser, slug property, `_index` branches, single canonical index, property lifecycle, phase transitions, depth-scaled breakers indexed by C4 element type, etc.). When editing C4-format behavior, update R14 first, then propagate to the format spec.

**`c4-plan-format.adoc`**: Two-layer overview → File layout → `index.adoc` anatomy → Slug property and element-path derivation → Standard property keys (asset-reference + metadata) → Property lifecycle → Pairing assignment → Detail `.adoc` anatomy → Implementation assets → Branch hierarchy → Phase lifecycle → Constraint propagation → Attribute → Git-trailer mapping → Stability gradient → Worked example → Out of scope → AsciiDoc features used → Relation to `sparse-workflow.md`.

The plan-format spec defers to `sparse-workflow.md` (especially R14) for everything beyond the on-disk encoding. When in doubt about behavior (eval contract details, pairing semantics, sandbox isolation, controller obligations), consult the controller spec.

## Edit Discipline

Both specs read as single coherent documents with no version history. Don't add "(new)" callouts, change-logs, "as of vX" markers, or "previously" comparisons. Older drafts of the controller spec were deleted; the plan-format spec is the only one of its kind. Edit in place; the documents are the specs.

When making controller-spec changes that touch shape (new failure_class, new trailer, new requirement), check if the plan-format spec needs a corresponding update — they are layered and need to stay consistent.

## Editing Conventions

- **Controller spec (`sparse-workflow.md`)**: Markdown with AsciiDoc snippets in code fences. ASCII box-drawing diagrams are used heavily; preserve column alignment. Tables are GFM pipe syntax. Requirements use a 3-column table: id, requirement, priority (`Must` / `Should`). Code blocks tagged with language (`bash`, `yaml`, `json`, `asciidoc`, `typescript`, `markdown`).
- **Plan-format spec (`c4-plan-format.adoc`)**: AsciiDoc. Uses `[%autowidth]` tables, `[source,...]` blocks for code samples, callout markers (`<1>` etc.) for annotated examples. **Nested source blocks need asymmetric delimiters**: outer `[source,asciidoc]` blocks use `------` (six dashes) so inner `[source,gherkin]` / `[source,structurizr]` blocks with `----` don't close them prematurely. The Structurizr DSL keyword `workspace { ... }` inside a `[source,structurizr]` block is literal syntax — do not rename it even if other "workspace" references in prose change.
