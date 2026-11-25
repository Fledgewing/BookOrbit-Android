# BookSync repository rename: device compatibility

The coordinator owns the GitHub rename. This change does not rename the remote repository,
publish a release, move a tag or touch a device.

**Verdict: hold an unconditional rename approval.** Every inspected update transport follows
301/302/307 redirects across HTTPS hosts. However, shipped Xteink manifest handlers also feed
redirect response bodies to the JSON parser. Certain non-JSON redirect bodies prevent the final
feed from being parsed. The regression demonstrates this using a numeric status line followed by the feed.
Patch 0055 fixes this for future firmware and supports the previous
feed name before the rename. Merging it does not fix readers already in the field.

The existing raw-content alias currently serves the feed directly with HTTP 200, so this
problem is conditional, not an observed outage. For a guarantee independent of that service
behaviour, first distribute and device-test the compatible firmware. CrossInk 1.6 is retired;
its stable readers need continued direct HTTP 200 service at their existing feed URL until a
compatible stable 2.x release reaches them. Do not claim those readers have received this fix.

## Inspected clients

All 53 local Android release tags use `HttpURLConnection` without disabling redirects. All
20 local firmware tags resolve to the four upstream commits below. The audit includes the
retired stable firmware, not only current source. Tag counts describe the local tag inventory
at this change, not an assertion that every tag was installed on a device.

| Client | 301 / 302 / 307, including another HTTPS host | Evidence |
|---|---|---|
| Android companion, earliest release onward | Yes. Automatic GET redirects; HTTP/HTTPS scheme changes are not followed. | `v0.1.0:companion/app/src/main/java/net/fledgewing/orbitcompanion/Updater.kt:164`; current `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/Updater.kt:275`. [Android response handling](https://developer.android.com/reference/java/net/HttpURLConnection#response-handling) documents cross-origin redirects. |
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

The feed carries per-asset signatures, not a signature over the feed JSON or its full URL.
`tools/feed-keys/feed-keys:73` signs the domain, tag, asset filename and SHA-256.
`xteink/orbify/core/UpdateSignature.cpp:60` reconstructs those inputs; `:75` takes only the
last path segment from the download URL. Old and new repository URLs therefore verify with
the identical signature. The OTA regression reads both URLs with the same signed fixture.
The plugin zip uses the same artifact signing scheme. APK verification pins its existing
Android package and signing certificate, independently of repository spelling.

Internal names remain unchanged: Android package, plugin folder, settings, database, SD
paths, NVS namespace, C++ symbols, signing domains, signature field, release asset filenames
and tag prefixes. Credits retain their exact meaning; only the project name changes.
Published release notes and CHANGELOG entries remain historical.

## Before and after the coordinator's rename

1. Merge this change with all checks green. Android and default firmware builds prefer the
   new repository name and fall back once on HTTP 404 to the previous name. Explicit custom
   firmware feeds never fall back to a public feed.
2. The [shared-version bridge](design/unified-version.md) on main can carry this redirect fix
   in the same rollout; its publication and device validation are still pending. Arrange a
   device-tested compatible firmware rollout, or explicitly preserve direct HTTP
   200 service at old raw feed URLs for every reader that remains on older firmware.
3. Rename using GitHub's repository rename operation. Never create a second repository at
   the old name: that removes the redirects, per [GitHub's rename guidance](https://docs.github.com/en/repositories/creating-and-managing-repositories/renaming-a-repository).
4. Verify old and new web, API, raw-feed and release-download URLs immediately. Check the
   earliest Android alias too. Confirm the old raw feed returns 200 directly, valid JSON,
   and the same release signatures. Follow downloads through the asset host and verify
   SHA256SUMS. Do not log expiring asset-host query strings.
5. Update local remotes after the rename. Existing checkouts need no directory rename.

Read-only probes on 2026-11-25 against the existing earliest Android alias found web 301,
API 301, and raw feed 200 with zero redirects and two release records. These are observations
of the existing alias, not a test of the future rename. No device validation was performed.

Older GitHub build attestations retain the repository identity at build time. When verifying
a pre-rename artifact, use that historical `gh attestation verify --repo` identity; redirects
can locate its bundle but cannot rewrite its certificate. Android and firmware updaters do
not depend on GitHub attestation identity for installation.
