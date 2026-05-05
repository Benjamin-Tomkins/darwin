import { describe, it, expect } from 'vitest';
import { join } from 'path';
import { fileURLToPath } from 'url';
import { dirname } from 'path';
import { extractStructurizrBlock, parseIndex } from '../src/parse-index.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE = join(__dirname, 'fixtures/hello-world/index.adoc');

describe('extractStructurizrBlock', () => {
  it('extracts the DSL from a [source,structurizr] block', () => {
    const adoc = `= Title\n\n[source,structurizr]\n----\nworkspace "x" {}\n----\n`;
    const dsl = extractStructurizrBlock(adoc);
    expect(dsl).toBe('workspace "x" {}');
  });

  it('handles 6-dash outer delimiters (nested blocks)', () => {
    const adoc = `[source,structurizr]\n------\nworkspace "x" {}\n------\n`;
    expect(extractStructurizrBlock(adoc)).toBe('workspace "x" {}');
  });

  it('throws when no block is present', () => {
    expect(() => extractStructurizrBlock('= No DSL here\n')).toThrow('No [source,structurizr]');
  });
});

describe('parseIndex — hello-world fixture', () => {
  it('returns the correct project identifier', () => {
    const tree = parseIndex(FIXTURE);
    expect(tree.projectIdentifier).toBe('hello-world');
  });

  it('finds the top-level softwareSystem element', () => {
    const tree = parseIndex(FIXTURE);
    expect(tree.elements).toHaveLength(1);
    const sys = tree.elements[0];
    expect(sys.type).toBe('softwareSystem');
    expect(sys.name).toBe('Greeter');
    expect(sys.identifier).toBe('greeter');
  });

  it('extracts asset-reference properties on the softwareSystem', () => {
    const sys = parseIndex(FIXTURE).elements[0];
    expect(sys.properties).toMatchObject({
      impl: 'greeter-impl.adoc',
      tests: 'greeter-tests.adoc',
    });
    // identifier must NOT appear in properties — it's lifted to the identifier field
    expect(sys.properties).not.toHaveProperty('identifier');
  });

  it('finds the nested container child', () => {
    const sys = parseIndex(FIXTURE).elements[0];
    expect(sys.children).toHaveLength(1);
    const container = sys.children[0];
    expect(container.type).toBe('container');
    expect(container.identifier).toBe('api');
    expect(container.properties.impl).toBe('api-impl.adoc');
  });

  it('container has no children', () => {
    const container = parseIndex(FIXTURE).elements[0].children[0];
    expect(container.children).toHaveLength(0);
  });
});

describe('parseIndex — inline DSL variants', () => {
  function parseInline(dsl: string) {
    const adoc = `= T\n\n[source,structurizr]\n----\n${dsl}\n----\n`;
    // Write a temp file? No — test extractStructurizrBlock + parser separately.
    // We test parseIndex with the fixture file; for inline variants we just check
    // extractStructurizrBlock since parseIndex needs a real file path.
    return extractStructurizrBlock(adoc);
  }

  it('extracts multi-line DSL intact', () => {
    const dsl = 'workspace "x" {\n  model {}\n}';
    expect(parseInline(dsl)).toBe(dsl);
  });

  it('handles DSL with comment lines', () => {
    const dsl = 'workspace "x" {\n  // a comment\n  model {}\n}';
    expect(parseInline(dsl)).toBe(dsl);
  });
});
