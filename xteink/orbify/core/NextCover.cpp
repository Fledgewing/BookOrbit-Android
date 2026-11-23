#include "NextCover.h"

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "CatalogCache.h"

namespace orbify {
namespace cover {

namespace {

Lookup fromBook(JsonVariantConst book, uint32_t& version) {
  version = 0;
  if (!(book["hasCover"] | false)) return Lookup::NoCover;
  version = versionOfUpdatedAt(book["updatedAt"].as<const char*>());
  return Lookup::Found;
}

// Digits up to `stop`; false when there are none or something else comes first.
bool readNumber(const char*& p, const char stop, const int base, uint64_t& out) {
  const char* start = p;
  out = 0;
  for (; *p && *p != stop; ++p) {
    const char c = *p;
    int digit;
    if (c >= '0' && c <= '9') {
      digit = c - '0';
    } else if (base == 16 && c >= 'a' && c <= 'f') {
      digit = c - 'a' + 10;
    } else {
      return false;
    }
    out = out * static_cast<uint64_t>(base) + static_cast<uint64_t>(digit);
    if (p - start > 18) return false;
  }
  return p > start && *p == stop;
}

}  // namespace

void addToFilter(JsonDocument& filter) {
  filter["relatedSections"][0]["books"][0]["hasCover"] = true;
  filter["relatedSections"][0]["books"][0]["updatedAt"] = true;
}

uint32_t versionOfUpdatedAt(const char* updatedAt) {
  const uint32_t v = cache::coverVersion(updatedAt);
  return v ? v : 1;
}

Lookup versionIn(JsonObjectConst detail, const int64_t id, uint32_t& version) {
  version = 0;
  if (id <= 0) return Lookup::NotListed;
  for (JsonVariantConst section : detail["relatedSections"].as<JsonArrayConst>()) {
    for (JsonVariantConst book : section["books"].as<JsonArrayConst>()) {
      if (book["id"].as<int64_t>() == id) return fromBook(book, version);
    }
  }
  return Lookup::NotListed;
}

Lookup versionOf(JsonObjectConst bookDetail, uint32_t& version) {
  version = 0;
  if (bookDetail["id"].as<int64_t>() <= 0) return Lookup::NotListed;
  return fromBook(bookDetail, version);
}

bool bmpPath(const char* dir, const int64_t bookId, const uint32_t version, const int width, const int height,
             char* out, const size_t size) {
  const int n = std::snprintf(out, size, "%s/%" PRId64 "_%08" PRIx32 "_%dx%d.bmp", dir, bookId, version, width, height);
  return n > 0 && static_cast<size_t>(n) < size;
}

bool jpgPath(const int64_t bookId, const uint32_t version, char* out, const size_t size) {
  const int n = std::snprintf(out, size, "%s/%" PRId64 "_%08" PRIx32 ".jpg", DIR, bookId, version);
  return n > 0 && static_cast<size_t>(n) < size;
}

bool parseName(const char* name, Name& out) {
  out = Name{};
  if (!name) return false;
  const char* p = name;
  uint64_t id = 0, version = 0, w = 0, h = 0;
  if (!readNumber(p, '_', 10, id) || id == 0) return false;
  ++p;
  const char* versionStart = p;
  if (std::strlen(p) == 12 && std::strcmp(p + 8, ".jpg") == 0) {
    // <id>_<ver>.jpg
    if (!readNumber(p, '.', 16, version) || p - versionStart != 8) return false;
    out.jpg = true;
  } else {
    if (!readNumber(p, '_', 16, version) || p - versionStart != 8) return false;
    ++p;
    if (!readNumber(p, 'x', 10, w) || w == 0) return false;
    ++p;
    if (!readNumber(p, '.', 10, h) || h == 0 || std::strcmp(p, ".bmp") != 0) return false;
  }
  out.bookId = static_cast<int64_t>(id);
  out.version = static_cast<uint32_t>(version);
  out.width = static_cast<int>(w);
  out.height = static_cast<int>(h);
  return true;
}

bool isStale(const Name& name, const int64_t bookId, const uint32_t version, const int width, const int height) {
  if (name.bookId != bookId) return false;
  if (name.version != version) return true;
  return !name.jpg && (name.width != width || name.height != height);
}

Step plan(const uint32_t version, const Disk& disk) {
  if (version == 0 || disk.bmp || disk.pending) return Step::None;
  if (disk.homeBmp) return Step::CopyHome;
  // The cache's rules for a Home cover (cache::planCover, a sync's Refresh): a kept file at an older
  // version with its ETag is asked If-None-Match.
  cache::CoverOnDisk onDisk;
  onDisk.present = disk.kept && disk.keptVersion != version;
  onDisk.version = disk.keptVersion;
  onDisk.file = onDisk.present ? cache::CoverFile::Ok : cache::CoverFile::Missing;
  onDisk.hasEtag = disk.hasEtag;
  const cache::CoverPlan p = cache::planCover(cache::Mode::Refresh, true, version, onDisk, false);
  switch (p.action) {
    case cache::CoverAction::Conditional:
      return Step::Conditional;
    case cache::CoverAction::Download:
      return Step::Download;
    case cache::CoverAction::None:
    default:
      return Step::None;
  }
}

After afterFetch(const bool ok, const int httpStatus, const Step step) {
  if (!ok && httpStatus == 304 && step == Step::Conditional) return After::RenameKept;
  return ok ? After::Decode : After::Drop;
}

}  // namespace cover
}  // namespace orbify
