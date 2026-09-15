# Security

strafe holds macOS Accessibility permission and installs a system-wide event
tap. That is a lot of trust to ask for, so this document states exactly what
strafe can and cannot do, and how to verify every claim yourself. Every claim
below points at a file and line you can read or a command you can run.

The program is a small Swift + C codebase (`wc -l Sources/strafe/*.swift Sources/CStrafe/*.{c,h} Sources/CStrafe/include/*.h`).
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
      return (1ULL << kCGSEventGesture) | (1ULL << kCGSEventDockControl)
          | (1ULL << kCGSEventFluidTouchGesture);
  }
  ```

  That is `(1<<29) | (1<<30) | (1<<31)` — the private trackpad-gesture event types
  and nothing else. There is no `kCGEventKeyDown`/`kCGEventKeyUp` bit. There is
  no second mask and no setting that widens this one.

- **Why keys are excluded — determination comment:** immediately above that
  function in `Sources/CStrafe/CStrafe.c` (the `KEY-EVENTS-IN-MASK
  DETERMINATION` block, lines 267–288) documents that an earlier revision
  masked key events, that they were never acted on, and that they were
  removed. The tap now wakes only on real space-swipe gestures.

- **The tap is installed here:** `Sources/strafe/SwipeInterceptor.swift`,
  `SwipeInterceptor.start()` (line 39; the `tapCreate` call itself is at
  line 54), using
  `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
  options: .defaultTap, eventsOfInterest: mask, ...)` where `mask` comes
  straight from `strafe_tap_event_mask()` above.

**Because keystrokes are not in the mask, strafe cannot observe what you type.**
A key event fails the `cgsType == dockControl || cgsType == gesture` guard
(`SwipeInterceptor.handle`, line 144) and is passed straight through, but in
practice a key event is never even delivered to the callback because it is not
in the tap's mask.

### Exactly what event data strafe touches

For the gesture events it does see, strafe reads a small fixed set of fields via
the wrappers in `Sources/CStrafe/CStrafe.c` (lines 221–242):

- CGS event type (field 55) — `strafe_event_cgs_type`
- IOHID gesture type (field 110) — `strafe_event_hid_type`
- swipe motion axis (field 123) — `strafe_event_swipe_motion`
- gesture phase (field 132) — `strafe_event_gesture_phase`
- swipe progress (field 124) — `strafe_event_swipe_progress`
- generic macOS 27 swipe progress (field 119) — `strafe_event_generic_progress`
- swipe velocity X (field 129) — `strafe_event_swipe_velocity_x`
- source process id — `strafe_event_source_pid`
- source user-data marker — `strafe_event_is_strafe`, to exclude our own output

That is the entire surface of event data strafe inspects: enough to tell a real
horizontal 3-finger space swipe from anything else, and its direction. No
coordinates, no window contents, no clipboard, no key codes.

Beyond the swipe event itself, strafe also calls `CGWindowListCopyWindowInfo`
(reading window owner names and layer numbers, to detect whether Exposé/Mission
Control is open so it can pass real swipes through — `strafe_is_expose_active`,
`Sources/CStrafe/CStrafe.c` line 295) and reads the current cursor location to
pick which display to switch on (`copy_cursor_display_identifier`, same file
line 112). Neither the window list nor the cursor position is stored or
transmitted; both are read, used for that one decision, and discarded.

`Sources/strafe/MissionControlMonitor.swift` also registers an Accessibility
observer on Dock for Exposé/Mission Control/Show Desktop entry and exit. It
tracks only overlay state, and reconnects if Dock relaunches. This uses the
existing Accessibility permission and does not observe application contents.

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
  ~line 28) and the `speed` / `mc-probe` CLI readouts — never to a network
  socket, a file, or an analytics sink. Nothing batches, serializes, or
  transmits usage. Opt-in `STRAFE_DIAGNOSTICS=1` logs gesture metadata (up to 64
  candidate samples), display/Space IDs, requested direction, phase timing and
  transition results to stderr. Errors are logged even without that option.
  A shell command using `tee` saves these diagnostics to a file chosen by the user.

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

- **No persistence beyond one menu setting.** strafe stores no databases and no
  caches. It writes exactly one `UserDefaults` value — `transitionSpeed`, an
  integer 0–2 recording which **Transition speed** preset you picked in the menu
  (`TransitionSpeed`, `Sources/strafe/TransitionSpeed.swift` line 101). It
  changes the shape of the gesture strafe *posts*; it has no effect on what the
  tap sees.

  Reads and writes go through one accessor, so the two launch modes
  (`strafe.app` and the bare CLI, which has no bundle id) cannot land in
  different plists:

  ```
  grep -rn 'Preferences.store' Sources/   # two hits, one key
  grep -rn 'UserDefaults(' Sources/       # one hit: the suite in Preferences.swift
  ```

  No usage data, no history, no coordinates — the plist holds one integer.
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
