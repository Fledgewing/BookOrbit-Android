// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <HalStorage.h>
#include <string>
#include <algorithm>

// A durable circuit breaker for resumable jobs. Two runs that never returned
// are enough: refuse a third, even after a cold power cycle. Expected pauses
// complete the attempt; no reset-reason or wall-clock assumptions are needed.
class ResumedWork {
 public:
  explicit ResumedWork(const char* file) : path(file), tmp(path + ".tmp") {}
  bool exhausted() const { return count() >= 2; }
  bool begin() {
    const unsigned prior = count();
    if (prior >= 2) return false;
    if (!Storage.mkdir(path.substr(0, path.find_last_of('/')).c_str())) return false;
    HalFile file;
    if (!Storage.openFileForWrite("ORB", tmp.c_str(), file)) return false;
    const char next = '1' + prior;
    const bool ok = file.write(reinterpret_cast<const uint8_t*>(&next), 1) == 1 && file.sync();
    file.close();
    if (!ok) return false;
    Storage.remove(path.c_str());
    return Storage.rename(tmp.c_str(), path.c_str());
  }
  void complete() { Storage.remove(path.c_str()); Storage.remove(tmp.c_str()); }
 private:
  std::string path, tmp;
  unsigned read(const std::string& p) const {
    if (!Storage.exists(p.c_str())) return 0;
    HalFile file;
    if (!Storage.openFileForRead("ORB", p.c_str(), file)) return 2;
    char value = 0;
    // Truncated/corrupt state is unsafe to resume, not a fresh attempt.
    if (file.fileSize() != 1 || file.read(reinterpret_cast<uint8_t*>(&value), 1) != 1) return 2;
    return value == '1' ? 1 : 2;
  }
  unsigned count() const { return std::max(read(path), read(tmp)); }
};
