#!/bin/sh
# Fails when a Swift Testing @Test or @Suite attribute names one half of the
# Mac-session gate without the other. The `.requiresMacSession` tag alone skips
# nothing (Tests/DeskhandTestSupport/Tags.swift), so a test with the tag but
# without `.macSessionTestsEnabled` would run in CI and on any plain
# `swift test`, and the trait without the tag is unreachable by tag filters.
#
# Deliberately no comment handling: comments are not stripped, so text inside
# an attribute (even a string such as "see https://x") can never hide the tag.
# An attribute is everything from `@Test(` / `@Suite(` to its matching `)`,
# possibly across lines; parens inside string literals are skipped. A commented
# out `// @Test(...)` is therefore linted like live code (conservative).
#
# Usage: scripts/check-mac-session-gate.sh [dir ...]   (default: Tests Sources)
set -eu

cd "$(dirname "$0")/.."
if [ "$#" -eq 0 ]; then
    set -- Tests Sources
fi

find "$@" -name '*.swift' ! -path 'Tests/DeskhandTestSupport/Tags.swift' -print | sort | {
    files=$(cat)
    if [ -z "$files" ]; then
        echo "check-mac-session-gate: no Swift files under $*" >&2
        exit 1
    fi
    # shellcheck disable=SC2086 # file names in this repo have no spaces
    awk '
    function check() {
        tag = (buf ~ /requiresMacSession/)
        trait = (buf ~ /macSessionTestsEnabled/)
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
    FNR == 1 { inattr = 0 }
    {
        rest = $0
        while (length(rest) > 0) {
            if (!inattr) {
                if (!match(rest, /@(Test|Suite)[ \t]*\(/)) break
                buf = substr(rest, RSTART, RLENGTH)
                rest = substr(rest, RSTART + RLENGTH)
                inattr = 1; depth = 1; instr = 0; start = FNR
            }
            n = length(rest)
            closed = 0
            for (i = 1; i <= n; i++) {
                c = substr(rest, i, 1)
                buf = buf c
                if (instr) {
                    if (c == "\\") { i++; buf = buf substr(rest, i, 1) }
                    else if (c == "\"") instr = 0
                } else if (c == "\"") instr = 1
                else if (c == "(") depth++
                else if (c == ")" && --depth == 0) { closed = 1; break }
            }
            if (closed) { check(); inattr = 0; rest = substr(rest, i + 1) }
            else { buf = buf "\n"; break }
        }
    }
    END {
        if (bad) exit 1
        printf "check-mac-session-gate: ok (%d attributes, %d gated)\n", attrs, gated
    }
    ' $files
}
