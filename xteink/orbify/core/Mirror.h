#pragma once
// Orbify offline mirror, X4 Pro and X4 (docs/design/write-through-cache.md, "Offline mirror" and
// its Xteink section): the rules, as pure functions. The firmware walker (orbify/Mirror) makes the
// requests through the catalog client, so every reply lands in the write-through cache, and the
// catalog browser then opens offline from it. xteink/test/mirror_test.cpp checks these, the due
// rule against the shared table Android reads too (shared/fixtures/cache/cases.json "mirror").
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace orbify {
namespace mirror {

constexpr uint32_t DEFAULT_TTL_DAYS = 7;
// The cache holds 200 entries (core/CatalogCache MAX_ENTRIES): the mirror takes at most this many,
// so the views read by hand keep their room.
constexpr size_t MAX_STEPS = 150;
// First pages only: a facet section (authors, series...) contributes the lists of its first rows.
constexpr size_t MAX_LISTS_PER_FACET = 20;
// Book details: the books on the reader and their next in series.
constexpr size_t MAX_DETAILS = 30;

// --- when ----------------------------------------------------------------------------------------

enum class Due : uint8_t { None, Never, Ttl, Library };
// saved: a mirror finished before, at `at` (epoch s), with the library version then (may be "").
// libNow: the server's library version now ("" = unknown). ttlDays 0: automatic runs off.
Due due(bool saved, uint32_t at, const char* savedLib, const char* libNow, uint32_t now, uint32_t ttlDays);
// Patch 0038, cache-first: the catalog opens a saved copy without Wi-Fi unless it is stale (the
// 7-day Full refresh due, or a new library version). Never saved: it connects.
inline bool catalogFromCache(const bool saved, const Due due) { return saved && due == Due::None; }
// "none" / "never" / "ttl" / "library": the shared table's words, and the log's.
const char* dueName(Due due);

// --- what ------------------------------------------------------------------------------------------

// The catalog browser's root: sections that list facets rather than books
// (BookOrbitCatalogBrowserActivity isFacetSection).
bool isFacetSection(const std::string& sectionId);

// A book list request: the fields of BookOrbitBookQuery, as strings.
struct FacetQuery {
  std::string sort, order, readStatus, shelf, query, author, seriesId, series, collectionId, smartScopeId,
      libraryId;
};
// The book list a facet row opens (BookOrbitCatalogBrowserActivity::activateSelected, FACET).
FacetQuery facetQuery(const std::string& facetSectionId, const std::string& entryId, const std::string& seriesId);
// One tab- and newline-free field for the plan file, and back. Tabs and newlines in values become
// spaces (the request is then the one the browser makes for that name, which has none).
std::string encodeQuery(const FacetQuery& query);
bool decodeQuery(const std::string& text, FacetQuery& out);
// The request a book list makes, after the server's base URL (patch 0037): BookOrbitCatalogClient's
// booksUrl() builds its URL with this on the X4s, so the host test checks the requests the mirror
// and the browser really send.
std::string booksPath(const FacetQuery& query, int page, int size, bool withLetters);

// --- the plan ----------------------------------------------------------------------------------------

enum class Kind : uint8_t {
  Root,     // the root sections (they add their lists)
  Section,  // a facet section's first page (its rows add their lists)
  Books,    // a book list's first page; arg = encodeQuery
  Detail,   // a book's detail; arg = the book id
};
struct Step {
  Kind kind = Kind::Root;
  std::string arg;
};

// The requests of one Full refresh, in order, kept on the card so a wake or a reset resumes it.
class Plan {
 public:
  // False when the step is already in the plan (done or not), or the plan is full.
  bool add(Kind kind, const std::string& arg);
  const Step* next() const;  // nullptr when finished
  void advance();
  bool empty() const { return steps.empty(); }
  bool finished() const { return done >= steps.size(); }
  size_t total() const { return steps.size(); }
  size_t doneCount() const { return done; }
  size_t count(Kind kind) const;

  // "orbify-mirror 2\n<done>\n" then one "<kind letter>\t<arg>\n" per step.
  std::string serialize() const;
  bool parse(const std::string& text);

 private:
  std::vector<Step> steps;
  size_t done = 0;
};

}  // namespace mirror
}  // namespace orbify
