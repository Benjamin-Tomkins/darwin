import { fileURLToPath } from 'url';

// ── Public API ─────────────────────────────────────────────────────────────

/**
 * Derives the canonical agent branch name from a slug chain and optional asset key.
 *
 * Examples:
 *   branchName(['hello-world', 'greeter'])               → 'agent/hello-world/greeter'
 *   branchName(['hello-world', 'greeter'], 'impl')       → 'agent/hello-world/greeter/impl'
 *   branchName(['my-project'], 'tests')                  → 'agent/my-project/tests'
 */
export function branchName(slugChain: string[], asset?: string): string {
  if (slugChain.length === 0) throw new Error('slugChain must not be empty');
  const parts = ['agent', ...slugChain];
  if (asset) parts.push(asset);
  return parts.join('/');
}

// ── CLI entry point ────────────────────────────────────────────────────────
// Usage: branch-name.js '["slug","chain"]' [--asset <key>]
//    →   agent/slug/chain/<key>

function parseSlugChain(raw: string): string[] {
  const parsed = JSON.parse(raw) as unknown;
  if (!Array.isArray(parsed) || parsed.some(s => typeof s !== 'string')) {
    throw new Error('not a string array');
  }
  return parsed as string[];
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const rawArg = process.argv[2];
  if (!rawArg) {
    process.stderr.write('Usage: branch-name.js \'["slug","chain"]\' [--asset <key>]\n');
    process.exit(1);
  }

  const assetIdx = process.argv.indexOf('--asset');
  const asset = assetIdx !== -1 ? process.argv[assetIdx + 1] : undefined;

  try {
    const slugChain = parseSlugChain(rawArg);
    process.stdout.write(branchName(slugChain, asset) + '\n');
  } catch (err) {
    process.stderr.write(`branch-name: ${(err as Error).message}\n`);
    process.exit(1);
  }
}
