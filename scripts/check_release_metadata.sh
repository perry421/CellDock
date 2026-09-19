#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
INFO_PLIST="$ROOT/Resources/Info.plist"
ENTITLEMENTS="$ROOT/Resources/CellDock.entitlements"

plutil -lint "$INFO_PLIST" >/dev/null
plutil -lint "$ENTITLEMENTS" >/dev/null

[[ "$(plutil -extract CFBundleIdentifier raw "$INFO_PLIST")" == "app.celldock.mac" ]]
[[ "$(plutil -extract CFBundleExecutable raw "$INFO_PLIST")" == "CellDock" ]]
[[ "$(plutil -extract LSMinimumSystemVersion raw "$INFO_PLIST")" == "14.0" ]]

version="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
build="$(plutil -extract CFBundleVersion raw "$INFO_PLIST")"
[[ "$version" == <->.<->.<-> ]]
[[ "$build" == <-> ]]

plutil -extract NSMicrophoneUsageDescription raw "$INFO_PLIST" >/dev/null
plutil -extract NSContactsUsageDescription raw "$INFO_PLIST" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$ENTITLEMENTS")" == "true" ]]

for language in zh-Hans en ja fr; do
  localization_dir="$ROOT/Resources/Localization/$language.lproj"
  plutil -lint "$localization_dir/Localizable.strings" >/dev/null
  plutil -lint "$localization_dir/InfoPlist.strings" >/dev/null
done

print "Release metadata valid: CellDock $version ($build)"
