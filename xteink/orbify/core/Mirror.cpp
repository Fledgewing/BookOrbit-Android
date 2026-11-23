#include "Mirror.h"

#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace orbify {
namespace mirror {

namespace {
constexpr uint32_t DAY_S = 86400;
// 2: a book list's fields keep their separator in the plan. Version 1 plans turned it into a space
// (one "sort" field holding the whole query, a 400 from the server) and are not resumed.
constexpr char HEADER[] = "orbify-mirror 2";
constexpr char SEP = '\x1f';

char kindLetter(const Kind kind) {
  switch (kind) {
    case Kind::Root:
      return 'R';
    case Kind::Section:
      return 'S';
    case Kind::Books:
      return 'B';
    case Kind::Detail:
      return 'D';
  }
  return '?';
}

bool kindOf(const char letter, Kind& out) {
  switch (letter) {
    case 'R':
      out = Kind::Root;
      return true;
    case 'S':
      out = Kind::Section;
      return true;
    case 'B':
      out = Kind::Books;
      return true;
    case 'D':
      out = Kind::Detail;
      return true;
    default:
      return false;
  }
}

// A query field's value: no line breaks, tabs or field separators.
std::string clean(std::string value) {
  for (char& c : value)
    if (c == '\t' || c == '\n' || c == '\r' || c == SEP) c = ' ';
  return value;
}

// A plan step's argument: one line of the plan file, so no line breaks or tabs. The field separator
// stays: a book list's argument is encodeQuery's fields joined by it.
std::string cleanLine(std::string value) {
  for (char& c : value)
    if (c == '\t' || c == '\n' || c == '\r') c = ' ';
  return value;
}

// The query's fields with their names, in one fixed order.
template <typename Q, typename Visit>
void fields(Q& q, Visit visit) {
  visit("sort", q.sort);
  visit("order", q.order);
  visit("readStatus", q.readStatus);
  visit("shelf", q.shelf);
  visit("q", q.query);
  visit("author", q.author);
  visit("seriesId", q.seriesId);
  visit("series", q.series);
  visit("collectionId", q.collectionId);
  visit("smartScopeId", q.smartScopeId);
  visit("libraryId", q.libraryId);
}
}  // namespace

Due due(const bool saved, const uint32_t at, const char* savedLib, const char* libNow, const uint32_t now,
        const uint32_t ttlDays) {
  if (!saved) return Due::Never;
  if (ttlDays == 0) return Due::None;
  if (savedLib && libNow && savedLib[0] && libNow[0] && std::strcmp(savedLib, libNow) != 0) return Due::Library;
  if (now != 0 && now >= at && now - at >= ttlDays * DAY_S) return Due::Ttl;
  return Due::None;
}

const char* dueName(const Due due) {
  switch (due) {
    case Due::Never:
      return "never";
    case Due::Ttl:
      return "ttl";
    case Due::Library:
      return "library";
    case Due::None:
      break;
  }
  return "none";
}

bool isFacetSection(const std::string& id) {
  return id == "authors" || id == "series" || id == "collections" || id == "libraries" || id == "smart-scopes";
}

FacetQuery facetQuery(const std::string& section, const std::string& entryId, const std::string& seriesId) {
  FacetQuery q;
  if (section == "series") {
    q.sort = "series";
    if (!seriesId.empty()) {
      q.seriesId = seriesId;
    } else {
      q.series = entryId;
    }
  } else if (section == "collections") {
    q.sort = "title";
    q.collectionId = entryId;
  } else if (section == "libraries") {
    q.sort = "title";
    q.libraryId = entryId;
  } else if (section == "smart-scopes") {
    q.sort = "title";
    q.smartScopeId = entryId;
  } else {
    q.author = entryId;
  }
  return q;
}

std::string encodeQuery(const FacetQuery& query) {
  std::string out;
  fields(query, [&out](const char* name, const std::string& value) {
    if (value.empty()) return;
    if (!out.empty()) out += SEP;
    out += name;
    out += '=';
    out += clean(value);
  });
  return out;
}

bool decodeQuery(const std::string& text, FacetQuery& out) {
  out = FacetQuery{};
  size_t start = 0;
  while (start < text.size()) {
    size_t end = text.find(SEP, start);
    if (end == std::string::npos) end = text.size();
    const std::string part = text.substr(start, end - start);
    const size_t eq = part.find('=');
    if (eq == std::string::npos) return false;
    const std::string name = part.substr(0, eq);
    bool known = false;
    fields(out, [&](const char* field, std::string& value) {
      if (name == field) {
        value = part.substr(eq + 1);
        known = true;
      }
    });
    if (!known) return false;
    start = end + 1;
  }
  return true;
}

bool Plan::add(const Kind kind, const std::string& arg) {
  if (steps.size() >= MAX_STEPS) return false;
  const std::string value = cleanLine(arg);
  for (const Step& s : steps)
    if (s.kind == kind && s.arg == value) return false;
  steps.push_back(Step{kind, value});
  return true;
}

const Step* Plan::next() const { return done < steps.size() ? &steps[done] : nullptr; }

void Plan::advance() {
  if (done < steps.size()) ++done;
}

size_t Plan::count(const Kind kind) const {
  size_t n = 0;
  for (const Step& s : steps) n += s.kind == kind ? 1 : 0;
  return n;
}

std::string Plan::serialize() const {
  std::string out = std::string(HEADER) + "\n" + std::to_string(done) + "\n";
  for (const Step& s : steps) {
    out += kindLetter(s.kind);
    out += '\t';
    out += s.arg;
    out += '\n';
  }
  return out;
}

bool Plan::parse(const std::string& text) {
  steps.clear();
  done = 0;
  size_t pos = text.find('\n');
  if (pos == std::string::npos || text.compare(0, pos, HEADER) != 0) return false;
  size_t start = pos + 1;
  pos = text.find('\n', start);
  if (pos == std::string::npos || pos == start) return false;
  const std::string doneText = text.substr(start, pos - start);
  char* end = nullptr;
  const unsigned long parsedDone = std::strtoul(doneText.c_str(), &end, 10);
  if (!end || *end != '\0') return false;
  start = pos + 1;
  std::vector<Step> read;
  while (start < text.size()) {
    pos = text.find('\n', start);
    if (pos == std::string::npos) pos = text.size();
    const std::string line = text.substr(start, pos - start);
    Kind kind;
    if (line.size() < 2 || line[1] != '\t' || !kindOf(line[0], kind)) return false;
    read.push_back(Step{kind, line.substr(2)});
    start = pos + 1;
  }
  if (parsedDone > read.size() || read.size() > MAX_STEPS) return false;
  steps = std::move(read);
  done = parsedDone;
  return true;
}

namespace {
std::string urlEncode(const std::string& s) {
  std::string out;
  out.reserve(s.size() * 3);
  for (const unsigned char c : s) {
    if (std::isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
      out += static_cast<char>(c);
    } else {
      char buf[4];
      std::snprintf(buf, sizeof(buf), "%%%02X", c);
      out += buf;
    }
  }
  return out;
}
void param(std::string& url, const char* name, const std::string& value) {
  if (value.empty()) return;
  url += '&';
  url += name;
  url += '=';
  url += urlEncode(value);
}
}  // namespace

std::string booksPath(const FacetQuery& q, const int page, const int size, const bool withLetters) {
  if (!q.shelf.empty()) return "/plugin/catalog/dashboard/sections/" + urlEncode(q.shelf);
  std::string url = "/plugin/catalog/books?page=" + std::to_string(page) + "&size=" + std::to_string(size) + "&format=epub";
  if (withLetters) url += "&buckets=true";
  param(url, "sort", q.sort);
  param(url, "order", q.order);
  param(url, "readStatus", q.readStatus);
  param(url, "q", q.query);
  param(url, "author", q.author);
  // BookOrbit's own plugin: the numeric series id when there is one, else the name.
  if (!q.seriesId.empty()) {
    param(url, "seriesId", q.seriesId);
  } else {
    param(url, "series", q.series);
  }
  param(url, "collectionId", q.collectionId);
  param(url, "smartScopeId", q.smartScopeId);
  param(url, "libraryId", q.libraryId);
  return url;
}

}  // namespace mirror
}  // namespace orbify
