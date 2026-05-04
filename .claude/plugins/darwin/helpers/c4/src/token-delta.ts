export interface TokenSnapshot {
  input: number;
  output: number;
  thinking: number;
}

export interface TokenDelta {
  input_delta: number;
  output_delta: number;
  thinking_delta: number;
}

export function computeDelta(before: TokenSnapshot, after: TokenSnapshot): TokenDelta {
  return {
    input_delta:    after.input    - before.input,
    output_delta:   after.output   - before.output,
    thinking_delta: after.thinking - before.thinking,
  };
}

// CLI entry point: reads JSON array [before, after] from stdin, writes delta to stdout
const chunks: Buffer[] = [];
process.stdin.on('data', (c: Buffer) => chunks.push(c));
process.stdin.on('end', () => {
  const [before, after] = JSON.parse(
    Buffer.concat(chunks).toString('utf8')
  ) as [TokenSnapshot, TokenSnapshot];
  process.stdout.write(JSON.stringify(computeDelta(before, after)) + '\n');
});
