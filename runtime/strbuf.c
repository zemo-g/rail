#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>

// Allocate a GC-compatible object using malloc
static uint64_t rt_alloc(uint64_t size) {
    uint64_t aligned = (size + 7) & ~7ULL;
    uint64_t* mem = (uint64_t*)malloc(8 + aligned);
    if (!mem) return 0;
    mem[0] = aligned;
    return (uint64_t)(mem + 1);
}

/* Tag 8 string buffer layout (32 bytes on GC heap):
 *   obj[0] = tag (8)
 *   obj[1] = length (untagged)
 *   obj[2] = capacity (untagged)
 *   obj[3] = pointer to malloc'd char buffer
 */

#define STRBUF_TAG 8
#define DEFAULT_CAP 256

static void buf_ensure(uint64_t *obj, uint64_t need) {
    uint64_t cap = obj[2];
    if (need <= cap) return;
    while (cap < need) cap *= 2;
    obj[3] = (uint64_t)realloc((char *)obj[3], cap);
    obj[2] = cap;
}

uint64_t rail_buf_new(uint64_t capacity_hint) {
    uint64_t cap = DEFAULT_CAP;
    if (capacity_hint & 1) {
        uint64_t hint = capacity_hint >> 1;
        if (hint > 0) cap = hint;
    }

    uint64_t ptr = rt_alloc(32);
    uint64_t *obj = (uint64_t *)ptr;
    obj[0] = STRBUF_TAG;
    obj[1] = 0;
    obj[2] = cap;
    obj[3] = (uint64_t)malloc(cap);
    return ptr;
}

uint64_t rail_buf_append(uint64_t buf, uint64_t str) {
    uint64_t *obj = (uint64_t *)buf;
    const char *s = (const char *)str;
    uint64_t slen = strlen(s);
    buf_ensure(obj, obj[1] + slen);
    memcpy((char *)obj[3] + obj[1], s, slen);
    obj[1] += slen;
    return buf;
}

uint64_t rail_buf_append_int(uint64_t buf, uint64_t n) {
    int64_t val = (int64_t)n >> 1;
    char tmp[32];
    snprintf(tmp, sizeof(tmp), "%lld", (long long)val);
    uint64_t *obj = (uint64_t *)buf;
    uint64_t slen = strlen(tmp);
    buf_ensure(obj, obj[1] + slen);
    memcpy((char *)obj[3] + obj[1], tmp, slen);
    obj[1] += slen;
    return buf;
}

uint64_t rail_buf_to_str(uint64_t buf) {
    uint64_t *obj = (uint64_t *)buf;
    uint64_t len = obj[1];
    char *s = (char *)malloc(len + 1);
    memcpy(s, (char *)obj[3], len);
    s[len] = '\0';
    return (uint64_t)s;
}

uint64_t rail_buf_len(uint64_t buf) {
    uint64_t *obj = (uint64_t *)buf;
    return (obj[1] << 1) | 1;
}

uint64_t rail_buf_clear(uint64_t buf) {
    uint64_t *obj = (uint64_t *)buf;
    obj[1] = 0;
    return buf;
}
