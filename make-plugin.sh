#!/bin/bash
# Builds the plugin and assembles iPhone.tcplugin — the bundle you install with
# Configuration ▸ Plugins ▸ Install… in tc4mac.
#
#   ./make-plugin.sh            release build (what you would ship)
#   ./make-plugin.sh debug      faster build, for iterating
set -euo pipefail
CONFIG="${1:-release}"
BUNDLE="iPhone.tcplugin"

swift build -c "$CONFIG"
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/IPhonePlugin"
[ -x "$BINARY" ] || { echo "no executable at $BINARY"; exit 1; }

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

# A minimal Info.plist makes the .tcplugin a REAL macOS bundle, which is what
# lets codesign sign it and seal the manifest (the host reads the manifest
# from Contents/Resources — a signable location — since tc4mac 0.2.0).
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIconFile</key>
	<string>tcplugin</string>
	<key>CFBundleExecutable</key>
	<string>iPhone</string>
	<key>CFBundleIdentifier</key>
	<string>com.tc4mac.sample.iphone</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
</dict>
</plist>
PLIST
cp "$BINARY" "$BUNDLE/Contents/MacOS/iPhone"

# The manifest is read before anything runs: it says what the plugin is and
# what it claims, so the host can refuse it without executing a line of it.
cp "$(dirname "$0")/tcplugin.icns" "$BUNDLE/Contents/Resources/tcplugin.icns"

cat > "$BUNDLE/Contents/Resources/manifest.json" <<JSON
{
  "id": "com.tc4mac.sample.iphone",
  "displayName": "iPhone",
  "version": "1.0.0",
  "minHostVersion": "0.1.0",
  "types": ["filesystem"],
  "schemes": ["iphone"]
}
JSON

# Bundle the libimobiledevice tools and every non-system library they load, so
# the plugin runs on a Mac WITHOUT Homebrew. The tools go beside the plugin
# executable (AFCSource.tool looks there first); the libraries go in
# Contents/Frameworks, rewired to find each other there instead of in
# /opt/homebrew. Build machine needs: brew install libimobiledevice.
TOOLS=(afcclient idevice_id ideviceinfo)
MACOS="$BUNDLE/Contents/MacOS"
FRAMEWORKS="$BUNDLE/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"

# Non-system libraries a Mach-O file links against, one path per line.
brew_libs() { otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -E '^/(opt|usr/local)/' || true; }

for tool in "${TOOLS[@]}"; do
  src="$BREW/bin/$tool"
  [ -x "$src" ] || { echo "missing $src — brew install libimobiledevice"; exit 1; }
  cp -L "$src" "$MACOS/$tool"
  chmod u+w "$MACOS/$tool"
done

# The closure of libraries, followed transitively.
pending=()
for tool in "${TOOLS[@]}"; do while read -r lib; do pending+=("$lib"); done < <(brew_libs "$MACOS/$tool"); done
while [ ${#pending[@]} -gt 0 ]; do
  lib="${pending[0]}"; pending=("${pending[@]:1}")
  name="$(basename "$lib")"
  [ -e "$FRAMEWORKS/$name" ] && continue
  cp -L "$lib" "$FRAMEWORKS/$name"
  chmod u+w "$FRAMEWORKS/$name"
  while read -r dep; do pending+=("$dep"); done < <(brew_libs "$FRAMEWORKS/$name")
done

# Rewire: tools find libraries in ../Frameworks, libraries find each other
# beside themselves. Matched by file name, whatever Homebrew path was used.
rewire() {
  local file="$1" prefix="$2"
  while read -r dep; do
    install_name_tool -change "$dep" "$prefix/$(basename "$dep")" "$file" 2>/dev/null
  done < <(brew_libs "$file")
}
for tool in "${TOOLS[@]}"; do rewire "$MACOS/$tool" "@executable_path/../Frameworks"; done
for lib in "$FRAMEWORKS"/*.dylib; do
  install_name_tool -id "@loader_path/$(basename "$lib")" "$lib" 2>/dev/null
  rewire "$lib" "@loader_path"
done

# The licenses travel with the libraries (LGPL-2.1 for libimobiledevice and
# its companions, Apache-2.0 for OpenSSL): unmodified upstream builds, source
# at https://libimobiledevice.org and https://www.openssl.org.
LICENSES="$BUNDLE/Contents/Resources/ThirdPartyLicenses"
mkdir -p "$LICENSES"
for formula in libimobiledevice libusbmuxd libimobiledevice-glue libplist openssl@3; do
  prefix="$(brew --prefix "$formula" 2>/dev/null)" || continue
  for notice in COPYING COPYING.LESSER LICENSE.txt; do
    [ -f "$prefix/$notice" ] && cp "$prefix/$notice" "$LICENSES/$formula-$notice"
  done
done

# install_name_tool voids the original signatures: every nested binary is
# re-signed, libraries first (inside-out), or it will not even run on arm64.
sign_nested() {
  if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$1"
  else
    codesign --force --sign - "$1"
  fi
}
for lib in "$FRAMEWORKS"/*.dylib; do sign_nested "$lib"; done
for tool in "${TOOLS[@]}"; do sign_nested "$MACOS/$tool"; done

# Sign when an identity is provided — a Developer-ID-signed bundle loads in
# tc4mac without the per-plugin Trust Anyway… override:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./make-plugin.sh
if [ -n "${SIGN_IDENTITY:-}" ]; then
  # The camera entitlement is REQUIRED: hardened runtime silently denies
  # camera-class devices (the iPhone, per ImageCaptureCore) without it —
  # the device browser then finds nothing, forever, with no error.
  codesign --force --options runtime --timestamp \
    --entitlements plugin.entitlements --sign "$SIGN_IDENTITY" "$BUNDLE"
  codesign --verify --strict "$BUNDLE"
  echo "signed as: $SIGN_IDENTITY"
fi

echo "built $BUNDLE"
echo "install it with Configuration ▸ Plugins ▸ Install…, then switch it on."
