# BookSync repository rename: device compatibility

The coordinator owns the GitHub rename. This change does not rename the remote repository,
publish a release, move a tag or touch a device.

## Maintainer-approved bridge rollout

The bridge replaces the feed-only repository proposal from #130. Ship one update while the
repository is still `Fledgewing/Orbify`, then rename to `Fledgewing/BookSync` **without recreating
the previous name**. Devices update once to the bridge and later OTA to ordinary releases.
GitHub's API and release-download redirects remain available to stragglers. Reusing the old
name would remove those redirects ([GitHub rename guidance](https://docs.github.com/en/repositories/creating-and-managing-repositories/renaming-a-repository)).

1. Device-test the bridge on Android, X4 Pro, X4 Classic and X3. Agents do not touch devices.
   Publish it as the **next Android Stable**, not just a preview/RC, so Stable-only clients and
   old Lua patches see it through today's `releases/latest`. Use a patch version above the
   installed previews/RCs (the planned 0.11.4 Stable follows 0.11.3 RCs and 0.11.4 previews).
   Companion and plugin remain one publication unit; the plugin gets the bridge through the
   companion. No package, signing certificate, plugin folder or settings keys change.
2. Publish the **next stable Xteink bridge release**, with images for X4 Pro, X4 Classic and
   X3. It must be the latest firmware release across channels, not just an opt-in preview.
   Keep the old numeric firmware tag scheme so 1.6/older 2.x readers can compare and install
   it. Record `booksync_version=<Android Stable version>` in its release notes and feed.
   The current pinned CrossInk base is an RC; this does not authorize calling an upstream
   RC stable. Wait for a stable base/bridge under the normal release policy. The separate
   [0.12 version bridge](design/unified-version.md) can carry the rename support too.
3. Both signed feeds must list the published bridge and every reader's image. Keep the
   bridge available; do not withdraw it or publish a newer preview that bypasses it before
   cutover. Bring readers online and allow time for one OTA bridge install. Publication is
   a machine-checkable gate, **not proof that all devices installed it**; there is no telemetry.
   The coordinator decides when the rollout has had sufficient time and accepts the residual
   risk below. **The rename waits for these stable bridge publications and device validation.**
4. Run the script's read-only gate check with the exact Android product version and legacy
   firmware tag. Add `--apply` only when ready for cutover. Never create a replacement repository,
   move a tag or rewrite published release notes/history to make the checks pass.

## Accepted residual risk and recovery

A CrossInk **1.6 X4 reader that misses the bridge** may fail to parse a raw-feed redirect body
and stop discovering OTA updates. Its transport follows redirects, but its streaming parser
also consumes the intermediate body. Being online after the rename alone does not repair a
poisoned manifest. The same unfiltered manifest handler exists in inspected pre-bridge 2.x
builds; the single residual risk is the raw-manifest path, especially retired 1.6 readers.
GitHub may serve the old raw URL directly with HTTP 200 today, but that is not a guaranteed
replacement for installing the bridge. The maintainer accepts this risk for missed bridges.

Before cutover, bring an affected reader online and install the stable bridge once OTA from
the existing feed. After cutover, if the old raw alias still returns direct 200, one online
bridge install also works; otherwise download the matching bridge image from BookSync and
install it through the reader's **File Transfer** workflow. Confirm the correct reader model
and the published checksum/signature. Once the bridge is installed, later updates use the
canonical feed. Do not erase NVS/settings or change internal IDs as a recovery step.

## Exact old URL inventory

The two raw JSON feeds below are the complete default feed paths in the inspected clients.
The detached Xteink signature is listed too, although shipped firmware checks per-image
signatures and does not fetch that sidecar itself. Arbitrary user-specified test feeds are
outside this migration and never fall back to public feeds.

| Old URL (query variants share the same endpoint) | Consumers and source evidence | Rename behavior |
|---|---|---|
| `https://raw.githubusercontent.com/Fledgewing/Orbify/xteink-feed/xteink/releases.json` | Retired stable `xteink-v1.6.1.114+bookorbit.9:xteink/tailnet/tailnet_build.py:24-27,395-396`; current `xteink/tailnet/tailnet_build.py:31-35,564-570`. Used from 1.6.1.111 and 2.0.0.110 onward; earlier API users are listed below. | Bridge reads BookSync first, then the previous name; unbridged readers have the residual risk above. |
| `https://raw.githubusercontent.com/Fledgewing/Orbify/xteink-feed/xteink/releases.json.sig` | Publisher `.github/workflows/xteink.yml:667,690`; detached feed signature, not a separate client manifest. | Same branch/path after renaming; the coordinator verifies the sidecar too. |
| `https://raw.githubusercontent.com/Fledgewing/Orbify/android-feed/android/releases.json` | Signed-feed companion on main: `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/AndroidReleaseFeed.kt:9-10`; no separate plugin feed. | Bridge checks both names and verifies the same signed envelope. |
| `https://api.github.com/repos/Fledgewing/Orbify/releases/latest` and `/releases?per_page=N` | Shipped `v0.7.0:android/companion/app/src/main/java/net/fledgewing/orbitcompanion/Updater.kt:40-41,144-147`; `v0.11.3-rc.17:android/companion/app/src/main/java/net/fledgewing/orbitcompanion/Updater.kt:40-41,207-210`; Lua `v0.7.0:android/koreader-patch/2-orbit-android.lua:2312,2368` (`N=30` in that patch). | Preserved by GitHub rename redirects; never recreate the old name. |
| `https://api.github.com/repos/Fledgewing/Orbify/releases?per_page=25` | Earliest firmware `xteink-v1.6.1.104+bookorbit.8:xteink/tailnet/tailnet_build.py:23-25,392-393` and `xteink-v2.0.0.106+bookorbit.1-rc2:xteink/tailnet/tailnet_build.py:23-25,392-393`. | API redirects remain; raw-manifest parsing caveat still applies to unbridged firmware. |
| `https://api.github.com/repos/Fledgewing/BookOrbit-Android/releases/latest` and `/releases?per_page=N` | Earliest companion `v0.1.0:companion/app/src/main/java/net/fledgewing/orbitcompanion/Updater.kt:40-41,110-113` (`N=5`); patch `v0.6.2:koreader-patch/2-orbit-android.lua:2310,2366`. | Historical alias must be checked separately; verify it still resolves to the renamed project. |
| `https://github.com/Fledgewing/Orbify/releases/download/<tag>/<asset>` (also historical `BookOrbit-Android` paths) | URLs returned by those APIs and already stored in published feeds; `v0.11.3-rc.17:android/companion/app/src/main/java/net/fledgewing/orbitcompanion/Updater.kt:228-246`; firmware `OtaUpdater.cpp` uses the manifest's asset URL. | Keep GitHub redirects for cached URLs and old signed payloads. New feed generation uses the current repository name. |

The plugin from 0.8 has no independent update/feed HTTP reader:
`android/koreader/orbit.koplugin/ko/updater.lua:25-30` delegates to the companion.
Older Lua patches use the Releases API above, not a raw plugin feed.

## Coordinator script and verification

`tools/rename-to-booksync.sh` is dry-run by default. With no arguments it prints an offline
plan. With both version arguments it performs the read-only publication/signature checks;
`--apply` repeats all checks before the sole mutation, `gh api --method PATCH ... -f name=BookSync`.
Use actual published versions; these placeholders are not a publication command:

```sh
tools/rename-to-booksync.sh --bridge-version MAJOR.MINOR.PATCH --firmware-tag xteink-vLEGACY_VERSION
# Later, coordinator only: repeat those arguments and add --apply.
```

The gate also checks the actual first 5/25 release-list results used by legacy clients.
It requires the exact bridge as Android Stable/latest; the latest firmware release
must also be stable, carry the same product-version marker and contain all three images.
The signed Android feed must include the bridge, companion and plugin, with no withdrawal or
higher offered preview. The signed Xteink feed must include that bridge for every reader.
Feed assets must match the published release assets. The existing signing tool checks the
root certificate, minimum key serial and exact feed bytes. A missing artifact, signature,
channel, version marker or feed entry fails before PATCH. The new name must still be unused.

Before renaming, the canonical **feed branch/path layouts** live in the current repository:
`android-feed/android/releases.json` and `xteink-feed/xteink/releases.json` under the old slug.
The future BookSync raw URL cannot be required to exist before the repository has that name.
After renaming, the same branches and signed content live under BookSync automatically.
The script checks that the repository ID survives the rename; it never creates repositories,
publishes releases, changes remotes or writes feeds.

Post-rename checks require new API URLs to return direct 200, old API URLs to redirect and
resolve to 200, and old/new companion, plugin and all reader-image downloads to resolve to
200 with matching SHA-256. A canonical GitHub release-download URL itself normally redirects
to the asset host; its final response must be 200. Canonical raw JSON/sidecar URLs must return
direct 200. An old raw URL may redirect or transparently return 200; either must deliver the
same bytes as the canonical URL. This handles GitHub's existing direct-200 raw aliases without
mistaking them for a failed rename. The canonical signatures are checked again afterward.
The script disables local curl configuration, only follows redirects when explicitly requested,
requires HTTPS throughout and never prints expiring asset-host URLs. It retries propagation
failures for one minute and then stops for coordinator inspection; it never automatically
renames back or creates a repository as a workaround. After a partial failure, inspect the
URLs below and repository state before retrying any mutation.

Manually check the earliest `BookOrbit-Android` alias as well. Test one bridge-to-later-release
OTA on each reader after cutover. Keep all internal IDs, historical tags, asset names and
signing identities unchanged. Local checkout directories need no rename; the script prints
both HTTPS and SSH `git remote set-url` commands for the coordinator to apply.

## Inspected clients

All 54 local Android release tags use `HttpURLConnection` without disabling redirects. All
21 local firmware tags resolve to the four upstream commits below. The audit includes the
retired stable firmware, not only current source. Tag counts describe the local tag inventory
at this change, not an assertion that every tag was installed on a device.

| Client | 301 / 302 / 307, including another HTTPS host | Evidence |
|---|---|---|
| Android companion, earliest release onward | Yes. Automatic GET redirects; HTTP/HTTPS scheme changes are not followed. | `v0.1.0:companion/app/src/main/java/net/fledgewing/orbitcompanion/Updater.kt:164`; current `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/Updater.kt:276`. [Android response handling](https://developer.android.com/reference/java/net/HttpURLConnection#response-handling) documents cross-origin redirects. |
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
under tag `xteink-feed` (`.github/workflows/xteink.yml:667`); that sidecar does not include
the fetch location. Moving the repository without editing either file preserves it as well.
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
fetch, JSON or signature failure (`AndroidReleaseFeed.kt:15-31`; `Updater.kt:208`). Both
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
