# BookSync account sign-in (Android F12-K)

Authorised Android implementation, 2026-11-25. Firmware follows later on X4 Pro,
X4 and X3; no firmware capability is claimed here. The companion owns credentials,
network and normalization. UI uses the library interface and capability flags.

## Pinned source and sign-in

All upstream references below are relative to `upstream/bookorbit/server/src/`,
at `c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7` (`tools/upstreams.lock`).

POST `auth/login` takes username, password, `clientKind: native` and optional
`deviceLabel` (`modules/auth/auth.controller.ts:84`, `modules/auth/dto/login.dto.ts:4`,
`modules/auth/dto/auth-client.dto.ts:4`). Native replies contain the JWT access
and opaque refresh token, both ISO expiry timestamps and session ID
(`modules/auth/auth-session.service.ts:64`). Access defaults to 15 minutes;
refresh to 7 days, configurable (`config/config.ts:27`). Refresh rotates tokens
and extends the session, with a configured 30-second rotation grace
(`modules/auth/auth-session.service.ts:47`, `config/config.ts:32`).
POST `auth/refresh` sends `{refreshToken}` in JSON for native sessions;
POST `auth/logout` sends the same credential and revokes the session
(`modules/auth/auth.service.ts:352`, `:384`). Cookies and native credentials
must not be mixed. Access is `Authorization: Bearer …` (`modules/auth/jwt.strategy.ts:14`).

GET `auth/login-options` reports password policy and OIDC providers. OIDC uses
POST `auth/oidc/:slug/state` followed by browser authorization and POST
`auth/oidc/callback`; backchannel logout is also supported
(`modules/auth/auth.controller.ts:70`, `:159`, `:175`). This initial plain screen
supports password sign-in; OIDC-only accounts need their server's browser flow,
which is deferred. There is no native TOTP/2FA challenge in the pinned login DTO
or password login service (`modules/auth/auth.service.ts:245`). An external OIDC
provider can enforce its own factors. No factor is skipped or emulated.

## Available route inventory

Routes below have no App Attest requirement in their controller. Authentication,
permissions, visible-library scope and server policy still apply. Account data
means the signed-in user's visible libraries across all devices, never a device
filter. There is no separate goals controller: the stored reading goal is in
`auth/me` user settings (`dashboardConfig.readingGoal`); `goal-trajectory` uses a
query goal with a default, so that default must never masquerade as a saved goal.

### user-statistics

- `GET user-statistics/summary` — `modules/user-statistics/user-statistics.controller.ts:63`.
- `GET user-statistics/daily-reading` — `modules/user-statistics/user-statistics.controller.ts:68`.
- `GET user-statistics/reading-heatmap` — `modules/user-statistics/user-statistics.controller.ts:73`.
- `GET user-statistics/reading-source-distribution` — `modules/user-statistics/user-statistics.controller.ts:78`.
- `GET user-statistics/peak-hours` — `modules/user-statistics/user-statistics.controller.ts:83`.
- `GET user-statistics/favorite-days` — `modules/user-statistics/user-statistics.controller.ts:88`.
- `GET user-statistics/session-timeline` — `modules/user-statistics/user-statistics.controller.ts:93`.
- `GET user-statistics/completion-timeline` — `modules/user-statistics/user-statistics.controller.ts:108`.
- `GET user-statistics/goal-trajectory` — `modules/user-statistics/user-statistics.controller.ts:113`.
- `GET user-statistics/progress-funnel` — `modules/user-statistics/user-statistics.controller.ts:118`.
- `GET user-statistics/completion-latency` — `modules/user-statistics/user-statistics.controller.ts:123`.
- `GET user-statistics/genre-reading-time` — `modules/user-statistics/user-statistics.controller.ts:128`.
- `GET user-statistics/reading-pace` — `modules/user-statistics/user-statistics.controller.ts:133`.
- `GET user-statistics/reading-survival` — `modules/user-statistics/user-statistics.controller.ts:138`.
- `GET user-statistics/completion-race` — `modules/user-statistics/user-statistics.controller.ts:143`.
- `GET user-statistics/session-archetypes` — `modules/user-statistics/user-statistics.controller.ts:148`.
- `GET user-statistics/author-genre-chord` — `modules/user-statistics/user-statistics.controller.ts:153`.

### reading-session

- `GET books/:bookId/sessions` — `modules/reading-session/book-reading-session.controller.ts:15`.
- `POST books/:bookId/sessions` — `modules/reading-session/book-reading-session.controller.ts:21`.
- `DELETE books/:bookId/sessions/:sessionId` — `modules/reading-session/book-reading-session.controller.ts:27`.

### statistics

Library composition/metadata, not reading-time totals.

- `GET statistics/format-distribution` — `modules/statistics/statistics.controller.ts:13`.
- `GET statistics/language-distribution` — `modules/statistics/statistics.controller.ts:18`.
- `GET statistics/books-added-over-time` — `modules/statistics/statistics.controller.ts:23`.
- `GET statistics/storage-by-format` — `modules/statistics/statistics.controller.ts:28`.
- `GET statistics/metadata-score-distribution` — `modules/statistics/statistics.controller.ts:33`.
- `GET statistics/library-metadata-completeness` — `modules/statistics/statistics.controller.ts:38`.
- `GET statistics/format-share-over-time` — `modules/statistics/statistics.controller.ts:43`.
- `GET statistics/page-count-distribution` — `modules/statistics/statistics.controller.ts:48`.
- `GET statistics/publication-decade` — `modules/statistics/statistics.controller.ts:53`.
- `GET statistics/publication-year-timeline` — `modules/statistics/statistics.controller.ts:58`.
- `GET statistics/top-authors` — `modules/statistics/statistics.controller.ts:63`.
- `GET statistics/metadata-completeness` — `modules/statistics/statistics.controller.ts:68`.
- `GET statistics/genre-distribution` — `modules/statistics/statistics.controller.ts:73`.
- `GET statistics/summary` — `modules/statistics/statistics.controller.ts:78`.
- `GET statistics/genre-cooccurrence` — `modules/statistics/statistics.controller.ts:83`.
- `GET statistics/metadata-freshness-gauge` — `modules/statistics/statistics.controller.ts:88`.
- `GET statistics/library-integrity-gauge` — `modules/statistics/statistics.controller.ts:93`.
- `GET statistics/acquisition-lag-scatter` — `modules/statistics/statistics.controller.ts:98`.
- `GET statistics/largest-books` — `modules/statistics/statistics.controller.ts:103`.
- `GET statistics/top-series` — `modules/statistics/statistics.controller.ts:108`.

### account-activity

Requires `ViewUserActivity`; unavailable to an ordinary account without that permission. Not used for personal stats.

- `GET account-activity` — `modules/account-activity/account-activity.controller.ts:13`.
- `GET account-activity/summary` — `modules/account-activity/account-activity.controller.ts:18`.
- `GET account-activity/:userId` — `modules/account-activity/account-activity.controller.ts:23`.

### achievement

- `GET achievements` — `modules/achievement/achievement.controller.ts:22`.
- `GET achievements/hints` — `modules/achievement/achievement.controller.ts:28`.

### collection

- `GET collections` — `modules/collection/collection.controller.ts:78`.
- `POST collections/membership` — `modules/collection/collection.controller.ts:85`.
- `GET collections/:id` — `modules/collection/collection.controller.ts:90`.
- `POST collections` — `modules/collection/collection.controller.ts:95`.
- `POST collections/reorder` — `modules/collection/collection.controller.ts:106`.
- `PATCH collections/:id` — `modules/collection/collection.controller.ts:112`.
- `DELETE collections/:id` — `modules/collection/collection.controller.ts:123`.
- `POST collections/:id/books` — `modules/collection/collection.controller.ts:135`.
- `DELETE collections/:id/books` — `modules/collection/collection.controller.ts:148`.
- `GET collections/:id/books` — `modules/collection/collection.controller.ts:161`.
- `POST collections/:id/books/query` — `modules/collection/collection.controller.ts:175`.
- `POST collections/:id/books/jump-buckets` — `modules/collection/collection.controller.ts:181`.

### smart-scope

- `GET smart-scopes` — `modules/smart-scope/smart-scope.controller.ts:58`.
- `GET smart-scopes/:id` — `modules/smart-scope/smart-scope.controller.ts:63`.
- `POST smart-scopes` — `modules/smart-scope/smart-scope.controller.ts:68`.
- `POST smart-scopes/reorder` — `modules/smart-scope/smart-scope.controller.ts:79`.
- `PATCH smart-scopes/:id` — `modules/smart-scope/smart-scope.controller.ts:85`.
- `PUT smart-scopes/:id/kobo-sync` — `modules/smart-scope/smart-scope.controller.ts:96`.
- `DELETE smart-scopes/:id` — `modules/smart-scope/smart-scope.controller.ts:107`.
- `POST smart-scopes/:id/books/query` — `modules/smart-scope/smart-scope.controller.ts:133`.
- `POST smart-scopes/:id/books/jump-buckets` — `modules/smart-scope/smart-scope.controller.ts:139`.

`POST books/files/:fileId/sessions` records a session; it is not a read endpoint
(`modules/reading-session/reading-session.controller.ts:12`). The companion adds
no second session uploader. `GET mobile/year-review/:year` is unavailable because
the entire controller requires attestation (`modules/year-review/year-review.controller.ts:10`).
Activity overview/calendar/day/detail routes are unavailable
(`modules/user-statistics/user-statistics.controller.ts:21`–`:63`), as are
achievement celebrations (`modules/achievement/achievement.controller.ts:34`).
Smart-scope GET book execution requires attestation; the separately declared
query operations above retain their own policy. No attempt is made to forge,
replay, bypass or impersonate the server app. Its fixed application/signature
policy and Google-root validation are respected (`modules/app-attest/app-attest.policy.ts:21`,
`modules/app-attest/app-attest.policy.ts:37`). A 403 disables that feature;
it does not initiate refresh or retry. A 401 permits one refresh and one replay.

## Connector setup

JWT `GET/POST/PATCH/DELETE koreader/credentials` requires `KoreaderSync`
(`modules/koreader/koreader.controller.ts:84`–`:108`). GET returns null if absent,
otherwise username and preferences, never a password or sync key
(`modules/koreader/koreader.service.ts:177`). Creation accepts a password and
stores bcrypt plus the kosync MD5 key (`:104`). BookSync generates a random
connector password only when absent and stores its derived key privately.
Existing credentials are preserved; reuse the current reader's matching connector
key. An existing connector with no known key needs the legacy connector login.
One account login cannot recover an existing secret from this server contract.

JWT `GET/POST opds-users`, `PATCH/DELETE opds-users/:id` requires `OpdsAccess`
(`modules/opds/opds-user.controller.ts:11`). Listing and creating do not return
passwords (`modules/opds/opds-user.service.ts:28`, `:45`). BookSync's catalog and
download integration uses the KOReader connector, so this slice creates no unused
OPDS identity. A future OPDS consumer must reuse a known identity or create a
separate random credential, never reset an existing one silently.

## Reuse and performance

Extend `ko/library.lua:5` and its private `ko/library_bookorbit.lua:5` binding,
`LibraryReadModel.kt:20` (bounded publication), `Worker.kt:108` (one batched
projection), `CacheStore.kt:20` (owned SQLite), `Core.kt:55` (timing log), and
`ReadingStats.kt:20` (worker aggregation). Connector stats from F12-F feed the
same projection, with account fields taking precedence. Tokens and account
passwords never enter plugin UI, events, shared settings or logs.

Every screen/widget inherits a strict budget. Account screen paint: one small
state row, ≤16 KiB, zero subprocesses/network, one local library read. Explicit
sign-in/refresh commands perform bounded HTTP off the UI thread, not during a
paint. Each call and paint emits one info timing span without credentials.
Account snapshots cap each reply and all decoded rows. Existing `reading.stats`
remains one ≤16 KiB materialized row per Home paint. Account days precede connector
days; account hours/sessions precede local fields. Only proven not-yet-uploaded
local minutes may be added to today. Fetch time is not an upload watermark;
without one, show local today separately rather than double-counting it.


## Implementation notes and follow-up

F12-K extends the F12-F connector projection (`BookOrbitLibrary.kt:8`) and
`ReadingStats.combine` rather than introducing another reading-statistics store.
Account fetches are normalized to ≤366 daily input rows, 24 hourly rows, ≤3000
weekly sessions (server cap: `modules/user-statistics/user-statistics.service.ts:71`)
and ≤14 completion-month rows before private persistence. Session IDs deduplicate;
only weekly count, longest duration and completeness enter the snapshot. A capped
week is marked incomplete. Transient failures retain the last snapshot as stale;
403 removes only that feature until the next sign-in/process session. Attested
activity details, year review and celebrations always have capabilities false.

`LibraryReadModel` adds `account.state` and extends `capabilities.account` and
`capabilities.stats`; both the module and worker tests cover these operations.
The Lua UI calls `Library.openAccount`; its private binding uses the existing
trusted provider and applies a one-time connector revision at lifecycle resume.
Sign-out clears private tokens/statistics and invalidates owned views; it preserves
the independent legacy reader login. The setup screen is intentionally plain under
the maintainer's F12-K instruction. Stored account identity is isolated by server,
account ID and connector username. Re-sign-in preserves a known connector key only
for the same server/account; no old token or job is reused for another owner.

Next slice can use these normalized capabilities and snapshots for final account
screens, browser/OIDC authentication and account-only library access. List writes
remain disabled: having an account session does not grant a new UI write feature.
