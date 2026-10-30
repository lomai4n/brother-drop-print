#!/bin/bash
# Regenerates the README images in docs/images. Briefly shows the panel and settings windows.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sources=()
for source in "$project_dir"/Sources/*.swift; do
  if [ "$(basename "$source")" != "main.swift" ]; then sources+=("$source"); fi
done
swiftc -swift-version 5 "${sources[@]}" "$project_dir/scripts/screenshots/main.swift" \
  -framework AppKit -framework PDFKit -framework QuartzCore -framework CoreGraphics -framework ImageIO \
  -framework CoreText -framework SystemConfiguration -o "$work/screenshots"
mkdir -p "$project_dir/docs/images"
"$work/screenshots" "$project_dir/docs/images" "$work"
