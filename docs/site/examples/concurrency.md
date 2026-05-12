# concurrency — fibers and channels

Rail ships cooperative fibers (`spawn`) and bounded channels (`channel`, `send`, `recv`). Two workers send to one channel; a counter fiber sends 1..5 in sequence.

**Source** (`examples/concurrency.rail`):

```rail
-- concurrency.rail — fibers and channels
--
-- Demonstrates: spawn, channel, send, recv

worker ch name =
  let _ = send ch name
  0

counter ch n max =
  if n > max then 0
  else let _ = send ch (show n)
       counter ch (n + 1) max

main =
  -- Basic: spawn two fibers, each sends a message
  let ch1 = channel 0
  let _ = spawn (worker ch1 "hello from fiber 1")
  let _ = spawn (worker ch1 "hello from fiber 2")
  let msg1 = recv ch1
  let _ = print msg1
  let msg2 = recv ch1
  let _ = print msg2

  -- Counter: fiber sends numbers 1 through 5
  let ch2 = channel 0
  let _ = spawn (counter ch2 1 5)
  let a = recv ch2
  let b = recv ch2
  let c = recv ch2
  let d = recv ch2
  let e = recv ch2
  let _ = print (join " " [a, b, c, d, e])

  0
```

**Run:**

```bash
./rail_native run examples/concurrency.rail
```

**Output:**

```
hello from fiber 1
hello from fiber 2
1 2 3 4 5
```

`channel 0` constructs a zero-buffer rendezvous channel. `send` blocks until a `recv` is waiting (and vice versa). Fibers are cooperative — they yield at I/O and channel operations.
