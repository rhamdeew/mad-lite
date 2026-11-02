#!/bin/sh
# Builds MacAutoDiag and starts it as a regular macOS app (MacAutoDiag.app via `open`), so it comes to
# the front and file panels behave normally. `swift run MacAutoDiag` starts a bare executable from
# the terminal: macOS 14+ keeps the terminal active, and the open panel showed up behind it.
#
#   tools/run-app.sh [release] [-- app arguments, e.g. firmware.bin --diag]
set -e
cd "$(dirname "$0")/.."
config=debug
if [ "$1" = "release" ]; then config=release; shift; fi
[ "$1" = "--" ] && shift
swift build -c "$config" --product MacAutoDiag
version=$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/VazCore/Version.swift)
edition_value() { sed -n "s/.*$1 = \"\(.*\)\".*/\1/p" Sources/VazCore/Edition.swift; }
app=".build/$config/MacAutoDiag.app"
mkdir -p "$app/Contents/MacOS"
# Remove first: copying over the old binary keeps its inode, the kernel keeps the old code
# signature cached for it, and the new launch is killed with "Code Signature Invalid".
rm -f "$app/Contents/MacOS/MacAutoDiag"
cp ".build/$config/MacAutoDiag" "$app/Contents/MacOS/MacAutoDiag"
# SwiftPM resources (calibration definitions): Bundle.module looks for them next to
# Bundle.main.bundleURL, i.e. in the .app folder itself.
for b in .build/"$config"/*.bundle; do [ -e "$b" ] && rm -rf "$app/$(basename "$b")" && cp -R "$b" "$app/"; done
# Finder/Dock icon: AppIcon.icns built from the 1024 px PNG.
icon_src=Sources/MacAutoDiag/Resources/AppIcon.png
icns="$app/Contents/Resources/AppIcon.icns"
if [ ! -e "$icns" ] || [ "$icon_src" -nt "$icns" ]; then
  mkdir -p "$app/Contents/Resources"
  iconset=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$iconset"
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz "$icon_src" --out "$iconset/icon_${sz}x${sz}.png" >/dev/null
    sips -z $((sz * 2)) $((sz * 2)) "$icon_src" --out "$iconset/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$icns"
  rm -rf "$(dirname "$iconset")"
fi
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>MacAutoDiag</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$(edition_value bundleID)</string>
  <key>CFBundleName</key><string>$(edition_value name)</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Relative paths in arguments are relative to here, not to the app bundle. Arguments are
# rebuilt in place so paths with spaces («Documents/MacAutoDiag/Logs/…») stay whole.
for a in "$@"; do
  shift
  case "$a" in -*) ;; *) [ -e "$a" ] && a="$(cd "$(dirname "$a")" && pwd)/$(basename "$a")" ;; esac
  set -- "$@" "$a"
done
open -n "$app" --args "$@"
