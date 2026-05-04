import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { resolve } from 'path';
// ── AsciiDoc extraction ────────────────────────────────────────────────────
export function extractStructurizrBlock(adoc) {
    // Match [source,structurizr] followed by a delimiter line (4+ dashes),
    // then content, then the same delimiter again.
    const m = adoc.match(/\[source,structurizr\]\n(-{4,})\n([\s\S]*?)\n\1(?:\n|$)/);
    if (!m)
        throw new Error('No [source,structurizr] block found in AsciiDoc file');
    return m[2];
}
function tokenise(src) {
    const toks = [];
    let i = 0;
    let line = 1;
    while (i < src.length) {
        const ch = src[i];
        // Line comments
        if ((ch === '/' && src[i + 1] === '/') || ch === '#') {
            while (i < src.length && src[i] !== '\n')
                i++;
            continue;
        }
        if (ch === '\r') {
            i++;
            continue;
        }
        if (ch === '\n') {
            toks.push({ type: 'NL', value: '\n', line });
            line++;
            i++;
            continue;
        }
        if (ch === ' ' || ch === '\t') {
            i++;
            continue;
        }
        if (ch === '{') {
            toks.push({ type: 'LBRACE', value: '{', line });
            i++;
            continue;
        }
        if (ch === '}') {
            toks.push({ type: 'RBRACE', value: '}', line });
            i++;
            continue;
        }
        if (ch === '"') {
            let j = i + 1;
            while (j < src.length && src[j] !== '"') {
                if (src[j] === '\\')
                    j++;
                j++;
            }
            toks.push({ type: 'STRING', value: src.slice(i + 1, j), line });
            i = j + 1;
            continue;
        }
        // WORD: everything up to whitespace, braces, quotes, or comment start
        let j = i;
        while (j < src.length && !/[\s{}"#]/.test(src[j])) {
            if (src[j] === '/' && src[j + 1] === '/')
                break;
            j++;
        }
        if (j > i) {
            toks.push({ type: 'WORD', value: src.slice(i, j), line });
            i = j;
        }
        else
            i++;
    }
    toks.push({ type: 'EOF', value: '', line });
    return toks;
}
// ── Parser ─────────────────────────────────────────────────────────────────
const ELEMENT_KEYWORDS = new Set([
    'softwareSystem', 'container', 'component', 'person',
    'deploymentEnvironment', 'deploymentNode',
]);
class Parser {
    toks;
    pos = 0;
    constructor(toks) {
        this.toks = toks;
    }
    peek() { return this.toks[this.pos]; }
    next() { return this.toks[this.pos++]; }
    skipNl() { while (this.peek().type === 'NL')
        this.next(); }
    /** True if the current token ends the enclosing block (closing brace or input end). */
    atBlockEnd() {
        const t = this.peek().type;
        return t === 'RBRACE' || t === 'EOF';
    }
    expect(type, value) {
        const t = this.next();
        if (t.type !== type || (value !== undefined && t.value !== value)) {
            throw new Error(`Expected ${type}${value ? `(${value})` : ''} at line ${t.line}, got ${t.type}(${JSON.stringify(t.value)})`);
        }
        return t;
    }
    /** Skip until end-of-line (without consuming the NL). */
    skipToEol() {
        while (this.peek().type !== 'NL' && this.peek().type !== 'EOF')
            this.next();
    }
    /** Skip a brace-delimited block, including the opening brace. */
    skipBraceBlock() {
        this.expect('LBRACE');
        let depth = 1;
        while (depth > 0 && this.peek().type !== 'EOF') {
            const t = this.next();
            if (t.type === 'LBRACE')
                depth++;
            else if (t.type === 'RBRACE')
                depth--;
        }
    }
    /** Skip an unknown statement or block at current position. */
    skipStatement() {
        while (this.peek().type !== 'NL' && this.peek().type !== 'RBRACE' && this.peek().type !== 'EOF') {
            if (this.peek().type === 'LBRACE') {
                this.skipBraceBlock();
                return;
            }
            this.next();
        }
    }
    parseWorkspace() {
        this.skipNl();
        this.expect('WORD', 'workspace');
        const slugTok = this.next(); // string or bare word
        const projectSlug = slugTok.value;
        this.skipNl();
        this.expect('LBRACE');
        let elements = [];
        while (!this.atBlockEnd()) {
            this.skipNl();
            if (this.atBlockEnd())
                break;
            const tok = this.peek();
            if (tok.type === 'WORD' && tok.value === 'model') {
                elements = this.parseModel();
            }
            else {
                this.skipStatement();
            }
        }
        return { projectSlug, elements };
    }
    parseModel() {
        this.expect('WORD', 'model');
        this.skipNl();
        this.expect('LBRACE');
        const elements = this.parseElementList();
        this.expect('RBRACE');
        return elements;
    }
    parseElementList() {
        const elems = [];
        while (!this.atBlockEnd()) {
            this.skipNl();
            if (this.atBlockEnd())
                break;
            const tok = this.peek();
            if (tok.type === 'WORD' && ELEMENT_KEYWORDS.has(tok.value)) {
                elems.push(this.parseElement());
            }
            else {
                this.skipStatement();
            }
        }
        return elems;
    }
    parseElement() {
        const type = this.next().value;
        // Name (required)
        this.skipNl();
        const name = this.next().value;
        // Optional description
        let description = '';
        if (this.peek().type === 'STRING')
            description = this.next().value;
        // Skip any remaining tokens on this line before the block
        while (this.peek().type !== 'LBRACE' &&
            this.peek().type !== 'NL' &&
            !this.atBlockEnd())
            this.next();
        const properties = {};
        let slug = '';
        const children = [];
        if (this.peek().type === 'LBRACE') {
            this.expect('LBRACE');
            while (!this.atBlockEnd()) {
                this.skipNl();
                if (this.atBlockEnd())
                    break;
                const tok = this.peek();
                if (tok.type === 'WORD' && tok.value === 'properties') {
                    const props = this.parseProperties();
                    if ('slug' in props) {
                        slug = props.slug;
                        delete props.slug;
                    }
                    Object.assign(properties, props);
                }
                else if (tok.type === 'WORD' && tok.value === 'tags') {
                    const tagSlug = this.parseTags();
                    if (tagSlug)
                        slug = tagSlug;
                }
                else if (tok.type === 'WORD' && ELEMENT_KEYWORDS.has(tok.value)) {
                    children.push(this.parseElement());
                }
                else {
                    this.skipStatement();
                }
            }
            this.expect('RBRACE');
        }
        return { slug, type, name, description, properties, children };
    }
    parseProperties() {
        this.expect('WORD', 'properties');
        this.skipNl();
        this.expect('LBRACE');
        const props = {};
        while (!this.atBlockEnd()) {
            this.skipNl();
            if (this.atBlockEnd())
                break;
            const keyTok = this.peek();
            if (keyTok.type === 'WORD' || keyTok.type === 'STRING') {
                const key = this.next().value;
                // Value: next non-NL token on same line
                if (this.peek().type === 'WORD' || this.peek().type === 'STRING') {
                    props[key] = this.next().value;
                }
            }
            this.skipToEol();
        }
        this.expect('RBRACE');
        return props;
    }
    parseTags() {
        this.expect('WORD', 'tags');
        let slugTag = null;
        while (this.peek().type === 'STRING' || this.peek().type === 'WORD') {
            const val = this.next().value;
            const m = val.match(/^slug=(.+)$/);
            if (m)
                slugTag = m[1];
        }
        this.skipToEol();
        return slugTag;
    }
}
// ── Public API ─────────────────────────────────────────────────────────────
export function parseIndex(filePath) {
    const content = readFileSync(resolve(filePath), 'utf8');
    const dsl = extractStructurizrBlock(content);
    const toks = tokenise(dsl);
    const parser = new Parser(toks);
    return parser.parseWorkspace();
}
// ── CLI entry point ────────────────────────────────────────────────────────
if (process.argv[1] === fileURLToPath(import.meta.url)) {
    const fileIdx = process.argv.indexOf('--file');
    if (fileIdx === -1 || !process.argv[fileIdx + 1]) {
        process.stderr.write('Usage: parse-index.js --file <path/to/index.adoc>\n');
        process.exit(1);
    }
    try {
        const tree = parseIndex(process.argv[fileIdx + 1]);
        process.stdout.write(JSON.stringify(tree, null, 2) + '\n');
    }
    catch (err) {
        process.stderr.write(`parse-index: ${err.message}\n`);
        process.exit(1);
    }
}
//# sourceMappingURL=parse-index.js.map