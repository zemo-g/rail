// tools/runtime/concurrent.c
//
// v0 concurrency primitive for Rail: bounded blocking channels + thread spawn,
// backed by pthread_mutex + pthread_cond. Carries only int64_t values.
//
// Build:
//   bash tools/runtime/build_concurrent.sh
//
// Output:
//   tools/runtime/libconcurrent.dylib
//
// Wiring:
//   compile.rail auto-links libconcurrent.dylib when present (see the
//   `has_concurrent_lib` branch in `build`). Rail-side bindings in
//   stdlib/concurrent.rail expose `rc_chan_make`, `rc_chan_send`,
//   `rc_chan_recv`, `rc_chan_close`, plus the demo helpers used by
//   tools/runtime/test_concurrent.rail.
//
// Design notes:
//   • Channels are identified by small int handles (1..MAX_CHANNELS). This
//     keeps the Rail/C boundary tag-safe: handles fit in tagged ints and
//     survive Rail's untag/retag wrapper unscathed. Raw-pointer returns
//     would need the 4000+ arity-encoding dance; we don't need that here.
//   • A channel is a bounded ring buffer of int64_t with capacity provided
//     at make time. send blocks when full; recv blocks when empty.
//     close wakes all waiters; recv on a closed+empty channel returns
//     INT64_MIN as a poison value (Rail-side bindings translate as needed).
//   • Spawned threads are tracked in a parallel handle table for join.
//   • The demo producer/consumer helpers (rc_demo_producer / rc_demo_consumer)
//     exist so a pure-Rail smoke can drive the primitive end-to-end without
//     needing a generic Rail -> C callback bridge (deferred to v1).

#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>

#define MAX_CHANNELS 256
#define MAX_TASKS    256

typedef struct {
    int            in_use;
    int            closed;
    int            capacity;
    int            count;
    int            head;     // next slot to read
    int            tail;     // next slot to write
    int64_t       *buf;
    pthread_mutex_t mu;
    pthread_cond_t  not_empty;
    pthread_cond_t  not_full;
} rc_chan_t;

typedef struct {
    int        in_use;
    int        done;
    int64_t    result;       // for the demo consumer: sum of received values
    pthread_t  th;
} rc_task_t;

static rc_chan_t g_chans[MAX_CHANNELS];
static rc_task_t g_tasks[MAX_TASKS];
static pthread_mutex_t g_tab_mu = PTHREAD_MUTEX_INITIALIZER;

// ── public API ──────────────────────────────────────────────────────────────

// Returns a channel handle in [1, MAX_CHANNELS], or 0 on failure.
long rcon_chan_make(long capacity) {
    if (capacity <= 0) capacity = 1;
    pthread_mutex_lock(&g_tab_mu);
    int slot = -1;
    for (int i = 0; i < MAX_CHANNELS; i++) {
        if (!g_chans[i].in_use) { slot = i; break; }
    }
    if (slot < 0) { pthread_mutex_unlock(&g_tab_mu); return 0; }
    rc_chan_t *c = &g_chans[slot];
    memset(c, 0, sizeof(*c));
    c->in_use   = 1;
    c->capacity = (int)capacity;
    c->buf      = (int64_t*)calloc((size_t)capacity, sizeof(int64_t));
    pthread_mutex_init(&c->mu, NULL);
    pthread_cond_init(&c->not_empty, NULL);
    pthread_cond_init(&c->not_full,  NULL);
    pthread_mutex_unlock(&g_tab_mu);
    return (long)(slot + 1);
}

static rc_chan_t* chan_lookup(long h) {
    if (h < 1 || h > MAX_CHANNELS) return NULL;
    rc_chan_t *c = &g_chans[h - 1];
    if (!c->in_use) return NULL;
    return c;
}

// Blocks while channel is full and not closed.
// Returns 1 on success, 0 if the channel was closed before send completed.
long rcon_chan_send(long h, long value) {
    rc_chan_t *c = chan_lookup(h);
    if (!c) return 0;
    pthread_mutex_lock(&c->mu);
    while (c->count == c->capacity && !c->closed) {
        pthread_cond_wait(&c->not_full, &c->mu);
    }
    if (c->closed) { pthread_mutex_unlock(&c->mu); return 0; }
    c->buf[c->tail] = (int64_t)value;
    c->tail = (c->tail + 1) % c->capacity;
    c->count++;
    pthread_cond_signal(&c->not_empty);
    pthread_mutex_unlock(&c->mu);
    return 1;
}

// Blocks while channel is empty and not closed.
// Returns the int64 value on success. On closed+empty returns INT64_MIN
// (callers must coordinate via close or a known sentinel).
long rcon_chan_recv(long h) {
    rc_chan_t *c = chan_lookup(h);
    if (!c) return INT64_MIN;
    pthread_mutex_lock(&c->mu);
    while (c->count == 0 && !c->closed) {
        pthread_cond_wait(&c->not_empty, &c->mu);
    }
    if (c->count == 0 && c->closed) {
        pthread_mutex_unlock(&c->mu);
        return INT64_MIN;
    }
    int64_t v = c->buf[c->head];
    c->head = (c->head + 1) % c->capacity;
    c->count--;
    pthread_cond_signal(&c->not_full);
    pthread_mutex_unlock(&c->mu);
    return (long)v;
}

// Recv variant intended for the v1 typed-channel wrapper:
// returns the same int64 as rcon_chan_recv, but is declared on the Rail
// side as `-> ptr` so the FFI emitter skips the int-retag (`lsl x0,#1; orr
// x0,#1`). Used to round-trip raw 64-bit handles to heap-allocated boxes
// (see stdlib/concurrent.rail::chan_send_v / chan_recv_v).
//
// Rail-side arg untagging is still applied to the channel handle (small
// int, fits cleanly), so no caller change is needed for that arg.
long rcon_chan_recv_box(long h) {
    return rcon_chan_recv(h);
}


// ── select primitive (v1) ───────────────────────────────────────────────────
//
// Try-recv on each channel in turn; if any has a value, return its index
// and write the value to *out. If all are empty and at least one is open,
// sleep briefly and retry. If all are empty and all are closed, return -1.
//
// `handles` points to a Rail mutable-array data block (see _rail_arr_new
// layout: [tag, len, slot_0, slot_1, ...]). We dispatch via a small adapter
// since the Rail side passes the array pointer verbatim.
//
// Performance characteristic: this is a busy-poll with usleep(50us) between
// rounds. v1 is correctness-first; a true cond-var-driven select (single
// shared cond + per-channel registration) is deferred to v2.
//
// Returns:
//   >=0  : index of channel that produced a value; *out_value holds it
//   -1   : all channels closed and drained (caller should treat as EOF)

#include <unistd.h>

// blocking try-once: returns 1 + sets *out if c has a value; 0 otherwise.
// Distinguishes "empty-but-open" (0) from "empty-and-closed" (-1) via *closed_out.
static int try_recv_locked(rc_chan_t *c, int64_t *out, int *closed_out) {
    pthread_mutex_lock(&c->mu);
    if (c->count > 0) {
        *out = c->buf[c->head];
        c->head = (c->head + 1) % c->capacity;
        c->count--;
        pthread_cond_signal(&c->not_full);
        *closed_out = 0;
        pthread_mutex_unlock(&c->mu);
        return 1;
    }
    *closed_out = c->closed ? 1 : 0;
    pthread_mutex_unlock(&c->mu);
    return 0;
}

// rail_arr_new layout: [type_tag(8), len(8), slot_0(8), slot_1(8), ...]
// (verified empirically via arr_set/arr_get codegen at compile.rail:1199-1204
//  which addresses slot_i at base + (i+2)*8).
static int64_t arr_slot(long arr_ptr, int idx) {
    int64_t *base = (int64_t*)arr_ptr;
    return base[2 + idx];
}

// Untag a Rail tagged-int (LSB=1: arithmetic shift right by 1).
// LSB=0 values pass through untouched (heap pointers, etc.).
static int64_t rail_untag(int64_t v) {
    if (v & 1) return v >> 1;
    return v;
}

// Generic select across `count` channels held in `handles_arr`. Returns
// the index of the channel that produced a value, or -1 if all closed.
// The recv'd value is placed into the first slot of `out_value_arr` (also
// a Rail mutable array of length >= 1).
//
// Both array pointers come in as Rail heap pointers (LSB=0); Rail's FFI
// untag is a CSEL no-op for them.
//
// `as_tagged_int`:
//   0 = store the raw wire value (v0 boxed-ptr path: caller derefs)
//   1 = pre-retag the wire value as Rail tagged int `(v << 1) | 1`
//       so the caller can read via arr_get and use as a normal int
//       without further bit manipulation
//
// Fairness: a process-wide rotating cursor (`g_select_cursor`) is the
// scan starting offset on every call. Without rotation, an always-ready
// channel-0 would starve the rest. The cursor is incremented on each
// call (atomic-relaxed semantics; tearing on the int is benign for our
// purposes since the only requirement is "eventually all values").
static unsigned int g_select_cursor = 0;

static long select_loop(long handles_arr, long count, long out_value_arr, int as_tagged_int) {
    int64_t *out_base = (int64_t*)out_value_arr;
    int64_t *out_slot = &out_base[2];  // slot 0 of the out array
    if (count <= 0) { *out_slot = 0; return -1; }
    unsigned int rot = g_select_cursor++;
    while (1) {
        int all_closed = 1;
        // Round-robin starting at `rot` (advanced each call) so we don't
        // perpetually favor channel 0 when several are simultaneously ready.
        for (long step = 0; step < count; step++) {
            long i = (rot + step) % count;
            long h = (long)rail_untag(arr_slot(handles_arr, (int)i));
            rc_chan_t *c = chan_lookup(h);
            if (!c) continue;  // bad handle is "closed" for our purposes
            int64_t v = 0;
            int closed = 0;
            int got = try_recv_locked(c, &v, &closed);
            if (got) {
                *out_slot = as_tagged_int ? ((v << 1) | 1) : v;
                return i;
            }
            if (!closed) all_closed = 0;
        }
        if (all_closed) {
            *out_slot = 0;
            return -1;
        }
        // Brief sleep + advance rot to give a different channel
        // first-chance on the next poll round.
        rot++;
        usleep(50);  // 50us busy-poll cadence
    }
}

// Boxed-value select (for v1 typed channels carrying box pointers).
// Caller unboxes via arr_get on the recv'd box.
long rcon_chan_select(long handles_arr, long count, long out_value_arr) {
    return select_loop(handles_arr, count, out_value_arr, 0);
}

// Int-value select (for v0 raw-int channels). Pre-retags the wire value
// as a Rail tagged int so the Rail caller can use arr_get + the value
// directly as a normal int.
long rcon_chan_select_int(long handles_arr, long count, long out_value_arr) {
    return select_loop(handles_arr, count, out_value_arr, 1);
}

// Non-blocking variant: scans once; returns -1 immediately if no channel
// has a value. Distinct from rcon_chan_select's -1 (all-closed) — caller
// pairs with a sentinel default value at the Rail level.
static long select_try_once(long handles_arr, long count, long out_value_arr, int as_tagged_int) {
    int64_t *out_base = (int64_t*)out_value_arr;
    int64_t *out_slot = &out_base[2];
    for (long i = 0; i < count; i++) {
        long h = (long)rail_untag(arr_slot(handles_arr, (int)i));
        rc_chan_t *c = chan_lookup(h);
        if (!c) continue;
        int64_t v = 0;
        int closed = 0;
        if (try_recv_locked(c, &v, &closed)) {
            *out_slot = as_tagged_int ? ((v << 1) | 1) : v;
            return i;
        }
    }
    *out_slot = 0;
    return -1;
}

long rcon_chan_select_try(long handles_arr, long count, long out_value_arr) {
    return select_try_once(handles_arr, count, out_value_arr, 0);
}

long rcon_chan_select_int_try(long handles_arr, long count, long out_value_arr) {
    return select_try_once(handles_arr, count, out_value_arr, 1);
}

// Closes a channel: wakes all blocked senders/recvers, drains permitted but
// subsequent send returns 0 and subsequent recv on empty returns INT64_MIN.
long rcon_chan_close(long h) {
    rc_chan_t *c = chan_lookup(h);
    if (!c) return 0;
    pthread_mutex_lock(&c->mu);
    c->closed = 1;
    pthread_cond_broadcast(&c->not_empty);
    pthread_cond_broadcast(&c->not_full);
    pthread_mutex_unlock(&c->mu);
    return 1;
}

// Returns current count of buffered items (informational; not synchronized
// across multiple recvs without external coordination).
long rcon_chan_count(long h) {
    rc_chan_t *c = chan_lookup(h);
    if (!c) return 0;
    pthread_mutex_lock(&c->mu);
    long n = (long)c->count;
    pthread_mutex_unlock(&c->mu);
    return n;
}

// ── generic spawn (foundation for future Rail-callable spawns) ──────────────
//
// rcon_spawn registers a C-side function pointer + opaque arg on a new
// pthread. Returns a task handle in [1, MAX_TASKS], or 0 on failure.
// Today this is only callable from C (the demo helpers below use it);
// a future v1 will wire it to JIT-emitted Rail thunks the way
// tools/jit_call.c::jit_call wires direct-call trampolines.

static int alloc_task_slot(void) {
    pthread_mutex_lock(&g_tab_mu);
    int slot = -1;
    for (int i = 0; i < MAX_TASKS; i++) {
        if (!g_tasks[i].in_use) { slot = i; break; }
    }
    if (slot >= 0) {
        memset(&g_tasks[slot], 0, sizeof(rc_task_t));
        g_tasks[slot].in_use = 1;
    }
    pthread_mutex_unlock(&g_tab_mu);
    return slot;
}

typedef void *(*rc_thread_fn_t)(void *);

long rcon_spawn(rc_thread_fn_t fn, void *arg) {
    int slot = alloc_task_slot();
    if (slot < 0) return 0;
    int rc = pthread_create(&g_tasks[slot].th, NULL, fn, arg);
    if (rc != 0) {
        g_tasks[slot].in_use = 0;
        return 0;
    }
    return (long)(slot + 1);
}

// Join a task handle; returns the int64 result the thread parked in
// g_tasks[slot].result (set by the demo workers below) or 0 if invalid.
long rcon_join(long task_id) {
    if (task_id < 1 || task_id > MAX_TASKS) return 0;
    rc_task_t *t = &g_tasks[task_id - 1];
    if (!t->in_use) return 0;
    pthread_join(t->th, NULL);
    long r = (long)t->result;
    t->in_use = 0;
    return r;
}

// ── demo workers (used by tools/runtime/test_concurrent.rail) ───────────────
//
// We need these C-side stubs because Rail does not yet have a way to ship a
// pure-Rail function pointer through `rcon_spawn`. Once that's available
// (JIT thunk + tagged-pointer-to-closure), these go away.

typedef struct {
    long chan_h;
    long n;       // produce 1..n
} producer_arg_t;

static void *demo_producer_thread(void *vp) {
    producer_arg_t *a = (producer_arg_t*)vp;
    for (long i = 1; i <= a->n; i++) {
        if (rcon_chan_send(a->chan_h, i) == 0) break;  // closed mid-flight
    }
    rcon_chan_close(a->chan_h);
    free(a);
    return NULL;
}

typedef struct {
    long      chan_h;
    long      slot;        // index into g_tasks for result write-back
} consumer_arg_t;

static void *demo_consumer_thread(void *vp) {
    consumer_arg_t *a = (consumer_arg_t*)vp;
    int64_t sum = 0;
    for (;;) {
        long v = rcon_chan_recv(a->chan_h);
        if (v == INT64_MIN) break;   // channel closed + drained
        sum += v;
    }
    g_tasks[a->slot].result = sum;
    g_tasks[a->slot].done   = 1;
    free(a);
    return NULL;
}

// Spawn a producer that sends 1..n then closes the channel.
// Returns a task handle for rcon_join (which will return 0; producer has no
// result). Returns 0 on failure.
long rcon_spawn_producer(long chan_h, long n) {
    producer_arg_t *a = (producer_arg_t*)malloc(sizeof(producer_arg_t));
    if (!a) return 0;
    a->chan_h = chan_h;
    a->n      = n;
    int slot = alloc_task_slot();
    if (slot < 0) { free(a); return 0; }
    int rc = pthread_create(&g_tasks[slot].th, NULL, demo_producer_thread, a);
    if (rc != 0) {
        g_tasks[slot].in_use = 0;
        free(a);
        return 0;
    }
    return (long)(slot + 1);
}

// Spawn a consumer that recvs until the channel is closed+drained, summing
// values; sum is written back to the task slot for rcon_join to return.
long rcon_spawn_consumer(long chan_h) {
    int slot = alloc_task_slot();
    if (slot < 0) return 0;
    consumer_arg_t *a = (consumer_arg_t*)malloc(sizeof(consumer_arg_t));
    if (!a) { g_tasks[slot].in_use = 0; return 0; }
    a->chan_h = chan_h;
    a->slot   = slot;
    int rc = pthread_create(&g_tasks[slot].th, NULL, demo_consumer_thread, a);
    if (rc != 0) {
        g_tasks[slot].in_use = 0;
        free(a);
        return 0;
    }
    return (long)(slot + 1);
}
