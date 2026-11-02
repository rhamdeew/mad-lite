#!/bin/sh
# Screenshot for docs/tutorial: starts MacAutoDiag.app with the given arguments, waits, captures
# the main window and saves a JPEG (1400 px wide).
#
#   tools/tutorial-shot.sh NAME SECONDS [app arguments…]
#   tools/tutorial-shot.sh 01-diag 25 firmware/j5/j5v05l19/J5V05L19.BIN --diag --rpm 2500
set -e
cd "$(dirname "$0")/.."
name=$1; wait=$2; shift 2
out=docs/tutorial/images; mkdir -p "$out"
pkill -f "MacAutoDiag.app/Contents/MacOS/MacAutoDiag" 2>/dev/null || true
tools/run-app.sh -- "$@" >/dev/null
sleep "$wait"
id=$(EDITION_NAME=$(sed -n 's/.*name = "\(.*\)".*/\1/p' Sources/VazCore/Edition.swift) swift - <<'SWIFT'
import CoreGraphics
import Foundation
let l = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]] // any Space
let name = ProcessInfo.processInfo.environment["EDITION_NAME"]!
let w = l.filter { ($0["kCGWindowOwnerName"] as? String) == name && ($0["kCGWindowLayer"] as? Int) == 0 }
    .max { a, b in
        let x = a["kCGWindowBounds"] as! [String: Double], y = b["kCGWindowBounds"] as! [String: Double]
        return x["Width"]! * x["Height"]! < y["Width"]! * y["Height"]! }
print(w?["kCGWindowNumber"] ?? "")
SWIFT
)
[ -n "$id" ] || { echo "окно не найдено"; exit 1; }
tmp=$(mktemp -t vazshot).png
screencapture -l "$id" -o -x "$tmp"
sips -Z 1400 -s format jpeg -s formatOptions 82 "$tmp" --out "$out/$name.jpg" >/dev/null
pkill -f "MacAutoDiag.app/Contents/MacOS/MacAutoDiag" 2>/dev/null || true
echo "$out/$name.jpg"
