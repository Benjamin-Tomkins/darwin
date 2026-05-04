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
export declare function computeDelta(before: TokenSnapshot, after: TokenSnapshot): TokenDelta;
//# sourceMappingURL=token-delta.d.ts.map