#pragma once
// Orbify: keeping book copies current (patch 0034). When the server rewrites a library file
// (a tag or cover written into the EPUB moves its hash), every card copy of it stops syncing
// annotations and bookmarks (positionIncompatible). The background refresh finds those copies
// through the server's match check and replaces them, one book at a time, from a queue kept on
// the card so a wake press or a reset resumes it. Pure C++: the firmware side is
// ../CopyRefresh.cpp.
#include <cstdint>
#include <string>
#include <vector>

namespace orbify::refresh {

constexpr uint8_t MAX_ATTEMPTS = 3;

// What the match check said about one card hash.
struct Match {
  int64_t bookId = 0;
  int64_t fileId = 0;
  bool positionCompatible = true;
};

// A copy is refreshed only when the server matched its hash to the very book the download
// index recorded for it, and says the hash is an older one of that book's file. Unmatched or
// current copies, other books' hashes and unreadable copies are left alone.
bool shouldRefresh(int64_t indexedBookId, const char* cardHash, const Match* match);

struct Entry {
  int64_t bookId = 0;
  int64_t fileId = 0;
  char oldHash[33] = {};  // the card copy's hash when it was queued
  uint8_t attempts = 0;
  std::string path;       // replaced in place: same path, same name
};

class Queue {
 public:
  // False when the path is queued already (with that hash: a given-up entry stays given up).
  // A path queued with a different hash starts over.
  bool add(const Entry& entry);
  // The next copy to replace: the first not given up, oldest first; nullptr when none.
  const Entry* next() const;
  void done(const std::string& path);
  // One more attempt used; it moves behind the others.
  void failed(const std::string& path);
  size_t pending() const;

  // "orbify-copy-refresh 1" then one line per entry: bookId, fileId, hash, attempts, path
  // (tab-separated). parse() drops damaged lines; an unknown version leaves the queue empty.
  std::string serialize() const;
  bool parse(const std::string& text);

 private:
  std::vector<Entry> entries;
};

// Before downloading: the library file's hash is the only way to know the download is the
// right one, so without it nothing is downloaded.
enum class BeforeDownload { Download, AlreadyCurrent, CannotVerify };
BeforeDownload beforeDownload(const char* cardHash, const char* libraryHash);

// After downloading: the new copy stays only when its hash is the library file's.
enum class AfterDownload { Commit, RollBack };
AfterDownload afterDownload(const char* newHash, const char* libraryHash);

}  // namespace orbify::refresh
