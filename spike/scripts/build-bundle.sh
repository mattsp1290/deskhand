#!/bin/bash
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
source "$script_dir/common.sh"
[[ ${1:-} == --out && $# == 2 ]] || fail 'usage: build-bundle.sh --out DIR'
[[ ${DESKHAND_SIGN_IDENTITY:-} == "$identity" ]] || fail 'Set DESKHAND_SIGN_IDENTITY to the fixed signer SHA-1'
[[ ${DESKHAND_NOTARY_PROFILE:-} == deskhand-notary ]] || fail 'Set DESKHAND_NOTARY_PROFILE=deskhand-notary'
repo=$(cd "$script_dir/../.." && pwd)
[[ -z $(git -C "$repo" status --porcelain --untracked-files=normal) ]] || fail 'Build from a clean committed checkout'
mkdir -p "$2"
out=$(cd "$2" && pwd)
[[ ! -e "$out/DeskhandSpike.app" && ! -e "$out/DeskhandSpike.zip" ]] || fail 'Use a fresh output directory'
app="$out/DeskhandSpike.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchAgents"
swift build -c release --arch arm64 --package-path "$repo/spike"
bin=$(swift build -c release --arch arm64 --package-path "$repo/spike" --show-bin-path)
cp "$bin/deskhand-spike" "$app/Contents/MacOS/deskhand-spike"
cp "$repo/spike/Bundle/Info.plist" "$app/Contents/Info.plist"
cp "$repo/spike/Bundle/$bundle_id.agent.plist" "$app/Contents/Library/LaunchAgents/"
source_sha=$(git -C "$repo" rev-parse HEAD)
printf '{"source_sha":"%s","team":"%s","architecture":"arm64"}\n' "$source_sha" "$team" > "$app/Contents/Resources/BuildReceipt.json"
plutil -lint "$app/Contents/Info.plist" "$app/Contents/Library/LaunchAgents/$bundle_id.agent.plist"
[[ $(lipo -archs "$app/Contents/MacOS/deskhand-spike") == arm64 ]] || fail 'Unexpected architecture'
codesign --force --options runtime --timestamp --sign "$identity" "$app"
ditto -c -k --keepParent "$app" "$out/notary-upload.zip"
xcrun notarytool submit "$out/notary-upload.zip" --keychain-profile "$DESKHAND_NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
verify_app "$app"
ditto -c -k --keepParent "$app" "$out/DeskhandSpike.zip"
archive_sha=$(shasum -a 256 "$out/DeskhandSpike.zip" | awk '{print $1}')
executable_sha=$(shasum -a 256 "$app/Contents/MacOS/deskhand-spike" | awk '{print $1}')
printf '{"source_sha":"%s","team":"%s","architecture":"arm64","archive_sha256":"%s","executable_sha256":"%s"}\n' "$source_sha" "$team" "$archive_sha" "$executable_sha" > "$out/DeskhandSpike.receipt.json"
printf '%s\n' "$out/DeskhandSpike.zip" "$out/DeskhandSpike.receipt.json"
