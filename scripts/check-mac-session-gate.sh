#!/bin/sh
# Fails when a Swift Testing @Test or @Suite attribute names one half of the
# Mac-session gate without the other. The `.requiresMacSession` tag alone skips
# nothing (Tests/DeskhandTestSupport/Tags.swift), so a test with the tag but
# without `.macSessionTestsEnabled` would run in CI and on any plain
# `swift test`. The tag is also refused outside an attribute, so it cannot be
# smuggled in through a variable. Comments (`//` to end of line) are ignored.
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
    function stray(text) {
        if (text ~ /requiresMacSession/) {
            printf "%s:%d: .requiresMacSession outside a @Test or @Suite attribute\n", FILENAME, FNR
            bad = 1
        }
    }
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
    FNR == 1 { inattr = 0; instr = 0 }
    {
        rest = $0
        cut = index(rest, "//")
        if (cut > 0) rest = substr(rest, 1, cut - 1)
        while (length(rest) > 0) {
            if (!inattr) {
                a = index(rest, "@Test(")
                b = index(rest, "@Suite(")
                s = a
                if (s == 0 || (b > 0 && b < s)) s = b
                if (s == 0) { stray(rest); break }
                stray(substr(rest, 1, s - 1))
                rest = substr(rest, s)
                inattr = 1; depth = 0; instr = 0; buf = ""; start = FNR
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
