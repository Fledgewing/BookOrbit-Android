// SPDX-License-Identifier: GPL-3.0-or-later
#include "ResumedWork.h"
#include <cassert>
#include <cstdio>
int main() {
  files["settings"] = "kept"; files["book.epub"] = "book";
  ResumedWork first("/job");
  assert(!first.exhausted() && first.begin());
  assert(files["/job"] == "1");
  // New instances stand for cold boots; RTC and reset reason are irrelevant.
  ResumedWork second("/job");
  assert(!second.exhausted() && second.begin());
  ResumedWork third("/job");
  assert(third.exhausted() && !third.begin());
  third.complete();
  for(int i=0;i<5;++i) {
    assert(third.begin());  // normal pause/offline/cancellation never accumulates
    third.complete();
    assert(!third.exhausted());
  }
  files["/job.tmp"] = "2"; // reset between durable write and rename
  assert(third.exhausted() && !third.begin());
  third.complete();files["/job"]="bad record";
  assert(third.exhausted() && !third.begin());
  third.complete();files["/job.tmp"]="";
  assert(third.exhausted()); // a partial write is never silently resumed
  third.complete();writable=false;
  assert(!third.begin());writable=true;synced=false;
  assert(!third.begin());synced=true;third.complete();
  assert(files.size()==2 && files["settings"]=="kept" && files["book.epub"]=="book");
  puts("resumed-work: passed");
}
