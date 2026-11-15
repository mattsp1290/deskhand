#!/bin/bash
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
source "$script_dir/common.sh"
[[ $# == 1 ]] || fail 'usage: install.sh /path/DeskhandSpike.app'
app=$1
verify_app "$app"
receipt="$(dirname "$app")/DeskhandSpike.receipt.json"
[[ -f "$receipt" ]] || fail 'Transfer the artifact receipt beside the app'
python3 - "$app" "$receipt" <<'PY'
import hashlib, json, pathlib, sys
app, receipt = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
r = json.loads(receipt.read_text())
b = json.loads((app/'Contents/Resources/BuildReceipt.json').read_text())
assert all(r[k] == b[k] for k in ('source_sha', 'team', 'architecture')), 'Receipt identity mismatch'
assert r['team'] == 'QV7QZ68XH2' and r['architecture'] == 'arm64'
assert hashlib.sha256((app/'Contents/MacOS/deskhand-spike').read_bytes()).hexdigest() == r['executable_sha256'], 'Executable digest mismatch'
archive = app.parent/'DeskhandSpike.zip'
if archive.exists():
 assert hashlib.sha256(archive.read_bytes()).hexdigest() == r['archive_sha256'], 'Archive digest mismatch'
PY
mkdir -p "$HOME/Applications"
stage=$(mktemp -d "$HOME/Applications/.deskhand-install.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/DeskhandSpike.app"
cp "$receipt" "$stage/DeskhandSpike.receipt.json"
verify_app "$stage/DeskhandSpike.app"
backup="$HOME/Applications/.DeskhandSpike.previous.app"
if [[ -e "$backup" ]]; then verify_app "$backup"; fi
if [[ -e "$installed_app" ]]; then
  verify_app "$installed_app"
  "$installed_app/Contents/MacOS/deskhand-spike" unregister
  if [[ -e "$backup" ]]; then
    mv "$installed_app" "$stage/displaced.app"
  else
    mv "$installed_app" "$backup"
  fi
fi
mv "$stage/DeskhandSpike.app" "$installed_app"
cp "$stage/DeskhandSpike.receipt.json" "$HOME/Applications/DeskhandSpike.receipt.json"
verify_app "$installed_app"
cli="$installed_app/Contents/MacOS/deskhand-spike"
if ! "$cli" register; then
  fail "Registration incomplete. The signed installation remains at $installed_app; rerun register after approval. Prior installation remains at $backup."
fi
for ((attempt=0; attempt<20; attempt++)); do
  if "$cli" agent-call ping > "$stage/ping.json"; then
    if python3 - "$stage/ping.json" "$installed_app" "$installed_app/Contents/Resources/BuildReceipt.json" "$verified_cdhash" <<'PY'
import json, sys
r=json.load(open(sys.argv[1])); c=r['context']
assert r['pong'] and c['launched_by']=='launch_agent' and c['team_id']=='QV7QZ68XH2'
assert c['bundle_path']==sys.argv[2]
assert c['build_receipt']==json.load(open(sys.argv[3]))
assert c['cdhash']==sys.argv[4]
PY
    then
      if [[ -e "$backup" ]]; then rm -rf "$backup"; fi
      printf 'Installed and agent reachable: %s\n' "$installed_app"
      exit 0
    fi
  fi
  sleep 1
done
fail 'Agent did not become reachable. Installation remains for inspection; prior bundle is preserved.'
