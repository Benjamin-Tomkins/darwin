import { fileURLToPath } from 'url';
export function computeDelta(before, after) {
    return {
        input_delta: after.input - before.input,
        output_delta: after.output - before.output,
        thinking_delta: after.thinking - before.thinking,
    };
}
// ── CLI entry point ────────────────────────────────────────────────────────
// Reads JSON array [before, after] from stdin, writes delta JSON to stdout.
if (process.argv[1] === fileURLToPath(import.meta.url)) {
    const chunks = [];
    process.stdin.on('data', (c) => chunks.push(c));
    process.stdin.on('end', () => {
        try {
            const [before, after] = JSON.parse(Buffer.concat(chunks).toString('utf8'));
            process.stdout.write(JSON.stringify(computeDelta(before, after)) + '\n');
        }
        catch (err) {
            process.stderr.write(`token-delta: ${err.message}\n`);
            process.exit(1);
        }
    });
}
//# sourceMappingURL=token-delta.js.map