#!/bin/bash
set -euo pipefail

# The destination must be a new absolute path ending in .app.
# First build the embedded gateway with build-gateway.sh.
macos_dir="$(cd "$(dirname "$0")/.." && pwd)"
destination="${1:?Usage: bash build-app.sh /absolute/path/Commondev.app}"
gateway="${COMMONDEV_GATEWAY_DIR:-$macos_dir/.build/FreeLLMAPI}"
configuration="${COMMONDEV_BUILD_CONFIGURATION:-release}"

case "$destination" in /*.app) ;; *) echo "Destination must be an absolute .app path." >&2; exit 2;; esac
case "$configuration" in debug|release) ;; *) echo "COMMONDEV_BUILD_CONFIGURATION must be debug or release." >&2; exit 2;; esac
if [ -e "$destination" ]; then echo "Destination already exists: $destination" >&2; exit 2; fi
for file in node server.mjs gateway-entry.mjs; do
    if [ ! -f "$gateway/$file" ]; then
        echo "Missing gateway file $gateway/$file. Run build-gateway.sh first." >&2
        exit 1
    fi
done
if [ ! -x "$gateway/node" ]; then
    echo "Gateway Node executable is not executable: $gateway/node" >&2
    exit 1
fi
architecture="$(uname -m)"
if ! lipo -verify_arch "$architecture" "$gateway/node"; then
    echo "Gateway Node does not support this build machine's architecture ($architecture). Rebuild the gateway on this machine." >&2
    exit 1
fi
# Verify the actual packaged dependencies before creating an app. A gateway
# directory can contain Node and server.mjs yet be missing native modules, or
# contain modules for another architecture. Keep this smoke check offline and
# resolve modules from the gateway rather than the caller's working directory.
if ! env -i PATH=/usr/bin:/bin "$gateway/node" - "$gateway" <<'NODE'
const path = require('node:path');
const { createRequire } = require('node:module');
const gatewayRequire = createRequire(path.join(path.resolve(process.argv[2]), 'package.json'));
const Database = gatewayRequire('better-sqlite3');
const db = new Database(':memory:');
try {
  if (db.prepare('SELECT 1 AS value').get().value !== 1) throw new Error('SQLite smoke test failed');
} finally {
  db.close();
}
if (!gatewayRequire('sharp').versions?.vips) throw new Error('sharp/libvips unavailable');
NODE
then
    echo "Gateway dependencies failed to load. Rebuild the gateway for this machine." >&2
    exit 1
fi

# Keep the deployment target separate from the SDK used for AppKit's linked-on-or-after checks.
minimum_macos=13.0
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
swift build --package-path "$macos_dir" -c "$configuration" --product CommondevApp \
    -Xlinker -platform_version -Xlinker macos -Xlinker "$minimum_macos" -Xlinker "$sdk_version"
binary_dir="$(swift build --package-path "$macos_dir" -c "$configuration" --show-bin-path)"
if ! lipo -verify_arch "$architecture" "$binary_dir/CommondevApp"; then
    echo "Application does not support this build machine's architecture ($architecture)." >&2
    exit 1
fi
mkdir -p "$destination/Contents/MacOS" "$destination/Contents/Resources"
cp "$binary_dir/CommondevApp" "$destination/Contents/MacOS/CommondevApp"
cp -R "$binary_dir/Commondev_CommondevApp.bundle" "$destination/Contents/Resources/"
cp -R "$gateway" "$destination/Contents/Resources/FreeLLMAPI"
# Also support gateways built before the package-scope boundary was added.
cp "$macos_dir/Sources/Gateway/Resources/package.json" "$destination/Contents/Resources/FreeLLMAPI/package.json"
# Preserve upstream notices only for the exact arm64 libvips binary audited in
# this repository. This is a partial notice bundle, not a license clearance.
if [ "$architecture" = arm64 ]; then
    sharp_manifest="$gateway/node_modules/@img/sharp-libvips-darwin-arm64/package.json"
    sharp_binary="$gateway/node_modules/@img/sharp-libvips-darwin-arm64/lib/libvips-cpp.8.18.3.dylib"
    if [ -f "$sharp_manifest" ] && [ -f "$sharp_binary" ]; then
        sharp_version="$("$gateway/node" -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).version || "")' "$sharp_manifest")"
        sharp_hash="$(shasum -a 256 "$sharp_binary" | cut -d ' ' -f 1)"
        if [ "$sharp_version" = 1.3.2 ] && [ "$sharp_hash" = 50090a3a7c8f455de3c6cf2b274d231ddcc92901f4b1957c3b3391b6b9877989 ]; then
            mkdir -p "$destination/Contents/Resources/ThirdParty"
            cp -R "$macos_dir/ThirdParty/sharp-libvips-1.3.2" "$destination/Contents/Resources/ThirdParty/"
        else
            echo "Warning: unrecognised sharp-libvips binary; matching notices require review." >&2
        fi
    elif [ -f "$sharp_manifest" ]; then
        echo "Warning: unrecognised sharp-libvips binary; matching notices require review." >&2
    fi
fi
cat > "$destination/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CommondevApp</string>
<key>CFBundleIdentifier</key><string>dev.commondev.app</string>
<key>CFBundleName</key><string>commondev</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>$minimum_macos</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Микрофон нужен, чтобы надиктовать сообщение в чат commondev.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>commondev преобразует речь в черновик. Если на устройстве недоступно распознавание выбранного языка, macOS может использовать сервис Apple.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$destination"
codesign --verify --deep --strict "$destination"
echo "Built $destination"
