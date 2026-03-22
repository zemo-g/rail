// Rail GC — Conservative Mark-Sweep Garbage Collector
// Scans ARM64 stack frames for heap pointers, marks reachable tagged objects,
// sweeps unmarked objects into a free list for reuse by _rail_alloc.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Globals defined in generated assembly (C names → symbol _rail_*)
extern char rail_heap[];
extern uint64_t rail_heap_ptr;
extern uint64_t rail_heap_end;

// Free list node — overlaid on freed heap objects
typedef struct free_node {
    uint64_t size;           // usable size (excluding 8-byte header)
    struct free_node* next;
} free_node_t;

free_node_t* rail_free_list = NULL;

// Mark stack — heap-allocated array of pointers to mark
static void**   mark_stack     = NULL;
static uint64_t mark_stack_top = 0;
static uint64_t mark_stack_cap = 0;

#define MARK_BIT      (1ULL << 63)
#define TAG_MASK      (~MARK_BIT)
#define FRAME_SIZE    2048

// --- Helpers ---

static inline int is_heap_ptr(uint64_t val) {
    return val >= (uint64_t)rail_heap &&
           val < (uint64_t)rail_heap_ptr &&
           (val & 7) == 0;  // 8-byte aligned
}

static inline uint64_t get_tag(void* obj) {
    return *(uint64_t*)obj & TAG_MASK;
}

static inline int is_marked(void* obj) {
    return (*(uint64_t*)obj & MARK_BIT) != 0;
}

static inline void set_mark(void* obj) {
    *(uint64_t*)obj |= MARK_BIT;
}

static inline void clear_mark(void* obj) {
    *(uint64_t*)obj &= ~MARK_BIT;
}

// Get allocation size from header (stored at obj - 8)
static inline uint64_t alloc_size(void* obj) {
    return *((uint64_t*)obj - 1);
}

static void mark_push(void* ptr) {
    if (mark_stack_top < mark_stack_cap) {
        mark_stack[mark_stack_top++] = ptr;
    }
    // If stack full, silently drop — conservative GC is safe,
    // just means some objects won't be freed this cycle
}

// --- Mark Phase ---

// Try to mark an object. If it's a valid unmarked heap object, mark it
// and push its children for processing.
static void try_mark(uint64_t val) {
    if (!is_heap_ptr(val)) return;

    void* obj = (void*)val;

    // Check if this points to a valid object (past a size header)
    uint64_t tag = get_tag(obj);
    if (tag < 1 || tag > 6) return;  // not a valid tagged object
    if (is_marked(obj)) return;

    set_mark(obj);
    uint64_t sz = alloc_size(obj);

    switch (tag) {
    case 1: { // Cons [tag, head, tail]
        uint64_t head = ((uint64_t*)obj)[1];
        uint64_t tail = ((uint64_t*)obj)[2];
        // Mark head, then tail-chase for list optimization
        if (is_heap_ptr(head)) {
            void* h = (void*)head;
            uint64_t ht = get_tag(h);
            if (ht >= 1 && ht <= 6 && !is_marked(h)) {
                mark_push(h);
            }
        }
        // Tail-chase: iterate through cons cells without pushing
        while (is_heap_ptr(tail)) {
            void* t = (void*)tail;
            uint64_t tt = get_tag(t);
            if (tt < 1 || tt > 6 || is_marked(t)) break;
            set_mark(t);
            if (tt != 1) { mark_push(t); break; }
            // It's another cons cell — mark head, continue with tail
            uint64_t th = ((uint64_t*)t)[1];
            if (is_heap_ptr(th)) {
                void* thp = (void*)th;
                uint64_t tht = get_tag(thp);
                if (tht >= 1 && tht <= 6 && !is_marked(thp))
                    mark_push(thp);
            }
            tail = ((uint64_t*)t)[2];
        }
        break;
    }
    case 2: // Nil — no children
    case 6: // Float — no children
        break;
    case 3: { // Tuple [tag, elem0, elem1, ...]
        uint64_t n = (sz - 8) / 8;  // number of elements
        for (uint64_t i = 0; i < n; i++) {
            uint64_t child = ((uint64_t*)obj)[1 + i];
            if (is_heap_ptr(child)) {
                void* c = (void*)child;
                uint64_t ct = get_tag(c);
                if (ct >= 1 && ct <= 6 && !is_marked(c))
                    mark_push(c);
            }
        }
        break;
    }
    case 4: { // Closure [tag, fn_ptr, ncap, cap0, cap1, ...]
        uint64_t ncap = ((uint64_t*)obj)[2];
        for (uint64_t i = 0; i < ncap; i++) {
            uint64_t child = ((uint64_t*)obj)[3 + i];
            if (is_heap_ptr(child)) {
                void* c = (void*)child;
                uint64_t ct = get_tag(c);
                if (ct >= 1 && ct <= 6 && !is_marked(c))
                    mark_push(c);
            }
        }
        break;
    }
    case 5: { // ADT [tag, ctor_idx, field0, field1, ...]
        uint64_t n = (sz - 16) / 8;  // number of fields
        for (uint64_t i = 0; i < n; i++) {
            uint64_t child = ((uint64_t*)obj)[2 + i];
            if (is_heap_ptr(child)) {
                void* c = (void*)child;
                uint64_t ct = get_tag(c);
                if (ct >= 1 && ct <= 6 && !is_marked(c))
                    mark_push(c);
            }
        }
        break;
    }
    }
}

// Drain the mark stack — process all pending objects
static void drain_mark_stack(void) {
    while (mark_stack_top > 0) {
        void* obj = mark_stack[--mark_stack_top];
        uint64_t tag = get_tag(obj);
        uint64_t sz = alloc_size(obj);

        switch (tag) {
        case 1: { // Cons
            uint64_t head = ((uint64_t*)obj)[1];
            uint64_t tail = ((uint64_t*)obj)[2];
            try_mark(head);
            try_mark(tail);
            break;
        }
        case 3: { // Tuple
            uint64_t n = (sz - 8) / 8;
            for (uint64_t i = 0; i < n; i++)
                try_mark(((uint64_t*)obj)[1 + i]);
            break;
        }
        case 4: { // Closure
            uint64_t ncap = ((uint64_t*)obj)[2];
            for (uint64_t i = 0; i < ncap; i++)
                try_mark(((uint64_t*)obj)[3 + i]);
            break;
        }
        case 5: { // ADT
            uint64_t n = (sz - 16) / 8;
            for (uint64_t i = 0; i < n; i++)
                try_mark(((uint64_t*)obj)[2 + i]);
            break;
        }
        default: break; // Nil, Float — no children
        }
    }
}

// Scan a stack frame for potential heap pointers
static void scan_frame(uint64_t* frame_base, uint64_t* frame_top) {
    for (uint64_t* p = frame_base; p < frame_top; p++) {
        try_mark(*p);
    }
}

// --- Sweep Phase ---

static void sweep(void) {
    char* pos = rail_heap;
    char* end = (char*)rail_heap_ptr;

    rail_free_list = NULL;  // rebuild free list from scratch

    while (pos + 8 <= end) {
        uint64_t sz = *(uint64_t*)pos;        // size header
        void* obj = pos + 8;                   // object pointer

        if ((char*)obj + sz > end) break;      // corrupt/partial — stop

        uint64_t tag = get_tag(obj);
        if (tag >= 1 && tag <= 6) {
            if (is_marked(obj)) {
                clear_mark(obj);
            } else {
                // Unmarked — add to free list
                free_node_t* node = (free_node_t*)obj;
                node->size = sz;
                node->next = rail_free_list;
                rail_free_list = node;
            }
        }
        // Advance: header(8) + aligned(size)
        uint64_t aligned = (sz + 7) & ~7ULL;
        pos += 8 + aligned;
    }
}

// --- Public API ---

void rail_gc(void) {
    // Allocate mark stack (512K entries = 4MB)
    mark_stack_cap = 512 * 1024;
    mark_stack = (void**)malloc(mark_stack_cap * sizeof(void*));
    if (!mark_stack) return;  // can't GC, caller will fall back to malloc
    mark_stack_top = 0;

    // Walk stack frames via x29 chain
    uint64_t* fp;
    __asm__ volatile("mov %0, x29" : "=r"(fp));

    while (fp) {
        uint64_t* parent = (uint64_t*)*fp;
        uint64_t* locals_start = fp + 2;
        uint64_t* locals_end = fp + (FRAME_SIZE / 8);

        // Don't scan beyond the parent frame or into invalid memory
        if (parent && parent < locals_end)
            locals_end = parent;

        scan_frame(locals_start, locals_end);
        drain_mark_stack();

        fp = parent;
    }

    // Sweep
    sweep();

    // Free mark stack
    free(mark_stack);
    mark_stack = NULL;
    mark_stack_top = 0;
    mark_stack_cap = 0;
}

// Find a free block >= size. First-fit. Returns pointer, or NULL.
void* rail_free_list_alloc(uint64_t size) {
    free_node_t** prev = &rail_free_list;
    free_node_t* node = rail_free_list;

    while (node) {
        if (node->size >= size) {
            *prev = node->next;
            return (void*)node;
        }
        prev = &node->next;
        node = node->next;
    }
    return NULL;
}

// Clear free list (called by arena_reset)
void rail_free_list_clear(void) {
    rail_free_list = NULL;
}
