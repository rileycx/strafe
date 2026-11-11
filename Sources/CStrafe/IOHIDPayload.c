// macOS 27 gesture serialization, adapted from joshuarli/iss (0BSD).
// Copyright (c) 2026 joshuarli. See LICENSE for attribution and license.
#include "IOHIDPayload.h"
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

// --- Follow-finger: rewrite a REAL event's payload velocity ---------------
// A real macOS 27 dock-swipe event already carries a field-4205 record, and the
// Dock reads velocity from it rather than from field 129. Find that record by
// validating its layout, then replace (or add) its velocity child event.

// No real payload comes close; this only bounds the walk over untrusted bytes.
static const uint32_t kMaxPayloadEvents = 64;

static uint32_t read_u32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static void write_u32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static size_t read_be16(const uint8_t *p) { return ((size_t)p[0] << 8) | p[1]; }

// A validated field-4205 record. Offsets are from the start of the serialized
// event, so they stay valid when a velocity child is inserted at `events_end`.
typedef struct {
    size_t payload;      // first payload byte, just past the 4-byte record header
    size_t size;         // payload size, as stored in the record header
    size_t events_end;   // just past the payload's last event
    bool has_velocity;
    size_t velocity;     // the velocity child event, when has_velocity
} PayloadRecord;

// Walk the flattened event list of the payload at `record->payload`, filling in
// the rest of `record`. False unless every event fits and one is a fluid gesture.
static bool parse_payload(const uint8_t *bytes, PayloadRecord *record) {
    const uint8_t *p = bytes + record->payload;
    size_t size = record->size;
    if (size < sizeof(IOHIDSystemQueueElementHeader)) return false;
    uint32_t attributes = read_u32(p + offsetof(IOHIDSystemQueueElementHeader, attribute_length));
    uint32_t count = read_u32(p + offsetof(IOHIDSystemQueueElementHeader, event_count));
    if (count == 0 || count > kMaxPayloadEvents || attributes > size) return false;
    size_t pos = sizeof(IOHIDSystemQueueElementHeader) + attributes;
    bool fluid = false;
    for (uint32_t i = 0; i < count; i++) {
        if (pos + sizeof(IOHIDEventBase) > size) return false;
        uint32_t eventSize = read_u32(p + pos + offsetof(IOHIDEventBase, size));
        uint32_t type = read_u32(p + pos + offsetof(IOHIDEventBase, type));
        if (eventSize < sizeof(IOHIDEventBase) || pos + eventSize > size) return false;
        if (type == kIOHIDEventTypeFluidTouchGesture) fluid = true;
        if (type == kIOHIDEventTypeVelocity && !record->has_velocity
            && eventSize >= sizeof(IOHIDVelocityEventData)) {
            record->has_velocity = true;
            record->velocity = record->payload + pos;
        }
        pos += eventSize;
    }
    record->events_end = record->payload + pos;
    return fluid;
}

static bool find_payload_record(const uint8_t *bytes, size_t length, PayloadRecord *record) {
    for (size_t off = 4; off + 4 <= length; off++) {
        size_t size = read_be16(bytes + off);
        if (read_be16(bytes + off + 2) != kCGEventRawIOHIDPayload || off + 4 + size > length) continue;
        *record = (PayloadRecord){ .payload = off + 4, .size = size };
        if (parse_payload(bytes, record)) return true;
    }
    return false;
}

// Overwrite the velocity child's x velocity, or append a child carrying it.
// False if the record cannot grow to hold a new child.
static bool set_payload_velocity(CFMutableDataRef data, const PayloadRecord *record, double velocity) {
    int32_t fixed = double_to_fixed1616(velocity);
    if (record->has_velocity) {
        CFIndex at = (CFIndex)(record->velocity + offsetof(IOHIDVelocityEventData, velocity_x));
        CFDataReplaceBytes(data, CFRangeMake(at, sizeof(fixed)), (const UInt8 *)&fixed, sizeof(fixed));
        return true;
    }
    size_t grown = record->size + sizeof(IOHIDVelocityEventData);
    if (grown > UINT16_MAX) return false;
    IOHIDVelocityEventData child = {
        .base = { .size = sizeof(child), .type = kIOHIDEventTypeVelocity, .depth = 1 },
        .velocity_x = fixed,
    };
    CFDataReplaceBytes(data, CFRangeMake((CFIndex)record->events_end, 0),
                       (const UInt8 *)&child, sizeof(child));
    uint8_t *payload = CFDataGetMutableBytePtr(data) + record->payload;
    uint8_t *count = payload + offsetof(IOHIDSystemQueueElementHeader, event_count);
    write_u32(count, read_u32(count) + 1);
    payload[-4] = (uint8_t)(grown >> 8);
    payload[-3] = (uint8_t)grown;
    return true;
}

CGEventRef strafe_create_event_with_payload_velocity(CGEventRef event, double velocity) {
    if (!event) return NULL;
    CFDataRef data = CGEventCreateData(kCFAllocatorDefault, event);
    if (!data) return NULL;
    CFMutableDataRef patched = CFDataCreateMutableCopy(kCFAllocatorDefault, 0, data);
    CFRelease(data);
    if (!patched) return NULL;

    CGEventRef result = NULL;
    PayloadRecord record;
    if (find_payload_record(CFDataGetBytePtr(patched), (size_t)CFDataGetLength(patched), &record)
        && set_payload_velocity(patched, &record, velocity)) {
        result = CGEventCreateFromData(kCFAllocatorDefault, patched);
    }
    CFRelease(patched);
    return result;
}
