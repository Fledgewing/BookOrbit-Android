#include "CatalogCache.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>

namespace orbify {
namespace cache {

namespace {

constexpr uint32_t FNV_OFFSET = 2166136261u;
constexpr uint32_t FNV_PRIME = 16777619u;

uint32_t fnv(uint32_t hash, const char* data, size_t length) {
  for (size_t i = 0; i < length; i++) hash = (hash ^ static_cast<uint8_t>(data[i])) * FNV_PRIME;
  return hash;
}
uint32_t fnv(uint32_t hash, const std::string& text) { return fnv(hash, text.data(), text.size()); }

std::string lower(std::string text) {
  for (char& c : text) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return text;
}

bool endsWith(const std::string& text, const char* suffix) {
  const size_t n = std::strlen(suffix);
  return text.size() >= n && text.compare(text.size() - n, n, suffix) == 0;
}

// "/…/catalog/books/<id>/<tail>" -> id, or 0.
int64_t bookIdBefore(const std::string& path, const char* tail) {
  const std::string suffix = std::string("/") + tail;
  if (!endsWith(path, suffix.c_str())) return 0;
  const std::string head = path.substr(0, path.size() - suffix.size());
  const size_t slash = head.rfind('/');
  if (slash == std::string::npos) return 0;
  if (!endsWith(head.substr(0, slash), "/catalog/books")) return 0;
  const std::string digits = head.substr(slash + 1);
  if (digits.empty() || digits.find_first_not_of("0123456789") != std::string::npos) return 0;
  return std::strtoll(digits.c_str(), nullptr, 10);
}

uint32_t hashValue(uint32_t hash, JsonVariantConst v) {
  if (v.is<JsonObjectConst>()) {
    JsonObjectConst object = v.as<JsonObjectConst>();
    std::vector<const char*> names;
    names.reserve(object.size());
    for (JsonPairConst p : object) names.push_back(p.key().c_str());
    std::sort(names.begin(), names.end(), [](const char* a, const char* b) { return std::strcmp(a, b) < 0; });
    hash = fnv(hash, "{", 1);
    for (const char* name : names) {
      hash = fnv(hash, name, std::strlen(name) + 1);
      hash = hashValue(hash, object[name]);
    }
    return fnv(hash, "}", 1);
  }
  if (v.is<JsonArrayConst>()) {
    hash = fnv(hash, "[", 1);
    for (JsonVariantConst item : v.as<JsonArrayConst>()) hash = hashValue(fnv(hash, ",", 1), item);
    return fnv(hash, "]", 1);
  }
  std::string scalar;
  serializeJson(v, scalar);
  return fnv(hash, scalar.c_str(), scalar.size() + 1);
}

}  // namespace

std::string makeKey(const std::string& account, const std::string& server, const std::string& method,
                    const std::string& path, const Query& query) {
  std::string base = lower(server);
  while (!base.empty() && base.back() == '/') base.pop_back();
  Query params;
  for (const auto& p : query)
    if (!p.second.empty()) params.push_back(p);
  std::sort(params.begin(), params.end());
  std::string key = account + "\n" + base + "\n" + method + "\n" + path + "\n";
  for (size_t i = 0; i < params.size(); i++) key += (i ? "&" : "") + params[i].first + "=" + params[i].second;
  return key;
}

std::string keyForUrl(const std::string& account, const std::string& method, const std::string& url) {
  const size_t scheme = url.find("://");
  const size_t pathStart = url.find('/', scheme == std::string::npos ? 0 : scheme + 3);
  const std::string server = pathStart == std::string::npos ? url : url.substr(0, pathStart);
  std::string rest = pathStart == std::string::npos ? "/" : url.substr(pathStart);
  Query query;
  const size_t mark = rest.find('?');
  if (mark != std::string::npos) {
    const std::string text = rest.substr(mark + 1);
    rest.resize(mark);
    size_t start = 0;
    while (start <= text.size()) {
      size_t end = text.find('&', start);
      if (end == std::string::npos) end = text.size();
      const std::string pair = text.substr(start, end - start);
      const size_t eq = pair.find('=');
      if (!pair.empty())
        query.emplace_back(pair.substr(0, eq), eq == std::string::npos ? std::string() : pair.substr(eq + 1));
      start = end + 1;
    }
  }
  return makeKey(account, server, method, rest, query);
}

uint32_t keyHash(const std::string& key) { return fnv(FNV_OFFSET, key); }

bool isCacheable(const std::string& method, const std::string& path) {
  if (method != "GET") return false;
  if (path.find("/plugin/catalog/") == std::string::npos && !endsWith(path, "/plugin/catalog")) return false;
  return !endsWith(path, "/thumbnail") && !endsWith(path, "/download") && !endsWith(path, "/file");
}

ReadPlan planRead(const bool hasEntry, const uint32_t validatedAt, const uint32_t now, const Mode mode,
                  const bool offline) {
  ReadPlan plan;
  if (mode == Mode::Full) {
    plan.fetch = !offline;
    plan.serve = offline && hasEntry;  // offline, a Full refresh can only show what is saved
    return plan;
  }
  plan.serve = hasEntry;
  if (offline) return plan;
  if (!hasEntry || mode == Mode::Refresh) {
    plan.fetch = true;
    return plan;
  }
  plan.fetch = now < validatedAt || now - validatedAt >= REVALIDATE_WINDOW_S;
  return plan;
}

uint32_t canonicalHash(JsonVariantConst value) { return hashValue(FNV_OFFSET, value); }

Revalidated revalidate(const int status, const bool hadEntry, const uint32_t cachedHash, const uint32_t replyHash) {
  Revalidated r;
  if (status < 200 || status >= 300) return r;
  r.stored = true;
  r.changed = hadEntry && cachedHash != replyHash;
  return r;
}

WriteEffect writeEffect(const std::string& method, const std::string& path, const int status, JsonVariantConst body) {
  WriteEffect e;
  if (method == "GET" || status < 200 || status >= 300) return e;
  if (const int64_t id = bookIdBefore(path, "read-status")) {
    e.bookId = id;
    e.homeStale = true;
    e.fields["readStatus"] = body["status"];
  } else if (const int64_t id = bookIdBefore(path, "rating")) {
    e.bookId = id;
    e.homeStale = true;
    e.fields["rating"] = body["rating"];
  } else if (path.find("progress") != std::string::npos || path.find("book-states") != std::string::npos) {
    e.homeStale = true;
  }
  return e;
}

bool patchBook(JsonVariant doc, const int64_t bookId, JsonObjectConst fields) {
  if (bookId <= 0 || fields.isNull()) return false;
  bool changed = false;
  if (doc.is<JsonObject>()) {
    JsonObject object = doc.as<JsonObject>();
    if (object["id"].is<int64_t>() && object["id"].as<int64_t>() == bookId) {
      for (JsonPairConst f : fields) {
        if (!object[f.key()].isUnbound() && object[f.key()] != f.value()) {
          object[f.key()] = f.value();
          changed = true;
        }
      }
    }
    for (JsonPair p : object) changed |= patchBook(p.value(), bookId, fields);
  } else if (doc.is<JsonArray>()) {
    for (JsonVariant item : doc.as<JsonArray>()) changed |= patchBook(item, bookId, fields);
  }
  return changed;
}

uint32_t coverVersion(const char* updatedAt) {
  return fnv(FNV_OFFSET, updatedAt ? updatedAt : "", updatedAt ? std::strlen(updatedAt) : 0);
}

CoverPlan planCover(const Mode mode, const bool listedWithCover, const uint32_t listedVersion,
                    const CoverOnDisk& disk, const bool failedBefore) {
  CoverPlan plan;
  if (!listedWithCover) return plan;
  const bool broken = disk.present && disk.file != CoverFile::Ok;
  if (!disk.present) {
    // Missing: fetch it, unless it failed earlier and only the view was opened.
    if (!(failedBefore && mode == Mode::Open)) plan.action = CoverAction::Download;
    return plan;
  }
  if (mode == Mode::Full && broken) {
    plan.removeFirst = true;
    plan.action = CoverAction::Download;
    return plan;
  }
  if (disk.version != listedVersion) {
    // Re-versioned: a metadata-only edit costs a 304 when the old file's ETag is known.
    plan.action = disk.hasEtag && !broken ? CoverAction::Conditional : CoverAction::Download;
    plan.removeFirst = broken;
    return plan;
  }
  // At the listed version: Refresh never touches it; Full refresh asks the server when it can.
  if (mode == Mode::Full && disk.hasEtag) plan.action = CoverAction::Conditional;
  return plan;
}

size_t entriesToEvict(const EntryInfo* entries, const size_t count, const uint32_t maxBytes, const size_t maxEntries,
                      size_t* drop, const size_t capacity) {
  uint64_t bytes = 0;
  for (size_t i = 0; i < count; i++) bytes += entries[i].bytes;
  std::vector<size_t> order;
  for (size_t i = 0; i < count; i++)
    if (!entries[i].pinned) order.push_back(i);
  std::stable_sort(order.begin(), order.end(),
                   [&](size_t a, size_t b) { return entries[a].usedAt < entries[b].usedAt; });
  size_t kept = count;
  size_t n = 0;
  for (size_t i : order) {
    if (bytes <= maxBytes && kept <= maxEntries) break;
    if (n == capacity) break;
    drop[n++] = i;
    bytes -= entries[i].bytes;
    kept--;
  }
  return n;
}


IndexEntry* Index::find(const uint32_t hash) {
  for (auto& e : entries)
    if (e.hash == hash) return &e;
  return nullptr;
}

CoverRecord* Index::cover(const int32_t bookId) {
  for (auto& c : covers)
    if (c.bookId == bookId) return &c;
  return nullptr;
}

namespace {
constexpr char INDEX_MAGIC[4] = {'O', 'C', 'I', '1'};

uint32_t crc32Of(const uint8_t* data, const size_t size) {
  uint32_t crc = 0xFFFFFFFFu;
  for (size_t i = 0; i < size; i++) {
    crc ^= data[i];
    for (int b = 0; b < 8; b++) crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
  }
  return ~crc;
}
void put32(std::string& out, const uint32_t v) {
  for (int i = 0; i < 4; i++) out.push_back(static_cast<char>((v >> (8 * i)) & 0xFF));
}
void putText(std::string& out, const std::string& text, const size_t max) {
  const size_t n = std::min(text.size(), max);
  out.push_back(static_cast<char>(n));
  out.append(text, 0, n);
}
struct Reader {
  const uint8_t* p;
  size_t left;
  bool ok = true;
  uint32_t u32() {
    if (left < 4) return ok = false, 0;
    const uint32_t v = p[0] | (p[1] << 8) | (p[2] << 16) | (static_cast<uint32_t>(p[3]) << 24);
    p += 4, left -= 4;
    return v;
  }
  uint8_t u8() {
    if (left < 1) return ok = false, 0;
    left--;
    return *p++;
  }
  std::string text() {
    const size_t n = u8();
    if (!ok || left < n) return ok = false, std::string();
    std::string s(reinterpret_cast<const char*>(p), n);
    p += n, left -= n;
    return s;
  }
};
}  // namespace

std::string serializeIndex(const Index& index) {
  std::string out(INDEX_MAGIC, 4);
  put32(out, 1);
  put32(out, index.owner);
  put32(out, index.clock);
  put32(out, static_cast<uint32_t>(index.entries.size()));
  for (const auto& e : index.entries) {
    put32(out, e.hash);
    put32(out, e.bytes);
    put32(out, e.fetchedAt);
    put32(out, e.validatedAt);
    put32(out, e.usedAt);
    put32(out, e.replyHash);
    out.push_back(static_cast<char>(e.flags));
    putText(out, e.url.size() <= 255 ? e.url : std::string(), 255);
  }
  const size_t covers = std::min(index.covers.size(), MAX_COVER_RECORDS);
  put32(out, static_cast<uint32_t>(covers));
  for (size_t i = 0; i < covers; i++) {
    const auto& c = index.covers[i];
    put32(out, static_cast<uint32_t>(c.bookId));
    put32(out, c.version);
    putText(out, c.etag.size() <= 63 ? c.etag : std::string(), 63);
  }
  put32(out, crc32Of(reinterpret_cast<const uint8_t*>(out.data()), out.size()));
  return out;
}

bool deserializeIndex(const uint8_t* data, const size_t size, Index& out) {
  out = Index{};
  if (size < 28 || std::memcmp(data, INDEX_MAGIC, 4) != 0) return false;
  Reader tail{data + size - 4, 4};
  if (tail.u32() != crc32Of(data, size - 4)) return false;
  Reader r{data + 4, size - 8};
  if (r.u32() != 1) return false;
  Index index;
  index.owner = r.u32();
  index.clock = r.u32();
  const uint32_t count = r.u32();
  for (uint32_t i = 0; r.ok && i < count && i < 4096; i++) {
    IndexEntry e;
    e.hash = r.u32();
    e.bytes = r.u32();
    e.fetchedAt = r.u32();
    e.validatedAt = r.u32();
    e.usedAt = r.u32();
    e.replyHash = r.u32();
    e.flags = r.u8();
    e.url = r.text();
    index.entries.push_back(std::move(e));
  }
  const uint32_t covers = r.u32();
  for (uint32_t i = 0; r.ok && i < covers && i < MAX_COVER_RECORDS; i++) {
    CoverRecord c;
    c.bookId = static_cast<int32_t>(r.u32());
    c.version = r.u32();
    c.etag = r.text();
    index.covers.push_back(std::move(c));
  }
  if (!r.ok || r.left != 0) return false;
  out = std::move(index);
  return true;
}

}  // namespace cache
}  // namespace orbify
