/**
 * Derives the canonical agent branch name from a slug chain and optional asset key.
 *
 * Examples:
 *   branchName(['hello-world', 'greeter'])               → 'agent/hello-world/greeter'
 *   branchName(['hello-world', 'greeter'], 'impl')       → 'agent/hello-world/greeter/impl'
 *   branchName(['my-project'], 'tests')                  → 'agent/my-project/tests'
 */
export declare function branchName(slugChain: string[], asset?: string): string;
//# sourceMappingURL=branch-name.d.ts.map