// SPDX-License-Identifier: GPL-3.0-or-later
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

constexpr uint32_t DEFAULT_TTL_DAYS = 0;
// --- when ----------------------------------------------------------------------------------------

enum class Due : uint8_t { None, Never, Ttl, Library };
// Legacy shared-table rule, not a firmware scheduler: dueNow() always returns None and both
// firmware walkers require a persisted user request. Kept for reading the old cross-platform table.
// saved: a mirror finished before, at `at` (epoch s), with the library version then (may be "").
// libNow: the server's library version now ("" = unknown). ttlDays 0: automatic runs off.
Due due(bool saved, uint32_t at, const char* savedLib, const char* libNow, uint32_t now, uint32_t ttlDays);
// Saved replies remain usable at any age; opening one never joins Wi-Fi to revalidate it.
inline bool catalogFromCache(const bool saved, const Due) { return saved; }
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
// The finite browse controls exposed by CrossInk's book list (not arbitrary search).
// Visit one identity at a time: no vector of scopes or whole lists on the reader.
template <class Visit>
void browseQueries(const FacetQuery& base, Visit visit) {
  if (!base.shelf.empty() || !base.query.empty()) {
    visit(base);
    return;
  }
  FacetQuery q = base;
  const auto family = [&](const char* sort, bool descending) {
    q.sort = sort;
    for (unsigned order = 0; order < 2; ++order) {
      q.order = order ? (descending ? "asc" : "desc") : "";
      for (const char* status : {"", "unread", "reading", "finished"}) {
        q.readStatus = status;
        visit(q);
      }
    }
  };
  // Authors start with the server's default (recently added), spelled without
  // sort. The sheet can retain that spelling while changing status/direction.
  if (base.sort.empty()) family("", true);
  family("recently_added", true);
  family("title", false);
  family("author", false);
  family("recently_read", true);
  family("series", false);
}

// The book list a facet row opens (BookOrbitCatalogBrowserActivity::activateSelected, FACET).
FacetQuery facetQuery(const std::string& facetSectionId, const std::string& entryId,
                      const std::string& seriesId);
// One tab- and newline-free field for the plan file, and back. Tabs and newlines in values become
// spaces (the request is then the one the browser makes for that name, which has none).
std::string encodeQuery(const FacetQuery& query);
bool decodeQuery(const std::string& text, FacetQuery& out);
// The request a book list makes, after the server's base URL: BookOrbitCatalogClient's
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
  // The step ran; failed: it was asked and did not land (counted for "Done with N errors").
  void advance(bool failed = false);
  bool empty() const { return steps.empty(); }
  bool finished() const { return done >= steps.size(); }
  size_t total() const { return steps.size(); }
  size_t doneCount() const { return done; }
  size_t count(Kind kind) const;
  size_t failures() const { return failed; }
  // Enumeration stays at 0%; data requests then use a sealed total. A book detail is
  // deduplicated by id, including across lists and after a reboot. No section discovers
  // more work after the data phase begins. Old persisted percentages never decrease.
  unsigned percent() const;

  // "orbify-mirror 4\n<done>\t<percent shown>\t<failed>\n" then one "<kind letter>\t<arg>\n" per
  // step. A version 2 plan (no percent, no failures) is still read.
  std::string serialize() const;
  bool parse(const std::string& text);

 private:
  unsigned rawPercent() const;
  std::vector<Step> steps;
  size_t done = 0;
  size_t failed = 0;
  unsigned shown = 0;
};

// --- the progress badge ------------------------------------------------------------------------------

// The badge is redrawn (its own rectangle only) when the % changed, at most this often: each paint
// is an e-ink refresh.
constexpr unsigned long BADGE_REPAINT_MS = 3000;
// Background work cannot arm a progress display; only an explicit user request can.
inline bool showProgress(bool userRequested, bool running) { return userRequested && running; }
// The start popup closes by itself after this long (or at the next button press).
constexpr unsigned long START_POPUP_MS = 5000;
// "Done" / "Done with N errors" stays this long, then the header's stamp comes back.
constexpr unsigned long DONE_MS = 5000;
// painted: the % on screen now (-1 = none yet); paintedAt and now in ms.
bool badgeDue(int painted, unsigned percent, unsigned long paintedAt, unsigned long now);
// "37%" while it runs; "Done" or "Done with 3 errors" (1 error) once finished.
void badgeText(unsigned percent, bool finished, size_t failures, char* out, size_t size);

}  // namespace mirror
}  // namespace orbify
