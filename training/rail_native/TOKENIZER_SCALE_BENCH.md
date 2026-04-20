# Tokenizer Scale Bench — counted-loop `build_vocab`

Measures `build_vocab` + `encode` throughput on `stdlib/tokenizer.rail`
after rewriting `collect_unique` as a counted loop (commit `1ccb302` on
`next`). The old O(n²) form capped usable training corpora at the tiny
`stdlib/optim.rail` (9.2 KB) slice; this bench shows the new path
carries the full `stdlib/*.rail` concatenation (~540 KB) in ~1.6 s of
tokenizer work.

## Method

- Corpus: `training/rail_corpus_stdlib.txt`, produced by
  `./rail_native run tools/train/build_corpus.rail`.
  74 files, 552 857 bytes, alphabetical (`LC_ALL=C` sort).
- Slicer: `head -c N` on the concatenated corpus, written to
  `/tmp/rail_bench_corpus.txt`.
- Runner: `./tools/bench/tokenizer_scale_bench.sh` wraps each run
  in `/usr/bin/time -l` (macOS) for external peak-RSS measurement.
  `peak_rss` below is `maximum resident set size` (bytes).
  `peak_footprint` is `peak memory footprint` from the same output
  (darwin dirty + compressed pages).
- In-Rail timing: `perl -MTime::HiRes` wall clock around `build_vocab`
  and `encode`.
- Host: Mac Mini M4 Pro (24 GB). Commit: `58f7406` on `next`.

## Numbers

| Slice  | Bytes   | Chars   | V   | build_vocab (ms) | encode (ms) | total_tok (ms) | real (s) | peak_rss (MB) |
|--------|---------|---------|-----|-----------------:|------------:|---------------:|---------:|--------------:|
| 9.2KB  |   9 250 |   9 250 |  90 |               11 |          23 |             34 |     0.42 |            37 |
| 50KB   |  51 200 |  51 200 | 103 |               32 |         102 |            134 |     0.46 |            38 |
| 200KB  | 204 800 | 204 800 | 114 |               93 |         436 |            529 |     0.85 |            79 |
| full   | 552 857 | 552 857 | 130 |              257 |       1 339 |          1 596 |     2.00 |           202 |

`real` is process wall-clock (includes compile + runtime init).
`peak_rss` grows with the encoded-id cons-list the bench builds — the
training path uses `encode_into_arr` into a `float_arr` instead, which
is O(n) allocation, not O(n) cons cells.

## Scaling verdict

`build_vocab` across the 60× corpus-size span:

```
 9.2 →  50 KB :  11 →  32 ms   (×2.9 wall,  ×5.5 data)
  50 → 200 KB :  32 →  93 ms   (×2.9 wall,  ×4.0 data)
 200 → 540 KB :  93 → 257 ms   (×2.8 wall,  ×2.7 data)
```

Clean sub-linear to linear — the counted loop erased the O(n²)
`length input == 0` that was killing the old path. No iteration-count
runaway, no heap thrash: the arena stays flat (`12 599 680`
peak_footprint is identical 50 KB → 540 KB, a page-sized constant).

`encode` remains the tallest single bar at full scale (1.34 s) and is
where any future tokenizer-path work earns its keep. The counted-loop
pattern is already applied there too (`enc_fast_loop` in
`tools/train/lm_v3_chunked.rail`); the remaining cost is per-char
`char_id` which is O(V) linear scan. A sorted-char lookup or a direct
char→id int array would collapse it.

## Reproduce

```bash
./rail_native run tools/train/build_corpus.rail
./tools/bench/tokenizer_scale_bench.sh
# → /tmp/rail_tokenizer_bench.log has every run's /usr/bin/time -l dump
```

The determinism test (`tools/train/tokenizer_determinism_test.rail`)
asserts the new counted-loop ordering matches the preserved
`build_vocab_old` form on a fixed 256-char corpus; run it after any
tokenizer edit.

## BPE bake-off (stdlib/bpe.rail)

The BPE trainer got three companion changes. `bpe_train` is now backed
by `bpe_train_loop_deferred`:

1. **Tree-walk max** (`bpe_map_best_pair`) — finds the max-count pair
   by direct in-order traversal of the persistent BST, instead of
   materializing `map_keys` (itself O(K²) via `append (map_keys l) …`)
   and then calling `map_get` per key.
2. **Deferred vocab** — during training we keep only the token-id
   array + `(a,b,nid)` merge triples. The actual vocab strings are
   built once at the end from base_vocab + merges. Removes the
   per-iter `append vocab [new_token]` (O(V)) and the `bpe_nth a
   vocab` / `bpe_nth b vocab` O(V) lookups that computed `new_token`.
3. **Cons merges, reverse at end** — O(1) per iter instead of O(M)
   per `append merges [...]`.

Determinism regression: `tools/train/bpe_determinism_test.rail`
asserts the new path produces byte-identical `(merges, vocab, size)`
to the preserved `bpe_train_legacy` (same seed, same corpus) — PASS
at V=256 on a 3.9 KB synthetic corpus.

Timings on Mac Mini M4 Pro (`/tmp/bpe_prof` of
`tools/bench/bpe_profile.rail`):

| Corpus   | target V | legacy (ms) | deferred (ms) | peak RSS | speedup |
|----------|---------:|------------:|--------------:|---------:|--------:|
|   50 KB  |      512 |      11 671 |         6 775 |   —      |   1.72× |
|  540 KB  |     1024 |         —   |       393 600 |   —      |     —   |
|  540 KB  |     2048 |         —   |       466 520 | 1.56 GB  |     —   |

The `—` cell for legacy × 540 KB × any target wasn't run — the legacy
profile on 50 KB × 512 was already slow enough (the `.Lapp_list` list-
append was 95% of the `sample` stack traces) that extrapolated
legacy-at-scale is many hours.

Target axis scales sub-linearly (1.19× wall for 2× target) — post-merge
corpus compaction means later iters touch fewer positions per
`bpe_apply_merge_arr`.

**Where we stand relative to the <5 min / target=4096 / 540 KB bar:**
short on the wall-clock bar, clear on correctness and capability.
The deferred path handles the full stdlib corpus to target=2048 in
7.8 minutes at 1.56 GB peak, which is already enough to unblock
Phase 3 LM training on real Rail source (the original goal of
this stream). Extrapolating to target=4096 on the same corpus:
~9–11 minutes. Above the bar, but a tractable starting point. An incremental-counts prototype
(`bpe_train_inc_wip`, disabled) proved semantically identical on
smoke + determinism runs but the persistent BST's per-bump `map_put`
allocation overwhelmed the arena above ~50 KB — the 540 KB × 1024
run hadn't completed after 30 min and was killed. The correct fix
is an open-addressed mutable hash table of ints (two parallel
`float_arr`s for keys + counts), which makes each bump O(1) with
zero allocation. That's the next session's first item, together with
an explicit max-heap for `best_pair`.

