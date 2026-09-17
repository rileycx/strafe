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

1. Clone the repo and read SECURITY.md, then skim the source (~1,486 lines,
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
You build the code you can read. That means you need Apple's command line tools
(`xcode-select --install`, a ~1.5 GB one-time download) and a Swift 6.3 or newer
toolchain.

```bash
git clone https://github.com/rileycx/strafe strafe && cd strafe
./Scripts/install.sh
```

`install.sh` builds `strafe.app`, copies it to `/Applications`, launches it, and
opens the Accessibility pane. Grant permission there, then quit strafe from its
menu-bar icon and launch it again — the event tap is created at launch, so the
grant does nothing until the app restarts.

Read the script first if you like; it's about 90 lines and does nothing
privileged.
If you'd rather do it by hand, `./Scripts/bundle.sh` just builds
`build/strafe.app` and leaves it there for you to drag over yourself.

One wrinkle worth knowing: the bundle is ad-hoc signed, and ad-hoc signatures
are content-based. Every rebuild looks like a *different* app to macOS, so
after you update you will have to re-grant Accessibility and delete the stale
entry from the list.

The app is about 1,486 lines of Swift and C with no third-party dependencies —
`swift build` finishes in seconds and you can read the whole thing. See
[SECURITY.md](SECURITY.md).


## Usage

- **3-finger swipe** — just works once strafe is running and has Accessibility.
  Swipe left/right between Spaces and the switch is instant.
- **Keyboard** — `ctrl`+`opt`+`←` and `ctrl`+`opt`+`→` switch Spaces.
- **Menu bar** — click the strafe icon to enable/disable interception, check
  whether Accessibility has been granted, and see which version you're running
  and where to get a newer one.
- **Transition speed** *(menu bar › Transition speed)* — if instant is too
  abrupt, you can trade some of it back for animation:

  | preset | measured | what it is |
  | --- | --- | --- |
  | Instant | ~40 ms | the default: no slide at all |
  | Quick | ~80 ms | a hint of motion |
  | Smooth | ~110 ms | a visible but short slide |

  Nothing slower is offered. The next step up measures ~170 ms, which is
  macOS's own animated switch — and that is already what you get with strafe
  turned off.

- **Hide from menu bar** *(menu bar › Hide from menu bar)* — hide the strafe
  icon from the menu bar. The app keeps running: swipes and shortcuts still work.
  To get the icon back, open strafe again.
- **CLI:**

  ```
  strafe switch left|right   # switch once and exit
  strafe status              # print accessibility / tap status
  strafe speed [preset]      # show or set transition speed
  strafe                     # start the menu-bar app
  ```

## Permissions

strafe needs **Accessibility** permission, and only that. macOS requires it to
create an *active* event tap — the kind that can suppress the slow animated
swipe and replace it with the instant one.

The tap sees only trackpad gesture and dock-control events. It does **not** see
keystrokes: the event mask excludes key events entirely, and strafe has no
network, telemetry, file access, or subprocess code. It stores exactly one
preference: which transition speed you picked. Every one of those claims is
grep-verifiable — see [SECURITY.md](SECURITY.md) for the exact file and line
pointers.

To revoke: **System Settings › Privacy & Security › Accessibility**, and toggle
strafe off (or remove it from the list).

## Uninstall

1. Quit strafe from its menu-bar menu.
2. Delete `strafe.app`.
3. Remove its entry from **System Settings › Privacy & Security ›
   Accessibility**.
4. If you ever changed the transition speed: `defaults delete com.rileycx.strafe`.

That's everything. strafe writes no caches, databases, or other files — that one
preference is the only thing it can leave behind.

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
