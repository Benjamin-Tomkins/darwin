export function computeDelta(before, after) {
    return {
        input_delta: after.input - before.input,
        output_delta: after.output - before.output,
        thinking_delta: after.thinking - before.thinking,
    };
}
// CLI entry point: reads JSON array [before, after] from stdin, writes delta to stdout
const chunks = [];
process.stdin.on('data', (c) => chunks.push(c));
process.stdin.on('end', () => {
    const [before, after] = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    process.stdout.write(JSON.stringify(computeDelta(before, after)) + '\n');
});
//# sourceMappingURL=token-delta.js.map