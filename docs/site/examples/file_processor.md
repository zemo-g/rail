# file_processor — read, write, transform files

Rail's I/O surface is small but functional: `write_file path content`, `read_file path`, and `shell "cmd"` for everything else. This example writes a file, reads it back via shell (to demonstrate piping), and runs a few transforms.

**Source** (`examples/file_processor.rail`):

```rail
-- file_processor.rail — read, process, and write files
--
-- Demonstrates: write_file, shell, split, join, reverse, length

main =
  -- Write some data to a file
  let path = "/tmp/rail_example_data.txt"
  let _ = write_file path "the quick brown fox jumps over the lazy dog"
  let _ = print "Wrote file."

  -- Read it back via shell (reliable)
  let content = shell "cat /tmp/rail_example_data.txt"
  let _ = print "Contents:"
  let _ = print content

  -- Split into words and count
  let words = split " " content
  let _ = print "Word count:"
  let _ = print (show (length words))

  -- Reverse the words
  let reversed = join " " (reverse words)
  let _ = print "Reversed:"
  let _ = print reversed

  -- Write processed output
  let outpath = "/tmp/rail_example_output.txt"
  let _ = write_file outpath reversed

  -- Transform via shell
  let upper = shell "tr a-z A-Z < /tmp/rail_example_data.txt"
  let _ = print "Uppercase:"
  let _ = print upper

  -- Line count via shell
  let wc = shell "wc -w < /tmp/rail_example_data.txt"
  let _ = print "wc says:"
  let _ = print wc

  0
```

**Run:**

```bash
./rail_native run examples/file_processor.rail
```

**Output:**

```
Wrote file.
Contents:
the quick brown fox jumps over the lazy dog
Word count:
9
Reversed:
dog lazy the over jumps fox brown quick the
Uppercase:
THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG
wc says:
       9
```

`shell` is the escape hatch for anything Rail doesn't have a builtin for. The output of `shell` includes any trailing newline from the command, which is why "wc says:" prints with the leading spaces from `wc -w`'s formatted output.
