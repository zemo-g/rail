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
