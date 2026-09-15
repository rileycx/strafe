# strafe

Swiping between macOS desktop workspaces is a core part of how I personally work. I might have one Figma file open in fullscreen on one space, another open fullscreen in another space, and every other app that I am interacting with likely is in a fullscreen space dedicated to the app. It's how I prefer to work. I swipe between these tabs like a mad-man. I use this to reference a design, go back and forth between spaces quickly and frequently.

There's only one problem... If you work like this, you will know that whenever you 3-finger swipe between these spaces on macOS, there is a slight delay between when you swipe and when you can actually click on something post-swipe. That delay is slight. 150ms or so (I measured.) But 150ms fifty times in an hour is 7.5 seconds. 7.5 seconds each hour you work is about 60 seconds per day. It's death by a thousand cuts.

This is my contribution to the flow state.

— Riley Hennigh

---

When you swipe between macOS Spaces with three fingers, the system plays a
slide animation and queues your input until the transition finishes — roughly
half a second of dead time on every switch, during which clicks and keystrokes
go nowhere. strafe removes that dead time. It intercepts the swipe and jumps
straight to the neighboring Space, so the switch is instant and the new Space is
interactive immediately.

It runs as a menu-bar accessory (no Dock icon), works with your normal 3-finger
swipe, and adds keyboard shortcuts and a small CLI.

## See it

![Side-by-side: native macOS switching vs strafe](docs/media/demo-loop.gif)

## Time to interactivity

The number that matters: after you switch Spaces, how long until the landed
window actually accepts your input. macOS queues input until its transition
finishes; strafe collapses the transition, so the queue never builds.

Measured on a MacBook Pro (Apple M3 Pro, 18 GB, macOS 26.3), 20 trials per
mode, zero timeouts ([full video](docs/media/demo.mp4)):

| time to interactivity (median) | native swipe | with strafe |
|---|---|---|
| first event delivered to the landed window | 168.5 ms | 49.6 ms |
| transition complete (input unlocks) | 164.4 ms | 42.3 ms |

Native ranged 149–185 ms across trials; strafe ranged 30–79 ms — strafe's
slowest switch beat native's fastest by nearly half. Two honest caveats: the
native figures are a *lower bound* on what a human feels (the clock starts at
gesture start, and a real swipe adds your own finger-travel time on top), and
native duration grows with gentler swipe velocity — a variable strafe
eliminates entirely. Both modes are measured identically by the same harness.

Reproduce it yourself with the [bench harness](bench/), which documents the
full methodology and its caveats.

## Have your agent set it up

Copy this into Claude Code (or any coding agent) and it will handle everything
except the one click macOS reserves for you:

```text
Set up strafe (https://github.com/rileycx/strafe), a macOS utility that makes
Space switching instant. Steps:

1. Clone the repo and read SECURITY.md, then skim the source (~1,100 lines,
   no dependencies) and confirm the claims hold: the event tap mask covers
   only gesture events, and there is no network, subprocess, or file-write
   code. Tell me what you found before proceeding.
2. Run ./Scripts/bundle.sh and move build/strafe.app to /Applications.
3. Launch it, then open System Settings > Privacy & Security > Accessibility
   so I can grant it permission. Remove any stale strafe entries first.
4. Wait for me to confirm I granted it, then quit strafe from the menu-bar
   icon and relaunch it — the event tap is only created at launch, so the
   grant does nothing until the app restarts.
5. Have me test a 3-finger swipe between Spaces. It should be instant.
```

The audit step is not decoration: strafe asks for Accessibility, so make your
agent verify the code before you run it. It's small enough that it actually can.

## Credit

The instant space-switching technique strafe uses — synthesizing a
high-velocity Dock-swipe `CGEvent` with near-zero progress, and intercepting
your real trackpad swipe with an active event tap — was invented and first
implemented by **jurplel** in
[InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) (MIT).
The concept and the original implementation are entirely jurplel's work. strafe
is an independent reimplementation of that idea; if you want the original, go
give InstantSpaceSwitcher a star. See [LICENSE](LICENSE) for the full
acknowledgment and their copyright notice.

## Install

strafe is distributed as source only — there is no prebuilt binary to trust.
You build the code you can read.

```bash
git clone https://github.com/rileycx/strafe strafe && cd strafe
./Scripts/bundle.sh
```

This builds a release binary and assembles `build/strafe.app` (ad-hoc signed).
Then:

1. Drag `build/strafe.app` to `/Applications`.
2. Launch it. It will prompt for Accessibility permission.
3. Grant it in **System Settings › Privacy & Security › Accessibility**.

The app is about 1,080 lines of Swift and C with no third-party dependencies —
`swift build` finishes in seconds and you can read the whole thing. See
[SECURITY.md](SECURITY.md).


## Usage

- **3-finger swipe** — just works once strafe is running and has Accessibility.
  Swipe left/right between Spaces and the switch is instant.
- **Keyboard** — `ctrl`+`opt`+`←` and `ctrl`+`opt`+`→` switch Spaces.
- **Menu bar** — click the strafe icon to enable/disable interception or check
  whether Accessibility has been granted.
- **CLI:**

  ```
  strafe switch left|right   # switch once and exit
  strafe status              # print accessibility / tap status
  strafe                     # start the menu-bar app
  ```

## macOS 27 diagnostic build

This checkout now includes an experimental macOS 27 compatibility path. It uses
an embedded IOHID gesture payload and paced asynchronous posting. Physical
interception is restricted to horizontal HID23 gestures; ambiguous HID32 events
are logged in diagnostic mode but passed through. Live switching and time-to-interactivity
still need verification on the target machine; the macOS 26 measurements above
do not describe this build. See [the research report](docs/MACOS-27-RESEARCH.md).

Build with `./Scripts/bundle.sh`, quit any running Strafe instance, then run:

```bash
STRAFE_DIAGNOSTICS=1 ./build/strafe.app/Contents/MacOS/strafe 2>&1 | tee /tmp/strafe-macos27.log
```

Test Control + Option + Left/Right from a middle Space, one press at a time.
Diagnostics distinguish posted phases from an observed neighboring Space, or a
timeout. Indices in the logs are **zero-based**. The engine serializes requests
and waits for a stable live destination rather than counting unconfirmed moves.
This diagnostic policy includes 100 ms of destination stability before servicing
the next queued request; it is not the final rapid-switch latency tuning.

Options are read from the environment at launch:

| Variable | Values / default |
|---|---|
| `STRAFE_EVENT_PROFILE` | `auto` (macOS 27+ payload, older OS legacy), `legacy`, `macos27` |
| `STRAFE_PHASE_GAP_MS` | `0`–`100`; default `10` for macOS27, `0` for legacy |
| `STRAFE_INVERT_DIRECTION` | Defaults to `1` for augmented output, `0` for legacy; explicit `0`/`1` overrides |
| `STRAFE_INVERT_SWIPE_DIRECTION` | Defaults to `1` on macOS 27+, `0` earlier; independent physical-progress mapping |
| `STRAFE_INTERCEPT_SWIPES` | `1` (default); `0` leaves trackpad gestures native for hotkey-only testing |
| `STRAFE_DIAGNOSTICS` | `0` (default), `1` for request/gesture diagnostics |

Run `bash Scripts/test.sh` for non-posting serialization and mock-engine tests.
These tests work with Command Line Tools and do not require XCTest. The existing
`bench/` raw poster remains the **legacy** path; its timing results do not validate
the new asynchronous app path.

The initial live test confirmed instant switching but reversed output signs.
The current build corrects those signs separately from physical swipe progress,
and observes Dock's Accessibility Exposé notifications to pass Mission Control,
App Exposé and Show Desktop gestures through. Notification delivery and the
corrected mappings still require validation on the target machine.
If delivery times out, goes to an unexpected Space, or cannot be prepared,
trackpad interception is disabled automatically; it can be re-enabled from the
menu. Hotkeys remain available. For initial hotkey-only diagnosis, prefix the
launch command with `STRAFE_INTERCEPT_SWIPES=0`.

## Permissions

strafe needs **Accessibility** permission, and only that. macOS requires it to
create an *active* event tap — the kind that can suppress the slow animated
swipe and replace it with the instant one.

The tap sees only trackpad gesture and dock-control events. It does **not** see
keystrokes: the event mask excludes key events entirely, and strafe has no
network, telemetry, file access, or subprocess code. Every one of those claims
is grep-verifiable — see [SECURITY.md](SECURITY.md) for the exact file and line
pointers.

To revoke: **System Settings › Privacy & Security › Accessibility**, and toggle
strafe off (or remove it from the list).

## Uninstall

1. Quit strafe from its menu-bar menu.
2. Delete `strafe.app`.
3. Remove its entry from **System Settings › Privacy & Security ›
   Accessibility**.

That's everything. strafe writes no preferences, caches, or other files — there
is nothing else to clean up.

## How it works

macOS generates a "Dock swipe" event for a real 3-finger horizontal swipe.
strafe posts a synthetic one with an artificially near-zero *progress* and a
very high *velocity*. The high velocity makes the WindowServer treat the gesture
as a flick and skip the slide animation, jumping instantly to the neighboring
Space. At the same time an active event tap suppresses your real swipe so the OS
never runs its own animated version. For the field-by-field derivation, read
[docs/SPEC.md](docs/SPEC.md).

## Requirements

- macOS 15 or newer
- Apple Silicon (that is what strafe is built and tested on)

## License

MIT — Copyright (c) 2026 Riley Hennigh. See [LICENSE](LICENSE), which also
carries the acknowledgment and MIT notice for jurplel's InstantSpaceSwitcher.
