#!/bin/sh
# Builds the Mac Bluetooth test peer as a tiny .app (macOS only grants Bluetooth to apps with a usage description)
# and runs it. Usage: tools/mac-peer/run.sh <file containing the group code> [log file]
set -e
cd "$(dirname "$0")/../.."
APP=build/mac-peer/BlackoutMacPeer.app
mkdir -p "$APP/Contents/MacOS"
cp tools/mac-peer/Info.plist "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -module-name BlackoutMacPeer -o "$APP/Contents/MacOS/BlackoutMacPeer" \
  ios/BlackoutCore/Sources/BlackoutCore/*.swift ios/Blackout/BleLink.swift tools/mac-peer/main.swift
codesign --force -s - "$APP" >/dev/null
LOG="${2:-build/mac-peer/peer.log}"
: > "$LOG"
# Launched through `open` so macOS treats it as its own app for the Bluetooth permission.
open -n -W --stdout "$LOG" --stderr "$LOG" "$APP" --args "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
