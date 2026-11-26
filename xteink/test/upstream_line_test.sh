#!/usr/bin/env bash
# Tests for xteink/scripts/upstream-line.sh: which CrossInk tags BookSync builds, and which
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

# Whether a run publishes (release bodies on stdin; each carries "upstream=<tag> overlay-tree=<tree>").
# Releases are batched: the daily run publishes only for an upstream tag never released before (a
# new rc, or the final that becomes stable); our own changes go out only by a manual run.
released=$'Firmware.\nupstream=v2.0.0+bookorbit.1-rc3 overlay-tree=aaa\n\nupstream=v2.0.0+bookorbit.1-rc2 overlay-tree=bbb'
expect false publish schedule v2.0.0+bookorbit.1-rc3 "upstream=v2.0.0+bookorbit.1-rc3 overlay-tree=ccc" false <<<"$released"
expect false publish schedule v2.0.0+bookorbit.1-rc3 "upstream=v2.0.0+bookorbit.1-rc3 overlay-tree=aaa" false <<<"$released"
expect true publish schedule v2.0.0+bookorbit.1-rc4 "upstream=v2.0.0+bookorbit.1-rc4 overlay-tree=ccc" false <<<"$released"
expect true publish schedule v2.0.0+bookorbit.1 "upstream=v2.0.0+bookorbit.1 overlay-tree=aaa" false <<<"$released"
# A tag that only prefixes a released one is still new ("-rc3" is not "-rc30").
expect true publish schedule v2.0.0+bookorbit.1-rc30 "upstream=v2.0.0+bookorbit.1-rc30 overlay-tree=aaa" false <<<"$released"
expect true publish schedule v2.0.0+bookorbit.1-rc3 "upstream=v2.0.0+bookorbit.1-rc3 overlay-tree=ccc" false <<<""
# Real input: a page of 100 release bodies in the published format (fixtures/release-body-rc3.txt
# is release xteink-v2.0.0.150+bookorbit.1-rc3's body), the released tag first, as GitHub lists
# newest first. Far bigger than a pipe buffer: run 45164565596 read a match as a miss there and
# republished rc3 (grep -q exiting early, SIGPIPE, pipefail).
body="$(cat "$(dirname "$0")/fixtures/release-body-rc3.txt")"
page="$body"
for _ in $(seq 99); do page+=$'\n'"${body//-rc3/-rc2}"; done
expect false publish schedule v2.0.0+bookorbit.1-rc3 "upstream=v2.0.0+bookorbit.1-rc3 overlay-tree=90cb06d" false <<<"$page"
expect true publish schedule v2.0.0+bookorbit.1-rc4 "upstream=v2.0.0+bookorbit.1-rc4 overlay-tree=90cb06d" false <<<"$page"
expect false publish workflow_dispatch v2.0.0+bookorbit.1-rc3 "upstream=v2.0.0+bookorbit.1-rc3 overlay-tree=5674cf9301d6914f242fbb79d4dbd13131dc6acd" false <<<"$page"
# A manual run publishes our changes once per overlay tree, or again when forced.
expect true publish workflow_dispatch v2.0.0+bookorbit.1-rc3 "upstream=v2.0.0+bookorbit.1-rc3 overlay-tree=ccc" false <<<"$released"
expect false publish workflow_dispatch v2.0.0+bookorbit.1-rc3 "upstream=v2.0.0+bookorbit.1-rc3 overlay-tree=aaa" false <<<"$released"
expect true publish workflow_dispatch v2.0.0+bookorbit.1-rc3 "upstream=v2.0.0+bookorbit.1-rc3 overlay-tree=aaa" true <<<"$released"
# Pushes and pull requests never publish; forcing doesn't change that.
expect false publish push v2.0.0+bookorbit.1-rc4 "upstream=v2.0.0+bookorbit.1-rc4 overlay-tree=ccc" true <<<"$released"
expect false publish pull_request v2.0.0+bookorbit.1-rc4 "upstream=v2.0.0+bookorbit.1-rc4 overlay-tree=ccc" false <<<""

[ "$fails" -eq 0 ] || { echo "$fails failed" >&2; exit 1; }
echo "upstream-line: all passed"
