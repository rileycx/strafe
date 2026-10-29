// CStrafe.c — implementation of the synthetic dock-swipe mechanism.
//
// An independent reimplementation of the technique from
// jurplel/InstantSpaceSwitcher (MIT). Every magic number here is documented in
// docs/SPEC.md §1–2. Treat the field indices and event-type values as
// version-fragile (SPEC §7).

#include "CStrafe.h"
#include "IOHIDPayload.h"

#include <ApplicationServices/ApplicationServices.h>
#include <CoreGraphics/CGEventTypes.h>
#include <CoreFoundation/CoreFoundation.h>
#include <float.h>
#include <string.h>

// --- Private CGEventField indices (SPEC §1.2) -----------------------------
static const CGEventField kCGSEventTypeField           = (CGEventField)55;   // private CGSEventType selector
static const CGEventField kCGEventGestureHIDType       = (CGEventField)110;  // IOHIDEvent gesture type
static const CGEventField kCGEventGestureSwipeMotion   = (CGEventField)123;  // motion axis (horizontal=1)
static const CGEventField kCGEventGestureSwipeProgress = (CGEventField)124;  // gesture progress (double)
static const CGEventField kCGEventGestureSwipeVelocityX= (CGEventField)129;  // (double)
static const CGEventField kCGEventGestureSwipeVelocityY= (CGEventField)130;  // (double)
static const CGEventField kCGEventGesturePhase         = (CGEventField)132;  // CGSGesturePhase
static const CGEventField kCGEventGestureSwipePositionX = (CGEventField)125;
static const CGEventField kCGEventGesturePhaseAlias     = (CGEventField)134;
static const CGEventField kCGEventGestureZoomDeltaY     = (CGEventField)138;

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

// --- Native Space shortcuts (symbolic hotkeys 79/81) -----------------------
// Weak-imported private WindowServer calls. They flip the *live* enabled flag
// only; the com.apple.symbolichotkeys preference file is never touched.
extern CGError CGSSetSymbolicHotKeyEnabled(int32_t hotKey, bool enabled) __attribute__((weak_import));

static const int32_t kSymbolicHotKeyMoveLeftASpace  = 79;
static const int32_t kSymbolicHotKeyMoveRightASpace = 81;

bool strafe_set_space_arrow_shortcuts_enabled(bool enabled) {
    if (&CGSSetSymbolicHotKeyEnabled == NULL) { return false; }
    CGError left  = CGSSetSymbolicHotKeyEnabled(kSymbolicHotKeyMoveLeftASpace, enabled);
    CGError right = CGSSetSymbolicHotKeyEnabled(kSymbolicHotKeyMoveRightASpace, enabled);
    return left == kCGErrorSuccess && right == kCGErrorSuccess;
}

// --- Synthesis (SPEC §1.5) ------------------------------------------------
bool strafe_uses_iohid_payload(void) {
    if (__builtin_available(macOS 27.0, *)) { return true; }
    return false;
}

// Whether "Natural scrolling" is on (System Settings > Trackpad > Scroll &
// Zoom). An absent key means the macOS default, which is on. Read at post time,
// not cached, so toggling the setting takes effect without relaunching.
static bool natural_scrolling_enabled(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(
        CFSTR("com.apple.swipescrolldirection"), kCFPreferencesAnyApplication);
    if (!value) { return true; }
    bool enabled = true;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        enabled = CFBooleanGetValue((CFBooleanRef)value);
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int number = 1;
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number);
        enabled = number != 0;
    }
    CFRelease(value);
    return enabled;
}

// MEASURED on macOS 27.0 (26A428), one display: the Dock reads a POSTED
// gesture's direction in the Natural-scrolling orientation, so the posted sign
// must be reversed only when Natural scrolling is on. An INCOMING real gesture's
// sign does not depend on the setting (see strafe_event_moves_right). Coupling
// both to one macOS 27 flag reversed swipes with Natural scrolling on and
// inverted the first/last-Space guard with it off (issue #10).
bool strafe_posted_sign_reversed(void) {
    return strafe_uses_iohid_payload() && natural_scrolling_enabled();
}

// One phase of a horizontal dock swipe, with progress and velocity supplied by
// the caller. Every field the WindowServer reads is set here; the two callers
// below differ only in the numbers they hand it.
static bool post_dock_swipe_shaped(CGSGesturePhase phase, double progress, double velocity) {
    const bool augmented = strafe_uses_iohid_payload();
    // Keep the caller-facing sign stable: positive means the Space on the right.
    if (strafe_posted_sign_reversed()) { progress = -progress; velocity = -velocity; }
    CGEventRef ev = CGEventCreate(NULL);
    if (!ev) { return false; }
    CGEventSetIntegerValueField(ev, kCGSEventTypeField,            kCGSEventDockControl);
    CGEventSetIntegerValueField(ev, kCGEventGestureHIDType,        kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(ev, kCGEventGesturePhase,          phase);
    CGEventSetDoubleValueField (ev, kCGEventGestureSwipeProgress,  progress);
    CGEventSetIntegerValueField(ev, kCGEventGestureSwipeMotion,    kCGGestureMotionHorizontal);
    CGEventSetDoubleValueField (ev, kCGEventGestureSwipeVelocityX, velocity);
    CGEventSetDoubleValueField (ev, kCGEventGestureSwipeVelocityY, augmented ? 0 : velocity);
    CGEventRef companion = NULL;
    if (augmented) {
        CGEventSetIntegerValueField(ev, kCGEventGesturePhaseAlias, phase);
        CGEventSetDoubleValueField(ev, kCGEventGestureZoomDeltaY, 3.0);
        CGEventSetDoubleValueField(ev, kCGEventGestureSwipePositionX, 0.1);
        CGEventRef replacement = strafe_create_augmented_event(ev);
        CFRelease(ev);
        if (!replacement) { return false; }
        ev = replacement;
        companion = CGEventCreate(NULL);
        if (!companion) { CFRelease(ev); return false; }
        CGEventSetIntegerValueField(companion, kCGSEventTypeField, kCGSEventGesture);
    }
    CGEventPost(kCGSessionEventTap, ev);
    if (companion) {
        CGEventPost(kCGSessionEventTap, companion);
        CFRelease(companion);
    }
    CFRelease(ev);
    return true;
}

static bool post_dock_swipe(CGSGesturePhase phase, StrafeDirection direction, double velocity) {
    const bool isRight = (direction == StrafeDirectionRight);
    // Keep travel visually negligible. Full travel (1.0) switches on macOS 27
    // but can still animate a slide. 1e-4 also survives conversion
    // to the IOHID payload's signed 16.16 value without losing direction.
    const bool augmented = strafe_uses_iohid_payload();
    const double magnitude = augmented ? 1e-4 : (double)FLT_TRUE_MIN;
    const double progress = isRight ? magnitude : -magnitude;

    // Velocity of gesture based on speed setting.
    const double vel = augmented && phase != kCGSGesturePhaseEnded
        ? 0.0 : (isRight ? velocity : -velocity);

    return post_dock_swipe_shaped(phase, progress, vel);
}

bool strafe_post_switch_gesture(StrafeDirection direction, double velocity) {
    // Send three gesture events--began, changed, and ended.
    // If we only send two then mission control doesn't work.
    return post_dock_swipe(kCGSGesturePhaseBegan,   direction, velocity)
        && post_dock_swipe(kCGSGesturePhaseChanged, direction, velocity)
        && post_dock_swipe(kCGSGesturePhaseEnded,   direction, velocity);
}

// One phase with caller-chosen progress and velocity, for the animated
// Transition speed presets (SPEC §1.4). A began, then a `changed` stream whose
// progress climbs, then an ended is what makes the WindowServer run its slide
// instead of flicking. The instant preset does not use this — it still goes
// through `strafe_post_switch_gesture` above, unchanged.
bool strafe_post_dock_swipe_phase(int64_t phase, double progress, double velocity) {
    return post_dock_swipe_shaped((CGSGesturePhase)phase, progress, velocity);
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

bool strafe_get_space_info(StrafeInfo *outInfo) {
    if (!outInfo) { return false; }
    if (!strafe_cgs_available()) { return false; }

    memset(outInfo, 0, sizeof(*outInfo));

    CGSConnectionID conn = CGSMainConnectionID();

    CFStringRef targetDisplay = copy_cursor_display_identifier();
    // Fall back to the menu-bar display identifier if cursor lookup failed.
    if (!targetDisplay && (&CGSCopyActiveMenuBarDisplayIdentifier != NULL)) {
        targetDisplay = CGSCopyActiveMenuBarDisplayIdentifier(conn);
    }

    CFArrayRef displaySpaces = CGSCopyManagedDisplaySpaces(conn, NULL);
    if (!displaySpaces) {
        if (targetDisplay) { CFRelease(targetDisplay); }
        return false;
    }

    CFIndex displayCount = CFArrayGetCount(displaySpaces);
    if (displayCount == 0) {
        if (targetDisplay) { CFRelease(targetDisplay); }
        CFRelease(displaySpaces);
        return false;
    }

    // Pick the matching display dict; if the target isn't found, fall back to
    // the first display in the list (SPEC §6).
    CFDictionaryRef displayDict = NULL;
    if (targetDisplay) {
        for (CFIndex d = 0; d < displayCount; d++) {
            CFDictionaryRef candidate = (CFDictionaryRef)CFArrayGetValueAtIndex(displaySpaces, d);
            if (!candidate) { continue; }
            CFStringRef ident = (CFStringRef)CFDictionaryGetValue(candidate, CFSTR("Display Identifier"));
            if (ident && CFStringCompare(ident, targetDisplay, 0) == kCFCompareEqualTo) {
                displayDict = candidate;
                break;
            }
        }
    }
    if (!displayDict) {
        displayDict = (CFDictionaryRef)CFArrayGetValueAtIndex(displaySpaces, 0);
    }

    bool found = false;
    if (displayDict) {
        CFStringRef displayIdentifier = (CFStringRef)CFDictionaryGetValue(displayDict, CFSTR("Display Identifier"));

        CFArrayRef spaces = (CFArrayRef)CFDictionaryGetValue(displayDict, CFSTR("Spaces"));
        if (spaces) {
            CFIndex count = CFArrayGetCount(spaces);
            outInfo->spaceCount = (unsigned int)count;

            // Determine the current space id for this display.
            CGSSpaceID currentSpaceID = 0;
            CFDictionaryRef currentSpace = (CFDictionaryRef)CFDictionaryGetValue(displayDict, CFSTR("Current Space"));
            if (currentSpace) {
                CFNumberRef id64 = (CFNumberRef)CFDictionaryGetValue(currentSpace, CFSTR("id64"));
                if (id64) { CFNumberGetValue(id64, kCFNumberSInt64Type, &currentSpaceID); }
            }
            if (currentSpaceID == 0) {
                currentSpaceID = CGSGetActiveSpace(conn);
            }

            // Map the current space id to a zero-based index within this display.
            outInfo->currentIndex = 0;
            for (CFIndex s = 0; s < count; s++) {
                CFDictionaryRef spaceDict = (CFDictionaryRef)CFArrayGetValueAtIndex(spaces, s);
                if (!spaceDict) { continue; }
                CFNumberRef idNum = (CFNumberRef)CFDictionaryGetValue(spaceDict, CFSTR("id64"));
                CGSSpaceID sid = 0;
                if (idNum) { CFNumberGetValue(idNum, kCFNumberSInt64Type, &sid); }
                if (sid == currentSpaceID) {
                    outInfo->currentIndex = (unsigned int)s;
                    break;
                }
            }

            if (displayIdentifier) {
                CFStringGetCString(displayIdentifier, outInfo->displayID, sizeof(outInfo->displayID), kCFStringEncodingUTF8);
            }
            found = true;
        }
    }

    if (targetDisplay) { CFRelease(targetDisplay); }
    CFRelease(displaySpaces);
    return found;
}

// --- Event inspection helpers (SPEC §2.2, §2.3) ---------------------------
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

// Direction of a REAL (pid 0) gesture from the sign of field 124/129: positive
// means the Space on the right, on every macOS version and with Natural
// scrolling on or off (measured on macOS 27.0, 26A428, both settings).
bool strafe_event_moves_right(double progressOrVelocity) {
    return progressOrVelocity > 0;
}

void strafe_clear_swipe_motion(CGEventRef event) {
    CGEventSetDoubleValueField(event, kCGEventGestureSwipeProgress, 0);
    CGEventSetDoubleValueField(event, kCGEventGestureSwipeVelocityX, 0);
    CGEventSetDoubleValueField(event, kCGEventGestureSwipeVelocityY, 0);
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

// Raw tap mask: (1<<29) gesture | (1<<30) dock-control ONLY.
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
//   - Optional Control-arrow switching uses ControlArrowInterceptor, a
//     separate flagsChanged-only tap plus Carbon hotkeys. It does not widen
//     this gesture-only mask and never receives key-down/up events.
// Cost of the old mask: every keystroke system-wide round-tripped synchronously
// through this process's active tap only to be passed through, adding keyboard
// latency and a wakeup per key. With keys removed the active tap wakes only on
// real space-swipe gestures. The separate toggleable modifier tap only wakes on
// modifier changes. Gesture behavior is unchanged because the
// removed events were never acted upon by this tap.
uint64_t strafe_tap_event_mask(void) {
    return (1ULL << kCGSEventGesture) | (1ULL << kCGSEventDockControl);
}

// --- Overlay / Exposé detection (SPEC §2.5) -------------------------------
// Heuristic: count Dock-owned windows at layers 18 and 20.
bool strafe_is_expose_active(void) {
    CFArrayRef windows = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!windows) { return false; }

    int layer18Count = 0;
    int layer20Count = 0;
    CFIndex count = CFArrayGetCount(windows);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef win = (CFDictionaryRef)CFArrayGetValueAtIndex(windows, i);
        if (!win) { continue; }

        CFStringRef owner = (CFStringRef)CFDictionaryGetValue(win, kCGWindowOwnerName);
        if (!owner || CFStringCompare(owner, CFSTR("Dock"), 0) != kCFCompareEqualTo) {
            continue;
        }
        CFNumberRef layerNum = (CFNumberRef)CFDictionaryGetValue(win, kCGWindowLayer);
        if (!layerNum) { continue; }
        int layer = 0;
        CFNumberGetValue(layerNum, kCFNumberIntType, &layer);
        if (layer == 18) { layer18Count++; }
        else if (layer == 20) { layer20Count++; }
    }
    CFRelease(windows);

    // App Exposé: layer18Count > 0 && layer20Count > 0 && layer20Count <= layer18Count.
    // Mission Control: layer18Count > 0 && layer20Count > layer18Count.
    if (layer18Count > 0 && layer20Count > 0 && layer20Count <= layer18Count) { return true; }
    if (layer18Count > 0 && layer20Count > layer18Count) { return true; }
    // macOS 27 Mission Control can show a lone Dock window at layer 20.
    // Earlier systems retain the existing layer-18 requirement.
    if (__builtin_available(macOS 27.0, *)) {
        if (layer20Count > 0) { return true; }
    }
    return false;
}
