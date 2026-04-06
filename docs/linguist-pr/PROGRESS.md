# Linguist PR — Add Rail Language

**Goal:** Get `github-linguist/linguist` to recognize `.rail` files as "Rail" so GitHub's language bar shows Rail instead of defaulting to Haskell.

**Status:** Work-in-progress. Do NOT submit until human review.

## Checklist

- [x] Fork `github-linguist/linguist` → `zemo-g/linguist`
- [x] Create branch `add-rail-language`
- [x] Add Rail entry to `lib/linguist/languages.yml` (between Raku and Rascal)
- [x] Derive keyword list from compiler tokenizer (`tools/compile.rail:15` — kw_list is authoritative)
- [x] Write TextMate grammar `rail.tmLanguage.json` from EBNF + keyword list
- [x] Create `zemo-g/rail.tmbundle` grammar repo (MIT-licensed)
- [x] Add grammar as git submodule at `vendor/grammars/rail.tmbundle`
- [x] Register grammar in `grammars.yml` → `source.rail`
- [x] Copy 7 diverse sample files to `samples/Rail/`
- [x] Push branch to `zemo-g/linguist:add-rail-language`
- [ ] Run Linguist's test suite locally (ruby rake test — optional)
- [ ] **Human review of PR description** (in `PR_DESCRIPTION.md`)
- [ ] **Human submits PR** (we stop here — don't auto-open)

## Source of truth

All language facts are derived from the self-hosting compiler, not guessed:

| Fact | Source file | Line(s) |
|---|---|---|
| Tokenizer (keywords, operators) | `tools/compile.rail` | ~120-210 |
| Parser grammar (EBNF) | `grammar/rail.ebnf` | full file |
| Builtin function names | `tools/compile.rail` | ~835-927 |
| Float-returning builtins | `tools/compile.rail` | 778-779 |
| Reserved keywords | `grammar/rail.ebnf` | "KEYWORD" production |

## Keywords (from grammar/rail.ebnf + parser)

Reserved:
```
let, if, then, else, match, type, import, foreign, true, false, null,
in, as, do, handle, try, spawn
```

Operators:
```
+ - * / %             (arithmetic)
== != < > <= >=       (comparison)
&& || !                (logical)
|                     (pattern alt / ADT constructor)
->                    (lambda body, pattern arm)
|>                    (pipe)
=                     (binding)
```

Punctuation:
```
( ) [ ] , \
--                    (line comment)
" ... "               (string literal)
```

## Builtin functions (pattern family)

**IO / shell:**
`print, read_line, read_file, write_file, shell, args`

**Integer arithmetic / conversion:**
`to_float, to_int, show, not`

**List operations:**
`cons, head, tail, length, reverse, append, map, filter, fold, range`

**String operations:**
`chars, split, cat, join, str_find, str_contains, str_replace, str_split, str_sub`

**Float math:**
`sqrt, sin, cos, tan, tanh, exp, log, pow, fabs, floor, ceil, atan2, fneg, fsqrt`

**Arrays (tagged / mutable):**
`arr_new, arr_get, arr_set, arr_len`
`float_arr_new, float_arr_get, float_arr_set, float_arr_len`

**Memory:**
`rc_alloc, rc_retain, rc_release, arena_mark, arena_reset`

**Error handling:**
`error, is_error, err_msg`

**GPU / concurrency:**
`gpu_map, spawn, channel, send, recv, fiber_await`

## Language ID

- Chose `999888777` as placeholder. Linguist maintainers assign the final ID.
- Picked a number unlikely to collide with existing IDs (max observed was 998078858).

## Color

`#ff5500` — Rail orange. Chosen to match the badge in the README and the ledatic.org brand.

## Ace mode

`haskell` — closest existing Ace mode for the Haskell-family syntax. Monaco/CodeMirror users get working highlighting out of the box.

## Acceptance criteria (Linguist)

From `CONTRIBUTING.md` in github-linguist:

1. ✓ New extension not already claimed (`.rail` isn't used elsewhere)
2. ⚠ Popularity: "at least 200 unique :user/:repo repositories" — **WE DO NOT MEET THIS**
3. ✓ Grammar: TextMate bundle linked as submodule (WIP)
4. ✓ Sample files
5. ✓ Color field
6. ✓ Language type (programming)

The 200-repo threshold is the main blocker. The PR may be closed with a request to resubmit when adoption grows. We submit anyway to start the conversation.

## Open questions (for human review)

- Should we use `ace_mode: haskell` or leave unset?
- Should we request color `#ff5500` (brand match) or a less-saturated orange?
- Do we disclose the self-hosting/BSL aspect in the PR description?
- Do we mention the neural plasma engine / flywheel as evidence of real use?
- Who signs off on the PR as the human maintainer?
