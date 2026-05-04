---
name: darwin-new
description: Guided C4 model builder — walks through Context → Containers → Components → Asset stubs, producing AsciiDoc files ready for /darwin-worktree. Use when starting a new Darwin project from scratch.
---

# /darwin-new

Guided creation of a C4 AsciiDoc plan. Produces `index.adoc` and sibling asset `.adoc` files ready for `/darwin-worktree`.

---

## Output Format (apply to every response)

Every response starts with a one-line status header, then the question or action:

```
**Darwin New** — <Phase name> | <N>/<T> phases complete
```

Single-line acknowledgment before each new question: `Got it: <captured value>`

One question per turn. No verbose preamble. Use A/B/C choices where natural.

---

## Phases

Use TaskCreate at startup — one task per phase:

1. Project setup
2. Level 1: Context — systems and actors
3. Level 2: Containers — deployable units
4. Level 3: Components — logical units (optional)
5. Level 4: Assets — impl/tests/bdd stubs + pairing stubs
6. Write files and handoff

Mark each task completed immediately when the phase is done.

---

## Phase 1: Project Setup

Ask in sequence (one per turn):

1. **Project name** — display name, e.g. "Payment Service"
2. **Slug** — auto-derive: lowercase, spaces→hyphens, strip specials. Show derived slug and ask "Slug: `<slug>` — looks good?" (yes / change to X)
3. **Plan directory** — default `plans/<slug>/`. Show and confirm.
4. **One-line overview** — "What does this system do in one sentence?"

Write nothing to disk yet.

---

## Phase 2: Level 1 — Context

Three questions (one per turn):

**Q1 — Software systems:**
"Is this a single software system, or multiple independent systems?
A) Single system (most common)
B) Multiple systems — list them"

If B: collect name + one-line description for each.

**Q2 — Human actors:**
"Who are the direct human users? (e.g. 'Admin, Customer') — or say 'none'"

Collect name + role description for each.

**Q3 — External systems:**
"Does this interact with any external services? (e.g. 'Stripe, SendGrid, PostgreSQL') — or say 'none'"

Collect name + description for each.

After all three, show a text summary and ask to confirm:

```
Level 1 — Context:
  Systems:   <name> (<slug>)
  Actors:    <list or none>
  External:  <list or none>

Confirm? (yes / revise)
```

Do not proceed until confirmed.

---

## Phase 3: Level 2 — Containers

For each software system, ask: "What are the **deployable units** inside `<System>`? List them (e.g. 'REST API, Background Worker, PostgreSQL DB') — or say 'single' to treat the system as an atomic unit."

For each container collect (one turn each):
- Display name
- Slug (auto-derive, confirm)
- Technology (optional — ask "Technology? e.g. Node.js, PostgreSQL — or press enter to skip")
- One-line description

Show summary after all containers for a system:

```
Level 2 — Containers in <System>:
  <slug>   <Name> — <description>
  ...

Confirm? (yes / revise)
```

---

## Phase 4: Level 3 — Components

For each container that is not a database/queue/external system, ask:
"Does `<Container>` need to be decomposed into logical components? (e.g. 'UserService, AuthMiddleware, UserRepository')
A) Yes — list them
B) No — treat as atomic"

If A: for each component collect name, slug (auto-derive, confirm), one-line description.

Show summary, confirm. It is fine for all containers to be atomic.

---

## Phase 5: Level 4 — Assets

For each **implementable element** (components, or atomic containers — not databases, queues, or external services), determine which assets to create.

Ask once per element (batch the questions in one turn to save turns):

```
For `<element-slug>` — which assets should I generate?
A) impl only
B) impl + tests
C) impl + tests + BDD spec
D) tests only
E) skip (no assets)
```

After collecting all asset choices, ask for pairing configuration:
"What pairing should I use for implementation tasks?
A) Use a single default pairing for all elements (name it `<project-slug>`)
B) Use separate pairings per element — I'll name them as we go"

For option B, ask the pairing name for each element that has an impl asset.

---

## Phase 6: Write Files and Handoff

Build all file content in memory, then write to disk in one pass.

### `<plan-dir>/index.adoc`

```adoc
= <Project Name> Plan

:phase: spec

[source,structurizr]
------
workspace "<project-slug>" {
  model {
<softwareSystem blocks, nested containers/components>
  }
}
------

== Overview

<overview text>

== Context

=== Actors

<actor list>

=== External Systems

<external systems list>
```

Use six-dash `------` delimiters for the outer source block so inner `----` blocks in asset files don't prematurely close it.

**Structurizr DSL rules:**
- Only elements that will be implemented appear in the DSL.
- Actors and external systems go in the Overview prose, not the DSL (they have no slug and no tasks).
- Nest containers inside their parent softwareSystem block.
- Nest components inside their parent container block.
- Every element that has at least one asset property must have a `slug` property.
- Property keys: `slug`, `impl`, `tests`, `bdd`, `detail` (asset-reference), `skills` (metadata).

**Example DSL structure:**

```
softwareSystem "Payment Service" "Processes card payments" {
  properties {
    slug payment-service
  }
  container "API" "HTTP REST interface" {
    properties {
      slug api
      impl api-impl.adoc
      tests api-tests.adoc
    }
    component "AuthMiddleware" "JWT validation" {
      properties {
        slug auth-middleware
        impl auth-middleware-impl.adoc
      }
    }
  }
  container "Worker" "Background job processor" {
    properties {
      slug worker
      impl worker-impl.adoc
      tests worker-tests.adoc
    }
  }
}
```

### Asset stub files

One file per asset property. Filename must match the property value exactly.

```adoc
= <Element Name> — <Asset Type>

:phase: spec

[task]
pairing: <pairing-name>
writable_globs:
  - src/**

[task-state]
status: ◌

== <Asset Type title>

TODO: Describe what this task should produce.
```

For `tests` and `bdd` assets, use `writable_globs: [tests/**]`.

### Pairing stubs

One pairing per unique pairing name, at `.claude/darwin-pairings/<name>/pairing.yaml`:

```yaml
name: <pairing-name>
agent:
  instructions: |
    TODO: Describe what the agent should do.
    Be specific about file paths, function signatures, and expected behaviour.
evals:
  - id: smoke
    type: command
    command: echo "TODO: replace with a real eval command"
    timeout: 10
    on_fail:
      problem: "Pairing not configured"
      hypothesis: "pairing.yaml stub has not been filled in"
      failure_class: validation-fail
```

### After writing all files

Print a compact file tree (not file contents):

```
Written:
  <plan-dir>/index.adoc
  <plan-dir>/<element>-impl.adoc
  <plan-dir>/<element>-tests.adoc
  ...
  .claude/darwin-pairings/<name>/pairing.yaml

Next steps:
  1. Fill in TODO sections in each asset file — describe what each task should produce
  2. Replace pairing.yaml stubs with real agent instructions and eval commands
  3. Run /darwin-worktree <plan-dir>/index.adoc to start the Ralph loop
```

Do NOT run /darwin-worktree automatically. The user needs to review and complete the stubs first.

---

## Slug Rules

Auto-derive slugs from display names:
- Lowercase
- Spaces and underscores → hyphens
- Strip all non-alphanumeric except hyphens
- Collapse consecutive hyphens
- Strip leading/trailing hyphens

Examples: "API Server" → `api-server`, "User_Auth" → `user-auth`, "PostgreSQL DB" → `postgresql-db`

Always show the derived slug and confirm before using it.

---

## Stopping and Resuming

If the user says "stop" or "save progress" at any phase boundary, write a `.darwin-new-state.json` to the plan directory capturing all answers so far, and tell the user to run `/darwin-new --resume <plan-dir>` to continue.

If invoked with `--resume <plan-dir>`, read `.darwin-new-state.json`, show a summary of what was captured, and continue from the last incomplete phase.
