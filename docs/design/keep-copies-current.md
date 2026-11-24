# Keep book copies current

Status: approved by the user (2026-11-22); Android ships it in v0.11.1.

## Why

BookOrbit writes metadata (tags, series) into the library file, so the file's partial MD5
changes ([server contract](../server-contract.md#a-metadata-write-changes-the-file-hash)). A copy
downloaded before then no longer matches: the server marks it `positionCompatible: false`, and
progress, highlights and bookmarks stop syncing for that book.

## What Orbit does

- **Find.** A copy is changed when BookOrbit's state marks it `positionIncompatible`, or when a
  saved book detail lists its library file with a `fileHash` other than the copy's
  Orbit Companion looks this up (`COPIES`, `CopiesLogic`; docs/design/companion-worker.md), so
  KOReader's UI thread reads no saved detail and checks no file. Copies not on this reader are skipped. BookOrbit's
  plugin has no path for updating a copy (its bulk download skips books already on the device,
  `bookorbit_catalog_bulk_download.lua:965`), so Orbit adds one.
- **When.** Online only, never while reading (the [reading gate](reading-gate.md)), one book at a
  time, from a queue kept on disk that resumes. It looks when a Full refresh starts and again when
  it ends, when BookOrbit Home opens (over a book too), at a wake or the network coming up, and
  when a book closes (at most every 10 min, except a Full refresh). v0.11.1 looked only on catalog
  reads, which run in the plugin's child process, so on the M8C it never ran. The open book is
  never replaced.
- **Saved details.** The hashes come from the offline mirror's details of every book (v0.11.2) and
  the end-of-book cache, whichever is newer.
- **Replace in place.** The plugin's own Download path: the detail with this reader's delivery
  variant (`fetchDeliveryBook`), its supported file (the same library file when listed), and
  `downloadFile` to the **same path**: the download is checked against `fileHash` and renamed
  over the old file in one step (`bookorbit_download_transfer.lua:186-195`), then linked
  (`linkDownloadedFile`, match-check and `linkFile`). A copy that already matches, or a file with
  no hash to check, is left alone.
- **Carry over.** The KOReader sidecar is kept by path (`book.sdr` next to the book, or the
  `docsettings` folder), and the text is unchanged, so positions, highlights and bookmarks still
  fit. Orbit then moves what is keyed by the file hash:
  - the sidecar's `partial_md5_checksum`, which KOReader never updates by itself
    (`readerui.lua:496-500`);
  - KOReader's hash-keyed sidecar folder, when that location is used: copied to the new hash;
  - KOReader's reading statistics (`book.md5`);
  - BookOrbit's state, through its own repair for a file whose bytes changed
    (`repairFileIdentity`, `bookorbit_state_manager.lua:453`, the same call its
    `getDocumentDigest` makes, `bookorbit_progress_sync.lua:80-108`).
- **Log.** `copies: N changed; replacing`, then one line per book: replaced (old -> new hash),
  already current, or failed (the old copy stays).
- **Setting.** Orbit menu › "Keep book copies current", on by default.

## Xteink

Built in overlay patch 0034 (`CROSSINK_TAILNET_ORBIFY_COPY_REFRESH`, X4 Pro, X4 and X3); details
in [XTEINK-BUILD-NOTES](XTEINK-BUILD-NOTES.md#keep-book-copies-current-patch-0034-2026-11-22).

- **Find.** The sleep sync (and the BookOrbit Home's refresh) hashes the catalog's downloads and
  sends them through the match check, 20 per request; a copy is queued when the server matched it
  to the same book with `positionCompatible: false`. Unchanged library token: one batch only.
- **When.** Only the sleep sync replaces copies (Wi-Fi up, no book open), one book at a time, for up
  to 180 s per sleep, from `/.crosspoint/orbify/copy-refresh.tsv`, which resumes after a wake or a
  reset. A sync that finds the open book changed queues it ("Updates when you leave the book").
- **Replace in place.** Same path and name: the catalog's staged download (`.part`, resumed,
  checked as an EPUB, the old copy kept at `.old`), then the copy's hash must equal the detail's
  `fileHash`, or the old copy goes back. A file without `fileHash` is never downloaded.
- **Carry over.** On the Xteink the position, highlights, bookmarks and sync state live under the
  content hash (`/.crosspoint/book_<hash>`), so they are moved to the new hash by the fork's
  `BookUpdateMigration`, the same step its catalog update runs.
- **Log.** `ORB Copy refresh: <n> queued`, then per book `replaced: <old> -> <new>`, `already is
  the library file`, or the failure (the old copy stays).
- **Setting.** BookOrbit Sync › "Keep Book Copies Current", on by default.
