// Rail HashMap — Open-addressed hash map for the Rail runtime
// Tag 7, linear probing, grows at 75% load factor

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Allocate a GC-compatible object: size header + usable area
// Mirrors _rail_alloc but uses malloc to avoid symbol dependency
static uint64_t rt_alloc(uint64_t size) {
    uint64_t aligned = (size + 7) & ~7ULL;
    uint64_t* mem = (uint64_t*)malloc(8 + aligned);
    if (!mem) return 0;
    mem[0] = aligned;  // size header
    return (uint64_t)(mem + 1);  // pointer to usable area
}

// Build a Cons cell [tag=1, head, tail]
static uint64_t rt_cons(uint64_t head, uint64_t tail) {
    uint64_t obj = rt_alloc(24);
    if (!obj) return 2; // nil
    ((uint64_t*)obj)[0] = 1;  // tag = Cons
    ((uint64_t*)obj)[1] = head;
    ((uint64_t*)obj)[2] = tail;
    return obj;
}

#define MAP_TAG         7
#define INITIAL_CAP     16
#define LOAD_FACTOR_NUM 3
#define LOAD_FACTOR_DEN 4
// We need a Nil value (tag=2 object). Create our own since _rail_nil is local.
static uint64_t nil_obj[2] = {0, 2};  // size header=0, tag=2
#define NIL             ((uint64_t)&nil_obj[1])

#define BUCKET_EMPTY     0
#define BUCKET_OCCUPIED  1
#define BUCKET_TOMBSTONE 2

typedef struct {
    uint64_t key;
    uint64_t value;
    uint64_t used;
} bucket_t;

// --- Hashing ---

static uint64_t hash_int(uint64_t x) {
    // Fibonacci hash (golden ratio constant for 64-bit)
    return x * 11400714819323198485ULL;
}

static uint64_t hash_str(const char* s) {
    // FNV-1a 64-bit
    uint64_t h = 14695981039346656037ULL;
    while (*s) {
        h ^= (uint64_t)(unsigned char)*s++;
        h *= 1099511628211ULL;
    }
    return h;
}

static uint64_t hash_key(uint64_t key) {
    if (key & 1) {
        return hash_int(key >> 1);
    } else {
        return hash_str((const char*)key);
    }
}

static int keys_equal(uint64_t a, uint64_t b) {
    if ((a & 1) != (b & 1)) return 0;  // mixed types
    if (a & 1) return a == b;           // both integers
    return strcmp((const char*)a, (const char*)b) == 0;  // both strings
}

// --- Accessors ---

static inline uint64_t  map_count(uint64_t map)    { return ((uint64_t*)map)[1]; }
static inline uint64_t  map_cap(uint64_t map)      { return ((uint64_t*)map)[2]; }
static inline bucket_t* map_buckets(uint64_t map)   { return (bucket_t*)((uint64_t*)map)[3]; }

static inline void set_count(uint64_t map, uint64_t n)    { ((uint64_t*)map)[1] = n; }
static inline void set_cap(uint64_t map, uint64_t n)      { ((uint64_t*)map)[2] = n; }
static inline void set_buckets(uint64_t map, bucket_t* b) { ((uint64_t*)map)[3] = (uint64_t)b; }

// --- Internal ---

static bucket_t* alloc_buckets(uint64_t cap) {
    bucket_t* b = (bucket_t*)malloc(cap * sizeof(bucket_t));
    memset(b, 0, cap * sizeof(bucket_t));
    return b;
}

static void map_resize(uint64_t map) {
    uint64_t old_cap = map_cap(map);
    bucket_t* old = map_buckets(map);
    uint64_t new_cap = old_cap * 2;
    bucket_t* new_b = alloc_buckets(new_cap);

    for (uint64_t i = 0; i < old_cap; i++) {
        if (old[i].used != BUCKET_OCCUPIED) continue;
        uint64_t idx = hash_key(old[i].key) & (new_cap - 1);
        while (new_b[idx].used == BUCKET_OCCUPIED) {
            idx = (idx + 1) & (new_cap - 1);
        }
        new_b[idx].key   = old[i].key;
        new_b[idx].value = old[i].value;
        new_b[idx].used  = BUCKET_OCCUPIED;
    }

    free(old);
    set_cap(map, new_cap);
    set_buckets(map, new_b);
}

// --- Public API ---

uint64_t rail_map_new(uint64_t dummy) {
    (void)dummy;
    uint64_t map = rt_alloc(32);  // 4 x uint64_t
    ((uint64_t*)map)[0] = MAP_TAG;
    set_count(map, 0);
    set_cap(map, INITIAL_CAP);
    set_buckets(map, alloc_buckets(INITIAL_CAP));
    return map;
}

uint64_t rail_map_put(uint64_t map, uint64_t key, uint64_t value) {
    // Grow if needed
    if ((map_count(map) + 1) * LOAD_FACTOR_DEN > map_cap(map) * LOAD_FACTOR_NUM) {
        map_resize(map);
    }

    uint64_t cap = map_cap(map);
    bucket_t* buckets = map_buckets(map);
    uint64_t idx = hash_key(key) & (cap - 1);
    uint64_t first_tombstone = cap;  // sentinel: no tombstone seen

    while (1) {
        if (buckets[idx].used == BUCKET_EMPTY) {
            // Insert at tombstone if we passed one, else here
            if (first_tombstone < cap) idx = first_tombstone;
            buckets[idx].key   = key;
            buckets[idx].value = value;
            buckets[idx].used  = BUCKET_OCCUPIED;
            set_count(map, map_count(map) + 1);
            return map;
        }
        if (buckets[idx].used == BUCKET_TOMBSTONE) {
            if (first_tombstone == cap) first_tombstone = idx;
        } else if (keys_equal(buckets[idx].key, key)) {
            // Update existing key
            buckets[idx].value = value;
            return map;
        }
        idx = (idx + 1) & (cap - 1);
    }
}

uint64_t rail_map_get(uint64_t map, uint64_t key) {
    uint64_t cap = map_cap(map);
    bucket_t* buckets = map_buckets(map);
    uint64_t idx = hash_key(key) & (cap - 1);

    while (1) {
        if (buckets[idx].used == BUCKET_EMPTY) {
            return (0 << 1) | 1;  // tagged 0
        }
        if (buckets[idx].used == BUCKET_OCCUPIED && keys_equal(buckets[idx].key, key)) {
            return buckets[idx].value;
        }
        idx = (idx + 1) & (cap - 1);
    }
}

uint64_t rail_map_has(uint64_t map, uint64_t key) {
    uint64_t cap = map_cap(map);
    bucket_t* buckets = map_buckets(map);
    uint64_t idx = hash_key(key) & (cap - 1);

    while (1) {
        if (buckets[idx].used == BUCKET_EMPTY) {
            return (0 << 1) | 1;  // false
        }
        if (buckets[idx].used == BUCKET_OCCUPIED && keys_equal(buckets[idx].key, key)) {
            return (1 << 1) | 1;  // true
        }
        idx = (idx + 1) & (cap - 1);
    }
}

uint64_t rail_map_del(uint64_t map, uint64_t key) {
    uint64_t cap = map_cap(map);
    bucket_t* buckets = map_buckets(map);
    uint64_t idx = hash_key(key) & (cap - 1);

    while (1) {
        if (buckets[idx].used == BUCKET_EMPTY) {
            return map;  // key not found
        }
        if (buckets[idx].used == BUCKET_OCCUPIED && keys_equal(buckets[idx].key, key)) {
            buckets[idx].used = BUCKET_TOMBSTONE;
            set_count(map, map_count(map) - 1);
            return map;
        }
        idx = (idx + 1) & (cap - 1);
    }
}

uint64_t rail_map_keys(uint64_t map) {
    uint64_t cap = map_cap(map);
    bucket_t* buckets = map_buckets(map);
    uint64_t list = NIL;

    for (uint64_t i = 0; i < cap; i++) {
        if (buckets[i].used == BUCKET_OCCUPIED) {
            list = rt_cons(buckets[i].key, list);
        }
    }
    return list;
}

uint64_t rail_map_size(uint64_t map) {
    return (map_count(map) << 1) | 1;
}
