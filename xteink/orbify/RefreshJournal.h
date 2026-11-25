// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <HalStorage.h>
#include <Arduino.h>
#include "core/RefreshPlan.h"

namespace OrbifyMirror {
// Append-only queues on SD. Startup streams the journals to rebuild dedup markers after
// an interrupted append. No library-sized RAM allocation, including when resuming.
class RefreshJournal final : public orbify::mirror::Journal {
 public:
  explicit RefreshJournal(bool reset) {
    if (reset) removeTree(DIR);
    ok = Storage.exists(DIR) || Storage.mkdir(DIR);
    for (unsigned lane = 0; lane < 3 && ok; ++lane) {
      size_t offset = 0, next;
      orbify::mirror::Step step; int page;
      HalFile probe = Storage.open(path(lane).c_str());
      const size_t length = probe ? probe.fileSize() : 0;
      probe.close();
      while (offset < length && read(lane, offset, step, page, next)) {
        ++counts[lane];
        mark(lane, step, page);
        offset = next;
      }
      if (offset != length) ok = false;
    }
  }
  bool append(unsigned lane, const orbify::mirror::Step& step, int page) override {
    if (!ok) return false;
    // Arguments are encoded queries with no newlines/tabs. A malformed row is terminal,
    // never retried into an infinite walk.
    if (step.arg.find_first_of("\r\n\t") != std::string::npos || step.arg.size() > 4096) return ok = false;
    const std::string row = std::to_string(static_cast<unsigned>(step.kind)) + "\t" + std::to_string(page) + "\t" + step.arg + "\n";
    HalFile file = Storage.open(path(lane).c_str(), O_WRONLY | O_CREAT | O_APPEND);
    if (!file || file.write(row.data(), row.size()) != row.size() || !file.sync()) return ok = false;
    file.close();
    ++counts[lane];
    mark(lane, step, page);
    return ok;
  }
  bool read(unsigned lane, size_t offset, orbify::mirror::Step& step, int& page, size_t& next) override {
    HalFile file = Storage.open(path(lane).c_str());
    if (!file || !file.seek(offset)) return ok = false;
    std::string row;
    int ch;
    while ((ch = file.read()) >= 0 && ch != '\n' && row.size() < 4160) row += static_cast<char>(ch);
    next = file.position();
    file.close();
    const size_t first = row.find('\t'), second = row.find('\t', first + 1);
    if (ch != '\n' || first == std::string::npos || second == std::string::npos) return ok = false;
    const int kind = atoi(row.c_str());
    page = atoi(row.c_str() + first + 1);
    if (kind < 0 || kind > 3 || page < 1) return ok = false;
    step = {static_cast<orbify::mirror::Kind>(kind), row.substr(second + 1)};
    return true;
  }
  size_t count(unsigned lane) override { return counts[lane]; }
  bool contains(unsigned lane, const orbify::mirror::Step& step, int page) override {
    return Storage.exists(marker(lane, step, page).c_str());
  }
  bool good() const override { return ok; }
  uint64_t bytes() const {
    uint64_t bytes = 0;
    for (unsigned lane = 0; lane < 3; ++lane) {
      HalFile file = Storage.open(path(lane).c_str());
      if (file) bytes += file.fileSize64();
    }
    return bytes;
  }
 private:
  static void removeTree(const char* path) {
    HalFile dir = Storage.open(path);
    while (HalFile file = dir.openNextFile()) {
      char name[80]{}; file.getName(name, sizeof(name));
      const bool directory = file.isDirectory(); file.close();
      const auto child = std::string(path) + "/" + name;
      if (directory) removeTree(child.c_str());
      else Storage.remove(child.c_str());
      delay(1); // no library-sized SD lock while the user changes pages
    }
    dir.close(); Storage.rmdir(path);
  }
  static constexpr const char* DIR = "/.crosspoint/orbify/walk";
  bool ok = true;
  size_t counts[3]{};
  std::string path(unsigned lane) const { return std::string(DIR) + "/" + std::to_string(lane) + ".q"; }
  std::string marker(unsigned lane, const orbify::mirror::Step& step, int page) const {
    const std::string key = std::to_string(lane) + ":" + std::to_string(static_cast<unsigned>(step.kind)) + ":" + std::to_string(page) + ":" + step.arg;
    uint64_t hash = 14695981039346656037ULL;
    for (unsigned char c : key) { hash ^= c; hash *= 1099511628211ULL; }
    char name[96];
    snprintf(name, sizeof(name), "%s/%02x/%016llx.seen", DIR, static_cast<unsigned>(hash >> 56), static_cast<unsigned long long>(hash));
    return name;
  }
  void mark(unsigned lane, const orbify::mirror::Step& step, int page) {
    const std::string name = marker(lane, step, page);
    if (Storage.exists(name.c_str())) return;
    Storage.mkdir(name.substr(0, name.find_last_of('/')).c_str());
    HalFile file = Storage.open(name.c_str(), O_WRONLY | O_CREAT);
    if (!file) ok = false;
  }
};
}
