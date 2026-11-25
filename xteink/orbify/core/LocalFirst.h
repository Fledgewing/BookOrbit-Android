#pragma once
// BookSync local-first catalog (docs/design/local-first/DESIGN.md, ROADMAP item 4): the decisions the
// Xteink catalog makes about saved lists, as pure functions. The firmware glue is overlay patch
// 0029; xteink/test/localfirst_test.cpp checks these against shared/fixtures/localfirst/ (the
// stamp and overlay tables Android reads too) and the design's own cases.
#include <cstddef>
#include <cstdint>

namespace orbify {

// --- freshness stamp ("Shared concepts") ---------------------------------------------------

// fetchedAt: epoch seconds of the last successful fetch of the view, 0 = unknown (clock never
// set, or a page saved before stamps). failed: online, but the server did not answer.
// "updated just now" · "updated 12 min ago" · "Not updated · saved 3 h ago" · "Offline, saved 3 h
// ago" · "Offline". Returns the length written (always NUL-terminated).
size_t formatStamp(bool online, uint32_t fetchedAt, uint32_t now, bool failed, char* out, size_t capacity);
// "just now" / "12 min" / "3 h" / "2 d" for an age in seconds.
size_t formatAge(uint32_t seconds, char* out, size_t capacity);

// --- device wins while newer -----------------------------------------------------------------

enum class BookState : uint8_t { Unknown = 0, Reading, Complete };

struct ServerBook {
  int percent = -1;            // progressPercentage, -1 = none
  BookState state = BookState::Unknown;
  uint32_t lastReadAt = 0;     // epoch seconds, 0 = none
};
struct DeviceBook {
  bool known = false;          // this reader has a position or status for the book
  int percent = 0;
  BookState state = BookState::Unknown;
  uint32_t changedAt = 0;      // epoch seconds of the last local change
  bool pending = false;        // the change still waits to upload
  bool blocked = false;        // its upload is blocked or retrying
};
struct ShownBook {
  int percent = -1;
  BookState state = BookState::Unknown;
  bool notSynced = false;      // the "not synced" mark (lists only)
  bool deviceWins = false;
};
// The device's value is shown when it changed after the server's lastReadAt or still waits to
// upload; otherwise the server's. "not synced" shows only when the upload is blocked, or a change
// waits and auto-sync is off.
ShownBook overlayBook(const ServerBook& server, const DeviceBook& device, bool autoSync);

// --- what the catalog does offline ---------------------------------------------------------

// Item 4 change 3: with a saved root the catalog opens in place and offline (no network boot on
// the C3, no Wi-Fi join elsewhere).
bool catalogOpensInPlace(bool hasSavedRoot, bool hasCredentials);

enum class OfflineTap : uint8_t { Open, ConnectAndOpen, ConnectAndDownload, OpenBook };
enum class RowTarget : uint8_t { List, Book };
// Change 6 (D2): a tap offline on a list or a book. saved: the list's page is saved; onCard: the
// book's file is on this reader.
OfflineTap offlineTapAction(RowTarget target, bool saved, bool onCard);

// Change 7: a sort or filter offline is done on the reader when the saved pages hold the whole list.
bool canSortLocally(size_t savedRows, size_t total);

// Change 7, search: true when the title or the author contains every word of the query, folded
// for case and Latin accents.
bool searchMatches(const char* query, const char* title, const char* author);

// --- the saved-list folder ------------------------------------------------------------------

constexpr size_t MAX_SAVED_PAGES = 96;
// Change 10: which of `count` pages to delete so the newest MAX_SAVED_PAGES stay (an unstamped page,
// savedAt 0, is the oldest). Fills `drop` with indexes, returns how many.
size_t pagesToEvict(const uint32_t* savedAt, size_t count, size_t* drop, size_t capacity);
// owner.json's key: FNV-1a of "<server url>\n<username>" (change 1).
uint32_t ownerKey(const char* serverUrl, const char* username);

}  // namespace orbify
