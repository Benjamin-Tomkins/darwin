import { describe, it, expect } from 'vitest';
import { computeDelta } from '../src/token-delta.js';

describe('computeDelta', () => {
  it('computes positive deltas for a thinking-model attempt', () => {
    const before = { input: 1000, output: 200, thinking: 0 };
    const after  = { input: 3500, output: 800, thinking: 500 };
    expect(computeDelta(before, after)).toEqual({
      input_delta:   2500,
      output_delta:  600,
      thinking_delta: 500,
    });
  });

  it('returns zero deltas for identical snapshots', () => {
    const snap = { input: 1000, output: 200, thinking: 100 };
    expect(computeDelta(snap, snap)).toEqual({
      input_delta: 0, output_delta: 0, thinking_delta: 0,
    });
  });

  it('thinking_delta is 0 for non-thinking model', () => {
    const before = { input: 500,  output: 100, thinking: 0 };
    const after  = { input: 2000, output: 400, thinking: 0 };
    expect(computeDelta(before, after)).toEqual({
      input_delta: 1500, output_delta: 300, thinking_delta: 0,
    });
  });

  it('handles a later attempt with larger input from growing experience brief', () => {
    const before = { input: 38000, output: 5000, thinking: 0 };
    const after  = { input: 44800, output: 6200, thinking: 0 };
    expect(computeDelta(before, after)).toEqual({
      input_delta: 6800, output_delta: 1200, thinking_delta: 0,
    });
  });
});
