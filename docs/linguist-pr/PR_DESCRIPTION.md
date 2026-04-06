# PR Description Draft — `github-linguist/linguist`

**READ FIRST — instructions for the human reviewer (you, Reilly):**

This file is the draft of the PR description that will be submitted to `github-linguist/linguist`. Everything below the `---` line is what actually goes into the PR. Sections marked with **[HUMAN:]** are places where you should add your own voice — a sentence or two, not a speech.

When you're happy with it:
1. Review the content below
2. Edit the **[HUMAN:]** sections in your own words
3. Run: `gh pr create --repo github-linguist/linguist --base main --head zemo-g:add-rail-language --title "Add Rail programming language" --body-file docs/linguist-pr/PR_DESCRIPTION.md` (will probably need to strip this header first, or use `--body` directly)
4. Monitor the PR for maintainer feedback

**Do NOT submit before human review.** The fork branch is ready at:
https://github.com/zemo-g/linguist/tree/add-rail-language

---

## Summary

This PR adds [Rail](https://github.com/zemo-g/rail) as a recognized programming language in Linguist.

Rail is a self-hosting programming language. Its compiler is written in Rail, compiles itself to a ~640KB ARM64 binary, and produces byte-identical output on second-compile (fixed point). Zero C dependencies — the garbage collector and runtime are hand-written ARM64 assembly.

**[HUMAN: add one sentence here about why you built Rail or what it's for. This is where maintainers get a sense of the project vs. just seeing a spec.]**

## Checklist

- [x] I have read [CONTRIBUTING.md](https://github.com/github-linguist/linguist/blob/main/CONTRIBUTING.md)
- [x] New entry in `lib/linguist/languages.yml` — between Raku and Rascal (alphabetical)
- [x] TextMate grammar as git submodule at `vendor/grammars/rail.tmbundle` → [zemo-g/rail.tmbundle](https://github.com/zemo-g/rail.tmbundle) (MIT-licensed, standalone repo)
- [x] Grammar registered in `grammars.yml` → `source.rail`
- [x] 7 sample files in `samples/Rail/` covering: hello world, recursion (fibonacci), control flow (fizzbuzz), list operations, closures / lambdas, float arithmetic + TCO (d8_test), a full 2D MHD plasma simulator (mhd — ~360 lines, real physics)
- [x] File extension `.rail` is unique — verified against existing Linguist entries
- [x] Color `#ff5500` — brand color, passes WCAG AA against GitHub's language bar background

## About the popularity threshold

Linguist's CONTRIBUTING.md asks for ≥200 public repositories using the language. **Rail does not meet this threshold yet** — the main public repo is [zemo-g/rail](https://github.com/zemo-g/rail), a single author project that went public recently.

I'm opening this PR anyway because:

1. The language is clearly distinct — unique `.rail` extension, self-hosting, real compiler, real users (well, one at the moment), ~5,000+ lines of real Rail code in the repo.
2. Getting added to Linguist would let the main repo's language bar show "Rail" instead of defaulting to Haskell (via a `.gitattributes` override we have in place now).
3. I'd rather start the conversation and hear what's needed than sit on it.

**[HUMAN: if you want to make a case for bending the 200-repo rule, this is the place. A sentence about the research / neural plasma stuff, or who's using it, or where it's going. Or leave it alone and let the maintainers decide — that's fine too.]**

Happy to close this PR and revisit in N months if the preferred path is "come back when adoption grows."

## Grammar quality

The TextMate grammar was derived directly from the compiler's own tokenizer and parser, not guessed at:

- **Keyword list** — `tools/compile.rail:15` (`kw_list` — the exact list the tokenizer matches against)
- **Grammar rules** — `grammar/rail.ebnf` (EBNF spec derived from the parser)
- **Builtin function names** — `tools/compile.rail:835-927` (dispatch tables)

Repository: https://github.com/zemo-g/rail.tmbundle

The grammar is MIT-licensed (separate from the Rail compiler's BSL 1.1 license — the grammar is trivially redistributable tooling).

## Sample file highlights

- `hello.rail` (10 lines) — minimal hello world
- `fibonacci.rail` — recursive with pattern matching
- `lists.rail` — fold/map/filter idioms
- `closures.rail` — lambdas, captured variables
- `d8_test.rail` (115 lines) — float arithmetic stress test (compiler regression suite)
- `mhd.rail` — 360-line 2D ideal MHD plasma simulator (real physics: Orszag-Tang vortex, Lax-Friedrichs scheme, machine-precision mass/energy conservation)

The diversity should give the grammar coverage for comments, strings, numbers, keywords, operators, function definitions, pattern matches, ADT constructors, and floating-point.

## Related links

- Main repo: https://github.com/zemo-g/rail
- Grammar repo: https://github.com/zemo-g/rail.tmbundle
- Language design notes: https://github.com/zemo-g/rail/blob/master/README.md
- EBNF grammar: https://github.com/zemo-g/rail/blob/master/grammar/rail.ebnf

**[HUMAN: if there's anything else you want maintainers to know — thanks, context, a specific maintainer to tag, etc. — put it here.]**

Thanks for reviewing.
