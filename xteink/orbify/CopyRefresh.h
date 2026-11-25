#pragma once
// Orbify: "Keep book copies current" (patch 0034, docs/design/XTEINK-BUILD-NOTES.md). When the
// server rewrites a library file (tags or a cover written into the EPUB), the card copy stops
// syncing highlights and bookmarks (positionIncompatible). This finds those copies and replaces
// them in place, one book at a time, with their reading position, highlights and bookmarks
// carried over (BookUpdateMigration). core/CopyQueue holds the rules and the queue format.
//
// It runs only in syncs where Wi-Fi is already up and no book is on screen (the user's ruling,
// 2026-11-23: these readers cannot reach Wi-Fi when a book is closed): the sleep sync (every
// queued copy, the book that was open included), the BookOrbit Home's refresh and a Full refresh.
// A sync while reading only queues the open book's copy; nothing is offered or swapped on screen.
// In the sleep sync the requests ride the sync's own connection and need OrbifyHeap's
// floor; short of it, or of time, the rest carries over to the next sync.
#include <cstddef>
#include <cstdint>
#include <string>

namespace OrbifyCopyRefresh {

// The "Keep book copies current" setting (BookOrbit Sync, on by default).
bool enabled();

// With Wi-Fi up: hashes the catalog's downloads on the card and asks the server's match check
// about them, 20 at a time; the copies it calls older ones of their book's file are queued.
// When the server's library token is the one the last full pass saw, it stops after the first
// batch. Returns the number of copies newly queued.
size_t detect(bool (*cancelled)());

// With Wi-Fi up and no book on screen: replaces queued copies one at a time until the queue is
// empty, cancelled() says stop, or budgetMs is used. Each replacement is checked against the
// library file's hash before it goes live; the position, highlights and bookmarks move with it.
// where: the sync, for the log ("sleep sync", "Home", "Full refresh"). Returns the number replaced.
size_t run(bool (*cancelled)(), unsigned long budgetMs, const char* where);

// A sync that found the open book's copy is an older one of its library file: queued for the next
// sync that may replace it.
bool enqueue(int64_t bookId, const std::string& path, const std::string& cardHash);

// Copies waiting (not given up).
size_t pending();

// The server's library version as the last full match-check pass saw it ("" = none yet): the
// offline mirror's "the library changed" rule (orbify/Mirror).
std::string libraryVersion();

}  // namespace OrbifyCopyRefresh
