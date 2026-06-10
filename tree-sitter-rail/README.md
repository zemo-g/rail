# tree-sitter-rail

Tree-sitter grammar for the [Rail programming language](https://github.com/zemo-g/rail).
Lives in-tree under `tree-sitter-rail/`; derived from `grammar/rail.ebnf` and the
parser in `tools/compile.rail`.

## Build

```bash
npm install            # pulls the tree-sitter CLI (devDependency)
npx tree-sitter generate
npx tree-sitter test
```

## Status

Grammar frozen as of 2026-03. It predates the `try` effect-handler keyword and
later language additions (type layer, AD forms) — see the issue tracker. The
generated bindings (node/rust/python/go/swift) are stock tree-sitter boilerplate.
