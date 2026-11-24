#include "SleepPick.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace orbify {
namespace sleep {

namespace {

int indexIn(const Entry* pool, const size_t count, const uint32_t id) {
  if (id == 0) return -1;
  for (size_t i = 0; i < count; i++) {
    if (pool[i].id == id) return static_cast<int>(i);
  }
  return -1;
}

bool inList(const uint32_t* ids, const size_t count, const uint32_t id) {
  for (size_t i = 0; i < count; i++) {
    if (ids[i] == id) return true;
  }
  return false;
}

uint32_t draw(const Rand rand, void* ctx, const uint32_t n) {
  if (n <= 1 || !rand) return 0;
  const uint32_t r = rand(n, ctx);
  return r < n ? r : n - 1;
}

Decision everySleep(const uint64_t now, Entry* pool, const size_t count, State& st, const bool advance, const Rand rand,
                    void* ctx) {
  const int shownAt = indexIn(pool, count, st.shown);
  if (!advance && shownAt >= 0) return {Show::Pool, st.shown};
  // Indexes of the covers it may pick: never the one just shown (unless it is the only one), those
  // shown fewer than SHOWS_MAX times first.
  size_t others[BATCH];
  size_t otherCount = 0;
  for (size_t i = 0; i < count && otherCount < BATCH; i++) {
    if (count == 1 || pool[i].id != st.shown) others[otherCount++] = i;
  }
  size_t fresh[BATCH];
  size_t freshCount = 0;
  for (size_t i = 0; i < otherCount; i++) {
    if (pool[others[i]].shows < SHOWS_MAX) fresh[freshCount++] = others[i];
  }
  const size_t* from = freshCount ? fresh : others;
  const size_t fromCount = freshCount ? freshCount : otherCount;
  const size_t pick = from[draw(rand, ctx, static_cast<uint32_t>(fromCount))];
  if (!advance) return {Show::Pool, pool[pick].id};
  if (pool[pick].shows < 0xFF) pool[pick].shows++;
  st.shown = pool[pick].id;
  st.changedAt = now;
  return {Show::Pool, st.shown};
}

}  // namespace

Decision decide(const Mode mode, const int hours, const uint64_t now, Entry* pool, const size_t count,
                const bool hasCurrent, State& st, const bool advance, const Rand rand, void* ctx) {
  if (mode == Mode::Off) return {Show::Off, 0};
  if (mode == Mode::Current && hasCurrent) return {Show::Current, 0};
  if (count == 0) return {hasCurrent ? Show::Current : Show::Default, 0};
  if (hours == EVERY_SLEEP) return everySleep(now, pool, count, st, advance, rand, ctx);
  const int idx = indexIn(pool, count, st.shown);
  if (now == 0) {
    // R6: no clock. The cover shown last stays (or the pool's first, if it left); nothing moves.
    st.shown = idx < 0 ? pool[0].id : pool[idx].id;
    return {Show::Pool, st.shown};
  }
  // A clock that went backwards resets the last change to now.
  const uint64_t changed = now < st.changedAt ? now : st.changedAt;
  const bool due = st.shown == 0 || now - changed >= static_cast<uint64_t>(hours) * 3600000ULL;
  uint32_t next;
  if (idx < 0) {
    next = pool[0].id;
  } else if (due) {
    next = pool[(static_cast<size_t>(idx) + 1) % count].id;
  } else {
    next = pool[idx].id;
  }
  st.shown = next;
  st.changedAt = due ? now : changed;
  return {Show::Pool, next};
}

// --- the batch -------------------------------------------------------------------------------------------

size_t carry(const Entry* prev, const size_t count, Entry* carried, uint32_t* retired, size_t* retiredCount) {
  size_t c = 0;
  size_t r = 0;
  for (size_t i = 0; i < count; i++) {
    const uint32_t id = prev[i].id;
    if (id == 0) continue;
    bool seen = false;
    for (size_t j = 0; j < i; j++) seen = seen || prev[j].id == id;
    if (seen) continue;
    if (prev[i].shows >= SHOWS_MAX) {
      retired[r++] = id;
    } else {
      carried[c++] = prev[i];
    }
  }
  if (retiredCount) *retiredCount = r;
  return c;
}

bool usedUp(const Entry& e, const bool every, const bool bag, const uint32_t current) {
  // The cover on screen stays: the sleep sync's redraw draws it again.
  if (e.id == current) return false;
  if (every) return e.shows >= SHOWS_MAX;
  return bag && e.shows >= 1 && e.id != current;
}

int Batch::indexOf(const uint32_t id) const { return indexIn(entries, count, id); }

size_t Batch::wanted(const bool every, const bool bag, const uint32_t current) const {
  size_t n = BATCH - count;
  for (size_t i = 0; i < count; i++) {
    if (usedUp(entries[i], every, bag, current)) n++;
  }
  return n;
}

bool Batch::admit(const uint32_t id, const bool every, const bool bag, const uint32_t current, uint32_t* replaced) {
  if (replaced) *replaced = 0;
  if (id == 0 || contains(id)) return false;
  if (count < BATCH) {
    entries[count++] = Entry{id, 0, 0};
    return true;
  }
  for (size_t i = 0; i < count; i++) {
    if (!usedUp(entries[i], every, bag, current)) continue;
    if (replaced) *replaced = entries[i].id;
    // The fresh cover goes to the end of the rotation; the used-up one leaves.
    for (size_t j = i; j + 1 < count; j++) entries[j] = entries[j + 1];
    entries[count - 1] = Entry{id, 0, 0};
    return true;
  }
  return false;
}

bool Batch::remove(const uint32_t id) {
  const int at = indexOf(id);
  if (at < 0) return false;
  for (size_t j = static_cast<size_t>(at); j + 1 < count; j++) entries[j] = entries[j + 1];
  count--;
  return true;
}

size_t Batch::followList(const uint32_t* list, const size_t listCount, uint32_t* dropped) {
  Entry kept[BATCH];
  size_t k = 0;
  size_t d = 0;
  for (size_t i = 0; i < listCount && k < BATCH; i++) {
    const int at = indexOf(list[i]);
    if (at >= 0 && indexIn(kept, k, list[i]) < 0) kept[k++] = entries[at];
  }
  for (size_t i = 0; i < count; i++) {
    if (indexIn(kept, k, entries[i].id) < 0 && dropped) dropped[d++] = entries[i].id;
  }
  std::copy(kept, kept + k, entries);
  count = k;
  return d;
}

size_t freshOrder(const uint32_t* candidates, const size_t count, const Batch& batch, const uint32_t* retired,
                  const size_t retiredCount, uint32_t* out, const size_t max) {
  size_t n = 0;
  for (size_t i = 0; i < count && n < max; i++) {
    const uint32_t id = candidates[i];
    if (id == 0 || batch.contains(id) || inList(retired, retiredCount, id) || inList(out, n, id)) continue;
    out[n++] = id;
  }
  return n;
}

// --- the shuffle bag -------------------------------------------------------------------------------------

void shuffle(uint32_t* ids, const size_t count, const uint32_t avoidFirst, const Rand rand, void* ctx) {
  for (size_t i = count; i >= 2; i--) {
    const size_t j = draw(rand, ctx, static_cast<uint32_t>(i));
    std::swap(ids[i - 1], ids[j]);
  }
  if (avoidFirst != 0 && count > 1 && ids[0] == avoidFirst) {
    const size_t j = 1 + draw(rand, ctx, static_cast<uint32_t>(count - 1));
    std::swap(ids[0], ids[j]);
  }
}

void bagSync(Bag& bag, const uint32_t* members, const size_t memberCount, const Rand rand, void* ctx) {
  // Keep the old order's members (once each), counting how many taken ones left.
  size_t out = 0;
  size_t pos = bag.pos;
  for (size_t i = 0; i < bag.count; i++) {
    const uint32_t id = bag.order[i];
    if (inList(members, memberCount, id) && !inList(bag.order, out, id)) {
      bag.order[out++] = id;
    } else if (i < bag.pos && pos > 0) {
      pos--;
    }
  }
  // New members go in among the books not taken yet.
  for (size_t m = 0; m < memberCount && out < bag.capacity; m++) {
    const uint32_t id = members[m];
    if (id == 0 || inList(bag.order, out, id)) continue;
    const size_t at = pos + draw(rand, ctx, static_cast<uint32_t>(out - pos + 1));
    for (size_t j = out; j > at; j--) bag.order[j] = bag.order[j - 1];
    bag.order[at] = id;
    out++;
  }
  bag.count = out;
  bag.pos = std::min(pos, out);
}

size_t bagNext(Bag& bag, const Rand rand, void* ctx, const uint32_t** out) {
  *out = bag.order;
  if (bag.count == 0) return 0;
  if (bag.pos >= bag.count) {
    shuffle(bag.order, bag.count, bag.prev, rand, ctx);
    bag.pos = 0;
  }
  *out = bag.order + bag.pos;
  return bag.count - bag.pos;
}

void bagTake(Bag& bag, const uint32_t* taken, const size_t takenCount) {
  size_t pos = bag.pos;
  for (size_t i = bag.pos; i < bag.count; i++) {
    if (inList(taken, takenCount, bag.order[i])) pos = i + 1;
  }
  if (pos != bag.pos) {
    bag.prev = bag.order[pos - 1];
    bag.pos = pos;
  }
}

// --- Leave out ---------------------------------------------------------------------------------------------

bool sortedContains(const uint32_t id, const size_t count, const ReadAt readAt, void* ctx) {
  size_t lo = 0;
  size_t hi = count;
  while (lo < hi) {
    const size_t mid = lo + (hi - lo) / 2;
    uint32_t v = 0;
    if (!readAt(mid, &v, ctx)) return false;
    if (v == id) return true;
    if (v < id) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return false;
}

size_t sortUnique(uint32_t* ids, const size_t count) {
  std::sort(ids, ids + count);
  return static_cast<size_t>(std::unique(ids, ids + count) - ids);
}

namespace {
char lowerAscii(const char c) { return (c >= 'A' && c <= 'Z') ? static_cast<char>(c + 32) : c; }
bool isSpace(const char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }

// [b, e) trimmed.
void trim(const char*& b, const char*& e) {
  while (b < e && isSpace(*b)) b++;
  while (e > b && isSpace(e[-1])) e--;
}

bool sameIgnoringCase(const char* a, const char* ae, const char* b, const char* be) {
  if (ae - a != be - b) return false;
  for (; a < ae; a++, b++) {
    if (lowerAscii(*a) != lowerAscii(*b)) return false;
  }
  return true;
}
}  // namespace

bool tagMatches(const char* rules, const char* tag) {
  if (!rules || !tag) return false;
  const char* tb = tag;
  const char* te = tag + std::strlen(tag);
  trim(tb, te);
  if (tb == te) return false;
  const char* p = rules;
  while (*p) {
    const char* e = p;
    while (*e && *e != ',') e++;
    const char* rb = p;
    const char* re = e;
    trim(rb, re);
    if (rb < re && sameIgnoringCase(rb, re, tb, te)) return true;
    p = *e ? e + 1 : e;
  }
  return false;
}

bool hasTagRules(const char* rules) {
  if (!rules) return false;
  for (const char* p = rules; *p; p++) {
    if (!isSpace(*p) && *p != ',') return true;
  }
  return false;
}

// --- Pick from and the settings --------------------------------------------------------------------------

namespace {
bool parseRef(const char* text, const char* prefix, uint32_t& id) {
  const size_t n = std::strlen(prefix);
  if (std::strncmp(text, prefix, n) != 0) return false;
  const char* digits = text + n;
  if (*digits < '1' || *digits > '9') return false;
  uint64_t v = 0;
  const char* p = digits;
  for (; *p >= '0' && *p <= '9'; p++) {
    v = v * 10 + static_cast<uint64_t>(*p - '0');
    if (v > 0xFFFFFFFFull) return false;
  }
  if (*p != '\0') return false;
  id = static_cast<uint32_t>(v);
  return true;
}
}  // namespace

bool parseFrom(const char* text, From& out) {
  if (!text) return false;
  if (std::strcmp(text, "up_next") == 0) return out = From{FromKind::UpNext, 0}, true;
  if (std::strcmp(text, "want_to_read") == 0) return out = From{FromKind::WantToRead, 0}, true;
  if (std::strcmp(text, "discover") == 0) return out = From{FromKind::Discover, 0}, true;
  uint32_t id = 0;
  if (parseRef(text, "scope:", id)) return out = From{FromKind::Scope, id}, true;
  if (parseRef(text, "collection:", id)) return out = From{FromKind::Collection, id}, true;
  return false;
}

bool formatFrom(const From& from, char* out, const size_t size) {
  int n = 0;
  switch (from.kind) {
    case FromKind::UpNext:
      n = std::snprintf(out, size, "up_next");
      break;
    case FromKind::WantToRead:
      n = std::snprintf(out, size, "want_to_read");
      break;
    case FromKind::Discover:
      n = std::snprintf(out, size, "discover");
      break;
    case FromKind::Scope:
      n = std::snprintf(out, size, "scope:%u", static_cast<unsigned>(from.id));
      break;
    case FromKind::Collection:
      n = std::snprintf(out, size, "collection:%u", static_cast<unsigned>(from.id));
      break;
  }
  return n > 0 && static_cast<size_t>(n) < size;
}

const char* sectionType(const FromKind kind) {
  switch (kind) {
    case FromKind::UpNext:
      return "up-next-in-series";
    case FromKind::WantToRead:
      return "want-to-read";
    case FromKind::Discover:
      return "random";
    default:
      return nullptr;
  }
}

size_t listOrder(const FromKind chosen, FromKind* out) {
  size_t n = 0;
  out[n++] = chosen;
  for (const FromKind k : {FromKind::UpNext, FromKind::WantToRead, FromKind::Discover}) {
    if (k != chosen) out[n++] = k;
  }
  return n;
}

const char* nextScopeRule(const char* text, From& out) {
  if (!text) return nullptr;
  const char* p = text;
  while (*p) {
    const char* e = p;
    while (*e && *e != ',' && *e != '\n') e++;
    const char* b = p;
    const char* t = e;
    trim(b, t);
    char item[32];
    const size_t len = static_cast<size_t>(t - b);
    p = *e ? e + 1 : e;
    if (len == 0 || len >= sizeof(item)) continue;
    std::memcpy(item, b, len);
    item[len] = '\0';
    From f;
    if (parseFrom(item, f) && (f.kind == FromKind::Scope || f.kind == FromKind::Collection)) {
      out = f;
      return p;
    }
  }
  return nullptr;
}

bool validHours(const int hours) {
  for (const int h : HOURS) {
    if (h == hours) return true;
  }
  return false;
}

void cleanText(const char* in, char* out, const size_t size) {
  if (size == 0) return;
  out[0] = '\0';
  if (!in) return;
  size_t o = 0;
  size_t points = 0;
  bool pendingSpace = false;
  for (const char* p = in; *p;) {
    const unsigned char c = static_cast<unsigned char>(*p);
    if (c == '\r' || c == '\n' || c == '\t' || c == ' ') {
      pendingSpace = o > 0;
      p++;
      continue;
    }
    // One code point: its lead byte and continuation bytes.
    size_t len = 1;
    if (c >= 0xF0) {
      len = 4;
    } else if (c >= 0xE0) {
      len = 3;
    } else if (c >= 0xC0) {
      len = 2;
    }
    for (size_t k = 1; k < len; k++) {
      if ((static_cast<unsigned char>(p[k]) & 0xC0) != 0x80) {
        len = k;
        break;
      }
    }
    const size_t need = len + (pendingSpace ? 1 : 0);
    if (points + (pendingSpace ? 1 : 0) + 1 > TEXT_MAX || o + need + 1 > size) break;
    if (pendingSpace) {
      out[o++] = ' ';
      points++;
      pendingSpace = false;
    }
    std::memcpy(out + o, p, len);
    o += len;
    points++;
    p += len;
  }
  out[o] = '\0';
}

uint32_t fnv1a(const char* text, uint32_t seed) {
  uint32_t h = seed;
  for (const char* p = text ? text : ""; *p; p++) {
    h ^= static_cast<uint8_t>(*p);
    h *= 16777619u;
  }
  return h;
}

// --- the store ------------------------------------------------------------------------------------------

uint32_t crc32(const uint8_t* data, const size_t size) {
  uint32_t crc = 0xFFFFFFFFu;
  for (size_t i = 0; i < size; i++) {
    crc ^= data[i];
    for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
  }
  return ~crc;
}

namespace {
constexpr uint32_t MAGIC = 0x504C534Fu;  // "OSLP"
constexpr uint16_t VERSION = 1;

struct Writer {
  uint8_t* p;
  void u8(const uint8_t v) { *p++ = v; }
  void u16(const uint16_t v) {
    u8(static_cast<uint8_t>(v));
    u8(static_cast<uint8_t>(v >> 8));
  }
  void u32(const uint32_t v) {
    u16(static_cast<uint16_t>(v));
    u16(static_cast<uint16_t>(v >> 16));
  }
  void u64(const uint64_t v) {
    u32(static_cast<uint32_t>(v));
    u32(static_cast<uint32_t>(v >> 32));
  }
};
struct Reader {
  const uint8_t* p;
  uint8_t u8() { return *p++; }
  uint16_t u16() {
    const uint16_t lo = u8();
    return static_cast<uint16_t>(lo | (u8() << 8));
  }
  uint32_t u32() {
    const uint32_t lo = u16();
    return lo | (static_cast<uint32_t>(u16()) << 16);
  }
  uint64_t u64() {
    const uint64_t lo = u32();
    return lo | (static_cast<uint64_t>(u32()) << 32);
  }
};
}  // namespace

size_t serialize(const Store& s, uint8_t* out, const size_t size) {
  if (size < STORE_BYTES) return 0;
  Writer w{out};
  w.u32(MAGIC);
  w.u16(VERSION);
  w.u32(s.sourceStamp);
  w.u32(s.rulesStamp);
  w.u32(s.state.shown);
  w.u64(s.state.changedAt);
  w.u8(s.battery);
  w.u32(s.listAt);
  w.u32(s.scopesAt);
  w.u8(s.listKind);
  w.u8(s.listCount);
  for (size_t i = 0; i < BATCH; i++) w.u32(i < s.listCount ? s.list[i] : 0);
  w.u8(static_cast<uint8_t>(s.batch.count));
  for (size_t i = 0; i < BATCH; i++) {
    const Entry e = i < s.batch.count ? s.batch.entries[i] : Entry{};
    w.u32(e.id);
    w.u8(e.shows);
    w.u8(e.flags);
  }
  const size_t body = static_cast<size_t>(w.p - out);
  w.u32(crc32(out, body));
  return STORE_BYTES;
}

bool parse(const uint8_t* in, const size_t size, Store& out) {
  if (size < STORE_BYTES) return false;
  Reader r{in};
  if (r.u32() != MAGIC || r.u16() != VERSION) return false;
  Reader crcAt{in + STORE_BYTES - 4};
  if (crc32(in, STORE_BYTES - 4) != crcAt.u32()) return false;
  Store s;
  s.sourceStamp = r.u32();
  s.rulesStamp = r.u32();
  s.state.shown = r.u32();
  s.state.changedAt = r.u64();
  s.battery = r.u8();
  s.listAt = r.u32();
  s.scopesAt = r.u32();
  s.listKind = r.u8();
  s.listCount = std::min<uint8_t>(r.u8(), BATCH);
  for (size_t i = 0; i < BATCH; i++) s.list[i] = r.u32();
  s.batch.count = std::min<size_t>(r.u8(), BATCH);
  for (size_t i = 0; i < BATCH; i++) {
    Entry e;
    e.id = r.u32();
    e.shows = r.u8();
    e.flags = r.u8();
    if (i < s.batch.count) s.batch.entries[i] = e;
  }
  out = s;
  return true;
}

}  // namespace sleep
}  // namespace orbify
