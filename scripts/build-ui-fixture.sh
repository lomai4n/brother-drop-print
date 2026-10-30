#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$project_dir/build/Drag Test Source.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$project_dir/build/Calibration.pdf" "$app_dir/Contents/Resources/Calibration.pdf"
swiftc -swift-version 5 "$project_dir/Tests/DragSource.swift" -framework AppKit \
  -o "$app_dir/Contents/MacOS/DragTestSource"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.brotherdropprint.drag-test-source</string>
<key>CFBundleName</key><string>V1.1 Drag Test Source</string>
<key>CFBundleExecutable</key><string>DragTestSource</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
