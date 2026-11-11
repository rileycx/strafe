#include "IOHIDPayload.h"
#include "CStrafe.h"
#include <assert.h>
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static CGEventRef postedEvents[6];
static unsigned postedCount;
static CFArrayRef overlayWindows;

// Supply window metadata so overlay tests do not depend on the live desktop.
CFArrayRef CGWindowListCopyWindowInfo(CGWindowListOption options, CGWindowID relativeToWindow) {
    assert(options == (kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements));
    assert(relativeToWindow == kCGNullWindowID);
    return overlayWindows ? (CFArrayRef)CFRetain(overlayWindows) : NULL;
}

static void check_overlay(CFStringRef owner, const int *layers, size_t count, bool expected) {
    CFMutableArrayRef windows = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    assert(windows);
    for (size_t i = 0; i < count; i++) {
        CFNumberRef layer = CFNumberCreate(NULL, kCFNumberIntType, &layers[i]);
        const void *keys[] = {kCGWindowOwnerName, kCGWindowLayer};
        const void *values[] = {owner, layer};
        CFDictionaryRef window = CFDictionaryCreate(NULL, keys, values, 2,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFArrayAppendValue(windows, window);
        CFRelease(window);
        CFRelease(layer);
    }
    overlayWindows = windows;
    assert(strafe_is_expose_active() == expected);
    overlayWindows = NULL;
    CFRelease(windows);
}

static void check_overlay_detection(void) {
    assert(!strafe_is_expose_active()); // Window enumeration unavailable.
    check_overlay(CFSTR("Dock"), NULL, 0, false);
    check_overlay(CFSTR("Dock"), (int[]){18}, 1, false);
    check_overlay(CFSTR("Dock"), (int[]){18, 18, 20}, 3, true);
    check_overlay(CFSTR("Dock"), (int[]){18, 20, 20}, 3, true);
    check_overlay(CFSTR("Finder"), (int[]){18, 20}, 2, false);
    check_overlay(CFSTR("Finder"), (int[]){20}, 1, false);
    check_overlay(CFSTR("Dock"), (int[]){0, 19, 21}, 3, false);
    bool modern = false;
    if (__builtin_available(macOS 27.0, *)) { modern = true; }
    check_overlay(CFSTR("Dock"), (int[]){20}, 1, modern);
}

// Override the framework entry point in this test executable. Exercise the
// real synthesizer without sending input to the user's desktop.
void CGEventPost(CGEventTapLocation location, CGEventRef event) {
    assert(location == kCGSessionEventTap);
    assert(postedCount < 6);
    postedEvents[postedCount++] = (CGEventRef)CFRetain(event);
}

static void check_instant_switch(StrafeDirection direction) {
    postedCount = 0;
    assert(strafe_post_switch_gesture(direction, 2000));
    bool augmented = strafe_uses_iohid_payload();
    assert(postedCount == (augmented ? 6 : 3));
    const int phases[] = {1, 2, 4};
    double sign = direction == StrafeDirectionRight ? 1 : -1;
    if (strafe_posted_sign_reversed()) sign = -sign;
    for (unsigned i = 0; i < 3; i++) {
        CGEventRef event = postedEvents[i * (augmented ? 2 : 1)];
        assert(CGEventGetType(event) == 30);
        assert(CGEventGetIntegerValueField(event, 132) == phases[i]);
        double progress = CGEventGetDoubleValueField(event, 124);
        assert(progress * sign > 0);
        assert(fabs(progress) <= 1e-4);
        if (augmented) {
            assert(CGEventGetDoubleValueField(event, 129) == (i == 2 ? sign * 2000 : 0));
            assert(CGEventGetType(postedEvents[i * 2 + 1]) == 29);
        }
    }
    for (unsigned i = 0; i < postedCount; i++) CFRelease(postedEvents[i]);
}

static uint32_t read32(const uint8_t *bytes) {
    uint32_t value;
    memcpy(&value, bytes, sizeof(value));
    return value;
}

// Parse the reserialized event to check that CoreGraphics accepted the payload,
// including its packed record offsets. No event is posted by these tests.
static void check_payload(int phase, double progress, double velocity,
                          int32_t expectedProgress, int32_t expectedVelocity) {
    CGEventRef event = CGEventCreate(NULL);
    assert(event);
    CGEventSetType(event, (CGEventType)30);
    CGEventSetIntegerValueField(event, 110, 23);
    CGEventSetIntegerValueField(event, 123, 1);
    CGEventSetIntegerValueField(event, 132, phase);
    CGEventSetDoubleValueField(event, 124, progress);
    CGEventSetDoubleValueField(event, 129, velocity);
    CGEventRef augmented = strafe_create_augmented_event(event);
    CFRelease(event);
    assert(augmented);
    assert(CGEventGetType(augmented) == 30);
    assert(CGEventGetIntegerValueField(augmented, 132) == phase);
    CFDataRef data = CGEventCreateData(NULL, augmented);
    assert(data);
    const uint8_t *bytes = CFDataGetBytePtr(data);
    size_t length = (size_t)CFDataGetLength(data);
    bool found = false;
    for (size_t offset = 4; offset + 4 <= length; offset++) {
        size_t size = ((size_t)bytes[offset] << 8) | bytes[offset + 1];
        unsigned field = ((unsigned)bytes[offset + 2] << 8) | bytes[offset + 3];
        if (field == 4205 && (size == 68 || size == 96)) {
            assert(offset + 4 + size <= length);
            const uint8_t *payload = bytes + offset + 4;
            bool hasVelocity = velocity != 0 || phase == 4;
            assert(size == (hasVelocity ? 96 : 68));
            assert(read32(payload + 24) == (hasVelocity ? 2 : 1));
            assert(read32(payload + 28) == 40);
            assert(read32(payload + 32) == 23);
            assert(read32(payload + 36) == (uint32_t)phase << 24);
            assert(payload[60] == 1 && payload[62] == 3);
            assert((int32_t)read32(payload + 64) == expectedProgress);
            if (hasVelocity) {
                assert(read32(payload + 68) == 28);
                assert(read32(payload + 72) == 9);
                assert(payload[80] == 1);
                assert((int32_t)read32(payload + 84) == expectedVelocity);
            }
            found = true;
        }
    }
    assert(found);
    CFRelease(data);
    CFRelease(augmented);
}

// Locate the field-4205 payload in a serialized event; returns its size or 0.
static size_t find_payload(CGEventRef event, uint8_t *copy, size_t capacity) {
    CFDataRef data = CGEventCreateData(NULL, event);
    assert(data);
    const uint8_t *bytes = CFDataGetBytePtr(data);
    size_t length = (size_t)CFDataGetLength(data);
    size_t found = 0;
    for (size_t offset = 4; offset + 4 <= length && !found; offset++) {
        size_t size = ((size_t)bytes[offset] << 8) | bytes[offset + 1];
        unsigned field = ((unsigned)bytes[offset + 2] << 8) | bytes[offset + 3];
        if (field == 4205 && (size == 68 || size == 96) && offset + 4 + size <= length) {
            assert(size <= capacity);
            memcpy(copy, bytes + offset + 4, size);
            found = size;
        }
    }
    CFRelease(data);
    return found;
}

static CGEventRef real_like_event(int phase, double progress, double velocity) {
    CGEventRef event = CGEventCreate(NULL);
    assert(event);
    CGEventSetType(event, (CGEventType)30);
    CGEventSetIntegerValueField(event, 110, 23);
    CGEventSetIntegerValueField(event, 123, 1);
    CGEventSetIntegerValueField(event, 132, phase);
    CGEventSetDoubleValueField(event, 124, progress);
    CGEventSetDoubleValueField(event, 129, velocity);
    CGEventRef augmented = strafe_create_augmented_event(event);
    CFRelease(event);
    assert(augmented);
    return augmented;
}

// Follow-finger: the release velocity is replaced inside the payload (in the
// payload's own orientation), an absent velocity child is added, and
// everything else is left as it was.
static void check_release_patch(void) {
    uint8_t before[96], after[96];
    int32_t sign = strafe_posted_sign_reversed() ? -1 : 1;

    CGEventRef ended = real_like_event(4, 0.4, 3);
    assert(find_payload(ended, before, sizeof(before)) == 96);
    CGEventRef patched = strafe_copy_with_release_velocity(ended, 130);
    assert(patched && patched != ended);
    assert(find_payload(patched, after, sizeof(after)) == 96);
    assert((int32_t)read32(after + 84) == sign * 130 * 65536);
    assert(memcmp(before, after, 84) == 0);
    assert(CGEventGetIntegerValueField(patched, 132) == 4);
    assert(CGEventGetDoubleValueField(patched, 129) == 130);
    assert(CGEventGetDoubleValueField(ended, 129) == 3);
    CFRelease(patched);
    CFRelease(ended);

    CGEventRef bare = real_like_event(2, -0.3, 0);
    assert(find_payload(bare, before, sizeof(before)) == 68);
    patched = strafe_copy_with_release_velocity(bare, -130);
    assert(patched && find_payload(patched, after, sizeof(after)) == 96);
    assert(read32(after + 24) == 2);
    assert(memcmp(before + 28, after + 28, 40) == 0);
    assert(read32(after + 68) == 28 && read32(after + 72) == 9 && after[80] == 1);
    assert((int32_t)read32(after + 84) == sign * -130 * 65536);
    CFRelease(patched);
    CFRelease(bare);

    // Before macOS 27 there is no payload; the field alone carries it.
    CGEventRef plain = CGEventCreate(NULL);
    CGEventSetType(plain, (CGEventType)30);
    patched = strafe_copy_with_release_velocity(plain, 130);
    assert(patched && find_payload(patched, after, sizeof(after)) == 0);
    assert(CGEventGetDoubleValueField(patched, 129) == 130);
    CFRelease(patched);
    CFRelease(plain);
    assert(strafe_copy_with_release_velocity(NULL, 130) == NULL);
}

int main(void) {
    assert(strafe_create_augmented_event(NULL) == NULL);
    check_payload(1, -1, 0, -65536, 0);
    check_payload(2, 0.35, 130, (int32_t)(0.35 * 65536), 130 * 65536);
    check_payload(4, -1, -2000, -65536, -2000 * 65536);
    check_payload(1, -1e-4, 0, -6, 0);
    check_payload(4, 1e-4, 2000, 6, 2000 * 65536);
    check_payload(4, 0, 0, 0, 0);
    check_payload(2, FLT_TRUE_MIN, 0, 1, 0);
    check_payload(2, -FLT_TRUE_MIN, 0, -1, 0);
    check_payload(4, INFINITY, 1e30, 0, INT32_MAX);
    check_payload(4, NAN, -1e30, 0, INT32_MIN);
    assert(strafe_event_moves_right(1));
    assert(!strafe_event_moves_right(-1));
    assert(!strafe_event_moves_right(0));
    assert(strafe_tap_event_mask() == ((1ULL << 29) | (1ULL << 30)));
    check_instant_switch(StrafeDirectionRight);
    check_instant_switch(StrafeDirectionLeft);
    check_overlay_detection();
    check_release_patch();
    puts("IOHID payload, direction, and overlay tests passed (no events posted)");
}
