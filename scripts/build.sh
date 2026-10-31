#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$project_dir/build"
app_name="Brother Drop Print"
bundle_identifier="org.brotherdropprint.app"
ui_element="false"
background_mode="false"
if [ "${1:-}" = "--background" ]; then
  app_name="Brother Drop Print Background"
  bundle_identifier="org.brotherdropprint.background"
  ui_element="true"
  background_mode="true"
elif [ "$#" -gt 0 ]; then
  printf 'Usage: %s [--background]\n' "$0" >&2
  exit 2
fi
app_dir="$build_dir/$app_name.app"
architecture="$(uname -m)"
cd "$project_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

clang++ -std=c++11 -O2 -Wall -Wextra -mmacosx-version-min=14.0 \
  -I vendor/brlaser/src \
  native/Encoder.cpp vendor/brlaser/src/job.cc vendor/brlaser/src/line.cc \
  -o "$app_dir/Contents/Resources/brother-encoder"

swiftc -O -swift-version 5 -target "$architecture-apple-macos14.0" \
  Sources/*.swift \
  -framework AppKit -framework PDFKit -framework CoreGraphics -framework ImageIO -framework QuartzCore -framework CoreText -framework SystemConfiguration \
  -o "$app_dir/Contents/MacOS/BrotherDropPrint"

cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_identifier</string>
<key>CFBundleName</key><string>$app_name</string>
<key>CFBundleDisplayName</key><string>$app_name</string>
<key>CFBundleExecutable</key><string>BrotherDropPrint</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2.3</string>
<key>CFBundleVersion</key><string>15</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><$ui_element/>
<key>BrotherDropPrintBackground</key><$background_mode/>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Printable documents</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array>
<string>com.adobe.pdf</string><string>public.png</string><string>public.jpeg</string>
<string>org.openxmlformats.wordprocessingml.document</string><string>com.microsoft.word.doc</string>
<string>org.openxmlformats.spreadsheetml.sheet</string><string>com.microsoft.excel.xls</string>
<string>org.openxmlformats.presentationml.presentation</string><string>com.microsoft.powerpoint.ppt</string>
<string>org.oasis-open.opendocument.text</string><string>org.oasis-open.opendocument.spreadsheet</string>
<string>org.oasis-open.opendocument.presentation</string><string>public.rtf</string><string>public.plain-text</string>
</array>
</dict></array>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>仅向你填写的打印机 IP 和端口发送打印数据。</string>
</dict></plist>
PLIST
swift scripts/make-icon.swift "$build_dir/AppIcon.iconset"
iconutil -c icns "$build_dir/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"

cp "$project_dir/LICENSE" "$app_dir/Contents/Resources/LICENSE"
cp "$project_dir/THIRD_PARTY.md" "$app_dir/Contents/Resources/THIRD_PARTY.md"
mkdir -p "$app_dir/Contents/Resources/Fonts"
cp "$project_dir"/assets/fonts/* "$app_dir/Contents/Resources/Fonts/"
codesign --force --deep --sign - "$app_dir"
printf '%s\n' "$app_dir"
