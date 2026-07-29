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
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$BINARY" "$BUNDLE/Contents/MacOS/iPhone"

# The manifest is read before anything runs: it says what the plugin is and
# what it claims, so the host can refuse it without executing a line of it.
cat > "$BUNDLE/manifest.json" <<JSON
{
  "id": "com.tc4mac.sample.iphone",
  "displayName": "iPhone photos (sample)",
  "version": "1.0.0",
  "minHostVersion": "0.1.0",
  "types": ["filesystem"],
  "schemes": ["iphone"]
}
JSON

echo "built $BUNDLE"
echo "install it with Configuration ▸ Plugins ▸ Install…, then switch it on."
