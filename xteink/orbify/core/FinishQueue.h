#pragma once
// Orbify "mark done at the end of a book" (docs/design/end-of-book/DESIGN.md §3, §5, §7): the device's
// durable queue of finished books and the drain that tells BookOrbit about them.
//
// Pure C++: no Arduino, no SD card, no HTTP. The firmware glue (../FinishSync.cpp) gives it a
// file and a transport; xteink/test/finish_test.cpp runs it against
// shared/fixtures/bookorbit/finish-cases.json (the table Android's tests read too) and finish-steps.json.
#include <cstddef>
#include <cstdint>

namespace orbify {

// BookOrbit's per-user read status (server/src/db/schema/reader.ts:35).
enum class ServerStatus : uint8_t {
  Unknown = 0,
  Unread,
  WantToRead,
  Reading,
  OnHold,
  Rereading,
  Read,
  Skimmed,
  Abandoned,
};
ServerStatus parseServerStatus(const char* text);  // Unknown for null, empty or an unknown value
const char* serverStatusName(ServerStatus status);

// One finished book. One record per book: the newest local intent wins.
struct FinishJob {
  static constexpr uint8_t SENT = 1;       // BookOrbit has it; kept for the stale-push hold (§7)
  static constexpr uint8_t PARKED = 2;     // 5 failed attempts: only a manual sync retries it
  static constexpr uint8_t AUTH_WAIT = 4;  // the server said 401: kept until the next sign-in works

  char hash[33] = {};          // KOReader partial MD5, lower-case hex
  int64_t bookId = 0;          // BookOrbit book id, 0 = unknown (a sideloaded book)
  uint32_t finishedOn = 0;     // YYYYMMDD local day, 0 = unknown (clock never set: G19)
  int8_t rating = 0;           // 0 = none, 1..5 stars, -1 = clear (X4 only, item 2)
  ServerStatus statusSeen = ServerStatus::Unknown;  // the server's status when the book was finished
  uint8_t flags = 0;
  uint8_t attempts = 0;
  uint32_t nextTryAt = 0;      // epoch seconds; 0 = at the next network session
  uint32_t createdAt = 0;      // epoch seconds, 0 when the clock was not set
  uint16_t finalPermille = 0;  // the final position, 0..1000
  uint32_t pagesAtFinish = 0;  // the book's forward page-turn count when it was finished

  bool sent() const { return (flags & SENT) != 0; }
  bool parked() const { return (flags & PARKED) != 0; }
};

// Fixed-size records, at most MAX_JOBS, kept in book order of creation.
class FinishQueue {
 public:
  static constexpr size_t MAX_JOBS = 16;
  static constexpr size_t RECORD_BYTES = 64;
  static constexpr size_t HEADER_BYTES = 8;  // magic "OFQ1", version, count, 2 reserved
  static constexpr size_t MAX_PAYLOAD_BYTES = HEADER_BYTES + MAX_JOBS * RECORD_BYTES;

  size_t size() const { return count_; }
  FinishJob& at(size_t i) { return jobs_[i]; }
  const FinishJob& at(size_t i) const { return jobs_[i]; }
  FinishJob* find(const char* hash);
  const FinishJob* find(const char* hash) const;

  // Adds or replaces the job for job.hash. A full queue drops its oldest sent job, else its oldest.
  void upsert(const FinishJob& job);
  // Undo, or the book was marked unfinished: forgets the job. True when there was one.
  bool remove(const char* hash);
  // Jobs that still need the network.
  size_t pending() const;

  size_t serialize(uint8_t* out, size_t capacity) const;  // bytes written, 0 when it does not fit
  bool deserialize(const uint8_t* data, size_t size);     // false (and empty) for anything unknown

 private:
  FinishJob jobs_[MAX_JOBS];
  size_t count_ = 0;
};

// Crash safety, the same policy as CrossInk's progress.bin and reading stats (TwoSlotFile.h):
// each save overwrites the older of two slot files in place; a slot is the payload, a u32
// sequence and a u32 CRC-32 of both, so a torn write fails its CRC and the other slot, one
// save older, is read instead.
namespace slot {
constexpr size_t TRAILER_BYTES = 8;
size_t encode(const uint8_t* payload, size_t size, uint32_t seq, uint8_t* out, size_t capacity);
// Payload size, or 0 when the slot is missing, torn or not a slot. outSeq gets its sequence.
size_t decode(const uint8_t* data, size_t size, uint32_t& outSeq);
uint32_t crc32(const uint8_t* data, size_t size);
}  // namespace slot

// The drain's view of the server: each call returns the HTTP status, or a negative number
// when the transport failed. Implemented over BookOrbitSyncClient in the firmware and from
// the fixture in the host test.
class FinishTransport {
 public:
  virtual ~FinishTransport() = default;
  // POST /koreader/plugin/book-states {hash, status:"complete", statusModified?, rating?}.
  virtual int bookStates(const FinishJob& job, bool withStatus, bool withRating) = 0;
  // POST /koreader/plugin/match-check: the book id of a hash the server already knows.
  virtual int matchCheck(const char* hash, int64_t& outBookId) = 0;
  // GET /koreader/plugin/catalog/books/:id, read for its readStatus only.
  virtual int readStatus(int64_t bookId, ServerStatus& outStatus) = 0;
  // PUT /koreader/plugin/catalog/books/:id/read-status {status:"read"}.
  virtual int setRead(int64_t bookId) = 0;
  // PUT /koreader/plugin/catalog/books/:id/rating {rating}, null for a clear.
  virtual int setRating(int64_t bookId, int8_t rating) = 0;
};

enum class DrainOutcome : uint8_t {
  NotDue,    // waiting for its retry time, parked, already sent, or waiting for a sign-in
  Sent,      // every step done; the job stays as SENT for the hold
  Retry,     // network, timeout, 5xx or 429: tried again later (60 s doubling to 1 h)
  Parked,    // the fifth failure in a row
  AuthWait,  // 401: kept, "Sign in to BookOrbit to send"
  Dropped,   // 400, 403 or 404: removed and logged
};
const char* drainOutcomeName(DrainOutcome outcome);

struct DrainOptions {
  uint32_t now = 0;             // epoch seconds, 0 or implausible = unknown (no retry times)
  bool manual = false;          // a sync the reader started: parked and 401 jobs are tried again
  const char* knownHash = "";   // a hash this session's progress fetch found on the server
  bool sendRatings = true;      // false on the X3 (no rating row)
};

// The plausible-clock floor CrossInk uses (BookOrbitHomeStore.cpp MIN_PLAUSIBLE_EPOCH).
constexpr uint32_t MIN_PLAUSIBLE_EPOCH = 1704067200u;  // 2024-01-01
constexpr uint8_t MAX_ATTEMPTS = 5;

bool isDue(const FinishJob& job, const DrainOptions& options);
// Runs steps 2-6 of the drain for one job (step 1, the final position, is the reader's own
// progress push, made just before). Updates the job's flags, attempts and retry time.
DrainOutcome drainOne(FinishJob& job, FinishTransport& transport, const DrainOptions& options);

// §7, Xteink: an automatic sync does not push a position ≥10 points below where a book that is
// finished on this device ended, unless the reader turned ≥10 pages forward since finishing.
bool holdAutomaticPush(const FinishJob* job, bool finishedLocally, uint16_t pushPermille, uint32_t pagesTurnedNow);

// "2026-11-20" <-> 20261120. 0 / false for anything else.
uint32_t parseDay(const char* text);
bool formatDay(uint32_t day, char out[11]);

}  // namespace orbify
