// Standalone, non-posting tests. Include implementation to exercise malformed
// wire data and topology fixtures without exposing test-only public API.
#include "../Sources/CStrafe/CStrafe.c"
#include <assert.h>
#include <stdio.h>

static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
        ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void check_payload(CFDataRef data, int phase, int sign) {
    const uint8_t *p = CFDataGetBytePtr(data);
    size_t length = (size_t)CFDataGetLength(data), hits = 0;
    for (size_t i = 4; i < length;) {
        assert(length - i >= 4);
        unsigned count = ((unsigned)p[i] << 8) | p[i + 1];
        unsigned header = ((unsigned)p[i + 2] << 8) | p[i + 3];
        unsigned tag = header >> 14;
        size_t size = tag == 0 ? (count == 1 ? 8 : count) : count * 4;
        assert(size <= length - i - 4);
        if ((header & 0x3fff) == 4205) {
            ++hits;
            assert(tag == 0 && size == (phase == 4 ? 96 : 68));
            const uint8_t *b = p + i + 4;
            assert(le32(b + 24) == (phase == 4 ? 2u : 1u));
            assert(le32(b + 28) == 40 && le32(b + 32) == 23);
            assert(le32(b + 36) == (uint32_t)phase << 24);
            assert(le32(b + 40) == 0 && le32(b + 44) == 6553);
            assert(le32(b + 48) == 0 && le32(b + 52) == 0 && le32(b + 56) == 0);
            assert(b[60] == 1 && b[61] == 0 && b[62] == 3 && b[63] == 0);
            assert((int32_t)le32(b + 64) == sign);
            if (phase == 4) {
                assert(le32(b + 68) == 28 && le32(b + 72) == 9);
                assert(le32(b + 76) == 0 && le32(b + 80) == 1);
                assert((int32_t)le32(b + 84) == sign * 2000 * 65536);
                assert(le32(b + 88) == 0 && le32(b + 92) == 0);
            }
        }
        i += size + 4;
    }
    assert(hits == 1);
}

static void events(void) {
    const int phases[] = {1, 2, 4, 8};
    for (int modern = 0; modern < 2; ++modern)
    for (int inverted = 0; inverted < 2; ++inverted)
    for (int dir = 0; dir < 2; ++dir)
    for (size_t i = 0; i < 4; ++i) {
        int phase = phases[i], sign = (dir != inverted) ? 1 : -1;
        CGEventRef event = strafe_create_switch_event((StrafeDirection)dir, 2000, phase, modern, inverted);
        assert(event && strafe_event_is_strafe(event));
        CFDataRef data = CGEventCreateData(NULL, event);
        assert(data);
        CGEventRef copy = CGEventCreateFromData(NULL, data);
        // Source user data is omitted by this host's CGEventCreateData; the
        // augmented builder must restore it after its internal round-trip.
        assert(copy);
        CGEventRef retainedCopy = CGEventCreateCopy(event);
        assert(retainedCopy && strafe_event_is_strafe(retainedCopy));
        CFRelease(retainedCopy);
        assert(strafe_event_source_pid(copy) == getpid());
        assert(strafe_event_cgs_type(copy) == 30 && strafe_event_hid_type(copy) == 23);
        assert(strafe_event_gesture_phase(copy) == phase && strafe_event_swipe_motion(copy) == 1);
        double progress = strafe_event_swipe_progress(copy);
        assert(sign * progress > 0);
        assert(fabs(progress - sign * (modern ? 0.000016 : FLT_TRUE_MIN)) < (modern ? 1e-10 : FLT_TRUE_MIN));
        assert(strafe_event_swipe_velocity_x(copy) == (modern && phase != 4 ? 0 : sign * 2000));
        assert(CGEventGetDoubleValueField(copy, (CGEventField)130) == (modern ? 0 : sign * 2000));
        if (modern) {
            assert(CGEventGetIntegerValueField(copy, (CGEventField)134) == phase);
            assert(fabs(CGEventGetDoubleValueField(copy, (CGEventField)125) - 0.1) < 1e-7);
            assert(CGEventGetDoubleValueField(copy, (CGEventField)138) == 3);
            assert(CGEventGetDoubleValueField(copy, (CGEventField)169) > 0);
            check_payload(data, phase, sign);
            CGEventRef again = strafe_augment(copy);
            assert(again);
            CFDataRef replaced = CGEventCreateData(NULL, again);
            check_payload(replaced, phase, sign);
            assert(CFDataGetLength(data) == CFDataGetLength(replaced));
            CFRelease(replaced);
            CFRelease(again);
        }
        CFRelease(copy);
        CFRelease(data);
        CFRelease(event);
    }
    CGEventRef plain = CGEventCreate(NULL);
    assert(plain && !strafe_event_is_strafe(plain) && !strafe_event_is_strafe(NULL));
    CGEventSetIntegerValueField(plain, (CGEventField)55, 29);
    CGEventSetIntegerValueField(plain, (CGEventField)110, 32);
    CGEventSetDoubleValueField(plain, (CGEventField)119, -0.25);
    assert(strafe_event_generic_progress(plain) == -0.25);
    CFRelease(plain);
    assert(strafe_tap_event_mask() == UINT64_C(0xe0000000));
    assert(strafe_cgs_event_fluid_touch() == 31 && strafe_iohid_event_generic_swipe() == 32);
}

static void invalid(void) {
    const double bad[] = {-1, NAN, INFINITY, -INFINITY, DBL_MAX};
    for (size_t i = 0; i < sizeof(bad) / sizeof(*bad); ++i)
        for (int modern = 0; modern < 2; ++modern)
            assert(!strafe_create_switch_event(StrafeDirectionRight, bad[i], 1, modern, false));
    assert(!strafe_create_switch_event((StrafeDirection)42, 2000, 1, false, false));
    assert(!strafe_create_switch_event(StrafeDirectionRight, 2000, 3, true, false));
    assert(!strafe_create_switch_event(StrafeDirectionRight, 32768, 1, true, false));
    int32_t fixed;
    assert(strafe_fixed(-32768, &fixed) && fixed == INT32_MIN);
    assert(strafe_fixed((double)INT32_MAX / 65536, &fixed) && fixed == INT32_MAX);
    assert(!strafe_fixed(32768, &fixed) && !strafe_fixed(NAN, &fixed));
    assert(strafe_fixed(-FLT_TRUE_MIN, &fixed) && fixed == -1);
    uint8_t payload[96] = {0};
    const uint8_t badWire[][12] = {
        {0,0,0,3},                         // unsupported version
        {0,0,0,2, 0,1,0x80,1},            // reserved tag
        {0,0,0,2, 0,0,0,1},               // zero blob size
        {0,0,0,2, 0,2,0x40,1},            // int32 size != 1
        {0,0,0,2, 0,3,0xc0,1},            // invalid floating size
        {0,0,0,2, 0,1,0,1},               // truncated int64
        {0,0,0,2, 0,1,0x50,0x6d,0,0,0,0} // 4205 is not a blob
    };
    for (size_t i = 0; i < sizeof(badWire) / sizeof(*badWire); ++i) {
        CFDataRef data = CFDataCreate(NULL, badWire[i], i == 6 ? 12 : 8);
        assert(!strafe_replace_payload(data, payload, 68));
        CFRelease(data);
    }
    const uint8_t duplicate[] = {0,0,0,2, 0,1,0x40,1,0,0,0,0, 0,1,0x40,1,0,0,0,0};
    CFDataRef data = CFDataCreate(NULL, duplicate, sizeof(duplicate));
    assert(!strafe_replace_payload(data, payload, 68));
    CFRelease(data);
    const uint8_t shortWire[] = {0,0,0,2,0,1,0x40,1,0,0,0,0};
    for (size_t n = 0; n < sizeof(shortWire); ++n) {
        if (n == 4) continue; // an empty v2 field list is valid
        data = CFDataCreate(NULL, shortWire, n);
        assert(!strafe_replace_payload(data, payload, 68));
        CFRelease(data);
    }
}

static CFDictionaryRef space(int64_t id) {
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt64Type, &id);
    const void *keys[] = {CFSTR("id64")}, *values[] = {number};
    CFDictionaryRef result = CFDictionaryCreate(NULL, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(number);
    return result;
}

static void topology(void) {
    CFDictionaryRef a = space(42), b = space(99), missing = space(123);
    const void *items[] = {a, b};
    CFArrayRef spaces = CFArrayCreate(NULL, items, 2, &kCFTypeArrayCallBacks);
    CFMutableDictionaryRef display = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(display, CFSTR("Display Identifier"), CFSTR("test-display"));
    CFDictionarySetValue(display, CFSTR("Spaces"), spaces);
    CFDictionarySetValue(display, CFSTR("Current Space"), b);
    StrafeInfo info = {0};
    assert(strafe_extract_space_info(display, &info));
    assert(info.currentIndex == 1 && info.currentSpaceID == 99 && info.spaceCount == 2);
    assert(!strcmp(info.displayID, "test-display"));
    CFDictionarySetValue(display, CFSTR("Current Space"), missing);
    assert(!strafe_extract_space_info(display, &info));
    CFDictionarySetValue(display, CFSTR("Current Space"), CFSTR("wrong type"));
    assert(!strafe_extract_space_info(display, &info));
    CFDictionarySetValue(display, CFSTR("Current Space"), b);
    CFDictionarySetValue(display, CFSTR("Spaces"), b);
    assert(!strafe_extract_space_info(display, &info));
    CFArrayRef empty = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    CFDictionarySetValue(display, CFSTR("Spaces"), empty);
    assert(!strafe_extract_space_info(display, &info));
    assert(!strafe_extract_space_info(CFSTR("wrong type"), &info));
    assert(!strafe_get_space_info_for_display(NULL, NULL));
    CFRelease(empty); CFRelease(display); CFRelease(spaces);
    CFRelease(a); CFRelease(b); CFRelease(missing);
}

static void ramps(void) {
    const int phases[] = {1, 2, 4, 8};
    const double steps[][2] = {{0.0, 0.0}, {0.1, 65.0}, {0.35, 130.0}};
    for (int modern = 0; modern < 2; ++modern)
    for (int inverted = 0; inverted < 2; ++inverted)
    for (int dir = 0; dir < 2; ++dir)
    for (size_t i = 0; i < 3; ++i) {
        int phase = phases[i], sign = (dir != inverted) ? 1 : -1;
        double progress = steps[i][0], velocity = steps[i][1];
        CGEventRef event = strafe_create_ramp_event((StrafeDirection)dir, velocity,
            phase, progress, modern, inverted);
        assert(event && strafe_event_is_strafe(event));
        // Ramps carry per-phase velocity on every phase, unlike the instant shape.
        assert(strafe_event_swipe_velocity_x(event) == sign * velocity);
        assert(CGEventGetDoubleValueField(event, (CGEventField)130) == sign * velocity);
        CFDataRef data = CGEventCreateData(NULL, event);
        assert(data);
        CGEventRef copy = CGEventCreateFromData(NULL, data);
        assert(copy);
        assert(strafe_event_cgs_type(copy) == 30 && strafe_event_hid_type(copy) == 23);
        assert(strafe_event_gesture_phase(copy) == phase && strafe_event_swipe_motion(copy) == 1);
        // Progress crosses a float conversion in serialization; velocities here
        // are exactly representable and compare exactly.
        assert(fabs(strafe_event_swipe_progress(copy) - sign * progress) < 1e-7);
        assert(strafe_event_swipe_velocity_x(copy) == sign * velocity);
        if (modern) {
            assert(CGEventGetIntegerValueField(copy, (CGEventField)134) == phase);
            // Re-augmenting the copy replaces (not duplicates) the payload.
            CGEventRef again = strafe_augment(copy);
            assert(again);
            CFRelease(again);
        }
        CFRelease(copy);
        CFRelease(data);
        CFRelease(event);
    }
    // Invalid ramp inputs: bad direction/phase, negative or non-finite progress.
    assert(!strafe_create_ramp_event((StrafeDirection)42, 130, 2, 0.1, false, false));
    assert(!strafe_create_ramp_event(StrafeDirectionRight, 130, 3, 0.1, true, false));
    assert(!strafe_create_ramp_event(StrafeDirectionRight, 130, 2, -0.1, false, false));
    assert(!strafe_create_ramp_event(StrafeDirectionRight, 130, 2, NAN, true, false));
    assert(!strafe_create_ramp_event(StrafeDirectionRight, -1, 2, 0.1, false, false));
}

static void expose(void) {
    int dock = -1, layer18 = -1, layer20 = -1;
    strafe_expose_counts(&dock, &layer18, &layer20);
    assert(dock >= 0 && layer18 >= 0 && layer20 >= 0);
    assert(layer18 + layer20 <= dock);
    strafe_expose_counts(NULL, NULL, NULL); // NULL out-parameters are allowed
}

int main(void) {
    events(); invalid(); topology(); ramps(); expose();
    puts("CStrafe: 32 instant + 24 ramp event round-trips, invalid input/wire, topology and overlay-census tests passed (no posting).");
    return 0;
}
