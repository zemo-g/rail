# string_processing — split, join, reverse, append, shell

The basics of working with strings: `split " "` (per-character delimiter — see CLAUDE.md for the `str_split` multi-char variant), `join`, `reverse` (on the resulting list), `append`, and dropping into `shell` for OS-level transforms.

**Source** (`examples/string_processing.rail`):

```rail
-- string_processing.rail — string manipulation
--
-- Demonstrates: split, join, reverse, length, append, shell for transforms

main =
  let sentence = "the quick brown fox"

  -- Split into words (split on space)
  let words = split " " sentence
  let _ = print "Words:"
  let _ = print (show (length words))

  -- Reverse word order
  let _ = print "Reversed:"
  let _ = print (join " " (reverse words))

  -- Join with different separator
  let _ = print "Dashed:"
  let _ = print (join "-" words)

  -- String concatenation via append
  let greeting = append "hello" " world"
  let _ = print greeting

  -- Split on characters
  let chars = split "" "abcdef"
  let _ = print (show (length chars))

  -- Use shell for more string ops
  let date = shell "date +%Y-%m-%d"
  let _ = print date

  0
```

**Run:**

```bash
./rail_native run examples/string_processing.rail
```

**Output (date will vary):**

```
Words:
4
Reversed:
fox brown quick the
Dashed:
the-quick-brown-fox
hello world
1
2026-05-11
```

`split " "` on `"the quick brown fox"` produces 4 words. `split ""` is the edge case — empty delimiter gives one element. The trailing `2026-05-11` is `shell "date +%Y-%m-%d"` — Rail's `shell` returns the command's stdout as a string.
