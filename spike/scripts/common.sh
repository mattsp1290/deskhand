#!/bin/bash
set -euo pipefail
bundle_id=homes.birb.deskhand
team=QV7QZ68XH2
identity=23F09E197A3C0CB477D4FC48FA7AA022317DAF48
installed_app="$HOME/Applications/DeskhandSpike.app"
fail() { printf '%s\n' "$*" >&2; exit 1; }
verify_app() {
  local app=$1 facts cert_dir cert_hash
  [[ -d "$app" && ! -L "$app" ]] || fail "Expected an app directory: $app"
  [[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist") == "$bundle_id" ]] || fail 'Wrong bundle identifier'
  [[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Contents/Info.plist") == deskhand-spike ]] || fail 'Wrong executable'
  /usr/bin/codesign --verify --deep --strict "$app"
  facts=$(/usr/bin/codesign -d --verbose=4 "$app" 2>&1)
  [[ "$facts" == *"TeamIdentifier=$team"* && "$facts" == *'Authority=Developer ID Application: Matthew Spurlin (QV7QZ68XH2)'* && "$facts" == *'runtime)'* ]] || fail 'Expected the fixed Developer ID team and hardened runtime'
  cert_dir=$(mktemp -d /tmp/deskhand-certificate.XXXXXX)
  if ! /usr/bin/codesign --display --extract-certificates="$cert_dir/leaf" "$app"; then
    rm -rf "$cert_dir"
    fail 'Cannot extract signing certificate'
  fi
  cert_hash=$(shasum -a 1 "$cert_dir/leaf0" | awk '{print toupper($1)}')
  rm -rf "$cert_dir"
  [[ "$cert_hash" == "$identity" ]] || fail 'Wrong signing certificate'
  verified_cdhash=$(printf '%s\n' "$facts" | awk -F= '$1 == "CDHash" {print $2}')
  [[ -n "$verified_cdhash" ]] || fail 'Missing signed code hash'
  /usr/bin/codesign --verify --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$team\"" "$app"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$app"
  /usr/bin/xcrun stapler validate "$app"
  [[ -f "$app/Contents/Resources/BuildReceipt.json" ]] || fail 'Missing signed build receipt'
}
