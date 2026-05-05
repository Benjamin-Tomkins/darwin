---
name: plan-software
description: Guided C4 model builder — walks through the big picture, applications & services, and internal structure, producing AsciiDoc files ready for /darwin:worktree. Use when starting a new project from scratch.
---

# /darwin:plan-software

Guided creation of a C4 AsciiDoc plan. Produces `index.adoc` and sibling asset `.adoc` files ready for `/darwin:worktree`.

You are guiding the user through a structured architectural conversation. They may not know C4 terminology — use plain professional language throughout. Map their answers to C4 internally (softwareSystem, container, component) without exposing those terms unless the user is already comfortable with C4.

---

## Output Format (apply to every response)

Every response starts with a one-line status header using the current task name and the native task counts, then the question or action:

```
**<current task name>** [N done | 1 in progress | N open]
```

Single-line acknowledgment before each new question: `Got it: <captured value>`

One question per turn. No verbose preamble. Use A/B/C choices where natural.

---

## Phases

Use TaskCreate at startup — one task per phase, with these exact names:

1. Explore existing plans
2. Gather project details
3. Map the big picture
4. Identify applications & services
5. Detail internal structure
6. Plan implementation tasks
7. Write files

Mark each task completed immediately when the phase is done.

---

## Explore existing plans

Check for any existing plan files:
```bash
find . -name "index.adoc" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null
```
If any exist, show them and ask whether to start fresh or extend one.

---

## Gather project details

Ask in sequence (one per turn):

1. **Project name** — display name, e.g. "Payment Service"
2. **Identifier** — auto-derive from the name (lowercase, spaces→hyphens). Show it: "I'll use `<identifier>` as the identifier — looks good?" (yes / change to X)
3. **Plan directory** — default `plans/<identifier>/`. Show and confirm.
4. **One-line overview** — "What does this system do?"

Write nothing to disk yet.

---

## Map the big picture

_This step maps to C4 Level 1: System Context._

Frame it naturally: "Let's start with the big picture — who this system serves and what it connects to."

Three questions (one per turn):

**Q1 — Is this one product or several?**

"Are you building a single product, or multiple independent products that should be modelled separately?
A) Single product (most common)
B) Multiple independent products — list them"

If B: for each, collect display name and one-line description. (Each maps to a C4 softwareSystem.)

**Q2 — Who are the users?**

"Who are the people that use this system directly? (e.g. 'Customer, Admin, Support Agent') — or say 'none'"

Collect name + one-line role description for each. (These are C4 persons/actors; they go in the Overview prose, not the DSL.)

**Q3 — External connections**

"What external services or systems does this connect to? Think: payment providers, email/SMS services, databases you don't own, third-party APIs, legacy systems. (e.g. 'Stripe, SendGrid, legacy ERP') — or say 'none'"

Collect name + one-line description for each. (External systems go in prose only.)

After all three, show a text summary and ask to confirm:

```
Big picture:
  Product(s):  <name> (<identifier>)
  Users:       <list or none>
  Connects to: <list or none>

Confirm? (yes / revise)
```

Do not proceed until confirmed.

---

## Identify applications & services

_This step maps to C4 Level 2: Containers (independently deployable/runnable units — not Docker containers)._

Frame it: "Now let's map out what you'd actually deploy or run. These are the independently operating parts: a web app, a REST API, a background worker, a database, a message queue — anything that runs in its own process or environment."

For each product from the previous step, ask:

**"What are the separately deployable pieces of `<Product>`?**
List them (e.g. 'REST API, React frontend, PostgreSQL database, background worker') — or say 'single' if it's one deployable unit."

For each piece, collect (one turn per piece if there are several; batch if only 1-2):
- Display name
- Identifier (auto-derive, confirm)
- Technology (optional — "What technology? e.g. Node.js, PostgreSQL — skip if unsure")
- One-line responsibility ("What does it do?")

**Categorise each piece as one of:**
- `app` — user-facing application (web, mobile, desktop)
- `service` — API or backend process
- `worker` — background job processor, queue consumer
- `store` — database, cache, object storage, message broker
- `gateway` — API gateway, reverse proxy, BFF

This category affects whether it gets implementation tasks (apps, services, workers → yes; stores → typically not unless custom).

Show summary after all pieces for a product:

```
Applications & services in <Product>:
  <identifier>    <Name> (<category>) — <description>
  ...

Confirm? (yes / revise)
```

---

## Detail internal structure

_This step maps to C4 Level 3: Components. It is optional — use it only for complex services._

Frame it: "For any complex services, we can map out the internal building blocks — things like request handlers, business logic layers, data access modules, or external adapters. This is optional: skip it for straightforward services."

For each `service` or `worker` piece from the previous step, ask:

**"Does `<Name>` have distinct internal modules worth naming?**
Think: controllers, service classes, repositories, adapters, middleware layers.
A) Yes — list them (e.g. 'OrderController, PaymentAdapter, OrderRepository')
B) No — it's straightforward enough as-is"

If A: for each module collect name, identifier (auto-derive, confirm), one-line responsibility.

Show summary per service, confirm. It is fine and common to say No to all.

---

## Plan implementation tasks

_Determines which asset files and pairing stubs to generate._

Frame it: "Now let's decide which parts need implementation tasks. For each piece we'll implement, we generate a stub file that describes what the AI agent should build."

For each implementable element (apps, services, workers, and any internal modules — not stores):

Ask once per element:

```
For `<Name>` — what should the agent produce?
A) Implementation only
B) Implementation + automated tests
C) Implementation + tests + behaviour specs (BDD)
D) Tests only
E) Skip — no task needed
```

After collecting all choices, ask:

**"How should I name the pairing configurations?**
A) One shared pairing for all tasks (name: `<project-identifier>`)
B) Separate pairings per element — I'll ask as we go"

For option B, ask the pairing name for each element that has an implementation task.

---

## Write files

Build all file content in memory, then write to disk in one pass.

### `<plan-dir>/index.adoc`

```adoc
= <Project Name> Plan

:phase: spec

[source,structurizr]
------
workspace "<project-identifier>" {
  model {
<softwareSystem blocks, nested containers/components>
  }
}
------

== Overview

<overview text>

== Users

<user list: name — role description>

== External connections

<external system list: name — description>
```

Use six-dash `------` delimiters for the outer source block so inner `----` blocks don't prematurely close it.

**DSL rules:**
- Only elements with implementation tasks appear in the DSL (they need identifiers and asset properties).
- Users and external connections go in the Overview prose sections only — they have no identifier and no tasks.
- Nest services/workers/apps inside their parent softwareSystem block (as `container` elements).
- Nest internal modules inside their parent container block (as `component` elements).
- Every element in the DSL must have an `identifier` property.
- Asset property keys: `impl`, `tests`, `bdd`, `detail`. Metadata keys: `identifier`, `skills`.
- Stores (databases, queues) only appear in the DSL if they have a task (rare — usually custom stores).

**Example DSL:**

```
softwareSystem "Payment Service" "Processes card payments" {
  properties {
    identifier payment-service
  }
  container "API" "HTTP REST interface" {
    properties {
      identifier api
      impl api-impl.adoc
      tests api-tests.adoc
    }
    component "PaymentAdapter" "Stripe integration" {
      properties {
        identifier payment-adapter
        impl payment-adapter-impl.adoc
      }
    }
  }
  container "Worker" "Background job processor" {
    properties {
      identifier worker
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

Use `writable_globs: [tests/**]` for `tests` and `bdd` assets.

### Pairing stubs

One directory per unique pairing name, at `.claude/darwin-pairings/<name>/pairing.yaml`:

```yaml
name: <pairing-name>
agent:
  instructions: |
    TODO: Describe what the agent should build.
    Be specific about file paths, function signatures, and expected behaviour.
evals:
  - id: smoke
    type: command
    command: echo "TODO: replace with a real eval"
    timeout: 10
    on_fail:
      problem: "Pairing not configured"
      hypothesis: "pairing.yaml stub has not been filled in"
      failure_class: validation-fail
```

### After writing

Print a compact file tree (not file contents):

```
Written:
  <plan-dir>/index.adoc
  <plan-dir>/<element>-impl.adoc
  <plan-dir>/<element>-tests.adoc
  ...
  .claude/darwin-pairings/<name>/pairing.yaml

Next steps:
  1. Fill in the TODO sections in each task file — describe what should be built
  2. Update each pairing.yaml with real agent instructions and eval commands
  3. Run /darwin:worktree to start the implementation loop
```

Do NOT run /darwin:worktree automatically.

---

## Identifier Rules

Auto-derive identifiers from display names:
- Lowercase
- Spaces and underscores → hyphens
- Strip all non-alphanumeric except hyphens
- Collapse consecutive hyphens
- Strip leading/trailing hyphens

Examples: "API Server" → `api-server`, "User_Auth" → `user-auth`, "PostgreSQL DB" → `postgresql-db`

Always show the derived identifier and confirm before using it.

---

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
