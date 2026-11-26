#pragma once
// BookSync sleep screen, X4 Pro and X4 (docs/design/lock-screen.md R1-R10, X1-X7, ROADMAP 11): the
// rules, as pure functions with no allocation. The firmware (../SleepScreen.cpp) does the files and
// the requests; xteink/test/sleep_pick_test.cpp checks these, the rotation and the batch against the
// table Android's companion reads too (shared/fixtures/sleep/cases.json).
//
//   - A batch of up to 24 covers is kept ready on the SD card, whatever Pick from is (the user's
//     ruling, 2026-11-24). Each sleep sync tops it up by a few covers (FETCH_PER_SYNC), inside the
//     sync's own time budget: no network step is added and the wake path never waits on one.
//   - Every sleep (sleep_hours 0): a random ready cover at each sleep, never the one just shown, each
//     shown at most SHOWS_MAX times; the next sync replaces used-up covers with fresh ones. With
//     nothing new they keep cycling, offline included. The counts live with the batch on the card.
//   - A smart scope or collection is a shuffle bag (R1b); Leave out is a set of rules, tags and
//     smart scopes or collections, never a hard-coded field (X1-X7), failed closed.
#include <cstddef>
#include <cstdint>

namespace orbify {
namespace sleep {

constexpr size_t BATCH = 24;
constexpr uint8_t SHOWS_MAX = 3;
constexpr size_t BAG_MAX = 500;
constexpr size_t LEAVE_OUT_MAX = 4000;
constexpr int PAGE_SIZE = 100;
// Listing pages (bag and Leave out members) per sleep sync, as the mirror's slices (design "Scope
// sources and Leave out on the X4s").
constexpr int PAGES_PER_SLEEP = 10;
// Covers fetched per sleep sync: the batch fills over a few sleeps instead of one long one.
constexpr size_t FETCH_PER_SYNC = 4;
// Books whose detail is asked (Leave out by tag, or the book's own checks) per sleep sync.
constexpr size_t PROBE_PER_SYNC = 8;
constexpr uint32_t DAY_S = 86400;
constexpr int EVERY_SLEEP = 0;
constexpr size_t TEXT_MAX = 60;  // code points (L5)
// Change cover every: Every sleep, then hours (R5). Default 6 h.
constexpr int HOURS[] = {EVERY_SLEEP, 1, 3, 6, 12, 24};
constexpr size_t HOURS_COUNT = sizeof(HOURS) / sizeof(HOURS[0]);
constexpr int DEFAULT_HOURS = 6;

enum class Mode : uint8_t { Off, Recommended, Current };

// One ready cover: its book and, with Every sleep, how often it was shown.
struct Entry {
  uint32_t id = 0;
  uint8_t shows = 0;
  uint8_t flags = 0;  // the firmware's (SleepScreen.cpp): decoded, checked against the rules
};

// READY and HIDDEN are persistent batch flags. The open book never enters the ready pool.
inline bool readyForPick(const Entry& entry, const uint32_t openId) {
  return entry.id != 0 && entry.id != openId && (entry.flags & 0x01) && !(entry.flags & 0x08);
}

// The cover shown last and when it last changed (ms since the epoch, as Android's).
struct State {
  uint32_t shown = 0;
  uint64_t changedAt = 0;
};

enum class Show : uint8_t { Off, Pool, Current, Default };
struct Decision {
  Show show = Show::Off;
  uint32_t id = 0;  // Show::Pool
};

// n -> 0 .. n-1 (n >= 1).
using Rand = uint32_t (*)(uint32_t n, void* ctx);

// What to show at sleep (R4, R4b, F1, F4). now: ms since the epoch, 0 = the clock is unknown (an X4
// without Keep Clock in Sleep, R6: the cover shown last stays, and the sleep sync's redraw changes it
// once the time is known). pool: the ready covers in rotation order; with Every sleep and advance,
// the shown cover's count goes up in place. advance false (a redraw of the same sleep): Every sleep
// keeps the cover just shown.
Decision decide(Mode mode, int hours, uint64_t now, Entry* pool, size_t count, bool hasCurrent, State& state,
                bool advance, Rand rand, void* ctx);

// --- the batch (R2, R3, R4b) ---------------------------------------------------------------------------

// Every sleep at a sync: the ready covers carried on, in order, and those used up (shown SHOWS_MAX
// times). Returns the carried count; retired gets the rest (both may be the caller's buffers of
// `count`). Duplicates count once. SleepPoolLogic.carry on Android, the same table.
size_t carry(const Entry* prev, size_t count, Entry* carried, uint32_t* retired, size_t* retiredCount);

// A cover the batch may give up for a fresh one, never the one on screen (`current`, which the sleep
// sync's redraw draws again): Every sleep, shown SHOWS_MAX times; with a bag in hours mode, shown once. A list source in hours mode never: the list
// itself decides what is in the batch.
bool usedUp(const Entry& e, bool every, bool bag, uint32_t current);

struct Batch {
  Entry entries[BATCH];
  size_t count = 0;

  int indexOf(uint32_t id) const;
  bool contains(uint32_t id) const { return indexOf(id) >= 0; }
  // How many fresh covers it can take now: free places plus used-up covers.
  size_t wanted(bool every, bool bag, uint32_t current) const;
  // Takes a fetched cover: a free place, else the first used-up cover's (whose id goes to *replaced,
  // so its files can go). False when it is full of covers still in use.
  bool admit(uint32_t id, bool every, bool bag, uint32_t current, uint32_t* replaced);
  // Drops one; true when it was there.
  bool remove(uint32_t id);
  // Hours mode from a list: the batch follows the list's order, and covers that left it go to
  // `dropped` (up to BATCH). Returns how many were dropped.
  size_t followList(const uint32_t* list, size_t listCount, uint32_t* dropped);
};

// The order a sync tries the candidates in: those not in the batch and not retired, first come first,
// duplicates once. Writes up to `max` ids to out; returns how many.
size_t freshOrder(const uint32_t* candidates, size_t count, const Batch& batch, const uint32_t* retired,
                  size_t retiredCount, uint32_t* out, size_t max);

// --- the shuffle bag (R1b) ------------------------------------------------------------------------------

struct Bag {
  uint32_t* order = nullptr;  // the caller's buffer of `capacity` ids
  size_t capacity = 0;
  size_t count = 0;
  size_t pos = 0;     // the ids before pos were taken
  uint32_t prev = 0;  // the id taken last (never first after a reshuffle)
};
// Fisher-Yates; avoidFirst (0 none) never comes first when there is another.
void shuffle(uint32_t* ids, size_t count, uint32_t avoidFirst, Rand rand, void* ctx);
// Listed again: members that left come out, new ones go in at random places among those not taken
// yet. members: the scope's ids now (at most capacity are kept).
void bagSync(Bag& bag, const uint32_t* members, size_t memberCount, Rand rand, void* ctx);
// The ids not taken yet (a used-up bag is shuffled again first, never starting with prev).
size_t bagNext(Bag& bag, Rand rand, void* ctx, const uint32_t** out);
// The books admitted into the batch count as taken: the cursor moves past the last of them.
void bagTake(Bag& bag, const uint32_t* taken, size_t takenCount);

// --- Leave out (X1-X7) ---------------------------------------------------------------------------------

// A book in a sorted id file, by binary search: readAt(i, &id) reads the i-th id. No heap.
using ReadAt = bool (*)(size_t index, uint32_t* id, void* ctx);
bool sortedContains(uint32_t id, size_t count, ReadAt readAt, void* ctx);
// Sorts and removes duplicates in place; returns the new count.
size_t sortUnique(uint32_t* ids, size_t count);

// Tag rules: comma-separated, matched exactly ignoring ASCII case and outer spaces (X3). True when
// `tag` is one of them.
bool tagMatches(const char* rules, const char* tag);
bool hasTagRules(const char* rules);

// "keep", "out" or "unknown" for one book (X7: the caller fails unknown closed).
enum class Check : uint8_t { Keep, Out, Unknown };
inline Check combine(Check a, Check b) {
  if (a == Check::Out || b == Check::Out) return Check::Out;
  return (a == Check::Unknown || b == Check::Unknown) ? Check::Unknown : Check::Keep;
}

// --- Pick from and the stored settings (R1, S3, S4) -----------------------------------------------------

// Library: every book the account can see (R1c, X8). The three dashboard lists come first, so a
// list's kind is its slot in the store.
enum class FromKind : uint8_t { UpNext, WantToRead, Discover, Scope, Collection, Library, LibrarySource };
constexpr size_t LIST_KINDS = 3;
inline bool isList(FromKind k) { return k == FromKind::UpNext || k == FromKind::WantToRead || k == FromKind::Discover; }
struct From {
  FromKind kind = FromKind::UpNext;
  uint32_t id = 0;  // Scope, Collection
};
// "up_next", "want_to_read", "discover", "library", "scope:<id>", "collection:<id>" (one item of
// Android's sleep_from).
bool parseFrom(const char* text, From& out);
// Writes the same form; false when the buffer is too small.
bool formatFrom(const From& from, char* out, size_t size);
// The dashboard section type a list source asks for (B koreader.ts:443-449), nullptr for a bag.
const char* sectionType(FromKind kind);
// R1: an empty list falls back to Up next, Want to read, Discover in that order (without itself).
// Writes up to 3 kinds, the chosen one first.
size_t listOrder(FromKind chosen, FromKind* out);

// One member rule ("scope:<id>" or "collection:<id>") of a list (one per line; commas also
// separate); returns the next position, or nullptr at the end. Other and malformed items are skipped.
const char* nextScopeRule(const char* text, From& out);
// One item of Pick from (any kind), the same way.
const char* nextFrom(const char* text, From& out);

// --- Pick from and Leave out as sets (R1c, X8; cases.json "sources") ----------------------------------

// Pick from as stored: valid items, once each, in the order picked, one per line (commas are read as
// separators too). Library stands alone; nothing valid is "up_next". Returns false when out is too small.
bool normalizeSources(const char* text, char* out, size_t size);
// Leave out as stored: rules ("tag:<text>" lower-cased, "scope:<id>", "collection:<id>", "library"),
// one per line, once each; Library stands alone (it leaves out every book). Dashboard lists are not rules.
bool normalizeRules(const char* text, char* out, size_t size);
// Library is among the items (Pick from or Leave out).
bool hasLibrary(const char* text);
// Toggles one item of a set (R1c, X8): Library clears the others, another item clears Library.
// `item` is one formatted item; out gets the new set (normalized when sources is true, else as rules).
bool toggleItem(const char* text, const char* item, bool sources, char* out, size_t size);

// The order a top-up tries books in (R1c): each picked list a stream in the server's order, and one
// shuffle bag over every picked library, scope and collection, one more stream where its first source
// was picked; the streams in turn, a book once. When every stream is empty: Up next, Want to read,
// Discover, the first not picked that has books (*fallback; else nullptr). listAt(kind, &count, ctx)
// gives a list's books (nullptr: none).
using ListAt = const uint32_t* (*)(FromKind kind, size_t* count, void* ctx);
size_t candidates(const char* sources, ListAt listAt, void* ctx, const uint32_t* bag, size_t bagCount, uint32_t* out,
                  size_t max, const FromKind** fallback);
// The picked sources that are listed by their members (library, scopes, collections).
bool hasMemberSources(const char* sources);

// One book against the Leave out rules (X1-X8): Library out; a tag rule needs the book's tags
// (tags nullptr: not known yet); a scope or collection rule asks inMembers (Unknown while its list is
// not complete). Out wins, then Unknown (failed closed, X7).
using InMembers = Check (*)(const From& rule, uint32_t id, void* ctx);
Check checkBook(uint32_t id, const char* rules, InMembers inMembers, void* ctx, const char* const* tags,
                size_t tagCount);

bool validHours(int hours);
// Hours as stored: a bad value is the default.
inline int cleanHours(int hours) { return validHours(hours) ? hours : DEFAULT_HOURS; }
// One line of at most TEXT_MAX code points: newlines and tabs become spaces, outer spaces go.
// Writes into out (size >= 4 * TEXT_MAX + 1 always fits).
void cleanText(const char* in, char* out, size_t size);

// FNV-1a 32, for the source and rules stamps the store keeps.
uint32_t fnv1a(const char* text, uint32_t seed = 2166136261u);

// --- the store on the card (two slots with a CRC, as the finish queue) -------------------------------

struct Store {
  uint32_t sourceStamp = 0;  // fnv1a of Pick from: another source empties the batch
  uint32_t rulesStamp = 0;   // fnv1a of the Leave out rules: other rules check every cover again
  State state;
  uint8_t battery = 0xFF;   // the level the first pass drew (the redraw draws the same), 0xFF none
  uint32_t listAt = 0;      // epoch s of the dashboard lists, 0 never
  uint32_t scopesAt = 0;    // epoch s of the smart scope and collection names (the settings' lists)
  uint8_t listCount[LIST_KINDS] = {};
  uint32_t list[LIST_KINDS][BATCH] = {};  // each dashboard list's books in its order (eligible ones only)
  Batch batch;
};
constexpr size_t STORE_BYTES = 4 + 2 + 4 + 4 + 4 + 8 + 1 + 4 + 4 + LIST_KINDS * (1 + 4 * BATCH) + 1 + 6 * BATCH + 4;
// Fixed-size little-endian record with a trailing CRC-32.
size_t serialize(const Store& store, uint8_t* out, size_t size);
bool parse(const uint8_t* in, size_t size, Store& out);
uint32_t crc32(const uint8_t* data, size_t size);

}  // namespace sleep
}  // namespace orbify
