import { fileURLToPath } from 'url';

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

// ── CLI entry point ────────────────────────────────────────────────────────
// Reads JSON array [before, after] from stdin, writes delta JSON to stdout.

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const chunks: Buffer[] = [];
  process.stdin.on('data', (c: Buffer) => chunks.push(c));
  process.stdin.on('end', () => {
    try {
      const [before, after] = JSON.parse(
        Buffer.concat(chunks).toString('utf8')
      ) as [TokenSnapshot, TokenSnapshot];
      process.stdout.write(JSON.stringify(computeDelta(before, after)) + '\n');
    } catch (err) {
      process.stderr.write(`token-delta: ${(err as Error).message}\n`);
      process.exit(1);
    }
  });
}
