#pragma once
// BookSync End-of-Book page: the next book's cover, at the left of the "Next in series" row (X4 Pro
// and X4; CROSSINK_TAILNET_ORBIFY_EOB_COVER, off on the X3 for flash). Pure C++: the firmware
// (../FinishSync.cpp) does the requests and the files; xteink/test/end_of_book_test.cpp checks
// these rules.
//
//   - The version is the Home store's: FNV-1a 32 of the book's updatedAt (cache::coverVersion), taken
//     from the detail's related sections, or from the next book's own detail when no section lists it.
//   - Files: <DIR>/<bookId>_<ver %08x>_<w>x<h>.bmp, and the fetched JPEG <DIR>/<bookId>_<ver %08x>.jpg
//     until a radio-off decode turns it into the BMP. DIR is the series cards' own directory, so the
//     Home store's prune (it lists only HOME_DIR) never removes them.
//   - A sync fetches it (never the page): the BMP or a pending JPEG at this version needs nothing; a
//     Home BMP at this version is copied; else the thumbnail is downloaded, If-None-Match with the kept
//     ETag when an older version's BMP is here (a 304 renames that file and downloads nothing).
#include <ArduinoJson.h>

#include <cstddef>
#include <cstdint>

namespace orbify {
namespace cover {

constexpr char DIR[] = "/.crosspoint/orbify_series";
constexpr char HOME_DIR[] = "/.crosspoint/bookorbit_home";

// The fields versionIn reads, added to the detail filter (core/SeriesCard's cardFilter).
void addToFilter(JsonDocument& filter);

enum class Lookup : uint8_t { NotListed, NoCover, Found };
// Book `id`'s cover version from the detail's related sections (series, author, similar). NotListed:
// no section lists it (the series section holds only the first 8 other books).
Lookup versionIn(JsonObjectConst detail, int64_t id, uint32_t& version);
// The same, from that book's own detail (hasCover, updatedAt).
Lookup versionOf(JsonObjectConst bookDetail, uint32_t& version);
// cache::coverVersion, never 0 (0 means "no cover known" on the card).
uint32_t versionOfUpdatedAt(const char* updatedAt);

// Full paths. Both false when the buffer is too small.
bool bmpPath(const char* dir, int64_t bookId, uint32_t version, int width, int height, char* out, size_t size);
bool jpgPath(int64_t bookId, uint32_t version, char* out, size_t size);

// A file name (no directory) of either kind; false for anything else (a card's <bookId>.bin).
struct Name {
  int64_t bookId = 0;
  uint32_t version = 0;
  int width = 0, height = 0;  // 0 for the JPEG
  bool jpg = false;
};
bool parseName(const char* name, Name& out);
// A cover file of this book that is not the one at this version and size (a BMP at another size, from
// an older firmware's page, is stale too): removed when the version moves on.
bool isStale(const Name& name, int64_t bookId, uint32_t version, int width, int height);

// What the sync does for the next book's cover.
struct Disk {
  bool bmp = false;         // the BMP at this version and size is here
  bool pending = false;     // its JPEG is here, waiting for the decode
  bool homeBmp = false;     // the Home store has a BMP of this book at this version
  bool kept = false;        // a BMP of an older version is here (the cache's cover record names it)
  uint32_t keptVersion = 0;
  bool hasEtag = false;     // the cache kept that file's ETag
};
enum class Step : uint8_t { None, CopyHome, Download, Conditional };
Step plan(uint32_t version, const Disk& disk);

// After the request: a 304 renames the kept file to this version (nothing was downloaded), a 200
// leaves the JPEG for the decode, anything else drops it.
enum class After : uint8_t { RenameKept, Decode, Drop };
After afterFetch(bool ok, int httpStatus, Step step);

}  // namespace cover
}  // namespace orbify
