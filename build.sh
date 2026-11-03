#!/bin/sh
set -eu
cd "$(dirname "$0")"
app="$(pwd)/build/OptionTab.app"
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"
clang -O2 -c Sources/ApplicationActivation.c -o build/ApplicationActivation.o
swiftc -O -swift-version 5 -import-objc-header Sources/ApplicationActivation.h -framework AppKit -framework ApplicationServices Sources/OptionTab.swift build/ApplicationActivation.o -o "$app/Contents/MacOS/OptionTab"
codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$app"
printf '%s\n' "$app"
