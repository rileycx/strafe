# strafe — Instant macOS Spaces Switching: Implementation Spec

> ⚠️ **THIS FILE DOCUMENTS THE UPSTREAM PROJECT, NOT strafe.**
>
> This spec describes `jurplel/InstantSpaceSwitcher` (ISS) — the reference
> implementation that strafe was independently reimplemented *from*. It is a
> record of how the upstream C project works, **not** a description of strafe's
> own code. Wherever this document and strafe's source disagree, the source is
> authoritative. In particular, several things described below exist **only in
> upstream and are intentionally absent from strafe**:
>
> - **The `tccutil reset Accessibility` subprocess call** (§4). strafe never
>   shells out to `tccutil` or any other process.
> - **The second event tap** used for hotkey recording (§4). strafe has exactly
>   one event tap and records hotkeys via Carbon, not a tap.
> - **Key-event masking / key events in the tap mask** (§2.1). strafe's tap masks
>   only the two private gesture types (`1<<29 | 1<<30`); it never masks or
>   inspects `kCGEventKeyDown`/`kCGEventKeyUp`, so it cannot observe keystrokes.
>
> For the authoritative statement of what strafe actually does — and grep-able
> proof of what it does not — see [SECURITY.md](../SECURITY.md).

Source of truth for this spec: reverse-engineered from `jurplel/InstantSpaceSwitcher`
(ISS), v2.0, MIT-licensed. Core mechanism lives entirely in one C file:
`Sources/ISS/ISS.c` (+ header `Sources/ISS/include/ISS.h`). Swift is only glue
(hotkeys, UI, permissions, lifecycle). The author's blog post
(`arhan.sh/blog/native-instant-space-switching-on-macos/`) contains only one
technical sentence ("it works by simulating a trackpad swipe with a large amount
of velocity"); all concrete detail below comes from the source.

**License:** MIT License, Copyright (c) 2026 jurplel.

---

## 1. Core mechanism: synthesizing a Dock-swipe gesture

The trick: post a synthetic **Dock swipe** CGEvent (the same event type the OS
generates for a real 3-finger horizontal trackpad swipe between Spaces) but with
(a) an artificially near-zero *progress* and (b) an artificially *high velocity*.
The high velocity makes the WindowServer treat the gesture as a flick and skip
the slide animation, jumping instantly to the neighboring Space.

### 1.1 Frameworks / linkage
No private framework is dlopen'd. The event API is plain public CoreGraphics
(`CGEvent*`). The only *private* pieces are:
- Undocumented `CGEventField` integer field indices (magic numbers below).
- Undocumented `CGSEventType` values written into private field 55.
- CGS (SkyLight/CoreGraphicsServices) symbols for reading Space topology, declared
  `extern ... __attribute__((weak_import))` and used directly (no dlsym; they
  resolve from the already-linked CoreGraphics/SkyLight).

`Package.swift` links: `ApplicationServices`, `CoreFoundation`, `IOKit`. Includes:
`ApplicationServices/ApplicationServices.h`, `CoreGraphics/CGEventTypes.h`,
`dlfcn.h`, `float.h`.

Weak-imported CGS symbols (used for topology, NOT for synthesis):
```c
typedef int32_t  CGSConnectionID;
typedef uint64_t CGSSpaceID;
extern CFArrayRef  CGSCopyManagedDisplaySpaces(CGSConnectionID connection, CFStringRef display) __attribute__((weak_import));
extern CFStringRef CGSCopyActiveMenuBarDisplayIdentifier(CGSConnectionID connection) __attribute__((weak_import));
extern CGSConnectionID CGSMainConnectionID(void) __attribute__((weak_import));
extern CGSSpaceID  CGSGetActiveSpace(CGSConnectionID connection) __attribute__((weak_import));
```
Availability is guarded at runtime by taking the address of the weak symbol:
```c
static bool cgs_symbols_available(void) {
    return (&CGSMainConnectionID != NULL) &&
           (&CGSGetActiveSpace != NULL) &&
           (&CGSCopyManagedDisplaySpaces != NULL);
}
```

### 1.2 Event field constants (private `CGEventField` indices — MAGIC NUMBERS)
```c
static const CGEventField kCGSEventTypeField          = (CGEventField)55;   // private CGSEventType selector
static const CGEventField kCGEventGestureHIDType      = (CGEventField)110;  // IOHIDEvent gesture type
static const CGEventField kCGEventGestureSwipeMotion  = (CGEventField)123;  // motion axis (horizontal=1)
static const CGEventField kCGEventGestureSwipeProgress= (CGEventField)124;  // gesture progress (double)
static const CGEventField kCGEventGestureSwipeVelocityX = (CGEventField)129; // (double)
static const CGEventField kCGEventGestureSwipeVelocityY = (CGEventField)130; // (double)
static const CGEventField kCGEventGesturePhase        = (CGEventField)132;  // CGSGesturePhase
```

### 1.3 Type/enum constants
```c
// See IOHIDEventType enum in IOHIDFamily
static const uint32_t kIOHIDEventTypeDockSwipe = 23;   // written into field 110

typedef uint32_t CGSEventType;                          // written into field 55
enum {
    kCGSEventScrollWheel       = 22,
    kCGSEventZoom              = 28,
    kCGSEventGesture           = 29,
    kCGSEventDockControl       = 30,   // <-- the Dock-swipe event type we synthesize + intercept
    kCGSEventFluidTouchGesture = 31,
};

typedef CF_ENUM(uint8_t, CGSGesturePhase) {             // written into field 132
    kCGSGesturePhaseNone      = 0,
    kCGSGesturePhaseBegan     = 1,
    kCGSGesturePhaseChanged   = 2,
    kCGSGesturePhaseEnded     = 4,
    kCGSGesturePhaseCancelled = 8,
    kCGSGesturePhaseMayBegin  = 128,
};

typedef CF_ENUM(uint16_t, CGGestureMotion) {            // written into field 123
    kCGGestureMotionHorizontal = 1,
};
```

### 1.4 Direction & progress encoding
- **Right** (next Space): `progress = +FLT_TRUE_MIN`, `velocityX/Y = +velocity`.
- **Left** (previous Space): `progress = -FLT_TRUE_MIN`, `velocityX/Y = -velocity`.
- `FLT_TRUE_MIN` is the smallest positive denormal float (~1.4e-45). The sign of
  `progress` carries direction; its near-zero magnitude + high velocity is what
  makes the switch *instant* (per source comment: "Empirically, ±FLT_TRUE_MIN
  used in this way makes switching instant.").
- Velocity magnitude comes from the `gestureSpeed` setting (default **2000.0**).

> **strafe deviates here.** The reference treats velocity as the speed knob, so
> a "slower transition" setting would be lower `gestureSpeed` at unchanged
> zero-progress. Measured (`bench sweep`, n=6/shape, median ms to the new Space):
> v=40 → 841 ms and it only switched 5/6; v=50 → 770; v=60 → 559; v=80 → 77;
> v=2000 → 40. That is a cliff between 60 and 80, not a dial, and it is
> unreliable at the slow end.
>
> Animation actually lives on the **progress ramp**: climbing progress 0 → 0.35
> across N `changed` events over a span, then `ended` with a moderate end
> velocity (~130). Same sweep: 30 ms → 80 ms, 60 ms → 107 ms, 120 ms → 171 ms,
> 6/6 at every duration — evenly spaced and reliable, with 120 ms landing on
> macOS's own animated switch. strafe's **Transition speed** setting is
> therefore a ramp duration, not a velocity
> (`Sources/strafe/TransitionSpeed.swift`).

### 1.5 The exact synthesis: one event builder, three-phase sequence
Each phase is one `CGEventCreate(NULL)` event with all seven fields set, posted to
**`kCGSessionEventTap`** via `CGEventPost`:
```c
static bool iss_post_dock_swipe(CGSGesturePhase phase, ISSDirection direction, double velocity) {
    const bool isRight = (direction == ISSDirectionRight);
    // Empirically, ±FLT_TRUE_MIN used in this way makes switching instant.
    const double progress = isRight ? (double)FLT_TRUE_MIN : -(double)FLT_TRUE_MIN;

    // Velocity of gesture based on speed setting
    const double vel = isRight ? velocity : -velocity;

    CGEventRef ev = CGEventCreate(NULL);
    if (!ev) { return false; }
    CGEventSetIntegerValueField(ev, kCGSEventTypeField,           kCGSEventDockControl);
    CGEventSetIntegerValueField(ev, kCGEventGestureHIDType,       kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(ev, kCGEventGesturePhase,         phase);
    CGEventSetDoubleValueField (ev, kCGEventGestureSwipeProgress, progress);
    CGEventSetIntegerValueField(ev, kCGEventGestureSwipeMotion,   kCGGestureMotionHorizontal);
    CGEventSetDoubleValueField (ev, kCGEventGestureSwipeVelocityX, vel);
    CGEventSetDoubleValueField (ev, kCGEventGestureSwipeVelocityY, vel);
    CGEventPost(kCGSessionEventTap, ev);
    CFRelease(ev);
    return true;
}
```
**Sequence (order is load-bearing):** post `began` → `changed` → `ended`, all
immediately, **no sleeps/delays between them**:
```c
static bool iss_perform_switch_gesture(ISSDirection direction, double velocity) {
    // Send three gesture events--began, changed, and ended
    // If we only send two then mission control doesn't work.
    return iss_post_dock_swipe(kCGSGesturePhaseBegan,   direction, velocity)
        && iss_post_dock_swipe(kCGSGesturePhaseChanged, direction, velocity)
        && iss_post_dock_swipe(kCGSGesturePhaseEnded,   direction, velocity);
}
```
> GOTCHA: All three phases are required. Two phases leave Mission Control in a
> broken state (source comment above). Same `progress`/`velocity` values are used
> on all three phases.

### 1.6 Direct-to-space-N
Not a single event — implemented as N repeated single-step swipes in a loop,
with velocity multiplied by the number of steps:
```c
ISSDirection direction = currentIndex < targetIndex ? ISSDirectionRight : ISSDirectionLeft;
unsigned int steps = direction == ISSDirectionRight ? (targetIndex - currentIndex)
                                                    : (currentIndex - targetIndex);
double velocity = gestureSpeed * steps;   // Multiply velocity by steps for faster multi-space switching
for (unsigned int i = 0; i < steps; i++) {
    if (!iss_perform_switch_gesture(direction, velocity)) return false;
}
set_prediction(info.displayID, targetIndex);
```
CLI: `ISSCli index <n>` (1-based on the CLI, converted to zero-based internally).
`left`/`right`/`l`/`r`/`0`/`1` for directional.

---

## 2. Intercepting the user's REAL trackpad swipe

### 2.1 The event tap
Created in `iss_init()`:
```c
CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp)
    | (1ULL << kCGSEventGesture) | (1ULL << kCGSEventDockControl);
globalTap = CGEventTapCreate(
    kCGSessionEventTap,        // location
    kCGHeadInsertEventTap,     // placement: head of the tap chain
    kCGEventTapOptionDefault,  // active tap (can modify/suppress) — NOT listen-only
    mask,
    eventTapCallback,
    NULL
);
globalSource = CFMachPortCreateRunLoopSource(NULL, globalTap, 0);
CFRunLoopAddSource(CFRunLoopGetMain(), globalSource, kCFRunLoopCommonModes);
CGEventTapEnable(globalTap, true);
```
- **Tap location:** `kCGSessionEventTap` (both for the tap AND for posting synthetic
  events — they go to the same place).
- **Placement:** `kCGHeadInsertEventTap` (so it sees events before the WindowServer).
- **Option:** `kCGEventTapOptionDefault` — active tap, so the callback can return
  `NULL` to suppress the original event.
- **Mask:** the two private types `kCGSEventGesture (29)` and `kCGSEventDockControl
  (30)` are added to the mask by raw bit shift `(1ULL << type)` (not covered by any
  public `CGEventMaskBit` constant), plus key up/down.
- **Run loop:** source added to the **main** run loop in `kCFRunLoopCommonModes`.
  The app must have a running CFRunLoop (it's an `LSUIElement` AppKit app; the main
  run loop is alive).

### 2.2 Distinguishing a real 3-finger horizontal space-swipe
In `eventTapCallback` (only acts when `swipeOverrideEnabled`):
1. Handle tap-disable events first (re-enable, see gotchas).
2. Read private field 55 → `CGSEventType`. Only care about `kCGSEventDockControl`
   (and `kCGSEventGesture` for companion suppression).
3. **Real vs synthetic discrimination:** real HID gestures have
   `kCGEventSourceUnixProcessID == 0` (they originate in the HID kernel). Synthetic
   events (ours, and any other app's) have nonzero source pid and are passed through:
   ```c
   if (eventType == kCGSEventDockControl || eventType == kCGSEventGesture) {
       pid_t sourcePid = (pid_t)CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
       if (sourcePid != 0) return event;   // pass through synthetic
   }
   ```
4. For a Dock-control event: require `field110 == kIOHIDEventTypeDockSwipe (23)` and
   `field123 == kCGGestureMotionHorizontal (1)`; anything else passes through (e.g.
   vertical/App Exposé swipes).
5. Read phase from field 132 and drive a small state machine.

### 2.3 State machine (suppress real, fire synthetic instant switch)
```c
switch (phase) {
case kCGSGesturePhaseBegan:
    if (iss_is_expose_active()) return event;   // let real gesture through in Exposé
    swipeTracking = true;
    swipeFired = false;
    return NULL;                                // SUPPRESS the real 'began'

case kCGSGesturePhaseChanged: {
    if (!swipeTracking) return event;
    if (!swipeFired) {
        double progress = CGEventGetDoubleValueField(event, kCGEventGestureSwipeProgress);
        if (progress != 0.0) {
            ISSDirection dir = progress > 0 ? ISSDirectionRight : ISSDirectionLeft;
            swipeFired = true;
            swipe_override_switch(dir);         // fire our instant switch as soon as direction is known
        }
    }
    return NULL;                                // SUPPRESS
}

case kCGSGesturePhaseEnded: {
    if (!swipeTracking) return event;
    if (!swipeFired) {                          // fallback: derive direction from end velocity
        double velocity = CGEventGetDoubleValueField(event, kCGEventGestureSwipeVelocityX);
        if (velocity != 0.0) {
            ISSDirection dir = velocity > 0 ? ISSDirectionRight : ISSDirectionLeft;
            swipeFired = true;
            swipe_override_switch(dir);
        }
    }
    swipeTracking = false;
    swipeFired = false;
    return NULL;                                // SUPPRESS
}

case kCGSGesturePhaseCancelled:
    swipeTracking = false;
    swipeFired = false;
    return NULL;

default:
    return swipeTracking ? NULL : event;
}
```
And companion gesture events (type 29) are dropped while tracking:
```c
if (eventType == kCGSEventGesture && swipeTracking) {
    return NULL;
}
```
- **Suppression mechanism:** returning `NULL` from an active event tap deletes the
  event so the WindowServer never animates the real slide.
- **Firing:** the switch fires on the FIRST `changed` phase where `progress != 0`
  (direction = sign of progress), not waiting for gesture end — this is what makes
  the override feel instant. `ended` is a fallback (direction from velocityX sign)
  if no nonzero-progress `changed` was seen.

### 2.4 Elastic-rebound handling (repo issue #65 context — issue not publicly
resolvable via API; behavior is addressed in code as follows)
The real problem the override must beat: between two rapid swipes, macOS's live
"active space" query lags, and the real gesture's continued phases would try to
elastically drag/rebound the Space. Two mechanisms:
1. **Full original-gesture suppression.** Every phase of the real gesture returns
   `NULL` once tracking starts, so the OS never runs its own elastic drag/rebound —
   ISS replaces the whole gesture with one discrete jump.
2. **Prediction dictionary** to avoid rebounding off a stale current index. Instead
   of re-reading the (laggy) live active space for each switch, ISS keeps a
   per-display predicted index (`DisplayID → index`) and advances it optimistically:
   ```c
   static bool get_prediction(const char *displayID, unsigned int *outIndex);
   static void set_prediction(const char *displayID, unsigned int index);
   // on switch:
   unsigned int current = get_prediction(info.displayID, &predicted) ? predicted : info.currentIndex;
   unsigned int target  = dir == ISSDirectionLeft ? current - 1 : current + 1;
   if (iss_switch_with_info(&info, dir)) { set_prediction(info.displayID, target); ... }
   ```
   The prediction is reset to live CGS data whenever the OS reports a real space
   change, via `iss_reset_predictions()` called from Swift on
   `NSWorkspace.activeSpaceDidChangeNotification` (see §5). This keeps rapid
   repeated swipes from either overshooting bounds or snapping back.
- **Bounds guard** prevents swiping past the first/last space (which is where visible
  rubber-band/rebound would otherwise occur):
  ```c
  if (direction == ISSDirectionLeft) return current == 0;
  return current + 1 >= info->spaceCount;   // block at right edge
  ```

### 2.5 Exposé / Mission Control passthrough
While overlays are up, real swipes should pass through. ISS detects them by scanning
`CGWindowListCopyWindowInfo` for Dock-owned windows at **layer 18** and **layer 20**:
- App Exposé: `layer18Count > 0 && layer20Count > 0 && layer20Count <= layer18Count`.
- Mission Control: `layer18Count > 0 && layer20Count > layer18Count`.
Detection is gated by `iss_set_overlay_detection_enabled(bool)` (default ON, see §5);
in `began`, if `iss_is_expose_active()` the real gesture is passed through untouched.

---

## 3. macOS 26 (Tahoe) specifics
- No `#available`/`@available` version checks anywhere in the code. No source
  comments mention "Tahoe" or "26". Runtime capability gating is done purely via the
  weak-import address check `cgs_symbols_available()` (§1.1), not OS version.
- `Info.plist` `LSMinimumSystemVersion = 13.0`; `Package.swift` platform `.macOS(.v13)`.
  So the same private-field/event-type approach is claimed to work from macOS 13
  through 26.
- **v2.0 release notes** (published 2026-04-18) explicitly list **"Build on macOS 26"**
  as a change, and add: fix switching spaces while in Mission Control; allow
  overriding swipe gestures; experimental Mission Control detection (used to hide OSD
  in Mission Control and to let overridden swipes pass through in Exposé); configurable
  animation speed; open settings on re-open.
- CI builds on the `macos-26` GitHub runner (`.github/workflows/nightly.yml`).
- Implication: no Tahoe-specific field renumbering or workaround was needed — the
  field indices (55/110/123/124/129/130/132) and `kCGSEventDockControl=30` /
  `kIOHIDEventTypeDockSwipe=23` are treated as stable across 13–26. (Still, treat
  these as version-fragile; see gotchas.)

---

## 4. Permissions model
- **Accessibility** is the only TCC permission requested (required for an active
  event tap). Requested in Swift (`AppDelegate.ensureAccessibilityPermission`):
  ```swift
  private func ensureAccessibilityPermission() {
    guard !AXIsProcessTrusted() else { return }
    if let bundleId = Bundle.main.bundleIdentifier {
      let task = Process()
      task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
      task.arguments = ["reset", "Accessibility", bundleId]   // clears stale grant (unsigned-app churn)
      try? task.run(); task.waitUntilExit()
    }
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [promptKey: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)   // prompts the user
  }
  ```
  Note: it runs `tccutil reset Accessibility <bundleId>` first — because the app is
  unsigned/ad-hoc-signed, its code identity changes across rebuilds and stale TCC
  grants must be cleared or the tap silently fails.
- **No** explicit Input Monitoring request (`IOHIDRequestAccess` /
  `CGRequestListenEventAccess`) in code. The CLI error text mentions "accessibility
  and input monitoring permissions" but only Accessibility is programmatically
  requested. `iss_init()` failure is retried every 1.0s (`retryIssInit`) until the
  user grants Accessibility and the tap can be created.
- UI paths (`ShortcutRecorderControl`, `PreferencesWindowController`) also guard on
  `AXIsProcessTrusted()` and, if untrusted, show an `NSAlert` that deep-links to
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.
- **Second, unrelated event tap** exists only for *recording* a hotkey in the UI
  (`Hotkeys/GlobalEventTapRecorder.swift`): `CGEvent.tapCreate(tap: .cgSessionEventTap,
  place: .headInsertEventTap, options: .defaultTap, ...)` masking keyDown + mouse-downs,
  returning `nil` to consume during recording. This is NOT part of the space-switch
  mechanism; global switch hotkeys use Carbon `RegisterEventHotKey` (signature
  `0x1111`), not this tap.

---

## 5. Swift ↔ C wiring & lifecycle (`AppDelegate.applicationDidFinishLaunching`)
Order:
1. `ensureAccessibilityPermission()`.
2. `iss_init()` (create tap); if it fails, `retryIssInit()` polls every 1s.
3. `if UserDefaults["swipeOverride"] { iss_set_swipe_override(true) }`.
4. `gestureSpeed = UserDefaults.double("gestureSpeed"); if > 0 { iss_set_gesture_speed(gestureSpeed) }`
   — **default C velocity is 2000.0** (`gestureSpeed` static in ISS.c) when unset.
   Settings UI (`GeneralSettingsViewController`) exposes named presets
   `["Normal","Fast","Faster","Fastest","Instant"]` → velocity values
   `[40.0, 50.0, 60.0, 80.0, 2000.0]`, defaulting to index 4 (2000.0 / "Instant").
   So lower values *keep* the slide animation but shorten it; only 2000.0 is truly
   instant.
5. `overlayDetectionEnabled` (default **true** if key absent) →
   `iss_set_overlay_detection_enabled(true)`.
6. `iss_set_switch_callback { newSpaceIndex in ... OSDWindow.shared.show(message: "\(newSpaceIndex + 1)") }`
   — OSD shows 1-based space number; callback fires on the main queue. The OSD is a
   borderless `.statusBar`-level `NSVisualEffectView` (`.hudWindow`) with
   `collectionBehavior = [.canJoinAllSpaces, .stationary]`, auto-hidden after
   `osdDurationMs` (default 200–500ms). It positions on the cursor's screen
   (`NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }`) and
   suppresses itself while Mission Control is active
   (`iss_is_mission_control_active()`) unless `showOSDInMissionControl` is set.
7. On `activeSpaceDidChangeNotification`: `refreshSpaceInfo()` + `iss_reset_predictions()`.

Hotkeys (Carbon `RegisterEventHotKey`, signature `0x1111`) map to:
`iss_switch(ISSDirectionLeft/Right)`, `iss_switch_to_index(0..9)`, and a
"last space" toggle. On any switch failure → `NSSound.beep()`. Not part of the
core mechanism but shows the public C API surface:
`iss_init`, `iss_destroy`, `iss_switch`, `iss_switch_to_index`,
`iss_get_space_info`, `iss_get_menubar_space_info`, `iss_set_swipe_override`,
`iss_set_gesture_speed`, `iss_set_overlay_detection_enabled`,
`iss_reset_predictions`, `iss_set_switch_callback`.

---

## 6. Multi-display handling
- Space topology read via `CGSCopyManagedDisplaySpaces(connection, displayIdentifier)`.
- Two display-selection modes:
  - **Cursor display** (`iss_get_space_info`, `useCursorDisplay=true`): current
    cursor location → `CGGetDisplaysWithPoint` → `CGDisplayCreateUUIDFromDisplayID` →
    `CFUUIDCreateString` → match against each display dict's `"Display Identifier"`.
  - **Menu-bar display** (`iss_get_menubar_space_info`, `useCursorDisplay=false`):
    `CGSCopyActiveMenuBarDisplayIdentifier(connection)`.
- Per-display current space is read from the display dict's `"Current Space" → "id64"`
  when present, falling back to global `CGSGetActiveSpace`. If the target display
  isn't found, falls back to the first display in the list.
- **Prediction dictionary is keyed per display UUID** (`displayID[128]` in
  `ISSSpaceInfo`) so each monitor tracks its own predicted index.

---

## 7. Gotchas / fragile bits
1. **Field index magic numbers** (55/110/123/124/129/130/132) and event-type values
   (`kCGSEventDockControl=30`, `kIOHIDEventTypeDockSwipe=23`,
   `kCGGestureMotion Horizontal=1`) are undocumented and could change with any macOS
   release. They currently hold 13→26 but are the most likely thing to break.
2. **`±FLT_TRUE_MIN` for progress is essential.** A larger progress value would run
   the animation; exactly-zero would be ignored (the interceptor also treats
   `progress == 0.0` as "not yet determined"). The near-denormal magnitude is what
   makes it instant. Do not "clean up" to `0.0`.
3. **All three phases (began→changed→ended) must be posted**, in that order, with no
   delay. Two phases break Mission Control state.
4. **Post to `kCGSessionEventTap`** (both post and tap). The tap is also placed at
   `kCGHeadInsertEventTap` and must be an **active** tap (`kCGEventTapOptionDefault`)
   so returning `NULL` actually suppresses.
5. **Tap can be auto-disabled.** Must handle `kCGEventTapDisabledByTimeout` /
   `kCGEventTapDisabledByUserInput` by calling `CGEventTapEnable(tap, true)` and
   returning the event — otherwise the override silently dies:
   ```c
   if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
       if (globalTap) CGEventTapEnable(globalTap, true);
       return event;
   }
   ```
6. **Real vs synthetic** relies on `kCGEventSourceUnixProcessID == 0` for real HID
   events. If you post with a source that yields pid 0 you'd re-trap your own events.
   ISS posts with `CGEventCreate(NULL)` (default source → nonzero pid), so its own
   synthetic events are passed through by the tap's pid check. This is load-bearing:
   the synthesizer and the interceptor coexist on the same tap location.
7. **Prediction staleness.** The OS's live active-space query lags right after a
   switch; ISS advances an optimistic per-display predicted index and only resets it
   on `activeSpaceDidChangeNotification`. Without this, rapid swipes overshoot/rebound.
8. **Run loop requirement.** Tap source must be on a live main CFRunLoop in
   `kCFRunLoopCommonModes`. A CLI one-shot still calls `iss_init()` then posts and
   exits (it does not need the tap for pure posting, but init creates it anyway).
9. **Unsigned-app TCC churn.** Ad-hoc signing means TCC identity changes per build;
   ISS proactively `tccutil reset Accessibility` before prompting. Expect to re-grant
   Accessibility after each rebuild in dev.
10. **Overlay detection is heuristic** (Dock window layers 18/20 counts) and marked
    "may not work in all cases" — used only to pass gestures through in Exposé and to
    hide the OSD in Mission Control.

---

## 8. Xcode/project configuration (SPM, not xcodeproj)
- Built with **Swift Package Manager** (`Package.swift`, swift-tools 5.9), not an
  `.xcodeproj`. Two executables: `InstantSpaceSwitcher` (GUI) and `ISSCli`.
- **No `.entitlements` file exists** in the repo. No hardened-runtime flags, no App
  Sandbox — an active session event tap is incompatible with the sandbox, and the app
  ships **ad-hoc signed** (`codesign --force --deep --sign -` in `dist/build.sh`), not
  notarized.
- `Info.plist` keys that matter:
  - `LSUIElement = true` (menu-bar/agent app, no Dock icon).
  - `LSMinimumSystemVersion = 13.0`.
  - `CFBundleIdentifier = com.interversehq.InstantSpaceSwitcher`.
  - `CFBundleShortVersionString = 2.0`, `CFBundleVersion = 2`.
  - Build injects a `GitCommitHash` string via PlistBuddy.
- Universal binary: arm64 + x86_64 built separately then `lipo`-merged.
- Frameworks linked: `ApplicationServices`, `CoreFoundation`, `IOKit`.

---

## 9. License (one line)
MIT License — Copyright (c) 2026 jurplel.
