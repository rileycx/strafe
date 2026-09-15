# Strafe macOS 27 repair — agent handoff

## Resume here

**Update 2026-09-15:** second diagnostic build hotkey test **passed**.
`/tmp/strafe-macos27-v2.log` shows ~17/17 observed transitions correct in both
directions plus correct atEdge at index0 and index3, no timeouts/unexpected.
Startup was `inverted=true invertSwipeDirection=true interceptSwipes=false`.
User confirms hotkeys correct; trackpad swipes feel "disabled" = running at
native macOS speed. That is expected: this run forced `STRAFE_INTERCEPT_SWIPES=0`,
and the log's 64 candidate lines all show `override=false` passthrough.
Next: test with interception **enabled** (default). See command below.

```bash
STRAFE_DIAGNOSTICS=1 STRAFE_INTERCEPT_SWIPES=0 \
  ~/strafe/build/strafe.app/Contents/MacOS/strafe \
  2>&1 | tee /tmp/strafe-macos27-v2.log
```

From workspace 2, Control + Option + Left should go to workspace 1; after a
second, Control + Option + Right should return to workspace 2. Both should feel
instant. Leave interception disabled for this first test.

**Do not replace `/Applications/strafe.app` yet.** That remains the original app.
The new build is at `/Users/ozairkhan/strafe/build/strafe.app`.

## User intent and interaction constraints

- Restore instant **native macOS Spaces** switching after upgrading from macOS
  26 to 27, including trackpad gestures, fullscreen Spaces, correct boundaries,
  and Mission Control passthrough.
- User initially explicitly authorized delegation. Later clarified: subagents
  must be **GPT Sol, not Astra**. The available `task` tool did not expose model
  selection or IDs; we told the user we would stop spawning subagents without
  that control. Respect this constraint. Do not silently use inherited agents.
- User's usage budget is nearly exhausted; this document is for another agent
  to continue efficiently. Avoid repeating the research or dumping huge logs.
- User quits the app between tests. We incorrectly inferred that an absent
  process explained failed hotkeys; user corrected us. A `pgrep` snapshot after
  a test says nothing about whether it was running during the test.
- Keep updates concise. Do not declare the repair complete based on build/tests.
- No commits, pushes, PRs, or installation were requested/performed.

## Environment and working tree

- Repo: `/Users/ozairkhan/strafe`, HEAD at investigation start: `31a240e`.
- OS: macOS **27.0 (26A428)**, arm64, SIP enabled.
- Command Line Tools, SDK 26.5, Swift 6.3.3. Full Xcode/XCTest/Swift Testing modules
  are not available in this environment. `swift test` failed for missing XCTest;
  use the standalone test script described below.
- User had four workspaces and was usually on workspace 2. Latest read-only
  topology snapshot: display `37D8832A-2D66-02CA-B9F7-8F30A301B230`, zero-based
  index1, count4, current Space ID3.
- Repo was initially clean. All current application changes and added documents
  are this session's uncommitted work. Still inspect status before modifying.
- No app was running at the last process check before the second-build edits.
  User may have launched it since.

## What was established before implementing

Original Strafe intercepted gesture types29/30, recognized type30/HID23 with
motion123=1, required PID0, and read progress124. It synthesized three numeric
CGEvents (Began/Changed/Ended) at velocity2000 and ±FLT_TRUE_MIN, back-to-back.

The user demonstrated that both hotkeys did nothing but the internal prediction
counter advanced until `atEdge`. Hotkeys definitely reached the engine. The
running app had an enabled active gesture tap; TCC logs explicitly allowed
Accessibility, event listening and posting. CGS symbols still resolved. This
was not explained by missing hotkey registration or denied permissions.

`CGEventPost` returns void. The original engine treated successful event creation
as a successful switch and poisoned its optimistic prediction when OS ignored it.

Deep research is in `docs/MACOS-27-RESEARCH.md`. Key primary sources:

- ISS issue72 payload findings:
  https://github.com/jurplel/InstantSpaceSwitcher/issues/72#issuecomment-4663746037
- Pinned serializer/output branch:
  https://github.com/jurplel/InstantSpaceSwitcher/tree/bf32cf9732c706119e8307d2d70ae795b2b11c1c
- PR88 phase pacing and CLI lifetime:
  https://github.com/jurplel/InstantSpaceSwitcher/pull/88
- `26A428` success report:
  https://github.com/jurplel/InstantSpaceSwitcher/pull/88#issuecomment-5644946567
- PR77 input investigation, pinned `4602184328ec13b01e52e4456ad6ec3239df5152`:
  https://github.com/jurplel/InstantSpaceSwitcher/pull/77
- Conflicting upstream direction/lifetime report:
  https://github.com/jurplel/InstantSpaceSwitcher/issues/72#issuecomment-5277119315
- Dock AX overlay notifications reference:
  https://github.com/asmvik/yabai/blob/master/src/mission_control.c

macOS27 output can need an embedded serialized IOHID payload in field4205.
Outer CGEvent data uses a v2 prefix and big-endian field headers; payload is packed
little-endian, with signed16.16 progress and velocity. The minimal nonzero progress
is 1/65536, not FLT_TRUE_MIN. Two 10ms phase gaps have working reports. Related
projects disagree about output inversion, and some report legacy output still
working on release27. These are empirical private contracts, not Apple guarantees.

## First diagnostic build: real user findings

First build defaulted to augmented output, 10ms gaps, **inverted=false**, and
trackpad interception enabled (including generic29/HID32).

User reported:

1. First Left hotkey moved **right instantly**.
2. Subsequent navigation got worse, especially at the left edge; had to force quit.
3. It consumed unexpected actions inside Mission Control.
4. On a restart, a rightward trackpad gesture did move right, but edge behavior
   eventually failed again.

The available `/tmp/strafe-macos27.log` was overwritten by the later launch and
contains the trackpad session, not necessarily the initial keyboard session.
It has decisive evidence:

```text
direction=left  live index=1 target=0 -> actual index=2 unexpectedChange
direction=right live index=2 target=3 -> actual index=1 unexpectedChange
direction=right live index=1 target=2 -> actual index=0 unexpectedChange
direction=left  live index=0 target=edge -> atEdge
direction=right live index=0 target=1 -> posted but timeout at index0
```

Normal physical desktop swipes on **this machine** were type30/HID23, PID0,
motion1, progress124. Negative progress requested logical left in that build,
but the uninverted synthetic output moved right. Thus blindly fixing output
alone would also reverse the physical behavior that the user said felt correct.
The second build fixes **input and output mappings separately**.

The log also had vertical motion2 gestures, which were passed through, and later
generic29/HID32 events during the user's navigation/overlay experiments. We cannot
prove those generic events were all horizontal Space swipes. The second build
no longer intercepts them. Do not blindly re-enable PR77's broad HID32 rule.

## Current implementation (second diagnostic build)

### C event builder and topology

`Sources/CStrafe/CStrafe.c`, `include/CStrafe.h`, new `EventSerialization.h`:

- `strafe_create_switch_event(direction, velocity, phase, augmented, inverted)`
  returns a retained single CGEvent, without posting or sleeping.
- Augmented output uses numeric type30/HID23, motion1, progress magnitude0.000016,
  metadata fields134/125/138/169, Ended-only velocityX, plus embedded field4205.
- Payload: queue header28 bytes + fluid gesture40 + optional velocity child28;
  total68/96 bytes. Checked endian writes, fixed-point finite/range validation,
  v2 field validation, replacement of an existing4205, no silent fallback.
- Each built event gets own PID and a Strafe user-data marker. **On this host,
  CGEvent serialization omits source user data**, so the builder stamps it again
  after deserialization. Tests also found clearing user data on an event from
  the marked source can still read the source marker; physical test fixtures
  therefore use a fresh private CGEventSource. Actual delivered marker preservation
  is not independently proven; own-PID filtering is also retained.
- `strafe_post_switch_gesture()` remains a synchronous **legacy-only** triplet
  used by the old benchmark. It does not measure the new app path.
- Mask includes29/30/31, no keyboard events.
- Strict topology CF-type checks reject unknown current IDs/empty topology
  instead of silently mapping them to index0.
- `StrafeInfo` adds `currentSpaceID`.
- `strafe_get_space_info_for_display()` observes the exact original display.

### Async engine and configuration

`Sources/strafe/SwitchEngine.swift`, new `SwitchDiagnostics.swift`:

- Serial request queue capped at16 including active. Whole event triplets cannot
  interleave. Phases are scheduled asynchronously, not slept inside the tap.
- Reads real topology at execution; **no optimistic predictions remain**.
- Prebuilds all three events to avoid partial allocation failures, then posts them.
- Checks for a new Space ID at the expected adjacent index on the original
  display, stable100ms, within750ms after Ended. Polls every25ms.
- Missing topology, wrong destination, construction failure, timeout drops queued
  requests. New requests start from real state. Boundaries are real live checks.
- `resetPredictions()` is now a compatibility no-op. Notifications do not cancel
  valid in-flight work.
- Completion distinguishes enqueue/post/observed transition. Logs explicitly say
  `inputUnlock=unverified`; topology observation is not latency measurement.
- CLI pumps the main loop until completion, with a2-second outer deadline.
- A delivery-failure callback disables trackpad interception on unexpectedChange,
  observationTimedOut, postFailed, topologyUnavailable. Normal atEdge or overlay
  activity does not disable it. Hotkeys remain usable.

Environment configuration (strictly parsed at startup):

| Variable | Current default / values |
|---|---|
| `STRAFE_EVENT_PROFILE` | `auto`; resolves augmented on27+, legacy earlier. Also `legacy`, `macos27` |
| `STRAFE_PHASE_GAP_MS` | 10 for augmented, 0 legacy; explicit0–100 |
| `STRAFE_INVERT_DIRECTION` | **1 for augmented**, 0 legacy; explicit0/1 overrides |
| `STRAFE_INVERT_SWIPE_DIRECTION` | **1 on27+**, 0 earlier; independent of output profile |
| `STRAFE_INTERCEPT_SWIPES` | 1; use0 for the next hotkey-only test |
| `STRAFE_DIAGNOSTICS` | 0; use1 for logs |

Input and output defaults were changed after the first live test. Verify startup
logs show `inverted=true invertSwipeDirection=true` for the revised build.

### Swipe interceptor

`Sources/strafe/SwipeInterceptor.swift`:

- Only recognized horizontal HID23 type30 or31 streams are currently intercepted.
- **Generic29/HID32 is diagnostic-only passthrough**, even while owning a swipe.
- Type30 keeps nonzero-PID passthrough; own PID/marker bypass all gesture handling.
- On27+, negative physical progress maps to logical **right**, positive to left.
  This is separate from the synthetic builder's output inversion.
- Tracks owning gesture family; duplicate Began cannot reset/fire twice;
  companion endings cannot clear owner's latch.
- Resets after500ms idle between owned events, on toggling, tap disable, teardown.
- Vertical/unknown gestures pass through.
- Window-layer overlay scan only on Began (repeating on every Changed caused
  unacceptable potential tap overhead during review). Cached AX overlay state
  is cheap to check on every candidate.
- `isRunning` queries `CGEvent.tapIsEnabled` rather than an optimistic flag.
- Candidate diagnostics capped at64 samples. Handler admission errors capped8.

### Mission Control protection (new in second build)

New `Sources/strafe/MissionControlMonitor.swift`:

- Shared lock-protected overlay state, AX observer/runloop setup on main thread.
- Observes Dock's `AXExposeShowAllWindows`, `AXExposeShowFrontWindows`,
  `AXExposeShowDesktop`, `AXExposeExit`.
- Reattaches if Dock relaunches. Uses old layer heuristic as initial snapshot.
- Local read-only check successfully registered **4/4 notifications**, initial
  active=false. **Actual notification delivery during Mission Control is untested**.
- Interceptor passes through when active. Engine rejects queued switches while
  active; if it opens between synthetic phases, posts Cancelled before dropping
  the request. Polling aborts if an overlay opens.
- Monitor is started/stopped for GUI and CLI switching/status.
- If notifications fail to arrive, MC protection may still need work. A successful
  registration is not proof of delivery; starting while MC is already open still
  depends on the legacy snapshot heuristic.

### Other changes

- `main.swift`: validated config, CLI completion waiting, monitor lifecycle,
  delivery-failure hook, startup accessibility/tap status, fixed delegate lifetime
  and retained workspace observer token.
- `HotkeyManager.swift`: registration/handler errors use deferred diagnostics.
- `Permissions.swift`: CLI tap status explicitly says it is not resident status.
- `status` now prints live topology and overlay state.
- `Scripts/bundle.sh`: includes license files in bundle Resources.
- Added `THIRD-PARTY-LICENSES.txt`, `LICENSE-FasterSwiper.txt` for MIT ISS and
  Apache-2.0 FasterSwiper-derived code. Preserve these notices.
- README/SECURITY/research report updated with diagnostic behavior and caveats.

## Verification already completed

Latest command, after second-build fixes:

```bash
TMPDIR=/var/folders/16/swy3r08s34q762v41d7tyqb00000gn/T/opencode \
  bash Scripts/test.sh
bash Scripts/bundle.sh
codesign --verify --strict --verbose=2 build/strafe.app
git diff --check
```

All passed. Do not needlessly repeat before any new code change.

Tests:

- `Tests/CStrafeTests.c`:32 event round-trips, raw payload layout/replacement,
  marker/copy checks, malformed formats, invalid inputs/fixed-point limits, topology
  fixtures. Compiled with AddressSanitizer/UBSan, no findings.
- `Tests/SwitchEngineTests.swift`: standalone runner compiled alongside engine,
  diagnostics, monitor, interceptor with mock event delivery. **No events posted.**
  Nine tests cover config, timeout/pending-drop/failure-callback/recovery, ordered
  pacing/fixed-display observation, wrong destination, construction failure before
  any posting, true boundary, observed27 sign convention with both edges and
  inward movement, overlay rejection/cancellation, physical direction and
  generic/vertical/overlay passthrough.
- Tests use a fresh private CGEventSource for physical fixtures to avoid inheriting
  the synthetic marker; an earlier fixture incorrectly reused the marked source
  and failed before this correction.
- `Scripts/test.sh` works without XCTest. `Package.swift` has no net changes;
  the briefly attempted XCTest target was removed.
- Signed release artifact valid. Last bundle size after stripping:155352 bytes.

No automated live switching was performed by the agent. All reported real
switches came from the user testing the **first** diagnostic build.

## Next work, in order

1. **Get second-build hotkey results.** Read `/tmp/strafe-macos27-v2.log`. Confirm
   revised startup flags, phase posts, correct observed destination, latency as
   perceived by user. Logs use **zero-based** indices.
2. If directions are now correct, test both boundaries and inward return before
   introducing trackpad interception. Do not mistake real atEdge for a failure.
3. Check Mission Control entry/exit logs (`overlay active=... notification=...`)
   while interception is still off. Normal gestures should remain native. If AX
   notifications are absent, investigate before enabling broad interception.
4. Enable interception via Strafe's menu **Enable** (no restart needed), then
   test physical directions, boundaries, cancellation and Mission Control. If a
   failure disables interception, the log says so; subsequent native animation
   is expected, not proof that the patched fast path slowed down.
5. If sign mapping differs with natural scrolling/settings, use the independent
   input/output environment switches to isolate it. Never change topology index
   meaning to compensate for a raw gesture sign.
6. Once correct and stable, tune rapid switching and measure actual input unlock.
   The current100ms confirmation stability deliberately slows queued requests;
   this is a diagnostic policy, not the final performance goal.
7. Update/repair `bench/` before using it for new-path performance claims. Its
   strafe mode still calls legacy synchronous C posting, and native benchmark
   setup itself uses that legacy poster to place windows on Spaces.
8. Install only once user-tested. A moved/rebuilt ad-hoc app may need its
   Accessibility entry re-granted; do not reset permissions speculatively.

## Remaining risks worth keeping in mind

- All private payload conventions, AX notification behavior and direction mappings
  are empirical. We have demonstrated payload acceptance/instant movement, not
  complete correctness of the revised build.
- Current input sign default is based on this user's data; natural-scrolling
  interpretation may vary. Generic HID32 remains intentionally unowned.
- Overlay startup snapshot is still an old heuristic. Successful AX registration
  has been verified, but no live enter/exit capture yet.
- Async phases are prebuilt, so embedded timestamps are created close together,
  despite actual posting gaps. First build did switch instantly, but investigate
  timestamp refresh if pacing still behaves inconsistently; don't alter payload
  that already works without evidence.
- Cursor routing can change between phases. Engine rechecks before Began and
  observes original display; it cannot explicitly direct the OS to a display.
-500ms idle gesture recovery is a heuristic; test slow held swipes if needed.
- Fallback disables interception after delivery failure, but cannot replay an
  already suppressed physical Began. Later fresh swipes are native.
- The new serializer header lives under Sources/CStrafe and is used internally;
  standalone C tests include implementation to exercise private parser helpers.

## Useful commands

```bash
# Inspect state without switching.
git status --short
pgrep -fl strafe
STRAFE_DIAGNOSTICS=1 ~/strafe/build/strafe.app/Contents/MacOS/strafe status

# First revised test: hotkeys only, native trackpad still available.
STRAFE_DIAGNOSTICS=1 STRAFE_INTERCEPT_SWIPES=0 \
  ~/strafe/build/strafe.app/Contents/MacOS/strafe \
  2>&1 | tee /tmp/strafe-macos27-v2.log

# Non-posting tests / rebuild after changes.
bash Scripts/test.sh
bash Scripts/bundle.sh
codesign --verify --strict --verbose=2 build/strafe.app
```

If an app launched through Finder has no useful errors, its stdout/stderr likely
point to `/dev/null`; system logs do not recover those messages. The foreground
Terminal launch above captures them. Do not run a second resident copy while
testing hotkeys or gesture taps.
