#!/usr/bin/env bash
# Which CrossInk-Bookorbit tags Orbify builds, and which release channel a build goes to.
#   upstream-line.sh channel <tag>   prints "stable" or "prerelease"; refuses an unsupported tag
#   upstream-line.sh pick            reads tags newest first on stdin, prints the first supported one
# Supported: CrossInk 2.x and later (1.6 is retired; its readers stay on the feed's stable entry,
# xteink-v1.6.1.114, until a final 2.x release takes its place).
# Channel: a tag with a pre-release part (a "-" followed by a letter: -rc3, -beta2) is a
# pre-release; any other supported tag is stable, and the feed then offers it as the stable entry.
# Tested by xteink/test/upstream_line_test.sh.
set -euo pipefail

supported() { # v2.0.0+bookorbit.1-rc3 -> yes when the major version is 2 or more
  local major
  major="$(printf '%s' "${1#v}" | sed -nE 's/^([0-9]+)\..*/\1/p')"
  [ -n "$major" ] && [ "$major" -ge 2 ]
}

case "${1:-}" in
  channel)
    tag="${2:-}"
    supported "$tag" || { echo "unsupported CrossInk tag '$tag': Orbify builds 2.x and later only" >&2; exit 1; }
    if printf '%s' "$tag" | grep -Eq -- '-[A-Za-z]'; then echo prerelease; else echo stable; fi
    ;;
  pick)
    while IFS= read -r tag; do
      if supported "$tag"; then echo "$tag"; exit 0; fi
    done
    echo "no supported CrossInk tag (2.x or later) on stdin" >&2
    exit 1
    ;;
  *)
    echo "usage: upstream-line.sh channel <tag> | pick" >&2
    exit 2
    ;;
esac
