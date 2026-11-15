#!/bin/sh
# Fails when a Swift Testing @Test or @Suite attribute names one half of the
# Mac-session gate without the other. The `.requiresMacSession` tag alone skips
# nothing (Tests/DeskhandTestSupport/Tags.swift), so a test with the tag but
# without `.macSessionTestsEnabled` would run in CI and on any plain
# `swift test`, and the trait without the tag is unreachable by tag filters.
#
# Comments and string literals are handled asymmetrically, so neither can fool
# the lint in the unsafe direction: the tag is looked for in the raw text of the
# attribute (a comment or a string can never hide it), the trait only in code (a
# comment or a string can never supply it). An attribute runs from `@Test(` /
# `@Suite(` to its matching `)`, possibly across lines. "...", """...""",
# #"..."# and #"""..."""# literals are skipped, and an attribute that never
# closes fails. A commented-out `// @Test(...)` is still linted (conservative).
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
        tag = (buf ~ /requiresMacSession/)          # raw text, comments and strings included
        trait = (code ~ /macSessionTestsEnabled/)   # code only: a comment or a string cannot supply it
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
    FNR == 1 { unterminated(prev); prev = FILENAME }
    {
        rest = $0
        while (length(rest) > 0) {
            if (!inattr) {
                if (!match(rest, /@(Test|Suite)[ \t]*\(/)) break
                buf = code = substr(rest, RSTART, RLENGTH)
                rest = substr(rest, RSTART + RLENGTH)
                inattr = 1; depth = 1; mode = ""; start = FNR
            }
            n = length(rest)
            closed = 0
            for (i = 1; i <= n; i++) {
                c = substr(rest, i, 1)
                if (mode != "") {                          # inside a string literal
                    if (mode == "esc" && c == "\\") { buf = buf substr(rest, i, 2); i++; continue }
                    if (substr(rest, i, length(closer)) == closer) {
                        buf = buf closer; i += length(closer) - 1; mode = ""; continue
                    }
                    buf = buf c; continue
                }
                if (c == "/" && substr(rest, i + 1, 1) == "/") { buf = buf substr(rest, i); break }
                if (match(substr(rest, i), /^#*"("")?/)) {  # "...", """...""", #"..."#, #"""..."""#
                    open = substr(rest, i, RLENGTH); hashes = open; gsub(/"/, "", hashes)
                    closer = substr(open, length(hashes) + 1) hashes
                    mode = length(hashes) ? "raw" : "esc"
                    buf = buf open; i += RLENGTH - 1; continue
                }
                buf = buf c; code = code c
                if (c == "(") depth++
                else if (c == ")" && --depth == 0) { closed = 1; break }
            }
            if (closed) { check(); inattr = 0; rest = substr(rest, i + 1) }
            else { buf = buf "\n"; code = code "\n"; break }
        }
    }
    END {
        unterminated(prev)
        if (bad) exit 1
        printf "check-mac-session-gate: ok (%d attributes, %d gated)\n", attrs, gated
    }
    ' $files
}
