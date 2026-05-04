# Scaffold Plugin Architecture — Design

## Section 1: Plugin Structure

The sparse-workflow controller ships as a Claude Code plugin. Claude Code IS the controller — an agentic session following the `scaffold-worktree.md` skill. No standalone process, daemon, or SDK loop is required.

**Plugin layout:**

```
~/.claude/plugins/superpowers/
├── skills/
│   ├── scaffold-init.md          # /scaffold-init — project setup, runtime detection, pairing validation
│   └── scaffold-worktree.md      # /scaffold-worktree — Ralph loop controller
├── hooks/
│   ├── hooks.json                # registers WorktreeCreate + SubagentStop
│   ├── worktree-create.sh        # sparse checkout, .claude/ injection, skip-worktree
│   └── subagent-stop.sh          # writes signal to ~/.claude/scaffold-state/<repo-hash>/<task-slug>/signal.json
└── helpers/c4/
    ├── detect-runtime.sh         # Bun → Node 20+ → Deno; writes runtime.json
    ├── rt.sh                     # thin wrapper: delegates to detected pm
    ├── dist/
    │   ├── parse-index.js        # index.adoc → element tree (compiled ESM)
    │   ├── branch-name.js        # slug chain → canonical branch string
    │   ├── format-trailers.js    # commit metadata → Git trailer block
    │   ├── validate-property.js  # property lifecycle guard
    │   └── resolve-phase-transition.js
    └── src/                      # TypeScript source
```

State persistence is via Git trailers on `agent/<slug>` branches. `~/.claude/scaffold-state/` holds ephemeral runtime state (signal files, `runtime.json`) that does not enter version control.

---

## Section 2: Skill Layer

Two skills. Both are Markdown files; the controller session follows their instructions directly via the Bash and Agent tools.

**`/scaffold-init`** (one-time setup per project):
1. Detects JS runtime (`bun` → `node` 20+ → `deno`); stores `~/.claude/scaffold-state/runtime.json`; blocks if none found
2. Adds `.claude/settings.json`, `.claude/agents/`, `.claude/CLAUDE.md` to project `.gitignore`
3. Validates all `.claude/scaffold-pairings/*/pairing.yaml` files: schema, judge-model separation, slug uniqueness
4. Verifies `escalation-ladder.json` exists and is not stale (default warn threshold: 30d)
5. Reports summary: pairings loaded, runtime detected, ladder-id

**`/scaffold-worktree <plan.adoc> [--base <ref>] [--resume <slug>]`** (per-run):
- Parses `plan.adoc` or `index.adoc` via the `parse-index` helper → element tree with asset property filenames
- For each asset property (e.g. `impl: auth-impl.adoc`), reads the asset `.adoc` to extract its `[task]` block (pairing name, `writable_globs`, stop criteria). This is the C4-specific second step — `parse-index` only reads `index.adoc`; the per-asset config lives in the sibling asset files.
- Loads the named pairing from `.claude/scaffold-pairings/<name>/pairing.yaml`. The pairing is the complete spec for one task: agent template (tools, scope, CLAUDE.md template, stop criteria) + eval pipeline (ordered, cheapest-first) + escalation-ladder overrides + circuit-breaker limits. If `pairing:` is omitted from the `[task]` block, the orchestrator infers it from element type and phase.
- Builds task queue; reconstructs per-task state from Git trailers + `[task-state]` blocks
- Drives the Ralph loop (see Section 5)
- Monitors approximate context token usage; checkpoints at 80% of session limit

---

## Section 3: Hook Layer

**`WorktreeCreate`** — replaces Claude Code's default `git worktree add`.

The hook receives the planned worktree path on stdin JSON. It:
1. Processes `.worktreeinclude` manually (native processing is disabled when this hook is registered)
2. Creates the worktree at `~/.claude/scaffold-worktrees/<repo-hash>/<task-slug>/`
3. Applies sparse checkout from `pairing.scope.readonly_globs + writable_globs`
4. Injects `.claude/` contents (settings, agent definition, CLAUDE.md) from pairing-specific templates
5. Runs `git update-index --skip-worktree` on each injected file so agent-local edits don't propagate to other branches
6. Returns the absolute worktree path on stdout

`chmod` is not used — OS-level sandbox enforcement (Seatbelt on macOS, bubblewrap on Linux) is the primary write boundary for subprocesses. `permissions.deny/allow` covers native Edit/Write/Read tools. Both are required; `chmod` adds nothing on top.

**`SubagentStop`** — signal hook only.

Receives `session_id` (parent session), `cwd` (worktree path), `transcript_path`, `agent_id` on stdin JSON. Derives the signal key from `cwd` by stripping the worktree base prefix:

```
cwd:         ~/.claude/scaffold-worktrees/a3f9c1/auth-rs256
signal path: ~/.claude/scaffold-state/a3f9c1/auth-rs256/signal.json
```

One signal path per task (not per session), so concurrent tasks on distinct branches never collide. The path is pre-computable by the controller before spawning and is stored in `[task-state]` as `signal_path`. Does not decide outcome — the controller reads the signal and drives all decisions.

Note: `session_id` in the hook input is the **parent** controller's session ID, not the subagent's. The subagent's own session ID is not exposed by the hook. The `name:` frontmatter field (set to `<task-slug>-attempt-<N>`) may equal `agent_id` in the hook input, but this mapping is not confirmed in the Claude Code documentation; signal routing uses `cwd`-derived paths, not `agent_id`.

**Sandbox configuration** injected per-task:

```json
{
  "sandbox": {
    "enabled": true,
    "allowUnsandboxedCommands": false,
    "failIfUnavailable": true,
    "filesystem": {
      "allowWrite": ["<from pairing.scope.writable_globs, expanded as explicit paths>"],
      "denyWrite": ["."],
      "denyRead": ["./.git/**", "../**/.git/**", "~/.ssh", "~/.aws", "./.env*", "./secrets/**"]
    }
  },
  "permissions": {
    "allow": ["<expanded from pairing.scope>"],
    "deny": ["Bash(*)", "Read(./.git/**)", "<pairing deny rules + project defaults>"]
  }
}
```

---

## Section 4: TypeScript Helper Layer

Five pure-function CLIs compiled to plain ESM (`dist/`) at plugin build time. Any Bun / Node 20+ / Deno installation can execute them without a compile step at runtime.

| Helper | Input | Output |
|---|---|---|
| `parse-index` | `index.adoc` path | JSON element tree (slug, type, properties, children) |
| `branch-name` | slug array + `--index` flag | Canonical branch string |
| `format-trailers` | commit metadata JSON on stdin | Git trailer block |
| `validate-property` | element JSON + key + phase | Exit 0 = valid; exit 1 + stderr = violation |
| `resolve-phase-transition` | `index.adoc` + element slug + new phase | Exit 0 = valid; emits `Phase-Transition: true` trailer if pairing-hash change is permitted without tripping R7.18's hash-drift halt |

**Runtime detection** (once, at `/scaffold-init`):

```bash
# scripts/detect-runtime.sh — probes in preference order
if command -v bun;       then emit bun   runtime JSON
elif node ≥ 20 available; then emit node  runtime JSON
elif command -v deno;    then emit deno  runtime JSON (execution-only; npm/node still needed for build)
else block with error
fi
# stores result in ~/.claude/scaffold-state/runtime.json
```

`scripts/rt.sh` reads `runtime.json` and delegates all `pm install` / `pm run` / `pm test` commands to the detected package manager. Compiled helpers in `dist/` are invoked by the controller skill via Bash as:

```bash
EXEC=$(jq -r '.exec' ~/.claude/scaffold-state/runtime.json)
FLAGS=$(jq -r '.run_flags[]' ~/.claude/scaffold-state/runtime.json)
$EXEC $FLAGS ~/.claude/plugins/superpowers/helpers/c4/dist/parse-index.js --file ./index.adoc
```

---

## Section 5: Ralph Loop Data Flow

**Entry:** user invokes `/scaffold-worktree docs/project/index.adoc`

**Plan parsing:** skill calls `parse-index` helper → element tree → task queue (all elements with asset-reference properties not yet `●`).

**State reconstruction (per task):**

```bash
git log agent/<project>/<element-path>/<asset-key> \
  --format='%(trailers:key=Try-Status,key=Tier,key=Pairing-Hash,key=Eval-Id)'
```

Derives: attempt count, current tier, Pairing-Hash (verified against on-disk pairing), experience brief (trailers where `Try-Status: fail`).

**Loop kernel (per task):**

```
1.  Read asset .adoc [task] block → resolve pairing name → load pairing YAML
    (pairing defines: agent template, eval pipeline, scope, escalation, circuit breakers)
2.  Verify Pairing-Hash against on-disk pairing YAML; halt if mismatch (R7.18)
3.  Build experience brief from fail trailers
4.  Compute deterministically (before spawning):
      worktree_path = ~/.claude/scaffold-worktrees/<repo-hash>/<task-slug>/
      signal_path   = ~/.claude/scaffold-state/<repo-hash>/<task-slug>/signal.json
      agent_name    = <task-slug>-attempt-<N>
5.  Write status: running + agent_name + worktree_path + signal_path to [task-state]
                                                        ← crash-recovery commit point
6.  Set name: agent_name in agent frontmatter (for observability in transcripts/logs)
7.  WorktreeCreate hook → creates worktree at worktree_path; sparse checkout + .claude/ injection
    (uses pairing.scope.writable_globs + readonly_globs for sparse checkout;
     pairing's agent template populates .claude/CLAUDE.md, settings.json, agents/task-agent.md)
8.  Spawn subagent (Agent tool, fresh invocation — blocks until subagent stops)
9.  SubagentStop hook fires → derives signal_path from cwd; writes signal file
10. Controller reads signal → snapshot staged diff (git diff --staged in worktree)
11. Run eval pipeline in isolated sandbox (pairing.evals, cheapest-first, declared order)
12. Verdict:
      pass  → commit ● + trailers → update [task-state] → done
      fail  → commit ⊗ + ↺ → check circuit breakers → retry/escalate/widen/HANDOFF
```

**Crash and resume recovery:**

| [task-state] on resume | Signal at `signal_path`? | Staged changes in `worktree_path`? | Recovery action |
|---|---|---|---|
| `status: running` | yes | — | Process signal; run eval; commit. Do not re-spawn. |
| `status: running` | no | yes | Run eval on staged diff; commit result. |
| `status: running` | no | no | Discard worktree; reset to `◌`; retry at same tier. |
| `status: ⊗` with no `↺` | — | — | Complete rollback; then retry. |

**Context limit checkpoint:** at 80% of session context, the controller finishes the current task, flushes all open `[task-state]` blocks to disk, and surfaces: "context limit approaching — re-invoke `/scaffold-worktree` to continue." The next session reconstructs cleanly from Git + `[task-state]`.

**Concurrency:** unordered tasks fan out; ordered/dependent tasks sequence on upstream `●`. All ref-mutating Git operations (commit, branch update) are serialized by the controller regardless of concurrency level.

**Termination:** all tasks `●` → session ends with summary report. Any task `⊖` → HANDOFF.md generated, controller pauses; `/scaffold-worktree --resume <slug>` re-enters the loop.

---

## Out of Scope

- Standalone controller process (Claude Code IS the controller)
- CI/CD integration (invocation is always by a human-initiated Claude Code session)
- Windows support (Seatbelt/bubblewrap sandbox not available)
- Deno as a build/test runtime (execution-only; vitest requires Bun or Node)
- Per-element `.gitignore` files (project `.gitignore` seeded by `/scaffold-init` handles all injected operational files)

---

## Relation to `sparse-workflow.md`

This design is the deployment layer for the controller specified in `sparse-workflow.md`. It resolves:

- **Open Question #10** (now closed): Claude Code IS the controller — skill-driven agentic session
- **Hook architecture**: WorktreeCreate + SubagentStop as specified in the Hook Architecture section
- **R10** (skill interface): `/scaffold-init` + `/scaffold-worktree` are the two entry points
- **R8.4–R8.6** (crash recovery): signal file + staged-diff resume paths
- **R7.19–R7.20**: pre-spawn `[task-state]` write and context-limit checkpoint

The controller spec remains normative for all loop semantics, eval contract, pairing schema, trailer vocabulary, and symbol definitions. This design doc covers only the Claude Code plugin shape and deployment mechanics.
