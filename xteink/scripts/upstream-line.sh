#!/usr/bin/env bash
# Which CrossInk-Bookorbit tags BookSync builds, and which release channel a build goes to.
#   upstream-line.sh channel <tag> [event] [promote_stable]   prints "stable" or "prerelease"; refuses an unsupported tag
#   upstream-line.sh pick            reads tags newest first on stdin, prints the first supported one
#   upstream-line.sh publish <event> <tag> <marker> <force>
#                                    reads the published releases' bodies on stdin, prints "true" or
#                                    "false": does this run publish? Releases are batched (README
#                                    "When a release is made"): a scheduled run publishes only for an
#                                    upstream tag no release was built from; our own changes go out
#                                    only by a manual run (workflow_dispatch), once per overlay tree
#                                    (<marker> = "upstream=<tag> overlay-tree=<tree>") unless forced.
# Supported: CrossInk 2.x and later (1.6 is retired; its readers stay on the feed's stable entry,
# xteink-v1.6.1.114, until an explicitly promoted 2.x release takes its place).
# Channel: previews by default, including final upstream tags. Only an explicit manual
# promotion can be stable; upstream rc/beta tags always remain pre-releases.
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
    supported "$tag" || { echo "unsupported CrossInk tag '$tag': BookSync builds 2.x and later only" >&2; exit 1; }
    if [ "${3:-}" = workflow_dispatch ] && [ "${4:-false}" = true ] &&
       ! printf '%s' "$tag" | grep -Eq -- '-[A-Za-z]'; then
      echo stable
    else
      echo prerelease
    fi
    ;;
  pick)
    while IFS= read -r tag; do
      if supported "$tag"; then echo "$tag"; exit 0; fi
    done
    echo "no supported CrossInk tag (2.x or later) on stdin" >&2
    exit 1
    ;;
  publish)
    event="${2:-}" tag="${3:-}" marker="${4:-}" force="${5:-false}"
    bodies="$(cat)"
    # Matched in the shell, never "printf | grep -q": grep -q exits at the first match, printf then
    # dies of SIGPIPE on a page of bodies bigger than the pipe buffer, and pipefail turns the match
    # into a miss (a scheduled run published an already-released upstream tag that way).
    released() { [[ "$bodies" == *"$1"* ]]; }
    case "$event" in
      schedule)
        # Only a new upstream tag: "upstream=<tag> " with the space, so -rc3 never matches -rc30.
        if released "upstream=$tag "; then echo false; else echo true; fi
        ;;
      workflow_dispatch)
        if [ "$force" = true ] || ! released "$marker"; then echo true; else echo false; fi
        ;;
      *) echo false ;;
    esac
    ;;
  *)
    echo "usage: upstream-line.sh channel <tag> [event] [promote_stable] | pick | publish <event> <tag> <marker> <force>" >&2
    exit 2
    ;;
esac
