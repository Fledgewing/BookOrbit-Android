# BookSync repository rename: device compatibility

The coordinator owns the GitHub rename. This change does not rename the remote repository,
publish a release, move a tag or touch a device.

**2026-11-25 maintainer decision:** keep a feed-only repository at `Fledgewing/Orbify`
after moving the project to `Fledgewing/BookSync`. Direct HTTP 200 at the old raw URLs avoids
shipped Xteink parsers consuming redirect bodies; no firmware rollout is needed for that
part of the migration. `stub/` is the deployable template, not a second development checkout.

**Remaining blocker:** raw feeds are only part of the installed-client contract. Shipped
Android companions and Lua patches read the old GitHub Releases API. Existing signed Android
payloads and firmware feeds also contain old release-download URLs. Recreating the old
repository removes GitHub's redirects for those paths ([GitHub rename guidance](https://docs.github.com/en/repositories/creating-and-managing-repositories/renaming-a-repository)); an empty release list or 404 download
would strand those clients. A feed-only stub cannot serve GitHub's Releases API or redirect
arbitrary release asset paths. Redirect support in the clients does not help if the endpoint
no longer redirects. Resolve this with an approved release-metadata/asset compatibility
mechanism before renaming; this PR does not create tags or releases to work around it.

`tools/rename-to-booksync.sh` defaults to an offline dry-run plan. Its execution
function contains the rename/create/seed/dispatch/direct-200 checks, but `--apply` deliberately
refuses before any mutation until the release-endpoint blocker has been resolved in code.
Do not remove that gate merely because raw-feed checks pass. No repositories have been
renamed or created, and no physical-device validation has been performed.

## Exact old URL inventory

The two raw JSON feeds below are the complete default feed paths in the inspected clients.
The detached Xteink signature is mirrored too, although shipped firmware checks per-image
signatures and does not fetch that sidecar itself. Arbitrary user-specified test feeds are
outside the mirror and never fall back to public feeds.

| Old URL (query variants share the same endpoint) | Consumers and source evidence | Stub coverage |
|---|---|---|
| `https://raw.githubusercontent.com/Fledgewing/Orbify/xteink-feed/xteink/releases.json` | Retired stable `xteink-v1.6.1.114+bookorbit.9:xteink/tailnet/tailnet_build.py:24-27,395-396`; current `xteink/tailnet/tailnet_build.py:31-35,564-570`. All inspected 1.6/2.x firmware uses this layout. | `xteink-feed` branch, `xteink/releases.json`, exact bytes. |
| `https://raw.githubusercontent.com/Fledgewing/Orbify/xteink-feed/xteink/releases.json.sig` | Publisher `.github/workflows/xteink.yml:603,626`; detached feed signature, not a separate client manifest. | Same branch, `xteink/releases.json.sig`, exact bytes, committed with the JSON. |
| `https://raw.githubusercontent.com/Fledgewing/Orbify/android-feed/android/releases.json` | Signed-feed companion on main: `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/AndroidReleaseFeed.kt:9-10`; no separate plugin feed. | `android-feed` branch, `android/releases.json`, exact signed envelope bytes. |
| `https://api.github.com/repos/Fledgewing/Orbify/releases/latest` and `/releases?per_page=N` | Shipped `v0.7.0:android/companion/app/src/main/java/net/fledgewing/orbitcompanion/Updater.kt:40-41,144-147`; `v0.11.3-rc.17:android/companion/app/src/main/java/net/fledgewing/orbitcompanion/Updater.kt:40-41,207-210`; Lua `v0.7.0:android/koreader-patch/2-orbit-android.lua:2312,2368` (`N=30` in that patch). | **Not covered. Blocking.** GitHub generates this API from releases, not raw branch files. |
| `https://api.github.com/repos/Fledgewing/BookOrbit-Android/releases/latest` and `/releases?per_page=N` | Earliest companion `v0.1.0:companion/app/src/main/java/net/fledgewing/orbitcompanion/Updater.kt:40-41,110-113` (`N=5`); patch `v0.6.2:koreader-patch/2-orbit-android.lua:2310,2366`. | Historical alias must be checked separately; do not assume it chains through the recreated name. |
| `https://github.com/Fledgewing/Orbify/releases/download/<tag>/<asset>` (also historical `BookOrbit-Android` paths) | URLs returned by those APIs and already stored in published feeds; `v0.11.3-rc.17:android/companion/app/src/main/java/net/fledgewing/orbitcompanion/Updater.kt:228-246`; firmware `OtaUpdater.cpp` uses the manifest's asset URL. | **Not covered. Blocking.** New generated feeds use canonical downloads; that cannot rewrite cached URLs or old signed envelopes. |

The plugin from 0.8 has no independent update/feed HTTP reader:
`android/koreader/orbit.koplugin/ko/updater.lua:25-30` delegates to the companion.
Older Lua patches use the Releases API above, not a raw plugin feed.

## Stub mirroring and verification

`stub/feeds.json` is the single branch/path manifest used by the scheduled mirror and the
coordinator's snapshot, seed and verification helpers. The workflow runs every five minutes,
on `repository_dispatch` type `mirror-feeds`, and on `workflow_dispatch`. GitHub schedules can
be delayed and may disable after inactivity; monitor the workflow and re-enable it as needed.
The publisher can be dispatched manually after a release without a cross-repository secret.

The mirror downloads all source files anonymously before changing anything, writes only feed
files, and commits only changed bytes. Each branch's JSON and signature are published in one
Git tree/commit; non-forced updates fail on concurrent writes instead of overwriting them.
Only the stub's own `GITHUB_TOKEN` has write access. A missing source file fails closed and
leaves existing feeds alone. Source code and full project history are never copied.

For the coordinator, after release compatibility is resolved and the execution gate is
removed by a reviewed change: snapshot the old feeds **before** renaming, rename the project,
create the public stub from its template, seed both branches from that snapshot byte-for-byte,
then dispatch the mirror. The initial snapshot preserves signatures; it may still contain old
asset URLs. Regenerate both source feeds in BookSync's normal signing CI and mirror again
before declaring completion. Their generators use `GITHUB_REPOSITORY` for canonical download
URLs; signed payload edits are never made by the stub. The rename/create operation has a
service gap, so perform it in a coordinated maintenance window and check both branches.

`python3 tools/rename-feeds.py verify Fledgewing/Orbify Fledgewing/BookSync <temporary-directory>`
uses `curl` **without `-L`**, requires direct HTTP 200 for every file on both repositories and
compares the downloaded bytes. The execution function retries raw CDN publication delays, then fails on
redirects, errors or different bytes. This proves raw-feed compatibility only. Also verify
old API latest/list responses, historical aliases, and old/new downloads with their checksums
before approving the migration. Never log expiring asset-host query strings.

Keep the stub until **no pre-0.12 client remains**. There is no telemetry to establish that,
so the default is to retain and maintain it indefinitely. Keep release compatibility for the
same installed population; retiring raw branches alone does not retire cached asset URLs.

## Inspected clients

All 53 local Android release tags use `HttpURLConnection` without disabling redirects. All
20 local firmware tags resolve to the four upstream commits below. The audit includes the
retired stable firmware, not only current source. Tag counts describe the local tag inventory
at this change, not an assertion that every tag was installed on a device.

| Client | 301 / 302 / 307, including another HTTPS host | Evidence |
|---|---|---|
| Android companion, earliest release onward | Yes. Automatic GET redirects; HTTP/HTTPS scheme changes are not followed. | `v0.1.0:companion/app/src/main/java/net/fledgewing/orbitcompanion/Updater.kt:164`; current `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/Updater.kt:278`. [Android response handling](https://developer.android.com/reference/java/net/HttpURLConnection#response-handling) documents cross-origin redirects. |
| KOReader user patch, through 0.7.x | Yes. Manual loop accepts any 3xx with Location, up to five requests, without host pinning. | `v0.1.0:koreader-patch/2-orbit-android.lua:785`; `v0.6.2:koreader-patch/2-orbit-android.lua:2316`; `v0.7.0:android/koreader-patch/2-orbit-android.lua:2318`. |
| KOReader plugin, from 0.8 | No HTTP update/feed reads of its own; delegates to companion. | `android/koreader/orbit.koplugin/ko/updater.lua:6`, `:24`. |
| Xteink manifest/feed GET, 1.6 and 2.x | Transport yes; certain redirect bodies can spoil manifest parsing in shipped builds. | At all four pinned commits, `src/network/OtaUpdater.cpp:143` feeds all ON_DATA bodies; `:255` leaves `disable_auto_redirect` false and `max_redirection_count` zero; `:285` calls `esp_http_client_perform`. [ESP-IDF defaults](https://docs.espressif.com/projects/esp-idf/en/v5.5.3/esp32/api-reference/protocols/esp_http_client.html) enable automatic redirects and use the default limit when zero. |
| Xteink image download, 1.6 | Yes, both wolfSSL and ESP transport branches explicitly handle these statuses and allow another HTTPS host. | Pinned 1.6 `src/network/HttpDownloader.cpp:50`, `:236`, `:350`; `src/network/HttpRedirectPolicy.h:75` forbids only HTTPS downgrade. |
| Xteink image download, 2.x | Yes, both transport branches, including signed OTA. | Pinned 2.x `src/network/HttpDownloader.cpp:113`, `:483`, `:639`; `src/network/HttpRedirectPolicy.h:75`. Patch `0050-orbify-signed-ota.patch` verifies the staged image; it does not disable redirects. |
| Tailnet DNS hook | Does not restrict redirected public hosts. Unknown public names return to normal DNS. | `xteink/tailnet/shim/TailnetResolver.cpp:40`, `:87`; the same behaviour is present in `xteink-v1.6.1.114+bookorbit.9`. |

Upstream pins (all in agosez/CrossInk-Bookorbit; line citations above are at these commits):

- 1.6.1+bookorbit.8: `d7b4aa85514afab262c52017c57fa68cd27bb695`.
- 1.6.1+bookorbit.9: `0665c915c830423b8db9546562cc14ec4692865b`.
- 2.0.0+bookorbit.1-rc2: `5ec6eb03e49282d9e1de20c919a5ee52ebd14ffd`.
- 2.0.0+bookorbit.1-rc3: `87e2e1984481e8a3d996f12b34b50a383f9013b8`.

The OTA manifest uses ESP-IDF, not Arduino HTTPClient: `setFollowRedirects` is therefore not
its configuration switch. ESP-IDF emits ON_DATA for redirect bodies as well as the final
response (`components/esp_http_client/esp_http_client.c:306`, `:331` at v5.5.3), and follows
301/302/307 in `:1099`. This explains why transport support alone is insufficient.

## Signatures and durable identifiers

Shipped Xteink firmware verifies per-asset signatures from the feed, rather than its detached
whole-feed sidecar. The publisher also signs the exact JSON bytes as asset `releases.json`
under tag `xteink-feed` (`.github/workflows/xteink.yml:603`); that sidecar does not include
the fetch location. Mirroring both files byte-for-byte preserves it as well.
`tools/feed-keys/feed-keys:73` signs the domain, tag, asset filename and SHA-256.
`xteink/orbify/core/UpdateSignature.cpp:60` reconstructs those inputs; `:75` takes only the
last path segment from the download URL. Old and new repository URLs therefore verify with
the identical signature. The OTA regression reads both URLs with the same signed fixture.

Current main's Android updater reads the signed envelope at
`android/companion/app/src/main/java/net/fledgewing/orbitcompanion/AndroidReleaseFeed.kt:9`.
Its **payload bytes, including asset URLs, are signed**; the envelope's fetch URL is not.
Changing the fetch location preserves the original payload and signature. Old payload asset
URLs continue through the normal download redirects. Regenerating payload URLs requires a new
signature; the Android feed publisher already signs every generated payload. The regression
verifies an old-URL payload, rejects a rewritten payload with its old signature, and accepts
it after signing again. This is separate from the Xteink per-asset scheme above. The signed
Android feed must be published before distributing that updater, as described in
[release safety](design/release-safety.md).

The plugin zip uses the same artifact signing scheme. APK verification pins its existing
Android package and signing certificate, independently of repository spelling.

Internal names remain unchanged: Android package, plugin folder, settings, database, SD
paths, NVS namespace, C++ symbols, signing domains, signature field, release asset filenames
and tag prefixes. Credits retain their exact meaning; only the project name changes.
Published release notes and CHANGELOG entries remain historical.

## New-client fallback

New companions try the canonical BookSync feed first, then the previous feed once on any
fetch, JSON or signature failure (`AndroidReleaseFeed.kt:15-25`; `Updater.kt:208-210`). Both
locations pass identical signature checks; neither failure enables unsigned metadata.
Firmware patch `0055-booksync-ota-redirect.patch` follows the same order for transport/HTTP
failures and unusable manifests. It clears parser/candidate state before changing URLs and
never loops back from the legacy feed. Explicit custom firmware feeds have no public fallback.
Firmware still checks the downloaded image's signature before installation; this fallback does
not relax that check or retry a failed image installation with different metadata.

The installer and run-ID sideload helpers also try the previous repository name.
Existing checkouts need only the remote commands printed by the dry-run script; directory
names and internal IDs do not change.

Older GitHub build attestations retain the repository identity at build time. The installer tries both exact repository identities for all artifacts together. For a manual
check of a pre-rename artifact, use its historical `gh attestation verify --repo` identity; redirects
can locate its bundle but cannot rewrite its certificate. Android and firmware updaters do
not depend on GitHub attestation identity for installation.
