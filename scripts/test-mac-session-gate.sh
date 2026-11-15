#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
check() {
    expected=$1
    label=$2
    source=$3
    printf '%s\n' "$source" > "$tmp/fixture.swift"
    status=0
    scripts/check-mac-session-gate.sh "$tmp/fixture.swift" > "$tmp/output" 2>&1 || status=$?
    if [ "$status" -ne "$expected" ]; then
        printf '%s: expected %s, got %s\n' "$label" "$expected" "$status" >&2
        cat "$tmp/output" >&2
        exit 1
    fi
}
check 1 block-trait '@Test(.tags(.requiresMacSession) /* .macSessionTestsEnabled */)'
check 1 nested-trait '@Test(.tags(.requiresMacSession) /* ( " /* .macSessionTestsEnabled */ ) */)'
check 1 multiline-trait '@Test(.tags(.requiresMacSession) /*
 .macSessionTestsEnabled
 */)'
check 1 quoted-trait '@Test(.tags(.requiresMacSession), "macSessionTestsEnabled")'
check 1 line-comment-trait '@Test(.tags(.requiresMacSession) // .macSessionTestsEnabled
)'
check 1 commented-tag '@Test(.macSessionTestsEnabled /* .requiresMacSession */)'
check 0 actual-pair '@Test(.tags(.requiresMacSession), /* ) " /* nested */ */ .macSessionTestsEnabled)'
check 0 comment-outside '/* @Test(.tags(.requiresMacSession))
 /* @Suite(.macSessionTestsEnabled) */
 */
@Test("plain")'
check 0 quoted-comment '@Test("/*", .tags(.requiresMacSession), .macSessionTestsEnabled)'
printf '%s\n' '/* @Test(.tags(.requiresMacSession))' > "$tmp/first.swift"
printf '%s\n' '@Test(.tags(.requiresMacSession))' > "$tmp/second.swift"
status=0
scripts/check-mac-session-gate.sh "$tmp/first.swift" "$tmp/second.swift" > "$tmp/output" 2>&1 || status=$?
[ "$status" -eq 1 ] || { cat "$tmp/output"; exit 1; }
printf '%s\n' 'test-mac-session-gate: ok (10 scanner-only cases)'
