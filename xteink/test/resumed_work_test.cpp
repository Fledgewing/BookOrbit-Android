// SPDX-License-Identifier: GPL-3.0-or-later
#include "ResumedWork.h"
#include <cassert>
#include <cstdio>
int main() {
  using Start = ResumedWork::Start;
  files["settings"] = "kept"; files["book.epub"] = "book";
  ResumedWork first("/job");
  assert(!first.exhausted() && first.begin() == Start::Started);
  assert(files["/job"] == "1");
  // New instances stand for cold boots; RTC and reset reason are irrelevant.
  ResumedWork second("/job");
  assert(!second.exhausted() && second.begin() == Start::Started);
  ResumedWork third("/job");
  assert(third.exhausted() && third.begin() == Start::Exhausted);
  third.complete();
  for(int i=0;i<5;++i) {
    assert(third.begin() == Start::Started);  // normal pause/offline/cancellation never accumulates
    third.complete();
    assert(!third.exhausted());
  }
  files["/job.tmp"] = "2"; // reset between durable write and rename
  assert(third.exhausted() && third.begin() == Start::Exhausted);
  third.complete();files["/job"]="bad record";
  assert(third.exhausted() && third.begin() == Start::Exhausted);
  third.complete();files["/job.tmp"]="";
  assert(third.exhausted()); // a partial write is never silently resumed
  third.complete();writable=false;
  assert(third.begin() == Start::StorageError);writable=true;synced=false;
  assert(third.begin() == Start::StorageError);synced=true;
  assert(!third.exhausted()); // a failed marker write is not a crash
  renamed=false; assert(third.begin() == Start::StorageError); renamed=true;
  assert(!third.exhausted());
  third.complete();
  // The device's existing-directory mkdir failure must not block a fresh job.
  directories.insert("/existing");
  assert(!Storage.mkdir("/existing"));
  ResumedWork nested("/existing/job");
  assert(nested.begin() == Start::Started);
  nested.complete();
  assert(files.size()==2 && files["settings"]=="kept" && files["book.epub"]=="book");
  puts("resumed-work: passed");
}
