# Security

strafe holds macOS Accessibility permission and installs a system-wide event
tap. That is a lot of trust to ask for, so this document states exactly what
strafe can and cannot do, and how to verify every claim yourself. Every claim
below points at a file and line you can read or a command you can run.

The whole program is about **1,486 lines** of Swift + C (`wc -l Sources/**`).
You can build it from source in about 30 seconds (`swift build`) and audit it
in an afternoon.

**strafe ships no binaries.** It is distributed as source only — the only way
to run it is to compile the code you can read. There is no prebuilt artifact,
no download, and no update channel to trust. Updating means pulling this
repository and building again.

This is also why the CI configuration holds no secrets. GitHub Actions
(`.github/workflows/ci.yml`) runs with `permissions: contents: read`, builds,
and verifies an ad-hoc bundle — there is no signing identity or publishing
credential anywhere in this repository to steal.

---

## What strafe can do

strafe installs one active `CGEventTap` and holds Accessibility permission to
do so. The tap's event mask is defined in exactly one place, and it covers
**only gesture and dock-control events** — not keystrokes.

- **Tap mask definition:** `Sources/CStrafe/CStrafe.c`, function
  `strafe_tap_event_mask()` (line 289):

  ```c
  uint64_t strafe_tap_event_mask(void) {
      return (1ULL << kCGSEventGesture) | (1ULL << kCGSEventDockControl);
  }
  ```

  That is `(1<<29) | (1<<30)` — the two private trackpad-gesture event types
  and nothing else. There is no `kCGEventKeyDown`/`kCGEventKeyUp` bit. There is
  no second mask and no setting that widens this one.

- **Why keys are excluded — determination comment:** immediately above that
  function in `Sources/CStrafe/CStrafe.c` (the `KEY-EVENTS-IN-MASK
  DETERMINATION` block, lines 267–288) documents that an earlier revision
  masked key events, that they were never acted on, and that they were
  removed. The tap now wakes only on real space-swipe gestures.

- **The tap is installed here:** `Sources/strafe/SwipeInterceptor.swift`,
  `SystemSwipeEventTap.make`, called by `SwipeInterceptor.recoverIfNeeded`, using
  `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
  options: .defaultTap, eventsOfInterest: mask, ...)` where `mask` comes
  straight from `strafe_tap_event_mask()` above.

  A once-per-second timer checks Accessibility trust and the existing tap's
  validity and enabled state. It retries failed creation, recovers disabled
  taps, and releases invalid taps before replacing them. The timer reads no
  input events and never widens the mask. Disabling or tearing down the
  interceptor stops the timer.

**The system-wide gesture tap cannot observe what you type.**
A key event fails the `cgsType == dockControl || cgsType == gesture` guard
(`SwipeInterceptor.handle`, line 144) and is passed straight through, but in
practice a key event is never even delivered to the callback because it is not
in the tap's mask. The settings shortcut recorder receives key events only
while recording in strafe's own focused window. It saves the chosen key code
and modifier flags, not a history of input, and installs no global keyboard
monitor or additional event tap.

### Exactly what event data strafe touches

For the gesture events it does see, strafe reads a small fixed set of fields via
the wrappers in `Sources/CStrafe/CStrafe.c` (lines 221–242):

- CGS event type (field 55) — `strafe_event_cgs_type`
- IOHID gesture type (field 110) — `strafe_event_hid_type`
- swipe motion axis (field 123) — `strafe_event_swipe_motion`
- gesture phase (field 132) — `strafe_event_gesture_phase`
- swipe progress (field 124) — `strafe_event_swipe_progress`
- swipe velocity X (field 129) — `strafe_event_swipe_velocity_x`
- source process id — `strafe_event_source_pid`

That is the entire surface of event data strafe inspects: enough to tell a real
horizontal 3-finger space swipe from anything else, and its direction. No
coordinates, no window contents, no clipboard, no key codes.

On macOS 27 and later, `Sources/CStrafe/IOHIDPayload.c` also serializes synthetic
events in memory to attach the raw IOHID payload required by the Dock (field
4205). Its position, phase, progress, and velocity values come from the event
strafe constructs, not recorded trackpad data. This code is adapted from
joshuarli/iss (0BSD; see LICENSE). It adds no permissions, input event types,
network access, or file access. The real swipe's terminal event is passed
through with its motion cleared after a replacement switch so the Dock can
finish its gesture state. At the first or last Space, strafe suppresses the
entire blocked swipe, including its terminal event, to prevent a bounce-back.

Beyond the swipe event itself, strafe also calls `CGWindowListCopyWindowInfo`
(reading window owner names and layer numbers, to detect whether Exposé/Mission
Control is open so it can pass real swipes through — `strafe_is_expose_active`,
`Sources/CStrafe/CStrafe.c` line 295) and reads the current cursor location to
pick which display to switch on (`copy_cursor_display_identifier`, same file
line 112). Neither the window list nor the cursor position is stored or
transmitted; both are read, used for that one decision, and discarded.

On macOS 27 and later, a Dock-owned window at layer 20 is enough to detect
Mission Control; older systems keep the existing layer-18 requirement. This
uses the same window metadata and adds no permissions or data collection.

---

## What strafe never does

Each of these is verifiable with a single grep over `Sources/`.

- **No network code, at all.** strafe never opens a socket, makes an HTTP
  request, or resolves a host.

  ```
  grep -rniE 'URLSession|NSURL|Network|CFSocket|socket|curl|http://|https://' Sources/
  ```

  Zero hits.

- **No third-party dependencies.** `Package.swift` declares no `dependencies`
  and no `.package(...)` entries — only Apple system frameworks
  (`ApplicationServices`, `CoreFoundation`, `CoreGraphics`, `IOKit`). Read the
  35-line `Package.swift` in full.

- **No analytics or telemetry.** strafe writes only to the process's own
  `stderr` (`grep -rn FileHandle.standardError Sources/`) and `stdout` (the
  `strafe status` CLI readout in `Permissions.printStatus`, `Sources/strafe/Permissions.swift`
  line 28) — never to a network socket, a file, or an analytics sink. Nothing
  batches, serializes, or transmits usage.

- **No auto-update, and no update check.** strafe never downloads or executes
  anything. There is no updater, no Sparkle, no download URL, and nothing that
  asks a server whether a newer version exists (all covered by the network grep
  above). It cannot notify you of an update because it cannot reach the network
  at all; the menu bar just states the running version and where the source
  lives. Updating means pulling this repository and building again.

- **No dynamic loading.** strafe does not `dlopen`/`dlsym` anything. The private
  CGS symbols it uses are weak-imported at link time and guarded by an address
  check (`strafe_cgs_available`, `CStrafe.c` line 57):

  ```
  grep -rniE 'dlopen|dlsym' Sources/    # zero hits
  ```

- **No file access.** strafe opens no files. There are no `FileManager`,
  `contentsOfFile`, `fopen`, or write calls in `Sources/`
  (`grep -rniE 'FileManager|contentsOfFile|fopen|write\(toFile' Sources/` — zero
  hits). The one indirect exception is `UserDefaults`, which macOS backs with a
  plist — see the persistence bullet below.

- **No subprocess execution.** strafe spawns no processes. Unlike some prior
  art, it does **not** shell out to `tccutil` or anything else
  (`grep -rniE 'Process\(\)|/usr/bin|/bin/|tccutil' Sources/` — no spawns).

- **Persistence is limited to settings.** strafe stores no databases and no
  caches. Its `UserDefaults` values include `transitionSpeed` (the selected
  transition preset), `spaceHotkeysEnabled` (the keyboard-shortcut toggle), and
  `spaceShortcut.left` / `spaceShortcut.right` (a key code and modifier flags,
  or a cleared shortcut). See `TransitionSpeed.swift`, `HotkeyManager.swift`,
  and `KeyboardShortcut.swift`. These never widen the gesture tap's mask.
  Keyboard shortcuts use Carbon `RegisterEventHotKey`, a separate mechanism
  that delivers only registered shortcut activations.

  Reads and writes go through one accessor, so the two launch modes
  (`strafe.app` and the bare CLI, which has no bundle id) cannot land in
  different plists:

  ```
  grep -rn 'Preferences.store' Sources/   # settings and cache synchronization
  grep -rn 'UserDefaults(' Sources/       # one hit: the suite in Preferences.swift
  ```

  AppKit also saves menu-bar item visibility automatically when the icon is
  hidden or shown. strafe resets visibility on every fresh launch, so hiding
  the icon only lasts until the app is reopened or restarted.

  Changing the hotkey setting flushes the shared preference and posts a local
  `DistributedNotificationCenter` notification in the same login session.
  It carries no payload. A running strafe rereads its own preference and
  updates only its existing Carbon shortcut registrations; it does not accept
  commands or settings from notification data. This adds no network access or
  permissions.

  `strafe settings` sends a separate payload-free local notification to open
  the resident app's settings window. It cannot change settings or permissions.

  No usage data, no history, no coordinates are stored.
  Deleting `strafe.app` leaves behind only that plist, which
  `defaults delete com.rileycx.strafe` removes (see README → Uninstall).

---

## Why strafe needs Accessibility

macOS only allows a process to create an **active** session-level event tap
(one that can suppress or modify events) if that process is trusted for
Accessibility. strafe's whole mechanism is to intercept your real 3-finger
space swipe, suppress the slow animated version, and post a faster synthetic
dock swipe in its place — that requires an active tap, which requires
Accessibility. (How much faster is the **Transition speed** setting; at every
preset it is the same event family, posted to the same tap, and it changes
nothing about what strafe can see.) See `Sources/strafe/Permissions.swift` for
the trust check (`AXIsProcessTrusted` / `AXIsProcessTrustedWithOptions`), which
is the only permission strafe requests.

strafe does not request Input Monitoring, Full Disk Access, Screen Recording,
or any other permission.

---

## How to verify

```bash
git clone https://github.com/rileycx/strafe strafe && cd strafe

# 1. Build from source (~30s). No dependencies to resolve.
swift build

# 2. Count the codebase yourself.
wc -l Sources/strafe/*.swift Sources/CStrafe/CStrafe.c Sources/CStrafe/include/CStrafe.h

# 3. Confirm zero network / dynamic-loading / subprocess code.
grep -rniE 'URLSession|NSURL|Network|CFSocket|socket|curl|http://|https://|dlopen|dlsym' Sources/
grep -rniE 'Process\(\)|tccutil|/usr/bin|/bin/' Sources/

# 4. Confirm the tap mask excludes keystrokes, and that there is only one mask.
grep -rn 'strafe_tap_event_mask' Sources/

# 5. Confirm the one stored setting.
grep -rn 'Preferences.store' Sources/
```

For the deep dive on exactly which private CGEvent fields are used and why, read
`docs/SPEC.md`. Caveat: `docs/SPEC.md` documents the upstream reference
implementation strafe was reimplemented from — the `tccutil` call, the second
event tap, and the key-event masking it describes are upstream-only and
intentionally absent from strafe.

---

## Reporting a vulnerability

Please report security issues through GitHub's private vulnerability reporting:
open the repository's **Security** tab and choose **Report a vulnerability**.
This keeps the report private until a fix is available. There is no email
contact for security reports.
