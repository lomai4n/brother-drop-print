#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$project_dir/build"
encoder="$build_dir/Brother Drop Print.app/Contents/Resources/brother-encoder"
swiftc -O -swift-version 5 "$project_dir/Sources/Core.swift" "$project_dir/Sources/MenuBar.swift" "$project_dir/Tests/main.swift" \
  -framework AppKit -framework QuartzCore -framework CoreGraphics -framework ImageIO -framework CoreText -framework SystemConfiguration -o "$build_dir/core-tests"
"$build_dir/core-tests" "$encoder" "$build_dir/Calibration.pdf"
python3 "$project_dir/Tests/test_encoder.py" "$encoder"
