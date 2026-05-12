# Rail Package Manifest — v0 spec

`rail.toml` is a tiny INI-flavored TOML subset. v0 supports local-path dependencies only — no network fetch, no registry, no version solver.

## Grammar

```
file       := (line)*
line       := blank | comment | section | entry
blank      := /^\s*$/
comment    := /^\s*#.*$/ | /^\s*--.*$/
section    := "[" ident "]"
entry      := ident "=" string
ident      := [A-Za-z0-9_-]+
string     := "..." (double-quoted; no escapes in v0; do not embed ")
```

Whitespace around `=` is trimmed. Leading/trailing whitespace on lines is trimmed. Unknown sections are tolerated and silently skipped.

## Sections

### `[package]` (required)

| key       | required | value                                  |
|-----------|----------|----------------------------------------|
| `name`    | yes      | package identifier                     |
| `version` | yes      | semver-shaped string (not parsed in v0)|

### `[dependencies]` (optional)

Each entry is `<dep_name> = "<source>"`. In v0, `<source>` must begin with `path:`.

```
[dependencies]
foo = "path:../local/foo"
bar = "path:./vendor/bar"
```

The path after `path:` is resolved relative to the directory containing `rail.toml`. The resolved path must exist (file or directory) or `pkg_resolve` exits non-zero.

## Minimal example

```
[package]
name = "package_b"
version = "0.1.0"

[dependencies]
package_a = "path:../package_a"
```

## Tooling contract

Both tools are invoked from the **repo root** (so `import "tools/pkg/pkg_lib.rail"` resolves), and take the package directory as a positional argument (default `.`):

```
./rail_native run tools/pkg/pkg_resolve.rail <pkg-dir>
./rail_native run tools/pkg/pkg_link.rail    <pkg-dir>
```

- `pkg_resolve.rail` — reads `<pkg-dir>/rail.toml`. For each dep, prints `<name>\t<absolute_resolved_path>`. Prints `MISSING <name>\t<unresolved>` and exits with status 2 if any dep path does not exist. Status 1 for malformed/missing manifest.
- `pkg_link.rail` — runs the same resolution; creates `<pkg-dir>/vendor/<dep_name>` as a symlink to the resolved path. Falls back to `cp -R` when symlinks fail (e.g., cross-device, sandboxed FS). Idempotent: re-running replaces stale links via `ln -snf`.

## Out of scope (v0)

- network fetch (`git:`, `https:`, registry URLs)
- version constraints / SAT solver / lockfile
- transitive dep walking (consumer must declare every dep it `import`s)
- semver checking
- build-time codegen / hooks
