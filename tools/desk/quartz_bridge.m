// quartz_bridge.m — Objective-C bridge for stdlib/quartz.rail
//
// Architecture:
//   • CGEventTap is installed on a dedicated runloop thread. The C callback
//     decodes the CGEvent into a fixed-size struct (qb_event_t) and pushes it
//     into a mutex-protected ring buffer.
//   • qb_next_event() pops from that buffer with a timeout via condvar wait.
//   • qb_inject_* synthesize events via CGEventCreate*Event + CGEventPost.
//   • All paths are pure C ABI so Rail's `foreign` decls resolve cleanly.
//
// Permissions:
//   CGEventTap requires Accessibility permission. First run will prompt;
//   user must grant it in System Settings → Privacy & Security → Accessibility.
//
// Build:
//   clang -shared -fobjc-arc \
//     -framework CoreGraphics -framework Foundation -framework AppKit \
//     -install_name ~/projects/rail/tools/desk/libquartz_bridge.dylib \
//     tools/desk/quartz_bridge.m -o tools/desk/libquartz_bridge.dylib
//
// Status: SKETCH. Skeleton compiles; tap installation + ring buffer TODO.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Event type codes (must match qz_ev_* in stdlib/quartz.rail)
#define QB_EV_NONE          0
#define QB_EV_MOUSE_MOVE    1
#define QB_EV_MOUSE_DOWN    2
#define QB_EV_MOUSE_UP      3
#define QB_EV_KEY_DOWN      4
#define QB_EV_KEY_UP        5
#define QB_EV_SCROLL        6
#define QB_EV_FLAGS_CHANGE  7

// Event-mask bits (must match qz_mask_*)
#define QB_MASK_MOUSE_MOVE   1
#define QB_MASK_MOUSE_BUTTON 2
#define QB_MASK_KEY          4
#define QB_MASK_SCROLL       8
#define QB_MASK_FLAGS       16

// On-the-wire event record. All fields are double so it lines up with Rail's
// float_arr (which is doubles). Reading code on the Rail side casts to int via
// float_to_int where appropriate.
typedef struct {
    int      type;
    double   field0;  // dx | button | keycode | scroll_dx
    double   field1;  // dy | mods   | mods    | scroll_dy
    double   field2;  // absolute x  (mouse_move only)
    double   field3;  // absolute y  (mouse_move only)
} qb_event_t;

// Ring buffer
#define QB_RING_CAPACITY 1024
static qb_event_t       g_ring[QB_RING_CAPACITY];
static size_t           g_ring_head = 0;
static size_t           g_ring_tail = 0;
static pthread_mutex_t  g_ring_mu   = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t   g_ring_cv   = PTHREAD_COND_INITIALIZER;

// Tap state
static CFMachPortRef    g_tap        = NULL;
static CFRunLoopSourceRef g_tap_src  = NULL;
static pthread_t        g_runloop_thread;
static int              g_initialized = 0;
static CFRunLoopRef     g_tap_runloop = NULL;

// Modifier flag conversion: macOS NSEventModifierFlags → our qz_mod_* bits.
// (Reduces a 32-bit field to the few bits Rail cares about.)
static int extract_mods(CGEventFlags f) {
    int m = 0;
    if (f & kCGEventFlagMaskShift)      m |= 1;
    if (f & kCGEventFlagMaskControl)    m |= 2;
    if (f & kCGEventFlagMaskAlternate)  m |= 4;
    if (f & kCGEventFlagMaskCommand)    m |= 8;
    if (f & kCGEventFlagMaskSecondaryFn) m |= 16;
    if (f & kCGEventFlagMaskAlphaShift)  m |= 32;
    return m;
}

static void ring_push(const qb_event_t *ev) {
    pthread_mutex_lock(&g_ring_mu);
    g_ring[g_ring_head] = *ev;
    g_ring_head = (g_ring_head + 1) % QB_RING_CAPACITY;
    if (g_ring_head == g_ring_tail) {
        // Overflow — drop oldest.
        g_ring_tail = (g_ring_tail + 1) % QB_RING_CAPACITY;
    }
    pthread_cond_signal(&g_ring_cv);
    pthread_mutex_unlock(&g_ring_mu);
}

static int ring_pop_blocking(qb_event_t *out, int timeout_ms) {
    pthread_mutex_lock(&g_ring_mu);
    if (g_ring_head == g_ring_tail) {
        if (timeout_ms == 0) {
            pthread_mutex_unlock(&g_ring_mu);
            return 0;
        }
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec  += timeout_ms / 1000;
        ts.tv_nsec += (timeout_ms % 1000) * 1000000L;
        if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
        while (g_ring_head == g_ring_tail) {
            int rc = pthread_cond_timedwait(&g_ring_cv, &g_ring_mu, &ts);
            if (rc == ETIMEDOUT) {
                pthread_mutex_unlock(&g_ring_mu);
                return 0;
            }
        }
    }
    *out = g_ring[g_ring_tail];
    g_ring_tail = (g_ring_tail + 1) % QB_RING_CAPACITY;
    pthread_mutex_unlock(&g_ring_mu);
    return 1;
}

static CGEventRef tap_callback(CGEventTapProxy proxy, CGEventType type,
                               CGEventRef event, void *userInfo) {
    qb_event_t ev = {0};
    switch (type) {
        case kCGEventMouseMoved:
        case kCGEventLeftMouseDragged:
        case kCGEventRightMouseDragged:
        case kCGEventOtherMouseDragged: {
            ev.type = QB_EV_MOUSE_MOVE;
            ev.field0 = CGEventGetDoubleValueField(event, kCGMouseEventDeltaX);
            ev.field1 = CGEventGetDoubleValueField(event, kCGMouseEventDeltaY);
            CGPoint p = CGEventGetLocation(event);
            ev.field2 = p.x;
            ev.field3 = p.y;
            ring_push(&ev);
            break;
        }
        case kCGEventLeftMouseDown:
        case kCGEventRightMouseDown:
        case kCGEventOtherMouseDown: {
            ev.type = QB_EV_MOUSE_DOWN;
            ev.field0 = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
            ring_push(&ev);
            break;
        }
        case kCGEventLeftMouseUp:
        case kCGEventRightMouseUp:
        case kCGEventOtherMouseUp: {
            ev.type = QB_EV_MOUSE_UP;
            ev.field0 = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
            ring_push(&ev);
            break;
        }
        case kCGEventKeyDown: {
            ev.type = QB_EV_KEY_DOWN;
            ev.field0 = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
            ev.field1 = extract_mods(CGEventGetFlags(event));
            ring_push(&ev);
            break;
        }
        case kCGEventKeyUp: {
            ev.type = QB_EV_KEY_UP;
            ev.field0 = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
            ev.field1 = extract_mods(CGEventGetFlags(event));
            ring_push(&ev);
            break;
        }
        case kCGEventScrollWheel: {
            ev.type = QB_EV_SCROLL;
            ev.field0 = CGEventGetDoubleValueField(event, kCGScrollWheelEventDeltaAxis2);  // horizontal
            ev.field1 = CGEventGetDoubleValueField(event, kCGScrollWheelEventDeltaAxis1);  // vertical
            ring_push(&ev);
            break;
        }
        case kCGEventFlagsChanged: {
            ev.type = QB_EV_FLAGS_CHANGE;
            ev.field0 = extract_mods(CGEventGetFlags(event));
            ring_push(&ev);
            break;
        }
        default:
            // Don't drop the event — return it unchanged so the system still gets it.
            break;
    }
    // Pass-through: we're a passive tap, so always return the event so the OS
    // delivers it to the focused app. (For the KVM SERVER case we'd return NULL
    // when in "remote focus" mode to swallow events locally.)
    return event;
}

static void *runloop_main(void *arg) {
    uint32_t mask_bits = (uint32_t)(uintptr_t)arg;
    CGEventMask mask = 0;
    if (mask_bits & QB_MASK_MOUSE_MOVE) {
        mask |= CGEventMaskBit(kCGEventMouseMoved)
             |  CGEventMaskBit(kCGEventLeftMouseDragged)
             |  CGEventMaskBit(kCGEventRightMouseDragged)
             |  CGEventMaskBit(kCGEventOtherMouseDragged);
    }
    if (mask_bits & QB_MASK_MOUSE_BUTTON) {
        mask |= CGEventMaskBit(kCGEventLeftMouseDown)  | CGEventMaskBit(kCGEventLeftMouseUp)
             |  CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp)
             |  CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp);
    }
    if (mask_bits & QB_MASK_KEY) {
        mask |= CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
    }
    if (mask_bits & QB_MASK_SCROLL) {
        mask |= CGEventMaskBit(kCGEventScrollWheel);
    }
    if (mask_bits & QB_MASK_FLAGS) {
        mask |= CGEventMaskBit(kCGEventFlagsChanged);
    }

    g_tap = CGEventTapCreate(kCGSessionEventTap,
                             kCGHeadInsertEventTap,
                             kCGEventTapOptionDefault,
                             mask,
                             tap_callback,
                             NULL);
    if (!g_tap) {
        NSLog(@"[quartz_bridge] CGEventTapCreate failed — Accessibility permission?");
        return NULL;
    }
    g_tap_src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_tap, 0);
    g_tap_runloop = CFRunLoopGetCurrent();
    CFRunLoopAddSource(g_tap_runloop, g_tap_src, kCFRunLoopCommonModes);
    CGEventTapEnable(g_tap, true);
    CFRunLoopRun();
    return NULL;
}

// ── Exported C ABI ────────────────────────────────────────────────────────────

int qb_init(int event_mask) {
    if (g_initialized) return 0;
    if (pthread_create(&g_runloop_thread, NULL, runloop_main,
                       (void *)(uintptr_t)event_mask) != 0) {
        return -1;
    }
    g_initialized = 1;
    return 0;
}

int qb_next_event(double *out_arr, int timeout_ms) {
    if (!g_initialized) return 0;
    qb_event_t ev;
    if (!ring_pop_blocking(&ev, timeout_ms)) return 0;
    // out_arr layout: [count_header_at_0][field0_at_1][field1_at_2]...
    // Rail float_arr's data starts at index 1 (count is at index 0).
    out_arr[1] = ev.field0;
    out_arr[2] = ev.field1;
    out_arr[3] = ev.field2;
    out_arr[4] = ev.field3;
    return ev.type;
}

int qb_inject_mouse_move(double x, double y) {
    CGEventRef e = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved,
                                           CGPointMake(x, y), kCGMouseButtonLeft);
    if (!e) return -1;
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
    return 0;
}

int qb_inject_mouse_button(int button, int down) {
    // Look up current cursor location to inject the click "in place."
    CGEventRef probe = CGEventCreate(NULL);
    CGPoint p = probe ? CGEventGetLocation(probe) : CGPointMake(0, 0);
    if (probe) CFRelease(probe);

    CGEventType ty;
    if (button == 0) ty = down ? kCGEventLeftMouseDown  : kCGEventLeftMouseUp;
    else if (button == 1) ty = down ? kCGEventRightMouseDown : kCGEventRightMouseUp;
    else                  ty = down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp;

    CGEventRef e = CGEventCreateMouseEvent(NULL, ty, p, (CGMouseButton)button);
    if (!e) return -1;
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
    return 0;
}

int qb_inject_key(int keycode, int down, int flags) {
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)keycode, down ? true : false);
    if (!e) return -1;
    CGEventFlags f = 0;
    if (flags &  1) f |= kCGEventFlagMaskShift;
    if (flags &  2) f |= kCGEventFlagMaskControl;
    if (flags &  4) f |= kCGEventFlagMaskAlternate;
    if (flags &  8) f |= kCGEventFlagMaskCommand;
    if (flags & 16) f |= kCGEventFlagMaskSecondaryFn;
    CGEventSetFlags(e, f);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
    return 0;
}

int qb_inject_scroll(double dx, double dy) {
    CGEventRef e = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2,
                                                 (int32_t)dy, (int32_t)dx);
    if (!e) return -1;
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
    return 0;
}

int qb_screen_count(int dummy) {
    (void)dummy;
    uint32_t n = 0;
    CGGetActiveDisplayList(0, NULL, &n);
    return (int)n;
}

int qb_screen_bounds(int idx, double *out_arr) {
    uint32_t n = 0;
    CGGetActiveDisplayList(0, NULL, &n);
    if ((uint32_t)idx >= n) return -1;
    CGDirectDisplayID *ids = (CGDirectDisplayID *)calloc(n, sizeof(CGDirectDisplayID));
    if (!ids) return -1;
    CGGetActiveDisplayList(n, ids, &n);
    CGRect r = CGDisplayBounds(ids[idx]);
    free(ids);
    out_arr[1] = r.origin.x;
    out_arr[2] = r.origin.y;
    out_arr[3] = r.size.width;
    out_arr[4] = r.size.height;
    return 0;
}

int qb_shutdown(int dummy) {
    (void)dummy;
    if (!g_initialized) return 0;
    if (g_tap_runloop) CFRunLoopStop(g_tap_runloop);
    pthread_join(g_runloop_thread, NULL);
    if (g_tap)     { CFRelease(g_tap);     g_tap = NULL; }
    if (g_tap_src) { CFRelease(g_tap_src); g_tap_src = NULL; }
    g_initialized = 0;
    return 0;
}
