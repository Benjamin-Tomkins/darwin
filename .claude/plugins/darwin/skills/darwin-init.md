# /darwin-init

Initialize a project for use with Darwin. Follow these steps in order. Stop and report any error before proceeding to the next step.

---

## Preamble

```bash
PLUGIN="$(git rev-parse --show-toplevel)/.claude/plugins/darwin"
```

---

## Step 1: Detect JS runtime

Run:
```bash
bash "$PLUGIN/helpers/c4/detect-runtime.sh"
```

If the script fails or exits non-zero, stop and report: "No supported JS runtime found. Install Bun, Node.js 20+, or Deno before running /darwin-init."

Verify the result:
```bash
cat ~/.claude/darwin-state/runtime.json
```

Expected: a JSON object with keys `runtime`, `exec`, `pm`, `run_flags`.

---

## Step 2: Update .gitignore

Read the project `.gitignore`. For each of the following lines that is NOT already present, append it:

```
.claude/settings.json
.claude/agents/
.claude/CLAUDE.md
.claude/escalation-ladder.json
```

Use the Edit tool to make any additions. Do not remove existing content.

---

## Step 3: Validate pairings

List all pairing files:
```bash
ls .claude/darwin-pairings/*/pairing.yaml 2>/dev/null || echo "(none)"
```

For each `pairing.yaml` found:

**3a. Required fields.** Parse the YAML using `cat`. Verify these keys are present at the top level: `name`, `agent`, `evals`. If any are missing, record: "Pairing <filename>: missing required field(s): <list>."

**3b. Judge-model separation.** For each eval entry with `type: rubric`:
- Read its `judge_model` value.
- Read `~/.claude/escalation-ladder.json` and collect all `ladder[].model` values.
- If `judge_model` matches any ladder model, record: "Pairing <name>: judge-model separation violation — judge_model '<model>' appears in escalation ladder."

**3c. Slug uniqueness.** Collect all `name` values across all pairings. If any value appears more than once, record: "Duplicate pairing name: '<name>'."

If any errors were recorded, print them all and stop with: "Pairing validation failed. Fix the errors above before running /darwin-worktree."

If no errors: "All pairings valid."

---

## Step 4: Verify escalation ladder

```bash
ls -l ~/.claude/escalation-ladder.json
```

If the file does not exist, stop with: "Escalation ladder not found. Create ~/.claude/escalation-ladder.json before running /darwin-worktree."

If it exists, read the `ladder_id` field:
```bash
jq -r '.ladder_id' ~/.claude/escalation-ladder.json
```

The value is an ISO-8601 timestamp. Compute the age in days. If age > 30, warn: "Escalation ladder may be stale (ladder_id: <id>, <N> days old). Consider regenerating."

---

## Step 5: Report summary

Print:
```
Darwin initialized.
  Runtime:  <runtime> <version>
  Pairings: <N> valid pairing(s) from .claude/darwin-pairings/
  Ladder:   <ladder_id> (<N> days old)
  Status:   Ready
```

Where `<version>` comes from `<exec> --version` using the detected runtime.
