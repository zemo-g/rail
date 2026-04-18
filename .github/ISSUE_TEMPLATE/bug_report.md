---
name: Bug report
about: Something Rail does that it shouldn't, or fails to do that it should
title: ''
labels: bug
---

**What happened**

<!-- A Rail program + the command you ran + what you saw. Minimal reproducer preferred. -->

**What you expected**

<!-- What should have happened. -->

**Environment**

- OS + arch (e.g. `macOS 15 / ARM64`):
- `./rail_native --version` or commit SHA of `rail_native`:
- Test suite status (`./rail_native test`):
- Self-compile fixed point (`./rail_native self && cmp rail_native /tmp/rail_self`):

**Reproducer**

```rail
-- paste the smallest program that shows the issue here
```

```bash
# the command + output you ran
./rail_native run bug.rail
```

**Extra context**

<!-- Anything else worth knowing. Stack traces, timing, whether it's a regression from a prior version. -->
