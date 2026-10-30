#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$project_dir/build"
encoder="$build_dir/Brother Drop Print.app/Contents/Resources/brother-encoder"
sources=()
for source in "$project_dir"/Sources/*.swift; do
  if [ "$(basename "$source")" != "main.swift" ]; then sources+=("$source"); fi
done
swiftc -O -swift-version 5 "${sources[@]}" "$project_dir/Tests/main.swift" \
  -framework AppKit -framework PDFKit -framework QuartzCore -framework CoreGraphics -framework ImageIO -framework CoreText -framework SystemConfiguration -o "$build_dir/core-tests"
"$build_dir/core-tests" "$encoder" "$build_dir/Calibration.pdf"
python3 "$project_dir/Tests/test_encoder.py" "$encoder"
