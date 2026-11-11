#ifndef STRAFE_IOHID_PAYLOAD_H
#define STRAFE_IOHID_PAYLOAD_H
#include <ApplicationServices/ApplicationServices.h>

// Returns a new event with the macOS 27 IOHID payload, or NULL on failure.
// The input is borrowed; the caller owns the returned event.
CGEventRef strafe_create_augmented_event(CGEventRef event);

// Returns a new copy of a real dock-swipe event whose embedded IOHID payload
// (field 4205) carries `velocity` as its x velocity, in the payload's own
// orientation. NULL if the event has no such payload (before macOS 27) or on
// failure. The input is borrowed; the caller owns the returned event.
CGEventRef strafe_create_event_with_payload_velocity(CGEventRef event, double velocity);
#endif
