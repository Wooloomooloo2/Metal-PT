#!/bin/bash
# Builds build/Metal-PT.app and build/Metal-PT-<version>.zip from a release build.
#
#     scripts/make-app.sh metal-pt [--sign IDENTITY]
#     scripts/make-app.sh helper                       # reserved for Metal-PT Helper (not yet)
#
# Without --sign the app is signed ad hoc (no Apple Developer ID): users approve it once in
# System Settings → Privacy & Security → Open Anyway. The version comes from the VERSION file, which must equal
# MetalPTVersion.current (Sources/MPTCore/Support/MetalPTVersion.swift); the script stops if they differ.
set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
    echo "usage: scripts/make-app.sh metal-pt [--sign IDENTITY]" >&2
    echo "       scripts/make-app.sh helper   (not yet)" >&2
    exit 2
}

[[ $# -ge 1 ]] || usage
target=$1
shift
identity="-"
while [[ $# -gt 0 ]]; do
    case $1 in
        --sign) [[ $# -ge 2 ]] || usage; identity=$2; shift 2 ;;
        *) usage ;;
    esac
done

case $target in
    metal-pt) ;;
    helper) echo "make-app: the Metal-PT Helper bundle is not yet built (coming later)."; exit 0 ;;
    *) usage ;;
esac

version=$(tr -d '[:space:]' < VERSION)
code_version=$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/MPTCore/Support/MetalPTVersion.swift)
if [[ -z $version || $version != "$code_version" ]]; then
    echo "make-app: VERSION ($version) differs from MetalPTVersion.current ($code_version); make them equal." >&2
    exit 1
fi

echo "==> swift build -c release --product MetalPT ($version)"
swift build -c release --product MetalPT
bin=$(swift build -c release --product MetalPT --show-bin-path)/MetalPT

app=build/Metal-PT.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Metal-PT"
sed "s/__VERSION__/$version/g" Resources/MetalPT/Info.plist > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" > /dev/null
printf 'APPL????' > "$app/Contents/PkgInfo"
if [[ ! -f Resources/MetalPT/AppIcon.icns ]]; then
    swift scripts/make-icon.swift Resources/MetalPT
fi
cp Resources/MetalPT/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# Hardened runtime with an ad-hoc signature: Metal-PT runs /bin/launchctl and /usr/bin/log and reads IOKit/SMC,
# none of which the hardened runtime restricts.
echo "==> codesign (${identity/-/ad hoc})"
codesign --sign "$identity" --force --deep --options runtime --timestamp=none "$app"
codesign --verify --strict --verbose=1 "$app"

zip=build/Metal-PT-$version.zip
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "==> $app"
echo "==> $zip ($(du -h "$zip" | cut -f1))"
