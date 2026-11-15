#!/bin/bash
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
source "$script_dir/common.sh"
[[ $# == 0 ]] || fail 'usage: uninstall.sh'
[[ -e "$installed_app" ]] || exit 0
verify_app "$installed_app"
"$installed_app/Contents/MacOS/deskhand-spike" unregister
rm -rf "$installed_app"
rm -f "$HOME/Applications/DeskhandSpike.receipt.json"
printf 'Removed app. Evidence and permission grants remain.\n'
