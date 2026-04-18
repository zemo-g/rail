<!--
Thanks for contributing to Rail. A few quick checks before you open:

 - [ ] `./rail_native test` passes 116/116 on your branch.
 - [ ] If you touched `tools/compile.rail`, `./rail_native self` reaches a
       byte-identical fixed point (`cmp rail_native /tmp/rail_self` is silent).
 - [ ] If you added an stdlib module, there's a test under `tools/tls/` or a
       similar directory that prints PASS.
 - [ ] Commit messages describe *why* the change matters, not just *what*.

See CONTRIBUTING.md for the full bar.
-->

## Summary

<!-- One or two sentences on what changed. -->

## Why

<!-- The motivation. What was broken or missing; what's better now. -->

## How to verify

<!-- Concrete commands a reviewer can run. Test files, expected output, etc. -->

```bash
./rail_native test                     # 116/116
./rail_native self && cmp rail_native /tmp/rail_self   # fixed point
# plus any module-specific tests
```

## Anything else worth calling out

<!-- Compiler quirks hit, design choices made, limits documented in CHANGELOG. -->
