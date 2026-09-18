#include <Carbon/Carbon.h>
#include <assert.h>
#include <stdlib.h>

static unsigned activeCount;
static unsigned registrationCount;
static UInt32 rejectedKey = UINT32_MAX;

// Keep tests from claiming the user's real keyboard shortcuts.
OSStatus RegisterEventHotKey(UInt32 key, UInt32 modifiers, EventHotKeyID id,
                            EventTargetRef target, OptionBits options, EventHotKeyRef *out) {
    assert(key < 128);
    assert(modifiers != 0);
    assert(id.id == 1 || id.id == 2);
    assert(target != NULL && options == 0);
    if (key == rejectedKey) { *out = NULL; return eventHotKeyExistsErr; }
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
void test_reject_key(UInt32 key) { rejectedKey = key; }
