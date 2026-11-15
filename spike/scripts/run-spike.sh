#!/bin/bash
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
source "$script_dir/common.sh"
usage() { printf '%s\n' 'usage: run-spike.sh --selfcheck | --host NAME [--out ROOT] [--remote [USER@HOST]] --automatic | --trial NAME [--path P] [--count N]'; }
if [[ ${1:-} == --selfcheck && $# == 1 ]]; then
  repo=$(cd "$script_dir/../.." && pwd)
  swift build --package-path "$repo/spike"
  swift test --package-path "$repo/spike"
  swift format lint --strict --recursive "$repo/spike"
  bin=$(swift build --package-path "$repo/spike" --show-bin-path)
  "$bin/deskhand-spike" selfcheck
  "$bin/deskhand-spike" probe list
  "$bin/deskhand-spike" trial list
  exit 0
fi
host=''
out="$script_dir/../../docs/spike-results"
remote=''
operation=''
trial_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --host) [[ $# -ge 2 ]] || fail 'Missing host'; host=$2; shift 2 ;;
    --out) [[ $# -ge 2 ]] || fail 'Missing output root'; out=$2; shift 2 ;;
    --remote)
      remote=punk1290@10.0.0.96; shift
      if [[ $# -gt 0 && $1 != --* ]]; then remote=$1; shift; fi ;;
    --automatic) [[ -z "$operation" ]] || fail 'Choose one operation'; operation=automatic; shift ;;
    --trial) [[ $# -ge 2 && -z "$operation" ]] || fail 'Choose one trial'; operation=trial; trial_args=("$2"); shift 2 ;;
    --path|--count) [[ $# -ge 2 ]] || fail 'Missing trial option'; trial_args+=("$1" "$2"); shift 2 ;;
    *) usage; fail "Unknown argument: $1" ;;
  esac
done
[[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && -n "$operation" ]] || fail 'Provide a safe host name and one operation'
if [[ -n "$remote" ]]; then
  [[ "$remote" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+$ ]] || fail 'Expected USER@HOST'
  ssh_options=(-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
  remote_dir=$(ssh "${ssh_options[@]}" "$remote" 'mktemp -d /tmp/deskhand-spike.XXXXXX')
  [[ "$remote_dir" == /tmp/deskhand-spike.* ]] || fail 'Invalid remote staging path'
  scp "${ssh_options[@]}" "$script_dir/run-spike.sh" "$script_dir/common.sh" "$remote:$remote_dir/"
  args=(bash "$remote_dir/run-spike.sh" --host "$host" --out "$remote_dir/results")
  if [[ "$operation" == automatic ]]; then args+=(--automatic); else args+=(--trial "${trial_args[@]}"); fi
  printf -v command '%q ' "${args[@]}"
  status=0
  ssh -t "${ssh_options[@]}" "$remote" "$command" || status=$?
  mkdir -p "$out/$host/runs"
  scp -r "${ssh_options[@]}" "$remote:$remote_dir/results/$host/runs/." "$out/$host/runs/" || fail "Retrieval failed; evidence retained at $remote:$remote_dir"
  scp "${ssh_options[@]}" "$remote:$remote_dir/results/$host/current-run" "$remote:$remote_dir/results/$host/summary.md" "$out/$host/" || fail "Retrieval incomplete; evidence retained at $remote:$remote_dir"
  printf 'Remote staging retained at %s:%s\n' "$remote" "$remote_dir"
  exit "$status"
fi
verify_app "$installed_app"
cli="$installed_app/Contents/MacOS/deskhand-spike"
receipt="$HOME/Applications/DeskhandSpike.receipt.json"
[[ -f "$receipt" ]] || fail 'Installed artifact receipt is missing'
lock="$HOME/Library/Application Support/$bundle_id/spike/driver.lock"
mkdir -p "$(dirname "$lock")"
mkdir "$lock" 2>/dev/null || fail "A driver owns this host. Inspect $lock before removing a stale lease."
printf '%s\n' "$$" > "$lock/pid"
token=''
cleanup() {
  if [[ -n "$token" ]]; then "$cli" agent-call session end "$token" >&2 || true; fi
  rm -rf "$lock"
}
trap cleanup EXIT
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen)"
mkdir -p "$out/$host/runs/$run_id"
run=$(cd "$out/$host/runs/$run_id" && pwd)
cp "$receipt" "$run/artifact-receipt.json"
"$cli" agent-call ping > "$run/agent-ping.json"
python3 - "$run/agent-ping.json" "$installed_app/Contents/Resources/BuildReceipt.json" "$receipt" "$installed_app" "$verified_cdhash" <<'PY'
import hashlib, json, pathlib, sys
p=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); r=json.load(open(sys.argv[3])); c=p['context']
assert p['pong'] and c['launched_by']=='launch_agent' and c['team_id']=='QV7QZ68XH2'
assert c['bundle_path']==sys.argv[4] and c['build_receipt']==b
assert c['cdhash']==sys.argv[5]
assert all(r[k]==b[k] for k in ('source_sha','team','architecture'))
assert hashlib.sha256((pathlib.Path(sys.argv[4])/'Contents/MacOS/deskhand-spike').read_bytes()).hexdigest()==r['executable_sha256']
PY
status=0
if [[ "$operation" == automatic ]]; then
  token=$(uuidgen)
  "$cli" agent-call session begin "$token" > "$run/session.json"
  "$cli" agent-call session "$token" probe all-automatic --out "$run" > "$run/automatic.jsonl" || status=$?
  "$cli" agent-call session end "$token" > "$run/session-end.json" || status=$?
  token=''
else
  "$cli" trial "${trial_args[@]}" --out "$run" || status=$?
fi
"$cli" agent-log --out "$run" > "$run/agent-log.jsonl" || status=$?
python3 - "$run" "$operation" <<'PY' || status=$?
import json, pathlib, sys
root=pathlib.Path(sys.argv[1]); reports=[]
for f in root.rglob('*.json'):
 r=json.loads(f.read_text())
 if 'probe' not in r: continue
 reports.append(r)
 assert r.get('status') in ('measured','blocked_on_permission','skipped','error'), f
 if r['probe'] != 'agent-log':
  c=r.get('evidence',{}).get('executor_context',r.get('context',{}))
  assert c.get('launched_by')=='launch_agent', f
 assert r['status']!='error', f
assert any(r['probe']!='agent-log' for r in reports), 'No measurement evidence persisted'
PY
printf '%s\n' "$run_id" > "$out/$host/current-run.next"
mv "$out/$host/current-run.next" "$out/$host/current-run"
"$cli" summarize --dir "$out/$host" || status=$?
"$cli" checklist --dir "$out/$host" > "$run/checklist.txt" || status=$?
printf 'Evidence: %s\n' "$run"
exit "$status"
