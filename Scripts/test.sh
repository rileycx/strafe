#!/bin/bash
# Non-posting tests, including on machines with Command Line Tools only.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
swift build
BIN="$(swift build --show-bin-path)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/strafe-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  -fno-omit-frame-pointer -I Sources/CStrafe/include Tests/CStrafeTests.c \
  -framework ApplicationServices -framework CoreFoundation -o "$TMP/CStrafeTests"
"$TMP/CStrafeTests"
swiftc -swift-version 6 -target "$(uname -m)-apple-macosx15.0" \
  -I "$BIN/CStrafe.build" Sources/strafe/SwitchDiagnostics.swift \
  Sources/strafe/Preferences.swift Sources/strafe/TransitionSpeed.swift \
  Sources/strafe/SwitchEngine.swift Sources/strafe/MissionControlMonitor.swift \
  Sources/strafe/SwipeInterceptor.swift Tests/SwitchEngineTests.swift \
  "$BIN/CStrafe.build/CStrafe.c.o" -framework ApplicationServices \
  -framework CoreFoundation -framework AppKit -o "$TMP/SwitchEngineTests"
"$TMP/SwitchEngineTests"
