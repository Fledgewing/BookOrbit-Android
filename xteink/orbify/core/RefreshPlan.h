// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <array>
#include <cstdio>

#include "Mirror.h"

namespace orbify::mirror {
// SD-backed append journals, never a vector of a library's pages/books. The
// backend reads one bounded record at a time and durably appends before
// remembering its identity.
struct Journal {
  virtual ~Journal() = default;
  virtual bool append(unsigned lane, const Step& step, int page) = 0;
  virtual bool read(unsigned lane, size_t offset, Step& step, int& page, size_t& next) = 0;
  virtual size_t count(unsigned lane) = 0;
  virtual bool contains(unsigned lane, const Step& step, int page) = 0;
  virtual bool good() const = 0;
};
// Discovery: root, every facet page, first page of every linked list. Then all
// remaining book pages, then deduplicated details. The all-books header
// supplies the detail count before the denominator is sealed; data pages can
// enqueue ids without changing it.
class RefreshPlan {
 public:
  explicit RefreshPlan(Journal& journal) : journal(journal) {}
  bool add(Kind kind, const std::string& arg, int page = 1, bool dataPage = false) {
    const unsigned lane = kind == Kind::Detail ? 2 : dataPage ? 1 : 0;
    if (fixedTotal && lane != 2) return false;
    const Step step{kind, arg};
    if (journal.contains(lane, step, page)) return false;
    return journal.append(lane, step, page);
  }
  bool next(Step& step, int& page) {
    for (lane = 0; lane < 3; ++lane) {
      if (done[lane] < journal.count(lane)) return journal.read(lane, offsets[lane], step, page, nextOffset);
    }
    return false;
  }
  void advance(bool failed = false) {
    offsets[lane] = nextOffset;
    ++done[lane];
    failures += failed;
    if (!fixedTotal && done[0] == journal.count(0))
      fixedTotal = journal.count(0) + journal.count(1) + std::max(expectedDetails, journal.count(2));
    shown = std::max(shown, percent());
  }
  void expectDetails(size_t count) { expectedDetails = std::max(expectedDetails, count); }
  size_t total() const {
    if (fixedTotal) return fixedTotal;
    return journal.count(0) + journal.count(1) + std::max(expectedDetails, journal.count(2));
  }
  size_t doneCount() const { return done[0] + done[1] + done[2]; }
  size_t errors() const {
    const size_t details = journal.count(2);
    const size_t missing =
        finished() ? (expectedDetails > details ? expectedDetails - details : details - expectedDetails) : 0;
    return failures + missing;
  }
  size_t savedCount() const { return doneCount() - failures; }
  size_t bookCount() const { return expectedDetails; }
  bool enumerated() const { return done[0] == journal.count(0); }
  bool finished() const {
    return done[0] == journal.count(0) && done[1] == journal.count(1) && done[2] == journal.count(2);
  }
  unsigned percent() const {
    // During enumeration 0%; once discovery ends the denominator is fixed.
    // Retain the displayed high-water mark across reset, including a library
    // changing during a run.
    if (done[0] < journal.count(0)) return shown;
    if (finished() && journal.good()) return 100;
    return std::max(shown,
                    static_cast<unsigned>(std::min<size_t>(99, total() ? doneCount() * 100 / total() : 0)));
  }
  std::string checkpoint() const {
    char text[256];
    std::snprintf(text, sizeof(text), "W9 1\n%zu %zu %zu %zu %zu %zu %zu %zu %u %zu\n", offsets[0],
                  offsets[1], offsets[2], done[0], done[1], done[2], expectedDetails, failures, percent(),
                  fixedTotal);
    return text;
  }
  bool restore(const std::string& text) {
    if (std::sscanf(text.c_str(), "W9 1\n%zu %zu %zu %zu %zu %zu %zu %zu %u %zu", &offsets[0], &offsets[1],
                    &offsets[2], &done[0], &done[1], &done[2], &expectedDetails, &failures, &shown,
                    &fixedTotal) < 9)
      return false;
    return shown <= 100 && done[0] <= journal.count(0) && done[1] <= journal.count(1) &&
           done[2] <= journal.count(2);
  }

 private:
  Journal& journal;
  std::array<size_t, 3> offsets{}, done{};
  size_t expectedDetails = 0, failures = 0, nextOffset = 0, fixedTotal = 0;
  unsigned lane = 0, shown = 0;
};
// uint64_t is required: the shared schema includes 10 GB and unlimited (0).
constexpr uint64_t SD_MARGIN = 16ULL * 1024 * 1024;
enum class Stop : uint8_t { None, StorageLimit, SdFull, Io };
inline Stop budget(uint64_t used, uint64_t replacing, uint64_t incoming, uint64_t limit, uint64_t free) {
  if (free < SD_MARGIN || incoming > free - SD_MARGIN) return Stop::SdFull;
  if (limit &&
      (used - std::min(used, replacing) > limit || incoming > limit - (used - std::min(used, replacing))))
    return Stop::StorageLimit;
  return Stop::None;
}
inline std::string stopText(Stop stop, size_t done, size_t total) {
  const char* reason = stop == Stop::StorageLimit ? "storage limit"
                       : stop == Stop::SdFull     ? "SD card full"
                                                  : "SD write error";
  return "Stopped at " + std::string(reason) + ": " + std::to_string(done) + " of " + std::to_string(total) +
         " saved" + (stop == Stop::StorageLimit ? " — raise it in Settings" : " — free space and retry");
}
}  // namespace orbify::mirror
