#!/bin/sh
# Fails when a Swift Testing @Test or @Suite attribute names one half of the
# Mac-session gate without the other. The `.requiresMacSession` tag alone skips
# nothing (Tests/DeskhandTestSupport/Tags.swift), so a test with the tag but
# without `.macSessionTestsEnabled` would run in CI and on any plain
# `swift test`, and the trait without the tag is unreachable by tag filters.
#
#
# Usage: scripts/check-mac-session-gate.sh [dir ...]   (default: Tests Sources)
set -eu

cd "$(dirname "$0")/.."
if [ "$#" -eq 0 ]; then
    set -- Tests Sources
fi

status=0
output=$(find "$@" -name '*.swift' ! -path 'Tests/DeskhandTestSupport/Tags.swift' -exec awk '
    function check() {
        tag = (buf ~ /requiresMacSession/)
        trait = (code ~ /macSessionTestsEnabled/)
        if (tag && !trait) {
            printf "%s:%d: .requiresMacSession without .macSessionTestsEnabled\n", FILENAME, start
            bad = 1
        }
        if (trait && !tag) {
            printf "%s:%d: .macSessionTestsEnabled without .tags(.requiresMacSession)\n", FILENAME, start
            bad = 1
        }
        if (tag && trait) gated++
        attrs++
    }
    function unterminated(file) {
        if (inattr) {
            printf "%s:%d: @Test/@Suite attribute is never closed; the lint cannot read it\n", file, start
            bad = 1
        }
        inattr = 0
    }
    FNR == 1 {
        unterminated(prev); prev = FILENAME
        blockDepth = 0; mode = ""
    }
    {
        rest = $0
        n = length(rest)
        for (i = 1; i <= n; i++) {
            c = substr(rest, i, 1)
            pair = substr(rest, i, 2)
            if (blockDepth > 0) {
                if (pair == "/*") { blockDepth++; i++ }
                else if (pair == "*/") { blockDepth--; i++ }
                continue
            }
            if (mode != "") {
                if (mode == "esc" && c == "\\") {
                    if (inattr) buf = buf substr(rest, i, 2)
                    i++; continue
                }
                if (substr(rest, i, length(closer)) == closer) {
                    if (inattr) buf = buf closer
                    i += length(closer) - 1; mode = ""; continue
                }
                if (inattr) buf = buf c
                continue
            }
            if (pair == "//") break
            if (pair == "/*") {
                blockDepth = 1; i++
                if (inattr) { buf = buf " "; code = code " " }
                continue
            }
            if (match(substr(rest, i), /^#*"("")?/)) {
                open = substr(rest, i, RLENGTH); hashes = open; gsub(/"/, "", hashes)
                closer = substr(open, length(hashes) + 1) hashes
                mode = length(hashes) ? "raw" : "esc"
                if (inattr) buf = buf open
                i += RLENGTH - 1; continue
            }
            if (!inattr) {
                if (match(substr(rest, i), /^@(Test|Suite)[ \t]*\(/)) {
                    buf = code = substr(rest, i, RLENGTH)
                    i += RLENGTH - 1
                    inattr = 1; depth = 1; start = FNR
                }
                continue
            }
            buf = buf c; code = code c
            if (c == "(") depth++
            else if (c == ")" && --depth == 0) { check(); inattr = 0 }
        }
        if (inattr) { buf = buf "\n"; code = code "\n" }
    }
    END {
        unterminated(prev)
        if (bad) exit 1
        printf "check-mac-session-gate: ok (%d attributes, %d gated)\n", attrs, gated
    }
    ' {} +) || status=$?
if [ -z "$output" ] && [ "$status" -eq 0 ]; then
    echo "check-mac-session-gate: no Swift files under $*" >&2
    exit 1
fi
if [ -n "$output" ]; then
    printf '%s\n' "$output"
fi
exit "$status"
