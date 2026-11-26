#!/usr/bin/env bash
# Coordinator-only migration plan. No mutations unless --apply is supplied.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OLD_REPO="Fledgewing/Orbify"
NEW_REPO="Fledgewing/BookSync"
case "${1:-}" in
  '') apply=false ;;
  --apply) apply=true ;;
  *) echo "Usage: $0 [--apply]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo 'Too many arguments' >&2; exit 2; }
cat <<EOF_PLAN
Dry-run migration plan (no repositories changed):
1. Snapshot the existing feed files byte-for-byte.
2. gh repo rename BookSync --repo $OLD_REPO --yes
3. gh repo create $OLD_REPO --public --source=<temporary copy of stub/> --push
4. Seed xteink-feed and android-feed from the snapshot, without rewriting bytes.
5. gh workflow run mirror-feeds.yml --repo $OLD_REPO
6. Verify old raw URLs return direct HTTP 200 and bytes match $NEW_REPO.
BLOCKED: recreating the old name also removes release API/download redirects.
A feed-only stub does not preserve those endpoints for shipped clients.
Resolve the release compatibility design before enabling execution.
EOF_PLAN
execute_migration() (
    temporary="$(mktemp -d)"
    trap 'rm -rf "$temporary"' EXIT
    python3 "$ROOT/tools/rename-feeds.py" snapshot "$OLD_REPO" "$NEW_REPO" "$temporary/feeds"
    cp -R "$ROOT/stub" "$temporary/stub"
    git -C "$temporary/stub" init --initial-branch=main
    git -C "$temporary/stub" config user.name "$(git -C "$ROOT" config user.name)"
    email="$(git -C "$ROOT" config user.email)"
    [[ $email == *@users.noreply.github.com ]] || { echo 'Configured noreply identity required' >&2; exit 1; }
    git -C "$temporary/stub" config user.email "$email"
    git -C "$temporary/stub" add README.md feeds.json mirror.py .github/workflows/mirror-feeds.yml
    git -C "$temporary/stub" commit -m 'Serve legacy BookSync update feeds' -m 'Co-Authored-By: Codex <noreply@openai.com>'
    gh repo rename BookSync --repo "$OLD_REPO" --yes
    gh repo create "$OLD_REPO" --public --source="$temporary/stub" --push
    python3 "$ROOT/tools/rename-feeds.py" seed "$OLD_REPO" "$NEW_REPO" "$temporary/feeds"
    gh workflow run mirror-feeds.yml --repo "$OLD_REPO"
    # Raw CDN publication may lag: wait for success rather than accept redirects/stale bytes.
    verified=false
    for _attempt in {1..12}; do
      if python3 "$ROOT/tools/rename-feeds.py" verify "$OLD_REPO" "$NEW_REPO" "$temporary/check"; then
        verified=true; break
      fi
      sleep 5
    done
    "$verified" || { echo 'Feed verification failed: migration needs coordinator attention' >&2; exit 1; }
)
if $apply; then
  echo 'Refusing --apply: shipped release API and download compatibility is unresolved; see docs/repository-rename.md.' >&2
  exit 1
  # Enable execute_migration only after a reviewed fix preserves those endpoints.
fi
printf '\nAfter a completed migration, update each local checkout (no directory rename needed):\n'
printf 'git remote set-url origin https://github.com/%s.git\n' "$NEW_REPO"
printf 'git remote set-url origin git@github.com:%s.git\n' "$NEW_REPO"
# The execution path intentionally remains disabled until the release-endpoint
# compatibility decision is implemented and reviewed. Never turn a raw-feed-only
# success into approval to break an installed updater.
