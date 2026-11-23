// orbify/core/CopyQueue: which card copies the background refresh replaces, the persisted
// queue it works through one book at a time, and the check that commits a replacement.
#include <cstdio>
#include <cstring>
#include <string>

#include "CopyQueue.h"

using namespace orbify::refresh;

static int passed = 0, failed = 0;
#define CHECK(c)                                              \
  do {                                                        \
    if (c) {                                                  \
      ++passed;                                               \
    } else {                                                  \
      ++failed;                                               \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); \
    }                                                         \
  } while (0)

static const char* OLD = "3dcf3eb3c005357c54c1f8a27320bf98";
static const char* NEW = "9a1c0e7d2b3f4a5b6c7d8e9f00112233";

static Entry entry(int64_t book, int64_t file, const char* hash, const char* path) {
  Entry e;
  e.bookId = book;
  e.fileId = file;
  std::strncpy(e.oldHash, hash, sizeof(e.oldHash) - 1);
  e.path = path;
  return e;
}

static void detection() {
  // Never blind: only a copy the server matched to the same book and called incompatible.
  Match m{1207, 3563, false};
  CHECK(shouldRefresh(1207, OLD, &m));
  m.positionCompatible = true;
  CHECK(!shouldRefresh(1207, OLD, &m));  // current: sync takes it
  m.positionCompatible = false;
  CHECK(!shouldRefresh(1208, OLD, &m));  // another book's hash: never overwrite this copy
  CHECK(!shouldRefresh(1207, OLD, nullptr));  // unmatched: the server does not know it
  CHECK(!shouldRefresh(0, OLD, &m));          // not a catalog download
  CHECK(!shouldRefresh(1207, "", &m));        // unreadable copy
  CHECK(!shouldRefresh(1207, "nothex", &m));
}

static void queue() {
  Queue q;
  CHECK(q.pending() == 0 && q.next() == nullptr);
  CHECK(q.add(entry(1207, 3563, OLD, "/Standalone/Panic.epub")));
  CHECK(q.add(entry(11, 21, NEW, "/Series/Two.epub")));
  CHECK(!q.add(entry(1207, 3563, OLD, "/Standalone/Panic.epub")));  // already queued
  CHECK(q.pending() == 2);
  CHECK(q.next() && q.next()->bookId == 1207);  // oldest first, one at a time
  // A failure keeps it, with one more attempt, behind the others.
  q.failed("/Standalone/Panic.epub");
  CHECK(q.next() && q.next()->bookId == 11);
  q.done("/Series/Two.epub");
  CHECK(q.pending() == 1 && q.next()->bookId == 1207 && q.next()->attempts == 1);
  for (int i = 1; i < MAX_ATTEMPTS; ++i) q.failed("/Standalone/Panic.epub");
  CHECK(q.pending() == 0 && q.next() == nullptr);  // given up after MAX_ATTEMPTS
  // A newer detection of the same path with a different card hash starts it over.
  Entry again = entry(1207, 3563, NEW, "/Standalone/Panic.epub");
  CHECK(q.add(again) && q.pending() == 1 && q.next()->attempts == 0);
  // The same path re-detected with the hash it failed on stays given up.
  for (int i = 0; i < MAX_ATTEMPTS; ++i) q.failed("/Standalone/Panic.epub");
  CHECK(!q.add(again) && q.pending() == 0);
}

static void resume() {
  // Persisted after every step; a reset or a wake press resumes where it stopped.
  Queue q;
  q.add(entry(1207, 3563, OLD, "/Standalone/David D. Burns M.D - When Panic Attacks.epub"));
  q.add(entry(11, 21, NEW, "/Series/Two.epub"));
  q.failed("/Standalone/David D. Burns M.D - When Panic Attacks.epub");
  const std::string text = q.serialize();
  Queue back;
  CHECK(back.parse(text));
  CHECK(back.pending() == 2);
  CHECK(back.next() && back.next()->bookId == 11);
  back.done("/Series/Two.epub");
  const Entry* e = back.next();
  CHECK(e && e->bookId == 1207 && e->fileId == 3563 && e->attempts == 1);
  CHECK(e && std::strcmp(e->oldHash, OLD) == 0);
  CHECK(e && e->path == "/Standalone/David D. Burns M.D - When Panic Attacks.epub");
  CHECK(back.serialize() != text);
  // Damaged lines are dropped, the rest kept; an unknown version starts empty.
  Queue partial;
  CHECK(partial.parse(std::string("orbify-copy-refresh 1\n12\t34\t") + OLD + "\t0\t/a.epub\nbroken line\n5\t6\tzz\t0\t/b.epub\n"));
  CHECK(partial.pending() == 1 && partial.next()->bookId == 12);
  Queue other;
  CHECK(!other.parse("orbify-copy-refresh 9\n12\t34\tx\t0\t/a.epub\n") && other.pending() == 0);
  Queue empty;
  CHECK(empty.parse("") && empty.pending() == 0);
}

static void commit() {
  // The new copy goes live only when its hash is the library file's: otherwise the old copy
  // comes back from "<book>.old" and its state stays under the old hash.
  CHECK(afterDownload(NEW, NEW) == AfterDownload::Commit);
  CHECK(afterDownload(NEW, "9A1C0E7D2B3F4A5B6C7D8E9F00112233") == AfterDownload::Commit);
  CHECK(afterDownload(OLD, NEW) == AfterDownload::RollBack);
  CHECK(afterDownload("", NEW) == AfterDownload::RollBack);
  CHECK(afterDownload(NEW, "") == AfterDownload::RollBack);
  // Before downloading: a copy that already is the library file is only re-recorded.
  CHECK(beforeDownload(NEW, NEW) == BeforeDownload::AlreadyCurrent);
  CHECK(beforeDownload(OLD, NEW) == BeforeDownload::Download);
  CHECK(beforeDownload(OLD, "") == BeforeDownload::CannotVerify);  // never download blindly
}

int main() {
  detection();
  queue();
  resume();
  commit();
  std::printf("copy-queue: %d passed, %d failed\n", passed, failed);
  return failed ? 1 : 0;
}
