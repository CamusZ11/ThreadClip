#!/bin/bash
# Build a standalone macOS app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

case "${THREADCLIP_ARCH:-$(uname -m)}" in
  arm64|aarch64) architectures=(arm64) ;;
  x86_64) architectures=(x86_64) ;;
  universal) architectures=(arm64 x86_64) ;;
  *) echo "Unsupported macOS build architecture" >&2; exit 2 ;;
esac

product=ThreadClip
name=ThreadClip
output="$PWD/build/$name.app"
mkdir -p build
stage="$(mktemp -d "$PWD/build/.hanger.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/$name.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
executables=()

for architecture in "${architectures[@]}"; do
  triple="$architecture-apple-macosx14.0"
  build_args=(--scratch-path "$PWD/.build/arch-$architecture" -c release --triple "$triple")
  swift build "${build_args[@]}" --product "$product"
  native_dir="$(swift build "${build_args[@]}" --show-bin-path)"
  executables+=("$native_dir/$product")
done
if [[ "${#executables[@]}" == 1 ]]; then
  cp "${executables[0]}" "$bundle/Contents/MacOS/$product"
else
  lipo -create "${executables[@]}" -output "$bundle/Contents/MacOS/$product"
fi

cp LICENSE "$bundle/Contents/Resources/Tendedero-MIT-LICENSE.txt"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.camus.threadclip</string>
  <key>CFBundleName</key><string>ThreadClip</string>
  <key>CFBundleDisplayName</key><string>ThreadClip</string>
  <key>CFBundleExecutable</key><string>ThreadClip</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>Hanger</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

icons="$stage/Hanger.iconset"
mkdir -p "$icons"
swift scripts/make-icon.swift "$stage/icon.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$stage/icon.png" --out "$icons/icon_${size}x${size}.png" >/dev/null
  twice=$((2 * size))
  sips -z "$twice" "$twice" "$stage/icon.png" --out "$icons/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icons" -o "$bundle/Contents/Resources/Hanger.icns"

if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --sign "$APPLE_SIGNING_IDENTITY" "$bundle"
else
  printf '%s\n' "Signing the local bundle ad hoc. Set APPLE_SIGNING_IDENTITY for distribution." >&2
  codesign --force --sign - "$bundle"
fi
codesign --verify --deep --strict --verbose=2 "$bundle"

rm -rf "$output"
mv "$bundle" "$output"
printf '%s\n' "$output"
