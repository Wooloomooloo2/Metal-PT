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
# CFBundleVersion takes digits and dots only.
if [[ ! $version =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "make-app: VERSION ($version) must be like 1.2.3 (digits and dots)." >&2
    exit 1
fi

echo "==> swift build -c release --product MetalPT ($version)"
swift build -c release --product MetalPT
bin=$(swift build -c release --product MetalPT --show-bin-path)/MetalPT

app=build/Metal-PT.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Metal-PT"
# The template's __VERSION__ values are replaced as plist values (no sed: nothing in VERSION is treated as syntax).
plist="$app/Contents/Info.plist"
cp Resources/MetalPT/Info.plist "$plist"
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -replace CFBundleVersion -string "$version" "$plist"
if grep -q __VERSION__ "$plist"; then
    echo "make-app: $plist still has a __VERSION__ placeholder." >&2
    exit 1
fi
plutil -lint "$plist" > /dev/null
printf 'APPL????' > "$app/Contents/PkgInfo"
if [[ ! -f Resources/MetalPT/AppIcon.icns ]]; then
    swift scripts/make-icon.swift Resources/MetalPT
fi
cp Resources/MetalPT/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# Hardened runtime with an ad-hoc signature: Metal-PT runs /bin/launchctl and /usr/bin/log and reads IOKit/SMC,
# none of which the hardened runtime restricts.
if [[ $identity == - ]]; then
    label="ad hoc"
    timestamp=(--timestamp=none)   # an ad-hoc signature cannot be timestamped
else
    label=$identity
    timestamp=()                    # a real identity: codesign's default (a secure timestamp for Developer ID)
fi
echo "==> codesign ($label)"
codesign --sign "$identity" --force --deep --options runtime ${timestamp[@]+"${timestamp[@]}"} "$app"
codesign --verify --strict --verbose=1 "$app"

zip=build/Metal-PT-$version.zip
rm -f "$zip"
# No resource forks, extended attributes or quarantine bits from this machine in the release zip.
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$app" "$zip"
echo "==> $app"
echo "==> $zip ($(du -h "$zip" | cut -f1))"
