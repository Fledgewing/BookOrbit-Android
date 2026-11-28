# F37c: independent logins and sign-out

Status: **NEEDS APPROVAL**. [Review gallery](f37c-account.html) ·
[approved screens](SCREENS.md) · [plan](PLAN.md).

F37b firmware PR #48 implements the eleven approved server-account presentations.
Its approval does not cover independent sync/OPDS entry, login-origin review,
removal or account sign-out on all three readers. The Home revision-16 X4 examples
are semantic/visual references, not missing X3 approval. This docs-only proposal
adds those states; none is enabled in firmware. Merging this PR is not approval.
No firmware source, integration pin, feature claim or release changes.

## Android 0.12 reference

Reference commit: `ed740a0b` on BookSync `feature/0.12`.
Paths below are relative to the BookSync integration repository:

- `android/koreader/orbit.koplugin/logic/account.lua:3–18`: independent login
  names, origin labels and availability; `:19–33`: all sign-out origin combinations;
  `:35–42`: errors; `:43–56`: Created/Found/Kept/Not set result wording.
- `android/koreader/orbit.koplugin/ko/account.lua:41–69`: worker delivery and
  visible-form completion; `:70–89`: transient field entry; `:93–143`: summary,
  sign-out/removal, result, separate service forms and explicit replacement.
- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/AccountActivity.kt:33–40`:
  three optional logins; `:43–69`: separate Server/User/Password capture, explicit
  derived-sync-key option, Save login, removal and replacement; `:76–82`: errors
  and closed-activity guard.
- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/LibraryAccount.kt:84–92`:
  Library command seam with secret erasure; UI does not select an adapter.

The plugin provides the detailed confirmation wording; the companion confirms
that an explicit derived sync key is distinct from a password. Firmware says
“this reader” in place of the plugin-specific “KOReader”. Passwords remain masked;
no actual credential, identity, address or private photo is included.

## Semantics and navigation

Each service has its own credentials. A sync login never signs into the server
account or supplies OPDS credentials. OPDS supports catalog browsing/downloads
without a server account. Account sign-in fills absent account-managed slots;
it keeps separately entered logins. Replacing one is an explicit action available
only while signed into the server account. Origin is a service value, never inferred
from matching names or addresses. A password and a derived sync key are distinct
input modes; deriving and validating them belongs inside the adapter.

Sign-out removes the server session and only the connectors it supplied. Own sync
and OPDS logins stay independently. Downloaded books and local places stay; stats
from other devices stop. Removing just Sync login stops position sync until it is
set again. Removing just OPDS login stops remote browsing/downloads, preserving
local books. Nothing in these actions deletes books or changes server records.
They do not unpair the private connection, forget Wi-Fi or discard durable work.
An old-owner job cannot be sent under another account's credentials.

Stay signed in and Keep it start focused on button readers; Back has the same
non-destructive effect. Summary → selected service preserves focus on return.
Selecting a field opens entry; the entry illustrations omit management rows to
reserve a bottom keyboard, rather than compress touch targets. Cancel clears
transient fields. Errors remain inline in the selected form; the five isolated
error views review wording, not extra destinations. Done acknowledges origin
results and returns to the same summary. No completion popup or automatic retry.

## Proposed states — all NEEDS APPROVAL

Every state has X4 Pro touch, X4 Classic buttons and X3 bounded-text views.
The gallery has **31 states / 93 device views**.

| Gallery IDs | Coverage |
|---|---|
| `logins-summary` | Three optional logins and origins |
| `sync-none`, `sync-user`, `sync-account` | Not set / Set by you / Set up by your account |
| `opds-none`, `opds-user`, `opds-account` | Same independent OPDS states |
| `sync-entry`, `sync-derived-entry`, `opds-entry` | Separate field entry; Pro bottom keyboard; explicit sync-key option |
| `sync-saving`, `opds-saving` | Pending submission and Cancel |
| `sync-remove`, `opds-remove` | Service-specific consequence and Keep it / Remove |
| `login-unauthorized`, `login-unavailable`, `login-forbidden`, `login-expired`, `login-failed` | Inline errors, same form and secret erasure |
| `signout-<sync>-<opds>` | All nine pairs of `none`, `account`, `user`; exact conditional keep/remove wording |
| `origin-result-kept`, `origin-result-supplied`, `origin-result-missing` | Kept / Created / Found / Not set after server sign-in |

Real product frames and attribution are documented in [frames/README.md](frames/README.md).
Screen styling follows the approved firmware gallery: grayscale, ruled rows,
serif section headings, rounded actions and visible focus. The supplied 0.11 X4
Home photo informs compact spacing, bold labels and top-right card icons; its
private content is neither copied nor committed. Pro and Classic use the gallery's
480 × 800 viewport; X3 uses its 528 × 792 aspect with text-only content. Product
frames establish device context, not measured native font fit.

## Implementation and acceptance after approval

Only immutable Library values and typed intents cross the UI boundary. Public
snapshots contain availability/origin/status and correlation, never stored secrets,
protocol keys, adapter DTOs or mutable jobs. Services own credential storage,
normalization, origin-sensitive removal, epoch changes and sole-writer dispatch.
No network, parsing, file access or persistence during paint. No new sync writer.

Before implementing, test all nine sign-out origin combinations, each independent
save/remove/replace, unsupported capability, failed auth preservation, derived-key
handling, source/transient erasure, epoch rejection and A → B → A. Host tests must
compile production account policy and UI controller code. Run every approved
scene with touch/focus/Back, pending completion after close and account switch in
all three simulator profiles; a closed form never reads, repaints or reopens.
Keep native reader position and capture unchanged. No cache reset is required.

Maintainer-only hardware acceptance: open Your server on Pro, Classic and X3/C3;
verify origins and the exact sign-out consequences with each mixed-origin pair.
Cancel first, then explicitly confirm. Check retained local books/places, independent
service behavior, bottom-docked touch keys, masked fields and no late presentation
over a resumed EPUB. Inspect internal free/largest heap and task-stack watermarks.
Agents never flash readers or open serial ports. Before firmware merge, run the
host gate, all three simulator suites and three real builds with bin/map/static-RAM
measurements and at least 131,072 bytes free in each unchanged app slot.

Documentation validation: Chromium checked all 93 device views at both 1200 px
and 390 px widths (**186 view checks**): no content clipping, page overflow,
broken scene anchors or page errors. Representative entry, mixed sign-out, summary
and origin-result views were visually inspected. Frame images are local and
unmodified. Existing approved gallery articles are byte-for-byte unchanged.
