#!/usr/bin/env bash
# The version of an Android test build (release.yml with publish off; AGENTS.md "Test builds"):
# the patch after the newest Android release, with the pre-release part 0.test.<run>.
#
#   git tag -l | tools/android-test-version.sh <run number>     # v0.11.2 newest -> 0.11.3-0.test.<run>
#
# A numeric "0" sorts before every alphanumeric pre-release part (semver 11.4.3), so the test
# build installs over the release it was built after, yet every release and pre-release of the
# next patch (0.11.3-alpha, -rc.1, 0.11.3 itself) is newer: the device's updater takes the next
# real release. The companion and the plugin never pick a test version (TestBuild).
set -euo pipefail

run=${1:?usage: android-test-version.sh <run number>  (tags on stdin)}
[[ $run =~ ^[0-9]+$ ]] || { echo "android-test-version: run number '$run' is not a number" >&2; exit 2; }

# Final Android releases only: v1.2.3 or android-v1.2.3, no pre-release or build part.
newest=$(sed -nE 's/^(android-)?v([0-9]+\.[0-9]+\.[0-9]+)$/\2/p' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
[[ -n $newest ]] || { echo "android-test-version: no v<MAJOR.MINOR.PATCH> tag on stdin" >&2; exit 1; }
IFS=. read -r major minor patch <<<"$newest"
printf '%s.%s.%s-0.test.%s\n' "$major" "$minor" "$((patch + 1))" "$run"
