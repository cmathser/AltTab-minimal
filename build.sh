#!/bin/sh
set -eu
cd "$(dirname "$0")"

app="$(pwd)/build/OptionTab.app"
obj_dir="$(pwd)/build/obj"
trap 'rm -rf "$obj_dir"' EXIT

mkdir -p "$app/Contents/MacOS" "$obj_dir"
cp Info.plist "$app/Contents/Info.plist"

clang -O2 -Wall -Wextra ${CLANG_FLAGS:-} -c Sources/ApplicationActivation.c -o "$obj_dir/ApplicationActivation.o"

swiftc -O -swift-version 5 -strict-concurrency=complete ${SWIFTC_FLAGS:-} \
  -import-objc-header Sources/ApplicationActivation.h \
  -framework AppKit -framework ApplicationServices \
  Sources/Models.swift \
  Sources/ShortcutStateMachine.swift \
  Sources/SwitcherOrdering.swift \
  Sources/AccessibilityService.swift \
  Sources/SwitcherPanelController.swift \
  Sources/OptionTab.swift \
  "$obj_dir/ApplicationActivation.o" \
  -o "$app/Contents/MacOS/OptionTab"

codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$app"
printf '%s\n' "$app"
