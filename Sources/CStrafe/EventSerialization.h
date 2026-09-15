// Modified adaptation of ISS bf32cf9732c706119e8307d2d70ae795b2b11c1c
// event_serialize.c and FasterSwiper src/gesture-serialization.cc.
// Rewritten for checked byte access, v2 validation and payload replacement.
// Copyright (c) 2026 jurplel; Copyright 2026 Matthew Bowen.
// See third-party license files at the repository root.
#ifndef STRAFE_EVENT_SERIALIZATION_H
#define STRAFE_EVENT_SERIALIZATION_H
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <mach/mach_time.h>

static bool strafe_fixed(double value, int32_t *out) {
    double scaled = value * 65536.0;
    if (!isfinite(scaled) || scaled < INT32_MIN || scaled > INT32_MAX) return false;
    *out = (int32_t)scaled;
    if (!*out && value != 0) *out = value > 0 ? 1 : -1;
    return true;
}

static void strafe_le(uint8_t *bytes, size_t offset, uint64_t value, size_t width) {
    for (size_t i = 0; i < width; ++i) bytes[offset + i] = (uint8_t)(value >> (8 * i));
}

static uint16_t strafe_be16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

// The caller supplies at least 96 bytes. Offsets are wire offsets, not C structs.
static bool strafe_payload(CGEventRef event, uint8_t bytes[96], size_t *length) {
    int64_t phase = CGEventGetIntegerValueField(event, (CGEventField)132);
    int64_t motion = CGEventGetIntegerValueField(event, (CGEventField)123);
    int64_t mask = CGEventGetIntegerValueField(event, (CGEventField)115);
    if (phase < 0 || phase > 255 || motion < 0 || motion > UINT16_MAX ||
        mask < 0 || mask > UINT32_MAX) return false;
    int32_t values[5];
    const int fields[] = {125, 126, 124, 129, 130};
    for (size_t i = 0; i < 5; ++i) {
        if (!strafe_fixed(CGEventGetDoubleValueField(event, (CGEventField)fields[i]), &values[i])) return false;
    }
    bool velocity = values[3] != 0 || values[4] != 0 || phase == 4;
    *length = velocity ? 96 : 68;
    memset(bytes, 0, 96);
    uint64_t time = CGEventGetTimestamp(event);
    strafe_le(bytes, 0, time ? time : mach_absolute_time(), 8);
    strafe_le(bytes, 24, velocity ? 2 : 1, 4);
    strafe_le(bytes, 28, 40, 4);
    strafe_le(bytes, 32, 23, 4);
    strafe_le(bytes, 36, (uint32_t)phase << 24, 4);
    strafe_le(bytes, 44, (uint32_t)values[0], 4);
    strafe_le(bytes, 48, (uint32_t)values[1], 4);
    strafe_le(bytes, 56, (uint32_t)mask, 4);
    strafe_le(bytes, 60, (uint16_t)motion, 2);
    strafe_le(bytes, 62, 3, 2);
    strafe_le(bytes, 64, (uint32_t)values[2], 4);
    if (velocity) {
        strafe_le(bytes, 68, 28, 4);
        strafe_le(bytes, 72, 9, 4);
        bytes[80] = 1;
        strafe_le(bytes, 84, (uint32_t)values[3], 4);
        strafe_le(bytes, 88, (uint32_t)values[4], 4);
    }
    return true;
}

// Reject unknown tags, illegal sizes, truncation and duplicate fields.
// Tag 0 size 1 is int64; other sizes are byte counts (including field4205).
static CFDataRef strafe_replace_payload(CFDataRef data, const uint8_t *payload, size_t payloadLength) {
    if (!data || !payload || (payloadLength != 68 && payloadLength != 96)) return NULL;
    CFIndex signedLength = CFDataGetLength(data);
    if (signedLength < 4 || signedLength > LONG_MAX - 100) return NULL;
    size_t length = (size_t)signedLength;
    const uint8_t *bytes = CFDataGetBytePtr(data);
    if (memcmp(bytes, "\0\0\0\2", 4)) return NULL;
    uint8_t seen[16384 / 8] = {0};
    size_t oldOffset = length, oldLength = 0;
    for (size_t offset = 4; offset < length;) {
        if (length - offset < 4) return NULL;
        uint16_t count = strafe_be16(bytes + offset);
        uint16_t header = strafe_be16(bytes + offset + 2);
        unsigned tag = header >> 14, field = header & 0x3fff;
        if (seen[field / 8] & (1u << (field % 8))) return NULL;
        seen[field / 8] |= (uint8_t)(1u << (field % 8));
        size_t size;
        if (tag == 0 && count > 0) size = count == 1 ? 8 : count;
        else if (tag == 1 && count == 1) size = 4;
        else if (tag == 3 && (count == 1 || count == 2)) size = count * 4;
        else return NULL;
        if (size > length - offset - 4) return NULL;
        if (field == 4205) {
            if (tag != 0 || count <= 1) return NULL;
            oldOffset = offset;
            oldLength = size + 4;
        }
        offset += size + 4;
    }
    size_t newLength = length - oldLength + 4 + payloadLength;
    uint8_t *result = malloc(newLength);
    if (!result) return NULL;
    memcpy(result, bytes, oldOffset);
    result[oldOffset] = 0;
    result[oldOffset + 1] = (uint8_t)payloadLength;
    result[oldOffset + 2] = 0x10;
    result[oldOffset + 3] = 0x6d;
    memcpy(result + oldOffset + 4, payload, payloadLength);
    memcpy(result + oldOffset + 4 + payloadLength, bytes + oldOffset + oldLength,
           length - oldOffset - oldLength);
    CFDataRef output = CFDataCreate(NULL, result, (CFIndex)newLength);
    free(result);
    return output;
}

static CGEventRef strafe_augment(CGEventRef event) {
    uint8_t payload[96];
    size_t length;
    if (!strafe_payload(event, payload, &length)) return NULL;
    CFDataRef original = CGEventCreateData(NULL, event);
    if (!original) return NULL;
    CFDataRef data = strafe_replace_payload(original, payload, length);
    CFRelease(original);
    if (!data) return NULL;
    CGEventRef result = CGEventCreateFromData(NULL, data);
    CFRelease(data);
    return result;
}
#endif
