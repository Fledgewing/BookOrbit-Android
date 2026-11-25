#!/usr/bin/env bash
# Public repository identities across the GitHub rename; no device operations.
BOOKSYNC_REPO="Fledgewing/BookSync"
BOOKSYNC_LEGACY_REPO="Fledgewing/Orbify"

# A missing new name/run can still belong to the existing repository. Keep REPO
# in the caller so the artifact download uses the same repository as this lookup.
booksync_run_info() {
    if gh run view "$SOURCE" -R "$REPO" "$@" 2>/dev/null; then return 0; fi
    [[ $REPO != "$BOOKSYNC_LEGACY_REPO" ]] || return 1
    REPO=$BOOKSYNC_LEGACY_REPO
    printf 'Trying previous repository name %s\n' "$REPO" >&2
    gh run view "$SOURCE" -R "$REPO" "$@"
}

# fetch is the installer's curl wrapper. Its caller supplies the canonical URL.
booksync_release_metadata() {
    local json
    if json=$(fetch "$1" 2>/dev/null); then printf '%s\n' "$json"; return 0; fi
    printf 'Trying previous repository name %s\n' "$BOOKSYNC_LEGACY_REPO" >&2
    fetch "https://api.github.com/repos/$BOOKSYNC_LEGACY_REPO/releases/latest"
}

# Certificates keep their build-time identity after a rename. All files must
# verify under the same exact repository identity; do not broaden owner trust.
booksync_attested() {
    [[ $# -gt 0 ]] || return 1
    local repo file
    for repo in "$BOOKSYNC_REPO" "$BOOKSYNC_LEGACY_REPO"; do
        for file in "$@"; do
            if ! gh attestation verify "$file" -R "$repo" >/dev/null 2>&1; then continue 2; fi
        done
        return 0
    done
    return 1
}
