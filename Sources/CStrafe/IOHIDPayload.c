// macOS 27 gesture serialization, adapted from joshuarli/iss (0BSD).
// Copyright (c) 2026 joshuarli. See LICENSE for attribution and license.
#include "IOHIDPayload.h"
#include "CStrafe.h"
#include <mach/mach_time.h>
#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

static const CGEventField kCGEventGestureSwipePositionX = 125;
static const CGEventField kCGEventGestureSwipePositionY = 126;
static const CGEventField kCGEventGestureSwipeMask = 115;
static const uint16_t kCGEventRawIOHIDPayload = 4205;

// macOS 27 validates synthetic dock swipes against this serialized IOHID
// queue payload, which is attached to CGEvent field 4205.
#pragma pack(push, 1)

typedef struct {
    uint32_t size;
    uint32_t type;
    uint32_t options;
    uint8_t depth;
    uint8_t reserved[3];
} IOHIDEventBase;

typedef struct {
    IOHIDEventBase base;
    int32_t position_x;
    int32_t position_y;
    int32_t position_z;
    uint32_t swipe_mask;
    uint16_t gesture_motion;
    uint16_t gesture_flavor;
    int32_t swipe_progress;
} IOHIDFluidTouchGestureData;

typedef struct {
    IOHIDEventBase base;
    int32_t velocity_x;
    int32_t velocity_y;
    int32_t velocity_z;
} IOHIDVelocityEventData;

typedef struct {
    uint64_t timestamp;
    uint64_t sender_id;
    uint32_t options;
    uint32_t attribute_length;
    uint32_t event_count;
} IOHIDSystemQueueElementHeader;

#pragma pack(pop)

_Static_assert(sizeof(IOHIDEventBase) == 16, "unexpected IOHID event base layout");
_Static_assert(sizeof(IOHIDFluidTouchGestureData) == 40,
               "unexpected IOHID fluid gesture layout");
_Static_assert(sizeof(IOHIDVelocityEventData) == 28,
               "unexpected IOHID velocity layout");
_Static_assert(sizeof(IOHIDSystemQueueElementHeader) == 28,
               "unexpected IOHID queue header layout");

static const uint32_t kIOHIDEventTypeVelocity = 9;
static const uint32_t kIOHIDEventTypeFluidTouchGesture = 23;
static const uint16_t kIOHIDGestureFlavorDockPrimary = 3;

static int32_t double_to_fixed1616(double value) {
    if (!isfinite(value)) return 0;
    double scaled = value * 65536.0;
    if (scaled >= INT32_MAX) return INT32_MAX;
    if (scaled <= INT32_MIN) return INT32_MIN;
    int32_t fixed = (int32_t)scaled;
    if (fixed == 0 && value != 0.0) return value > 0.0 ? 1 : -1;
    return fixed;
}

static uint8_t *generate_iohid_payload(CGEventRef event, size_t *out_length) {
    int64_t phase = CGEventGetIntegerValueField(event, (CGEventField)132);
    int64_t motion = CGEventGetIntegerValueField(event, (CGEventField)123);
    double progress = CGEventGetDoubleValueField(event, (CGEventField)124);
    double pos_x = CGEventGetDoubleValueField(event, kCGEventGestureSwipePositionX);
    double pos_y = CGEventGetDoubleValueField(event, kCGEventGestureSwipePositionY);
    double vel_x = CGEventGetDoubleValueField(event, (CGEventField)129);
    double vel_y = CGEventGetDoubleValueField(event, (CGEventField)130);
    int64_t swipe_mask = CGEventGetIntegerValueField(event, kCGEventGestureSwipeMask);

    bool include_velocity = (vel_x != 0.0 || vel_y != 0.0 || phase == 4);
    uint32_t event_count = include_velocity ? 2 : 1;
    size_t payload_length = sizeof(IOHIDSystemQueueElementHeader)
                          + sizeof(IOHIDFluidTouchGestureData);
    if (include_velocity) payload_length += sizeof(IOHIDVelocityEventData);

    uint8_t *payload = malloc(payload_length);
    if (!payload) return NULL;
    memset(payload, 0, payload_length);

    IOHIDSystemQueueElementHeader *header = (IOHIDSystemQueueElementHeader *)payload;
    uint64_t timestamp = CGEventGetTimestamp(event);
    header->timestamp = timestamp ? timestamp : mach_absolute_time();
    header->event_count = event_count;

    IOHIDFluidTouchGestureData *fluid =
        (IOHIDFluidTouchGestureData *)(payload + sizeof(IOHIDSystemQueueElementHeader));
    fluid->base.size = sizeof(IOHIDFluidTouchGestureData);
    fluid->base.type = kIOHIDEventTypeFluidTouchGesture;
    fluid->base.options = (uint32_t)((phase & 0xFF) << 24);
    fluid->position_x = double_to_fixed1616(pos_x);
    fluid->position_y = double_to_fixed1616(pos_y);
    fluid->swipe_mask = (uint32_t)swipe_mask;
    fluid->gesture_motion = (uint16_t)motion;
    fluid->gesture_flavor = kIOHIDGestureFlavorDockPrimary;
    fluid->swipe_progress = double_to_fixed1616(progress);

    if (include_velocity) {
        IOHIDVelocityEventData *velocity = (IOHIDVelocityEventData *)
            (payload + sizeof(IOHIDSystemQueueElementHeader)
             + sizeof(IOHIDFluidTouchGestureData));
        velocity->base.size = sizeof(IOHIDVelocityEventData);
        velocity->base.type = kIOHIDEventTypeVelocity;
        velocity->base.depth = 1;
        velocity->velocity_x = double_to_fixed1616(vel_x);
        velocity->velocity_y = double_to_fixed1616(vel_y);
    }

    *out_length = payload_length;
    return payload;
}

// Adds the raw IOHID payload needed for synthetic dock swipes on macOS 27.
CGEventRef strafe_create_augmented_event(CGEventRef event) {
    if (!event) return NULL;

    CFDataRef data = CGEventCreateData(kCFAllocatorDefault, event);
    if (!data) return NULL;

    const uint8_t *bytes = CFDataGetBytePtr(data);
    CFIndex length = CFDataGetLength(data);
    if (length < 4 || bytes[0] != 0 || bytes[1] != 0
        || bytes[2] != 0 || bytes[3] != 2) {
        CFRelease(data);
        return NULL;
    }

    size_t payload_length = 0;
    uint8_t *payload = generate_iohid_payload(event, &payload_length);
    if (!payload) {
        CFRelease(data);
        return NULL;
    }

    size_t new_length = (size_t)length + 4 + payload_length;
    uint8_t *new_bytes = malloc(new_length);
    if (!new_bytes) {
        free(payload);
        CFRelease(data);
        return NULL;
    }

    memcpy(new_bytes, bytes, length);
    new_bytes[length] = (uint8_t)(payload_length >> 8);
    new_bytes[length + 1] = (uint8_t)payload_length;
    new_bytes[length + 2] = (uint8_t)(kCGEventRawIOHIDPayload >> 8);
    new_bytes[length + 3] = (uint8_t)kCGEventRawIOHIDPayload;
    memcpy(new_bytes + length + 4, payload, payload_length);

    free(payload);
    CFRelease(data);

    CFDataRef new_data = CFDataCreate(kCFAllocatorDefault, new_bytes, (CFIndex)new_length);
    free(new_bytes);
    if (!new_data) return NULL;

    CGEventRef result = CGEventCreateFromData(kCFAllocatorDefault, new_data);
    CFRelease(new_data);
    return result;
}

// --- Follow-finger: change a REAL event's release velocity ----------------
// A real macOS 27 dock-swipe event already carries a field-4205 record, and the
// Dock reads velocity from it rather than from field 129. Find that record by
// validating its layout, then replace (or add) its velocity child event.

static uint32_t read_u32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static void write_u32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }

// Walk a payload's flattened event list. Returns false unless every event fits
// and a fluid-gesture event exists; `*velocity` is the velocity child's offset
// within the payload, or -1 if there is none.
static bool walk_payload(const uint8_t *p, size_t size, size_t *end, long *velocity) {
    if (size < sizeof(IOHIDSystemQueueElementHeader)) return false;
    uint32_t attributes = read_u32(p + offsetof(IOHIDSystemQueueElementHeader, attribute_length));
    uint32_t count = read_u32(p + offsetof(IOHIDSystemQueueElementHeader, event_count));
    if (count == 0 || count > 64 || attributes > size) return false;
    size_t pos = sizeof(IOHIDSystemQueueElementHeader) + attributes;
    bool fluid = false;
    *velocity = -1;
    for (uint32_t i = 0; i < count; i++) {
        if (pos + sizeof(IOHIDEventBase) > size) return false;
        uint32_t eventSize = read_u32(p + pos + offsetof(IOHIDEventBase, size));
        uint32_t type = read_u32(p + pos + offsetof(IOHIDEventBase, type));
        if (eventSize < sizeof(IOHIDEventBase) || pos + eventSize > size) return false;
        if (type == kIOHIDEventTypeFluidTouchGesture) fluid = true;
        if (type == kIOHIDEventTypeVelocity && *velocity < 0
            && eventSize >= sizeof(IOHIDVelocityEventData)) *velocity = (long)pos;
        pos += eventSize;
    }
    *end = pos;
    return fluid;
}

// Locate the field-4205 record: its offset in `bytes`, or -1.
static long find_payload_record(const uint8_t *bytes, size_t length,
                                size_t *size, size_t *end, long *velocity) {
    for (size_t off = 4; off + 4 <= length; off++) {
        size_t recordSize = ((size_t)bytes[off] << 8) | bytes[off + 1];
        unsigned field = ((unsigned)bytes[off + 2] << 8) | bytes[off + 3];
        if (field != kCGEventRawIOHIDPayload || off + 4 + recordSize > length) continue;
        if (walk_payload(bytes + off + 4, recordSize, end, velocity)) {
            *size = recordSize;
            return (long)off;
        }
    }
    return -1;
}

CGEventRef strafe_copy_with_release_velocity(CGEventRef event, double velocity) {
    if (!event) return NULL;
    CGEventRef copy = CGEventCreateCopy(event);
    if (!copy) return NULL;
    CGEventSetDoubleValueField(copy, (CGEventField)129, velocity);

    CFDataRef data = CGEventCreateData(kCFAllocatorDefault, copy);
    if (!data) return copy;
    const uint8_t *bytes = CFDataGetBytePtr(data);
    size_t length = (size_t)CFDataGetLength(data);
    size_t size = 0, end = 0;
    long vel = -1;
    long off = find_payload_record(bytes, length, &size, &end, &vel);
    // No payload (before macOS 27): the field above is what the Dock reads.
    if (off < 0) { CFRelease(data); return copy; }

    size_t insert = vel >= 0 ? 0 : sizeof(IOHIDVelocityEventData);
    if (size + insert > 0xFFFF) { CFRelease(data); return copy; }
    uint8_t *out = malloc(length + insert);
    if (!out) { CFRelease(data); return copy; }

    // Record header, payload events, [new velocity child], rest of the event.
    size_t payload = (size_t)off + 4;
    memcpy(out, bytes, payload + end);
    memcpy(out + payload + end + insert, bytes + payload + end, length - payload - end);
    if (insert) {
        IOHIDVelocityEventData child;
        memset(&child, 0, sizeof(child));
        child.base.size = sizeof(child);
        child.base.type = kIOHIDEventTypeVelocity;
        child.base.depth = 1;
        memcpy(out + payload + end, &child, sizeof(child));
        vel = (long)end;
        uint8_t *count = out + payload + offsetof(IOHIDSystemQueueElementHeader, event_count);
        write_u32(count, read_u32(count) + 1);
        out[off] = (uint8_t)((size + insert) >> 8);
        out[off + 1] = (uint8_t)(size + insert);
    }
    // The payload carries direction in the Natural-scrolling orientation, the
    // same rule as for posted events (measured on macOS 27.0 with it on).
    double written = strafe_posted_sign_reversed() ? -velocity : velocity;
    write_u32(out + payload + (size_t)vel + offsetof(IOHIDVelocityEventData, velocity_x),
              (uint32_t)double_to_fixed1616(written));
    CFRelease(data);

    CFDataRef patched = CFDataCreate(kCFAllocatorDefault, out, (CFIndex)(length + insert));
    free(out);
    if (!patched) return copy;
    CGEventRef result = CGEventCreateFromData(kCFAllocatorDefault, patched);
    CFRelease(patched);
    if (!result) return copy;
    CFRelease(copy);
    return result;
}
