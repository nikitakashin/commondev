#!/bin/bash
set -euo pipefail

# Output is a fresh directory containing the local Node sidecar.
# Optionally use a verified local checkout through COMMONDEV_FREELLMAPI_SOURCE.
script_dir="$(cd "$(dirname "$0")" && pwd)"
output="${1:?Usage: bash build-gateway.sh /absolute/output/directory}"
case "$output" in /*) ;; *) echo "Output must be absolute." >&2; exit 2;; esac
if [ -e "$output" ]; then echo "Output already exists: $output" >&2; exit 2; fi

revision="82958f510873ab2a6b000d95beb552fe0edeb4cf"
node_version="22.22.0"
case "$(uname -m)" in
  arm64) node_arch=arm64; checksum=2bd596bbfc4a275ceb8721a5954ee97daea5ebe673e96a185ebd732f6fb023ac ;;
  x86_64) node_arch=x64; checksum=48bc437e00e0c1483da34c21dca196efcb8d22e5dcb0bc7c65386afb00fabb85 ;;
  *) echo "Unsupported architecture." >&2; exit 2 ;;
esac
temporary="$(mktemp -d "${TMPDIR:-/tmp}/commondev-gateway-build.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
mkdir -p "$temporary/source" "$temporary/node" "$temporary/tools"
if [ -n "${COMMONDEV_FREELLMAPI_SOURCE:-}" ]; then
  git -C "$COMMONDEV_FREELLMAPI_SOURCE" cat-file -e "$revision^{commit}"
  git -C "$COMMONDEV_FREELLMAPI_SOURCE" archive "$revision" | tar -xf - -C "$temporary/source"
else
  git -C "$temporary/source" init -q
  git -C "$temporary/source" fetch --quiet --depth 1 https://github.com/tashfeenahmed/freellmapi.git "$revision"
  git -C "$temporary/source" checkout --quiet --detach FETCH_HEAD
fi
archive="node-v$node_version-darwin-$node_arch.tar.xz"
curl --fail --location --silent --show-error "https://nodejs.org/dist/v$node_version/$archive" -o "$temporary/$archive"
printf '%s  %s\n' "$checksum" "$temporary/$archive" | shasum -a 256 -c -
tar -xJf "$temporary/$archive" -C "$temporary/node" --strip-components=1
export PATH="$temporary/node/bin:$PATH"
export npm_config_cache="$temporary/npm-cache"
(
  cd "$temporary/source"
  npm ci --workspace server --workspace shared --omit=dev --no-audit --no-fund
)
npm install --prefix "$temporary/tools" --no-audit --no-fund --save-exact esbuild@0.24.2
(
  # Stable source-relative paths in the metafile also avoid recording the
  # machine-specific temporary build directory in the shipped artifact.
  cd "$temporary/source"
  "$temporary/tools/node_modules/.bin/esbuild" desktop/src/server-host.ts \
    --bundle --platform=node --format=esm --target=node20 \
    --external:better-sqlite3 --external:sharp \
    --banner:js="import { createRequire as __createRequire } from 'node:module'; const require = __createRequire(import.meta.url);" \
    --metafile=../server-metafile.json --outfile=../server.mjs
)
node "$script_dir/inventory-bundle.mjs" "$temporary/server-metafile.json" \
  "$temporary/source" "$temporary/server.mjs" > "$temporary/server-input-inventory.json"

mkdir -p "$(dirname "$output")"
mkdir "$output"
cp "$temporary/node/bin/node" "$output/node"
cp "$temporary/server.mjs" "$output/server.mjs"
cp "$temporary/server-metafile.json" "$output/server-metafile.json"
cp "$temporary/server-input-inventory.json" "$output/server-input-inventory.json"
cp "$script_dir/../Sources/Gateway/Resources/gateway-entry.mjs" "$output/gateway-entry.mjs"
# Stop Node's package-scope lookup inside the signed bundle, instead of
# searching parent directories that may require macOS privacy permissions.
cp "$script_dir/../Sources/Gateway/Resources/package.json" "$output/package.json"
cp "$temporary/source/LICENSE" "$output/LICENSE-FreeLLMAPI"
cp "$temporary/node/LICENSE" "$output/LICENSE-Node"
cp -R "$temporary/source/node_modules" "$output/node_modules"
# Workspace packages are bundled in server.mjs; npm's links point outside the
# copied node_modules tree and would leave dangling links in the app bundle.
for workspace_link in "$output/node_modules/@freellmapi/server" "$output/node_modules/@freellmapi/shared"; do
  if [ -L "$workspace_link" ]; then unlink "$workspace_link"; fi
done
printf '%s\n' "$revision" > "$output/FREELLMAPI_REVISION"
echo "Built FreeLLMAPI gateway for $node_arch at $output"
