import { describe, it, expect } from 'vitest';
import { branchName } from '../src/branch-name.js';

describe('branchName', () => {
  it('produces agent/<slug> for a single-element chain', () => {
    expect(branchName(['hello-world'])).toBe('agent/hello-world');
  });

  it('appends asset key when provided', () => {
    expect(branchName(['hello-world', 'greeter'], 'impl')).toBe('agent/hello-world/greeter/impl');
  });

  it('handles a three-level slug chain', () => {
    expect(branchName(['project', 'container', 'component'], 'tests'))
      .toBe('agent/project/container/component/tests');
  });

  it('omits asset key when not provided', () => {
    expect(branchName(['project', 'api'])).toBe('agent/project/api');
  });

  it('throws on an empty slug chain', () => {
    expect(() => branchName([])).toThrow();
  });
});
