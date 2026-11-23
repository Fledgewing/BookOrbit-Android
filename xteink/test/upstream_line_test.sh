#!/usr/bin/env bash
# Tests for xteink/scripts/upstream-line.sh: which CrossInk tags Orbify builds, and which
# release channel a build goes to (README "Releases and the update feed").
set -euo pipefail
script="$(cd "$(dirname "$0")/../scripts" && pwd)/upstream-line.sh"
fails=0
expect() { # want, then the command's arguments; stdin passes through
  local want="$1" got
  shift
  got="$("$script" "$@" 2>/dev/null)" || got="refused"
  if [ "$got" = "$want" ]; then echo "ok   $* -> $got"; else echo "FAIL $* -> $got (want $want)"; fails=$((fails + 1)); fi
}

# A final 2.x upstream release is our stable release (the feed's stable entry, which moves
# readers still on 1.6 to it); an rc or beta stays a pre-release.
expect prerelease channel v2.0.0+bookorbit.1-rc3
expect prerelease channel v2.0.0+bookorbit.1-beta2
expect prerelease channel v2.1.0-rc1+bookorbit.1
expect prerelease channel v2.0.0+bookorbit.1-RC4
expect stable channel v2.0.0+bookorbit.1
expect stable channel v2.0.1+bookorbit.2
expect stable channel 2.3.0
# Only 2.x and later are built: 1.6 is no longer supported.
expect refused channel v1.6.1+bookorbit.9
expect refused channel v1.7.0
expect refused channel ""
expect refused channel main

# The daily build takes the newest supported tag (newest first on stdin), rc or not; upstream's
# "latest release" skips pre-releases and would pick 1.6 while 2.0 is an rc.
expect v2.0.0+bookorbit.1-rc3 pick <<<$'v1.6.2+bookorbit.10\nv2.0.0+bookorbit.1-rc3\nv1.6.1+bookorbit.9'
expect v2.0.0+bookorbit.1 pick <<<$'v2.0.0+bookorbit.1\nv2.0.0+bookorbit.1-rc3'
expect refused pick <<<$'v1.6.1+bookorbit.9'

[ "$fails" -eq 0 ] || { echo "$fails failed" >&2; exit 1; }
echo "upstream-line: all passed"
