#!/bin/zsh
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_image="$project_dir/assets/app-icon.png"
xcrun swift "$project_dir/scripts/export-icon.swift" "$project_dir/assets/icon-artwork.png" "$source_image"
iconset_dir="$project_dir/.work/AppIcon.iconset"
resources_dir="$project_dir/dist/SpacePaper.app/Contents/Resources"
[[ -f "$source_image" ]] || { print -u2 "Missing app icon: $source_image"; exit 1; }
mkdir -p "$iconset_dir" "$resources_dir"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$source_image" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    retina_size=$(( size * 2 ))
    sips -z "$retina_size" "$retina_size" "$source_image" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_dir" -o "$resources_dir/AppIcon.icns"
print "Built icon: $resources_dir/AppIcon.icns"
