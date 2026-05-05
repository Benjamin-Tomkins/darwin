import { fileURLToPath } from 'url';
// ── Public API ─────────────────────────────────────────────────────────────
/**
 * Derives the canonical agent branch name from an identifier chain and optional asset key.
 *
 * Examples:
 *   branchName(['hello-world', 'greeter'])               → 'agent/hello-world/greeter'
 *   branchName(['hello-world', 'greeter'], 'impl')       → 'agent/hello-world/greeter/impl'
 *   branchName(['my-project'], 'tests')                  → 'agent/my-project/tests'
 */
export function branchName(identifierChain, asset) {
    if (identifierChain.length === 0)
        throw new Error('identifierChain must not be empty');
    const parts = ['agent', ...identifierChain];
    if (asset)
        parts.push(asset);
    return parts.join('/');
}
// ── CLI entry point ────────────────────────────────────────────────────────
// Usage: branch-name.js '["identifier","chain"]' [--asset <key>]
//    →   agent/identifier/chain/<key>
function parseIdentifierChain(raw) {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed) || parsed.some(s => typeof s !== 'string')) {
        throw new Error('not a string array');
    }
    return parsed;
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
    const rawArg = process.argv[2];
    if (!rawArg) {
        process.stderr.write('Usage: branch-name.js \'["identifier","chain"]\' [--asset <key>]\n');
        process.exit(1);
    }
    const assetIdx = process.argv.indexOf('--asset');
    const asset = assetIdx !== -1 ? process.argv[assetIdx + 1] : undefined;
    try {
        const identifierChain = parseIdentifierChain(rawArg);
        process.stdout.write(branchName(identifierChain, asset) + '\n');
    }
    catch (err) {
        process.stderr.write(`branch-name: ${err.message}\n`);
        process.exit(1);
    }
}
//# sourceMappingURL=branch-name.js.map