#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$project_dir/build"
app_dir="$build_dir/Brother Drop Print.app"
architecture="$(uname -m)"
cd "$project_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

clang++ -std=c++11 -O2 -Wall -Wextra -mmacosx-version-min=14.0 \
  -I vendor/brlaser/src \
  native/Encoder.cpp vendor/brlaser/src/job.cc vendor/brlaser/src/line.cc \
  -o "$app_dir/Contents/Resources/brother-encoder"

swiftc -O -swift-version 5 -target "$architecture-apple-macos14.0" \
  Sources/Core.swift Sources/MenuBar.swift Sources/main.swift \
  -framework AppKit -framework CoreGraphics -framework ImageIO -framework QuartzCore -framework CoreText -framework SystemConfiguration \
  -o "$app_dir/Contents/MacOS/BrotherDropPrint"

cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.brotherdropprint.app</string>
<key>CFBundleName</key><string>Brother Drop Print</string>
<key>CFBundleDisplayName</key><string>Brother Drop Print</string>
<key>CFBundleExecutable</key><string>BrotherDropPrint</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>仅向你填写的打印机 IP 和端口发送打印数据。</string>
</dict></plist>
PLIST

cp "$project_dir/LICENSE" "$app_dir/Contents/Resources/LICENSE"
cp "$project_dir/THIRD_PARTY.md" "$app_dir/Contents/Resources/THIRD_PARTY.md"
codesign --force --deep --sign - "$app_dir"
printf '%s\n' "$app_dir"
