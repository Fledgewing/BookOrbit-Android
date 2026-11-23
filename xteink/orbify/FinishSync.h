#pragma once
// Orbify: mark done at the end of a book (docs/design/end-of-book/DESIGN.md, ROADMAP item 1), the
// firmware side of core/FinishQueue. Compiled in with CROSSINK_TAILNET_ORBIFY_FINISH (overlay
// patch 0027); every function is a no-op without it.
//
//   - Every finish or un-finish on the reader (the End-of-Book page, the 99% prompt, the menus,
//     the book's stats page, the Library's long-press) passes through BookSyncFile's
//     onFinishedChanged, which calls onFinishedChanged() here: it writes or deletes the book's
//     job in /.crosspoint/orbify_finish.bin (and .bak, the second slot).
//   - Every BookOrbit sync drains the queue on its own connection, after the book's progress.
//   - An automatic sync holds a stale position of a book finished here (holdPush).
#include <cstdint>
#include <string>

namespace OrbifyFinish {

// Settings > BookOrbit Sync > Mark Finished at End (D1: on by default).
bool autoMarkEnabled();
// The reader's End-of-Book page, every frame: true once when the page is reached.
bool reachedEnd(bool atEndOfBook);

// A book was marked finished (or unfinished) on this device.
void onFinishedChanged(const std::string& bookPath, bool finished);

// Sends what is due, on the BookOrbit session the caller holds open. knownHash: this sync's
// document hash when the server answered progress for it (or ""). manual: a sync the reader
// started (retries parked jobs). stop: checked between jobs.
void drain(const std::string& knownHash, bool manual, bool (*stop)() = nullptr);

// True when an automatic sync must not push this position (0..1) of this book.
bool holdPush(const std::string& bookPath, const std::string& hash, float percentage);

}  // namespace OrbifyFinish
