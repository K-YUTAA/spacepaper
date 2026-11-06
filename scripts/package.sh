#!/bin/zsh
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
"$project_dir/scripts/build.sh" --universal
cd "$project_dir/dist"
version="$(< "$project_dir/VERSION")"
asset="SpacePaper-${version}-universal.zip"
architectures="$(lipo -archs SpacePaper.app/Contents/MacOS/SpacePaper)"
[[ "$architectures" == *arm64* && "$architectures" == *x86_64* ]] || {
    print -u2 "The release must contain arm64 and x86_64"; exit 1
}
ditto -c -k --norsrc --noextattr --keepParent SpacePaper.app "$asset"
shasum -a 256 "$asset" > SHA256SUMS
print "Packaged: $project_dir/dist/$asset"
cat SHA256SUMS
