# Darwin Plugin Architecture — Design

## Section 1: Plugin Structure

The sparse-workflow controller ships as a Claude Code plugin. Claude Code IS the controller — an agentic session following the `darwin-worktree.md` skill. No standalone process, daemon, or SDK loop is required.

**Plugin layout:**

```
~/.claude/plugins/darwin/
├── skills/
│   ├── darwin-init.md          # /darwin-init — project setup, runtime detection, pairing validation
│   └── darwin-worktree.md      # /darwin-worktree — Ralph loop controller
├── hooks/
│   ├── hooks.json                # registers WorktreeCreate + SubagentStop
│   ├── worktree-create.sh        # sparse checkout, .claude/ injection, skip-worktree
│   └── subagent-stop.sh          # writes signal to ~/.claude/darwin-state/<repo-hash>/<task-slug>/signal.json
└── helpers/c4/
    ├── detect-runtime.sh         # Bun → Node 20+ → Deno; writes runtime.json
    ├── rt.sh                     # thin wrapper: delegates to detected pm
    ├── bin/
    │   ├── parse-index.js        # index.adoc → element tree (compiled ESM)
    │   ├── branch-name.js        # slug chain → canonical branch string
    │   ├── format-trailers.js    # commit metadata → Git trailer block
    │   ├── validate-property.js  # property lifecycle guard
    │   ├── resolve-phase-transition.js
    │   └── token-delta.js        # two token snapshots → delta {input, output, thinking}
    └── src/                      # TypeScript source
```

State persistence is via Git trailers on `agent/<slug>` branches. `~/.claude/darwin-state/` holds ephemeral runtime state (signal files, `runtime.json`) that does not enter version control.

---

## Section 2: Skill Layer

Two skills. Both are Markdown files; the controller session follows their instructions directly via the Bash and Agent tools.

**`/darwin-init`** (one-time setup per project):
1. Detects JS runtime (`bun` → `node` 20+ → `deno`); stores `~/.claude/darwin-state/runtime.json`; blocks if none found
2. Adds `.claude/settings.json`, `.claude/agents/`, `.claude/CLAUDE.md` to project `.gitignore`
3. Validates all `.claude/darwin-pairings/*/pairing.yaml` files: schema, judge-model separation, slug uniqueness
4. Verifies `escalation-ladder.json` exists and is not stale (default warn threshold: 30d)
5. Reports summary: pairings loaded, runtime detected, ladder-id

**`/darwin-worktree <plan.adoc> [--base <ref>] [--resume <slug>]`** (per-run):
- Parses `plan.adoc` or `index.adoc` via the `parse-index` helper → element tree with asset property filenames
- For each asset property (e.g. `impl: auth-impl.adoc`), reads the asset `.adoc` to extract its `[task]` block (pairing name, `writable_globs`, stop criteria). This is the C4-specific second step — `parse-index` only reads `index.adoc`; the per-asset config lives in the sibling asset files.
- Loads the named pairing from `.claude/darwin-pairings/<name>/pairing.yaml`. The pairing is the complete spec for one task: agent template (tools, scope, CLAUDE.md template, stop criteria) + eval pipeline (ordered, cheapest-first) + escalation-ladder overrides + circuit-breaker limits. If `pairing:` is omitted from the `[task]` block, the orchestrator infers it from element type and phase.
- Detects **co-evolving pairs**: elements with both `tests:` and `impl:` asset properties. These run as concurrent Ralph loops; the controller enforces the tests gate (R12.9) before allowing `impl` to pass.
- Builds task queue; reconstructs per-task state from Git trailers + `[task-state]` blocks
- Drives the Ralph loop (see Section 5)
- Monitors approximate context token usage; checkpoints at 80% of session limit

---

## Section 3: Hook Layer

**`WorktreeCreate`** — replaces Claude Code's default `git worktree add`.

The hook receives the planned worktree path on stdin JSON. It:
1. Processes `.worktreeinclude` manually (native processing is disabled when this hook is registered)
2. Creates the worktree at `~/.claude/darwin-worktrees/<repo-hash>/<task-slug>/`
3. Applies sparse checkout from `pairing.scope.readonly_globs + writable_globs`
4. Injects `.claude/` contents (settings, agent definition, CLAUDE.md) from pairing-specific templates
5. Runs `git update-index --skip-worktree` on each injected file so agent-local edits don't propagate to other branches
6. Returns the absolute worktree path on stdout

`chmod` is not used — OS-level sandbox enforcement (Seatbelt on macOS, bubblewrap on Linux) is the primary write boundary for subprocesses. `permissions.deny/allow` covers native Edit/Write/Read tools. Both are required; `chmod` adds nothing on top.

**`SubagentStop`** — signal hook only.

Receives `session_id` (parent session), `cwd` (worktree path), `transcript_path`, `agent_id` on stdin JSON. Derives the signal key from `cwd` by stripping the worktree base prefix:

```
cwd:         ~/.claude/darwin-worktrees/a3f9c1/auth-rs256
signal path: ~/.claude/darwin-state/a3f9c1/auth-rs256/signal.json
```

Also reads `transcript_path` and sums `input_tokens`, `output_tokens`, and `thinking_tokens` across all API turns in the subagent session. Writes `signal.json` containing both the stop metadata and `agent_tokens: {input, output, thinking}`.

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
      "denyRead": [
        ".git",
        "~/.ssh", "~/.aws", "~/.gnupg",
        ".env", ".env.local", ".env.production", ".env.test",
        "secrets"
      ]
    }
  },
  "permissions": {
    "allow": ["<expanded from pairing.scope>"],
    "deny": ["Bash(*)", "Read(.git/)", "<pairing deny rules + project defaults>"]
  }
}
```

**Implementation notes:**

- **`allowWrite` / `denyWrite` precedence**: The Claude Code docs confirm `allowRead` overrides `denyRead`, but do not explicitly confirm the equivalent for `allowWrite` / `denyWrite`. At implementation time, verify that `allowWrite` paths punch through `denyWrite: ["."]`. If they do not, the fallback is to drop `denyWrite` and rely solely on `allowWrite` (which restricts beyond the default CWD-is-writable behaviour) combined with `permissions.deny` rules for the Edit/Write tools.
- **Glob patterns**: `sandbox.filesystem` path support for globs is not confirmed in Claude Code documentation. Paths above use concrete directory and file names. At implementation time, test whether glob patterns are supported before using them; otherwise enumerate specific paths.
- **Parent git directory**: The `../\**/.git/**` entry from earlier drafts was removed. Worktrees live at `~/.claude/darwin-worktrees/`; relative traversal to the project git dir is an infrastructure concern. Accessing it by absolute path would be project-specific. Network-layer and VM isolation (see setup README) is the appropriate mitigation.
- **Network isolation**: Not configured at the per-task sandbox level. Darwin should be run inside an Incus container or isolated VM to enforce network boundaries at the infrastructure layer. The setup README must document this deployment requirement.

---

## Section 4: TypeScript Helper Layer

Six pure-function CLIs compiled to plain ESM (`bin/`) at plugin build time. Any Bun / Node 20+ / Deno installation can execute them without a compile step at runtime.

| Helper | Input | Output |
|---|---|---|
| `parse-index` | `index.adoc` path | JSON element tree (slug, type, properties, children) |
| `branch-name` | slug array + `--index` flag | Canonical branch string |
| `format-trailers` | commit metadata JSON on stdin | Git trailer block |
| `validate-property` | element JSON + key + phase | Exit 0 = valid; exit 1 + stderr = violation |
| `resolve-phase-transition` | `index.adoc` + element slug + new phase | Exit 0 = valid; emits `Phase-Transition: true` trailer if pairing-hash change is permitted without tripping R7.18's hash-drift halt |
| `token-delta` | two token snapshot JSONs `{input, output, thinking}` on stdin | Delta JSON `{input_delta, output_delta, thinking_delta}` for one operation boundary |

**Runtime detection** (once, at `/darwin-init`):

```bash
# scripts/detect-runtime.sh — probes in preference order
if command -v bun;       then emit bun   runtime JSON
elif node ≥ 20 available; then emit node  runtime JSON
elif command -v deno;    then emit deno  runtime JSON (execution-only; npm/node still needed for build)
else block with error
fi
# stores result in ~/.claude/darwin-state/runtime.json
```

`scripts/rt.sh` reads `runtime.json` and delegates all `pm install` / `pm run` / `pm test` commands to the detected package manager. Compiled helpers in `bin/` are invoked by the controller skill via Bash as:

```bash
EXEC=$(jq -r '.exec' ~/.claude/darwin-state/runtime.json)
FLAGS=$(jq -r '.run_flags[]' ~/.claude/darwin-state/runtime.json)
$EXEC $FLAGS ~/.claude/plugins/darwin/helpers/c4/bin/parse-index.js --file ./index.adoc
```

---

## Section 5: Ralph Loop Data Flow

**Entry:** user invokes `/darwin-worktree docs/project/index.adoc`

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
      worktree_path = ~/.claude/darwin-worktrees/<repo-hash>/<task-slug>/
      signal_path   = ~/.claude/darwin-state/<repo-hash>/<task-slug>/signal.json
      agent_name    = <task-slug>-attempt-<N>
5.  Write status: running + agent_name + worktree_path + signal_path to [task-state]
                                                        ← crash-recovery commit point
6.  Set name: agent_name in agent frontmatter (for observability in transcripts/logs)
7.  WorktreeCreate hook → creates worktree at worktree_path; sparse checkout + .claude/ injection
    (uses pairing.scope.writable_globs + readonly_globs for sparse checkout;
     pairing's agent template populates .claude/CLAUDE.md, settings.json, agents/task-agent.md)
8.  Spawn subagent (Agent tool, fresh invocation — blocks until subagent stops)
9.  SubagentStop hook fires → reads transcript_path; extracts cumulative token usage;
    writes signal.json with {agent_tokens: {input, output, thinking}, ...stop metadata}
10. Controller reads signal → reads agent_tokens → snapshot staged diff (git diff --staged)
11. Run eval pipeline in isolated sandbox (pairing.evals, cheapest-first, declared order):
    for each eval step:
      run eval → result envelope + API response metadata
      accumulate: eval_input += response.usage.input_tokens
                  eval_output += response.usage.output_tokens
                  eval_thinking += response.usage.thinking_tokens
      if fail → short-circuit
12. Verdict:
      pass  → commit ● + Agent-*/Eval-* token trailers + remaining trailers
               → update [task-state] → done
      fail  → commit ⊗ + Agent-*/Eval-* token trailers + remaining trailers
               → ↺ → check circuit breakers → retry/escalate/widen/HANDOFF
```

Token trailers on every ⊗/● commit give the full cost of that attempt node. `Agent-Thinking-Tokens` and `Eval-Thinking-Tokens` are 0 for non-thinking models. The growing `Agent-Input-Tokens` across retries reflects the expanding experience brief — a signal of task complexity available from the Git log without external tooling.

**Crash and resume recovery:**

| [task-state] on resume | Signal at `signal_path`? | Staged changes in `worktree_path`? | Recovery action |
|---|---|---|---|
| `status: running` | yes | — | Process signal; run eval; commit. Do not re-spawn. |
| `status: running` | no | yes | Run eval on staged diff; commit result. |
| `status: running` | no | no | Discard worktree; reset to `◌`; retry at same tier. |
| `status: ⊗` with no `↺` | — | — | Complete rollback; then retry. |

**Context limit checkpoint:** at 80% of session context, the controller finishes the current task, flushes all open `[task-state]` blocks to disk, and surfaces: "context limit approaching — re-invoke `/darwin-worktree` to continue." The next session reconstructs cleanly from Git + `[task-state]`.

**Concurrency:** unordered tasks fan out; ordered/dependent tasks sequence on upstream `●`. All ref-mutating Git operations (commit, branch update) are serialized by the controller regardless of concurrency level.

**Co-evolving pairs (`tests:` + `impl:` on the same element):**

`tests` and `impl` run as independent concurrent Ralph loops. Before running `impl`'s eval pipeline, the controller performs a **tests gate check** (pure Git — no external state):

```
tests_last_pass = timestamp of latest ● on agent/<slug>/tests
impl_last_fail  = timestamp of latest ⊗ on agent/<slug>/impl

gate open   = tests_last_pass > impl_last_fail   (tests seen all current failures)
gate closed = tests not ● yet, OR gate stale
```

Gate closed → `failure_class: deps-missing`, `consumes_attempt: false`. Impl waits without burning an attempt.

When impl generates a new `⊗` after tests `●` (gate goes stale), the controller triggers a **tests re-evaluation** — re-running the tests eval pipeline with the impl's `⊗` trailer corpus appended to every rubric judge prompt:

```
## Implementation failure history — assess test coverage of these scenarios:
Attempt 3: PKCS#1 vs PKCS#8 key format not handled
  hypothesis: validator assumed PKCS#8 only
  evidence: "invalid key format" at validator.ts:67

Attempt 4: empty token not handled
  evidence: null pointer at validator.ts:45
```

This applies equally to subjective evals (LLM-judged architectural decisions, rubric-scored design reviews) and command evals. For command evals the test artifact is re-executed unchanged; the gate staleness check is still enforced. For rubric evals the judge gains concrete failure evidence to assess coverage against.

**Model tier strategy for co-evolving pairs:**

The tests agent uses the standard escalation ladder — entry tier first, escalating on repeated failure, same as any other Ralph loop. For cross-task re-evaluation attempts (triggered by gate staleness), the tests agent starts at `tier-above` entry rather than entry, reflecting that the simpler model's test suite was insufficient to track impl failures.

The cross-task rubric judge is unconditionally `judge_model: top` — the highest available tier — regardless of the tests agent's current tier. Standard evals in the tests pipeline (command evals, spec-coverage rubric) use their declared `judge_model`. Only the cross-task rubric is always top-tier, because assessing whether a test suite covers an evolving failure corpus across subjective, structural, and architectural dimensions requires broader reasoning than a tier-relative judge can reliably provide.

The top-tier judge's findings propagate to both loops:
- **Tests experience brief** receives: coverage gaps the judge identified (what tests are missing)
- **Impl experience brief** receives: structural or architectural issues the judge surfaced that weren't previously in the impl failure corpus (e.g. "distributed transaction concern not captured in any test or attempt")

Neither agent has to re-derive what the top-tier model already reasoned. The insight flows directly into the next attempt of each loop.

Re-evaluation attempts triggered by gate staleness are classified `cross-task-reeval` and do not count against `max_attempts_total`. A separate `max_reeval_attempts` limit (default: 3) prevents runaway loops; exhausting it generates HANDOFF on the tests task.

**Termination:** all tasks `●` → session ends with summary report. Any task `⊖` → HANDOFF.md generated, controller pauses; `/darwin-worktree --resume <slug>` re-enters the loop.

---

## Out of Scope

- Standalone controller process (Claude Code IS the controller)
- CI/CD integration (invocation is always by a human-initiated Claude Code session)
- Windows support (Seatbelt/bubblewrap sandbox not available)
- Deno as a build/test runtime (execution-only; vitest requires Bun or Node)
- Per-element `.gitignore` files (project `.gitignore` seeded by `/darwin-init` handles all injected operational files)
- Network isolation at the per-task sandbox level — delegated to deployment infrastructure (Incus container or isolated VM). A setup README must document the recommended deployment topology for secure Darwin use.

---

## Relation to `sparse-workflow.md`

This design is the deployment layer for the controller specified in `sparse-workflow.md`. It resolves:

- **Open Question #10** (now closed): Claude Code IS the controller — skill-driven agentic session
- **Hook architecture**: WorktreeCreate + SubagentStop as specified in the Hook Architecture section
- **R10** (skill interface): `/darwin-init` + `/darwin-worktree` are the two entry points
- **R8.4–R8.6** (crash recovery): signal file + staged-diff resume paths
- **R7.19–R7.20**: pre-spawn `[task-state]` write and context-limit checkpoint
- **R12.8–R12.16**: co-evolving `tests`/`impl` pairs, tests gate, gate staleness, cross-task experience injection, re-evaluation attempt classification, model tier strategy, bidirectional experience propagation

The controller spec remains normative for all loop semantics, eval contract, pairing schema, trailer vocabulary, and symbol definitions. This design doc covers only the Claude Code plugin shape and deployment mechanics.
