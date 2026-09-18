#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d -t strafe-hotkey-tests)"
trap 'rm -rf "$test_dir"' EXIT
clang -target "$(uname -m)-apple-macosx15.0" -Wall -Wextra -Werror \
  -c Tests/HotkeyRegistrationStub.c -o "$test_dir/registration.o"
swiftc -swift-version 6 -target "$(uname -m)-apple-macosx15.0" \
  -strict-concurrency=complete -warnings-as-errors \
  Sources/strafe/KeyboardShortcut.swift Sources/strafe/HotkeyManager.swift Tests/HotkeyManagerTests.swift \
  "$test_dir/registration.o" -o "$test_dir/hotkeys"
python3 - "$test_dir/hotkeys" <<'PY'
import select
import subprocess
import sys
import uuid

binary = sys.argv[1]
domain = 'com.rileycx.strafe.hotkey-tests.' + uuid.uuid4().hex
listener = None
try:
    subprocess.run([binary, domain, 'selftest'], check=True)
    listener = subprocess.Popen([binary, domain, 'listen'], stdout=subprocess.PIPE, text=True)
    def expect(line):
        assert select.select([listener.stdout], [], [], 4)[0], 'Notification delivery timed out'
        actual = listener.stdout.readline().strip()
        assert actual == line, (line, actual)
    expect('ACTIVE 2')
    for value, expected in [('off', 0), ('on', 2), ('off', 0), ('on', 2)]:
        subprocess.run([binary, domain, value], check=True)
        expect('ACTIVE ' + str(expected))
    print('PASS: separate processes apply on/off changes without restarting')
finally:
    if listener is not None:
        listener.terminate()
        listener.wait(timeout=5)
    subprocess.run(['defaults', 'delete', domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PY
