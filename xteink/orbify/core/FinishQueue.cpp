#include "FinishQueue.h"

#include <cstdio>
#include <cstring>

namespace orbify {
namespace {

constexpr uint8_t MAGIC[4] = {'O', 'F', 'Q', '1'};
constexpr uint8_t VERSION = 1;

struct StatusName {
  ServerStatus status;
  const char* name;
};
constexpr StatusName STATUS_NAMES[] = {
    {ServerStatus::Unread, "unread"},       {ServerStatus::WantToRead, "want_to_read"},
    {ServerStatus::Reading, "reading"},     {ServerStatus::OnHold, "on_hold"},
    {ServerStatus::Rereading, "rereading"}, {ServerStatus::Read, "read"},
    {ServerStatus::Skimmed, "skimmed"},     {ServerStatus::Abandoned, "abandoned"},
};

void putU16(uint8_t* p, uint16_t v) {
  p[0] = v & 0xFF;
  p[1] = v >> 8;
}
void putU32(uint8_t* p, uint32_t v) {
  for (int i = 0; i < 4; i++) p[i] = (v >> (8 * i)) & 0xFF;
}
void putU64(uint8_t* p, uint64_t v) {
  for (int i = 0; i < 8; i++) p[i] = (v >> (8 * i)) & 0xFF;
}
uint16_t getU16(const uint8_t* p) { return static_cast<uint16_t>(p[0] | (p[1] << 8)); }
uint32_t getU32(const uint8_t* p) {
  uint32_t v = 0;
  for (int i = 3; i >= 0; i--) v = (v << 8) | p[i];
  return v;
}
uint64_t getU64(const uint8_t* p) {
  uint64_t v = 0;
  for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
  return v;
}

bool isHexHash(const char* h) {
  for (int i = 0; i < 32; i++) {
    const char c = h[i];
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
  }
  return h[32] == '\0';
}

// A status somebody chose on purpose: never overwritten when it appeared after we finished (G4).
bool chosenElsewhere(ServerStatus s) {
  return s == ServerStatus::Rereading || s == ServerStatus::OnHold || s == ServerStatus::Abandoned ||
         s == ServerStatus::Skimmed;
}

bool ok(int code) { return code >= 200 && code < 300; }

// A failed step: what happens to the job. Returns the outcome; the job is updated.
DrainOutcome fail(FinishJob& job, int code, const DrainOptions& options) {
  if (code == 401) {
    job.flags |= FinishJob::AUTH_WAIT;
    return DrainOutcome::AuthWait;
  }
  if (code >= 400 && code < 500 && code != 408 && code != 429) return DrainOutcome::Dropped;
  if (job.attempts < 255) job.attempts++;
  // 60 s doubling to 1 h. A parked job keeps its time too (the shared table's next_try_in);
  // only a manual sync tries it again (isDue).
  if (options.now >= MIN_PLAUSIBLE_EPOCH) {
    const uint32_t shift = job.attempts - 1u < 6u ? job.attempts - 1u : 6u;
    uint32_t wait = 60u << shift;
    if (wait > 3600) wait = 3600;
    job.nextTryAt = options.now + wait;
  } else {
    job.nextTryAt = 0;
  }
  if (job.attempts >= MAX_ATTEMPTS) {
    job.flags |= FinishJob::PARKED;
    return DrainOutcome::Parked;
  }
  return DrainOutcome::Retry;
}

}  // namespace

ServerStatus parseServerStatus(const char* text) {
  if (!text) return ServerStatus::Unknown;
  for (const auto& entry : STATUS_NAMES) {
    if (strcmp(entry.name, text) == 0) return entry.status;
  }
  return ServerStatus::Unknown;
}

const char* serverStatusName(ServerStatus status) {
  for (const auto& entry : STATUS_NAMES) {
    if (entry.status == status) return entry.name;
  }
  return "";
}

const char* drainOutcomeName(DrainOutcome outcome) {
  switch (outcome) {
    case DrainOutcome::NotDue:
      return "not-due";
    case DrainOutcome::Sent:
      return "sent";
    case DrainOutcome::Retry:
      return "retry";
    case DrainOutcome::Parked:
      return "parked";
    case DrainOutcome::AuthWait:
      return "auth-wait";
    case DrainOutcome::Dropped:
      return "dropped";
  }
  return "";
}

// --- queue -------------------------------------------------------------------------

FinishJob* FinishQueue::find(const char* hash) {
  for (size_t i = 0; i < count_; i++) {
    if (strcmp(jobs_[i].hash, hash) == 0) return &jobs_[i];
  }
  return nullptr;
}

const FinishJob* FinishQueue::find(const char* hash) const { return const_cast<FinishQueue*>(this)->find(hash); }

void FinishQueue::upsert(const FinishJob& job) {
  if (FinishJob* existing = find(job.hash)) {
    *existing = job;
    return;
  }
  if (count_ == MAX_JOBS) {
    size_t drop = 0;
    for (size_t i = 0; i < count_; i++) {
      if (jobs_[i].sent()) {
        drop = i;
        break;
      }
    }
    for (size_t i = drop; i + 1 < count_; i++) jobs_[i] = jobs_[i + 1];
    count_--;
  }
  jobs_[count_++] = job;
}

bool FinishQueue::remove(const char* hash) {
  for (size_t i = 0; i < count_; i++) {
    if (strcmp(jobs_[i].hash, hash) != 0) continue;
    for (size_t j = i; j + 1 < count_; j++) jobs_[j] = jobs_[j + 1];
    count_--;
    return true;
  }
  return false;
}

size_t FinishQueue::pending() const {
  size_t n = 0;
  for (size_t i = 0; i < count_; i++) n += jobs_[i].sent() ? 0 : 1;
  return n;
}

size_t FinishQueue::serialize(uint8_t* out, const size_t capacity) const {
  const size_t total = HEADER_BYTES + count_ * RECORD_BYTES;
  if (capacity < total) return 0;
  memset(out, 0, total);
  memcpy(out, MAGIC, 4);
  out[4] = VERSION;
  out[5] = static_cast<uint8_t>(count_);
  for (size_t i = 0; i < count_; i++) {
    const FinishJob& j = jobs_[i];
    uint8_t* r = out + HEADER_BYTES + i * RECORD_BYTES;
    memcpy(r, j.hash, 32);
    putU64(r + 32, static_cast<uint64_t>(j.bookId));
    putU32(r + 40, j.finishedOn);
    r[44] = static_cast<uint8_t>(j.rating);
    r[45] = static_cast<uint8_t>(j.statusSeen);
    r[46] = j.flags;
    r[47] = j.attempts;
    putU32(r + 48, j.nextTryAt);
    putU32(r + 52, j.createdAt);
    putU16(r + 56, j.finalPermille);
    putU32(r + 58, j.pagesAtFinish);
    // 62..63 reserved
  }
  return total;
}

bool FinishQueue::deserialize(const uint8_t* data, const size_t size) {
  count_ = 0;
  if (size < HEADER_BYTES || memcmp(data, MAGIC, 4) != 0 || data[4] != VERSION) return false;
  const size_t n = data[5];
  if (n > MAX_JOBS || size != HEADER_BYTES + n * RECORD_BYTES) return false;
  for (size_t i = 0; i < n; i++) {
    const uint8_t* r = data + HEADER_BYTES + i * RECORD_BYTES;
    FinishJob j;
    memcpy(j.hash, r, 32);
    j.hash[32] = '\0';
    if (!isHexHash(j.hash)) {
      count_ = 0;
      return false;
    }
    j.bookId = static_cast<int64_t>(getU64(r + 32));
    j.finishedOn = getU32(r + 40);
    j.rating = static_cast<int8_t>(r[44]);
    j.statusSeen = r[45] <= static_cast<uint8_t>(ServerStatus::Abandoned) ? static_cast<ServerStatus>(r[45])
                                                                          : ServerStatus::Unknown;
    j.flags = r[46];
    j.attempts = r[47];
    j.nextTryAt = getU32(r + 48);
    j.createdAt = getU32(r + 52);
    j.finalPermille = getU16(r + 56);
    j.pagesAtFinish = getU32(r + 58);
    jobs_[count_++] = j;
  }
  return true;
}

// --- slots -------------------------------------------------------------------------

namespace slot {

uint32_t crc32(const uint8_t* data, const size_t size) {
  uint32_t crc = 0xFFFFFFFFu;
  for (size_t i = 0; i < size; i++) {
    crc ^= data[i];
    for (int b = 0; b < 8; b++) crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
  }
  return ~crc;
}

size_t encode(const uint8_t* payload, const size_t size, const uint32_t seq, uint8_t* out, const size_t capacity) {
  if (capacity < size + TRAILER_BYTES) return 0;
  memmove(out, payload, size);
  putU32(out + size, seq);
  putU32(out + size + 4, crc32(out, size + 4));
  return size + TRAILER_BYTES;
}

size_t decode(const uint8_t* data, const size_t size, uint32_t& outSeq) {
  if (size < TRAILER_BYTES) return 0;
  const size_t payload = size - TRAILER_BYTES;
  if (getU32(data + payload + 4) != crc32(data, payload + 4)) return 0;
  outSeq = getU32(data + payload);
  return payload;
}

}  // namespace slot

// --- drain -------------------------------------------------------------------------

bool isDue(const FinishJob& job, const DrainOptions& options) {
  if (job.sent()) return false;
  if (job.parked()) return options.manual;
  if (options.manual || job.nextTryAt == 0 || options.now < MIN_PLAUSIBLE_EPOCH) return true;
  return job.nextTryAt <= options.now;
}

DrainOutcome drainOne(FinishJob& job, FinishTransport& transport, const DrainOptions& options) {
  if (!isDue(job, options)) return DrainOutcome::NotDue;
  int code;

  // The book id: from the download index when the job was made, else match-check, asked only
  // for a hash the server already answered progress for, so no unmatched row is created (S15).
  if (job.bookId == 0 && options.knownHash && strcmp(options.knownHash, job.hash) == 0) {
    int64_t id = 0;
    code = transport.matchCheck(job.hash, id);
    if (code == 401 || code < 0 || code >= 500) return fail(job, code, options);
    if (ok(code) && id > 0) job.bookId = id;
  }

  // 2. book-states: the finish day, when the server last changed the book before it (S6). With no
  // book id it is the only route, so it also carries the status without a day, and the rating.
  const bool rated = options.sendRatings && job.rating != 0;
  if (job.finishedOn != 0 || job.bookId == 0) {
    code = transport.bookStates(job, true, rated && job.bookId == 0);
    if (!ok(code)) return fail(job, code, options);
  }

  if (job.bookId != 0) {
    // 3. Guard read.
    ServerStatus now = ServerStatus::Unknown;
    code = transport.readStatus(job.bookId, now);
    if (!ok(code)) return fail(job, code, options);
    const bool keep = now == ServerStatus::Read || (chosenElsewhere(now) && now != job.statusSeen);
    // 4. read-status read: the same-day tie and the threshold miss.
    if (!keep) {
      code = transport.setRead(job.bookId);
      if (!ok(code)) return fail(job, code, options);
    }
    // 5. The rating, after the status so it attaches to this read (S11).
    if (rated) {
      code = transport.setRating(job.bookId, job.rating);
      if (!ok(code)) return fail(job, code, options);
    }
  }

  // 6. Sent: kept for the stale-push hold until the queue needs the room.
  job.flags = FinishJob::SENT;
  job.attempts = 0;
  job.nextTryAt = 0;
  return DrainOutcome::Sent;
}

bool holdAutomaticPush(const FinishJob* job, const bool finishedLocally, const uint16_t pushPermille,
                       const uint32_t pagesTurnedNow) {
  if (!job || !finishedLocally) return false;
  if (pushPermille + 100 > job->finalPermille) return false;
  return pagesTurnedNow < job->pagesAtFinish + 10;
}

uint32_t parseDay(const char* text) {
  if (!text || strlen(text) != 10 || text[4] != '-' || text[7] != '-') return 0;
  unsigned y = 0, m = 0, d = 0;
  if (sscanf(text, "%4u-%2u-%2u", &y, &m, &d) != 3 || y < 2000 || m < 1 || m > 12 || d < 1 || d > 31) return 0;
  return y * 10000 + m * 100 + d;
}

bool formatDay(const uint32_t day, char out[11]) {
  const unsigned y = day / 10000, m = day / 100 % 100, d = day % 100;
  if (y < 2000 || y > 9999 || m < 1 || m > 12 || d < 1 || d > 31) return false;
  snprintf(out, 11, "%04u-%02u-%02u", y, m, d);
  return true;
}

}  // namespace orbify
