#!/bin/sh
set -eu
cd "$(dirname "$0")"

runner="${TMPDIR:-/tmp}/optiontab-tests.$$"
trap 'rm -f "$runner"' EXIT

swiftc -swift-version 5 -strict-concurrency=complete ${SWIFTC_FLAGS:-} \
  -framework AppKit -framework ApplicationServices \
  Sources/Models.swift \
  Sources/ShortcutStateMachine.swift \
  Sources/SwitcherOrdering.swift \
  Tests/RunTests.swift \
  -o "$runner"

"$runner"
