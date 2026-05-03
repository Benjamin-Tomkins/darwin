# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Shape

This repo is a **single-document design specification**, not an implementation. Contents:

- `sparse-workflow-v3.md` — the only artifact. ~1800 lines describing a self-healing state machine for AI agent + evaluator pairs. (The `-v3` in the filename is historical; older versions have been deleted and the document does not reference them.)

There is no source code, no build, no tests, no package manager, and no CI. Treat tasks here as **spec editing**, not software engineering. Don't propose adding tooling (linters, CI, package.json) unless explicitly asked.

## The Spec's Core Abstraction

The document specifies **(agent, eval) → controller**: a task-agnostic parent controller that drives a Ralph loop where any agent template paired with any eval pipeline produces a self-healing system. Understanding this triad is the prerequisite for any meaningful edit:

- **Agent** — does the work. Has no test access, no git, no Bash unless explicitly granted by its pairing. Each retry is a FRESH subagent invocation (resumption forbidden).
- **Eval** — judges the work. Returns a fixed result envelope (`verdict`, `failure_class`, `consumes_attempt`, `problem`, `hypothesis`, `evidence`). Seven standard types: `command`, `schema`, `rubric`, `comparative`, `metric-threshold`, `human-in-the-loop`, `composite`.
- **Controller** — owns the loop. Reads plan.adoc, spawns agents, runs evals in an isolated sandbox, commits ⊗/↺/●/⚠/↻, enforces circuit breakers, generates HANDOFF.md on exhaustion. The state machine lives here, NOT in the `SubagentStop` hook.

**Every commit is the result of an evaluation, not an implementation.** The branch is an evaluation corpus.

## Invariants That Must Hold When Editing

These are load-bearing across the spec — changes to one almost always require corresponding changes elsewhere:

1. **Recursive separation of concerns** — agent ≠ judge; controller ≠ what-it-judges; plan author ≠ agent; eval LLM ≠ agent's models. If an edit lets any of these collapse, it's wrong.
2. **Judge-model separation** — for any `rubric` eval, the resolved judge model must NOT appear in the agent's escalation ladder. Validated at pairing-load.
3. **Commit pairing** — every `⊗` is immediately followed by exactly one `↺` (real inverse-diff commit, not empty); `●` is terminal; `⚠` and `↻` are standalone and do NOT consume an attempt.
4. **Git is authoritative** — `plan.adoc`'s `[task-state]` is a rendered view, regenerable from Git trailers. Never describe plan.adoc as the source of truth.
5. **Trailer vocabulary** — machine-readable fields go in Git trailers (`Try-Status`, `Pairing`, `Eval-Id`, `Eval-Type`, `Judge-Model`, `Tier`, `Attempt`, `Model`, `Ladder-Id`, `Evals-Passed`, etc.). Subject lines carry the symbol + short reason for humans only. Don't introduce new metadata as bracket-tags or subject-line fields.
6. **Eval contract is fixed** — the JSON envelope schema is the stable interface. Adding a new eval type means defining how it produces this envelope, not extending the envelope.
7. **Symbol vocabulary is fixed** — `◌◎⊗●⊖⊘` (status), `◈◉` (provenance), `↺↻⚠` (loop action). Don't invent new symbols; reuse existing ones.

## Document Structure (mental map)

The spec is organized roughly as: Problem → Core Abstraction → Separation of Concerns → Symbol Vocabulary → Goals → Project Init → Architecture (roles, state sources, Ralph loop, controller pseudo-code) → Eval Contract → Pairings → Source Conventions → AsciiDoc Plan Structure → Commit Format → Querying → Experience Brief → HANDOFF → Recursive Composition → Crash Recovery → Trust Model → Worktree Contents → Hooks → Sub-Agent Definition → Sandbox → Eval Sandbox Isolation → **Requirements (R0–R13)** → Constraints → Open Questions.

The Requirements section (R0–R13) is the normative core — every "Must"/"Should" lives there. Prose sections above it are explanatory and must stay consistent with it. When editing behavior, update the requirement first, then propagate to the prose.

## Edit Discipline

The spec reads as a single coherent document with no version history. Don't add "(new)" callouts, change-logs, "as of vX" markers, or "previously" comparisons. There is no prior version to compare against — older drafts have been deleted. Edit in place; the document is the spec.

## Editing Conventions Observed in the File

- ASCII box-drawing diagrams (`┌─┐│└┘`) used heavily; preserve column alignment when editing them.
- Tables use GitHub-flavored markdown pipe syntax.
- Code blocks are tagged with language (`bash`, `yaml`, `json`, `asciidoc`, `typescript`, `markdown`).
- Requirements use a 3-column table: id, requirement, priority (`Must`/`Should`).
- The file mixes Markdown with AsciiDoc snippets (the spec describes an AsciiDoc-based plan format); keep AsciiDoc syntax inside code fences.
