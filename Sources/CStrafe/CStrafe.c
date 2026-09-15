// CStrafe.c — implementation of the synthetic dock-swipe mechanism.
//
// Legacy technique from jurplel/InstantSpaceSwitcher (MIT); macOS 27 synthesis
// adapted from pinned ISS and FasterSwiper. See THIRD-PARTY-LICENSES.txt.
// Legacy magic numbers are documented in
// docs/SPEC.md §1–2. Treat the field indices and event-type values as
// version-fragile (SPEC §7).

#include "CStrafe.h"

#include <ApplicationServices/ApplicationServices.h>
#include <CoreGraphics/CGEventTypes.h>
#include <CoreFoundation/CoreFoundation.h>
#include <float.h>
#include <string.h>
#include <unistd.h>
#include "EventSerialization.h"

// --- Private CGEventField indices (SPEC §1.2) -----------------------------
static const CGEventField kCGSEventTypeField           = (CGEventField)55;   // private CGSEventType selector
static const CGEventField kCGEventGestureHIDType       = (CGEventField)110;  // IOHIDEvent gesture type
static const CGEventField kCGEventGestureSwipeMotion   = (CGEventField)123;  // motion axis (horizontal=1)
static const CGEventField kCGEventGestureSwipeProgress = (CGEventField)124;  // gesture progress (double)
static const CGEventField kCGEventGestureSwipeVelocityX= (CGEventField)129;  // (double)
static const CGEventField kCGEventGestureSwipeVelocityY= (CGEventField)130;  // (double)
static const CGEventField kCGEventGesturePhase         = (CGEventField)132;  // CGSGesturePhase

// --- Type / enum constants (SPEC §1.3) ------------------------------------
static const uint32_t kIOHIDEventTypeDockSwipe = 23;   // written into field 110

enum {
    kCGSEventScrollWheel       = 22,
    kCGSEventZoom              = 28,
    kCGSEventGesture           = 29,
    kCGSEventDockControl       = 30,   // the dock-swipe type we synthesize + intercept
    kCGSEventFluidTouchGesture = 31,
};

typedef CF_ENUM(uint8_t, CGSGesturePhase) {
    kCGSGesturePhaseNone      = 0,
    kCGSGesturePhaseBegan     = 1,
    kCGSGesturePhaseChanged   = 2,
    kCGSGesturePhaseEnded     = 4,
    kCGSGesturePhaseCancelled = 8,
    kCGSGesturePhaseMayBegin  = 128,
};

typedef CF_ENUM(uint16_t, CGGestureMotion) {
    kCGGestureMotionHorizontal = 1,
};

// --- Weak-imported CGS symbols for space topology (SPEC §1.1) -------------
typedef int32_t  CGSConnectionID;
typedef uint64_t CGSSpaceID;
extern CFArrayRef  CGSCopyManagedDisplaySpaces(CGSConnectionID connection, CFStringRef display) __attribute__((weak_import));
extern CFStringRef CGSCopyActiveMenuBarDisplayIdentifier(CGSConnectionID connection) __attribute__((weak_import));
extern CGSConnectionID CGSMainConnectionID(void) __attribute__((weak_import));
extern CGSSpaceID  CGSGetActiveSpace(CGSConnectionID connection) __attribute__((weak_import));

bool strafe_cgs_available(void) {
    return (&CGSMainConnectionID != NULL) &&
           (&CGSGetActiveSpace != NULL) &&
           (&CGSCopyManagedDisplaySpaces != NULL);
}

// --- Synthesis (SPEC §1.5) ------------------------------------------------
// Modified from pinned ISS ISS.c; see THIRD-PARTY-LICENSES.txt.
static const int64_t kStrafeEventMarker = INT64_C(0x5354524146450001);

CGEventRef strafe_create_switch_event(StrafeDirection direction, double velocity,
                                     int64_t phase, bool augmented, bool inverted) {
    if ((direction != StrafeDirectionLeft && direction != StrafeDirectionRight) ||
        (phase != 1 && phase != 2 && phase != 4 && phase != 8) ||
        !isfinite(velocity) || velocity < 0 || velocity > FLT_MAX) return NULL;
    const bool isRight = (direction == StrafeDirectionRight) != inverted;
    // Empirically, ±FLT_TRUE_MIN used in this way makes switching instant.
    const double magnitude = augmented ? 0.000016 : (double)FLT_TRUE_MIN;
    const double progress = isRight ? magnitude : -magnitude;

    // Velocity of gesture based on speed setting.
    const double vel = isRight ? velocity : -velocity;
    int32_t fixed;
    // Validate even before Ended so an entire sequence can be prebuilt safely.
    if (augmented && !strafe_fixed(vel, &fixed)) return NULL;

    CGEventRef ev = CGEventCreate(NULL);
    if (!ev) { return NULL; }
    CGEventSetIntegerValueField(ev, kCGEventSourceUserData, kStrafeEventMarker);
    CGEventSetIntegerValueField(ev, kCGEventSourceUnixProcessID, getpid());
    CGEventSetIntegerValueField(ev, kCGSEventTypeField,            kCGSEventDockControl);
    CGEventSetIntegerValueField(ev, kCGEventGestureHIDType,        kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(ev, kCGEventGesturePhase,          phase);
    CGEventSetDoubleValueField (ev, kCGEventGestureSwipeProgress,  progress);
    CGEventSetIntegerValueField(ev, kCGEventGestureSwipeMotion,    kCGGestureMotionHorizontal);
    if (augmented) {
        CGEventSetIntegerValueField(ev, (CGEventField)134, phase);
        CGEventSetDoubleValueField(ev, (CGEventField)125, 0.1);
        CGEventSetDoubleValueField(ev, (CGEventField)138, 3.0);
        CGEventSetDoubleValueField(ev, (CGEventField)169, (double)mach_absolute_time());
        if (phase == kCGSGesturePhaseEnded)
            CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityX, vel);
        CGEventRef result = strafe_augment(ev);
        CFRelease(ev);
        // CGEventCreateData omits source user data on macOS 27. Stamp AFTER
        // reconstruction too, so every event returned to the scheduler is marked.
        if (result) {
            CGEventSetIntegerValueField(result, kCGEventSourceUserData, kStrafeEventMarker);
            CGEventSetIntegerValueField(result, kCGEventSourceUnixProcessID, getpid());
        }
        return result;
    }
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityX, vel);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityY, vel);
    return ev;
}

// One ramp phase for the animated Transition speed presets (SPEC §1.4):
// caller-chosen progress/velocity magnitudes, direction applied internally
// like the instant creator above. Unlike the instant shape — whose augmented
// form carries velocity on Ended only — a ramp carries its per-phase velocity
// on every phase; the climbing `changed` stream is what makes the WindowServer
// run its slide instead of flicking.
CGEventRef strafe_create_ramp_event(StrafeDirection direction, double velocity,
                                   int64_t phase, double progress, bool augmented,
                                   bool inverted) {
    if ((direction != StrafeDirectionLeft && direction != StrafeDirectionRight) ||
        (phase != 1 && phase != 2 && phase != 4 && phase != 8) ||
        !isfinite(velocity) || velocity < 0 || velocity > FLT_MAX ||
        !isfinite(progress) || progress < 0) return NULL;
    const bool isRight = (direction == StrafeDirectionRight) != inverted;
    const double signedProgress = isRight ? progress : -progress;
    const double vel = isRight ? velocity : -velocity;
    int32_t fixed;
    if (augmented && (!strafe_fixed(signedProgress, &fixed) || !strafe_fixed(vel, &fixed))) return NULL;

    CGEventRef ev = CGEventCreate(NULL);
    if (!ev) { return NULL; }
    CGEventSetIntegerValueField(ev, kCGEventSourceUserData, kStrafeEventMarker);
    CGEventSetIntegerValueField(ev, kCGEventSourceUnixProcessID, getpid());
    CGEventSetIntegerValueField(ev, kCGSEventTypeField,            kCGSEventDockControl);
    CGEventSetIntegerValueField(ev, kCGEventGestureHIDType,        kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(ev, kCGEventGesturePhase,          phase);
    CGEventSetDoubleValueField (ev, kCGEventGestureSwipeProgress,  signedProgress);
    CGEventSetIntegerValueField(ev, kCGEventGestureSwipeMotion,    kCGGestureMotionHorizontal);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityX, vel);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityY, vel);
    if (augmented) {
        CGEventSetIntegerValueField(ev, (CGEventField)134, phase);
        CGEventSetDoubleValueField(ev, (CGEventField)125, 0.1);
        CGEventSetDoubleValueField(ev, (CGEventField)138, 3.0);
        CGEventSetDoubleValueField(ev, (CGEventField)169, (double)mach_absolute_time());
        CGEventRef result = strafe_augment(ev);
        CFRelease(ev);
        // Same macOS 27 source-data omission as above: re-stamp after rebuild.
        if (result) {
            CGEventSetIntegerValueField(result, kCGEventSourceUserData, kStrafeEventMarker);
            CGEventSetIntegerValueField(result, kCGEventSourceUnixProcessID, getpid());
        }
        return result;
    }
    return ev;
}

bool strafe_post_switch_gesture(StrafeDirection direction, double velocity) {
    // Legacy synchronous benchmark path. Prebuild to avoid partial allocation posts.
    CGEventRef events[3] = {NULL, NULL, NULL};
    const int64_t phases[] = {1, 2, 4};
    bool ready = true;
    for (size_t i = 0; i < 3; ++i) {
        events[i] = strafe_create_switch_event(direction, velocity, phases[i], false, false);
        if (!events[i]) ready = false;
    }
    for (size_t i = 0; i < 3; ++i) {
        if (ready) CGEventPost(kCGSessionEventTap, events[i]);
        if (events[i]) CFRelease(events[i]);
    }
    return ready;
}

// --- Topology (SPEC §6) ---------------------------------------------------
// Read the cursor display's UUID string.
static CFStringRef copy_cursor_display_identifier(void) {
    CGEventRef locEvent = CGEventCreate(NULL);
    if (!locEvent) { return NULL; }
    CGPoint loc = CGEventGetLocation(locEvent);
    CFRelease(locEvent);

    CGDirectDisplayID displays[16];
    uint32_t matching = 0;
    if (CGGetDisplaysWithPoint(loc, 16, displays, &matching) != kCGErrorSuccess || matching == 0) {
        return NULL;
    }
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(displays[0]);
    if (!uuid) { return NULL; }
    CFStringRef str = CFUUIDCreateString(NULL, uuid);
    CFRelease(uuid);
    return str; // caller releases
}

static bool strafe_has_type(CFTypeRef value, CFTypeID type) {
    return value && CFGetTypeID(value) == type;
}

static bool strafe_space_id(CFTypeRef dictionary, uint64_t *out) {
    if (!strafe_has_type(dictionary, CFDictionaryGetTypeID())) return false;
    CFNumberRef number = CFDictionaryGetValue(dictionary, CFSTR("id64"));
    int64_t value = 0;
    if (!strafe_has_type(number, CFNumberGetTypeID()) || CFNumberIsFloatType(number) ||
        !CFNumberGetValue(number, kCFNumberSInt64Type, &value) || value <= 0) return false;
    *out = (uint64_t)value;
    return true;
}

static bool strafe_extract_space_info(CFTypeRef display, StrafeInfo *outInfo) {
    if (!strafe_has_type(display, CFDictionaryGetTypeID())) return false;
    CFStringRef ident = CFDictionaryGetValue(display, CFSTR("Display Identifier"));
    CFArrayRef spaces = CFDictionaryGetValue(display, CFSTR("Spaces"));
    uint64_t current;
    if (!strafe_has_type(ident, CFStringGetTypeID()) || CFStringGetLength(ident) == 0 ||
        !strafe_has_type(spaces, CFArrayGetTypeID()) ||
        !strafe_space_id(CFDictionaryGetValue(display, CFSTR("Current Space")), &current)) return false;
    CFIndex count = CFArrayGetCount(spaces);
    if (count <= 0 || (uint64_t)count > UINT_MAX) return false;
    StrafeInfo result = {0};
    if (!CFStringGetCString(ident, result.displayID, sizeof(result.displayID), kCFStringEncodingUTF8)) return false;
    bool found = false;
    for (CFIndex i = 0; i < count; ++i) {
        uint64_t sid;
        if (!strafe_space_id(CFArrayGetValueAtIndex(spaces, i), &sid)) return false;
        if (sid == current) {
            if (found) return false;
            result.currentIndex = (unsigned int)i;
            found = true;
        }
    }
    if (!found) return false;
    result.currentSpaceID = current;
    result.spaceCount = (unsigned int)count;
    *outInfo = result;
    return true;
}

bool strafe_get_space_info(StrafeInfo *outInfo) {
    return strafe_get_space_info_for_display(NULL, outInfo);
}

bool strafe_get_space_info_for_display(const char *displayID, StrafeInfo *outInfo) {
    if (!outInfo) { return false; }
    // Copy before clearing output: displayID may point into outInfo->displayID.
    CFStringRef targetDisplay = displayID
        ? CFStringCreateWithCString(NULL, displayID, kCFStringEncodingUTF8) : NULL;
    memset(outInfo, 0, sizeof(*outInfo));
    if (!strafe_cgs_available()) {
        if (targetDisplay) CFRelease(targetDisplay);
        return false;
    }
    CGSConnectionID conn = CGSMainConnectionID();
    if (!displayID) targetDisplay = copy_cursor_display_identifier();
    // Fall back to the menu-bar display identifier if cursor lookup failed.
    if (!displayID && !targetDisplay && (&CGSCopyActiveMenuBarDisplayIdentifier != NULL)) {
        targetDisplay = CGSCopyActiveMenuBarDisplayIdentifier(conn);
    }
    if (!strafe_has_type(targetDisplay, CFStringGetTypeID()) || CFStringGetLength(targetDisplay) == 0) {
        if (targetDisplay) CFRelease(targetDisplay);
        return false;
    }

    CFArrayRef displaySpaces = CGSCopyManagedDisplaySpaces(conn, NULL);
    if (!strafe_has_type(displaySpaces, CFArrayGetTypeID())) {
        if (targetDisplay) { CFRelease(targetDisplay); }
        if (displaySpaces) CFRelease(displaySpaces);
        return false;
    }

    CFIndex displayCount = CFArrayGetCount(displaySpaces);
    if (displayCount == 0) {
        if (targetDisplay) { CFRelease(targetDisplay); }
        CFRelease(displaySpaces);
        return false;
    }

    // Exact display identity is required, including subsequent verification reads.
    CFDictionaryRef displayDict = NULL;
    if (targetDisplay) {
        for (CFIndex d = 0; d < displayCount; d++) {
            CFDictionaryRef candidate = (CFDictionaryRef)CFArrayGetValueAtIndex(displaySpaces, d);
            if (!strafe_has_type(candidate, CFDictionaryGetTypeID())) { continue; }
            CFStringRef ident = (CFStringRef)CFDictionaryGetValue(candidate, CFSTR("Display Identifier"));
            if (strafe_has_type(ident, CFStringGetTypeID()) && CFEqual(ident, targetDisplay)) {
                displayDict = candidate;
                break;
            }
        }
    }
    bool found = strafe_extract_space_info(displayDict, outInfo);

    if (targetDisplay) { CFRelease(targetDisplay); }
    CFRelease(displaySpaces);
    return found;
}

// --- Event inspection helpers (SPEC §2.2, §2.3) ---------------------------
bool strafe_event_is_strafe(CGEventRef event) {
    return event && CGEventGetIntegerValueField(event, kCGEventSourceUserData) == kStrafeEventMarker;
}
double strafe_event_generic_progress(CGEventRef event) {
    return event ? CGEventGetDoubleValueField(event, (CGEventField)119) : 0;
}
int64_t strafe_cgs_event_fluid_touch(void) { return kCGSEventFluidTouchGesture; }
int64_t strafe_iohid_event_generic_swipe(void) { return 32; }
int64_t strafe_event_cgs_type(CGEventRef event) {
    return CGEventGetIntegerValueField(event, kCGSEventTypeField);
}
int64_t strafe_event_hid_type(CGEventRef event) {
    return CGEventGetIntegerValueField(event, kCGEventGestureHIDType);
}
int64_t strafe_event_swipe_motion(CGEventRef event) {
    return CGEventGetIntegerValueField(event, kCGEventGestureSwipeMotion);
}
int64_t strafe_event_gesture_phase(CGEventRef event) {
    return CGEventGetIntegerValueField(event, kCGEventGesturePhase);
}
double strafe_event_swipe_progress(CGEventRef event) {
    return CGEventGetDoubleValueField(event, kCGEventGestureSwipeProgress);
}
double strafe_event_swipe_velocity_x(CGEventRef event) {
    return CGEventGetDoubleValueField(event, kCGEventGestureSwipeVelocityX);
}
int64_t strafe_event_source_pid(CGEventRef event) {
    return CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
}

// --- Constants (SPEC §1.3) ------------------------------------------------
int64_t strafe_cgs_event_dock_control(void)    { return kCGSEventDockControl; }
int64_t strafe_cgs_event_gesture(void)         { return kCGSEventGesture; }
int64_t strafe_iohid_event_dock_swipe(void)    { return kIOHIDEventTypeDockSwipe; }
int64_t strafe_gesture_motion_horizontal(void) { return kCGGestureMotionHorizontal; }
int64_t strafe_gesture_phase_began(void)       { return kCGSGesturePhaseBegan; }
int64_t strafe_gesture_phase_changed(void)     { return kCGSGesturePhaseChanged; }
int64_t strafe_gesture_phase_ended(void)       { return kCGSGesturePhaseEnded; }
int64_t strafe_gesture_phase_cancelled(void)   { return kCGSGesturePhaseCancelled; }

// --- Private CGEventField indices (SPEC §1.2) -----------------------------
// Value accessors so an out-of-tree caller can build a custom-shaped dock-swipe
// event without re-hardcoding these numbers. No behavior change: the app never
// calls these, and they post nothing. The field indices stay single-sourced in
// the static consts at the top of this file.
int32_t strafe_field_cgs_event_type(void)   { return (int32_t)kCGSEventTypeField; }
int32_t strafe_field_hid_type(void)         { return (int32_t)kCGEventGestureHIDType; }
int32_t strafe_field_swipe_motion(void)     { return (int32_t)kCGEventGestureSwipeMotion; }
int32_t strafe_field_swipe_progress(void)   { return (int32_t)kCGEventGestureSwipeProgress; }
int32_t strafe_field_swipe_velocity_x(void) { return (int32_t)kCGEventGestureSwipeVelocityX; }
int32_t strafe_field_swipe_velocity_y(void) { return (int32_t)kCGEventGestureSwipeVelocityY; }
int32_t strafe_field_gesture_phase(void)    { return (int32_t)kCGEventGesturePhase; }

// Raw tap mask: gesture29, dock-control30 and fluid-touch31.
//
// KEY-EVENTS-IN-MASK DETERMINATION (see docs/SPEC.md §2.1):
// The upstream reference (and this file's earlier revision) also OR'd in
// keyDown|keyUp. That was NOT required for correct interception and has been
// removed. Evidence:
//   - The interceptor state machine (SwipeInterceptor.handle) is driven ENTIRELY
//     by dock-control gesture phases (field 132) on CGSEventType 29/30. Nothing
//     in the callback ever inspects a key event: a keyDown/keyUp fails the
//     `cgsType == dockControl || cgsType == gesture` guard on field 55 and is
//     passed straight through, unused. There is no Exposé-via-keys handling, no
//     prediction reset on keys, and no key-driven tap re-enable.
//   - Tap re-enable is handled via the kCGEventTapDisabledByTimeout /
//     ByUserInput callbacks, which the system delivers to the callback
//     REGARDLESS of the event mask — so dropping keys does not affect re-enable.
//   - Global switch hotkeys use Carbon RegisterEventHotKey (HotkeyManager), a
//     separate mechanism that does not depend on this tap seeing key events.
// Cost of the old mask: every keystroke system-wide round-tripped synchronously
// through this process's active tap only to be passed through, adding keyboard
// latency and a wakeup per key. With keys removed the active tap wakes only on
// real space-swipe gestures, dropping idle keyboard wakeups to zero. Behavior is
// unchanged because the removed events were never acted upon.
uint64_t strafe_tap_event_mask(void) {
    return (1ULL << kCGSEventGesture) | (1ULL << kCGSEventDockControl)
        | (1ULL << kCGSEventFluidTouchGesture);
}

// --- Overlay / Exposé detection (SPEC §2.5) -------------------------------
// Heuristic: count Dock-owned windows at layers 18 and 20. Counts are exposed
// separately so the mc-probe diagnostic can report what a given macOS version
// actually shows while an overlay is open.
void strafe_expose_counts(int *dockWindows, int *layer18, int *layer20) {
    if (dockWindows) *dockWindows = 0;
    if (layer18) *layer18 = 0;
    if (layer20) *layer20 = 0;
    CFArrayRef windows = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!windows) { return; }

    CFIndex count = CFArrayGetCount(windows);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef win = (CFDictionaryRef)CFArrayGetValueAtIndex(windows, i);
        if (!win) { continue; }

        CFStringRef owner = (CFStringRef)CFDictionaryGetValue(win, kCGWindowOwnerName);
        if (!owner || CFStringCompare(owner, CFSTR("Dock"), 0) != kCFCompareEqualTo) {
            continue;
        }
        if (dockWindows) *dockWindows += 1;
        CFNumberRef layerNum = (CFNumberRef)CFDictionaryGetValue(win, kCGWindowLayer);
        if (!layerNum) { continue; }
        int layer = 0;
        CFNumberGetValue(layerNum, kCFNumberIntType, &layer);
        if (layer == 18) { if (layer18) *layer18 += 1; }
        else if (layer == 20) { if (layer20) *layer20 += 1; }
    }
    CFRelease(windows);
}

bool strafe_is_expose_active(void) {
    int layer18Count = 0, layer20Count = 0;
    strafe_expose_counts(NULL, &layer18Count, &layer20Count);

    // App Exposé: layer18Count > 0 && layer20Count > 0 && layer20Count <= layer18Count.
    // Mission Control: layer18Count > 0 && layer20Count > layer18Count.
    if (layer18Count > 0 && layer20Count > 0 && layer20Count <= layer18Count) { return true; }
    if (layer18Count > 0 && layer20Count > layer18Count) { return true; }
    // macOS 27 (mc-probe): Mission Control shows a single Dock window at
    // layer 20 with none at layer 18 (closed desktop shows no Dock windows at
    // all under ExcludeDesktopElements), and Dock's AX overlay notifications
    // no longer arrive — so a lone layer-20 window is the MC signal there. A
    // Dock-owned layer-20 window is overlay chrome on older systems too, and
    // the failure mode here is fail-safe: a false positive only passes one
    // gesture through natively.
    if (layer20Count > 0) { return true; }
    return false;
}
