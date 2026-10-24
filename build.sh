#!/bin/sh
set -eu
cd "$(dirname "$0")"
app="$(pwd)/build/OptionTab.app"
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"
swiftc -O -swift-version 5 -framework AppKit -framework ApplicationServices Sources/OptionTab.swift -o "$app/Contents/MacOS/OptionTab"
codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$app"
printf '%s\n' "$app"
