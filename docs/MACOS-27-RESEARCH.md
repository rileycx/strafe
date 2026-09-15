# macOS 27 compatibility investigation

Research date: September 14, 2026. Checkout inspected: `31a240e`.
Local host: macOS **27.0 (26A428)**, arm64, SIP enabled.

## Conclusion

Strafe depends on undocumented gesture representations that changed in macOS 27.
Two independently actionable incompatibilities have been reported upstream:

1. **Incoming physical swipes:** a capture on this exact OS build found generic
   event type **29**, HID subtype **32**, progress field **119**, and potentially
   non-kernel source PIDs. Strafe only initiates switching from type **30**,
   HID subtype **23**, progress field **124**, with source PID zero.
2. **Outgoing synthetic swipes:** macOS 27 investigations found consumers requiring
   an embedded IOHID payload, added through CGEvent serialization. Strafe sets
   only the older numeric fields. A compatibility implementation exists, with
   successful switching reports on `26A428`.

These are not necessarily both active on every setup. In particular, the latest
physical-input investigation reports legacy numeric synthetic switching still
working on `26A428`. Do not infer that serialization is universally mandatory,
or that fixing output alone will restore physical swiping.

Instant-style switching remains plausible and has positive upstream reports.
Restoring Strafe's measured macOS 26 latency on this machine is **not yet verified**.
No live gestures were captured, no events posted, and no application code changed
during this investigation.

## What this checkout does

| Component | Current implementation | Compatibility risk |
|---|---|---|
| `Sources/CStrafe/CStrafe.c:64–91` | Three session-tap CGEvents: began/changed/ended, no gaps | Different representation or timing requirements |
| Same | Fields 55=30, 110=23, 123=1, 124=±FLT_TRUE_MIN, 129/130=±velocity, 132=phase | No embedded IOHID payload; extremely small progress |
| `Sources/strafe/SwitchEngine.swift:53–109` | Velocity 2000; topology bounds and optimistic target prediction | Posting success is not transition confirmation |
| `Sources/strafe/SwipeInterceptor.swift:38–79` | Event mask includes only 29 and 30 | Type31 cannot arrive at this tap |
| Same, `138–187` | Reject nonzero PID; treat type29 as companion; recognize type30/HID23 | Newly observed physical path passes through |
| `Sources/CStrafe/CStrafe.c:277–308` | Dock window layers 18/20 identify Mission Control/Exposé | Empirical overlay heuristic may require revalidation |
| `Sources/strafe/main.swift:104–109` | Reset predictions on Space-change notification | Helps actual changes, but not ignored requests |

Private CGS functions read Space topology; Strafe does not inject a scripting
addition into Dock or invoke a direct private Space-switch operation.

## Evidence and strength

### Physical-input change: particularly relevant to this host

[InstantSpaceSwitcher PR77][pr77], revision `4602184`, reports on macOS
`27.0 (26A428)`:

> generic type `29`, HID type `32`, with gesture phase in field `132` and
> fractional progress in field `119`

It also reports that macOS 27 gestures can have non-kernel PIDs. Its patch handles
types 29/30/31 and retains the kernel-PID restriction only for legacy type30.
Type31/HID23 uses the legacy horizontal motion/progress fields. Type29/HID32 is
the directly captured path; type31 has weaker hardware-validation evidence.

The PR reports a consumed synthetic type29/HID32 test, working menu switching,
and a physical capture. Those do not establish Strafe's end-to-end swipe latency.
The PR remains **open/unmerged**, and includes unrelated speed/defaults/process
management changes that should not be ported wholesale.

### Output representation: concrete workaround, mixed applicability

[ISS issue72][payload-report] documents both ISS and FasterSwiper breaking on
macOS 27, and describes the workaround:

1. Create and populate a CGEvent.
2. Serialize with `CGEventCreateData()`.
3. Insert an embedded IOHID queue/gesture payload under serialized field **4205**.
4. Recreate with `CGEventCreateFromData()` and post normally.

[Inspectable C implementation][serializer] exists on ISS's `macos-27` branch.
Its embedded progress/velocity use signed **16.16 fixed point**. `FLT_TRUE_MIN`
would truncate to zero; the implementation preserves a nonzero sign and uses
progress `0.000016`, encoded as one fixed-point unit (1/65536).

[PR88][pr88] adds 10 ms between phases and a 0.3-second CLI run-loop pump.
[A September 12 report][release-test] confirms left/right switching and the app
working on **26A428**. The PR remains **open/unmerged**.

However, [another report][derivative-report] required a resident process despite
the pump, and removed the branch's direction inversion. It reports 20/20 correct
switches and 51–66 ms timing in a derivative implementation on a beta. This is
encouraging, but is not a Strafe benchmark or a guarantee for the release build.

[A yabai fork][yabai-port] also ports the event-serialization fix. This is useful
cross-project corroboration, although it shares the same implementation lineage.

### Local binary inspection: what did NOT simply disappear

Read-only inspection of the installed CoreGraphics/SkyLight/Dock binaries found:

- CoreGraphics still re-exports all four topology symbols used here:
  `CGSMainConnectionID`, `CGSGetActiveSpace`, `CGSCopyManagedDisplaySpaces`,
  `CGSCopyActiveMenuBarDisplayIdentifier`.
- SkyLight still implements setters for fields 55/110/123/124/129/130/132.
  Progress and velocity are converted from double to **float** internally.
- Dock's `-[DOCKGestures handleDockControlEvent:]` still checks field110=23,
  reads field132, and dispatches fluid-gesture start/progress/end.
- Dock also calls WindowManager's `SpaceSwapSystemGesture` APIs, whose trackpad
  information exposes progress, velocityX, and natural-scrolling state.

This supports coexistence of gesture paths rather than wholesale removal of the
legacy constants. It does not prove which path handles this machine's events,
or when each path was introduced: no macOS 26 binary baseline was available.

Apple's [macOS 27 release notes][apple-notes] mention Dock/Mission Control fixes,
but do not document the field4205 or physical-event changes. The precise private
protocol findings come from developer investigations, not an Apple API contract.

## Recommended changes

### 1. Add macOS 27 input recognition independently of output selection

In `CStrafe.c`, its public header, and `SwipeInterceptor.swift`:

- Extend the gesture-only event mask to bits **29/30/31** (`0xe0000000`).
- Decode legacy 30/HID23, observed 31/HID23, and new 29/HID32 separately.
- Read progress119 for 29/HID32; preserve progress124 and horizontal motion123
  handling for the Dock-swipe paths.
- Do not reject every nonzero PID on the new input paths.
- Mark Strafe's synthetic events with `kCGEventSourceUserData` and ignore that
  marker before state-machine handling; retain an own-PID guard as appropriate.
  Verify the marker survives serialization and actual delivery.
- Avoid duplicate firing when companion representations describe one gesture.
- Validate vertical swipes, Mission Control/Exposé, cancellation and reversal:
  PR77 does not prove every 29/HID32 event is a horizontal Space swipe.

### 2. Introduce a reviewed macOS 27 output profile

Keep numeric and augmented output selectable during diagnosis. If raw legacy
output already works on this host, first establish whether the input patch alone
restores the desired behavior.

For augmented output, adapt the pinned ISS serializer and matching event builder,
not just one field from it. Important implementation constraints:

- Outer CGEvent format has a version prefix and big-endian field headers;
  embedded IOHID records use packed little-endian layouts on this architecture.
- Queue header is **28 bytes**, fluid gesture **40 bytes**, optional velocity
  child **28 bytes**: payload sizes are **68/96 bytes**, not padded structures.
- Field4205 stores the blob length in **bytes**. Validate field parsing, replace
  an existing payload rather than blindly duplicating it, and reject unexpected
  serialization formats.
- Fluid type remains **23**, output CGEvent type remains **30**. Type31 is an
  incoming-event compatibility path, not a replacement output type.
- Encode finite, range-checked 16.16 values; preserve nonzero progress sign.
- The upstream augmented builder also changes phase/position metadata and uses
  X velocity at Ended rather than copying Strafe's X/Y velocity into every phase.
- Treat direction inversion as unresolved. Test direction separately from
  topology bounds and physical-input sign; do not blindly invert the engine.
- Select using product OS version, not the `26A` build-number prefix.
- Preserve relevant MIT/Apache-2.0 notices when adapting upstream code, including
  FasterSwiper-derived material.

### 3. Schedule paced events without blocking interception

Strafe calls the engine synchronously inside its main-runloop tap callback.
Copying PR88's `usleep(10000)` there would block input interception.

Separate event construction from sequence scheduling. Enqueue a complete gesture,
return from the callback, and serialize asynchronous phase posting with measured
gaps. Prevent rapid requests from interleaving separate gestures. Two 10 ms gaps
add at least 20 ms before Ended; measure whether this is needed on the release OS.

For CLI use, keep the run loop alive until scheduled posting completes and allow
bounded observation of transition. A fixed sleep is not proof of delivery.
ISS's CLI creates a tap; Strafe's CLI does not, so its exact lifetime failure
explanation must not be transferred without testing.

### 4. Reconcile prediction and expose meaningful health

`CGEventPost` returns void. Current success means event allocation succeeded,
yet the engine advances its predicted index. An ignored post can therefore
create an imaginary edge and cause later swipes to be suppressed without moving.

- Distinguish queued, posted and observed transitions.
- Bound prediction lifetime and reconcile with live topology after failures or
  changed Space counts, while retaining rapid-switch support.
- Surface swallowed engine errors through bounded diagnostic counters/logging.
- Validate actual tap enablement with `CGEventTapIsEnabled`.
- Do not use CLI `status` as resident-app health: it currently always supplies
  `tapRunning: false` and only checks symbols/trust for the calling process.

## Validation order

1. Establish whether physical swipes, resident hotkeys and one-shot CLI differ.
   Normal animated swipes with working instant hotkeys strongly favor input decoding.
2. Capture only gesture metadata with interception disabled: type, HID subtype,
   PID, phase, motion, progress119/124 and velocities. Test horizontal/vertical.
3. From a middle Space, compare raw legacy output and augmented output independently
   of engine bounds/prediction. Test phase pacing separately.
4. Reintroduce interception, verify no self-interception or duplicate moves, then
   test rapid reversals, both edges, fullscreen apps, multiple displays and
   natural-scrolling direction.
5. Measure visible transition and destination input availability. A correct final
   Space ID, passing unit tests or successful event allocation is insufficient.
6. Verify the legacy profile on macOS 26 if a machine is available.

The existing benchmark can isolate raw synthesis, but its **native-mode setup
also uses Strafe's instant poster** to place windows. If that poster is broken,
native benchmark failure does not show that native-profile synthesis is broken.
Fix/setup-check that dependency before treating benchmark results as evidence.

## Sources

### Follow-up: first diagnostic build, local live test

The first augmented build produced instant workspace changes, confirming payload
acceptance on this host. Its uninverted output had the wrong direction:
`direction=left`, origin index1, target0 landed at index2; positive/right requests
landed one Space left. At index0 this made outward/inward edge handling disagree
with the movement the user intended. The revised output defaults to inversion
for augmented events, separately from the macOS27 physical-progress mapping.

The captured normal desktop stream was **type30/HID23**, horizontal motion1,
not exclusively type29/HID32. Generic HID32 appeared later during the user's
navigation/overlay testing. Its horizontal classification remains unproven, so
the revised interceptor logs but does not suppress it. Dock AX notifications
`AXExposeShowAllWindows`, `AXExposeShowFrontWindows`, `AXExposeShowDesktop`, and
`AXExposeExit` all registered successfully in a read-only local check; actual
notification delivery remains a live-test requirement. The old window-layer
heuristic is retained only as an additional snapshot check.

Mocked regression tests cover the observed reversed output convention, both
edges/inward recovery, physical input sign mapping, generic/vertical passthrough,
and overlay rejection/cancellation. These do not prove real OS behavior. The app
now restores native trackpad handling after failed replacement delivery.

[pr77]: https://github.com/jurplel/InstantSpaceSwitcher/pull/77
[payload-report]: https://github.com/jurplel/InstantSpaceSwitcher/issues/72#issuecomment-4663746037
[serializer]: https://github.com/jurplel/InstantSpaceSwitcher/blob/bf32cf9732c706119e8307d2d70ae795b2b11c1c/Sources/ISS/event_serialize.c
[pr88]: https://github.com/jurplel/InstantSpaceSwitcher/pull/88
[release-test]: https://github.com/jurplel/InstantSpaceSwitcher/pull/88#issuecomment-5644946567
[derivative-report]: https://github.com/jurplel/InstantSpaceSwitcher/issues/72#issuecomment-5277119315
[yabai-port]: https://github.com/agg23/yabai/commit/d0d387d1445048415fd1f3566393a191fe3c5097
[apple-notes]: https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes
