// orbify/core/SleepPick and SleepLayout: the X4 sleep screen (docs/design/lock-screen.md, ROADMAP 11).
// The rotation, Every sleep and the batch's carry run the table Android's companion reads too
// (shared/fixtures/sleep/cases.json); the rest checks the Xteink-only pieces: no clock (R6), the
// batch's top-up across syncs, the shuffle bag, Leave out, the settings and the store, and the band
// and overlay geometry on the X4's 480 x 800 panel.
#include <ArduinoJson.h>

#include <cstring>
#include <string>
#include <vector>

#include "SleepLayout.h"
#include "SleepPick.h"
#include "TestSupport.h"

using namespace orbify::sleep;

namespace {

// The case's draws in order; past the end, 0.
struct Draws {
  std::vector<uint32_t> values;
  size_t next = 0;
};
uint32_t fromDraws(const uint32_t n, void* ctx) {
  auto* d = static_cast<Draws*>(ctx);
  const uint32_t v = d->next < d->values.size() ? d->values[d->next++] : 0;
  return v < n ? v : n - 1;
}

// A small deterministic generator for the property checks.
uint32_t lcg(const uint32_t n, void* ctx) {
  auto* s = static_cast<uint32_t*>(ctx);
  *s = *s * 1103515245u + 12345u;
  return (*s >> 8) % n;
}

Mode modeOf(const char* s) {
  if (std::strcmp(s, "recommended") == 0) return Mode::Recommended;
  if (std::strcmp(s, "current") == 0) return Mode::Current;
  return Mode::Off;
}

std::string showName(const Decision& d) {
  switch (d.show) {
    case Show::Off:
      return "off";
    case Show::Current:
      return "current";
    case Show::Default:
      return "default";
    case Show::Pool:
      return "pool:" + std::to_string(d.id);
  }
  return "?";
}

void rotationCases(JsonArrayConst cases) {
  CHECK(cases.size() >= 20);
  for (JsonObjectConst c : cases) {
    const char* name = c["name"];
    Entry pool[BATCH];
    size_t n = 0;
    JsonObjectConst shows = c["state"]["shows"];
    for (JsonVariantConst id : c["pool"].as<JsonArrayConst>()) {
      pool[n].id = id.as<uint32_t>();
      pool[n].shows = shows[std::to_string(pool[n].id)] | 0;
      n++;
    }
    State st;
    st.shown = c["state"]["shown"];
    st.changedAt = c["state"]["changed_at"];
    Draws draws;
    for (JsonVariantConst v : c["rand"].as<JsonArrayConst>()) draws.values.push_back(v.as<uint32_t>());
    const Decision d = decide(modeOf(c["mode"]), c["hours"], c["now"].as<uint64_t>(), pool, n, c["current"], st,
                              c["advance"] | true, fromDraws, &draws);
    CHECK_NAMED(name, showName(d) == c["show"].as<std::string>());
    CHECK_NAMED(name, st.shown == c["next"]["shown"].as<uint32_t>());
    CHECK_NAMED(name, st.changedAt == c["next"]["changed_at"].as<uint64_t>());
    // The counts after: those of the covers still ready (the X4 keeps them with the batch).
    JsonObjectConst want = c["next"]["shows"];
    // (Counts of covers that are not ready are not kept on the card at all.)
    for (size_t i = 0; i < n; i++) CHECK_NAMED(name, (want[std::to_string(pool[i].id)] | 0) == pool[i].shows);
  }
}

void batchCases(JsonArrayConst cases) {
  CHECK(cases.size() >= 3);
  for (JsonObjectConst c : cases) {
    const char* name = c["name"];
    Entry prev[BATCH];
    size_t n = 0;
    for (JsonObjectConst e : c["prev"].as<JsonArrayConst>()) prev[n++] = Entry{e["id"], e["shows"], 0};
    Entry carried[BATCH];
    uint32_t retired[BATCH];
    size_t retiredCount = 0;
    const size_t carriedCount = carry(prev, n, carried, retired, &retiredCount);
    JsonArrayConst wantCarry = c["carry"];
    CHECK_NAMED(name, carriedCount == wantCarry.size());
    for (size_t i = 0; i < carriedCount && i < wantCarry.size(); i++) CHECK_NAMED(name, carried[i].id == wantCarry[i]);
    JsonArrayConst wantRetired = c["retired"];
    CHECK_NAMED(name, retiredCount == wantRetired.size());
    for (size_t i = 0; i < retiredCount && i < wantRetired.size(); i++) CHECK_NAMED(name, retired[i] == wantRetired[i]);
    // The X4 tops the batch up from the candidates it has not got yet.
    Batch batch;
    for (size_t i = 0; i < carriedCount; i++) batch.entries[batch.count++] = carried[i];
    std::vector<uint32_t> candidates;
    for (JsonVariantConst v : c["candidates"].as<JsonArrayConst>()) candidates.push_back(v);
    uint32_t fresh[BATCH];
    const size_t freshCount =
        freshOrder(candidates.data(), candidates.size(), batch, retired, retiredCount, fresh, BATCH);
    JsonArrayConst wantFresh = c["xteink_fresh"];
    CHECK_NAMED(name, freshCount == wantFresh.size());
    for (size_t i = 0; i < freshCount && i < wantFresh.size(); i++) CHECK_NAMED(name, fresh[i] == wantFresh[i]);
  }
}

// R6: an X4 without Keep Clock in Sleep knows no time at sleep. The cover shown last stays and
// nothing moves; the sleep sync's redraw, with the time, makes the change.
void noClock() {
  Entry pool[3] = {{5, 0, 0}, {7, 0, 0}, {9, 0, 0}};
  State st{7, 1700000000000ull};
  Decision d = decide(Mode::Recommended, 6, 0, pool, 3, true, st, true, nullptr, nullptr);
  CHECK(d.show == Show::Pool && d.id == 7 && st.shown == 7 && st.changedAt == 1700000000000ull);
  // First sleep with no clock: the first cover, and no change recorded, so the redraw counts it.
  st = State{};
  d = decide(Mode::Recommended, 6, 0, pool, 3, true, st, true, nullptr, nullptr);
  CHECK(d.id == 5 && st.shown == 5 && st.changedAt == 0);
  // The redraw with the time: due (never changed), so the next... no: shown with changedAt 0 is due.
  d = decide(Mode::Recommended, 6, 1700000000000ull, pool, 3, true, st, true, nullptr, nullptr);
  CHECK(d.id == 7 && st.changedAt == 1700000000000ull);
  // Every sleep needs no clock.
  uint32_t seed = 1;
  st = State{5, 0};
  d = decide(Mode::Recommended, EVERY_SLEEP, 0, pool, 3, true, st, true, lcg, &seed);
  CHECK(d.show == Show::Pool && d.id != 5);
}

// The user's ruling (2026-11-24): every cover at most 3 times, never twice in a row, then retired at
// the next sync, which tops the batch up; with nothing new, the ready ones keep cycling.
void everySleepOverSyncs() {
  Batch batch;
  for (uint32_t id = 1; id <= BATCH; id++) batch.admit(id, true, false, 0, nullptr);
  CHECK(batch.count == BATCH && batch.wanted(true, false, 0) == 0);
  State st;
  uint32_t seed = 7;
  uint32_t last = 0;
  for (int sleepN = 0; sleepN < static_cast<int>(BATCH) * SHOWS_MAX; sleepN++) {
    const Decision d = decide(Mode::Recommended, EVERY_SLEEP, 1000 + sleepN, batch.entries, batch.count, true, st,
                              true, lcg, &seed);
    CHECK(d.show == Show::Pool && d.id != last);
    last = d.id;
  }
  // Fresh covers first: after 72 sleeps nearly every cover had its 3 (the last may need a 4th to
  // avoid a repeat), none more than one over.
  size_t total = 0, atMax = 0;
  for (size_t i = 0; i < batch.count; i++) {
    total += batch.entries[i].shows;
    atMax += batch.entries[i].shows >= SHOWS_MAX && batch.entries[i].id != st.shown;
    CHECK(batch.entries[i].shows <= SHOWS_MAX + 1);
  }
  CHECK(total == BATCH * SHOWS_MAX && atMax >= BATCH - 3);
  // A sync: 4 fresh covers replace used-up ones, the batch stays full.
  CHECK(batch.wanted(true, false, st.shown) == atMax);
  for (uint32_t id = 100; id < 100 + FETCH_PER_SYNC; id++) {
    uint32_t replaced = 0;
    CHECK(batch.admit(id, true, false, st.shown, &replaced) && replaced != 0 && replaced != st.shown &&
          !batch.contains(replaced));
  }
  CHECK(batch.count == BATCH);
  // The fresh ones come first now.
  for (int k = 0; k < static_cast<int>(FETCH_PER_SYNC); k++) {
    const Decision d =
        decide(Mode::Recommended, EVERY_SLEEP, 5000 + k, batch.entries, batch.count, true, st, true, lcg, &seed);
    CHECK(d.id >= 100);
  }
  // Offline from here: no sync ever comes, and it keeps cycling (never the same twice in a row).
  last = st.shown;
  for (int k = 0; k < 200; k++) {
    const Decision d =
        decide(Mode::Recommended, EVERY_SLEEP, 9000 + k, batch.entries, batch.count, true, st, true, lcg, &seed);
    CHECK(d.show == Show::Pool && d.id != last);
    last = d.id;
  }
}

// R2/R3: a list source in hours mode follows the list; the batch fills a few covers per sync.
void hoursFromList() {
  Batch batch;
  const uint32_t list1[] = {10, 11, 12, 13, 14, 15};
  uint32_t fresh[BATCH];
  size_t n = freshOrder(list1, 6, batch, nullptr, 0, fresh, FETCH_PER_SYNC);
  CHECK(n == FETCH_PER_SYNC && fresh[0] == 10 && fresh[3] == 13);
  for (size_t i = 0; i < n; i++) batch.admit(fresh[i], false, false, 0, nullptr);
  n = freshOrder(list1, 6, batch, nullptr, 0, fresh, FETCH_PER_SYNC);
  CHECK(n == 2 && fresh[0] == 14 && fresh[1] == 15);
  for (size_t i = 0; i < n; i++) batch.admit(fresh[i], false, false, 0, nullptr);
  // The list moved on: 10 and 12 left, 16 came in second.
  const uint32_t list2[] = {11, 16, 13, 14, 15};
  uint32_t dropped[BATCH];
  CHECK(batch.followList(list2, 5, dropped) == 2 && dropped[0] == 10 && dropped[1] == 12);
  CHECK(batch.count == 4 && batch.entries[0].id == 11 && batch.entries[1].id == 13);
  n = freshOrder(list2, 5, batch, nullptr, 0, fresh, FETCH_PER_SYNC);
  CHECK(n == 1 && fresh[0] == 16);
  // A list source never retires in hours mode.
  batch.entries[0].shows = 9;
  CHECK(!usedUp(batch.entries[0], false, false, 0));
  // A full batch of covers in use takes nothing.
  Batch full;
  for (uint32_t id = 1; id <= BATCH; id++) full.admit(id, false, false, 0, nullptr);
  uint32_t replaced = 1;
  CHECK(!full.admit(99, false, false, 0, &replaced) && replaced == 0);
  // From a bag in hours mode: a cover shown once (and not on screen) makes room.
  full.entries[3].shows = 1;
  full.entries[5].shows = 1;
  CHECK(full.wanted(false, true, full.entries[5].id) == 1);
  CHECK(full.admit(99, false, true, full.entries[5].id, &replaced) && replaced == 4);
}

void bag() {
  uint32_t buf[16];
  Bag b{buf, 16, 0, 0, 0};
  const uint32_t members[] = {1, 2, 3, 4, 5, 6};
  uint32_t seed = 3;
  bagSync(b, members, 6, lcg, &seed);
  CHECK(b.count == 6 && b.pos == 0);
  for (const uint32_t m : members) {
    bool found = false;
    for (size_t i = 0; i < b.count; i++) found = found || b.order[i] == m;
    CHECK(found);
  }
  const uint32_t* next = nullptr;
  CHECK(bagNext(b, lcg, &seed, &next) == 6);
  const uint32_t taken[] = {next[0], next[1]};
  bagTake(b, taken, 2);
  CHECK(b.pos == 2 && b.prev == taken[1]);
  // Listed again: one taken book left, one not-taken left, one new: taken ones stay taken.
  const uint32_t left[] = {taken[1], b.order[4]};
  std::vector<uint32_t> now;
  for (size_t i = 0; i < b.count; i++) {
    if (b.order[i] != left[0] && b.order[i] != left[1]) now.push_back(b.order[i]);
  }
  now.push_back(7);
  bagSync(b, now.data(), now.size(), lcg, &seed);
  CHECK(b.count == 5 && b.pos == 1 && b.order[0] == taken[0]);
  bool sevenAfterPos = false;
  for (size_t i = b.pos; i < b.count; i++) sevenAfterPos = sevenAfterPos || b.order[i] == 7;
  CHECK(sevenAfterPos);
  // Used up: shuffled again, never starting with the book taken last.
  for (int round = 0; round < 50; round++) {
    b.pos = b.count;
    b.prev = b.order[b.count - 1];
    const uint32_t avoid = b.prev;
    CHECK(bagNext(b, lcg, &seed, &next) == b.count && next[0] != avoid);
  }
  // Over capacity: the first members are kept.
  uint32_t small[3];
  Bag c{small, 3, 0, 0, 0};
  bagSync(c, members, 6, lcg, &seed);
  CHECK(c.count == 3);
}

bool readVec(const size_t i, uint32_t* id, void* ctx) {
  const auto* v = static_cast<std::vector<uint32_t>*>(ctx);
  if (i >= v->size()) return false;
  *id = (*v)[i];
  return true;
}

void leaveOut() {
  std::vector<uint32_t> ids = {40, 3, 17, 3, 900, 1};
  ids.resize(sortUnique(ids.data(), ids.size()));
  CHECK(ids.size() == 5 && ids[0] == 1 && ids[4] == 900);
  for (const uint32_t id : {1u, 3u, 17u, 40u, 900u}) CHECK(sortedContains(id, ids.size(), readVec, &ids));
  for (const uint32_t id : {0u, 2u, 18u, 901u}) CHECK(!sortedContains(id, ids.size(), readVec, &ids));
  CHECK(!sortedContains(5, 0, readVec, &ids));
  // Tags: exact, ignoring ASCII case and outer spaces (X3); no rule knows a field.
  CHECK(tagMatches(" Age:18 , horror", "age:18"));
  CHECK(tagMatches("age:18,Horror", "  HORROR "));
  CHECK(!tagMatches("age:18", "age:1"));
  CHECK(!tagMatches("age:18", "age:180"));
  CHECK(!tagMatches("", "x") && !tagMatches(",,", "") && !tagMatches(nullptr, "x"));
  CHECK(hasTagRules(" a ") && !hasTagRules(" , ") && !hasTagRules(""));
  CHECK(combine(Check::Keep, Check::Unknown) == Check::Unknown);
  CHECK(combine(Check::Unknown, Check::Out) == Check::Out);
  CHECK(combine(Check::Keep, Check::Keep) == Check::Keep);
  // Scope rules: "scope:<id>" and "collection:<id>", comma or newline separated; others skipped.
  From f;
  const char* p = nextScopeRule("scope:3, tag:x ,collection:12\nscope:0,scope:4", f);
  CHECK(p && f.kind == FromKind::Scope && f.id == 3);
  p = nextScopeRule(p, f);
  CHECK(p && f.kind == FromKind::Collection && f.id == 12);
  p = nextScopeRule(p, f);
  CHECK(p && f.kind == FromKind::Scope && f.id == 4);
  CHECK(nextScopeRule(p, f) == nullptr);
}

void settings() {
  From f;
  char buf[32];
  for (const char* s : {"up_next", "want_to_read", "discover", "scope:12", "collection:4000000000"}) {
    CHECK(parseFrom(s, f) && formatFrom(f, buf, sizeof(buf)) && std::strcmp(buf, s) == 0);
  }
  for (const char* s : {"", "scope:", "scope:0", "scope:12x", "collection:99999999999", "upnext", "tag:x"}) {
    CHECK(!parseFrom(s, f));
  }
  CHECK(std::strcmp(sectionType(FromKind::UpNext), "up-next-in-series") == 0);
  CHECK(std::strcmp(sectionType(FromKind::Discover), "random") == 0);
  CHECK(sectionType(FromKind::Scope) == nullptr);
  FromKind order[3];
  CHECK(listOrder(FromKind::Discover, order) == 3 && order[0] == FromKind::Discover &&
        order[1] == FromKind::UpNext && order[2] == FromKind::WantToRead);
  CHECK(cleanHours(0) == 0 && cleanHours(24) == 24 && cleanHours(2) == DEFAULT_HOURS && cleanHours(-1) == 6);
  char text[4 * TEXT_MAX + 1];
  cleanText("  Bedtime\n8 pm ", text, sizeof(text));
  CHECK(std::strcmp(text, "Bedtime 8 pm") == 0);
  std::string longText(80, 'x');
  cleanText(longText.c_str(), text, sizeof(text));
  CHECK(std::strlen(text) == TEXT_MAX);
  std::string emoji;
  for (int i = 0; i < 70; i++) emoji += "\xF0\x9F\x98\x80";
  cleanText(emoji.c_str(), text, sizeof(text));
  CHECK(std::strlen(text) == 4 * TEXT_MAX);
}

// Pick from and Leave out as sets (R1c, X8): the cases Android's tests read too.
std::string lines(JsonVariantConst v) { return v.isNull() ? std::string() : std::string(v.as<const char*>()); }

struct Lists {
  std::vector<uint32_t> list[LIST_KINDS];
  bool known[LIST_KINDS] = {};
};
const uint32_t* listAtFor(const FromKind kind, size_t* count, void* ctx) {
  auto* l = static_cast<Lists*>(ctx);
  const size_t k = static_cast<size_t>(kind);
  if (k >= LIST_KINDS || !l->known[k]) return nullptr;
  *count = l->list[k].size();
  return l->list[k].data();
}

struct Members {
  JsonObjectConst sets;
};
Check inMembersFor(const From& rule, const uint32_t id, void* ctx) {
  char key[32];
  formatFrom(rule, key, sizeof(key));
  JsonArrayConst set = static_cast<Members*>(ctx)->sets[key].as<JsonArrayConst>();
  if (set.isNull()) return Check::Unknown;
  for (JsonVariantConst v : set) {
    if (v.as<uint32_t>() == id) return Check::Out;
  }
  return Check::Keep;
}

void sourceCases(JsonObjectConst sources) {
  for (JsonObjectConst c : sources["from"].as<JsonArrayConst>()) {
    char out[256];
    CHECK(normalizeSources(c["wire"].as<const char*>(), out, sizeof(out)));
    if (std::string(out) != lines(c["expect"])) std::printf("  from '%s': got '%s'\n", c["name"].as<const char*>(), out);
    CHECK(std::string(out) == lines(c["expect"]));
  }
  for (JsonObjectConst c : sources["leave_out"].as<JsonArrayConst>()) {
    char out[256];
    CHECK(normalizeRules(c["wire"].as<const char*>(), out, sizeof(out)));
    if (std::string(out) != lines(c["expect"])) std::printf("  leave_out '%s': got '%s'\n", c["name"].as<const char*>(), out);
    CHECK(std::string(out) == lines(c["expect"]));
  }
  static const char* const NAMES[LIST_KINDS] = {"up_next", "want_to_read", "discover"};
  for (JsonObjectConst c : sources["candidates"].as<JsonArrayConst>()) {
    Lists l;
    for (size_t k = 0; k < LIST_KINDS; k++) {
      JsonArrayConst a = c["lists"][NAMES[k]].as<JsonArrayConst>();
      if (a.isNull()) continue;
      l.known[k] = true;
      for (JsonVariantConst v : a) l.list[k].push_back(v.as<uint32_t>());
    }
    std::vector<uint32_t> bag;
    for (JsonVariantConst v : c["bag"].as<JsonArrayConst>()) bag.push_back(v.as<uint32_t>());
    uint32_t out[64];
    const FromKind* fallback = nullptr;
    const size_t n = candidates(c["from"].as<const char*>(), listAtFor, &l, bag.data(), bag.size(), out, 64, &fallback);
    std::vector<uint32_t> want;
    for (JsonVariantConst v : c["expect"].as<JsonArrayConst>()) want.push_back(v.as<uint32_t>());
    const bool same = std::vector<uint32_t>(out, out + n) == want;
    if (!same) std::printf("  candidates '%s'\n", c["name"].as<const char*>());
    CHECK(same);
    const char* fb = c["fallback"].isNull() ? nullptr : c["fallback"].as<const char*>();
    CHECK(fb ? (fallback && std::strcmp(NAMES[static_cast<size_t>(*fallback)], fb) == 0) : fallback == nullptr);
  }
  for (JsonObjectConst c : sources["check"].as<JsonArrayConst>()) {
    Members m{c["members"].as<JsonObjectConst>()};
    std::vector<const char*> tags;
    const bool known = !c["tags"].isNull();
    for (JsonVariantConst v : c["tags"].as<JsonArrayConst>()) tags.push_back(v.as<const char*>());
    const Check got = checkBook(c["id"].as<uint32_t>(), c["rules"].as<const char*>(), inMembersFor, &m,
                                known ? tags.data() : nullptr, tags.size());
    const char* want = c["expect"].as<const char*>();
    const Check expect = std::strcmp(want, "out") == 0 ? Check::Out : std::strcmp(want, "keep") == 0 ? Check::Keep
                                                                                                        : Check::Unknown;
    if (got != expect) std::printf("  check '%s'\n", c["name"].as<const char*>());
    CHECK(got == expect);
  }
  // Toggling (the X4s' list screens): Library stands alone both ways.
  char out[256];
  CHECK(toggleItem("up_next\nscope:3", "library", true, out, sizeof(out)) && std::string(out) == "library");
  CHECK(toggleItem("library", "discover", true, out, sizeof(out)) && std::string(out) == "discover");
  CHECK(toggleItem("up_next\nscope:3", "up_next", true, out, sizeof(out)) && std::string(out) == "scope:3");
  CHECK(toggleItem("scope:3", "scope:3", true, out, sizeof(out)) && std::string(out) == "up_next");
  CHECK(toggleItem("scope:3", "collection:4", false, out, sizeof(out)) && std::string(out) == "scope:3\ncollection:4");
  CHECK(toggleItem("scope:3\ncollection:4", "library", false, out, sizeof(out)) && std::string(out) == "library");
  CHECK(toggleItem("library", "library", false, out, sizeof(out)) && std::string(out).empty());
  CHECK(hasLibrary("scope:3\nlibrary") && !hasLibrary("scope:3") && hasMemberSources("up_next\nlibrary") &&
        !hasMemberSources("up_next\ndiscover"));
  // The old comma-separated settings still read.
  CHECK(normalizeSources("scope:3,up_next", out, sizeof(out)) && std::string(out) == "scope:3\nup_next");
}

void store() {
  Store s;
  s.sourceStamp = fnv1a("scope:12");
  s.rulesStamp = 0xDEADBEEF;
  s.state = State{7, 1700000000123ull};
  s.battery = 82;
  s.listAt = 1700000000;
  s.listCount[1] = 2;
  s.list[1][0] = 7;
  s.list[1][1] = 9;
  s.listCount[2] = 1;
  s.list[2][0] = 60;
  s.batch.admit(7, true, false, 0, nullptr);
  s.batch.admit(9, true, false, 0, nullptr);
  s.batch.entries[0].shows = 2;
  s.batch.entries[1].flags = 0x5;
  uint8_t buf[STORE_BYTES];
  CHECK(serialize(s, buf, sizeof(buf)) == STORE_BYTES);
  Store back;
  CHECK(parse(buf, sizeof(buf), back));
  CHECK(back.sourceStamp == s.sourceStamp && back.rulesStamp == s.rulesStamp && back.state.shown == 7 &&
        back.state.changedAt == 1700000000123ull && back.battery == 82 && back.listAt == 1700000000 &&
        back.listCount[0] == 0 && back.listCount[1] == 2 && back.list[1][1] == 9 && back.list[2][0] == 60 &&
        back.batch.count == 2 &&
        back.batch.entries[0].shows == 2 && back.batch.entries[1].flags == 0x5);
  buf[20] ^= 1;  // a flipped bit: the CRC refuses it, the caller takes the other slot
  CHECK(!parse(buf, sizeof(buf), back));
  CHECK(!parse(buf, sizeof(buf) - 1, back));
  CHECK(serialize(s, buf, sizeof(buf) - 1) == 0);
}

// L3-L3e on the X4 (480 x 800): the band 56 px (80 with two lines), plates inset 10 px.
void layout() {
  const int w = 480, h = 800;
  CHECK(bandHeight(h, 1) == 56 && bandHeight(h, 2) == 80);
  CHECK(inset(w, h) == 10);
  // A 2:3 cover over the band: 480 x 720, which leaves exactly the 80 px L3 counts on.
  Box c = coverBox(w, h, 56, 400, 600);
  CHECK(c.left == 0 && c.width() == 480 && c.height() == 720 && c.top == 12 && c.bottom <= h - 56);
  c = coverBox(w, h, 80, 400, 600);
  CHECK(c.bottom <= h - 80 && c.height() == 720);
  c = coverBox(w, h, 0, 0, 0);
  CHECK(c.width() == w && c.height() == h);
  // L3b2: the battery leaves the text's side.
  CHECK(batteryCorner(Corner::BottomLeft, TextPos::Bottom, true) == Corner::TopLeft);
  CHECK(batteryCorner(Corner::TopRight, TextPos::Top, true) == Corner::BottomRight);
  CHECK(batteryCorner(Corner::BottomRight, TextPos::Right, true) == Corner::BottomLeft);
  CHECK(batteryCorner(Corner::TopLeft, TextPos::Left, true) == Corner::TopRight);
  CHECK(batteryCorner(Corner::BottomLeft, TextPos::Right, true) == Corner::BottomLeft);  // the defaults
  CHECK(batteryCorner(Corner::BottomRight, TextPos::Right, false) == Corner::BottomRight);
  // Right: one rotated line along the right edge, centred; cut at 90 % of the edge.
  Box t = textPlate(w, h, TextPos::Right, 300, 20, 10);
  CHECK(t.right == w - 10 && t.width() == 40 && t.height() == 320 && t.top == (h - 320) / 2);
  t = textPlate(w, h, TextPos::Left, 2000, 20, 10);
  CHECK(t.left == 10 && t.height() == 720);
  t = textPlate(w, h, TextPos::Bottom, 600, 44, 10);
  CHECK(t.bottom == h - 10 && t.width() == 432 && t.left == 24);
  t = textPlate(w, h, TextPos::Top, 100, 20, 10);
  CHECK(t.top == 10 && t.width() == 120 && t.left == 180);
  Box b = batteryPlate(w, h, Corner::BottomLeft, 60, 20, 10);
  CHECK(b.left == 10 && b.bottom == h - 10 && b.width() == 80 && b.height() == 40);
  b = batteryPlate(w, h, Corner::TopRight, 60, 20, 10);
  CHECK(b.right == w - 10 && b.top == 10);
  // Plates never overlap the battery once it moved (every position, every corner).
  for (const TextPos p : {TextPos::Right, TextPos::Left, TextPos::Top, TextPos::Bottom}) {
    for (const Corner k : {Corner::TopLeft, Corner::TopRight, Corner::BottomLeft, Corner::BottomRight}) {
      const Box tp = textPlate(w, h, p, maxTextWidth(w, h, Style::Overlay, p, 10, 0), 22, 10);
      const Box bp = batteryPlate(w, h, batteryCorner(k, p, true), 60, 20, 10);
      const bool overlap = tp.left < bp.right && bp.left < tp.right && tp.top < bp.bottom && bp.top < tp.bottom;
      // A full-width top or bottom plate and a battery on the other side: never together.
      CHECK(!overlap || vertical(p));
    }
  }
  CHECK(maxTextWidth(w, h, Style::Bar, TextPos::Right, 10, 60) == 480 - 20 - 80);
  CHECK(maxTextWidth(w, h, Style::Overlay, TextPos::Right, 10, 0) == 700);
  CHECK(maxTextWidth(w, h, Style::Overlay, TextPos::Top, 10, 0) == 412);
  CHECK(maxLines(Style::Bar, TextPos::Right) == 2 && maxLines(Style::Overlay, TextPos::Left) == 1 &&
        maxLines(Style::Overlay, TextPos::Bottom) == 2);
  const BarLayout bl = bar(w, h, 56);
  CHECK(bl.band.top == h - 54 && bl.textLeft == 10 && bl.batteryRight == w - 10);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) return 2;
  std::string dir = argv[1];
  dir = dir.substr(0, dir.rfind('/')) + "/sleep";
  JsonDocument doc;
  if (!loadJsonFile((dir + "/cases.json").c_str(), doc)) return 1;
  rotationCases(doc["cases"].as<JsonArrayConst>());
  batchCases(doc["batch"].as<JsonArrayConst>());
  sourceCases(doc["sources"].as<JsonObjectConst>());
  noClock();
  everySleepOverSyncs();
  hoursFromList();
  bag();
  leaveOut();
  settings();
  store();
  layout();
  return report("sleep_pick");
}
