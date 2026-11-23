#pragma once
// Orbify: "Keep book copies current" (patch 0034, docs/design/XTEINK-BUILD-NOTES.md). When the
// server rewrites a library file (tags or a cover written into the EPUB), the card copy stops
// syncing highlights and bookmarks (positionIncompatible). This finds those copies and replaces
// them in place, one book at a time, with their reading position, highlights and bookmarks
// carried over (BookUpdateMigration). core/CopyQueue holds the rules and the queue format.
//
// It never runs while a book is open. The sleep sync detects and replaces (up to three minutes
// per sleep); the BookOrbit Home's refresh only detects. A replacement needs a 24 KB heap block
// for its TLS session: where the heap has less (the X3's sleep sync may), the copy stays queued
// and the sync's update offer remains the way to it.
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

// With Wi-Fi up: replaces queued copies one at a time until the queue is empty, cancelled()
// says stop, or budgetMs is used. Each replacement is checked against the library file's hash
// before it goes live. Returns the number replaced.
size_t run(bool (*cancelled)(), unsigned long budgetMs);

// The sync's "update this copy" (decision (a)): queues the open book's copy for the next run.
bool enqueue(int64_t bookId, const std::string& path, const std::string& cardHash);

// Copies waiting (not given up).
size_t pending();

// The server's library version as the last full match-check pass saw it ("" = none yet): the
// offline mirror's "the library changed" rule (orbify/Mirror).
std::string libraryVersion();

}  // namespace OrbifyCopyRefresh
