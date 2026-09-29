#include <Carbon/Carbon.h>
#include <assert.h>
#include <stdlib.h>

static unsigned activeCount;
static unsigned registrationCount;
static unsigned failingID;

// Keep tests from claiming the user's real keyboard shortcuts.
OSStatus RegisterEventHotKey(UInt32 key, UInt32 modifiers, EventHotKeyID id,
                            EventTargetRef target, OptionBits options, EventHotKeyRef *out) {
    assert(key == kVK_LeftArrow || key == kVK_RightArrow);
    assert(id.id >= 1 && id.id <= 4);
    assert(key == ((id.id % 2) ? kVK_LeftArrow : kVK_RightArrow));
    assert(modifiers == ((id.id <= 2) ? (controlKey | optionKey) : controlKey));
    if (id.id == failingID) { *out = NULL; return eventHotKeyExistsErr; }
    assert(target != NULL && options == 0);
    *out = (EventHotKeyRef)malloc(1);
    assert(*out != NULL);
    activeCount++;
    registrationCount++;
    return noErr;
}

OSStatus UnregisterEventHotKey(EventHotKeyRef ref) {
    assert(ref != NULL && activeCount > 0);
    free(ref);
    activeCount--;
    return noErr;
}

unsigned test_active_hotkeys(void) { return activeCount; }
unsigned test_registration_count(void) { return registrationCount; }

void test_fail_registration(unsigned id) { failingID = id; }
OSStatus test_fire_hotkey(unsigned id, unsigned signature) {
    EventRef event = NULL;
    assert(CreateEvent(NULL, kEventClassKeyboard, kEventHotKeyPressed,
                       GetCurrentEventTime(), 0, &event) == noErr);
    EventHotKeyID hotkey = {signature, id};
    assert(SetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
                             sizeof(hotkey), &hotkey) == noErr);
    OSStatus status = SendEventToEventTarget(event, GetApplicationEventTarget());
    ReleaseEvent(event);
    return status;
}
