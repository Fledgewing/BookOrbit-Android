#!/usr/bin/env bash
# Artifact-only Android previews use the workflow run number (no tag/release is created).
# Continue the newest preview's patch; after an RC or stable tag, bump the patch so the
# preview is newer. Published previews use preview.N too; RC is a maintainer decision.
set -euo pipefail
run=${1:?usage: android-test-version.sh <run number>  (tags on stdin)}
if ! [[ $run =~ ^[1-9][0-9]*$ ]] || ((run > 3999)); then
    echo "android-test-version: run must be 1..3999" >&2
    exit 2
fi
tags=$(sed -nE 's/^(android-)?v([0-9]+\.[0-9]+\.[0-9]+(-(preview|rc)\.[0-9]+)?)$/\2/p')
newest=$(printf '%s\n' "$tags" | sed 's/-.*//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
[[ -n $newest ]] || { echo "android-test-version: no Android release tag on stdin" >&2; exit 1; }
IFS=. read -r major minor patch <<<"$newest"
# Stable and RC tags close this patch's preview phase.
if printf '%s\n' "$tags" | grep -Eq "^${major}\.${minor}\.${patch}(-rc\.[0-9]+)?$"; then
    patch=$((patch + 1))
else
    previous=$(printf '%s\n' "$tags" | sed -nE "s/^${major}\.${minor}\.${patch}-preview\.([0-9]+)$/\1/p" | sort -n | tail -n 1)
    ((run > previous)) || run=$((previous + 1))
fi
((run <= 3999)) || { echo "android-test-version: preview number exceeds 3999" >&2; exit 2; }
printf '%s.%s.%s-preview.%s\n' "$major" "$minor" "$patch" "$run"
