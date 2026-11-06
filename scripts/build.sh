#!/bin/zsh
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
build_args=(--disable-sandbox --configuration release)
case "${1:-}" in
    "") ;;
    --universal) build_args+=(--arch arm64 --arch x86_64) ;;
    *) print -u2 "Usage: $0 [--universal]"; exit 2 ;;
esac
swift build "${build_args[@]}"
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"
app_dir="$project_dir/dist/SpacePaper.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/SpacePaper" "$app_dir/Contents/MacOS/SpacePaper"
/usr/bin/strip -S "$app_dir/Contents/MacOS/SpacePaper"
python3 - "$app_dir/Contents/Info.plist" "$project_dir/VERSION" <<'PY'
import plistlib, re, sys
from pathlib import Path
version = Path(sys.argv[2]).read_text().strip()
if not re.fullmatch(r'\d+\.\d+\.\d+', version):
    raise SystemExit('VERSION must contain a semantic version')
info = {
    'CFBundleIdentifier': 'local.kitano.spacepaper',
    'CFBundleName': 'SpacePaper', 'CFBundleDisplayName': 'SpacePaper',
    'CFBundleExecutable': 'SpacePaper', 'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': version, 'CFBundleVersion': version,
    'LSMinimumSystemVersion': '14.0', 'LSUIElement': True,
    'NSHighResolutionCapable': True,
}
Path(sys.argv[1]).write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
print "Built: $app_dir"
