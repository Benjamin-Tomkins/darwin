export interface DarwinElement {
    identifier: string;
    type: string;
    name: string;
    description: string;
    /** Asset-reference keys (impl, tests, bdd, detail) and metadata keys (identifier, skills). */
    properties: Record<string, string>;
    children: DarwinElement[];
}
export interface ElementTree {
    projectIdentifier: string;
    elements: DarwinElement[];
}
export declare function extractStructurizrBlock(adoc: string): string;
export declare function parseIndex(filePath: string): ElementTree;
//# sourceMappingURL=parse-index.d.ts.map